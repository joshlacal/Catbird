import Foundation
import Petrel
import OSLog
import CryptoKit
import SwiftCBOR

// MARK: - ⚠️ EXPERIMENTAL CAR PARSER ⚠️

/// 🧪 EXPERIMENTAL: Core engine for parsing CAR files into structured repository data
/// ⚠️ This is experimental functionality that may encounter parsing errors with malformed CAR files
///
/// The CARParser uses Petrel's CID infrastructure to decode IPLD DAG-CBOR records
/// from AT Protocol CAR backups into SwiftData models for browsing and analysis.
///
/// **Safety Features:**
/// - Never modifies original CAR files
/// - Preserves raw CBOR data alongside parsed data
/// - Comprehensive error handling for corrupted/invalid data
/// - Parsing confidence scores for records
/// - Extensive debug logging
actor CARParser {
    
    // MARK: - Types
    
    /// Result of parsing a single record
    struct ParsedRecord {
        let recordKey: String
        let recordType: String
        let cid: CID
        let rawCBORData: Data
        let parsedData: Any?
        let parseSuccessful: Bool
        let parseError: String?
        let parseConfidence: Double
    }
    
    /// Overall parsing statistics
    struct ParsingStatistics {
        var totalRecords: Int = 0
        var successfullyParsed: Int = 0
        var failedToParse: Int = 0
        var unknownRecordTypes: Int = 0
        var recordTypeCounts: [String: Int] = [:]
        var errors: [String] = []
        var warnings: [String] = []
        var startTime: Date = Date()
        var endTime: Date?
        
        var duration: TimeInterval? {
            guard let endTime = endTime else { return nil }
            return endTime.timeIntervalSince(startTime)
        }
        
        var successRate: Double {
            guard totalRecords > 0 else { return 0.0 }
            return Double(successfullyParsed) / Double(totalRecords)
        }
        
        func toJSON() -> String {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            
            let dict: [String: Any] = [
                "totalRecords": totalRecords,
                "successfullyParsed": successfullyParsed,
                "failedToParse": failedToParse,
                "unknownRecordTypes": unknownRecordTypes,
                "recordTypeCounts": recordTypeCounts,
                "errors": errors,
                "warnings": warnings,
                "startTime": ISO8601DateFormatter().string(from: startTime),
                "endTime": endTime.map { ISO8601DateFormatter().string(from: $0) } ?? nil,
                "duration": duration ?? 0,
                "successRate": successRate
            ]
            
            guard let jsonData = try? JSONSerialization.data(withJSONObject: dict),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                return "{\"error\": \"Failed to serialize statistics\"}"
            }
            
            return jsonString
        }
    }
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "blue.catbird.experimental", category: "CARParser")
    private var parsingStatistics = ParsingStatistics()
    private var parsingLogs: [String] = []
    
    // MARK: - Public API
    
    /// Parse a CAR file and return structured parsing results
    /// ⚠️ EXPERIMENTAL: This method may fail with malformed CAR files
    func parseCAR(data: Data, userDID: String, userHandle: String, backupRecordID: UUID) async throws -> (
        repositoryRecord: RepositoryRecord,
        parsedRecords: [ParsedRecord]
    ) {
        logger.warning("🧪 EXPERIMENTAL: Starting CAR parsing for backup \(backupRecordID.uuidString)")
        
        // Reset parsing state
        parsingStatistics = ParsingStatistics()
        parsingLogs = []
        
        logMessage("Starting CAR parsing for user \(userHandle) (\(userDID))")
        logMessage("CAR data size: \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
        
        do {
            // Parse CAR structure
            let carStructure = try parseCarStructure(data: data)
            logMessage("CAR structure parsed successfully")
            
            // Extract and parse records
            let parsedRecords = try await parseRecords(from: carStructure)
            
            // Calculate statistics
            parsingStatistics.endTime = Date()
            let confidence = calculateOverallConfidence(for: parsedRecords)
            
            // Create repository record
            let repositoryRecord = RepositoryRecord(
                backupRecordID: backupRecordID,
                userDID: userDID,
                userHandle: userHandle,
                totalRecordCount: parsingStatistics.totalRecords,
                successfullyParsedCount: parsingStatistics.successfullyParsed,
                failedParseCount: parsingStatistics.failedToParse,
                unknownRecordTypeCount: parsingStatistics.unknownRecordTypes,
                parsingStatus: .completed,
                parsingConfidenceScore: confidence,
                parsingLogs: parsingLogs.joined(separator: "\n"),
                originalCarSize: Int64(data.count),
                parsingStatistics: parsingStatistics.toJSON(),
                hasMediaReferences: parsedRecords.contains { $0.recordType.contains("media") || $0.recordType.contains("blob") },
                postCount: parsingStatistics.recordTypeCounts["app.bsky.feed.post"] ?? 0,
                profileCount: parsingStatistics.recordTypeCounts["app.bsky.actor.profile"] ?? 0,
                connectionCount: parsingStatistics.recordTypeCounts["app.bsky.graph.follow"] ?? 0,
                mediaCount: countMediaReferences(in: parsedRecords)
            )
            
            logMessage("Parsing completed successfully. Success rate: \(String(format: "%.1f%%", confidence * 100))")
            
            return (repositoryRecord, parsedRecords)
            
        } catch {
            parsingStatistics.endTime = Date()
            parsingStatistics.errors.append(error.localizedDescription)
            
            logMessage("Parsing failed: \(error.localizedDescription)")
            
            // Create failed repository record
            let repositoryRecord = RepositoryRecord(
                backupRecordID: backupRecordID,
                userDID: userDID,
                userHandle: userHandle,
                parsingStatus: .failed,
                parsingErrorMessage: error.localizedDescription,
                parsingLogs: parsingLogs.joined(separator: "\n"),
                originalCarSize: Int64(data.count),
                parsingStatistics: parsingStatistics.toJSON()
            )
            
            throw CARParsingError.parsingFailed(error.localizedDescription, repositoryRecord)
        }
    }
    
    // MARK: - Private Parsing Methods
    
    private func parseCarStructure(data: Data) throws -> CARStructure {
        logMessage("Parsing CAR header structure...")
        
        // Basic CAR validation
        guard data.count > 10 else {
            throw CARParsingError.invalidCARFormat("CAR file too small")
        }
        
        // Parse CAR header (simplified - would need full CAR spec implementation)
        var offset = 0
        
        // Read first varint (header length)
        let (headerLength, headerLengthBytes) = try readVarint(from: data, at: offset)
        offset += headerLengthBytes
        
        logMessage("CAR header length: \(headerLength) bytes")
        
        guard offset + Int(headerLength) <= data.count else {
            throw CARParsingError.invalidCARFormat("Invalid header length")
        }
        
        // Read header CBOR
        let headerData = data[offset..<(offset + Int(headerLength))]
        offset += Int(headerLength)
        
        let header = try parseCarHeader(headerData)
        logMessage("CAR version: \(header.version), roots: \(header.roots.count)")
        
        // Parse blocks
        var blocks: [CARBlock] = []
        var blockIndex = 0
        
        while offset < data.count {
            do {
                let (block, blockSize) = try parseCarBlock(from: data, at: offset, blockIndex: blockIndex)
                blocks.append(block)
                offset += blockSize
                blockIndex += 1
                
                if blockIndex % 100 == 0 {
                    logMessage("Parsed \(blockIndex) blocks...")
                }
                
            } catch {
                logMessage("Failed to parse block at offset \(offset): \(error.localizedDescription)")
                parsingStatistics.errors.append("Block \(blockIndex): \(error.localizedDescription)")
                break
            }
        }
        
        logMessage("Parsed \(blocks.count) CAR blocks total")
        
        return CARStructure(header: header, blocks: blocks)
    }
    
    private func parseRecords(from carStructure: CARStructure) async throws -> [ParsedRecord] {
        logMessage("Parsing AT Protocol records from CAR blocks...")
        
        var parsedRecords: [ParsedRecord] = []
        parsingStatistics.totalRecords = carStructure.blocks.count
        
        for (index, block) in carStructure.blocks.enumerated() {
            do {
                if let record = try parseATProtocolRecord(from: block) {
                    parsedRecords.append(record)
                    parsingStatistics.successfullyParsed += 1
                    
                    // Update record type counts
                    parsingStatistics.recordTypeCounts[record.recordType, default: 0] += 1
                    
                } else {
                    parsingStatistics.unknownRecordTypes += 1
                    logMessage("Unknown record type in block \(index)")
                }
                
                // Periodic progress logging
                if index % 500 == 0 && index > 0 {
                    logMessage("Processed \(index) blocks, \(parsedRecords.count) records parsed")
                }
                
            } catch {
                parsingStatistics.failedToParse += 1
                parsingStatistics.errors.append("Block \(index): \(error.localizedDescription)")
                
                // Still create a record for failed parsing (for debugging)
                let failedRecord = ParsedRecord(
                    recordKey: "unknown_\(index)",
                    recordType: "parse_failed",
                    cid: block.cid,
                    rawCBORData: block.data,
                    parsedData: nil,
                    parseSuccessful: false,
                    parseError: error.localizedDescription,
                    parseConfidence: 0.0
                )
                parsedRecords.append(failedRecord)
            }
        }
        
        logMessage("Record parsing completed. \(parsedRecords.count) total records")
        
        return parsedRecords
    }
    
    private func parseATProtocolRecord(from block: CARBlock) throws -> ParsedRecord? {
        // Decode CBOR data using Petrel's DAG-CBOR infrastructure
        let cborItem: CBOR
        do {
            guard let decoded = try? CBOR.decode([UInt8](block.data)) else {
                throw CARParsingError.invalidCBORData("Failed to decode CBOR")
            }
            cborItem = decoded
        } catch {
            throw CARParsingError.invalidCBORData("CBOR decode error: \(error.localizedDescription)")
        }
        
        // Convert CBOR to Swift value using Petrel's infrastructure
        let swiftValue = try DAGCBOR.decodeCBORItem(cborItem)
        
        // Extract record information
        guard let recordDict = swiftValue as? [String: Any] else {
            return nil // Not a standard AT Protocol record
        }
        
        // Determine record type from the data structure
        let recordType = inferRecordType(from: recordDict)
        let recordKey = extractRecordKey(from: recordDict) ?? "unknown"
        
        // Parse specific record types
        let (parsedData, parseConfidence) = parseSpecificRecordType(
            recordType: recordType,
            data: recordDict,
            rawCBOR: block.data
        )
        
        return ParsedRecord(
            recordKey: recordKey,
            recordType: recordType,
            cid: block.cid,
            rawCBORData: block.data,
            parsedData: parsedData,
            parseSuccessful: parsedData != nil,
            parseError: parsedData == nil ? "Failed to parse record type: \(recordType)" : nil,
            parseConfidence: parseConfidence
        )
    }
    
    private func inferRecordType(from recordDict: [String: Any]) -> String {
        // Look for AT Protocol type indicators
        if let type = recordDict["$type"] as? String {
            return type
        }
        
        // Infer from structure
        if recordDict["text"] != nil && recordDict["createdAt"] != nil {
            return "app.bsky.feed.post"
        } else if recordDict["displayName"] != nil || recordDict["description"] != nil {
            return "app.bsky.actor.profile"
        } else if recordDict["subject"] != nil && recordDict["createdAt"] != nil {
            return "app.bsky.graph.follow"
        }
        
        return "unknown"
    }
    
    private func extractRecordKey(from recordDict: [String: Any]) -> String? {
        // Look for record key indicators
        return recordDict["rkey"] as? String ?? 
               recordDict["recordKey"] as? String
    }
    
    private func parseSpecificRecordType(recordType: String, data: [String: Any], rawCBOR: Data) -> (Any?, Double) {
        switch recordType {
        case "app.bsky.feed.post":
            return parsePostRecord(data: data, rawCBOR: rawCBOR)
        case "app.bsky.actor.profile":
            return parseProfileRecord(data: data, rawCBOR: rawCBOR)
        case "app.bsky.graph.follow":
            return parseFollowRecord(data: data, rawCBOR: rawCBOR)
        default:
            return (data, 0.5) // Unknown type but preserve data
        }
    }
    
    private func parsePostRecord(data: [String: Any], rawCBOR: Data) -> (Any?, Double) {
        guard let text = data["text"] as? String,
              let createdAtString = data["createdAt"] as? String,
              let createdAt = ISO8601DateFormatter().date(from: createdAtString) else {
            return (nil, 0.0)
        }
        
        // Extract optional fields
        let reply = data["reply"] as? [String: Any]
        let embed = data["embed"] as? [String: Any]
        let facets = data["facets"] as? [[String: Any]] ?? []
        let langs = data["langs"] as? [String] ?? []
        let labels = data["labels"] as? [String: Any]
        
        let postData: [String: Any] = [
            "text": text,
            "createdAt": createdAt,
            "reply": reply as Any,
            "embed": embed as Any,
            "facets": facets,
            "langs": langs,
            "labels": labels as Any,
            "rawFields": data
        ]
        
        // Calculate confidence based on required fields
        var confidence = 1.0
        if reply != nil { confidence += 0.1 } // Has reply structure
        if !facets.isEmpty { confidence += 0.1 } // Has rich text
        if embed != nil { confidence += 0.1 } // Has embed
        
        return (postData, min(confidence, 1.0))
    }
    
    private func parseProfileRecord(data: [String: Any], rawCBOR: Data) -> (Any?, Double) {
        // Profile records are more lenient - most fields are optional
        let displayName = data["displayName"] as? String
        let description = data["description"] as? String
        let avatar = data["avatar"] as? [String: Any]
        let banner = data["banner"] as? [String: Any]
        let labels = data["labels"] as? [String: Any]
        
        let profileData: [String: Any] = [
            "displayName": displayName as Any,
            "description": description as Any,
            "avatar": avatar as Any,
            "banner": banner as Any,
            "labels": labels as Any,
            "rawFields": data
        ]
        
        // Confidence based on how much profile data is present
        var confidence = 0.5 // Base confidence for profile
        if displayName != nil { confidence += 0.2 }
        if description != nil { confidence += 0.2 }
        if avatar != nil { confidence += 0.1 }
        
        return (profileData, min(confidence, 1.0))
    }
    
    private func parseFollowRecord(data: [String: Any], rawCBOR: Data) -> (Any?, Double) {
        guard let subject = data["subject"] as? String,
              let createdAtString = data["createdAt"] as? String,
              let createdAt = ISO8601DateFormatter().date(from: createdAtString) else {
            return (nil, 0.0)
        }
        
        let followData: [String: Any] = [
            "subject": subject,
            "createdAt": createdAt,
            "rawFields": data
        ]
        
        return (followData, 1.0) // Follow records are simple and reliable
    }
    
    // MARK: - CAR Structure Parsing (Simplified)
    
    private func parseCarHeader(_ data: Data) throws -> CARHeader {
        // Parse CBOR header
        guard let cborItem = try? CBOR.decode([UInt8](data)) else {
            throw CARParsingError.invalidCARFormat("Invalid header CBOR")
        }
        
        let headerValue = try DAGCBOR.decodeCBORItem(cborItem)
        guard let headerDict = headerValue as? [String: Any] else {
            throw CARParsingError.invalidCARFormat("Header is not a map")
        }
        
        let version = headerDict["version"] as? Int ?? 1
        let roots = headerDict["roots"] as? [String] ?? []
        
        // Convert root strings to CIDs
        let rootCIDs = try roots.compactMap { try? CID.parse($0) }
        
        return CARHeader(version: version, roots: rootCIDs)
    }
    
    private func parseCarBlock(from data: Data, at offset: Int, blockIndex: Int) throws -> (CARBlock, Int) {
        var currentOffset = offset
        
        // Read block length
        let (blockLength, lengthBytes) = try readVarint(from: data, at: currentOffset)
        currentOffset += lengthBytes
        
        if blockIndex < 3 {
            logMessage("Block \(blockIndex): blockLength=\(blockLength), lengthBytes=\(lengthBytes), offset=\(currentOffset)")
        }
        
        guard currentOffset + Int(blockLength) <= data.count else {
            throw CARParsingError.invalidCARFormat("Block extends beyond data")
        }
        
        // Parse CID from raw bytes (no length prefix in CAR format)
        let blockEndOffset = currentOffset + Int(blockLength)
        let (cid, cidLength) = try parseCIDFromBytes(data: data, offset: currentOffset, maxOffset: blockEndOffset)
        currentOffset += cidLength
        
        // Debug logging for CID parsing
        if blockIndex < 3 {
            logMessage("Block \(blockIndex): Parsed CID length=\(cidLength), bytes=\(cid.bytes.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " "))")
        }
        
        // Log hash algorithm info for first few blocks
        if blockIndex < 5 {
            logMessage("Block \(blockIndex): CID uses \(cid.multihash.algorithmName) (0x\(String(format: "%02X", cid.multihash.algorithm))) with \(cid.multihash.length) byte digest")
        }
        
        // Read block data
        let dataLength = Int(blockLength) - cidLength
        guard currentOffset + dataLength <= data.count else {
            throw CARParsingError.invalidCARFormat("Block data extends beyond data")
        }
        
        let blockData = data[currentOffset..<(currentOffset + dataLength)]
        
        let block = CARBlock(cid: cid, data: Data(blockData))
        return (block, Int(blockLength) + lengthBytes)
    }
    
    /// Parse a CID from raw bytes at the given offset, returning the CID and its byte length
    private func parseCIDFromBytes(data: Data, offset: Int, maxOffset: Int) throws -> (CID, Int) {
        // CID format: [version][codec][multihash]
        // Multihash format: [algorithm][length][digest...]
        
        guard offset < maxOffset else {
            throw CARParsingError.invalidCARFormat("CID offset beyond block")
        }
        
        // Read version (1 byte for CIDv1)
        let version = data[offset]
        guard version == 1 else {
            throw CARParsingError.invalidCARFormat("Unsupported CID version: \(version)")
        }
        
        // Read codec (varint)
        let (codecValue, codecBytes) = try readVarint(from: data, at: offset + 1)
        guard let codec = CIDCodec(rawValue: UInt8(codecValue)) else {
            throw CARParsingError.invalidCARFormat("Unsupported CID codec: \(codecValue)")
        }
        
        // Read multihash
        let multihashStart = offset + 1 + codecBytes
        guard multihashStart + 1 < maxOffset else {
            throw CARParsingError.invalidCARFormat("Multihash extends beyond block")
        }
        
        let hashAlgorithm = data[multihashStart]
        let hashLength = data[multihashStart + 1]
        
        let digestStart = multihashStart + 2
        let digestEnd = digestStart + Int(hashLength)
        
        guard digestEnd <= maxOffset else {
            throw CARParsingError.invalidCARFormat("Hash digest extends beyond block")
        }
        
        let digest = data[digestStart..<digestEnd]
        let multihash = Multihash(algorithm: hashAlgorithm, length: hashLength, digest: Data(digest))
        
        let cid = CID(codec: codec, multihash: multihash)
        let totalCIDLength = digestEnd - offset
        
        return (cid, totalCIDLength)
    }
    
    private func readVarint(from data: Data, at offset: Int) throws -> (UInt64, Int) {
        var result: UInt64 = 0
        var bytesRead = 0
        var shift = 0
        
        while offset + bytesRead < data.count {
            let byte = data[offset + bytesRead]
            result |= UInt64(byte & 0x7F) << shift
            bytesRead += 1
            
            if byte & 0x80 == 0 {
                break
            }
            
            shift += 7
            if shift >= 64 {
                throw CARParsingError.invalidCARFormat("Varint too long")
            }
        }
        
        return (result, bytesRead)
    }
    
    // MARK: - Utility Methods
    
    private func calculateOverallConfidence(for records: [ParsedRecord]) -> Double {
        guard !records.isEmpty else { return 0.0 }
        
        let totalConfidence = records.reduce(0.0) { $0 + $1.parseConfidence }
        let averageConfidence = totalConfidence / Double(records.count)
        
        // Boost confidence if we have high success rate
        let successRate = Double(records.filter { $0.parseSuccessful }.count) / Double(records.count)
        
        return min((averageConfidence + successRate) / 2.0, 1.0)
    }
    
    private func countMediaReferences(in records: [ParsedRecord]) -> Int {
        return records.filter { record in
            if let data = record.parsedData as? [String: Any],
               let embed = data["embed"] as? [String: Any] {
                return embed["images"] != nil || embed["video"] != nil
            }
            return false
        }.count
    }
    
    private func logMessage(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logEntry = "[\(timestamp)] \(message)"
        parsingLogs.append(logEntry)
        logger.debug("\(logEntry)")
    }
}

// MARK: - Supporting Types

struct CARStructure {
    let header: CARHeader
    let blocks: [CARBlock]
}

struct CARHeader {
    let version: Int
    let roots: [CID]
}

struct CARBlock {
    let cid: CID
    let data: Data
}

// MARK: - Errors

enum CARParsingError: LocalizedError {
    case invalidCARFormat(String)
    case invalidCBORData(String)
    case unsupportedRecordType(String)
    case parsingFailed(String, RepositoryRecord)
    
    var errorDescription: String? {
        switch self {
        case .invalidCARFormat(let message):
            return "Invalid CAR format: \(message)"
        case .invalidCBORData(let message):
            return "Invalid CBOR data: \(message)"
        case .unsupportedRecordType(let type):
            return "Unsupported record type: \(type)"
        case .parsingFailed(let message, _):
            return "Parsing failed: \(message)"
        }
    }
}
