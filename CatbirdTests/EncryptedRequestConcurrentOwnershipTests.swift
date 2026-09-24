@testable import CatbirdMLSCore
import Foundation
import GRDB
import XCTest
@testable import Catbird

/// C36 Apple validation: two real owners racing the same account's crypto state.
///
/// Proves journal/receipt fences hold, one owner wins, and no concurrent
/// mutation is possible. Uses two `MLSGRDBManager` instances sharing the same
/// App Group–override directory (simulating App + Notification Service Extension
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

  // MARK: - C36-1: Barrier-synchronized WelcomeGate race enforces single winner

  func testConcurrentRaceOnWelcomeGateEnforcesSingleWinner() async throws {
    let did = "did:plc:c36-welcome-\(UUID().uuidString.lowercased())"
    let conversationID = UUID().uuidString

    // Set up barrier to release two concurrent tasks simultaneously.
    let barrier = DispatchSemaphore(value: 0)
    let winnerCounter = NSLock()
    nonisolated(unsafe) var winners = 0
    nonisolated(unsafe) var losers = 0

    let taskApp = Task.detached {
      _ = barrier.wait(timeout: .now() + 5)
      do {
        try await MLSWelcomeGate.shared.beginWelcomeProcessing(
          for: conversationID, userDID: did)
        winnerCounter.withLock { winners += 1 }
      } catch {
        winnerCounter.withLock { losers += 1 }
      }
    }

    let taskNSE = Task.detached {
      _ = barrier.wait(timeout: .now() + 5)
      do {
        try await MLSWelcomeGate.shared.beginWelcomeProcessing(
          for: conversationID, userDID: did)
        winnerCounter.withLock { winners += 1 }
      } catch {
        winnerCounter.withLock { losers += 1 }
      }
    }

    // Release both tasks into the gate at the exact same instant.
    barrier.signal()
    barrier.signal()

    _ = await taskApp.value
    _ = await taskNSE.value

    // Single-winner assertion: exactly one won, exactly one lost.
    XCTAssertEqual(winners, 1, "Exactly one process can win the Welcome processing race")
    XCTAssertEqual(losers, 1, "The second concurrent entrant MUST be rejected via O_EXCL")

    // The winner's pending marker remains active.
    let pending = await MLSWelcomeGate.shared.hasPendingWelcome(
      for: conversationID, userDID: did)
    XCTAssertTrue(pending, "Winner's Welcome marker must exist until completion")

    // Completing processing removes the marker.
    await MLSWelcomeGate.shared.completeWelcomeProcessing(
      for: conversationID, userDID: did)
    let afterCompletion = await MLSWelcomeGate.shared.hasPendingWelcome(
      for: conversationID, userDID: did)
    XCTAssertFalse(afterCompletion, "Welcome marker must be cleared after completion")
  }

  // MARK: - C36-2: Concurrent contention on journal state in SQLCipher

  func testTwoOwnersConcurrentContentionOnJournalState() async throws {
    let did = "did:plc:c36-shared-\(UUID().uuidString.lowercased())"

    // App creates the shared journal table.
    try await appManager.write(for: did) { db in
      try db.execute(sql: """
        CREATE TABLE c36_journal (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          owner TEXT NOT NULL,
          epoch INTEGER NOT NULL,
          created_at DATETIME NOT NULL
        )
        """)
    }

    // Two concurrent owners (App and NSE) race to write epochs.
    let barrier = DispatchSemaphore(value: 0)
    let appWrite = Task.detached {
      _ = barrier.wait(timeout: .now() + 5)
      try await self.appManager.write(for: did) { db in
        try db.execute(sql: "INSERT INTO c36_journal (owner, epoch, created_at) VALUES ('app', 1, datetime('now'))")
      }
    }

    let nseWrite = Task.detached {
      _ = barrier.wait(timeout: .now() + 5)
      try await self.nseManager.write(for: did) { db in
        try db.execute(sql: "INSERT INTO c36_journal (owner, epoch, created_at) VALUES ('nse', 2, datetime('now'))")
      }
    }

    barrier.signal()
    barrier.signal()

    try await appWrite.value
    try await nseWrite.value

    // Both writes must be present and distinct in the shared encrypted database.
    let rows: Int? = try await appManager.read(for: did) { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM c36_journal")
    }
    XCTAssertEqual(rows, 2, "Both concurrent writes must commit cleanly under WAL mode")

    let owners: [String] = try await nseManager.read(for: did) { db in
      try String.fetchAll(db, sql: "SELECT owner FROM c36_journal ORDER BY epoch ASC")
    }
    XCTAssertEqual(owners, ["app", "nse"], "Both owners' writes must be preserved without corruption")

    // Both operated over SQLCipher.
    let cipherV = try await appManager.read(for: did) { db in
      try String.fetchOne(db, sql: "PRAGMA cipher_version")
    }
    XCTAssertNotNil(cipherV, "Must be SQLCipher")
  }

  // MARK: - C36-3: Suspension fence strictly blocks new admissions

  func testSuspensionFenceStrictlyBlocksNewAdmissionsAndReleasesLeases() async throws {
    let did = "did:plc:c36-fence-\(UUID().uuidString.lowercased())"

    // App opens and writes seed data.
    try await appManager.write(for: did) { db in
      try db.execute(sql: "CREATE TABLE c36_fence (v INTEGER)")
      try db.execute(sql: "INSERT INTO c36_fence VALUES (1)")
    }

    // NSE reads to establish cached connection.
    let nseValue: Int? = try await nseManager.read(for: did) { db in
      try Int.fetchOne(db, sql: "SELECT v FROM c36_fence")
    }
    XCTAssertEqual(nseValue, 1)

    // Mark suspension: simulates scenePhase -> .background.
    MLSCoreContext.markSuspensionInProgress()
    let closeResult = MLSGRDBManager.closeAllDatabasesForSuspension()

    // Strict assertions: close must be complete, admission leases must be released.
    XCTAssertTrue(closeResult.isComplete, "Suspension close must report complete")
    XCTAssertFalse(
      MLSStorageCoordinator.shared.hasActiveAdmissionLease(for: .swiftGRDB, userDID: did),
      "After complete suspension close, no admission lease should be held")

    // New database opens from any manager MUST be rejected during suspension.
    do {
      _ = try await nseManager.getDatabasePool(for: did)
      XCTFail("New opens must remain blocked during suspension")
    } catch {
      // Expected: suspension gate rejects new work.
    }

    // Lift suspension.
    MLSCoreContext.clearSuspensionFlag()

    // App reopens; data is intact.
    let restored: Int? = try await appManager.read(for: did) { db in
      try Int.fetchOne(db, sql: "SELECT v FROM c36_fence")
    }
    XCTAssertEqual(restored, 1, "Data must survive suspension close cycle")
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

  // MARK: - C36-5: Admission lease strictly blocks exclusive reset

  func testAdmissionLeaseStrictlyBlocksExclusiveReset() async throws {
    let did = "did:plc:c36-lease-\(UUID().uuidString.lowercased())"

    // App opens pool -> acquires shared admission lease.
    _ = try await appManager.getDatabasePool(for: did)
    XCTAssertTrue(
      MLSStorageCoordinator.shared.hasActiveAdmissionLease(for: .swiftGRDB, userDID: did),
      "Opening a pool must acquire an admission lease")

    // Attempting an exclusive reset lease MUST throw because shared admission lease is held!
    do {
      let token = try await MLSStorageCoordinator.shared.acquireExclusiveResetLease(
        for: .swiftGRDB, userDID: did)
      token.release()
      XCTFail("acquireExclusiveResetLease MUST fail while shared admission lease is active")
    } catch let error as MLSStorageInitializationError {
      guard case .admissionDenied(let details) = error else {
        return XCTFail("Unexpected storage error while lease held: \(error)")
      }
      XCTAssertTrue(details.contains("Timed out waiting for lock"),
        "Reset must be refused by the flock fence, got: \(details)")
    }

    // Close and drain the database pool.
    await appManager.closeDatabaseAndDrain(for: did)

    // After drain, no shared admission lease is held.
    XCTAssertFalse(
      MLSStorageCoordinator.shared.hasActiveAdmissionLease(for: .swiftGRDB, userDID: did),
      "No admission lease after drain")

    // Now exclusive reset lease CAN be acquired!
    do {
      let token = try await MLSStorageCoordinator.shared.acquireExclusiveResetLease(
        for: .swiftGRDB, userDID: did)
      token.release()
    } catch {
      XCTFail("Exclusive reset lease should be available after drain: \(error)")
    }
  }
}
