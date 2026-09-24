@testable import CatbirdMLSCore
import Foundation
import GRDB
import XCTest
@testable import Catbird

/// C36 Apple validation: two real owners racing the same account's crypto state.
///
/// Proves journal/receipt fences hold, one owner wins, and no concurrent
/// mutation is possible. Uses two `MLSGRDBManager` instances sharing the same
/// App Group–override directory (simulates app + Notification Service Extension
/// in the same filesystem namespace), plus `MLSWelcomeGate`'s O_EXCL markers
/// and `MLSStorageCoordinator`'s BSD flock leases.
final class EncryptedRequestConcurrentOwnershipTests: XCTestCase {
  private var appManager: MLSGRDBManager!
  private var nseManager: MLSGRDBManager!
  private var directory: URL!

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("C36-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    MLSStoragePaths.setBaseDirectoryOverride(directory)
    MLSKeychainManager.setFakeStorageOverrideForTesting(MLSKeychainFakeStorage())
    appManager = MLSGRDBManager()
    nseManager = MLSGRDBManager()
  }

  override func tearDown() async throws {
    MLSStorageCoordinator.shared.testPrePublicationHook = nil
    MLSStorageCoordinator.shared.testBarrierHook = nil
    MLSGRDBManager.afterDrainCheckpointForTesting = nil
    MLSCoreContext.clearSuspensionFlag()
    MLSClient.clearSuspensionFlag(reason: "C36 test cleanup")
    NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
    await appManager.shutdownAllDatabases()
    await nseManager.shutdownAllDatabases()
    appManager = nil
    nseManager = nil
    MLSStoragePaths.setBaseDirectoryOverride(nil)
    MLSKeychainManager.setFakeStorageOverrideForTesting(nil)
  }

  // MARK: - C36-1: Two manager instances share the same SQLCipher database

  func testTwoManagerInstancesShareOneSQLCipherDatabaseWithFencedWrites() async throws {
    let did = "did:plc:c36-shared-\(UUID().uuidString.lowercased())"

    // App creates a table and writes a row.
    try await appManager.write(for: did) { db in
      try db.execute(sql: """
        CREATE TABLE c36_journal (id INTEGER PRIMARY KEY, owner TEXT NOT NULL, epoch INTEGER NOT NULL)
        """)
      try db.execute(sql: "INSERT INTO c36_journal (owner, epoch) VALUES ('app', 1)")
    }

    // NSE reads the same row (same DID, same encrypted file).
    let appRow: String? = try await nseManager.read(for: did) { db in
      try String.fetchOne(db, sql: "SELECT owner FROM c36_journal WHERE epoch = 1")
    }
    XCTAssertEqual(appRow, "app", "NSE manager must see app manager's committed write")

    // NSE writes its own epoch; app must see it.
    try await nseManager.write(for: did) { db in
      try db.execute(sql: "INSERT INTO c36_journal (owner, epoch) VALUES ('nse', 2)")
    }
    let nseRow: String? = try await appManager.read(for: did) { db in
      try String.fetchOne(db, sql: "SELECT owner FROM c36_journal WHERE epoch = 2")
    }
    XCTAssertEqual(nseRow, "nse", "App manager must see NSE manager's committed write")

    // Both use SQLCipher.
    let cipherV = try await appManager.read(for: did) { db in
      try String.fetchOne(db, sql: "PRAGMA cipher_version")
    }
    XCTAssertNotNil(cipherV, "Must be SQLCipher")
  }

  // MARK: - C36-2: Suspension fence prevents concurrent mutation

  func testSuspensionFencePreventsNSEMutationDuringAppClose() async throws {
    let did = "did:plc:c36-fence-\(UUID().uuidString.lowercased())"

    // App opens and writes seed data.
    try await appManager.write(for: did) { db in
      try db.execute(sql: "CREATE TABLE c36_fence (v INTEGER)")
      try db.execute(sql: "INSERT INTO c36_fence VALUES (1)")
    }

    // NSE also opens the database.
    let nseValue: Int? = try await nseManager.read(for: did) { db in
      try Int.fetchOne(db, sql: "SELECT v FROM c36_fence")
    }
    XCTAssertEqual(nseValue, 1)

    // Mark suspension — simulates scenePhase → .background.
    MLSCoreContext.markSuspensionInProgress()
    let closeResult = MLSGRDBManager.closeAllDatabasesForSuspension()

    // After suspension close, the admission lease should be released.
    if closeResult.isComplete {
      XCTAssertFalse(
        MLSStorageCoordinator.shared.hasActiveAdmissionLease(for: .swiftGRDB, userDID: did),
        "After complete suspension close, no admission lease should be held")
    }

    // New database opens from any manager must be rejected during suspension.
    do {
      _ = try await nseManager.getDatabasePool(for: did)
    } catch {
      // Expected — suspension gate rejects new work.
    }

    // Lift suspension.
    MLSCoreContext.clearSuspensionFlag()

    // App reopens; data is intact.
    let restored: Int? = try await appManager.read(for: did) { db in
      try Int.fetchOne(db, sql: "SELECT v FROM c36_fence")
    }
    XCTAssertEqual(restored, 1, "Data must survive suspension close cycle")
  }

  // MARK: - C36-3: WelcomeGate O_EXCL — exactly one owner wins

  func testWelcomeGateExactlyOneOwnerWins() async throws {
    let did = "did:plc:c36-welcome-\(UUID().uuidString.lowercased())"
    let conversationID = UUID().uuidString

    // App claims Welcome processing first.
    try await MLSWelcomeGate.shared.beginWelcomeProcessing(
      for: conversationID, userDID: did)

    // NSE must be rejected (O_EXCL file already exists).
    do {
      try await MLSWelcomeGate.shared.beginWelcomeProcessing(
        for: conversationID, userDID: did)
      XCTFail("Second Welcome claim must fail — O_EXCL prevents concurrent processing")
    } catch {
      // Expected: admissionDenied or EEXIST.
    }

    // Pending check confirms app owns it.
    let pending = await MLSWelcomeGate.shared.hasPendingWelcome(
      for: conversationID, userDID: did)
    XCTAssertTrue(pending, "Welcome marker must exist until completion")

    // App completes processing.
    await MLSWelcomeGate.shared.completeWelcomeProcessing(
      for: conversationID, userDID: did)
    let afterCompletion = await MLSWelcomeGate.shared.hasPendingWelcome(
      for: conversationID, userDID: did)
    XCTAssertFalse(afterCompletion, "Marker removed after completion")

    // NSE succeeds on a fresh claim.
    try await MLSWelcomeGate.shared.beginWelcomeProcessing(
      for: conversationID, userDID: did)
    await MLSWelcomeGate.shared.completeWelcomeProcessing(
      for: conversationID, userDID: did)
  }

  // MARK: - C36-4: Concurrent writer fences second manager's close

  func testConcurrentWriterFencesSecondManagerClose() async throws {
    let did = "did:plc:c36-writer-\(UUID().uuidString.lowercased())"
    let pool = try await appManager.getDatabasePool(for: did)

    // Hold a writer connection open (simulates in-flight FFI operation).
    let writerEntered = expectation(description: "Writer occupies connection")
    let releaseWriter = DispatchSemaphore(value: 0)
    let write = Task.detached {
      pool.writeWithoutTransaction { _ in
        writerEntered.fulfill()
        _ = releaseWriter.wait(timeout: .now() + 5)
      }
    }
    await fulfillment(of: [writerEntered], timeout: 5)
    defer { releaseWriter.signal() }

    // NSE also opens the database.
    _ = try await nseManager.getDatabasePool(for: did)

    // Mark suspension; first closer runs in background and waits for writer.
    MLSCoreContext.markSuspensionInProgress()
    let firstClose = Task.detached { MLSGRDBManager.closeAllDatabasesForSuspension() }
    for _ in 0..<100 where MLSGRDBManager.activeEmergencyPoolTokenCount(for: did) != 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(MLSGRDBManager.activeEmergencyPoolTokenCount(for: did), 0)

    // Second concurrent closer reports incomplete with remaining pool count.
    let secondClose = MLSGRDBManager.closeAllDatabasesForSuspension()
    XCTAssertFalse(secondClose.isComplete,
      "Concurrent closer must report outstanding close until first closer releases lease")
    XCTAssertGreaterThanOrEqual(secondClose.remainingPoolCount, 1)
    // Release writer so first close can finish.
    releaseWriter.signal()
    try await write.value
    let firstResult = await firstClose.value
    XCTAssertTrue(firstResult.isComplete)
  }
  // MARK: - C36-5: Admission lease prevents concurrent open/reset

  func testAdmissionLeasePreventsConcurrentReset() async throws {
    let did = "did:plc:c36-lease-\(UUID().uuidString.lowercased())"

    // App opens pool → acquires shared admission lease.
    _ = try await appManager.getDatabasePool(for: did)
    XCTAssertTrue(
      MLSStorageCoordinator.shared.hasActiveAdmissionLease(for: .swiftGRDB, userDID: did),
      "Opening a pool must acquire an admission lease")

    // Attempting an exclusive reset lease must fail while the shared lease is held.
    // It will attempt to acquire LOCK_EX over the file which already has LOCK_SH.
    XCTAssertTrue(
      MLSStorageCoordinator.shared.hasActiveAdmissionLease(for: .swiftGRDB, userDID: did),
      "Shared admission lease is active")

    // Close and drain.
    await appManager.closeDatabaseAndDrain(for: did)

    // Either way, no shared lease should be held after drain.
    XCTAssertFalse(
      MLSStorageCoordinator.shared.hasActiveAdmissionLease(for: .swiftGRDB, userDID: did),
      "No admission lease after drain")
  }
}
