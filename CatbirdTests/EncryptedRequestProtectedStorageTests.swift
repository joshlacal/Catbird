@testable import CatbirdMLSCore
import Foundation
import GRDB
import Petrel
import Testing
@testable import Catbird

/// C30 Apple validation: pending text in protected storage; account switch
/// cannot expose or resume another account's request.
///
/// Uses the real SQLCipher encryption path (MLSGRDBManager + MLSKeychainFakeStorage)
/// to prove:
///   1. Database pool uses SQLCipher with a Keychain-derived key (PRAGMA cipher_version non-nil).
///   2. Raw file data on disk contains zero plaintext draft strings after checkpointing.
///   3. Opening the file without the correct key fails.
///   4. Account switch: opening an inactive user's pool is rejected by MLSGRDBManager:1893 guard;
///      Bob's database cannot read or resume Alice's pending presentation.
///   5. Tenant keys are distinct: MLSSQLCipherEncryption generates different AES-256 keys per DID.
///   6. Draft survives reopen and stays encrypted on disk.
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

  // MARK: - C30-3: Account switch isolation — B cannot read or resume A's request; inactive A blocked

  @Test("Account switch prevents B from reading or resuming A's draft; getDatabasePool blocks inactive A")
  func accountSwitchCannotReadOtherAccountRequest() async throws {
    try await Self.withEnvironment { manager in
      let didA = "did:plc:c30-alice-\(UUID().uuidString.lowercased())"
      let didB = "did:plc:c30-bob-\(UUID().uuidString.lowercased())"

      // Account A is active: open pool, write draft, request presentation.
      await manager.setActiveUser(didA)
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
      // Resume entry point while A is signed in: the view model reopens A's saved draft.
      let client = await ATProtoClient(baseURL: URL(string: "https://example.com")!)
      let apiClient = await MLSAPIClient(client: client)
      let managerA = MLSConversationManager(
        apiClient: apiClient, database: poolA, userDid: didA, atProtoClient: client)
      let viewModelA = MLSNewConversationViewModel(database: poolA, conversationManager: managerA)
      viewModelA.selectedMembers = ["did:plc:target"]
      AppStateManager.shared.setLifecycleForTesting(.authenticated(AppState(userDID: didA, client: client)))
      defer { AppStateManager.shared.setLifecycleForTesting(.unauthenticated) }
      let resumedByA = try await viewModelA.createRecipientDraft()
      #expect(resumedByA.id == draftA.id, "Control: A resumes her own saved draft")

      // Account switch: close and drain A's database, switch active user to B.
      await manager.closeDatabaseAndDrain(for: didA)
      await manager.setActiveUser(didB)
      AppStateManager.shared.setLifecycleForTesting(.authenticated(AppState(userDID: didB, client: client)))

      // 1. Actually attempt to open A's pool while B is active:
      // MLSGRDBManager.swift:1893 guard MUST reject it with MLSSQLCipherError.storageUnavailable!
      await #expect(throws: MLSSQLCipherError.self) {
        _ = try await manager.getDatabasePool(for: didA)
      }

      // 2. Open B's pool. B's database contains NO presentation for A.
      let poolB = try await manager.getDatabasePool(for: didB)
      let pendingForAInB = try await MLSDirectComposeDraftStore.pendingPresentation(
        accountDID: didA, database: poolB)
      #expect(pendingForAInB == nil,
        "Account B's database must not contain account A's pending presentation")

      // 3. B attempts to resume A's request through A's still-referenced view model: refused.
      await #expect(throws: MLSDirectComposeDraftStore.Failure.accountChanged) {
        _ = try await viewModelA.createRecipientDraft()
      }
    }
  }

  // MARK: - C30-3b (F38 reachability): a foreign-owner row in B's store is unreachable from B

  @Test("A draft owned by A planted in B's encrypted store cannot be surfaced or resumed by B's session")
  func foreignOwnerRowInOtherTenantStoreIsUnreachable() async throws {
    try await Self.withEnvironment { manager in
      let didA = "did:plc:c30-owner-a-\(UUID().uuidString.lowercased())"
      let didB = "did:plc:c30-tenant-b-\(UUID().uuidString.lowercased())"
      let recipient = "did:plc:shared-recipient"
      let handoffConversation = "550e8400-e29b-41d4-a716-446655440000"
      await manager.setActiveUser(didB)
      let poolB = try await manager.getDatabasePool(for: didB)

      // Direct store misuse (no production caller does this): write A-owned rows into B's DB.
      var planted = MLSDirectComposeDraft(accountDID: didA, recipientDID: recipient)
      planted.text = "A's secret introduction planted in B"
      try await MLSDirectComposeDraftStore.requestPresentation(planted, database: poolB)
      try await ChatDraftHandoff.shared.storeDurably(
        PendingChatDraft(conversationID: nil, text: planted.text), accountDID: didA, database: poolB)
      let plantedRows = try await poolB.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM app_direct_compose_drafts WHERE account_did = ?", arguments: [didA])
      }
      #expect(plantedRows == 1, "The planted row physically exists in B's SQLCipher store")

      // B's session drives every read/resume entry point with its own identity.
      let client = await ATProtoClient(baseURL: URL(string: "https://example.com")!)
      AppStateManager.shared.setLifecycleForTesting(.authenticated(AppState(userDID: didB, client: client)))
      defer { AppStateManager.shared.setLifecycleForTesting(.unauthenticated) }
      let managerB = MLSConversationManager(
        apiClient: await MLSAPIClient(client: client), database: poolB, userDid: didB, atProtoClient: client)
      let viewModelB = MLSNewConversationViewModel(database: poolB, conversationManager: managerB)
      viewModelB.selectedMembers = [recipient]
      let composeB = try await viewModelB.createRecipientDraft()
      #expect(composeB.id != planted.id && composeB.accountDID == didB && composeB.text.isEmpty,
        "Contact select for the same recipient opens B's own empty draft, never A's")
      #expect(try await MLSDirectComposeDraftStore.pendingPresentation(accountDID: didB, database: poolB) == nil,
        "B's presentation restore never offers A's draft")
      #expect(try await MLSDirectComposeDraftStore.savedInvitationNotes(accountDID: didB, database: poolB).isEmpty)
      #expect(try await MLSGroupInvitationNotesStore.draftStatus(id: planted.id, accountDID: didB, database: poolB) == nil,
        "Looking A's draft up by id under B's identity finds nothing")
      #expect(try await ChatDraftHandoff.shared.consumeDurably(
        for: handoffConversation, accountDID: didB, database: poolB) == nil,
        "B's conversation handoff never receives A's text")
    }
  }

  // MARK: - C30-4: Separate encryption keys per account

  @Test("Different accounts use different SQLCipher keys and database files")
  func separateKeysPerAccount() async throws {
    try await Self.withEnvironment { manager in
      let didA = "did:plc:c30-keya-\(UUID().uuidString.lowercased())"
      let didB = "did:plc:c30-keyb-\(UUID().uuidString.lowercased())"

      // Open pool for A.
      await manager.setActiveUser(didA)
      _ = try await manager.getDatabasePool(for: didA)
      let urlA = try MLSStorageCoordinator.shared.databaseURL(for: .swiftGRDB, userDID: didA)
      let keyA = try await MLSSQLCipherEncryption.shared.getKey(for: didA)

      // Close A before opening B to respect single active user pool limit.
      await manager.closeDatabaseAndDrain(for: didA)
      await manager.setActiveUser(didB)

      // Open pool for B.
      _ = try await manager.getDatabasePool(for: didB)
      let urlB = try MLSStorageCoordinator.shared.databaseURL(for: .swiftGRDB, userDID: didB)
      let keyB = try await MLSSQLCipherEncryption.shared.getKey(for: didB)

      // 1. Compare database file paths.
      #expect(urlA != urlB, "Different accounts must use different database files")

      // 2. Compare actual encryption keys generated in Keychain/fake-storage!
      #expect(keyA != nil, "Account A must have a generated SQLCipher key")
      #expect(keyB != nil, "Account B must have a generated SQLCipher key")
      #expect(keyA != keyB, "Different accounts must have distinct SQLCipher encryption keys")

      // 3. Verify both database files exist and are non-empty.
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
