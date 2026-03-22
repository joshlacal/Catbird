import Foundation
import SwiftData
import Petrel
import OSLog
import CryptoKit

/// Manages local backup operations for user data.
/// Initialized per-account with a specific userDID and ATProtoClient.
@Observable
final class BackupManager {

  // MARK: - Properties

  private let logger = Logger(subsystem: "blue.catbird", category: "BackupManager")

  /// The user DID this manager operates on
  let userDID: String

  /// The AT Protocol client for fetching repository data
  private let client: ATProtoClient

  /// The model container for SwiftData operations
  private let modelContainer: ModelContainer

  /// Actor for thread-safe backup record persistence
  private let backupActor: BackupModelActor

  /// Optional repository parsing service for auto-parse after backup
  private weak var repositoryParsingService: RepositoryParsingService?

  /// Current backup operation status
  var isBackingUp = false

  /// Progress of current backup (0.0 - 1.0)
  var backupProgress: Double = 0.0

  /// Current backup status message
  var backupStatusMessage: String = ""

  /// Error from last backup attempt
  var lastBackupError: String?

  // MARK: - Initialization

  init(userDID: String, client: ATProtoClient, modelContainer: ModelContainer) {
    self.userDID = userDID
    self.client = client
    self.modelContainer = modelContainer
    self.backupActor = BackupModelActor(modelContainer: modelContainer)
    logger.info("BackupManager initialized for user: \(userDID)")
  }

  /// Set the repository parsing service for auto-parse after backup
  func setRepositoryParsingService(_ service: RepositoryParsingService) {
    self.repositoryParsingService = service
  }

  // MARK: - Public API

  /// Creates a manual backup for the current user
  @MainActor
  func createManualBackup(userHandle: String) async throws -> BackupRecord {
    logger.info("Creating manual backup for user: \(userHandle)")

    guard !isBackingUp else {
      throw BackupError.backupInProgress
    }

    let config = try await getBackupConfiguration()
    if !config.canCreateNewBackup {
      throw BackupError.tooSoonForNewBackup
    }

    return try await performBackup(
      userHandle: userHandle,
      isAutomatic: false
    )
  }

  /// Checks configuration and performs an automatic backup if the interval has elapsed
  @MainActor
  func checkAndPerformAutoBackupIfNeeded(userHandle: String? = nil) async {
    do {
      let config = try await getBackupConfiguration()
      guard config.autoBackupEnabled,
            config.needsAutomaticBackup,
            config.canCreateNewBackup else {
        return
      }

      let handle = userHandle ?? userDID
      logger.info("Auto-backup interval elapsed, performing backup for user: \(handle)")
      _ = try await performBackup(
        userHandle: handle,
        isAutomatic: true
      )
    } catch {
      logger.error("Automatic backup failed: \(error.localizedDescription)")
    }
  }

  /// Gets all backup records for this user
  func getBackupRecords() async throws -> [BackupRecord] {
    let records = try await backupActor.fetchBackupRecords(for: userDID)
    logger.info("Fetched \(records.count) backup records for user: \(self.userDID)")
    return records
  }

  /// Gets backup configuration for this user
  func getBackupConfiguration() async throws -> BackupConfiguration {
    return try await backupActor.getBackupConfiguration(for: userDID)
  }

  /// Updates backup configuration
  func updateBackupConfiguration(_ config: BackupConfiguration) async throws {
    try await backupActor.updateBackupConfiguration(config)
    logger.info("Backup configuration updated for user: \(config.userDID)")
  }

  /// Deletes a backup record and its file
  func deleteBackup(_ record: BackupRecord) async throws {
    let fileURL = record.fullFileURL
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try FileManager.default.removeItem(at: fileURL)
      logger.debug("Deleted backup file: \(fileURL.path)")
    }

    try await backupActor.deleteBackupRecord(record.id)

    logger.info("Deleted backup record: \(record.id)")
  }

  /// Verifies the integrity of a backup
  @MainActor
  func verifyBackupIntegrity(_ record: BackupRecord) async throws {
    logger.info("Verifying backup integrity: \(record.id)")

    record.status = .verifying

    let fileURL = record.fullFileURL
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      record.status = .corrupted
      record.errorMessage = "Backup file not found"
      throw BackupError.backupFileNotFound
    }

    let data = try Data(contentsOf: fileURL)

    guard data.count == record.fileSize else {
      record.status = .corrupted
      record.errorMessage = "File size mismatch"
      throw BackupError.integrityCheckFailed
    }

    let hash = SHA256.hash(data: data)
    let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()

    guard hashString == record.carDataHash else {
      record.status = .corrupted
      record.errorMessage = "Hash verification failed"
      throw BackupError.integrityCheckFailed
    }

    record.status = .verified
    record.lastVerifiedDate = Date()
    record.isIntegrityValid = true
    record.errorMessage = nil

    logger.info("Backup integrity verified successfully: \(record.id)")
  }

  /// Cleans up old backups based on configuration
  func cleanupOldBackups() async throws {
    let config = try await getBackupConfiguration()
    let records = try await getBackupRecords()

    let recordsToDelete = Array(records.dropFirst(config.maxBackupsToKeep))

    for record in recordsToDelete {
      try await deleteBackup(record)
    }

    if !recordsToDelete.isEmpty {
      logger.info("Cleaned up \(recordsToDelete.count) old backups for user: \(self.userDID)")
    }
  }

  // MARK: - Private Methods

  @MainActor
  private func performBackup(
    userHandle: String,
    isAutomatic: Bool
  ) async throws -> BackupRecord {
    logger.info("performBackup started for user: \(userHandle) (\(self.userDID))")

    isBackingUp = true
    backupProgress = 0.0
    backupStatusMessage = "Starting backup..."
    lastBackupError = nil

    defer {
      isBackingUp = false
      backupProgress = 0.0
      backupStatusMessage = ""
    }

    do {
      // Create backup directory if needed
      let backupsDir = getBackupsDirectory()
      try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)

      backupProgress = 0.1
      backupStatusMessage = "Fetching repository data..."

      // Fetch repository data
      let (responseCode, repoData) = try await client.com.atproto.sync.getRepo(
        input: .init(did: DID(didString: userDID), since: nil)
      )

      guard responseCode == 200, let data = repoData else {
        throw BackupError.repositoryFetchFailed
      }

      backupProgress = 0.5
      backupStatusMessage = "Processing backup data..."

      // Generate filename
      let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
      let filename = "backup-\(userHandle)-\(timestamp).car"
      let backupURL = backupsDir.appendingPathComponent(filename)

      // Write CAR data to file
      let carData = data.data
      try carData.write(to: backupURL)

      backupProgress = 0.8
      backupStatusMessage = "Creating backup record..."

      // Calculate hash
      let hash = SHA256.hash(data: carData)
      let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()

      // Create backup record
      let record = BackupRecord(
        userDID: userDID,
        userHandle: userHandle,
        filePath: "Backups/\(filename)",
        fileSize: Int64(carData.count),
        carDataHash: hashString,
        status: .completed,
        repositorySize: Int64(carData.count)
      )

      // Save via actor for thread safety
      try await backupActor.saveBackupRecord(record)
      logger.info("Backup record saved successfully: \(record.id)")

      backupProgress = 0.9
      backupStatusMessage = "Finalizing backup..."

      // Update configuration if automatic backup
      if isAutomatic {
        let config = try await getBackupConfiguration()
        config.lastAutoBackupDate = Date()
        try await backupActor.updateBackupConfiguration(config)
      }

      // Verify integrity if configured
      let config = try await getBackupConfiguration()
      if config.verifyIntegrityAfterBackup {
        try await verifyBackupIntegrity(record)
      }

      // Clean up old backups
      try await cleanupOldBackups()

      // Auto-parse repository if enabled
      if config.autoParseAfterBackup ?? true {
        await triggerRepositoryParsing(for: record)
      }

      backupProgress = 1.0
      backupStatusMessage = "Backup completed successfully"

      logger.info("Backup completed successfully: \(record.id)")

      // Post notification that backup was created
      NotificationCenter.default.post(
        name: NSNotification.Name("BackupCreated"),
        object: nil,
        userInfo: ["backupID": record.id, "userDID": userDID]
      )

      return record

    } catch {
      lastBackupError = error.localizedDescription
      logger.error("Backup failed: \(error.localizedDescription)")
      throw error
    }
  }

  private func getBackupsDirectory() -> URL {
    let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    return documentsPath.appendingPathComponent("Backups")
  }

  // MARK: - Repository Parsing Integration

  /// Triggers repository parsing for a backup record
  @MainActor
  private func triggerRepositoryParsing(for backupRecord: BackupRecord) async {
    guard let repositoryParsingService = repositoryParsingService else {
      logger.info("Repository parsing service not available - skipping auto-parse")
      return
    }

    logger.info("Auto-triggering repository parsing for backup \(backupRecord.id)")

    do {
      let repositoryRecord = try await repositoryParsingService.startRepositoryParsing(for: backupRecord)
      logger.info("Repository parsing completed successfully: \(repositoryRecord.id)")

    } catch {
      logger.error("Repository parsing failed: \(error.localizedDescription)")
      // Don't propagate the error - backup was successful even if parsing failed
    }
  }
}

// MARK: - Backup Errors

enum BackupError: LocalizedError {
  case modelContextNotAvailable
  case backupInProgress
  case tooSoonForNewBackup
  case repositoryFetchFailed
  case backupFileNotFound
  case integrityCheckFailed
  case invalidUserDID
  case invalidCarData

  var errorDescription: String? {
    switch self {
    case .modelContextNotAvailable:
      return "Database not available for backup operations"
    case .backupInProgress:
      return "A backup is already in progress"
    case .tooSoonForNewBackup:
      return "Please wait before creating another backup"
    case .repositoryFetchFailed:
      return "Failed to fetch repository data from server"
    case .backupFileNotFound:
      return "Backup file not found on disk"
    case .integrityCheckFailed:
      return "Backup integrity verification failed"
    case .invalidUserDID:
      return "Invalid user identifier"
    case .invalidCarData:
      return "Invalid CAR file data"
    }
  }
}
