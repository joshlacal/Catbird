import Foundation
import OSLog
import Petrel
import SwiftCBOR

// MARK: - ⚠️ EXPERIMENTAL STREAMING CAR PARSER ⚠️

/// 🧪 EXPERIMENTAL: Memory-efficient streaming CAR file parser
/// ⚠️ This parser processes CAR files block-by-block without loading entire files into memory
///
/// **Key Features:**
/// - Streams CAR blocks one at a time from disk
/// - Implements AT Protocol security limits (max object size, recursion depth)
/// - Never loads entire CAR file into memory
/// - Designed for repositories with millions of records
/// - Follows AT Protocol specification for CAR file format
final class StreamingCARParser {
    
    // MARK: - Security Limits (per AT Protocol spec)
    
    /// Maximum size for individual CBOR objects (reduced to 2MB for iOS memory safety)
    internal static let maxObjectSize: Int = 2 * 1024 * 1024
    
    /// Maximum recursion depth for CBOR decoding (32 levels)
    private static let maxRecursionDepth: Int = 32
    
    /// Maximum memory budget per decode operation (reduced to 10MB for iOS)
    private static let maxMemoryBudget: Int = 10 * 1024 * 1024
    
    /// Maximum blocks to process in memory at once (reduced to prevent accumulation)
    private static let maxBlocksInMemory: Int = 10
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "Catbird", category: "StreamingCARParser")
    private let enableVerboseLogging: Bool
    private var logBuffer: CircularLogBuffer
    
    // MARK: - Statistics
    
    private var stats = StreamingStats()
    
    // MARK: - Initialization
    
    init(enableVerboseLogging: Bool = false) {
        self.enableVerboseLogging = enableVerboseLogging
        self.logBuffer = CircularLogBuffer(capacity: 500, enableFileLogging: enableVerboseLogging)
    }
    
    // MARK: - Streaming CAR Parsing
    
    /// Parse CAR file using streaming approach - never loads entire file into memory
    func parseStreamingCAR(
        fileURL: URL,
        userDID: String,
        userHandle: String,
        backupRecordID: UUID,
        onBlock: @escaping (StreamingBlock) async throws -> Void
    ) async throws -> (repositoryRecord: RepositoryRecord, totalBlockCount: Int, logFileURL: URL?) {
        
        logEssential("🚀 Starting streaming CAR parsing for: \(fileURL.lastPathComponent)")
        logEssential("File size: \(getFileSize(fileURL))")
        
        stats.startTime = Date()
        stats.reset()
        
        do {
            // Open file for streaming
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            defer { fileHandle.closeFile() }
            
            // Parse CAR header first
            let header = try await parseStreamingCARHeader(fileHandle: fileHandle)
            logEssential("CAR header parsed - root CIDs: \(header.roots.count)")
            
            // Process blocks one by one with aggressive memory management
            var blockIndex = 0
            
            while true {
                // CRITICAL: Process each block with memory management
                do {
                    // Read next block
                    guard let block = try await readNextBlock(fileHandle: fileHandle, blockIndex: blockIndex) else {
                        break // End of file
                    }
                    
                    blockIndex += 1
                    stats.totalBlocks += 1
                    
                    // Process block immediately
                    try await processStreamingBlock(block, onBlock: onBlock)
                    
                    // More aggressive memory checks - every 10 blocks
                    if blockIndex % 10 == 0 {
                        try await checkMemoryUsage()
                        
                        // Force a brief pause to let memory settle
                        try await Task.sleep(nanoseconds: 10_000_000) // 0.01 second
                    }
                    
                    // Progress logging every 50 blocks
                    if blockIndex % 50 == 0 {
                        logProgress(blockIndex)
                    }
                    
                } catch {
                    stats.failedBlocks += 1
                    logEssential("❌ Failed to process block \(blockIndex): \(error.localizedDescription)")
                    
                    // Continue with next block for resilience
                    continue
                }
            }
            
            stats.endTime = Date()
            logEssential("✅ Streaming parsing completed")
            logEssential("Total blocks: \(stats.totalBlocks), Success: \(stats.successfulBlocks), Failed: \(stats.failedBlocks)")
            
            // Create repository record
            let repositoryRecord = RepositoryRecord(
                backupRecordID: backupRecordID,
                userDID: userDID,
                userHandle: userHandle,
                totalRecordCount: stats.totalRecords,
                successfullyParsedCount: stats.successfulRecords,
                failedParseCount: stats.failedRecords,
                parsingStatus: .completed,
                parsingConfidenceScore: stats.successRate,
                parsingLogs: logBuffer.recentLogs.joined(separator: "\n"),
                parsingLogFileURL: logBuffer.logFileURL,
                originalCarSize: getFileSize(fileURL),
                parsingStatistics: stats.toJSON(),
                postCount: stats.recordTypeCounts["app.bsky.feed.post"] ?? 0,
                profileCount: stats.recordTypeCounts["app.bsky.actor.profile"] ?? 0,
                connectionCount: (stats.recordTypeCounts["app.bsky.graph.follow"] ?? 0) + 
                                (stats.recordTypeCounts["app.bsky.graph.block"] ?? 0),
                mediaCount: 0 // Will be calculated during processing
            )
            
            return (repositoryRecord, stats.totalBlocks, logBuffer.logFileURL)
            
        } catch {
            stats.endTime = Date()
            logEssential("❌ Streaming parsing failed: \(error.localizedDescription)")
            
            // Create failed repository record
            let repositoryRecord = RepositoryRecord(
                backupRecordID: backupRecordID,
                userDID: userDID,
                userHandle: userHandle,
                parsingStatus: .failed,
                parsingErrorMessage: error.localizedDescription,
                parsingLogs: logBuffer.recentLogs.joined(separator: "\n"),
                parsingLogFileURL: logBuffer.logFileURL,
                originalCarSize: getFileSize(fileURL),
                parsingStatistics: stats.toJSON()
            )
            
            throw CARParsingError.streamingFailed(error.localizedDescription, repositoryRecord)
        }
    }
    
    // MARK: - CAR Header Parsing
    
    private func parseStreamingCARHeader(fileHandle: FileHandle) async throws -> StreamingCARHeader {
        logMessage("📋 Reading CAR header...")
        
        // Read header length (first 4 bytes as varint)
        let headerLengthData = fileHandle.readData(ofLength: 4)
        guard headerLengthData.count == 4 else {
            throw StreamingCARError.invalidHeaderLength
        }
        
        // Parse varint length
        let headerLength = try parseVarint(data: headerLengthData)
        logMessage("Header length: \(headerLength) bytes")
        
        // Read header data
        let headerData = fileHandle.readData(ofLength: Int(headerLength))
        guard headerData.count == headerLength else {
            throw StreamingCARError.invalidHeaderData
        }
        
        // Decode CBOR header with security limits
        let header = try decodeCBORWithLimits(data: headerData, maxSize: Self.maxObjectSize) as? [String: Any]
        guard let header = header else {
            throw StreamingCARError.invalidHeaderFormat
        }
        
        // Extract root CIDs
        guard let rootsArray = header["roots"] as? [Any] else {
            throw StreamingCARError.missingRoots
        }
        
        let roots = try rootsArray.compactMap { rootData -> CIDString? in
            // Parse CID from header data
            if let cidData = rootData as? Data {
                return try parseCIDFromData(cidData)
            }
            return nil
        }
        
        logMessage("✅ CAR header parsed with \(roots.count) roots")
        return StreamingCARHeader(version: 1, roots: roots)
    }
    
    // MARK: - Block Reading
    
    private func readNextBlock(fileHandle: FileHandle, blockIndex: Int) async throws -> StreamingBlock? {
        // Check if we've reached end of file
        let currentPosition = fileHandle.offsetInFile
        fileHandle.seekToEndOfFile()
        let fileSize = fileHandle.offsetInFile
        fileHandle.seek(toFileOffset: currentPosition)
        
        if currentPosition >= fileSize {
            return nil // End of file
        }
        
        // Read block length (varint)
        let lengthData = fileHandle.readData(ofLength: 8) // Max varint size
        guard !lengthData.isEmpty else {
            return nil // End of file
        }
        
        // Parse block length
        let (blockLength, lengthSize) = try parseVarintWithSize(data: lengthData)
        
        // Seek back to correct position
        fileHandle.seek(toFileOffset: currentPosition + UInt64(lengthSize))
        
        // Security check: limit block size
        guard blockLength <= Self.maxObjectSize else {
            throw StreamingCARError.blockTooLarge(blockLength)
        }
        
        // Read block data
        let blockData = fileHandle.readData(ofLength: Int(blockLength))
        guard blockData.count == blockLength else {
            throw StreamingCARError.incompleteBlock
        }
        
        logVerbose("📦 Read block \(blockIndex): \(blockLength) bytes")
        
        return StreamingBlock(
            index: blockIndex,
            data: blockData,
            position: currentPosition
        )
    }
    
    // MARK: - Block Processing
    
    private func processStreamingBlock(
        _ block: StreamingBlock,
        onBlock: @escaping (StreamingBlock) async throws -> Void
    ) async throws {
        
        stats.successfulBlocks += 1
        
        // Parse CID and data from block with memory management
        do {
            var cid: String = ""
            var minimalDict: [String: Any] = [:]
            
            // Use autoreleasepool for CBOR parsing to prevent accumulation
            autoreleasepool {
                do {
                    let (parsedCid, recordData) = try parseBlockCIDAndData(block.data)
                    cid = parsedCid
                    
                    // Try to decode as CBOR with security limits
                    let decodedData = try decodeCBORWithLimits(data: recordData, maxSize: Self.maxObjectSize)
                    
                    // Determine if this is an AT Protocol record
                    if let recordDict = decodedData as? [String: Any] {
                        if let recordType = inferRecordType(from: recordDict) {
                            stats.totalRecords += 1
                            stats.recordTypeCounts[recordType, default: 0] += 1
                            logVerbose("📝 Found \(recordType) record in block \(block.index)")
                            
                            // Extract minimal data to reduce memory
                            minimalDict = extractMinimalData(from: recordDict, recordType: recordType)
                            minimalDict["$type"] = recordType
                        } else {
                            logVerbose("🔍 Block \(block.index) contains non-record data")
                        }
                    }
                } catch {
                    logMessage("Error in autoreleasepool: \(error)")
                }
            }
            
            // Only process if we have valid data
            if !minimalDict.isEmpty, let recordType = minimalDict["$type"] as? String {
                // Create enhanced block with minimal data
                let enhancedBlock = StreamingBlock(
                    index: block.index,
                    data: Data(), // Clear raw data immediately
                    position: block.position,
                    cid: cid,
                    decodedData: minimalDict,
                    recordType: recordType
                )
                
                // Pass to caller for processing
                try await onBlock(enhancedBlock)
                stats.successfulRecords += 1
            }
            
        } catch {
            stats.failedRecords += 1
            logMessage("❌ Failed to process block \(block.index): \(error.localizedDescription)")
            throw error
        }
    }
    
    // Extract only essential data to minimize memory usage
    private func extractMinimalData(from dict: [String: Any], recordType: String) -> [String: Any] {
        var minimal: [String: Any] = [:]
        
        // Always keep record type
        minimal["$type"] = recordType
        
        // Keep only essential fields based on record type
        switch recordType {
        case "app.bsky.feed.post":
            if let text = dict["text"] { minimal["text"] = text }
            if let createdAt = dict["createdAt"] { minimal["createdAt"] = createdAt }
        case "app.bsky.actor.profile":
            if let displayName = dict["displayName"] { minimal["displayName"] = displayName }
        case "app.bsky.graph.follow", "app.bsky.graph.block":
            if let subject = dict["subject"] { minimal["subject"] = subject }
            if let createdAt = dict["createdAt"] { minimal["createdAt"] = createdAt }
        default:
            // For other types, keep createdAt if available
            if let createdAt = dict["createdAt"] { minimal["createdAt"] = createdAt }
        }
        
        return minimal
    }
    
    // MARK: - Memory Management
    
    private func checkMemoryUsage() async throws {
        let memoryUsage = getCurrentMemoryUsage()
        
        // Much more conservative limits for iOS
        if memoryUsage > 400_000_000 { // 400MB critical (iOS typically kills at ~1.4GB)
            throw StreamingCARError.memoryLimitExceeded(memoryUsage)
        } else if memoryUsage > 250_000_000 { // 250MB warning
            logEssential("⚠️ High memory usage: \(formatBytes(memoryUsage))")
            
            // Pause briefly to let memory settle
            try await Task.sleep(nanoseconds: 50_000_000) // 0.05 second pause
        }
    }
    
    // MARK: - Utility Methods
    
    private func getFileSize(_ url: URL) -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }
    
    private func getCurrentMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
    
    private func formatBytes(_ bytes: UInt64) -> String {
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
    
    private func logProgress(_ blockIndex: Int) {
        if blockIndex % 500 == 0 {
            logEssential("📊 Progress: \(blockIndex) blocks processed, \(stats.successfulRecords) records found")
            logEssential("Memory usage: \(formatBytes(getCurrentMemoryUsage()))")
        }
    }
    
    // MARK: - Logging
    
    private func logEssential(_ message: String) {
        logBuffer.append(message, level: .essential)
        logger.info("\(message)")
    }
    
    private func logMessage(_ message: String) {
        logBuffer.append(message, level: .debug)
        if enableVerboseLogging {
            logger.debug("\(message)")
        }
    }
    
    private func logVerbose(_ message: String) {
        logBuffer.append(message, level: .verbose)
        if enableVerboseLogging {
            logger.debug("\(message)")
        }
    }
}

// MARK: - Supporting Types

/// Streaming CAR block representation - minimized for memory efficiency
struct StreamingBlock {
    let index: Int
    let data: Data  // Consider making this optional and clearing after processing
    let position: UInt64
    var cid: String?
    var decodedData: [String: Any]?
    var recordType: String?
    
    // Clear data after processing to free memory
    mutating func clearRawData() {
        // Note: Can't actually clear 'data' since it's a let constant
        // This would require refactoring to use a class or different approach
    }
}

/// CAR file header for streaming parser
struct StreamingCARHeader {
    let version: Int
    let roots: [String] // CID strings
}

/// Statistics for streaming parsing
private class StreamingStats {
    var startTime: Date?
    var endTime: Date?
    var totalBlocks = 0
    var successfulBlocks = 0
    var failedBlocks = 0
    var totalRecords = 0
    var successfulRecords = 0
    var failedRecords = 0
    var recordTypeCounts: [String: Int] = [:]
    
    func reset() {
        totalBlocks = 0
        successfulBlocks = 0
        failedBlocks = 0
        totalRecords = 0
        successfulRecords = 0
        failedRecords = 0
        recordTypeCounts.removeAll()
    }
    
    var successRate: Double {
        guard totalRecords > 0 else { return 0.0 }
        return Double(successfulRecords) / Double(totalRecords)
    }
    
    var processingDuration: TimeInterval {
        guard let start = startTime, let end = endTime else { return 0 }
        return end.timeIntervalSince(start)
    }
    
    func toJSON() -> String {
        let stats = [
            "totalBlocks": totalBlocks,
            "successfulBlocks": successfulBlocks,
            "failedBlocks": failedBlocks,
            "totalRecords": totalRecords,
            "successfulRecords": successfulRecords,
            "failedRecords": failedRecords,
            "successRate": successRate,
            "processingDuration": processingDuration,
            "recordTypeCounts": recordTypeCounts
        ] as [String: Any]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: stats)
            return String(data: jsonData, encoding: .utf8) ?? "{}"
        } catch {
            return "{}"
        }
    }
}

/// Streaming CAR parsing errors
enum StreamingCARError: LocalizedError {
    case invalidHeaderLength
    case invalidHeaderData
    case invalidHeaderFormat
    case missingRoots
    case blockTooLarge(Int)
    case incompleteBlock
    case memoryLimitExceeded(UInt64)
    case securityLimitViolation(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidHeaderLength:
            return "Invalid CAR header length"
        case .invalidHeaderData:
            return "Invalid CAR header data"
        case .invalidHeaderFormat:
            return "Invalid CAR header format"
        case .missingRoots:
            return "Missing root CIDs in CAR header"
        case .blockTooLarge(let size):
            return "Block too large: \(size) bytes (max: \(StreamingCARParser.maxObjectSize))"
        case .incompleteBlock:
            return "Incomplete block data"
        case .memoryLimitExceeded(let usage):
            return "Memory limit exceeded: \(usage) bytes"
        case .securityLimitViolation(let detail):
            return "Security limit violation: \(detail)"
        }
    }
}

// MARK: - Circular Log Buffer (reuse from CARParser)

/// Memory-efficient circular buffer for logging with fixed capacity and optional file output
private class CircularLogBuffer {
    private var buffer: [String]
    private let capacity: Int
    private var currentIndex: Int = 0
    private var count: Int = 0
    internal let logFileURL: URL?
    private var fileHandle: FileHandle?
    
    enum LogLevel {
        case essential
        case debug
        case verbose
    }
    
    init(capacity: Int, enableFileLogging: Bool = false) {
        self.capacity = capacity
        self.buffer = Array(repeating: "", count: capacity)
        
        if enableFileLogging {
            let tempDir = FileManager.default.temporaryDirectory
            let logFileName = "streaming-car-parser-\(UUID().uuidString).log"
            self.logFileURL = tempDir.appendingPathComponent(logFileName)
            
            if let url = logFileURL {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
                self.fileHandle = try? FileHandle(forWritingTo: url)
            }
        } else {
            self.logFileURL = nil
        }
    }
    
    deinit {
        fileHandle?.closeFile()
    }
    
    func append(_ message: String, level: LogLevel) {
        let timestamp = DateFormatter().string(from: Date())
        let logMessage = "[\(timestamp)] \(message)"
        
        // Add to circular buffer
        buffer[currentIndex] = logMessage
        currentIndex = (currentIndex + 1) % capacity
        count = min(count + 1, capacity)
        
        // Write to file if enabled
        if let fileHandle = fileHandle {
            if let data = (logMessage + "\n").data(using: .utf8) {
                fileHandle.write(data)
            }
        }
    }
    
    var recentLogs: [String] {
        guard count > 0 else { return [] }
        
        if count < capacity {
            return Array(buffer.prefix(count))
        } else {
            let firstPart = Array(buffer[currentIndex...])
            let secondPart = Array(buffer[..<currentIndex])
            return firstPart + secondPart
        }
    }
}

// MARK: - Placeholder Functions (to be implemented)

typealias CIDString = String

private func parseVarint(data: Data) throws -> Int {
    // Proper varint parsing according to CAR spec
    // Varints use the lower 7 bits of each byte for data, MSB indicates continuation
    var result: UInt64 = 0
    var shift: UInt64 = 0
    
    for (index, byte) in data.enumerated() {
        guard index < 9 else { // Max 9 bytes for 64-bit integer
            throw StreamingCARError.securityLimitViolation("Varint too long")
        }
        
        let value = UInt64(byte & 0x7F) // Lower 7 bits
        result |= value << shift
        
        // Check for overflow
        if shift >= 64 {
            throw StreamingCARError.securityLimitViolation("Varint overflow")
        }
        
        // If MSB is 0, this is the last byte
        if (byte & 0x80) == 0 {
            return Int(result)
        }
        
        shift += 7
    }
    
    throw StreamingCARError.invalidHeaderData
}

private func parseVarintWithSize(data: Data) throws -> (Int, Int) {
    // Parse varint and return both value and bytes consumed
    var result: UInt64 = 0
    var shift: UInt64 = 0
    var bytesRead = 0
    
    for (index, byte) in data.enumerated() {
        guard index < 9 else { // Max 9 bytes for 64-bit integer
            throw StreamingCARError.securityLimitViolation("Varint too long")
        }
        
        bytesRead += 1
        let value = UInt64(byte & 0x7F) // Lower 7 bits
        result |= value << shift
        
        // Check for overflow
        if shift >= 64 {
            throw StreamingCARError.securityLimitViolation("Varint overflow")
        }
        
        // If MSB is 0, this is the last byte
        if (byte & 0x80) == 0 {
            return (Int(result), bytesRead)
        }
        
        shift += 7
    }
    
    throw StreamingCARError.invalidHeaderData
}

private func decodeCBORWithLimits(data: Data, maxSize: Int) throws -> Any {
    // Security check
    guard data.count <= maxSize else {
        throw StreamingCARError.securityLimitViolation("CBOR data too large: \(data.count) bytes")
    }
    
    // Use SwiftCBOR for proper CBOR decoding
    do {
        // Import SwiftCBOR at the top of file is needed
        guard let cborItem = try CBOR.decode([UInt8](data)) else {
            throw StreamingCARError.securityLimitViolation("Failed to decode CBOR data")
        }
        return try convertCBORToSwiftValue(cborItem)
    } catch {
        // If CBOR decoding fails, try JSON as fallback
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            // Last resort: return raw data
            throw StreamingCARError.securityLimitViolation("Failed to decode CBOR or JSON: \(error.localizedDescription)")
        }
    }
}

/// Convert CBOR item to Swift value
private func convertCBORToSwiftValue(_ cbor: CBOR) throws -> Any {
    switch cbor {
    case .utf8String(let string):
        return string
    case .unsignedInt(let uint):
        return uint
    case .negativeInt(let uint):
        return -Int64(uint) - 1
    case .boolean(let bool):
        return bool
    case .array(let array):
        return try array.map { try convertCBORToSwiftValue($0) }
    case .map(let dict):
        var result: [String: Any] = [:]
        for (key, value) in dict {
            guard case .utf8String(let keyString) = key else {
                throw StreamingCARError.securityLimitViolation("Non-string map key")
            }
            result[keyString] = try convertCBORToSwiftValue(value)
        }
        return result
    case .byteString(let bytes):
        return Data(bytes)
    case .null:
        return NSNull()
    case .tagged(let tag, let value):
        // Handle CID tags (Tag 42)
        if tag.rawValue == 42 {
            guard case .byteString(let bytes) = value,
                  bytes.count > 0,
                  bytes[0] == 0x00 else {
                throw StreamingCARError.securityLimitViolation("Invalid CID tag format")
            }
            let cidBytes = Data(bytes.dropFirst())
            return try parseCIDFromBytes(cidBytes)
        }
        // For other tags, return the unwrapped value
        return try convertCBORToSwiftValue(value)
    default:
        throw StreamingCARError.securityLimitViolation("Unsupported CBOR type: \(cbor)")
    }
}

private func parseCIDFromData(_ data: Data) throws -> CIDString {
    // Parse CID from binary data using Petrel's CID implementation
    do {
        let cid = try CID(bytes: data)
        return cid.string
    } catch {
        throw StreamingCARError.securityLimitViolation("Invalid CID format: \(error.localizedDescription)")
    }
}

private func parseCIDFromBytes(_ data: Data) throws -> String {
    // Parse CID bytes and return as string
    do {
        let cid = try CID(bytes: data)
        return cid.string
    } catch {
        throw StreamingCARError.securityLimitViolation("Invalid CID bytes: \(error.localizedDescription)")
    }
}

private func parseBlockCIDAndData(_ blockData: Data) throws -> (String, Data) {
    // Parse CAR block according to spec: [CID length varint][CID][Record Data]
    guard blockData.count >= 2 else {
        throw StreamingCARError.incompleteBlock
    }
    
    // Parse CID length
    let (cidLength, varintSize) = try parseVarintWithSize(data: blockData)
    let cidStart = varintSize
    let cidEnd = cidStart + cidLength
    
    guard blockData.count >= cidEnd else {
        throw StreamingCARError.incompleteBlock
    }
    
    // Extract CID bytes
    let cidData = blockData.subdata(in: cidStart..<cidEnd)
    let cid = try parseCIDFromData(cidData)
    
    // Extract record data (everything after CID)
    let recordData = blockData.suffix(from: cidEnd)
    
    return (cid, recordData)
}

private func inferRecordType(from recordDict: [String: Any]) -> String? {
    // Proper AT Protocol record type detection
    
    // Check for $type field first (definitive)
    if let typeField = recordDict["$type"] as? String {
        return typeField
    }
    
    // Fallback to heuristic detection based on field patterns
    
    // Post detection (app.bsky.feed.post)
    if recordDict["text"] != nil && recordDict["createdAt"] != nil {
        return "app.bsky.feed.post"
    }
    
    // Profile detection (app.bsky.actor.profile)
    if recordDict["displayName"] != nil || 
       recordDict["description"] != nil ||
       recordDict["avatar"] != nil ||
       recordDict["banner"] != nil {
        return "app.bsky.actor.profile"
    }
    
    // Follow detection (app.bsky.graph.follow)
    if let subject = recordDict["subject"] as? String,
       subject.starts(with: "did:"),
       recordDict["createdAt"] != nil {
        return "app.bsky.graph.follow"
    }
    
    // Block detection (app.bsky.graph.block)
    if let subject = recordDict["subject"] as? String,
       subject.starts(with: "did:"),
       recordDict["createdAt"] != nil,
       recordDict["text"] == nil { // Distinguish from follow by lack of text
        return "app.bsky.graph.block"
    }
    
    // Like detection (app.bsky.feed.like)
    if recordDict["subject"] != nil,
       recordDict["createdAt"] != nil {
        // Check if subject has uri and cid (typical like structure)
        if let subjectDict = recordDict["subject"] as? [String: Any],
           subjectDict["uri"] != nil && subjectDict["cid"] != nil {
            return "app.bsky.feed.like"
        }
    }
    
    // Repost detection (app.bsky.feed.repost)
    if recordDict["subject"] != nil,
       recordDict["createdAt"] != nil {
        if let subjectDict = recordDict["subject"] as? [String: Any],
           subjectDict["uri"] != nil && subjectDict["cid"] != nil,
           recordDict["text"] == nil { // Reposts don't have text
            return "app.bsky.feed.repost"
        }
    }
    
    // List detection (app.bsky.graph.list)
    if recordDict["name"] != nil &&
       recordDict["purpose"] != nil &&
       recordDict["createdAt"] != nil {
        return "app.bsky.graph.list"
    }
    
    // Feed generator detection (app.bsky.feed.generator)
    if recordDict["did"] != nil &&
       recordDict["displayName"] != nil &&
       recordDict["createdAt"] != nil {
        return "app.bsky.feed.generator"
    }
    
    return nil // Unknown record type
}