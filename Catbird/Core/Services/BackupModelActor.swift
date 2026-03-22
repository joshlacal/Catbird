import Foundation
import SwiftData
import OSLog

/// Actor for thread-safe backup record operations.
/// Ensures consistent access to SwiftData across different contexts.
actor BackupModelActor {

  // MARK: - Properties

  private let modelContainer: ModelContainer
  private let logger = Logger(subsystem: "blue.catbird", category: "BackupModelActor")

  // MARK: - Initialization

  init(modelContainer: ModelContainer) {
    self.modelContainer = modelContainer
    logger.debug("BackupModelActor initialized")
  }

  // MARK: - Backup Record Operations

  /// Save a backup record using a fresh ModelContext
  func saveBackupRecord(_ record: BackupRecord) throws {
    logger.info("Saving backup record: \(record.id)")

    let context = ModelContext(self.modelContainer)
    context.insert(record)
    try context.save()
    context.processPendingChanges()
  }

  /// Fetch backup records for a user using a fresh ModelContext
  func fetchBackupRecords(for userDID: String) throws -> [BackupRecord] {
    logger.info("Fetching backup records for user: \(userDID)")

    let context = ModelContext(self.modelContainer)

    let descriptor = FetchDescriptor<BackupRecord>(
      predicate: #Predicate<BackupRecord> { backupRecord in backupRecord.userDID == userDID },
      sortBy: [SortDescriptor(\.createdDate, order: .reverse)]
    )

    let records = try context.fetch(descriptor)
    logger.info("Found \(records.count) records for user: \(userDID)")

    return records
  }

  /// Fetch all backup records
  func fetchAllBackupRecords() throws -> [BackupRecord] {
    let context = ModelContext(self.modelContainer)

    let descriptor = FetchDescriptor<BackupRecord>(
      sortBy: [SortDescriptor(\.createdDate, order: .reverse)]
    )

    let records = try context.fetch(descriptor)
    logger.info("Fetched \(records.count) total backup records")

    return records
  }

  /// Delete a backup record
  func deleteBackupRecord(_ recordID: UUID) throws {
    let context = ModelContext(self.modelContainer)

    let descriptor = FetchDescriptor<BackupRecord>(
      predicate: #Predicate<BackupRecord> { backupRecord in backupRecord.id == recordID }
    )

    if let record = try context.fetch(descriptor).first {
      context.delete(record)
      try context.save()
      context.processPendingChanges()
      logger.info("Deleted backup record: \(recordID)")
    } else {
      logger.warning("Backup record not found for deletion: \(recordID)")
    }
  }

  /// Update a backup record
  func updateBackupRecord(_ recordID: UUID, updates: (BackupRecord) -> Void) throws {
    let context = ModelContext(self.modelContainer)

    let descriptor = FetchDescriptor<BackupRecord>(
      predicate: #Predicate<BackupRecord> { backupRecord in backupRecord.id == recordID }
    )

    if let record = try context.fetch(descriptor).first {
      updates(record)
      try context.save()
      context.processPendingChanges()
      logger.info("Updated backup record: \(recordID)")
    } else {
      logger.warning("Backup record not found for update: \(recordID)")
    }
  }

  // MARK: - Backup Configuration Operations

  /// Get or create backup configuration for a user
  func getBackupConfiguration(for userDID: String) throws -> BackupConfiguration {
    let context = ModelContext(self.modelContainer)

    let descriptor = FetchDescriptor<BackupConfiguration>(
      predicate: #Predicate<BackupConfiguration> { config in config.userDID == userDID }
    )

    if let existingConfig = try context.fetch(descriptor).first {
      return existingConfig
    } else {
      let newConfig = BackupConfiguration(userDID: userDID)
      context.insert(newConfig)
      try context.save()
      context.processPendingChanges()
      logger.info("Created new backup configuration for user: \(userDID)")
      return newConfig
    }
  }

  /// Update backup configuration
  func updateBackupConfiguration(_ config: BackupConfiguration) throws {
    let context = ModelContext(self.modelContainer)

    let configID = config.id
    let descriptor = FetchDescriptor<BackupConfiguration>(
      predicate: #Predicate<BackupConfiguration> { backupConfig in backupConfig.id == configID }
    )

    if let existingConfig = try context.fetch(descriptor).first {
      existingConfig.autoBackupEnabled = config.autoBackupEnabled
      existingConfig.backupFrequencyHours = config.backupFrequencyHours
      existingConfig.maxBackupsToKeep = config.maxBackupsToKeep
      existingConfig.verifyIntegrityAfterBackup = config.verifyIntegrityAfterBackup
      existingConfig.lastAutoBackupDate = config.lastAutoBackupDate
      existingConfig.autoParseAfterBackup = config.autoParseAfterBackup

      try context.save()
      context.processPendingChanges()
      logger.info("Updated backup configuration for user: \(config.userDID)")
    } else {
      context.insert(config)
      try context.save()
      context.processPendingChanges()
      logger.info("Inserted new backup configuration for user: \(config.userDID)")
    }
  }
}
