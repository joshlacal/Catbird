import Foundation
import Petrel
import OSLog
import CryptoKit
import SwiftCBOR

// MARK: - ⚠️ EXPERIMENTAL CAR PARSER ⚠️

// MARK: - Memory Monitor

/// Memory monitoring utility for parsing operations
private class MemoryMonitor {
    private let warningThreshold: UInt64 = 500_000_000 // 500MB warning threshold (iOS safe limit)
    private let criticalThreshold: UInt64 = 800_000_000 // 800MB critical threshold (before iOS kill)
    
    struct MemoryInfo {
        let currentUsage: UInt64
        let isWarning: Bool
        let isCritical: Bool
        
        var formattedUsage: String {
            return ByteCountFormatter.string(fromByteCount: Int64(currentUsage), countStyle: .memory)
        }
    }
    
    func getCurrentMemoryUsage() -> MemoryInfo {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        let currentUsage = result == KERN_SUCCESS ? info.resident_size : 0
        
        return MemoryInfo(
            currentUsage: currentUsage,
            isWarning: currentUsage > warningThreshold,
            isCritical: currentUsage > criticalThreshold
        )
    }
    
    func checkMemoryUsage(logEssential: (String) -> Void, dummyRepositoryRecord: () -> RepositoryRecord) throws {
        let memInfo = getCurrentMemoryUsage()
        
        if memInfo.isCritical {
            let message = "🚨 CRITICAL: Memory usage at \(memInfo.formattedUsage) - stopping parsing to prevent crash"
            logEssential(message)
            throw CARParsingError.parsingFailed("Memory usage exceeded safe limits: \(memInfo.formattedUsage)", dummyRepositoryRecord())
        } else if memInfo.isWarning {
            logEssential("⚠️ WARNING: High memory usage at \(memInfo.formattedUsage)")
        }
    }
}

// MARK: - Memory-Safe Circular Log Buffer

/// Memory-efficient circular buffer for logging with fixed capacity and optional file output
private class CircularLogBuffer {
    private var buffer: [String]
    private let capacity: Int
    private var currentIndex: Int = 0
    private var count: Int = 0
    let logFileURL: URL?
    private var fileHandle: FileHandle?
    
    init(capacity: Int, enableFileLogging: Bool = false) {
        self.capacity = capacity
        self.buffer = Array(repeating: "", count: capacity)
        
        if enableFileLogging {
            // Create log file in temporary directory
            let tempDir = FileManager.default.temporaryDirectory
            let logFileName = "car-parser-\(UUID().uuidString).log"
            self.logFileURL = tempDir.appendingPathComponent(logFileName)
            
            // Initialize file
            if let url = logFileURL {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
                self.fileHandle = try? FileHandle(forWritingTo: url)
            }
        } else {
            self.logFileURL = nil
        }
    }
    
    func append(_ message: String) {
        buffer[currentIndex] = message
        currentIndex = (currentIndex + 1) % capacity
        count = min(count + 1, capacity)
        
        // Also write to file if file logging is enabled
        if let fileHandle = fileHandle {
            let messageWithNewline = message + "\n"
            if let data = messageWithNewline.data(using: .utf8) {
                try? fileHandle.write(contentsOf: data)
            }
        }
    }
    
    func clear() {
        currentIndex = 0
        count = 0
        buffer = Array(repeating: "", count: capacity)
    }
    
    var allLogs: [String] {
        guard count > 0 else { return [] }
        
        if count < capacity {
            // Buffer not full yet, return only filled entries
            return Array(buffer.prefix(count))
        } else {
            // Buffer is full, return in correct order
            let firstPart = Array(buffer[currentIndex...])
            let secondPart = Array(buffer[..<currentIndex])
            return firstPart + secondPart
        }
    }
    
    var logSummary: String {
        let totalEntries = count
        let capacity = self.capacity
        let hasMore = count >= capacity
        
        if hasMore {
            return "Last \(capacity) log entries (total: \(totalEntries)+ entries, showing most recent)"
        } else {
            return "\(totalEntries) log entries"
        }
    }
    
    
    func closeFile() {
        try? fileHandle?.close()
        fileHandle = nil
    }
    
    deinit {
        closeFile()
    }
}

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
    private var logBuffer = CircularLogBuffer(capacity: 500, enableFileLogging: true) // Memory-safe log buffer with file backup
    private let enableVerboseLogging: Bool
    private var memoryMonitor = MemoryMonitor()
    
    // MARK: - Initialization
    
    init(enableVerboseLogging: Bool = false) {
        self.enableVerboseLogging = enableVerboseLogging
    }
    
    // MARK: - Public API
    
    /// Parse a CAR file with batch processing to manage memory usage
    /// ⚠️ EXPERIMENTAL: This method may fail with malformed CAR files
    /// - Parameters:
    ///   - data: CAR file data
    ///   - userDID: User's DID
    ///   - userHandle: User's handle
    ///   - backupRecordID: Backup record ID
    ///   - batchSize: Number of records to process in each batch (default: 100)
    ///   - onBatch: Callback called for each batch of parsed records
    /// - Returns: Repository record and total count of parsed records
    func parseCARWithBatching(
        data: Data,
        userDID: String,
        userHandle: String,
        backupRecordID: UUID,
        batchSize: Int = 10,
        onBatch: @escaping ([ParsedRecord]) async throws -> Void
    ) async throws -> (repositoryRecord: RepositoryRecord, totalRecordCount: Int, logFileURL: URL?) {
        logger.warning("🧪 EXPERIMENTAL: Starting batched CAR parsing for backup \(backupRecordID.uuidString)")
        
        // Reset parsing state
        parsingStatistics = ParsingStatistics()
        logBuffer.clear()
        
        logEssential("Starting batched CAR parsing for user \(userHandle) (\(userDID))")
        logEssential("CAR data size: \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
        logEssential("Batch size: \(batchSize) records per batch")
        
        // Initial memory check
        let initialMemInfo = memoryMonitor.getCurrentMemoryUsage()
        logEssential("Initial memory usage: \(initialMemInfo.formattedUsage)")
        
        var totalParsedRecords = 0
        
        do {
            // Parse CAR structure
            let carStructure = try parseCarStructure(data: data)
            logEssential("CAR structure parsed successfully")
            
            // Process records in batches
            totalParsedRecords = try await parseRecordsInBatches(
                from: carStructure,
                batchSize: batchSize,
                backupRecordID: backupRecordID,
                userDID: userDID,
                userHandle: userHandle,
                originalDataSize: Int64(data.count),
                onBatch: onBatch
            )
            
            // Calculate final statistics
            parsingStatistics.endTime = Date()
            let confidence = parsingStatistics.successRate
            
            logEssential("Batched parsing completed successfully.")
            logEssential("Total records processed: \(totalParsedRecords)")
            logEssential("Success rate: \(String(format: "%.1f%%", confidence * 100))")
            
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
                parsingLogs: logBuffer.allLogs.joined(separator: "\n"),
                parsingLogFileURL: logBuffer.logFileURL,
                originalCarSize: Int64(data.count),
                parsingStatistics: parsingStatistics.toJSON(),
                hasMediaReferences: false, // Will be updated by batch processor
                postCount: parsingStatistics.recordTypeCounts["app.bsky.feed.post"] ?? 0,
                profileCount: parsingStatistics.recordTypeCounts["app.bsky.actor.profile"] ?? 0,
                connectionCount: parsingStatistics.recordTypeCounts["app.bsky.graph.follow"] ?? 0,
                mediaCount: 0 // Will be updated by batch processor
            )
            
            // Close the log file to ensure all data is written
            logBuffer.closeFile()
            
            return (repositoryRecord, totalParsedRecords, logBuffer.logFileURL)
            
        } catch {
            parsingStatistics.endTime = Date()
            parsingStatistics.errors.append(error.localizedDescription)
            
            logEssential("Batched parsing failed: \(error.localizedDescription)")
            
            // Create failed repository record
            let repositoryRecord = RepositoryRecord(
                backupRecordID: backupRecordID,
                userDID: userDID,
                userHandle: userHandle,
                parsingStatus: .failed,
                parsingErrorMessage: error.localizedDescription,
                parsingLogs: logBuffer.allLogs.joined(separator: "\n"),
                parsingLogFileURL: logBuffer.logFileURL,
                originalCarSize: Int64(data.count),
                parsingStatistics: parsingStatistics.toJSON()
            )
            
            throw CARParsingError.parsingFailed(error.localizedDescription, repositoryRecord)
        }
    }
    
    /// Parse a CAR file and return structured parsing results (Legacy method - prefer parseCARWithBatching)
    /// ⚠️ EXPERIMENTAL: This method may fail with malformed CAR files and can use excessive memory
    func parseCAR(data: Data, userDID: String, userHandle: String, backupRecordID: UUID) async throws -> (
        repositoryRecord: RepositoryRecord,
        parsedRecords: [ParsedRecord],
        logFileURL: URL?
    ) {
        logger.warning("🧪 EXPERIMENTAL: Starting CAR parsing for backup \(backupRecordID.uuidString)")
        
        // Reset parsing state
        parsingStatistics = ParsingStatistics()
        logBuffer.clear()
        
        logEssential("Starting CAR parsing for user \(userHandle) (\(userDID))")
        logEssential("CAR data size: \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
        
        do {
            // Parse CAR structure
            let carStructure = try parseCarStructure(data: data)
            logEssential("CAR structure parsed successfully")
            
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
                parsingLogs: logBuffer.allLogs.joined(separator: "\n"),
                parsingLogFileURL: logBuffer.logFileURL,
                originalCarSize: Int64(data.count),
                parsingStatistics: parsingStatistics.toJSON(),
                hasMediaReferences: parsedRecords.contains { $0.recordType.contains("media") || $0.recordType.contains("blob") },
                postCount: parsingStatistics.recordTypeCounts["app.bsky.feed.post"] ?? 0,
                profileCount: parsingStatistics.recordTypeCounts["app.bsky.actor.profile"] ?? 0,
                connectionCount: parsingStatistics.recordTypeCounts["app.bsky.graph.follow"] ?? 0,
                mediaCount: countMediaReferences(in: parsedRecords)
            )
            
            logEssential("Parsing completed successfully. Success rate: \(String(format: "%.1f%%", confidence * 100))")
            
            // Close the log file to ensure all data is written
            logBuffer.closeFile()
            
            return (repositoryRecord, parsedRecords, logBuffer.logFileURL)
            
        } catch {
            parsingStatistics.endTime = Date()
            parsingStatistics.errors.append(error.localizedDescription)
            
            logEssential("Parsing failed: \(error.localizedDescription)")
            
            // Create failed repository record
            let repositoryRecord = RepositoryRecord(
                backupRecordID: backupRecordID,
                userDID: userDID,
                userHandle: userHandle,
                parsingStatus: .failed,
                parsingErrorMessage: error.localizedDescription,
                parsingLogs: logBuffer.allLogs.joined(separator: "\n"),
                parsingLogFileURL: logBuffer.logFileURL,
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
        
        // Build repository map by traversing the repository structure
        let repositoryMap = try buildRepositoryMap(from: header, blocks: blocks)
        
        // Update blocks with their repository paths
        var enhancedBlocks = blocks
        for i in 0..<enhancedBlocks.count {
            if let path = repositoryMap.getPath(for: enhancedBlocks[i].cid) {
                enhancedBlocks[i].repositoryPath = path
                let pathComponents = extractPathComponents(from: path)
                enhancedBlocks[i].collectionType = pathComponents.collectionType
                enhancedBlocks[i].recordKey = pathComponents.recordKey
            }
        }
        
        return CARStructure(header: header, blocks: enhancedBlocks, repositoryMap: repositoryMap)
    }
    
    private func parseRecords(from carStructure: CARStructure) async throws -> [ParsedRecord] {
        logMessage("Parsing AT Protocol records from CAR blocks...")
        
        var parsedRecords: [ParsedRecord] = []
        parsingStatistics.totalRecords = carStructure.blocks.count
        
        for (index, block) in carStructure.blocks.enumerated() {
            do {
                // Try to parse as AT Protocol record
                if let record = try parseATProtocolRecord(from: block, repositoryMap: carStructure.repositoryMap) {
                    parsedRecords.append(record)
                    parsingStatistics.successfullyParsed += 1
                    
                    // Update record type counts
                    parsingStatistics.recordTypeCounts[record.recordType, default: 0] += 1
                    
                    if record.recordType == "app.bsky.feed.post" {
                        logVerbose("✅ Successfully parsed POST record \(index): \(record.recordKey)")
                    }
                    
                } else {
                    parsingStatistics.unknownRecordTypes += 1
                    logMessage("❓ Block \(index) did not parse as AT Protocol record")
                    
                    // For debugging: try to inspect the block content directly
                    if index < 5 { // Only for first few blocks to avoid spam
                        try inspectBlockContent(block, index: index)
                    }
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
    
    /// Parse records in batches to manage memory usage
    private func parseRecordsInBatches(
        from carStructure: CARStructure,
        batchSize: Int,
        backupRecordID: UUID,
        userDID: String,
        userHandle: String,
        originalDataSize: Int64,
        onBatch: @escaping ([ParsedRecord]) async throws -> Void
    ) async throws -> Int {
        logEssential("Parsing AT Protocol records from CAR blocks in batches...")
        
        var currentBatch: [ParsedRecord] = []
        var totalProcessed = 0
        var batchCount = 0
        
        let blocks = carStructure.blocks
        parsingStatistics.totalRecords = blocks.count
        
        for (index, block) in blocks.enumerated() {
            do {
                if let record = try parseATProtocolRecord(from: block, repositoryMap: carStructure.repositoryMap) {
                    parsingStatistics.successfullyParsed += 1
                    currentBatch.append(record)
                    
                    // Update record type counts
                    parsingStatistics.recordTypeCounts[record.recordType, default: 0] += 1
                    
                    if record.recordType == "app.bsky.feed.post" {
                        logVerbose("✅ Successfully parsed POST record \(index): \(record.recordKey)")
                    }
                    
                } else {
                    parsingStatistics.unknownRecordTypes += 1
                    logMessage("❓ Block \(index) did not parse as AT Protocol record")
                }
                
                // Process batch when it reaches the batch size
                if currentBatch.count >= batchSize {
                    batchCount += 1
                    logEssential("Processing batch \(batchCount) with \(currentBatch.count) records")
                    
                    // Memory check before processing batch
                    try memoryMonitor.checkMemoryUsage(
                        logEssential: logEssential,
                        dummyRepositoryRecord: {
                            RepositoryRecord(
                                backupRecordID: backupRecordID,
                                userDID: userDID,
                                userHandle: userHandle,
                                parsingStatus: .failed,
                                parsingErrorMessage: "Memory limit exceeded during batch processing",
                                parsingLogs: logBuffer.allLogs.joined(separator: "\n"),
                                parsingLogFileURL: logBuffer.logFileURL,
                                originalCarSize: originalDataSize,
                                parsingStatistics: parsingStatistics.toJSON()
                            )
                        }
                    )
                    
                    // Process batch synchronously to reduce memory pressure
                    // Concurrent processing can create multiple memory-intensive tasks
                    try await onBatch(currentBatch)
                    
                    totalProcessed += currentBatch.count
                    currentBatch.removeAll() // Clear batch from memory immediately
                    
                    // Memory check after processing batch
                    let postBatchMemInfo = memoryMonitor.getCurrentMemoryUsage()
                    logEssential("Processed \(totalProcessed) records in \(batchCount) batches so far - Memory: \(postBatchMemInfo.formattedUsage)")
                }
                
                // Periodic progress logging for blocks
                if index % 500 == 0 && index > 0 {
                    logMessage("Processed \(index) blocks, \(totalProcessed + currentBatch.count) records parsed")
                }
                
            } catch {
                parsingStatistics.failedToParse += 1
                parsingStatistics.errors.append("Block \(index): \(error.localizedDescription)")
                logMessage("Failed to parse block \(index): \(error.localizedDescription)")
                
                // Create a failed record for tracking
                let failedRecord = ParsedRecord(
                    recordKey: "failed-\(index)",
                    recordType: "unknown",
                    cid: block.cid,
                    rawCBORData: block.data,
                    parsedData: nil,
                    parseSuccessful: false,
                    parseError: error.localizedDescription,
                    parseConfidence: 0.0
                )
                currentBatch.append(failedRecord)
            }
        }
        
        // Process any remaining records in the final batch
        if !currentBatch.isEmpty {
            batchCount += 1
            logEssential("Processing final batch \(batchCount) with \(currentBatch.count) records")
            
            try await onBatch(currentBatch)
            totalProcessed += currentBatch.count
            currentBatch.removeAll() // Clear final batch from memory
        }
        
        logEssential("Batch record parsing completed. \(totalProcessed) total records processed in \(batchCount) batches")
        
        return totalProcessed
    }
    
    private func parseATProtocolRecord(from block: CARBlock, repositoryMap: RepositoryMap) throws -> ParsedRecord? {
        // Debug: Log block information
        logVerbose("🔍 Parsing block CID: \(block.cid.string)")
        logVerbose("📦 Block data size: \(block.data.count) bytes")
        if let path = block.repositoryPath {
            logVerbose("📍 Repository path: \(path)")
        }
        if let collectionType = block.collectionType {
            logVerbose("📑 Collection type: \(collectionType)")
        }
        if let recordKey = block.recordKey {
            logVerbose("🔑 Record key: \(recordKey)")
        }
        
        // Decode CBOR data using Petrel's DAG-CBOR infrastructure
        let cborItem: CBOR
        do {
            guard let decoded = try? CBOR.decode([UInt8](block.data)) else {
                logMessage("❌ Failed to decode CBOR for block \(block.cid.string)")
                throw CARParsingError.invalidCBORData("Failed to decode CBOR")
            }
            cborItem = decoded
            logVerbose("✅ Successfully decoded CBOR for block \(block.cid.string)")
        } catch {
            logVerbose("❌ CBOR decode error for block \(block.cid.string): \(error.localizedDescription)")
            throw CARParsingError.invalidCBORData("CBOR decode error: \(error.localizedDescription)")
        }
        
        // Convert CBOR to Swift value using Petrel's infrastructure
        let swiftValue = try DAGCBOR.decodeCBORItem(cborItem)
        
        // Extract record information
        logMessage("🔍 Swift value type: \(type(of: swiftValue))")
        
        guard let recordDict = swiftValue as? [String: Any] else {
            logMessage("❌ Block \(block.cid.string) is not a dictionary - type: \(type(of: swiftValue))")
            if let stringValue = swiftValue as? String {
                logMessage("📝 String content: \(stringValue.prefix(100))")
            } else if let arrayValue = swiftValue as? [Any] {
                logMessage("📜 Array with \(arrayValue.count) elements")
            }
            return nil // Not a standard AT Protocol record
        }
        
        logMessage("✅ Block \(block.cid.string) is a dictionary with \(recordDict.keys.count) keys")
        logMessage("🔑 Dictionary keys: \(Array(recordDict.keys).sorted())")
        
        // Log some sample values for debugging
        for (key, value) in recordDict.prefix(3) {
            let valueType = type(of: value)
            let valuePreview = String(describing: value).prefix(50)
            logMessage("🔍 \(key): \(valueType) = \(valuePreview)...")
        }
        
        // Use repository path information if available, otherwise infer from data
        let recordType: String
        let recordKey: String
        
        if let pathCollectionType = block.collectionType, let pathRecordKey = block.recordKey {
            // Use information from repository path
            recordType = pathCollectionType
            recordKey = pathRecordKey
            logMessage("✅ Using path-based record info: \(recordType)/\(recordKey)")
        } else {
            // Fallback to inference from data structure
            recordType = inferRecordType(from: recordDict)
            recordKey = extractRecordKey(from: recordDict) ?? "unknown"
            logMessage("🤔 Inferred from data: \(recordType)/\(recordKey)")
        }
        
        // Log successful parsing
        if block.repositoryPath != nil {
            logMessage("✅ Found record at path: \(block.repositoryPath!) -> \(recordType)/\(recordKey)")
        } else {
            logMessage("🔍 Processing record without path: \(recordType)/\(recordKey)")
        }
        
        // Parse specific record types
        logMessage("🔧 Parsing specific record type: \(recordType)")
        let (parsedData, parseConfidence) = parseSpecificRecordType(
            recordType: recordType,
            data: recordDict,
            rawCBOR: block.data
        )
        
        if parsedData != nil {
            logMessage("✅ Successfully parsed \(recordType) with confidence \(parseConfidence)")
        } else {
            logMessage("❌ Failed to parse \(recordType)")
        }
        
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
        logMessage("🔎 Inferring record type from dictionary with keys: \(Array(recordDict.keys).sorted())")
        
        // Look for AT Protocol type indicators
        if let type = recordDict["$type"] as? String {
            logMessage("✅ Found explicit $type: \(type)")
            return type
        }
        
        // Enhanced inference from structure
        if recordDict["text"] != nil && recordDict["createdAt"] != nil {
            logMessage("✅ Inferred as app.bsky.feed.post (has text + createdAt)")
            return "app.bsky.feed.post"
        } else if recordDict["displayName"] != nil || recordDict["description"] != nil || recordDict["avatar"] != nil {
            return "app.bsky.actor.profile"
        } else if let subject = recordDict["subject"] as? String, recordDict["createdAt"] != nil {
            // Determine specific graph record type based on context
            if subject.contains("app.bsky.feed.post") {
                return "app.bsky.feed.like"
            } else if subject.hasPrefix("did:") {
                return "app.bsky.graph.follow"
            } else {
                return "app.bsky.graph.follow" // Default for subject + createdAt
            }
        } else if recordDict["subject"] != nil && recordDict["createdAt"] == nil {
            return "app.bsky.graph.block"
        } else if recordDict["list"] != nil && recordDict["subject"] != nil {
            return "app.bsky.graph.listitem"
        } else if recordDict["name"] != nil && recordDict["purpose"] != nil {
            return "app.bsky.graph.list"
        } else if recordDict["parent"] != nil && recordDict["root"] != nil {
            return "app.bsky.feed.post" // Reply post
        } else if recordDict["embed"] != nil {
            return "app.bsky.feed.post" // Post with embed
        }
        
        logMessage("❓ Could not infer record type, defaulting to 'unknown'")
        return "unknown"
    }
    
    private func extractRecordKey(from recordDict: [String: Any]) -> String? {
        // Look for record key indicators in various possible fields
        if let rkey = recordDict["rkey"] as? String {
            return rkey
        }
        if let recordKey = recordDict["recordKey"] as? String {
            return recordKey
        }
        
        // For some record types, we can generate a reasonable key from content
        if let createdAt = recordDict["createdAt"] as? String {
            // Use a hash of the creation timestamp as a fallback key
            let timestamp = createdAt.replacingOccurrences(of: ":", with: "")
                                   .replacingOccurrences(of: "-", with: "")
                                   .replacingOccurrences(of: ".", with: "")
                                   .replacingOccurrences(of: "T", with: "")
                                   .replacingOccurrences(of: "Z", with: "")
            return String(timestamp.prefix(13)) // Use first 13 chars as key
        }
        
        // If we have text content, create a simple hash-based key
        if let text = recordDict["text"] as? String, !text.isEmpty {
            let hashValue = abs(text.hashValue)
            return String(hashValue)
        }
        
        return nil
    }
    
    private func parseSpecificRecordType(recordType: String, data: [String: Any], rawCBOR: Data) -> (Any?, Double) {
        logMessage("🔧 Using Petrel models for parsing \(recordType)")
        
        switch recordType {
        case "app.bsky.feed.post":
            return parsePetrelRecordDirect(AppBskyFeedPost.self, cborData: rawCBOR, recordType: recordType)
        case "app.bsky.actor.profile":
            return parsePetrelRecordDirect(AppBskyActorProfile.self, cborData: rawCBOR, recordType: recordType)
        case "app.bsky.graph.follow":
            return parsePetrelRecordDirect(AppBskyGraphFollow.self, cborData: rawCBOR, recordType: recordType)
        case "app.bsky.feed.like":
            return parsePetrelRecordDirect(AppBskyFeedLike.self, cborData: rawCBOR, recordType: recordType)
        case "app.bsky.graph.block":
            return parsePetrelRecordDirect(AppBskyGraphBlock.self, cborData: rawCBOR, recordType: recordType)
        case "app.bsky.graph.listitem":
            return parsePetrelRecordDirect(AppBskyGraphListitem.self, cborData: rawCBOR, recordType: recordType)
        case "app.bsky.graph.list":
            return parsePetrelRecordDirect(AppBskyGraphList.self, cborData: rawCBOR, recordType: recordType)
        case "app.bsky.feed.repost":
            return parsePetrelRecordDirect(AppBskyFeedRepost.self, cborData: rawCBOR, recordType: recordType)
        default:
            logMessage("❓ Unknown record type \(recordType), preserving raw data")
            return (data, 0.5) // Unknown type but preserve data
        }
    }
    
    private func parsePostRecord(data: [String: Any], rawCBOR: Data) -> (Any?, Double) {
        logMessage("📝 Parsing post record with keys: \(Array(data.keys).sorted())")
        
        let text = data["text"] as? String
        let createdAtString = data["createdAt"] as? String
        
        logMessage("🔍 Post text present: \(text != nil), createdAt present: \(createdAtString != nil)")
        if let text = text {
            logMessage("📝 Post text preview: \(text.prefix(50))...")
        }
        if let createdAtString = createdAtString {
            logMessage("🗓️ Post createdAt: \(createdAtString)")
        }
        
        guard let text = text,
              let createdAtString = createdAtString,
              let createdAt = ISO8601DateFormatter().date(from: createdAtString) else {
            logMessage("❌ Post parsing failed - missing required fields")
            return (nil, 0.0)
        }
        
        logMessage("✅ Post parsing successful - text length: \(text.count)")
        
        
        // Extract optional fields
        let reply = data["reply"] as? [String: Any]
        let embed = data["embed"] as? [String: Any]
        let facets = data["facets"] as? [[String: Any]] ?? []
        let langs = data["langs"] as? [String] ?? []
        let labels = data["labels"] as? [String: Any]
        
        let postData: [String: Any] = [
            "text": text,
            "createdAt": createdAtString, // Keep as string for JSON serialization
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
              let createdAtString = data["createdAt"] as? String else {
            return (nil, 0.0)
        }
        
        let followData: [String: Any] = [
            "subject": subject,
            "createdAt": createdAtString,
            "rawFields": data
        ]
        
        return (followData, 1.0)
    }
    
    private func parseLikeRecord(data: [String: Any], rawCBOR: Data) -> (Any?, Double) {
        guard let subject = data["subject"] as? [String: Any],
              let uri = subject["uri"] as? String,
              let createdAtString = data["createdAt"] as? String else {
            return (nil, 0.0)
        }
        
        let likeData: [String: Any] = [
            "subject": [
                "uri": uri,
                "cid": subject["cid"] as? String ?? ""
            ],
            "createdAt": createdAtString,
            "rawFields": data
        ]
        
        return (likeData, 1.0)
    }
    
    private func parseBlockRecord(data: [String: Any], rawCBOR: Data) -> (Any?, Double) {
        guard let subject = data["subject"] as? String,
              let createdAtString = data["createdAt"] as? String else {
            return (nil, 0.0)
        }
        
        let blockData: [String: Any] = [
            "subject": subject,
            "createdAt": createdAtString,
            "rawFields": data
        ]
        
        return (blockData, 1.0)
    }
    
    private func parseListItemRecord(data: [String: Any], rawCBOR: Data) -> (Any?, Double) {
        guard let subject = data["subject"] as? String,
              let list = data["list"] as? String,
              let createdAtString = data["createdAt"] as? String else {
            return (nil, 0.0)
        }
        
        let listItemData: [String: Any] = [
            "subject": subject,
            "list": list,
            "createdAt": createdAtString,
            "rawFields": data
        ]
        
        return (listItemData, 1.0)
    }
    
    private func parseListRecord(data: [String: Any], rawCBOR: Data) -> (Any?, Double) {
        guard let name = data["name"] as? String,
              let purpose = data["purpose"] as? String else {
            return (nil, 0.0)
        }
        
        let listData: [String: Any] = [
            "name": name,
            "purpose": purpose,
            "description": data["description"] as? String ?? "",
            "createdAt": data["createdAt"] as? String ?? "",
            "rawFields": data
        ]
        
        return (listData, 0.9)
    }
    
    private func parseRepostRecord(data: [String: Any], rawCBOR: Data) -> (Any?, Double) {
        guard let subject = data["subject"] as? [String: Any],
              let uri = subject["uri"] as? String,
              let createdAtString = data["createdAt"] as? String else {
            return (nil, 0.0)
        }
        
        let repostData: [String: Any] = [
            "subject": [
                "uri": uri,
                "cid": subject["cid"] as? String ?? ""
            ],
            "createdAt": createdAtString,
            "rawFields": data
        ]
        
        return (repostData, 1.0)
    }
    
    // MARK: - Petrel Model Parsing
    
    /// Parse using Petrel's AT Protocol models directly from CBOR data
    private func parsePetrelRecordDirect<T: ATProtocolCodable>(_ modelType: T.Type, cborData: Data, recordType: String) -> (Any?, Double) {
        logMessage("🅰️ Parsing \(recordType) directly using Petrel model \(String(describing: modelType))")
        
        do {
            // Use Petrel's built-in DAG-CBOR decoding
            let parsedModel = try modelType.decodedFromDAGCBOR(cborData)
            
            logMessage("✅ Successfully parsed \(recordType) using Petrel's DAG-CBOR decoder")
            
            // Convert to dictionary for storage consistency
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let encodedData = try encoder.encode(parsedModel)
            
            do {
                let resultDict = try JSONSerialization.jsonObject(with: encodedData) as? [String: Any]
                return (resultDict, 1.0)
            } catch {
                // If JSON serialization fails, create a simplified representation
                logMessage("⚠️ Model parsed successfully but couldn't convert to JSON dict")
                let simplifiedResult: [String: Any] = [
                    "$type": recordType,
                    "parseSuccessful": true,
                    "modelType": String(describing: modelType)
                ]
                return (simplifiedResult, 0.9)
            }
            
        } catch {
            logMessage("❌ Failed to parse \(recordType) with Petrel DAG-CBOR decoder: \(error.localizedDescription)")
            
            // Fallback to low confidence
            return (nil, 0.1)
        }
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
        let rootCIDs = roots.compactMap { try? CID.parse($0) }
        
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
    
    private func logMessage(_ message: String, level: LogLevel = .debug) {
        // Always log to system logger for debugging
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logEntry = "[\(timestamp)] \(message)"
        logger.debug("\(logEntry)")
        
        // Only store in memory buffer for essential logs or when verbose logging is enabled
        let shouldStore = level == .essential || enableVerboseLogging
        if shouldStore {
            logBuffer.append(logEntry)
        }
    }
    
    // Add convenience methods for different log levels
    private func logEssential(_ message: String) {
        logMessage(message, level: .essential)
    }
    
    private func logVerbose(_ message: String) {
        logMessage(message, level: .verbose)
    }
    
    enum LogLevel {
        case essential  // Always stored in buffer (critical info)
        case debug     // Default level, stored only if verbose enabled
        case verbose   // Detailed debugging, stored only if verbose enabled
    }
    
    /// Debug helper to inspect block content directly
    private func inspectBlockContent(_ block: CARBlock, index: Int) throws {
        logMessage("🔍 DEEP INSPECTION Block \(index) CID: \(block.cid.string)")
        
        // Try to decode CBOR
        if let cborItem = try? CBOR.decode([UInt8](block.data)) {
            let swiftValue = try DAGCBOR.decodeCBORItem(cborItem)
            
            if let dict = swiftValue as? [String: Any] {
                logMessage("📋 Block \(index) is dictionary with keys: \(Array(dict.keys).prefix(10))")
                
                // Check for post-like content
                if dict["text"] != nil {
                    logMessage("📝 Block \(index) contains 'text' field")
                }
                if dict["createdAt"] != nil {
                    logMessage("🗓️ Block \(index) contains 'createdAt' field")
                }
                if dict["$type"] != nil {
                    logMessage("🏷️ Block \(index) contains '$type': \(dict["$type"] ?? "unknown")")
                }
                
                // If it looks like a post, log more details
                if dict["text"] != nil && dict["createdAt"] != nil {
                    logMessage("❗ Block \(index) looks like a POST but wasn't parsed as one!")
                    if let text = dict["text"] as? String {
                        logMessage("📝 Post text: \(text.prefix(100))")
                    }
                    if let createdAt = dict["createdAt"] as? String {
                        logMessage("🗓️ Post createdAt: \(createdAt)")
                    }
                }
            } else {
                logMessage("🤷 Block \(index) is not a dictionary: \(type(of: swiftValue))")
            }
        } else {
            logMessage("❌ Block \(index) failed CBOR decode")
        }
    }
    
    // MARK: - Repository Structure Analysis
    
    /// Build a map of CIDs to their paths in the repository structure
    private func buildRepositoryMap(from header: CARHeader, blocks: [CARBlock]) throws -> RepositoryMap {
        var repositoryMap = RepositoryMap()
        
        logMessage("Building repository map from \(blocks.count) blocks and \(header.roots.count) roots...")
        
        // Start with root blocks and traverse the repository tree
        for rootCID in header.roots {
            if let rootBlock = blocks.first(where: { $0.cid.string == rootCID.string }) {
                var visited = Set<String>()
                try traverseRepositoryNode(
                    block: rootBlock,
                    path: "",
                    blocks: blocks,
                    repositoryMap: &repositoryMap,
                    visited: &visited
                )
            }
        }
        
        logMessage("Repository map built with \(repositoryMap.allPaths.count) paths")
        
        // Log some example paths for debugging
        let samplePaths = Array(repositoryMap.allPaths.prefix(10))
        for path in samplePaths {
            logMessage("Sample path: \(path)")
        }
        
        return repositoryMap
    }
    
    /// Recursively traverse repository nodes to build the path map
    private func traverseRepositoryNode(
        block: CARBlock,
        path: String,
        blocks: [CARBlock],
        repositoryMap: inout RepositoryMap,
        visited: inout Set<String>
    ) throws {
        let cidString = block.cid.string
        
        logMessage("🌳 Traversing node at path: '\(path)' CID: \(cidString.prefix(20))...")
        
        // Avoid infinite loops
        guard !visited.contains(cidString) else { 
            logMessage("➡️ Skipping already visited CID: \(cidString.prefix(20))...")
            return 
        }
        visited.insert(cidString)
        
        // Decode the block to see its structure
        guard let cborItem = try? CBOR.decode([UInt8](block.data)) else {
            logMessage("❌ Failed to decode CBOR for traversal of CID: \(cidString.prefix(20))...")
            return // Skip blocks that can't be decoded
        }
        
        let blockData = try DAGCBOR.decodeCBORItem(cborItem)
        logMessage("🔍 Block data type: \(type(of: blockData))")
        
        // Check if this is a repository node (directory-like structure)
        if let nodeDict = blockData as? [String: Any] {
            logMessage("📋 Node is dictionary with keys: \(Array(nodeDict.keys).sorted())")
            // Check for links to other blocks (CID references)
            for (key, value) in nodeDict {
                if let linkDict = value as? [String: Any],
                   let cidData = linkDict["/"] {
                    // This is a link to another block
                    let childPath = path.isEmpty ? key : "\(path)/\(key)"
                    
                    // Handle different CID formats
                    var childCID: CID?
                    if let cidBytes = cidData as? Data {
                        // For Data, convert to base64 string first or use raw bytes
                        childCID = try? CID(bytes: cidBytes)
                    } else if let cidString = cidData as? String {
                        childCID = try? CID.parse(cidString)
                    }
                    
                    // Find the referenced block
                    if let cid = childCID,
                       let childBlock = blocks.first(where: { $0.cid.string == cid.string }) {
                        
                        repositoryMap.addMapping(cid: cid, path: childPath)
                        
                        // Recursively traverse child
                        try traverseRepositoryNode(
                            block: childBlock,
                            path: childPath,
                            blocks: blocks,
                            repositoryMap: &repositoryMap,
                            visited: &visited
                        )
                    }
                } else if isAtProtocolRecord(nodeDict) {
                    // This is an actual AT Protocol record, not a directory node
                    let recordPath = path
                    repositoryMap.addMapping(cid: block.cid, path: recordPath)
                    break
                }
            }
        } else {
            // This might be a leaf record, add it with current path
            repositoryMap.addMapping(cid: block.cid, path: path)
        }
    }
    
    /// Check if a dictionary represents an AT Protocol record
    private func isAtProtocolRecord(_ dict: [String: Any]) -> Bool {
        // AT Protocol records typically have specific fields
        return dict["$type"] != nil ||
               (dict["text"] != nil && dict["createdAt"] != nil) ||
               (dict["subject"] != nil && dict["createdAt"] != nil) ||
               dict["displayName"] != nil ||
               dict["description"] != nil
    }
    
    /// Extract collection type and record key from repository path
    private func extractPathComponents(from path: String) -> (collectionType: String?, recordKey: String?) {
        let components = path.split(separator: "/").map(String.init)
        
        // AT Protocol paths are typically: collection/recordKey
        // e.g., "app.bsky.feed.post/3k2a4didkk2s6"
        if components.count >= 2 {
            let collectionType = components[components.count - 2]
            let recordKey = components[components.count - 1]
            return (collectionType, recordKey)
        } else if components.count == 1 {
            // Single component might be a collection type or record key
            let component = components[0]
            if component.contains(".") {
                // Looks like a collection type (e.g., "app.bsky.feed.post")
                return (component, nil)
            } else {
                // Looks like a record key
                return (nil, component)
            }
        }
        
        return (nil, nil)
    }
}

// MARK: - Supporting Types

struct CARStructure {
    let header: CARHeader
    let blocks: [CARBlock]
    let repositoryMap: RepositoryMap
}

struct CARHeader {
    let version: Int
    let roots: [CID]
}

struct CARBlock {
    let cid: CID
    let data: Data
    var repositoryPath: String?
    var recordKey: String?
    var collectionType: String?
}

/// Maps CIDs to their paths in the repository structure
struct RepositoryMap {
    private var cidToPath: [String: String] = [:]
    private var pathToCID: [String: CID] = [:]
    
    mutating func addMapping(cid: CID, path: String) {
        let cidString = cid.string
        cidToPath[cidString] = path
        pathToCID[path] = cid
    }
    
    func getPath(for cid: CID) -> String? {
        return cidToPath[cid.string]
    }
    
    func getCID(for path: String) -> CID? {
        return pathToCID[path]
    }
    
    var allPaths: [String] {
        return Array(pathToCID.keys)
    }
}

// MARK: - Errors

enum CARParsingError: LocalizedError {
    case invalidCARFormat(String)
    case invalidCBORData(String)
    case unsupportedRecordType(String)
    case parsingFailed(String, RepositoryRecord)
    case streamingFailed(String, RepositoryRecord)
    
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
        case .streamingFailed(let message, _):
            return "Streaming parsing failed: \(message)"
        }
    }
}
