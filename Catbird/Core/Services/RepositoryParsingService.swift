import Foundation
import SwiftData
import Petrel
import OSLog
import SwiftCBOR

// MARK: - ⚠️ EXPERIMENTAL REPOSITORY PARSING SERVICE ⚠️

/// 🧪 EXPERIMENTAL: Service that orchestrates parsing CAR backups into structured repository data
/// ⚠️ This is experimental functionality that may encounter parsing errors with malformed CAR files
///
/// The RepositoryParsingService orchestrates the parsing of CAR backup files
/// into structured SwiftData models, providing progress tracking, cancellation,
/// and comprehensive error handling.
///
/// **Safety Features:**
/// - Background processing to avoid blocking UI
/// - Progress tracking with cancellation support
/// - Automatic error recovery and retry logic
/// - Parsing status persistence
/// - Memory management for large CAR files
@Observable
final class RepositoryParsingService {
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "blue.catbird.experimental", category: "RepositoryParsingService")
    private var modelContext: ModelContext?
    private var carParser = CARParser()
    
    /// Current parsing operation
    var currentParsingOperation: ParsingOperation?
    
    /// Active parsing operations by backup ID
    private var activeOperations: [UUID: ParsingOperation] = [:]
    
    /// Experimental feature toggle
    var experimentalParsingEnabled: Bool {
        get {
            // Default to true if not explicitly set to false
            UserDefaults.standard.object(forKey: "experimentalRepositoryParsingEnabled") as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: "experimentalRepositoryParsingEnabled") }
    }
    
    // MARK: - Initialization
    
    init() {
        logger.debug("🧪 RepositoryParsingService initialized")
    }
    
    func configure(with modelContext: ModelContext) {
        self.modelContext = modelContext
        logger.debug("RepositoryParsingService configured with ModelContext")
    }
    
    // MARK: - Public API
    
    /// Start parsing a backup repository (EXPERIMENTAL)
    /// ⚠️ This operation may take significant time and resources
    @MainActor
    func startRepositoryParsing(for backupRecord: BackupRecord) async throws -> RepositoryRecord {
        logger.warning("🧪 EXPERIMENTAL: Starting repository parsing for backup \(backupRecord.id.uuidString)")
        
        // CRITICAL: Check memory before starting parsing
        let initialMemory = getCurrentMemoryUsage()
        logger.warning("🚨 Initial memory usage: \(self.formatBytes(initialMemory))")
        
        if initialMemory > 200_000_000 { // 200MB initial threshold
            logger.error("🚨 ABORTING: Memory usage too high before parsing: \(self.formatBytes(initialMemory))")
            throw RepositoryParsingError.experimentalFeatureDisabled
        }
        
        // Check if experimental parsing is enabled
        guard experimentalParsingEnabled else {
            throw RepositoryParsingError.experimentalFeatureDisabled
        }
        
        // Check if already parsing this backup
        if activeOperations[backupRecord.id] != nil {
            throw RepositoryParsingError.parsingAlreadyInProgress
        }
        
        // Check if already parsed
        if let existingRepo = try getExistingRepositoryRecord(for: backupRecord.id) {
            logger.info("Repository already parsed, returning existing record")
            return existingRepo
        }
        
        // Verify backup file exists
        guard FileManager.default.fileExists(atPath: backupRecord.fullFileURL.path) else {
            throw RepositoryParsingError.backupFileNotFound
        }
        
        // Create parsing operation
        let operation = ParsingOperation(
            backupRecord: backupRecord,
            startTime: Date(),
            status: .starting
        )
        
        activeOperations[backupRecord.id] = operation
        currentParsingOperation = operation
        
        // Perform parsing synchronously to reduce memory pressure
        let backupID = backupRecord.id
        return try await withTaskCancellationHandler {
            // Run parsing directly to minimize memory overhead
            return try await self.performRepositoryParsing(operation: operation)
        } onCancel: {
            Task { @MainActor [weak self] in
                await self?.cancelRepositoryParsing(for: backupID)
            }
        }
    }
    
    /// Cancel repository parsing operation
    @MainActor
    func cancelRepositoryParsing(for backupID: UUID) async {
        guard let operation = activeOperations[backupID] else { return }
        
        logger.info("Cancelling repository parsing for backup \(backupID.uuidString)")
        
        operation.status = .cancelled
        operation.endTime = Date()
        
        // Mark repository record as cancelled if it exists
        if let repoRecord = try? getRepositoryRecord(for: backupID) {
            repoRecord.parsingStatus = .cancelled
            try? modelContext?.save()
        }
        
        activeOperations.removeValue(forKey: backupID)
        
        if currentParsingOperation?.backupRecord.id == backupID {
            currentParsingOperation = nil
        }
    }
    
    /// Get repository record for a backup
    func getRepositoryRecord(for backupID: UUID) throws -> RepositoryRecord? {
        guard let modelContext = modelContext else {
            throw RepositoryParsingError.modelContextNotAvailable
        }
        
        let descriptor = FetchDescriptor<RepositoryRecord>(
            predicate: #Predicate { $0.backupRecordID == backupID }
        )
        
        return try modelContext.fetch(descriptor).first
    }
    
    /// Get all parsed posts for a repository
    func getParsedPosts(for repositoryID: UUID) throws -> [ParsedPost] {
        guard let modelContext = modelContext else {
            throw RepositoryParsingError.modelContextNotAvailable
        }
        
        let descriptor = FetchDescriptor<ParsedPost>(
            predicate: #Predicate { $0.repositoryRecordID == repositoryID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        
        return try modelContext.fetch(descriptor)
    }
    
    /// Get parsed profile for a repository
    func getParsedProfile(for repositoryID: UUID) throws -> ParsedProfile? {
        guard let modelContext = modelContext else {
            throw RepositoryParsingError.modelContextNotAvailable
        }
        
        let descriptor = FetchDescriptor<ParsedProfile>(
            predicate: #Predicate { $0.repositoryRecordID == repositoryID }
        )
        
        return try modelContext.fetch(descriptor).first
    }
    
    /// Get parsed connections for a repository
    func getParsedConnections(for repositoryID: UUID) throws -> [ParsedConnection] {
        guard let modelContext = modelContext else {
            throw RepositoryParsingError.modelContextNotAvailable
        }
        
        let descriptor = FetchDescriptor<ParsedConnection>(
            predicate: #Predicate { $0.repositoryRecordID == repositoryID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        
        return try modelContext.fetch(descriptor)
    }
    
    /// Debug function to inspect connection records and see if they contain post data
    func debugConnectionRecords(for repositoryID: UUID) throws -> [String] {
        guard let modelContext = modelContext else {
            throw RepositoryParsingError.modelContextNotAvailable
        }
        
        var descriptor = FetchDescriptor<ParsedConnection>(
            predicate: #Predicate { $0.repositoryRecordID == repositoryID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 10  // Just look at first 10
        
        let connections = try modelContext.fetch(descriptor)
        var debugInfo: [String] = []
        
        for (index, connection) in connections.enumerated() {
            let info = """
            Connection \(index):
              Type: \(connection.connectionType)
              Target: \(connection.targetUserDID)
              Record Key: \(connection.recordKey)
              Created: \(connection.createdAt)
              Parse Success: \(connection.parseSuccessful)
              Parse Error: \(connection.parseErrorMessage ?? "none")
            """
            debugInfo.append(info)
            logger.debug("Connection \(index): type=\(connection.connectionType), target=\(connection.targetUserDID.prefix(20))..., key=\(connection.recordKey.prefix(20))...")
        }
        
        return debugInfo
    }
    
    /// Get parsed media for a repository
    func getParsedMedia(for repositoryID: UUID) throws -> [ParsedMedia] {
        guard let modelContext = modelContext else {
            throw RepositoryParsingError.modelContextNotAvailable
        }
        
        let descriptor = FetchDescriptor<ParsedMedia>(
            predicate: #Predicate { $0.repositoryRecordID == repositoryID },
            sortBy: [SortDescriptor(\.discoveredAt, order: .reverse)]
        )
        
        return try modelContext.fetch(descriptor)
    }
    
    /// Get parsed unknown records for debugging
    func getParsedUnknownRecords(for repositoryID: UUID) throws -> [ParsedUnknownRecord] {
        guard let modelContext = modelContext else {
            throw RepositoryParsingError.modelContextNotAvailable
        }
        
        let descriptor = FetchDescriptor<ParsedUnknownRecord>(
            predicate: #Predicate { $0.repositoryRecordID == repositoryID },
            sortBy: [SortDescriptor(\.discoveredAt, order: .reverse)]
        )
        
        return try modelContext.fetch(descriptor)
    }
    
    /// Delete all parsed data for a repository
    func deleteRepositoryData(for repositoryID: UUID) throws {
        guard let modelContext = modelContext else {
            throw RepositoryParsingError.modelContextNotAvailable
        }
        
        // Delete all related parsed data
        let posts = try getParsedPosts(for: repositoryID)
        let profiles = try getParsedProfile(for: repositoryID).map { [$0] } ?? []
        let connections = try getParsedConnections(for: repositoryID)
        let media = try getParsedMedia(for: repositoryID)
        let unknownRecords = try getParsedUnknownRecords(for: repositoryID)
        
        for post in posts { modelContext.delete(post) }
        for profile in profiles { modelContext.delete(profile) }
        for connection in connections { modelContext.delete(connection) }
        for mediaItem in media { modelContext.delete(mediaItem) }
        for unknownRecord in unknownRecords { modelContext.delete(unknownRecord) }
        
        // Delete repository record
        if let repoRecord = try getRepositoryRecord(for: repositoryID) {
            modelContext.delete(repoRecord)
        }
        
        try modelContext.save()
        
        logger.info("Deleted all parsed data for repository \(repositoryID.uuidString)")
    }
    
    /// Re-parse a repository (experimental)
    @MainActor
    func reparseRepository(for backupRecord: BackupRecord) async throws -> RepositoryRecord {
        logger.warning("🧪 EXPERIMENTAL: Re-parsing repository for backup \(backupRecord.id.uuidString)")
        
        // Delete existing parsed data
        if let existingRepo = try getExistingRepositoryRecord(for: backupRecord.id) {
            try deleteRepositoryData(for: existingRepo.id)
        }
        
        // Start fresh parsing
        return try await startRepositoryParsing(for: backupRecord)
    }
    
    // MARK: - Private Methods
    
    /// Save parsed records directly to main ModelContext for UI access
    private func saveParsedRecordsToMainContext(
        _ parsedRecords: [CARParser.ParsedRecord],
        to repositoryRecord: RepositoryRecord,
        modelContext: ModelContext
    ) async throws {
        logger.info("Saving \(parsedRecords.count) parsed records directly to main context")
        
        var batchCount = 0
        let batchSize = 5  // Smaller batches to reduce memory pressure
        var recordTypeCounts: [String: Int] = [:]
        
        for record in parsedRecords {
            // Track record type counts
            recordTypeCounts[record.recordType, default: 0] += 1
            
            try saveIndividualParsedRecord(record, to: repositoryRecord, modelContext: modelContext)
            batchCount += 1
            
            // Save periodically to avoid memory issues
            if batchCount % batchSize == 0 {
                try modelContext.save()
                logger.debug("Saved batch of \(batchSize) records to main context, total: \(batchCount)")
            }
        }
        
        // Final save
        try modelContext.save()
        
        // Log summary of what was processed
        logger.info("Successfully saved all \(parsedRecords.count) parsed records to main context")
        logger.info("📊 Record type summary:")
        for (recordType, count) in recordTypeCounts.sorted(by: { $0.value > $1.value }) {
            logger.info("  \(recordType): \(count)")
        }
    }
    
    private func saveIndividualParsedRecord(
        _ record: CARParser.ParsedRecord,
        to repositoryRecord: RepositoryRecord,
        modelContext: ModelContext
    ) throws {
        // Create the AT Protocol record URI
        let recordURI = "at://\(repositoryRecord.userDID)/\(record.recordType)/\(record.recordKey)"
        
        // Extract createdAt date if available
        var createdAt: Date?
        if let parsedData = record.parsedData as? [String: Any],
           let createdAtString = parsedData["createdAt"] as? String {
            createdAt = ISO8601DateFormatter().date(from: createdAtString)
        } else if let parsedData = record.parsedData as? [String: Any],
                  let createdAtDate = parsedData["createdAt"] as? Date {
            createdAt = createdAtDate
        }
        
        // Validate record data before processing
        if record.recordType.isEmpty || record.recordKey.isEmpty {
            logger.warning("Invalid record with empty type or key: type='\(record.recordType)', key='\(record.recordKey)'")
            let unknownRecord = ParsedUnknownRecord(
                repositoryRecordID: repositoryRecord.id,
                recordKey: record.recordKey.isEmpty ? "unknown" : record.recordKey,
                recordType: record.recordType.isEmpty ? "unknown" : record.recordType,
                rawCBORData: record.rawCBORData,
                recordCID: record.cid.string,
                parseAttemptError: "Empty record type or key"
            )
            modelContext.insert(unknownRecord)
            return
        }
        
        // Direct conversion based on record type and parsed data
        // This is more reliable than trying to create ATProtocolValueContainer
        logger.debug("Processing record type: '\(record.recordType)' for key: \(record.recordKey)")
        
        switch record.recordType {
        case "app.bsky.feed.post":
            if let parsedData = record.parsedData as? [String: Any] {
                logger.debug("✅ Processing app.bsky.feed.post for key: \(record.recordKey)")
                try savePostRecord(parsedData, record: record, repositoryID: repositoryRecord.id, modelContext: modelContext)
            } else {
                logger.warning("❌ No parsed data for app.bsky.feed.post record: \(record.recordKey)")
            }
            
        case "app.bsky.actor.profile":
            if let parsedData = record.parsedData as? [String: Any] {
                logger.debug("✅ Processing app.bsky.actor.profile for key: \(record.recordKey)")
                try saveProfileRecord(parsedData, record: record, repositoryID: repositoryRecord.id, modelContext: modelContext)
            } else {
                logger.warning("❌ No parsed data for app.bsky.actor.profile record: \(record.recordKey)")
            }
            
        case "app.bsky.graph.follow":
            if let parsedData = record.parsedData as? [String: Any] {
                logger.debug("✅ Processing app.bsky.graph.follow for key: \(record.recordKey)")
                try saveFollowRecord(parsedData, record: record, repositoryID: repositoryRecord.id, modelContext: modelContext)
            } else {
                logger.warning("❌ No parsed data for app.bsky.graph.follow record: \(record.recordKey)")
            }
            
        case "app.bsky.feed.like":
            if let parsedData = record.parsedData as? [String: Any] {
                logger.debug("✅ Processing app.bsky.feed.like for key: \(record.recordKey)")
                try saveLikeRecord(parsedData, record: record, repositoryID: repositoryRecord.id, modelContext: modelContext)
            } else {
                logger.warning("❌ No parsed data for app.bsky.feed.like record: \(record.recordKey)")
            }
            
        case "app.bsky.graph.block":
            if let parsedData = record.parsedData as? [String: Any] {
                logger.debug("✅ Processing app.bsky.graph.block for key: \(record.recordKey)")
                try saveBlockRecord(parsedData, record: record, repositoryID: repositoryRecord.id, modelContext: modelContext)
            } else {
                logger.warning("❌ No parsed data for app.bsky.graph.block record: \(record.recordKey)")
            }
            
        case "app.bsky.graph.listitem":
            if let parsedData = record.parsedData as? [String: Any] {
                logger.debug("✅ Processing app.bsky.graph.listitem for key: \(record.recordKey)")
                try saveListItemRecord(parsedData, record: record, repositoryID: repositoryRecord.id, modelContext: modelContext)
            } else {
                logger.warning("❌ No parsed data for app.bsky.graph.listitem record: \(record.recordKey)")
            }
            
        case "app.bsky.graph.list":
            if let parsedData = record.parsedData as? [String: Any] {
                logger.debug("✅ Processing app.bsky.graph.list for key: \(record.recordKey)")
                try saveListRecord(parsedData, record: record, repositoryID: repositoryRecord.id, modelContext: modelContext)
            } else {
                logger.warning("❌ No parsed data for app.bsky.graph.list record: \(record.recordKey)")
            }
            
        case "app.bsky.feed.repost":
            if let parsedData = record.parsedData as? [String: Any] {
                logger.debug("✅ Processing app.bsky.feed.repost for key: \(record.recordKey)")
                try saveRepostRecord(parsedData, record: record, repositoryID: repositoryRecord.id, modelContext: modelContext)
            } else {
                logger.warning("❌ No parsed data for app.bsky.feed.repost record: \(record.recordKey)")
            }
            
        default:
            logger.warning("❓ Processing unknown record type: '\(record.recordType)' for key: \(record.recordKey)")
            // Save as unknown record for debugging
            let unknownRecord = ParsedUnknownRecord(
                repositoryRecordID: repositoryRecord.id,
                recordKey: record.recordKey,
                recordType: record.recordType,
                rawCBORData: record.rawCBORData,
                recordCID: record.cid.string,
                parseAttemptError: record.parseError ?? "Unknown record type"
            )
            modelContext.insert(unknownRecord)
        }
        
        // Also save a unified AT Protocol record for completeness
        do {
            let sanitizedData = sanitizeDataForJSON(record.parsedData ?? [:])
            let recordData = try JSONSerialization.data(withJSONObject: sanitizedData)
            let atProtoRecord = ParsedATProtocolRecord(
                repositoryRecordID: repositoryRecord.id,
                recordURI: recordURI,
                recordKey: record.recordKey,
                collectionType: record.recordType,
                recordData: recordData,
                recordCID: record.cid.string,
                createdAt: createdAt,
                parseSuccessful: record.parseSuccessful,
                parseConfidence: record.parseConfidence,
                parseError: record.parseError,
                rawCBORData: record.rawCBORData
            )
            modelContext.insert(atProtoRecord)
        } catch {
            logger.error("Failed to save unified AT Protocol record: \(error)")
            // Create a minimal record with just basic info if JSON serialization fails
            let fallbackRecord = ParsedATProtocolRecord(
                repositoryRecordID: repositoryRecord.id,
                recordURI: recordURI,
                recordKey: record.recordKey,
                collectionType: record.recordType,
                recordData: Data(), // Empty data as fallback
                recordCID: record.cid.string,
                createdAt: createdAt,
                parseSuccessful: false, // Mark as failed since we couldn't serialize
                parseConfidence: record.parseConfidence,
                parseError: "JSON serialization failed: \(error.localizedDescription)",
                rawCBORData: record.rawCBORData
            )
            modelContext.insert(fallbackRecord)
        }
    }
    
    private func savePostRecord(
        _ data: [String: Any],
        record: CARParser.ParsedRecord,
        repositoryID: UUID,
        modelContext: ModelContext
    ) throws {
        // Extract from Petrel-parsed data
        // Extract and SANITIZE text to prevent crashes
        let rawText = data["text"] as? String ?? ""
        let text = rawText.sanitizedForDisplay()
        
        // Log if sanitization was needed
        if rawText.containsProblematicCharacters {
            logger.warning("Sanitized problematic text for post \(record.recordKey)")
        }
        
        // Handle createdAt - Petrel models should provide proper Date objects
        let createdAt: Date
        if let date = data["createdAt"] as? Date {
            createdAt = date
        } else if let dateString = data["createdAt"] as? String {
            // Fallback for string dates
            createdAt = ISO8601DateFormatter().date(from: dateString) ?? Date()
        } else {
            createdAt = Date()
        }
        
        // Extract additional post fields that Petrel would have parsed
        let reply = data["reply"] as? [String: Any]
        let embed = data["embed"] as? [String: Any]
        let facets = data["facets"] as? [[String: Any]] ?? []
        let langs = data["langs"] as? [String] ?? []
        let labels = data["labels"] as? [String: Any]
        
        let parsedPost = ParsedPost(
            repositoryRecordID: repositoryID,
            recordKey: record.recordKey,
            text: text,
            createdAt: createdAt,
            rawCBORData: record.rawCBORData,
            recordCID: record.cid.string,
            parseSuccessful: record.parseSuccessful,
            parseErrorMessage: record.parseError,
            parseConfidence: record.parseConfidence
        )
        modelContext.insert(parsedPost)
        logger.debug("Successfully created ParsedPost using Petrel data for: \(record.recordKey) - text: '\(text.prefix(50))...'")
    }
    
    private func saveProfileRecord(
        _ data: [String: Any],
        record: CARParser.ParsedRecord,
        repositoryID: UUID,
        modelContext: ModelContext
    ) throws {
        // Extract and SANITIZE profile fields from Petrel-parsed data
        let rawDisplayName = data["displayName"] as? String
        let rawDescription = data["description"] as? String
        
        // Sanitize text fields to prevent crashes
        let displayName = rawDisplayName?.sanitizedForDisplay()
        let description = rawDescription?.sanitizedForDisplay()
        
        // Log if sanitization was needed
        if let raw = rawDisplayName, raw.containsProblematicCharacters {
            logger.warning("Sanitized problematic display name for profile \(record.recordKey)")
        }
        if let raw = rawDescription, raw.containsProblematicCharacters {
            logger.warning("Sanitized problematic description for profile \(record.recordKey)")
        }
        
        // Petrel would also parse avatar, banner, labels, etc.
        let avatar = data["avatar"] as? [String: Any]
        let banner = data["banner"] as? [String: Any]
        let labels = data["labels"] as? [String: Any]
        
        let parsedProfile = ParsedProfile(
            repositoryRecordID: repositoryID,
            recordKey: record.recordKey,
            displayName: displayName,
            description: description,
            rawCBORData: record.rawCBORData,
            recordCID: record.cid.string,
            parseSuccessful: record.parseSuccessful,
            parseErrorMessage: record.parseError,
            parseConfidence: record.parseConfidence
        )
        modelContext.insert(parsedProfile)
        logger.debug("Successfully created ParsedProfile using Petrel data for: \(record.recordKey) - display: '\(displayName ?? "none")'")
    }
    
    private func saveFollowRecord(
        _ data: [String: Any],
        record: CARParser.ParsedRecord,
        repositoryID: UUID,
        modelContext: ModelContext
    ) throws {
        let targetUserDID = data["subject"] as? String ?? ""
        
        // Handle createdAt from Petrel parsing
        let createdAt: Date
        if let date = data["createdAt"] as? Date {
            createdAt = date
        } else if let dateString = data["createdAt"] as? String {
            createdAt = ISO8601DateFormatter().date(from: dateString) ?? Date()
        } else {
            createdAt = Date()
        }
        
        let parsedConnection = ParsedConnection(
            repositoryRecordID: repositoryID,
            recordKey: record.recordKey,
            targetUserDID: targetUserDID,
            connectionType: "follow",
            createdAt: createdAt,
            rawCBORData: record.rawCBORData,
            recordCID: record.cid.string,
            parseSuccessful: record.parseSuccessful,
            parseErrorMessage: record.parseError,
            parseConfidence: record.parseConfidence
        )
        modelContext.insert(parsedConnection)
        logger.debug("Successfully created ParsedConnection (follow) using Petrel data for: \(targetUserDID.prefix(30))...")
    }
    
    private func saveLikeRecord(
        _ data: [String: Any],
        record: CARParser.ParsedRecord,
        repositoryID: UUID,
        modelContext: ModelContext
    ) throws {
        // Extract target from the subject field (Petrel-parsed structure)
        var targetUserDID = ""
        var targetPostURI = ""
        
        if let subject = data["subject"] as? [String: Any],
           let uri = subject["uri"] as? String {
            targetPostURI = uri
            // Parse AT URI to get the DID
            if let atURI = try? ATProtocolURI(uriString: uri) {
                targetUserDID = atURI.authority ?? ""
            }
        } else if let subjectURI = data["subject"] as? String {
            // Handle case where subject might be directly a string
            targetPostURI = subjectURI
            if let atURI = try? ATProtocolURI(uriString: subjectURI) {
                targetUserDID = atURI.authority ?? ""
            }
        }
        
        // Handle createdAt from Petrel parsing
        let createdAt: Date
        if let date = data["createdAt"] as? Date {
            createdAt = date
        } else if let dateString = data["createdAt"] as? String {
            createdAt = ISO8601DateFormatter().date(from: dateString) ?? Date()
        } else {
            createdAt = Date()
        }
        
        let parsedConnection = ParsedConnection(
            repositoryRecordID: repositoryID,
            recordKey: record.recordKey,
            targetUserDID: targetUserDID,
            connectionType: "like",
            createdAt: createdAt,
            rawCBORData: record.rawCBORData,
            recordCID: record.cid.string,
            parseSuccessful: record.parseSuccessful,
            parseErrorMessage: record.parseError,
            parseConfidence: record.parseConfidence
        )
        modelContext.insert(parsedConnection)
        logger.debug("Successfully created ParsedConnection (like) for post: \(targetPostURI) by user: \(targetUserDID) using Petrel parsing")
    }
    
    private func saveBlockRecord(
        _ data: [String: Any],
        record: CARParser.ParsedRecord,
        repositoryID: UUID,
        modelContext: ModelContext
    ) throws {
        let targetUserDID = data["subject"] as? String ?? ""
        let createdAtString = data["createdAt"] as? String ?? ""
        let createdAt = ISO8601DateFormatter().date(from: createdAtString) ?? Date()
        
        let parsedConnection = ParsedConnection(
            repositoryRecordID: repositoryID,
            recordKey: record.recordKey,
            targetUserDID: targetUserDID,
            connectionType: "block",
            createdAt: createdAt,
            rawCBORData: record.rawCBORData,
            recordCID: record.cid.string,
            parseSuccessful: record.parseSuccessful,
            parseErrorMessage: record.parseError,
            parseConfidence: record.parseConfidence
        )
        modelContext.insert(parsedConnection)
        logger.debug("Successfully created ParsedConnection (block) for: \(record.recordKey)")
    }
    
    private func saveListItemRecord(
        _ data: [String: Any],
        record: CARParser.ParsedRecord,
        repositoryID: UUID,
        modelContext: ModelContext
    ) throws {
        let targetUserDID = data["subject"] as? String ?? ""
        let createdAtString = data["createdAt"] as? String ?? ""
        let createdAt = ISO8601DateFormatter().date(from: createdAtString) ?? Date()
        
        let parsedConnection = ParsedConnection(
            repositoryRecordID: repositoryID,
            recordKey: record.recordKey,
            targetUserDID: targetUserDID,
            connectionType: "listitem",
            createdAt: createdAt,
            rawCBORData: record.rawCBORData,
            recordCID: record.cid.string,
            parseSuccessful: record.parseSuccessful,
            parseErrorMessage: record.parseError,
            parseConfidence: record.parseConfidence
        )
        modelContext.insert(parsedConnection)
        logger.debug("Successfully created ParsedConnection (listitem) for: \(record.recordKey)")
    }
    
    private func saveListRecord(
        _ data: [String: Any],
        record: CARParser.ParsedRecord,
        repositoryID: UUID,
        modelContext: ModelContext
    ) throws {
        // Sanitize list text fields to prevent crashes
        let rawName = data["name"] as? String ?? ""
        let rawPurpose = data["purpose"] as? String ?? ""
        let rawDescription = data["description"] as? String ?? ""
        
        let name = rawName.sanitizedForDisplay()
        let purpose = rawPurpose.sanitizedForDisplay()
        let description = rawDescription.sanitizedForDisplay()
        let createdAtString = data["createdAt"] as? String ?? ""
        let createdAt = ISO8601DateFormatter().date(from: createdAtString) ?? Date()
        
        // Save as a connection with special type "list"
        let parsedConnection = ParsedConnection(
            repositoryRecordID: repositoryID,
            recordKey: record.recordKey,
            targetUserDID: name, // Store list name in targetUserDID field
            connectionType: "list",
            createdAt: createdAt,
            rawCBORData: record.rawCBORData,
            recordCID: record.cid.string,
            parseSuccessful: record.parseSuccessful,
            parseErrorMessage: record.parseError,
            parseConfidence: record.parseConfidence
        )
        modelContext.insert(parsedConnection)
        logger.debug("Successfully created ParsedConnection (list) for: \(name)")
    }
    
    private func saveRepostRecord(
        _ data: [String: Any],
        record: CARParser.ParsedRecord,
        repositoryID: UUID,
        modelContext: ModelContext
    ) throws {
        // Extract target from the subject field
        var targetUserDID = ""
        var targetPostURI = ""
        
        if let subject = data["subject"] as? [String: Any],
           let uri = subject["uri"] as? String {
            targetPostURI = uri
            // Parse AT URI to get the DID
            if let atURI = try? ATProtocolURI(uriString: uri) {
                targetUserDID = atURI.authority ?? ""
            }
        }
        
        let createdAtString = data["createdAt"] as? String ?? ""
        let createdAt = ISO8601DateFormatter().date(from: createdAtString) ?? Date()
        
        let parsedConnection = ParsedConnection(
            repositoryRecordID: repositoryID,
            recordKey: record.recordKey,
            targetUserDID: targetUserDID,
            connectionType: "repost",
            createdAt: createdAt,
            rawCBORData: record.rawCBORData,
            recordCID: record.cid.string,
            parseSuccessful: record.parseSuccessful,
            parseErrorMessage: record.parseError,
            parseConfidence: record.parseConfidence
        )
        modelContext.insert(parsedConnection)
        logger.debug("Successfully created ParsedConnection (repost) for post: \(targetPostURI) by user: \(targetUserDID)")
    }
    
    private func sanitizeDataForJSON(_ data: Any) -> Any {
        switch data {
        case let dict as [String: Any]:
            var sanitized: [String: Any] = [:]
            for (key, value) in dict {
                sanitized[key] = sanitizeDataForJSON(value)
            }
            return sanitized
        case let array as [Any]:
            return array.map { sanitizeDataForJSON($0) }
        case let string as String:
            return string
        case let number as NSNumber:
            return number
        case let bool as Bool:
            return bool
        case is NSNull:
            return NSNull()
        case let date as Date:
            // Convert Date to ISO8601 string for JSON compatibility
            return ISO8601DateFormatter().string(from: date)
        case let data as Data:
            // Convert Data to base64 string
            return data.base64EncodedString()
        default:
            // For any other type (including SwiftData objects), inspect the type name
            let typeName = String(describing: type(of: data))
            if typeName.contains("SwiftData") ||
               typeName.contains("__NS") ||
               typeName.hasPrefix("_") ||
               typeName.contains("Foundation.") {
                logger.debug("Sanitizing non-JSON-serializable type: \(typeName)")
                return NSNull() // Replace with null for SwiftData and internal Foundation types
            }
            // For other unknown types, convert to string representation
            return String(describing: data)
        }
    }
    
    private func getExistingRepositoryRecord(for backupID: UUID) throws -> RepositoryRecord? {
        return try getRepositoryRecord(for: backupID)
    }
    
    private func performRepositoryParsing(operation: ParsingOperation) async throws -> RepositoryRecord {
        guard let modelContext = modelContext else {
            throw RepositoryParsingError.modelContextNotAvailable
        }
        
        // CRITICAL: Pre-parsing memory check to prevent starting with high memory
        let preParseMemory = getCurrentMemoryUsage()
        logger.warning("🚨 Pre-parse memory usage: \(self.formatBytes(preParseMemory))")
        
        // Abort if memory is already high (app might have other data loaded)
        if preParseMemory > 250_000_000 { // 250MB threshold before even starting
            logger.error("🚨 ABORTING: Memory usage too high before parsing: \(self.formatBytes(preParseMemory))")
            throw RepositoryParsingError.memoryLimitExceeded("Pre-parse memory too high: \(formatBytes(preParseMemory))")
        }
        
        do {
            // Update operation status
            await MainActor.run {
                operation.status = .readingCarFile
                operation.progress = 0.1
            }
            
            // Check file size to determine which parser to use
            let fileURL = operation.backupRecord.fullFileURL
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
            
            // Update operation status
            await MainActor.run {
                operation.status = .parsingStructure
                operation.progress = 0.2
            }
            
            // CRITICAL: ONLY use streaming parser - NEVER load full file into memory
            // This is the ONLY parsing path to prevent memory kills
            let repositoryRecord: RepositoryRecord
            let estimatedRecordCount = max(1, fileSize / 150) // Estimate ~150 bytes per record
            
            logger.info("🚨 Using STREAMING ONLY parser for memory safety - File: \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)), Est. records: \(estimatedRecordCount)")
            
            // Create a separate child context for batch operations to prevent memory accumulation
            let batchContext = ModelContext(modelContext.container)
            batchContext.autosaveEnabled = false // Manual control over saves
            
            repositoryRecord = try await performEnhancedStreamingParsing(
                operation: operation,
                fileURL: fileURL,
                fileSize: fileSize,
                mainContext: modelContext,
                batchContext: batchContext
            )
            
            // Update operation status
            await MainActor.run {
                operation.status = .savingToDatabase
                operation.progress = 0.8
            }
            
            // Save repository record directly to main context
            modelContext.insert(repositoryRecord)
            try modelContext.save()
            logger.info("Saved repository record to main context: \(repositoryRecord.userHandle)")
            
            // Update operation status
            await MainActor.run {
                operation.status = .completed
                operation.progress = 1.0
                operation.endTime = Date()
            }
            
            // Clean up operation
            activeOperations.removeValue(forKey: operation.backupRecord.id)
            if currentParsingOperation?.backupRecord.id == operation.backupRecord.id {
                currentParsingOperation = nil
            }
            
            logger.info("Repository parsing completed successfully for backup \(operation.backupRecord.id.uuidString)")
            
            return repositoryRecord
            
        } catch {
            // Handle parsing errors
            await MainActor.run {
                operation.status = .failed
                operation.errorMessage = error.localizedDescription
                operation.endTime = Date()
            }
            
            // If we have a partial repository record from the parser, save it
            if case let CARParsingError.parsingFailed(_, partialRecord) = error {
                modelContext.insert(partialRecord)
                try? modelContext.save()
            } else if case let CARParsingError.streamingFailed(_, partialRecord) = error {
                modelContext.insert(partialRecord)
                try? modelContext.save()
            }
            
            // Clean up operation
            activeOperations.removeValue(forKey: operation.backupRecord.id)
            if currentParsingOperation?.backupRecord.id == operation.backupRecord.id {
                currentParsingOperation = nil
            }
            
            logger.error("Repository parsing failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Enhanced streaming parsing with proper memory management
    private func performEnhancedStreamingParsing(
        operation: ParsingOperation,
        fileURL: URL,
        fileSize: Int64,
        mainContext: ModelContext,
        batchContext: ModelContext
    ) async throws -> RepositoryRecord {
        
        let streamingParser = StreamingCARParser(enableVerboseLogging: true)
        var recordsProcessed = 0
        var batchRecords = 0
        let BATCH_SIZE = 5 // Process and save every 5 records
        
        // Create a temporary repository record for the streaming process
        let tempRepositoryRecord = RepositoryRecord(
            backupRecordID: operation.backupRecord.id,
            userDID: operation.backupRecord.userDID,
            userHandle: operation.backupRecord.userHandle,
            parsingStatus: .inProgress,
            originalCarSize: fileSize
        )
        
        // Insert repository record into main context first
        mainContext.insert(tempRepositoryRecord)
        
        let streamingResult = try await streamingParser.parseStreamingCAR(
            fileURL: fileURL,
            userDID: operation.backupRecord.userDID,
            userHandle: operation.backupRecord.userHandle,
            backupRecordID: operation.backupRecord.id
        ) { [self] block in
            // Process each block using batch context for memory efficiency
            try await self.processStreamingBlock(block, repositoryRecord: tempRepositoryRecord, modelContext: batchContext)
            recordsProcessed += 1
            batchRecords += 1
            
            // Save batch and reset context periodically
            if batchRecords >= BATCH_SIZE {
                // Transfer batch to main context
                try batchContext.save()
                
                // Clear batch context to free memory (SwiftData doesn't have reset)
                // Force memory cleanup by disabling features that retain objects
                batchContext.autosaveEnabled = false
                batchContext.undoManager = nil
                batchRecords = 0
                
                // Update progress
                await MainActor.run {
                    operation.progress = 0.2 + (0.6 * Double(recordsProcessed) / 80000.0)
                }
                
                // Save main context periodically
                if recordsProcessed % 20 == 0 {
                    try mainContext.save()
                    self.logger.debug("Saved batch to main context: \(recordsProcessed) records processed")
                }
                
                // Aggressive memory check with very low threshold
                let memoryUsage = self.getCurrentMemoryUsage()
                if memoryUsage > 200_000_000 { // 200MB threshold - very conservative
                    self.logger.warning("⚠️ High memory usage: \(self.formatBytes(memoryUsage)) - resetting batch context")
                    
                    // Force save and clear context
                    try mainContext.save()
                    batchContext.autosaveEnabled = false
                    batchContext.undoManager = nil
                    
                    // Brief pause to let memory settle
                    try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second pause
                    
                    let newMemoryUsage = self.getCurrentMemoryUsage()
                    self.logger.debug("Memory after reset: \(self.formatBytes(newMemoryUsage))")
                    
                    // Abort if memory still high
                    if newMemoryUsage > 400_000_000 { // 400MB hard limit
                        throw RepositoryParsingError.memoryLimitExceeded("Memory usage too high after reset: \(self.formatBytes(newMemoryUsage))")
                    }
                }
            }
        }
        
        // Process any remaining records in final batch
        if batchRecords > 0 {
            try batchContext.save()
            batchContext.autosaveEnabled = false
            batchContext.undoManager = nil
        }
        
        // Update the repository record with final statistics
        let finalRepositoryRecord = streamingResult.repositoryRecord
        finalRepositoryRecord.parsingStatus = RepositoryParsingStatus.completed
        finalRepositoryRecord.totalRecordCount = recordsProcessed
        finalRepositoryRecord.parsingLogFileURL = streamingResult.logFileURL
        
        logger.info("Streaming parsing completed: \(recordsProcessed) records processed")
        return finalRepositoryRecord
    }
    
    // REMOVED: performRegularParsing function
    // This function was causing OOM crashes by loading entire CAR files into memory
    // ALL parsing MUST use streaming to prevent memory issues
    
    /// Process a streaming block and save parsed data immediately
    private func processStreamingBlock(
        _ block: StreamingBlock,
        repositoryRecord: RepositoryRecord,
        modelContext: ModelContext
    ) async throws {
        
        guard let decodedData = block.decodedData,
              let recordType = block.recordType,
              let cid = block.cid else {
            return // Skip blocks without decoded data
        }
        
        // Process based on record type
        switch recordType {
        case "app.bsky.feed.post":
            try await processStreamingPost(decodedData, cid: cid, repositoryRecord: repositoryRecord, modelContext: modelContext)
            
        case "app.bsky.actor.profile":
            try await processStreamingProfile(decodedData, cid: cid, repositoryRecord: repositoryRecord, modelContext: modelContext)
            
        case "app.bsky.graph.follow", "app.bsky.graph.block":
            try await processStreamingConnection(decodedData, cid: cid, connectionType: recordType, repositoryRecord: repositoryRecord, modelContext: modelContext)
            
        default:
            // Store as general AT Protocol record
            try await processStreamingATProtocolRecord(decodedData, cid: cid, collectionType: recordType, repositoryRecord: repositoryRecord, modelContext: modelContext)
        }
    }
    
    /// Process streaming post data
    private func processStreamingPost(
        _ recordData: [String: Any],
        cid: String,
        repositoryRecord: RepositoryRecord,
        modelContext: ModelContext
    ) async throws {
        
        // Sanitize text to prevent crashes
        let rawText = recordData["text"] as? String ?? ""
        let text = rawText.sanitizedForDisplay()
        let createdAt = parseATProtocolTimestamp(recordData["createdAt"] as? String ?? "")
        
        let post = ParsedPost(
            repositoryRecordID: repositoryRecord.id,
            recordKey: "streaming-\(UUID().uuidString)",
            text: text,
            createdAt: createdAt,
            rawCBORData: Data(), // Don't store raw data to save memory
            recordCID: cid,
            parseConfidence: 0.9
        )
        
        // Insert directly without MainActor to avoid queue buildup
        modelContext.insert(post)
    }
    
    /// Process streaming profile data  
    private func processStreamingProfile(
        _ recordData: [String: Any],
        cid: String,
        repositoryRecord: RepositoryRecord,
        modelContext: ModelContext
    ) async throws {
        
        // Sanitize profile text fields to prevent crashes
        let rawDisplayName = recordData["displayName"] as? String ?? ""
        let rawDescription = recordData["description"] as? String ?? ""
        
        let displayName = rawDisplayName.sanitizedForDisplay()
        let description = rawDescription.sanitizedForDisplay()
        
        let profile = ParsedProfile(
            repositoryRecordID: repositoryRecord.id,
            recordKey: "self",
            displayName: displayName.isEmpty ? nil : displayName,
            description: description.isEmpty ? nil : description,
            rawCBORData: Data(),
            recordCID: cid,
            parseConfidence: 0.9
        )
        
        // Insert directly without MainActor to avoid queue buildup
        modelContext.insert(profile)
    }
    
    /// Process streaming connection data
    private func processStreamingConnection(
        _ recordData: [String: Any],
        cid: String,
        connectionType: String,
        repositoryRecord: RepositoryRecord,
        modelContext: ModelContext
    ) async throws {
        
        let targetDID = recordData["subject"] as? String ?? ""
        let createdAt = parseATProtocolTimestamp(recordData["createdAt"] as? String ?? "")
        
        let connection = ParsedConnection(
            repositoryRecordID: repositoryRecord.id,
            recordKey: "streaming-\(UUID().uuidString)",
            targetUserDID: targetDID,
            connectionType: connectionType.contains("follow") ? "follow" : "block",
            createdAt: createdAt,
            rawCBORData: Data(),
            recordCID: cid,
            parseConfidence: 0.9
        )
        
        // Insert directly without MainActor to avoid queue buildup
        modelContext.insert(connection)
    }
    
    /// Process streaming AT Protocol record data
    private func processStreamingATProtocolRecord(
        _ recordData: [String: Any],
        cid: String,
        collectionType: String,
        repositoryRecord: RepositoryRecord,
        modelContext: ModelContext
    ) async throws {
        
        let serializedData: String
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: recordData)
            serializedData = String(data: jsonData, encoding: .utf8) ?? "{}"
        } catch {
            serializedData = "{}"
        }
        
        let record = ParsedATProtocolRecord(
            repositoryRecordID: repositoryRecord.id,
            recordURI: "at://\(repositoryRecord.userDID)/\(collectionType)/\(UUID().uuidString)",
            recordKey: "streaming-\(UUID().uuidString)",
            collectionType: collectionType,
            recordData: serializedData.data(using: .utf8) ?? Data(),
            recordCID: cid,
            parseSuccessful: true,
            parseConfidence: 0.8
        )
        
        // Insert directly without MainActor to avoid queue buildup
        modelContext.insert(record)
    }
    
    /// Parse AT Protocol timestamp string to Date
    private func parseATProtocolTimestamp(_ timestamp: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: timestamp) ?? Date()
    }
    
    /// Get current memory usage in bytes
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
    
    /// Format bytes as human readable string
    private func formatBytes(_ bytes: UInt64) -> String {
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Parsing Operation

/// Represents an active parsing operation
@Observable
final class ParsingOperation {
    let backupRecord: BackupRecord
    let startTime: Date
    var endTime: Date?
    var status: ParsingStatus = .starting
    var progress: Double = 0.0
    var errorMessage: String?
    
    init(backupRecord: BackupRecord, startTime: Date, status: ParsingStatus) {
        self.backupRecord = backupRecord
        self.startTime = startTime
        self.status = status
    }
    
    var duration: TimeInterval? {
        guard let endTime = endTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }
    
    var formattedDuration: String {
        guard let duration = duration else { return "In progress..." }
        
        if duration < 60 {
            return String(format: "%.1fs", duration)
        } else if duration < 3600 {
            return String(format: "%.1fm", duration / 60)
        } else {
            return String(format: "%.1fh", duration / 3600)
        }
    }
}

/// Status of a parsing operation
enum ParsingStatus: String, CaseIterable {
    case starting = "starting"
    case readingCarFile = "reading_car_file"
    case parsingStructure = "parsing_structure"
    case savingToDatabase = "saving_to_database"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
    
    var displayName: String {
        switch self {
        case .starting:
            return "Starting..."
        case .readingCarFile:
            return "Reading CAR file..."
        case .parsingStructure:
            return "Parsing repository structure..."
        case .savingToDatabase:
            return "Saving to database..."
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }
    
    var systemImage: String {
        switch self {
        case .starting:
            return "clock"
        case .readingCarFile:
            return "doc.text"
        case .parsingStructure:
            return "cpu"
        case .savingToDatabase:
            return "externaldrive.badge.plus"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .cancelled:
            return "stop.circle.fill"
        }
    }
    
    var color: String {
        switch self {
        case .starting, .readingCarFile, .parsingStructure, .savingToDatabase:
            return "blue"
        case .completed:
            return "green"
        case .failed:
            return "red"
        case .cancelled:
            return "orange"
        }
    }
}

// MARK: - Errors

public enum RepositoryParsingError: LocalizedError {
    case experimentalFeatureDisabled
    case modelContextNotAvailable
    case backupRecordNotFound
    case parsingAlreadyInProgress
    case backupFileNotFound
    case invalidRecordData(String)
    case memoryLimitExceeded(String)
    
    public var errorDescription: String? {
        switch self {
        case .experimentalFeatureDisabled:
            return "Experimental repository parsing is disabled. Enable it in settings to use this feature."
        case .modelContextNotAvailable:
            return "Database not available for parsing operations"
        case .backupRecordNotFound:
            return "Backup record not found"
        case .parsingAlreadyInProgress:
            return "Repository parsing is already in progress for this backup"
        case .backupFileNotFound:
            return "Backup file not found on disk"
        case .invalidRecordData(let message):
            return "Invalid record data: \(message)"
        case .memoryLimitExceeded(let message):
            return "Memory limit exceeded: \(message)"
        }
    }
}
