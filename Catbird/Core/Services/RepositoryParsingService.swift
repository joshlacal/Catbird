import Foundation
import SwiftData
import Petrel
import OSLog
import SwiftCBOR

// MARK: - Repository Parsing Service

/// Service that orchestrates parsing CAR backups into structured repository data.
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

  private let logger = Logger(subsystem: "blue.catbird", category: "RepositoryParsingService")
  private var modelContext: ModelContext?
  private var carParser = CARParser()

  /// Current parsing operation
  var currentParsingOperation: ParsingOperation?

  /// Active parsing operations by backup ID
  private var activeOperations: [UUID: ParsingOperation] = [:]

  /// Parsing is always enabled (no longer gated behind experimental toggle)
  var experimentalParsingEnabled: Bool {
    get { true }
    set { }
  }

  // MARK: - Initialization

  init() {
    logger.debug("RepositoryParsingService initialized")
  }

  func configure(with modelContext: ModelContext) {
    self.modelContext = modelContext
    logger.debug("RepositoryParsingService configured with ModelContext")
  }

  // MARK: - Public API

  /// Start parsing a backup repository
  @MainActor
  func startRepositoryParsing(for backupRecord: BackupRecord) async throws -> RepositoryRecord {
    logger.info("Starting repository parsing for backup \(backupRecord.id.uuidString)")

    // Log memory baseline (no pre-parse rejection — streaming parser handles large files)
    let initialMemory = getCurrentMemoryUsage()
    logger.info("Initial memory usage: \(self.formatBytes(initialMemory))")

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
    descriptor.fetchLimit = 10

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

    if let repoRecord = try getRepositoryRecord(for: repositoryID) {
      modelContext.delete(repoRecord)
    }

    try modelContext.save()

    logger.info("Deleted all parsed data for repository \(repositoryID.uuidString)")
  }

  /// Re-parse a repository
  @MainActor
  func reparseRepository(for backupRecord: BackupRecord) async throws -> RepositoryRecord {
    logger.info("Re-parsing repository for backup \(backupRecord.id.uuidString)")

    if let existingRepo = try getExistingRepositoryRecord(for: backupRecord.id) {
      try deleteRepositoryData(for: existingRepo.id)
    }

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
    let batchSize = 5
    var recordTypeCounts: [String: Int] = [:]

    for record in parsedRecords {
      recordTypeCounts[record.recordType, default: 0] += 1

      try saveIndividualParsedRecord(record, to: repositoryRecord, modelContext: modelContext)
      batchCount += 1

      if batchCount % batchSize == 0 {
        try modelContext.save()
        logger.debug("Saved batch of \(batchSize) records to main context, total: \(batchCount)")
      }
    }

    try modelContext.save()

    logger.info("Successfully saved all \(parsedRecords.count) parsed records to main context")
    for (recordType, count) in recordTypeCounts.sorted(by: { $0.value > $1.value }) {
      logger.info("Record type \(recordType): \(count)")
    }
  }

  private func saveIndividualParsedRecord(
    _ record: CARParser.ParsedRecord,
    to repositoryRecord: RepositoryRecord,
    modelContext: ModelContext
  ) throws {
    let recordURI = "at://\(repositoryRecord.userDID)/\(record.recordType)/\(record.recordKey)"

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

    logger.debug("Processing record type: '\(record.recordType)' for key: \(record.recordKey)")

    switch record.recordType {
    case "app.bsky.feed.post":
      if let parsedData = record.parsedData as? [String: Any] {
        try savePostRecord(parsedData, record: record, repositoryID: repositoryRecord.id, modelContext: modelContext)
      } else {
        logger.warning("No parsed data for app.bsky.feed.post record: \(record.recordKey)")
      }

    case "app.bsky.actor.profile":
      if let parsedData = record.parsedData as? [String: Any] {
        try saveProfileRecord(parsedData, record: record, repositoryID: repositoryRecord.id, modelContext: modelContext)
      } else {
        logger.warning("No parsed data for app.bsky.actor.profile record: \(record.recordKey)")
      }

    case "app.bsky.graph.follow":
      if let parsedData = record.parsedData as? [String: Any] {
        try saveFollowRecord(parsedData, record: record, repositoryID: repositoryRecord.id, modelContext: modelContext)
      } else {
        logger.warning("No parsed data for app.bsky.graph.follow record: \(record.recordKey)")
      }

    case "app.bsky.feed.like":
      if let parsedData = record.parsedData as? [String: Any] {
        try saveLikeRecord(parsedData, record: record, repositoryID: repositoryRecord.id, modelContext: modelContext)
      } else {
        logger.warning("No parsed data for app.bsky.feed.like record: \(record.recordKey)")
      }

    case "app.bsky.graph.block":
      if let parsedData = record.parsedData as? [String: Any] {
        try saveBlockRecord(parsedData, record: record, repositoryID: repositoryRecord.id, modelContext: modelContext)
      } else {
        logger.warning("No parsed data for app.bsky.graph.block record: \(record.recordKey)")
      }

    case "app.bsky.graph.listitem":
      if let parsedData = record.parsedData as? [String: Any] {
        try saveListItemRecord(parsedData, record: record, repositoryID: repositoryRecord.id, modelContext: modelContext)
      } else {
        logger.warning("No parsed data for app.bsky.graph.listitem record: \(record.recordKey)")
      }

    case "app.bsky.graph.list":
      if let parsedData = record.parsedData as? [String: Any] {
        try saveListRecord(parsedData, record: record, repositoryID: repositoryRecord.id, modelContext: modelContext)
      } else {
        logger.warning("No parsed data for app.bsky.graph.list record: \(record.recordKey)")
      }

    case "app.bsky.feed.repost":
      if let parsedData = record.parsedData as? [String: Any] {
        try saveRepostRecord(parsedData, record: record, repositoryID: repositoryRecord.id, modelContext: modelContext)
      } else {
        logger.warning("No parsed data for app.bsky.feed.repost record: \(record.recordKey)")
      }

    default:
      logger.debug("Unknown record type: '\(record.recordType)' for key: \(record.recordKey)")
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
      let fallbackRecord = ParsedATProtocolRecord(
        repositoryRecordID: repositoryRecord.id,
        recordURI: recordURI,
        recordKey: record.recordKey,
        collectionType: record.recordType,
        recordData: Data(),
        recordCID: record.cid.string,
        createdAt: createdAt,
        parseSuccessful: false,
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
    let rawText = data["text"] as? String ?? ""
    let text = rawText.sanitizedForDisplay()

    if rawText.containsProblematicCharacters {
      logger.warning("Sanitized problematic text for post \(record.recordKey)")
    }

    let createdAt: Date
    if let date = data["createdAt"] as? Date {
      createdAt = date
    } else if let dateString = data["createdAt"] as? String {
      createdAt = ISO8601DateFormatter().date(from: dateString) ?? Date()
    } else {
      createdAt = Date()
    }

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
  }

  private func saveProfileRecord(
    _ data: [String: Any],
    record: CARParser.ParsedRecord,
    repositoryID: UUID,
    modelContext: ModelContext
  ) throws {
    let rawDisplayName = data["displayName"] as? String
    let rawDescription = data["description"] as? String

    let displayName = rawDisplayName?.sanitizedForDisplay()
    let description = rawDescription?.sanitizedForDisplay()

    if let raw = rawDisplayName, raw.containsProblematicCharacters {
      logger.warning("Sanitized problematic display name for profile \(record.recordKey)")
    }
    if let raw = rawDescription, raw.containsProblematicCharacters {
      logger.warning("Sanitized problematic description for profile \(record.recordKey)")
    }

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
  }

  private func saveFollowRecord(
    _ data: [String: Any],
    record: CARParser.ParsedRecord,
    repositoryID: UUID,
    modelContext: ModelContext
  ) throws {
    let targetUserDID = data["subject"] as? String ?? ""

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
  }

  private func saveLikeRecord(
    _ data: [String: Any],
    record: CARParser.ParsedRecord,
    repositoryID: UUID,
    modelContext: ModelContext
  ) throws {
    var targetUserDID = ""

    if let subject = data["subject"] as? [String: Any],
       let uri = subject["uri"] as? String {
      if let atURI = try? ATProtocolURI(uriString: uri) {
        targetUserDID = atURI.authority ?? ""
      }
    } else if let subjectURI = data["subject"] as? String {
      if let atURI = try? ATProtocolURI(uriString: subjectURI) {
        targetUserDID = atURI.authority ?? ""
      }
    }

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
  }

  private func saveListRecord(
    _ data: [String: Any],
    record: CARParser.ParsedRecord,
    repositoryID: UUID,
    modelContext: ModelContext
  ) throws {
    let rawName = data["name"] as? String ?? ""
    let name = rawName.sanitizedForDisplay()
    let createdAtString = data["createdAt"] as? String ?? ""
    let createdAt = ISO8601DateFormatter().date(from: createdAtString) ?? Date()

    let parsedConnection = ParsedConnection(
      repositoryRecordID: repositoryID,
      recordKey: record.recordKey,
      targetUserDID: name,
      connectionType: "list",
      createdAt: createdAt,
      rawCBORData: record.rawCBORData,
      recordCID: record.cid.string,
      parseSuccessful: record.parseSuccessful,
      parseErrorMessage: record.parseError,
      parseConfidence: record.parseConfidence
    )
    modelContext.insert(parsedConnection)
  }

  private func saveRepostRecord(
    _ data: [String: Any],
    record: CARParser.ParsedRecord,
    repositoryID: UUID,
    modelContext: ModelContext
  ) throws {
    var targetUserDID = ""

    if let subject = data["subject"] as? [String: Any],
       let uri = subject["uri"] as? String {
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
      return ISO8601DateFormatter().string(from: date)
    case let data as Data:
      return data.base64EncodedString()
    default:
      let typeName = String(describing: type(of: data))
      if typeName.contains("SwiftData") ||
         typeName.contains("__NS") ||
         typeName.hasPrefix("_") ||
         typeName.contains("Foundation.") {
        return NSNull()
      }
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

    let preParseMemory = getCurrentMemoryUsage()
    logger.info("Pre-parse memory usage: \(self.formatBytes(preParseMemory))")

    if preParseMemory > 800_000_000 { // 800MB — approaching iOS kill zone (~1.4GB)
      logger.error("Aborting: Memory usage too high before parsing: \(self.formatBytes(preParseMemory))")
      throw RepositoryParsingError.memoryLimitExceeded("Pre-parse memory too high: \(formatBytes(preParseMemory))")
    }

    do {
      await MainActor.run {
        operation.status = .readingCarFile
        operation.progress = 0.1
      }

      let fileURL = operation.backupRecord.fullFileURL
      let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0

      await MainActor.run {
        operation.status = .parsingStructure
        operation.progress = 0.2
      }

      let repositoryRecord: RepositoryRecord

      logger.info("Using streaming parser for memory safety - File: \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))")

      let batchContext = ModelContext(modelContext.container)
      batchContext.autosaveEnabled = false

      repositoryRecord = try await performEnhancedStreamingParsing(
        operation: operation,
        fileURL: fileURL,
        fileSize: fileSize,
        mainContext: modelContext,
        batchContext: batchContext
      )

      await MainActor.run {
        operation.status = .savingToDatabase
        operation.progress = 0.8
      }

      modelContext.insert(repositoryRecord)
      try modelContext.save()
      logger.info("Saved repository record to main context: \(repositoryRecord.userHandle)")

      await MainActor.run {
        operation.status = .completed
        operation.progress = 1.0
        operation.endTime = Date()
      }

      activeOperations.removeValue(forKey: operation.backupRecord.id)
      if currentParsingOperation?.backupRecord.id == operation.backupRecord.id {
        currentParsingOperation = nil
      }

      logger.info("Repository parsing completed successfully for backup \(operation.backupRecord.id.uuidString)")

      return repositoryRecord

    } catch {
      await MainActor.run {
        operation.status = .failed
        operation.errorMessage = error.localizedDescription
        operation.endTime = Date()
      }

      if case let CARParsingError.parsingFailed(_, partialRecord) = error {
        modelContext.insert(partialRecord)
        try? modelContext.save()
      } else if case let CARParsingError.streamingFailed(_, partialRecord) = error {
        modelContext.insert(partialRecord)
        try? modelContext.save()
      }

      activeOperations.removeValue(forKey: operation.backupRecord.id)
      if currentParsingOperation?.backupRecord.id == operation.backupRecord.id {
        currentParsingOperation = nil
      }

      logger.error("Repository parsing failed: \(error.localizedDescription)")
      throw error
    }
  }

  /// Parse repository using ATProtoRepoParser (correct CAR + MST implementation)
  private func performEnhancedStreamingParsing(
    operation: ParsingOperation,
    fileURL: URL,
    fileSize: Int64,
    mainContext: ModelContext,
    batchContext: ModelContext
  ) async throws -> RepositoryRecord {

    let parser = ATProtoRepoParser()
    var recordsProcessed = 0
    var batchRecords = 0
    let BATCH_SIZE = 50
    let repoRecordID = UUID()

    let repositoryRecord = try parser.parseRepository(
      fileURL: fileURL,
      userDID: operation.backupRecord.userDID,
      userHandle: operation.backupRecord.userHandle,
      backupRecordID: operation.backupRecord.id,
      repositoryRecordID: repoRecordID,
      onProgress: { progress in
        Task { @MainActor in
          switch progress.phase {
          case .parsing:
            let total = max(progress.recordsProcessed, 1)
            operation.progress = 0.1 + (0.7 * Double(progress.recordsProcessed) / Double(total))
          case .complete:
            operation.progress = 0.8
          }
        }
      },
      onRecord: { [self] record in
        self.processATProtoRecord(record, repositoryRecordID: repoRecordID, modelContext: batchContext, userDID: operation.backupRecord.userDID)
        recordsProcessed += 1
        batchRecords += 1

        if batchRecords >= BATCH_SIZE {
          try batchContext.save()
          batchContext.autosaveEnabled = false
          batchContext.undoManager = nil
          batchRecords = 0

          if recordsProcessed % 200 == 0 {
            try mainContext.save()
            self.logger.debug("Saved batch to main context: \(recordsProcessed) records processed")
          }

          let memoryUsage = self.getCurrentMemoryUsage()
          if memoryUsage > 600_000_000 {
            self.logger.warning("High memory usage: \(self.formatBytes(memoryUsage)) - flushing batch context")
            try mainContext.save()
            batchContext.autosaveEnabled = false
            batchContext.undoManager = nil
          }
        }
      }
    )

    if batchRecords > 0 {
      try batchContext.save()
      batchContext.autosaveEnabled = false
      batchContext.undoManager = nil
    }

    repositoryRecord.parsingStatus = .completed

    logger.info("Parsing completed: \(recordsProcessed) records processed")
    return repositoryRecord
  }

  /// Process a CARRepository.Record into SwiftData models using ATProtocolValueContainer
  private func processATProtoRecord(
    _ record: CARRepository.Record,
    repositoryRecordID: UUID,
    modelContext: ModelContext,
    userDID: String
  ) {
    let repoID = repositoryRecordID

    switch record.collection {
    case "app.bsky.feed.post":
      if case .knownType(let value) = record.value, let post = value as? AppBskyFeedPost {
        let text = post.text.sanitizedForDisplay()
        let parsedPost = ParsedPost(
          repositoryRecordID: repoID,
          recordKey: record.rkey,
          text: text,
          createdAt: post.createdAt.date,
          rawCBORData: record.rawCBOR,
          recordCID: record.cid.string,
          parseConfidence: 1.0
        )
        modelContext.insert(parsedPost)
      } else {
        insertFallbackRecord(record, repoID: repoID, userDID: userDID, modelContext: modelContext)
      }

    case "app.bsky.actor.profile":
      if case .knownType(let value) = record.value, let profile = value as? AppBskyActorProfile {
        let displayName = profile.displayName?.sanitizedForDisplay()
        let description = profile.description?.sanitizedForDisplay()
        let parsedProfile = ParsedProfile(
          repositoryRecordID: repoID,
          recordKey: record.rkey,
          displayName: displayName?.isEmpty == true ? nil : displayName,
          description: description?.isEmpty == true ? nil : description,
          rawCBORData: record.rawCBOR,
          recordCID: record.cid.string,
          parseConfidence: 1.0
        )
        modelContext.insert(parsedProfile)
      } else {
        insertFallbackRecord(record, repoID: repoID, userDID: userDID, modelContext: modelContext)
      }

    case "app.bsky.graph.follow":
      if case .knownType(let value) = record.value, let follow = value as? AppBskyGraphFollow {
        let connection = ParsedConnection(
          repositoryRecordID: repoID,
          recordKey: record.rkey,
          targetUserDID: follow.subject.description,
          connectionType: "follow",
          createdAt: follow.createdAt.date,
          rawCBORData: record.rawCBOR,
          recordCID: record.cid.string,
          parseConfidence: 1.0
        )
        modelContext.insert(connection)
      } else {
        insertFallbackRecord(record, repoID: repoID, userDID: userDID, modelContext: modelContext)
      }

    case "app.bsky.graph.block":
      if case .knownType(let value) = record.value, let block = value as? AppBskyGraphBlock {
        let connection = ParsedConnection(
          repositoryRecordID: repoID,
          recordKey: record.rkey,
          targetUserDID: block.subject.description,
          connectionType: "block",
          createdAt: block.createdAt.date,
          rawCBORData: record.rawCBOR,
          recordCID: record.cid.string,
          parseConfidence: 1.0
        )
        modelContext.insert(connection)
      } else {
        insertFallbackRecord(record, repoID: repoID, userDID: userDID, modelContext: modelContext)
      }

    default:
      insertFallbackRecord(record, repoID: repoID, userDID: userDID, modelContext: modelContext)
    }
  }

  /// Insert a generic ParsedATProtocolRecord for unknown or decode-failed records
  private func insertFallbackRecord(
    _ record: CARRepository.Record,
    repoID: UUID,
    userDID: String,
    modelContext: ModelContext
  ) {
    let isDecodeError: Bool
    if case .decodeError = record.value {
      isDecodeError = true
    } else {
      isDecodeError = false
    }

    // Encode the ATProtocolValueContainer to JSON for storage
    let recordData: Data
    if let jsonData = try? JSONEncoder().encode(record.value) {
      recordData = jsonData
    } else {
      recordData = Data()
    }

    let atRecord = ParsedATProtocolRecord(
      repositoryRecordID: repoID,
      recordURI: "at://\(userDID)/\(record.collection)/\(record.rkey)",
      recordKey: record.rkey,
      collectionType: record.collection,
      recordData: recordData,
      recordCID: record.cid.string,
      parseSuccessful: !isDecodeError,
      parseConfidence: isDecodeError ? 0.0 : 0.8
    )
    modelContext.insert(atRecord)
  }

  /// Process a streaming block and save parsed data immediately
  private func processStreamingBlock(
    _ block: StreamingBlock,
    repositoryRecord: RepositoryRecord,
    modelContext: ModelContext
  ) async throws {

    guard let decodedData = block.decodedData,
          let recordType = block.recordType,
          let cid = block.cid else {
      return
    }

    switch recordType {
    case "app.bsky.feed.post":
      try await processStreamingPost(decodedData, cid: cid, repositoryRecord: repositoryRecord, modelContext: modelContext)

    case "app.bsky.actor.profile":
      try await processStreamingProfile(decodedData, cid: cid, repositoryRecord: repositoryRecord, modelContext: modelContext)

    case "app.bsky.graph.follow", "app.bsky.graph.block":
      try await processStreamingConnection(decodedData, cid: cid, connectionType: recordType, repositoryRecord: repositoryRecord, modelContext: modelContext)

    default:
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

    let rawText = recordData["text"] as? String ?? ""
    let text = rawText.sanitizedForDisplay()
    let createdAt = parseATProtocolTimestamp(recordData["createdAt"] as? String ?? "")

    let post = ParsedPost(
      repositoryRecordID: repositoryRecord.id,
      recordKey: "streaming-\(UUID().uuidString)",
      text: text,
      createdAt: createdAt,
      rawCBORData: Data(),
      recordCID: cid,
      parseConfidence: 0.9
    )

    modelContext.insert(post)
  }

  /// Process streaming profile data
  private func processStreamingProfile(
    _ recordData: [String: Any],
    cid: String,
    repositoryRecord: RepositoryRecord,
    modelContext: ModelContext
  ) async throws {

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
  case modelContextNotAvailable
  case backupRecordNotFound
  case parsingAlreadyInProgress
  case backupFileNotFound
  case invalidRecordData(String)
  case memoryLimitExceeded(String)

  public var errorDescription: String? {
    switch self {
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
