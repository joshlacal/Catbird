//
//  MLSGRDBManager.swift
//  Catbird
//
//  GRDB DatabaseQueue manager with SQLCipher encryption for MLS storage
//  Works with SQLiteData for SwiftUI integration
//

import Foundation
import GRDB
import OSLog

/// Manages encrypted GRDB DatabaseQueue instances with per-user isolation
final class MLSGRDBManager: @unchecked Sendable {

  // MARK: - Properties

  /// Shared singleton instance
  @MainActor
  static let shared = MLSGRDBManager()

  /// Serial queue for thread-safe access to databases dictionary
  private let accessQueue = DispatchQueue(label: "com.catbird.mls.grdb.access")

  /// Logger for database operations
  private let logger = Logger(subsystem: "Catbird", category: "MLSGRDBManager")

  /// Active database queues per user DID
  private var databases: [String: DatabaseQueue] = [:]

  /// Encryption manager
  private let encryption = MLSSQLCipherEncryption.shared

  /// Base directory for all user databases
  private let databaseDirectory: URL

  /// Database file extension
  private let fileExtension = "db"

  // MARK: - Initialization

  private init() {
    // Create base directory for MLS databases
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    self.databaseDirectory = appSupport.appendingPathComponent("MLS", isDirectory: true)

    // Create directory if it doesn't exist
    do {
      try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
    } catch {
      logger.error("Failed to create database directory: \(error.localizedDescription)")
    }
  }

  // MARK: - Public API

  /// Get or create encrypted DatabaseQueue for a user (async to avoid main thread blocking)
  /// - Parameter userDID: User's decentralized identifier
  /// - Returns: Encrypted GRDB DatabaseQueue
  /// - Throws: MLSSQLCipherError if creation fails
  func getDatabaseQueue(for userDID: String) async throws -> DatabaseQueue {
    // Check cache first (thread-safe)
    let existingDatabase = accessQueue.sync {
      databases[userDID]
    }

    if let existingDatabase = existingDatabase {
      return existingDatabase
    }

    // Create database off main thread
    do {
        let database = try await createDatabase(for: userDID)

      // Cache the database (thread-safe)
      accessQueue.sync {
        databases[userDID] = database
      }

      logger.info("Created new database for user: \(userDID, privacy: .private)")

      return database
    } catch {
      // If database creation fails with corruption error, attempt repair
      let errorDescription = error.localizedDescription
      if errorDescription.contains("out of memory") || errorDescription.contains("SQLITE") {
        logger.warning("⚠️ Database creation failed, attempting repair: \(errorDescription)")

        // Attempt repair
        try? repairDatabase(for: userDID)

        // Retry database creation after repair
          let database = try await createDatabase(for: userDID)

        accessQueue.sync {
          databases[userDID] = database
        }

        logger.info("✅ Database recovered after repair for user: \(userDID, privacy: .private)")

        return database
      }

      // Re-throw if not a recoverable error
      throw error
    }
  }

  /// Close database for a user
  /// - Parameter userDID: User's decentralized identifier
  func closeDatabase(for userDID: String) {
    accessQueue.sync {
      if databases.removeValue(forKey: userDID) != nil {
        logger.info("Closed database for user: \(userDID, privacy: .private)")
      }
    }
  }

  /// Close all databases
  func closeAllDatabases() {
    accessQueue.sync {
      let userDIDs = Array(databases.keys)
      for userDID in userDIDs {
        databases.removeValue(forKey: userDID)
      }
      logger.info("Closed all databases")
    }
  }

  /// Delete database file for a user (when removing account)
  /// - Parameter userDID: User's decentralized identifier
  /// - Throws: MLSSQLCipherError if deletion fails
  @MainActor
  func deleteDatabase(for userDID: String) throws {
    // Close database first
    closeDatabase(for: userDID)

    // Delete database file
    let dbPath = databasePath(for: userDID)

    if FileManager.default.fileExists(atPath: dbPath.path) {
      do {
        try FileManager.default.removeItem(at: dbPath)
        logger.info("Deleted database for user: \(userDID, privacy: .private)")
      } catch {
        throw MLSSQLCipherError.databaseCreationFailed(underlying: error)
      }
    }

    // Delete encryption key
    try encryption.deleteKey(for: userDID)
  }

  /// Repair corrupted database by removing WAL and SHM files
  /// Call this if you get SQLITE_NOMEM or other corruption errors
  /// - Parameter userDID: User's decentralized identifier
  func repairDatabase(for userDID: String) throws {
    logger.warning("⚠️ Attempting to repair database for user: \(userDID, privacy: .private)")

    // Close database first
    closeDatabase(for: userDID)

    let dbPath = databasePath(for: userDID)
    let walPath = URL(fileURLWithPath: dbPath.path + "-wal")
    let shmPath = URL(fileURLWithPath: dbPath.path + "-shm")

    // Delete WAL and SHM files (will be recreated)
    for path in [walPath, shmPath] {
      if FileManager.default.fileExists(atPath: path.path) {
        do {
          try FileManager.default.removeItem(at: path)
          logger.info("Deleted corrupted file: \(path.lastPathComponent)")
        } catch {
          logger.error("Failed to delete \(path.lastPathComponent): \(error.localizedDescription)")
        }
      }
    }

    logger.info("✅ Database repair completed for user: \(userDID, privacy: .private)")
  }

  /// Check if database exists for user
  /// - Parameter userDID: User's decentralized identifier
  /// - Returns: True if database file exists
  func databaseExists(for userDID: String) -> Bool {
    let dbPath = databasePath(for: userDID)
    return FileManager.default.fileExists(atPath: dbPath.path)
  }

  /// Get database file size
  /// - Parameter userDID: User's decentralized identifier
  /// - Returns: Size in bytes, or nil if database doesn't exist
  func databaseSize(for userDID: String) -> Int64? {
    let dbPath = databasePath(for: userDID)

    guard let attributes = try? FileManager.default.attributesOfItem(atPath: dbPath.path),
          let fileSize = attributes[.size] as? Int64 else {
      return nil
    }

    return fileSize
  }

  // MARK: - Private Methods

  /// Create new encrypted database with GRDB
  @MainActor
  private func createDatabase(for userDID: String) throws -> DatabaseQueue {
    // Get or create encryption key
    let encryptionKey = try encryption.getOrCreateKey(for: userDID)

    // Get database file path
    let dbPath = databasePath(for: userDID)

    // Configure GRDB with SQLCipher encryption
    var config = Configuration()

    // Configure encryption using GRDB's prepareDatabase
    config.prepareDatabase { db in
      // Convert key to hex string for SQLCipher
      // SQLCipher expects: PRAGMA key = "x'hexstring'"
      let hexKey = encryptionKey.map { String(format: "%02x", $0) }.joined()

      // Set encryption key using quoted hex literal format
      try db.execute(sql: "PRAGMA key = \"x'\(hexKey)'\";")

      // Configure SQLCipher 4 parameters
      try db.execute(sql: "PRAGMA cipher_page_size = 4096;")
      try db.execute(sql: "PRAGMA kdf_iter = 256000;")
      try db.execute(sql: "PRAGMA cipher_hmac_algorithm = HMAC_SHA512;")
      try db.execute(sql: "PRAGMA cipher_kdf_algorithm = PBKDF2_HMAC_SHA512;")

      // Enable WAL mode for better concurrency
      try db.execute(sql: "PRAGMA journal_mode = WAL;")
      try db.execute(sql: "PRAGMA wal_autocheckpoint = 1000;")
      try db.execute(sql: "PRAGMA synchronous = FULL;")

      // Enable foreign keys
      try db.execute(sql: "PRAGMA foreign_keys = ON;")

      // Verify encryption by accessing database
      _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master;")
    }

    // Create DatabaseQueue
    let database: DatabaseQueue
    do {
      database = try DatabaseQueue(path: dbPath.path, configuration: config)
    } catch {
      throw MLSSQLCipherError.databaseCreationFailed(underlying: error)
    }

    // Set file protection (iOS Data Protection)
    try setFileProtection(for: dbPath)

    // Exclude from backups
    try excludeFromBackup(dbPath)

    // Run migrations
    try runMigrations(database)

    return database
  }

  /// Run database migrations using DatabaseMigrator
  private func runMigrations(_ db: DatabaseQueue) throws {
    var migrator = DatabaseMigrator()

    // MARK: v1 - Initial schema
    migrator.registerMigration("v1_initial_schema") { db in
      // Create all MLS tables using GRDB's native table creation
      try db.create(table: "MLSConversationModel") { t in
        t.primaryKey("conversationID", .text).notNull()
        t.column("currentUserDID", .text).notNull()
        t.column("groupID", .blob).notNull()
        t.column("epoch", .integer).notNull().defaults(to: 0)
        t.column("title", .text)
        t.column("avatarURL", .text)
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
        t.column("lastMessageAt", .datetime)
        t.column("isActive", .boolean).notNull().defaults(to: true)
        t.column("needsRejoin", .boolean).notNull().defaults(to: false)
        t.column("rejoinRequestedAt", .datetime)
      }
      
      try db.create(table: "MLSMessageModel") { t in
        t.primaryKey("messageID", .text).notNull()
        t.column("currentUserDID", .text).notNull()
        t.column("conversationID", .text).notNull().references("MLSConversationModel", onDelete: .cascade)
        t.column("senderID", .text).notNull()
        t.column("plaintext", .text)
        t.column("embedData", .blob)
        t.column("wireFormat", .blob)
        t.column("contentType", .text).notNull()
        t.column("timestamp", .datetime).notNull()
        t.column("epoch", .integer).notNull()
        t.column("sequenceNumber", .integer).notNull()
        t.column("authenticatedData", .blob)
        t.column("signature", .blob)
        t.column("isDelivered", .boolean).notNull().defaults(to: false)
        t.column("isRead", .boolean).notNull().defaults(to: false)
        t.column("isSent", .boolean).notNull().defaults(to: false)
        t.column("sendAttempts", .integer).notNull().defaults(to: 0)
        t.column("error", .text)
        t.column("processingState", .text).notNull()
        t.column("gapBefore", .boolean).notNull().defaults(to: false)
        t.column("plaintextExpired", .boolean).notNull().defaults(to: false)
      }
      
      try db.create(table: "MLSMemberModel") { t in
        t.primaryKey("memberID", .text).notNull()
        t.column("conversationID", .text).notNull().references("MLSConversationModel", onDelete: .cascade)
        t.column("currentUserDID", .text).notNull()
        t.column("did", .text).notNull()
        t.column("handle", .text)
        t.column("displayName", .text)
        t.column("leafIndex", .integer).notNull()
        t.column("credentialData", .blob)
        t.column("signaturePublicKey", .blob)
        t.column("addedAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
        t.column("removedAt", .datetime)
        t.column("isActive", .boolean).notNull().defaults(to: true)
        t.column("role", .text).notNull()
        t.column("capabilities", .blob)
      }
      
      try db.create(table: "MLSKeyPackageModel") { t in
        t.primaryKey("keyPackageID", .text).notNull()
        t.column("currentUserDID", .text).notNull()
        t.column("keyPackageData", .blob).notNull()
        t.column("credentialData", .blob).notNull()
        t.column("createdAt", .datetime).notNull()
        t.column("expiresAt", .datetime)
        t.column("isPublished", .boolean).notNull().defaults(to: false)
        t.column("isUsed", .boolean).notNull().defaults(to: false)
      }
      
      try db.create(table: "MLSEpochKeyModel") { t in
        t.primaryKey("epochKeyID", .text).notNull()
        t.column("conversationID", .text).notNull().references("MLSConversationModel", onDelete: .cascade)
        t.column("currentUserDID", .text).notNull()
        t.column("epoch", .integer).notNull()
        t.column("keyMaterial", .blob).notNull()
        t.column("createdAt", .datetime).notNull()
        t.column("expiresAt", .datetime)
        t.column("isActive", .boolean).notNull().defaults(to: true)
      }
      
      try db.create(table: "MLSMessageReactionModel") { t in
        t.primaryKey("reactionID", .text).notNull()
        t.column("messageID", .text).notNull().references("MLSMessageModel", onDelete: .cascade)
        t.column("conversationID", .text).notNull()
        t.column("currentUserDID", .text).notNull()
        t.column("actorDID", .text).notNull()
        t.column("emoji", .text).notNull()
        t.column("action", .text).notNull()
        t.column("timestamp", .datetime).notNull()
      }
      
      try db.create(table: "MLSStorageBlobModel") { t in
        t.primaryKey("blobID", .text).notNull()
        t.column("conversationID", .text).references("MLSConversationModel", onDelete: .cascade)
        t.column("currentUserDID", .text).notNull()
        t.column("blobType", .text).notNull()
        t.column("blobData", .blob).notNull()
        t.column("mimeType", .text).notNull()
        t.column("size", .integer).notNull()
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
      }

      try db.create(table: "MLSReportModel") { t in
        t.primaryKey("id", .text).notNull()
        t.column("convo_id", .text).notNull().references("MLSConversationModel", onDelete: .cascade)
        t.column("reporter_did", .text).notNull()
        t.column("reported_did", .text).notNull()
        t.column("reason", .text).notNull()
        t.column("details", .text)
        t.column("status", .text).notNull().defaults(to: "pending")
        t.column("action", .text)
        t.column("resolution_notes", .text)
        t.column("created_at", .datetime).notNull()
        t.column("resolved_at", .datetime)
      }

      try db.create(table: "MLSAdminRosterModel") { t in
        t.primaryKey("convo_id", .text).notNull().references("MLSConversationModel", onDelete: .cascade)
        t.column("version", .integer).notNull()
        t.column("roster_hash", .text).notNull()
        t.column("encrypted_roster", .blob).notNull()
        t.column("updated_at", .datetime).notNull()
      }
    }

    // MARK: v2 - Performance indexes
    migrator.registerMigration("v2_performance_indexes") { db in
      // MLSMessageModel indexes - frequently queried by conversation and timestamp
      try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_message_conversation_timestamp
        ON MLSMessageModel(conversationID, timestamp DESC);
      """)

      try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_message_user
        ON MLSMessageModel(currentUserDID);
      """)

      try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_message_sender
        ON MLSMessageModel(senderID);
      """)

      // MLSConversationModel indexes - frequently queried by user and activity
      try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_conversation_user_active
        ON MLSConversationModel(currentUserDID, isActive, lastMessageAt DESC);
      """)

      try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_conversation_updated
        ON MLSConversationModel(updatedAt DESC);
      """)

      // MLSMemberModel indexes - frequently queried by conversation
      try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_member_conversation
        ON MLSMemberModel(conversationID);
      """)

      try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_member_did
        ON MLSMemberModel(did);
      """)

      // MLSEpochKeyModel indexes - queried by conversation and epoch
      try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_epoch_conversation_epoch
        ON MLSEpochKeyModel(conversationID, epoch DESC);
      """)

      try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_epoch_created
        ON MLSEpochKeyModel(createdAt DESC);
      """)

      // MLSMessageReactionModel indexes - queried by message
      try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_reaction_message
        ON MLSMessageReactionModel(messageID);
      """)

      // MLSStorageBlobModel indexes - queried by user and type
      try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_blob_user_type
        ON MLSStorageBlobModel(currentUserDID, blobType);
      """)

      // MLSReportModel indexes - frequently queried by conversation and status
      try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_reports_convo
        ON MLSReportModel(convo_id);
      """)

      try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_reports_status
        ON MLSReportModel(status);
      """)

      try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_reports_convo_status
        ON MLSReportModel(convo_id, status, created_at DESC);
      """)

      // MLSAdminRosterModel - primary key index already covers convo_id lookups
    }

    // MARK: v3 - Consumption tracking
    migrator.registerMigration("v3_consumption_tracking") { db in
      // Create consumption record table
      try db.create(table: "MLSConsumptionRecordModel") { t in
        t.primaryKey("recordID", .text).notNull()
        t.column("currentUserDID", .text).notNull()
        t.column("timestamp", .datetime).notNull()
        t.column("packagesConsumed", .integer).notNull()
        t.column("operation", .text).notNull()
        t.column("context", .text)
      }

      // Indexes for consumption queries
      try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_consumption_user_timestamp
        ON MLSConsumptionRecordModel(currentUserDID, timestamp DESC);
      """)

      try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_consumption_operation
        ON MLSConsumptionRecordModel(currentUserDID, operation);
      """)
    }

    // Execute all migrations
    try migrator.migrate(db)
  }

  /// Set iOS Data Protection on database file
  private func setFileProtection(for fileURL: URL) throws {
    do {
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.complete],
        ofItemAtPath: fileURL.path
      )
    } catch {
      throw MLSSQLCipherError.fileProtectionFailed(underlying: error)
    }
  }

  /// Exclude database from iCloud/iTunes backup
  private func excludeFromBackup(_ fileURL: URL) throws {
    var url = fileURL
    do {
      var resourceValues = URLResourceValues()
      resourceValues.isExcludedFromBackup = true
      try url.setResourceValues(resourceValues)
    } catch {
      throw MLSSQLCipherError.backupExclusionFailed(underlying: error)
    }
  }

  /// Get database file path for user
  private func databasePath(for userDID: String) -> URL {
    // Sanitize DID for filesystem (replace : with -)
    let sanitizedDID = userDID.replacingOccurrences(of: ":", with: "-")

    // Create filename: mls_messages_{DID}.db
    let filename = "mls_messages_\(sanitizedDID).\(fileExtension)"

    return databaseDirectory.appendingPathComponent(filename)
  }
}


// MARK: - Debug Helpers

#if DEBUG
extension MLSGRDBManager {
  /// List all database files
  func listDatabases() -> [String] {
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: databaseDirectory.path) else {
      return []
    }

    return files.filter { $0.hasSuffix(".\(fileExtension)") }
  }

  /// Get table statistics for a user's database
  func getTableStats(for userDID: String) async throws -> [String: Int] {
    let db = try await getDatabaseQueue(for: userDID)

    return try await db.read { database in
      var stats: [String: Int] = [:]

      // Get all table names
      let tables = try String.fetchAll(
        database,
        sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';"
      )

      // Count rows in each table
      for table in tables {
        if let count = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table);") {
          stats[table] = count
        }
      }

      return stats
    }
  }

  /// Export database to unencrypted file (for debugging only)
  func exportUnencrypted(for userDID: String, to destinationPath: String) async throws {
    let db = try await getDatabaseQueue(for: userDID)

    try await db.write { database in
      // Use SQLCipher's ATTACH and export
      try database.execute(sql: """
        ATTACH DATABASE '\(destinationPath)' AS plaintext KEY '';
        SELECT sqlcipher_export('plaintext');
        DETACH DATABASE plaintext;
      """)
    }

    logger.warning("⚠️ Exported UNENCRYPTED database to \(destinationPath) - DELETE after debugging!")
  }

  /// Verify database encryption
  func verifyEncryption(for userDID: String) async throws -> Bool {
    let db = try await getDatabaseQueue(for: userDID)

    // Try to query sqlite_master (should succeed with correct key)
    return try await db.read { database in
      _ = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sqlite_master;")
      return true
    }
  }

  /// Run integrity check on database
  func checkIntegrity(for userDID: String) async throws -> Bool {
    let db = try await getDatabaseQueue(for: userDID)

    return try await db.read { database in
      if let result = try String.fetchOne(database, sql: "PRAGMA integrity_check;") {
        return result == "ok"
      }
      return false
    }
  }

  /// Optimize database (vacuum and analyze)
  func optimize(for userDID: String) async throws {
    let db = try await getDatabaseQueue(for: userDID)

    try await db.write { database in
      try database.execute(sql: "VACUUM;")
      try database.execute(sql: "ANALYZE;")
    }

    logger.info("Optimized database for user: \(userDID, privacy: .private)")
  }
}
#endif
