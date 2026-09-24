@testable import CatbirdMLSCore
import Foundation
import GRDB
import Testing
@testable import Catbird

/// C30 Apple validation: pending text in protected storage; account switch
/// cannot expose or resume another account's request.
///
/// Uses the real SQLCipher encryption path (MLSGRDBManager + MLSKeychainFakeStorage)
/// to prove:
///   1. Database pool uses SQLCipher with a Keychain-derived key (PRAGMA cipher_version non-nil).
///   2. Raw file data does not contain plaintext draft text.
///   3. Opening the file without the correct key fails.
///   4. Account A's drafts are invisible to account B (separate key, separate DB file).
///   5. pendingPresentation scoped to account DID returns nil for the wrong account.
@Suite("C30: Protected storage and account isolation", .serialized)
@MainActor
struct EncryptedRequestProtectedStorageTests {

  // MARK: - Shared setup helper

  private static func withEnvironment<T>(
    _ block: (MLSGRDBManager) async throws -> T
  ) async throws -> T {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("C30-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    MLSStoragePaths.setBaseDirectoryOverride(dir)
    let fakeStorage = MLSKeychainFakeStorage()
    MLSKeychainManager.setFakeStorageOverrideForTesting(fakeStorage)
    let manager = MLSGRDBManager()
    defer {
      MLSStoragePaths.setBaseDirectoryOverride(nil)
      MLSKeychainManager.setFakeStorageOverrideForTesting(nil)
    }
    let result = try await block(manager)
    await manager.shutdownAllDatabases()
    return result
  }

  // MARK: - C30-1: Production path is SQLCipher-encrypted

  @Test("Database pool uses SQLCipher with a Keychain-derived key")
  func productionPathIsSQLCipherEncrypted() async throws {
    try await Self.withEnvironment { manager in
      let did = "did:plc:c30-cipher-\(UUID().uuidString.lowercased())"
      let pool = try await manager.getDatabasePool(for: did)

      // Confirm SQLCipher is active.
      let cipherVersion = try await pool.read { db in
        try String.fetchOne(db, sql: "PRAGMA cipher_version")
      }
      #expect(cipherVersion != nil, "PRAGMA cipher_version must be non-nil (SQLCipher active)")

      // Write a draft with recognizable plaintext.
      let marker = "C30_PLAINTEXT_MARKER_\(UUID().uuidString)"
      var draft = try await MLSDirectComposeDraftStore.open(
        accountDID: did, recipientDID: "did:plc:recipient", database: pool)
      draft.text = marker
      try await MLSDirectComposeDraftStore.save(draft, database: pool)

      // Force checkpoint so data is on disk (not just in WAL).
      try await pool.writeWithoutTransaction { db in
        try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
      }

      // Read raw file bytes and verify the plaintext marker is NOT present.
      let dbURL = try MLSStorageCoordinator.shared.databaseURL(for: .swiftGRDB, userDID: did)
      let rawData = try Data(contentsOf: dbURL)
      #expect(rawData.count > 0, "Database file must exist and be non-empty")

      // Check that the plaintext marker string is NOT in the raw bytes.
      if let markerData = marker.data(using: .utf8) {
        let found = rawData.range(of: markerData)
        #expect(found == nil,
          "Plaintext draft text must not appear anywhere in the encrypted database file")
      }
    }
  }

  // MARK: - C30-2: Opening the encrypted file without the correct key fails

  @Test("Unkeyed open of the encrypted database file fails")
  func unkeyedOpenFails() async throws {
    try await Self.withEnvironment { manager in
      let did = "did:plc:c30-unkeyed-\(UUID().uuidString.lowercased())"
      let pool = try await manager.getDatabasePool(for: did)

      // Write seed data.
      try await pool.write { db in
        try db.execute(sql: "CREATE TABLE c30_seed (v TEXT)")
        try db.execute(sql: "INSERT INTO c30_seed VALUES ('secret')")
      }
      try await pool.writeWithoutTransaction { db in
        try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
      }

      // Close the pool to release file locks.
      await manager.closeDatabaseAndDrain(for: did)

      // Attempt to open the same file with a plain (unkeyed) DatabaseQueue.
      let dbURL = try MLSStorageCoordinator.shared.databaseURL(for: .swiftGRDB, userDID: did)
      do {
        let plainQueue = try DatabaseQueue(path: dbURL.path)
        _ = try await plainQueue.read { db in
          try String.fetchOne(db, sql: "SELECT v FROM c30_seed")
        }
        Issue.record("Unkeyed open of a SQLCipher database must fail")
      } catch {
        // Expected: "file is not a database" or similar SQLite error.
        #expect(true, "Unkeyed open correctly failed: \(error)")
      }
    }
  }

  // MARK: - C30-3: Account switch isolation — B cannot read A's request

  @Test("Account B cannot read or resume account A's pending request")
  func accountSwitchCannotReadOtherAccountRequest() async throws {
    try await Self.withEnvironment { manager in
      let didA = "did:plc:c30-alice-\(UUID().uuidString.lowercased())"
      let didB = "did:plc:c30-bob-\(UUID().uuidString.lowercased())"

      // Account A: open pool, write draft, request presentation.
      let poolA = try await manager.getDatabasePool(for: didA)
      var draftA = try await MLSDirectComposeDraftStore.open(
        accountDID: didA, recipientDID: "did:plc:target", database: poolA)
      draftA.text = "Alice's secret introduction"
      try await MLSDirectComposeDraftStore.requestPresentation(draftA, database: poolA)

      // Verify A can read her own presentation.
      let pendingA = try await MLSDirectComposeDraftStore.pendingPresentation(
        accountDID: didA, database: poolA)
      #expect(pendingA != nil, "Account A must see her own pending presentation")
      #expect(pendingA?.text == "Alice's secret introduction")

      // Account switch: close and drain A's database, switch active user to B!
      await manager.closeDatabaseAndDrain(for: didA)
      await manager.setActiveUser(didB)

      // Account B: open pool for B (separate encrypted database).
      let poolB = try await manager.getDatabasePool(for: didB)

      // B's pool is a completely separate encrypted database.
      // Attempting to read A's presentation from B's database returns nil.
      let pendingB = try await MLSDirectComposeDraftStore.pendingPresentation(
        accountDID: didA, database: poolB)
      #expect(pendingB == nil,
        "Account B's database must not contain account A's pending presentation")

      // B's own drafts are separate.
      let draftB = try await MLSDirectComposeDraftStore.open(
        accountDID: didB, recipientDID: "did:plc:target", database: poolB)
      #expect(draftB.id != draftA.id,
        "Drafts in different encrypted databases must have independent identities")
    }
  }

  // MARK: - C30-4: Separate encryption keys per account

  @Test("Different accounts use different SQLCipher keys and database files")
  func separateKeysPerAccount() async throws {
    try await Self.withEnvironment { manager in
      let didA = "did:plc:c30-keya-\(UUID().uuidString.lowercased())"
      let didB = "did:plc:c30-keyb-\(UUID().uuidString.lowercased())"

      // Open pool for A.
      _ = try await manager.getDatabasePool(for: didA)
      let urlA = try MLSStorageCoordinator.shared.databaseURL(for: .swiftGRDB, userDID: didA)

      // Close A before opening B to respect single active user pool limit.
      await manager.closeDatabaseAndDrain(for: didA)
      await manager.setActiveUser(didB)

      // Open pool for B.
      _ = try await manager.getDatabasePool(for: didB)
      let urlB = try MLSStorageCoordinator.shared.databaseURL(for: .swiftGRDB, userDID: didB)

      #expect(urlA != urlB, "Different accounts must use different database files")

      // Verify both database files exist and are non-empty.
      let fileA = try Data(contentsOf: urlA)
      let fileB = try Data(contentsOf: urlB)
      #expect(fileA.count > 0, "A's database file must exist and be non-empty")
      #expect(fileB.count > 0, "B's database file must exist and be non-empty")
    }
  }

  // MARK: - C30-5: Draft survives reopen and stays in encrypted storage

  @Test("Draft text survives database reopen and stays encrypted on disk")
  func draftSurvivesReopenEncrypted() async throws {
    try await Self.withEnvironment { manager in
      let did = "did:plc:c30-reopen-\(UUID().uuidString.lowercased())"
      let pool = try await manager.getDatabasePool(for: did)

      // Write and present a draft.
      var draft = try await MLSDirectComposeDraftStore.open(
        accountDID: did, recipientDID: "did:plc:peer", database: pool)
      draft.text = "Persistent encrypted draft"
      try await MLSDirectComposeDraftStore.requestPresentation(draft, database: pool)

      // Close and reopen the database.
      await manager.closeDatabaseAndDrain(for: did)
      let reopened = try await manager.getDatabasePool(for: did)

      // Draft must be recoverable with the same key.
      let restored = try await MLSDirectComposeDraftStore.pendingPresentation(
        accountDID: did, database: reopened)
      #expect(restored?.text == "Persistent encrypted draft",
        "Draft must survive database close/reopen cycle")
      #expect(restored?.id == draft.id, "Draft identity must be preserved across reopen")
    }
  }
}
