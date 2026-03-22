import Testing
import Foundation
import SwiftData
@testable import Catbird

@Suite("Backup System Tests")
struct BackupManagerTests {

  // MARK: - BackupRecord Tests

  @Test("BackupRecord creation with default values")
  func testBackupRecordDefaults() {
    let record = BackupRecord(
      userDID: "did:plc:test123",
      userHandle: "test.bsky.social",
      filePath: "Backups/test.car",
      fileSize: 1024,
      carDataHash: "abc123"
    )

    #expect(record.userDID == "did:plc:test123")
    #expect(record.userHandle == "test.bsky.social")
    #expect(record.filePath == "Backups/test.car")
    #expect(record.fileSize == 1024)
    #expect(record.carDataHash == "abc123")
    #expect(record.status == .inProgress)
    #expect(record.errorMessage == nil)
    #expect(record.isIntegrityValid == false)
    #expect(record.repositorySize == nil)
    #expect(record.recordCount == nil)
    #expect(record.lastVerifiedDate == nil)
  }

  @Test("BackupRecord creation with explicit status")
  func testBackupRecordExplicitStatus() {
    let record = BackupRecord(
      userDID: "did:plc:test123",
      userHandle: "test.bsky.social",
      filePath: "Backups/test.car",
      fileSize: 2048,
      carDataHash: "def456",
      status: .completed,
      repositorySize: 4096,
      recordCount: 150
    )

    #expect(record.status == .completed)
    #expect(record.repositorySize == 4096)
    #expect(record.recordCount == 150)
  }

  @Test("BackupRecord status transitions")
  func testStatusTransitions() {
    let record = BackupRecord(
      userDID: "did:plc:test123",
      userHandle: "test.bsky.social",
      filePath: "Backups/test.car",
      fileSize: 1024,
      carDataHash: "abc123",
      status: .inProgress
    )

    #expect(record.status == .inProgress)

    record.status = .completed
    #expect(record.status == .completed)

    record.status = .verifying
    #expect(record.status == .verifying)

    record.status = .verified
    record.isIntegrityValid = true
    record.lastVerifiedDate = Date()
    #expect(record.status == .verified)
    #expect(record.isIntegrityValid == true)
    #expect(record.lastVerifiedDate != nil)
  }

  @Test("BackupRecord failure status with error message")
  func testFailureStatus() {
    let record = BackupRecord(
      userDID: "did:plc:test123",
      userHandle: "test.bsky.social",
      filePath: "Backups/test.car",
      fileSize: 0,
      carDataHash: "",
      status: .failed,
      errorMessage: "Network connection lost"
    )

    #expect(record.status == .failed)
    #expect(record.errorMessage == "Network connection lost")
  }

  @Test("BackupRecord corrupted status")
  func testCorruptedStatus() {
    let record = BackupRecord(
      userDID: "did:plc:test123",
      userHandle: "test.bsky.social",
      filePath: "Backups/test.car",
      fileSize: 1024,
      carDataHash: "abc123",
      status: .completed
    )

    record.status = .corrupted
    record.errorMessage = "Hash verification failed"
    record.isIntegrityValid = false

    #expect(record.status == .corrupted)
    #expect(record.errorMessage == "Hash verification failed")
    #expect(record.isIntegrityValid == false)
  }

  @Test("BackupRecord formattedFileSize")
  func testFormattedFileSize() {
    let record = BackupRecord(
      userDID: "did:plc:test123",
      userHandle: "test.bsky.social",
      filePath: "Backups/test.car",
      fileSize: 1_048_576, // 1 MB
      carDataHash: "abc123"
    )

    let formatted = record.formattedFileSize
    #expect(formatted.contains("MB") || formatted.contains("1"))
  }

  @Test("BackupRecord ageDescription returns non-empty string")
  func testAgeDescription() {
    let record = BackupRecord(
      userDID: "did:plc:test123",
      userHandle: "test.bsky.social",
      filePath: "Backups/test.car",
      fileSize: 1024,
      carDataHash: "abc123"
    )

    let description = record.ageDescription
    #expect(!description.isEmpty)
  }

  @Test("BackupRecord fullFileURL points to Documents directory")
  func testFullFileURL() {
    let record = BackupRecord(
      userDID: "did:plc:test123",
      userHandle: "test.bsky.social",
      filePath: "Backups/test-backup.car",
      fileSize: 1024,
      carDataHash: "abc123"
    )

    let url = record.fullFileURL
    #expect(url.lastPathComponent == "test-backup.car")
    #expect(url.pathComponents.contains("Backups"))
  }

  // MARK: - BackupConfiguration Tests

  @Test("BackupConfiguration default values")
  func testConfigDefaults() {
    let config = BackupConfiguration(userDID: "did:plc:test123")

    #expect(config.userDID == "did:plc:test123")
    #expect(config.autoBackupEnabled == false)
    #expect(config.backupFrequencyHours == 168) // Weekly
    #expect(config.maxBackupsToKeep == 5)
    #expect(config.lastAutoBackupDate == nil)
    #expect(config.backupOnLaunch == false)
    #expect(config.verifyIntegrityAfterBackup == true)
    #expect(config.showBackupNotifications == true)
    #expect(config.minimumBackupInterval == 3600)
    #expect(config.autoParseAfterBackup == true)
  }

  @Test("BackupConfiguration needsAutomaticBackup when disabled")
  func testNeedsBackupDisabled() {
    let config = BackupConfiguration(userDID: "did:plc:test123", autoBackupEnabled: false)

    #expect(config.needsAutomaticBackup == false)
  }

  @Test("BackupConfiguration needsAutomaticBackup when never backed up")
  func testNeedsBackupNeverBackedUp() {
    let config = BackupConfiguration(
      userDID: "did:plc:test123",
      autoBackupEnabled: true,
      lastAutoBackupDate: nil
    )

    #expect(config.needsAutomaticBackup == true)
  }

  @Test("BackupConfiguration needsAutomaticBackup when interval elapsed")
  func testNeedsBackupIntervalElapsed() {
    let twoDaysAgo = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
    let config = BackupConfiguration(
      userDID: "did:plc:test123",
      autoBackupEnabled: true,
      backupFrequencyHours: 24, // Daily
      lastAutoBackupDate: twoDaysAgo
    )

    #expect(config.needsAutomaticBackup == true)
  }

  @Test("BackupConfiguration needsAutomaticBackup when interval not elapsed")
  func testNeedsBackupIntervalNotElapsed() {
    let oneHourAgo = Calendar.current.date(byAdding: .hour, value: -1, to: Date())!
    let config = BackupConfiguration(
      userDID: "did:plc:test123",
      autoBackupEnabled: true,
      backupFrequencyHours: 24, // Daily
      lastAutoBackupDate: oneHourAgo
    )

    #expect(config.needsAutomaticBackup == false)
  }

  @Test("BackupConfiguration canCreateNewBackup when never backed up")
  func testCanCreateNeverBackedUp() {
    let config = BackupConfiguration(userDID: "did:plc:test123")

    #expect(config.canCreateNewBackup == true)
  }

  @Test("BackupConfiguration canCreateNewBackup respects minimum interval")
  func testCanCreateRespectsInterval() {
    let thirtyMinutesAgo = Calendar.current.date(byAdding: .minute, value: -30, to: Date())!
    let config = BackupConfiguration(
      userDID: "did:plc:test123",
      lastAutoBackupDate: thirtyMinutesAgo,
      minimumBackupInterval: 3600 // 1 hour
    )

    #expect(config.canCreateNewBackup == false)
  }

  @Test("BackupConfiguration canCreateNewBackup after interval passes")
  func testCanCreateAfterInterval() {
    let twoHoursAgo = Calendar.current.date(byAdding: .hour, value: -2, to: Date())!
    let config = BackupConfiguration(
      userDID: "did:plc:test123",
      lastAutoBackupDate: twoHoursAgo,
      minimumBackupInterval: 3600 // 1 hour
    )

    #expect(config.canCreateNewBackup == true)
  }

  // MARK: - BackupStatus Tests

  @Test("BackupStatus displayName values")
  func testStatusDisplayNames() {
    #expect(BackupStatus.inProgress.displayName == "In Progress")
    #expect(BackupStatus.completed.displayName == "Completed")
    #expect(BackupStatus.failed.displayName == "Failed")
    #expect(BackupStatus.verifying.displayName == "Verifying")
    #expect(BackupStatus.verified.displayName == "Verified")
    #expect(BackupStatus.corrupted.displayName == "Corrupted")
  }

  @Test("BackupStatus systemImage values are non-empty")
  func testStatusSystemImages() {
    for status in BackupStatus.allCases {
      #expect(!status.systemImage.isEmpty, "systemImage should not be empty for \(status)")
    }
  }

  @Test("BackupStatus color values")
  func testStatusColors() {
    #expect(BackupStatus.inProgress.color == "blue")
    #expect(BackupStatus.verifying.color == "blue")
    #expect(BackupStatus.completed.color == "green")
    #expect(BackupStatus.verified.color == "green")
    #expect(BackupStatus.failed.color == "red")
    #expect(BackupStatus.corrupted.color == "red")
  }

  // MARK: - BackupError Tests

  @Test("BackupError descriptions are non-empty")
  func testErrorDescriptions() {
    let errors: [BackupError] = [
      .modelContextNotAvailable,
      .backupInProgress,
      .tooSoonForNewBackup,
      .repositoryFetchFailed,
      .backupFileNotFound,
      .integrityCheckFailed,
      .invalidUserDID,
      .invalidCarData,
    ]

    for error in errors {
      #expect(error.errorDescription != nil, "errorDescription should not be nil for \(error)")
      #expect(!error.errorDescription!.isEmpty, "errorDescription should not be empty for \(error)")
    }
  }

  // MARK: - BackupModelActor Tests

  @Test("BackupModelActor save and fetch round-trip")
  func testActorSaveAndFetch() async throws {
    let container = try makeInMemoryContainer()
    let actor = BackupModelActor(modelContainer: container)

    let record = BackupRecord(
      userDID: "did:plc:testactor",
      userHandle: "testactor.bsky.social",
      filePath: "Backups/actor-test.car",
      fileSize: 2048,
      carDataHash: "hash123",
      status: .completed
    )

    try await actor.saveBackupRecord(record)

    let fetched = try await actor.fetchBackupRecords(for: "did:plc:testactor")
    #expect(fetched.count == 1)
    #expect(fetched.first?.userDID == "did:plc:testactor")
    #expect(fetched.first?.status == .completed)
  }

  @Test("BackupModelActor filters records by DID")
  func testActorDIDFiltering() async throws {
    let container = try makeInMemoryContainer()
    let actor = BackupModelActor(modelContainer: container)

    let record1 = BackupRecord(
      userDID: "did:plc:user1",
      userHandle: "user1.bsky.social",
      filePath: "Backups/user1.car",
      fileSize: 1024,
      carDataHash: "hash1",
      status: .completed
    )

    let record2 = BackupRecord(
      userDID: "did:plc:user2",
      userHandle: "user2.bsky.social",
      filePath: "Backups/user2.car",
      fileSize: 2048,
      carDataHash: "hash2",
      status: .completed
    )

    let record3 = BackupRecord(
      userDID: "did:plc:user1",
      userHandle: "user1.bsky.social",
      filePath: "Backups/user1-2.car",
      fileSize: 3072,
      carDataHash: "hash3",
      status: .verified
    )

    try await actor.saveBackupRecord(record1)
    try await actor.saveBackupRecord(record2)
    try await actor.saveBackupRecord(record3)

    let user1Records = try await actor.fetchBackupRecords(for: "did:plc:user1")
    #expect(user1Records.count == 2)

    let user2Records = try await actor.fetchBackupRecords(for: "did:plc:user2")
    #expect(user2Records.count == 1)

    let noRecords = try await actor.fetchBackupRecords(for: "did:plc:unknown")
    #expect(noRecords.isEmpty)
  }

  @Test("BackupModelActor delete removes record")
  func testActorDelete() async throws {
    let container = try makeInMemoryContainer()
    let actor = BackupModelActor(modelContainer: container)

    let record = BackupRecord(
      userDID: "did:plc:delete-test",
      userHandle: "delete.bsky.social",
      filePath: "Backups/delete.car",
      fileSize: 512,
      carDataHash: "hash-delete",
      status: .completed
    )

    try await actor.saveBackupRecord(record)

    let before = try await actor.fetchBackupRecords(for: "did:plc:delete-test")
    #expect(before.count == 1)

    try await actor.deleteBackupRecord(record.id)

    let after = try await actor.fetchBackupRecords(for: "did:plc:delete-test")
    #expect(after.isEmpty)
  }

  @Test("BackupModelActor update modifies record")
  func testActorUpdate() async throws {
    let container = try makeInMemoryContainer()
    let actor = BackupModelActor(modelContainer: container)

    let record = BackupRecord(
      userDID: "did:plc:update-test",
      userHandle: "update.bsky.social",
      filePath: "Backups/update.car",
      fileSize: 1024,
      carDataHash: "hash-update",
      status: .completed
    )

    try await actor.saveBackupRecord(record)

    try await actor.updateBackupRecord(record.id) { rec in
      rec.status = .verified
      rec.isIntegrityValid = true
      rec.lastVerifiedDate = Date()
    }

    let fetched = try await actor.fetchBackupRecords(for: "did:plc:update-test")
    #expect(fetched.first?.status == .verified)
    #expect(fetched.first?.isIntegrityValid == true)
  }

  @Test("BackupModelActor getBackupConfiguration creates default config")
  func testActorGetOrCreateConfig() async throws {
    let container = try makeInMemoryContainer()
    let actor = BackupModelActor(modelContainer: container)

    let config = try await actor.getBackupConfiguration(for: "did:plc:config-test")
    #expect(config.userDID == "did:plc:config-test")
    #expect(config.autoBackupEnabled == false)
    #expect(config.backupFrequencyHours == 168)
  }

  @Test("BackupModelActor getBackupConfiguration returns existing config")
  func testActorReturnsExistingConfig() async throws {
    let container = try makeInMemoryContainer()
    let actor = BackupModelActor(modelContainer: container)

    let first = try await actor.getBackupConfiguration(for: "did:plc:existing-config")
    #expect(first.autoBackupEnabled == false)

    first.autoBackupEnabled = true
    try await actor.updateBackupConfiguration(first)

    let second = try await actor.getBackupConfiguration(for: "did:plc:existing-config")
    #expect(second.autoBackupEnabled == true)
  }

  @Test("BackupModelActor fetchAllBackupRecords returns all users")
  func testActorFetchAll() async throws {
    let container = try makeInMemoryContainer()
    let actor = BackupModelActor(modelContainer: container)

    for i in 1...3 {
      let record = BackupRecord(
        userDID: "did:plc:user\(i)",
        userHandle: "user\(i).bsky.social",
        filePath: "Backups/user\(i).car",
        fileSize: Int64(i * 1024),
        carDataHash: "hash\(i)",
        status: .completed
      )
      try await actor.saveBackupRecord(record)
    }

    let all = try await actor.fetchAllBackupRecords()
    #expect(all.count == 3)
  }

  // MARK: - Helpers

  private func makeInMemoryContainer() throws -> ModelContainer {
    let schema = Schema([
      BackupRecord.self,
      BackupConfiguration.self,
    ])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
  }
}
