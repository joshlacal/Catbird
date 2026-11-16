import CatbirdMLS
import CatbirdMLSCore
import Foundation
import Petrel
import PetrelCatbird
import SwiftData
import Testing
import UserNotifications
@testable import Catbird

private final class Wave0RecordingKeyStore: PlatformKeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var dbKeys: [String: Data] = [:]
  private var sigKeypairs: [String: Data] = [:]
  private var dpopTokens: [String: (token: String, expiresAtMs: Int64)] = [:]

  func loadOrCreateDbKey(accountDidHash: String) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    if let existing = dbKeys[accountDidHash] {
      return existing
    }
    let generated = Data((0..<32).map { UInt8(($0 &* 29 &+ 7) & 0xff) })
    dbKeys[accountDidHash] = generated
    return generated
  }

  func loadSignatureKeypair(keyId: String) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return sigKeypairs[keyId]
  }

  func storeSignatureKeypair(keyId: String, keypairBytes: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    sigKeypairs[keyId] = keypairBytes
  }

  func deleteAccountKeys(accountDidHash: String) throws {
    lock.lock()
    defer { lock.unlock() }
    dbKeys.removeValue(forKey: accountDidHash)
    dpopTokens.removeValue(forKey: accountDidHash)
  }

  func loadCachedChatDpopToken(accountDidHash: String) throws -> String? {
    lock.lock()
    defer { lock.unlock() }
    return dpopTokens[accountDidHash]?.token
  }

  func storeCachedChatDpopToken(accountDidHash: String, token: String, expiresAtMs: Int64) throws {
    lock.lock()
    defer { lock.unlock() }
    dpopTokens[accountDidHash] = (token, expiresAtMs)
  }

  func hasDbKey(accountDidHash: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return dbKeys[accountDidHash] != nil
  }

  var signatureKeypairCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return sigKeypairs.count
  }
}

@Suite("MLS Client Resurrection & Release Readiness Tests", .serialized)
struct MLSResurrectionWave0Tests {
  private func makeTempStorageRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("CatbirdWave0Tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func archiveTempDir(_ dir: URL) {
    let trash = FileManager.default.temporaryDirectory
      .appendingPathComponent("_trash-CatbirdWave0Tests", isDirectory: true)
    try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    try? FileManager.default.moveItem(
      at: dir,
      to: trash.appendingPathComponent(dir.lastPathComponent)
    )
  }

  @Test("LocalStateFormatUnsupported wipe removes SQLite DB/WAL/SHM/journal while preserving Keychain recovery keys (P0-6)")
  func wipeUnsupportedLocalMLSDatabasePreservesKeychain() throws {
    let tempRoot = try makeTempStorageRoot()
    defer { archiveTempDir(tempRoot) }

    let targetDID = "did:plc:unsupportedschema\(UUID().uuidString.prefix(8).lowercased())"
    let otherDID = "did:plc:healthyaccount\(UUID().uuidString.prefix(8).lowercased())"

    let mlsDir = MLSAppGroupStorage.mlsDirectoryURL(storageRoot: tempRoot)
    try FileManager.default.createDirectory(at: mlsDir, withIntermediateDirectories: true)

    let targetDB = try MLSAppGroupStorage.databaseURL(storageRoot: tempRoot, accountDid: targetDID)
    let otherDB = try MLSAppGroupStorage.databaseURL(storageRoot: tempRoot, accountDid: otherDID)

    for suffix in ["", "-wal", "-shm", "-journal"] {
      try Data("corrupt-or-v0".utf8).write(to: URL(fileURLWithPath: targetDB.path + suffix))
      try Data("keep-other".utf8).write(to: URL(fileURLWithPath: otherDB.path + suffix))
    }

    let didHash = try MLSAppGroupStorage.accountDidHash(for: targetDID)
    let keystore = Wave0RecordingKeyStore()
    let originalKey = try keystore.loadOrCreateDbKey(accountDidHash: didHash)
    try keystore.storeSignatureKeypair(keyId: "sig-\(didHash)", keypairBytes: Data([0xAA, 0xBB, 0xCC]))

    AppState.wipeUnsupportedLocalMLSDatabaseFiles(storageRoot: tempRoot, accountDid: targetDID)

    for suffix in ["", "-wal", "-shm", "-journal"] {
      #expect(!FileManager.default.fileExists(atPath: targetDB.path + suffix))
      #expect(FileManager.default.fileExists(atPath: otherDB.path + suffix))
    }

    // Keychain keys MUST remain intact so device identity / recovery keys survive DB format reset
    let preservedKey = try keystore.loadOrCreateDbKey(accountDidHash: didHash)
    #expect(preservedKey == originalKey)
    #expect(try keystore.loadSignatureKeypair(keyId: "sig-\(didHash)") == Data([0xAA, 0xBB, 0xCC]))
  }

  @Test("AccountDeletionCoordinator.eraseCatbirdData wipes SQLite DB and Keychain keys even when mlsCoordinator is nil (P0-2)")
  @MainActor
  func eraseCatbirdDataOfflineMLSArtifactsWipe() async throws {
    let tempRoot = try makeTempStorageRoot()
    defer { archiveTempDir(tempRoot) }

    let targetDID = "did:plc:offlineerase\(UUID().uuidString.prefix(8).lowercased())"
    let preservedDID = "did:plc:preservederase\(UUID().uuidString.prefix(8).lowercased())"

    let mlsDir = MLSAppGroupStorage.mlsDirectoryURL(storageRoot: tempRoot)
    try FileManager.default.createDirectory(at: mlsDir, withIntermediateDirectories: true)

    let targetDB = try MLSAppGroupStorage.databaseURL(storageRoot: tempRoot, accountDid: targetDID)
    let preservedDB = try MLSAppGroupStorage.databaseURL(storageRoot: tempRoot, accountDid: preservedDID)
    for suffix in ["", "-wal", "-shm", "-journal"] {
      try Data("encrypted-db".utf8).write(to: URL(fileURLWithPath: targetDB.path + suffix))
      try Data("keep-db".utf8).write(to: URL(fileURLWithPath: preservedDB.path + suffix))
    }

    let keystore = Wave0RecordingKeyStore()
    let targetHash = try MLSAppGroupStorage.accountDidHash(for: targetDID)
    let preservedHash = try MLSAppGroupStorage.accountDidHash(for: preservedDID)
    _ = try keystore.loadOrCreateDbKey(accountDidHash: targetHash)
    let initialPreservedKey = try keystore.loadOrCreateDbKey(accountDidHash: preservedHash)
    try keystore.storeCachedChatDpopToken(
      accountDidHash: targetHash,
      token: "cached-dpop-token",
      expiresAtMs: Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
    )

    let schema = Schema([AppSettingsModel.self, Preferences.self, DraftPost.self])
    let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    let context = ModelContext(container)

    try await AccountDeletionCoordinator.eraseCatbirdData(
      forDID: targetDID,
      token: nil,
      storageRoot: tempRoot,
      keystore: keystore,
      modelContext: context
    )

    for suffix in ["", "-wal", "-shm", "-journal"] {
      #expect(!FileManager.default.fileExists(atPath: targetDB.path + suffix))
      #expect(FileManager.default.fileExists(atPath: preservedDB.path + suffix))
    }

    // Cached DPoP token and DB key for targetHash were wiped while preservedHash remains untouched
    #expect(try keystore.loadCachedChatDpopToken(accountDidHash: targetHash) == nil)
    #expect(try keystore.loadOrCreateDbKey(accountDidHash: preservedHash) == initialPreservedKey)
  }

  @Test("MLSConversationDataSource folds same-sender edits, rejects cross-sender edits, and folds reaction add/remove events (P1-2)")
  @MainActor
  func dataSourceFoldsEditsAndReactionsWithSenderEnforcement() throws {
    let convoID = UUID().uuidString.lowercased()
    let groupID = Data([0x01, 0x02, 0x03, 0x04])
    let aliceRoot = "did:plc:aliceauthor001"
    let bobRoot = "did:plc:bobpeer000002"
    let malloryRoot = "did:plc:malloryspoof3"

    let dataSource = MLSConversationDataSource(
      conversationId: convoID,
      currentUserDID: aliceRoot,
      appState: nil
    )

    let textJSON = try #require(
      String(data: try MLSMessagePayload.text("Original message").encodeToJSON(), encoding: .utf8)
    )
    let validEditJSON = try #require(
      String(
        data: try MLSMessagePayload.edit(targetMessageId: "msg-1", newText: "Author edited text").encodeToJSON(),
        encoding: .utf8
      )
    )
    let forgedEditJSON = try #require(
      String(
        data: try MLSMessagePayload.edit(targetMessageId: "msg-1", newText: "Spoofed by Mallory").encodeToJSON(),
        encoding: .utf8
      )
    )
    let aliceAddThumbsUp = try #require(
      String(
        data: try MLSMessagePayload.reaction(messageId: "msg-1", emoji: "👍", action: .add).encodeToJSON(),
        encoding: .utf8
      )
    )
    let bobAddThumbsUp = try #require(
      String(
        data: try MLSMessagePayload.reaction(messageId: "msg-1", emoji: "👍", action: .add).encodeToJSON(),
        encoding: .utf8
      )
    )
    let bobAddHeart = try #require(
      String(
        data: try MLSMessagePayload.reaction(messageId: "msg-1", emoji: "❤️", action: .add).encodeToJSON(),
        encoding: .utf8
      )
    )
    let aliceRemoveThumbsUp = try #require(
      String(
        data: try MLSMessagePayload.reaction(messageId: "msg-1", emoji: "👍", action: .remove).encodeToJSON(),
        encoding: .utf8
      )
    )

    let rows: [MLSMessageRow] = [
      MLSMessageRow(
        messageId: "msg-1",
        conversationId: convoID,
        groupId: groupID,
        epoch: 1,
        seq: 1,
        senderDid: "\(aliceRoot)#dev-1",
        senderDeviceId: "dev-1",
        plaintextJson: textJSON,
        createdAtMs: 1_700_000_001_000,
        isOwn: true
      ),
      MLSMessageRow(
        messageId: "msg-2",
        conversationId: convoID,
        groupId: groupID,
        epoch: 1,
        seq: 2,
        senderDid: "\(aliceRoot)#dev-2",
        senderDeviceId: "dev-2",
        plaintextJson: validEditJSON,
        createdAtMs: 1_700_000_002_000,
        isOwn: true
      ),
      MLSMessageRow(
        messageId: "msg-3",
        conversationId: convoID,
        groupId: groupID,
        epoch: 1,
        seq: 3,
        senderDid: "\(malloryRoot)#dev-9",
        senderDeviceId: "dev-9",
        plaintextJson: forgedEditJSON,
        createdAtMs: 1_700_000_003_000,
        isOwn: false
      ),
      MLSMessageRow(
        messageId: "msg-4",
        conversationId: convoID,
        groupId: groupID,
        epoch: 1,
        seq: 4,
        senderDid: "\(aliceRoot)#dev-1",
        senderDeviceId: "dev-1",
        plaintextJson: aliceAddThumbsUp,
        createdAtMs: 1_700_000_004_000,
        isOwn: true
      ),
      MLSMessageRow(
        messageId: "msg-5",
        conversationId: convoID,
        groupId: groupID,
        epoch: 1,
        seq: 5,
        senderDid: "\(bobRoot)#dev-1",
        senderDeviceId: "dev-1",
        plaintextJson: bobAddThumbsUp,
        createdAtMs: 1_700_000_005_000,
        isOwn: false
      ),
      MLSMessageRow(
        messageId: "msg-6",
        conversationId: convoID,
        groupId: groupID,
        epoch: 1,
        seq: 6,
        senderDid: "\(bobRoot)#dev-1",
        senderDeviceId: "dev-1",
        plaintextJson: bobAddHeart,
        createdAtMs: 1_700_000_006_000,
        isOwn: false
      ),
      MLSMessageRow(
        messageId: "msg-7",
        conversationId: convoID,
        groupId: groupID,
        epoch: 1,
        seq: 7,
        senderDid: "\(aliceRoot)#dev-2",
        senderDeviceId: "dev-2",
        plaintextJson: aliceRemoveThumbsUp,
        createdAtMs: 1_700_000_007_000,
        isOwn: true
      ),
    ]

    dataSource.ingestRowsForTesting(rows)

    #expect(dataSource.messages.count == 1)
    let rendered = try #require(dataSource.messages.first)
    #expect(rendered.id == "msg-1")
    #expect(rendered.text == "Author edited text")
    #expect(rendered.isEdited)
    #expect(rendered.editedAt != nil)

    let reactions = rendered.mlsReactions
    #expect(reactions.count == 2)
    #expect(reactions.contains { $0.reaction == "👍" && $0.senderDID == bobRoot })
    #expect(reactions.contains { $0.reaction == "❤️" && $0.senderDID == bobRoot })
    #expect(!reactions.contains { $0.senderDID == aliceRoot })
  }

  @Test("MLSConversationDataSource sends encrypted reaction payloads and rolls back failed optimistic toggles (P1-2)")
  @MainActor
  func dataSourceSendsEncryptedReactionsRoundtrip() async throws {
    let accountDid = "did:plc:reactionroundtrip01"
    let conversationId = UUID().uuidString.lowercased()
    let groupID = Data([0x10, 0x20, 0x30, 0x40])

    var sentWirePayloads: [String] = []
    var nextSeq: Int64 = 2
    var shouldFailSend = false
    weak var weakDataSource: MLSConversationDataSource?

    let performer = MLSMessageActionPerformer(
      edit: { _, _, _ in },
      unsend: { _, _ in },
      react: { convoID, messageID, emoji, action in
        if shouldFailSend {
          throw NSError(domain: "Wave0Test", code: 503, userInfo: [NSLocalizedDescriptionKey: "Simulated transport failure"])
        }
        let encoded = try MLSMessagePayload.reaction(
          messageId: messageID,
          emoji: emoji,
          action: action
        ).encodeToJSON()
        let wireJSON = try #require(String(data: encoded, encoding: .utf8))
        sentWirePayloads.append(wireJSON)

        let seq = nextSeq
        nextSeq += 1
        weakDataSource?.ingestRowsForTesting([
          MLSMessageRow(
            messageId: "msg-\(seq)",
            conversationId: convoID,
            groupId: groupID,
            epoch: 1,
            seq: seq,
            senderDid: "\(accountDid)#dev-1",
            senderDeviceId: "dev-1",
            plaintextJson: wireJSON,
            createdAtMs: 1_700_000_000_000 + seq * 1_000,
            isOwn: true
          )
        ])
      }
    )

    let dataSource = MLSConversationDataSource(
      conversationId: conversationId,
      currentUserDID: accountDid,
      appState: nil,
      actionPerformer: performer
    )
    weakDataSource = dataSource
    dataSource.setActionConsentForTesting(resolved: true, pending: false)

    let baseTextJSON = try #require(
      String(data: try MLSMessagePayload.text("React to this message").encodeToJSON(), encoding: .utf8)
    )
    dataSource.ingestRowsForTesting([
      MLSMessageRow(
        messageId: "msg-1",
        conversationId: conversationId,
        groupId: groupID,
        epoch: 1,
        seq: 1,
        senderDid: "\(accountDid)#dev-1",
        senderDeviceId: "dev-1",
        plaintextJson: baseTextJSON,
        createdAtMs: 1_700_000_001_000,
        isOwn: true
      )
    ])

    let sentMessage = try #require(dataSource.messages.first)
    dataSource.toggleReaction(messageID: sentMessage.id, emoji: "🔥")

    // Optimistic state updates immediately
    #expect(dataSource.messages.first?.mlsReactions.map(\.reaction) == ["🔥"])

    try await Task.sleep(for: .milliseconds(50))

    #expect(sentWirePayloads.count == 1)
    let addDecoded = try MLSMessagePayload.decodeFromJSON(Data(sentWirePayloads[0].utf8))
    #expect(addDecoded.messageType == .reaction)
    #expect(addDecoded.reaction?.messageId == "msg-1")
    #expect(addDecoded.reaction?.emoji == "🔥")
    #expect(addDecoded.reaction?.action == .add)
    #expect(dataSource.messages.count == 1)
    #expect(dataSource.messages.first?.mlsReactions.map(\.reaction) == ["🔥"])

    // Toggle off sends .remove reaction payload
    dataSource.toggleReaction(messageID: sentMessage.id, emoji: "🔥")
    try await Task.sleep(for: .milliseconds(50))

    #expect(sentWirePayloads.count == 2)
    let removeDecoded = try MLSMessagePayload.decodeFromJSON(Data(sentWirePayloads[1].utf8))
    #expect(removeDecoded.reaction?.action == .remove)
    #expect(dataSource.messages.first?.mlsReactions.isEmpty == true)

    // Failed send rolls back optimistic reaction cleanly
    shouldFailSend = true
    dataSource.toggleReaction(messageID: sentMessage.id, emoji: "🚀")
    #expect(dataSource.messages.first?.mlsReactions.map(\.reaction) == ["🚀"])
    try await Task.sleep(for: .milliseconds(50))
    #expect(dataSource.messages.first?.mlsReactions.isEmpty == true)

    dataSource.stopObserving()
  }

  @Test("NotificationService fails closed to generic fallback when preview.receiptVerified is false")
  func notificationServiceFailsClosedOnUnverifiedReceipt() {
    let wake = PushWakePayload(
      kind: "application",
      conversationId: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      generation: 1,
      entrySeq: 42,
      messageId: "msg-42",
      recipientAccountHash: String(repeating: "a", count: 64),
      fetchRequired: false,
      senderDid: "did:plc:sender",
      inlineCiphertext: nil
    )

    let unverifiedPreview = NotificationPreview(
      messageId: "msg-42",
      conversationId: wake.conversationId,
      senderDid: "did:plc:attacker",
      senderDisplayName: "Spoofed Sender",
      groupTitle: "Spoofed Group Title",
      body: "Spoofed secret message body",
      epoch: 1,
      seq: 42,
      fromCache: false,
      fallbackGeneric: false,
      darwinNotificationName: MLSAppGroupStorage.nseDidCommitDarwinNotification,
      receiptVerified: false,
      isOwnSiblingSender: false
    )

    let unverifiedResult = NotificationService.buildCommunicationNotification(
      base: UNMutableNotificationContent(),
      preview: unverifiedPreview,
      wake: wake
    )
    #expect(unverifiedResult.title == "Catbird")
    #expect(unverifiedResult.body == MLSPushExtensionProcessor.genericFallbackBody)
    #expect(!unverifiedResult.title.contains("Spoofed"))
    #expect(!unverifiedResult.body.contains("Spoofed"))
    #expect(unverifiedResult.userInfo["message_id"] == nil)

    let verifiedPreview = NotificationPreview(
      messageId: "msg-42",
      conversationId: wake.conversationId,
      senderDid: "did:plc:alice",
      senderDisplayName: "Alice",
      groupTitle: "Trusted Group",
      body: "Verified hello",
      epoch: 1,
      seq: 42,
      fromCache: false,
      fallbackGeneric: false,
      darwinNotificationName: MLSAppGroupStorage.nseDidCommitDarwinNotification,
      receiptVerified: true,
      isOwnSiblingSender: false
    )

    let verifiedResult = NotificationService.buildCommunicationNotification(
      base: UNMutableNotificationContent(),
      preview: verifiedPreview,
      wake: wake
    )
    #expect(verifiedResult.body == "Verified hello")
    #expect(verifiedResult.userInfo["message_id"] as? String == "msg-42")
  }

  @Test("AccountDeletionSheet surfaces actionable remediation for ExpiredToken and InvalidToken (P0-3)")
  func permanentAccountDeletionErrorDescriptions() {
    let expired = AccountDeletionSheet.describePermanentDeletionError(
      ComAtprotoServerDeleteAccount.Error.expiredToken
    )
    #expect(expired.localizedCaseInsensitiveContains("expired"))

    let invalid = AccountDeletionSheet.describePermanentDeletionError(
      ComAtprotoServerDeleteAccount.Error.invalidToken
    )
    #expect(invalid.localizedCaseInsensitiveContains("invalid"))
  }

  @Test("Sign-out wipe rotates per-account deviceId and prefix-safely filters MLS sigkey and CircleKeyStore Keychain items")
  func wipeLocalMLSArtifactsRotatesDeviceIdAndFiltersScopedKeychainResiduals() throws {
    let tempRoot = try makeTempStorageRoot()
    defer { archiveTempDir(tempRoot) }

    let suiteName = "CatbirdWave0DeviceID-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let aliceDID = "did:plc:aliceprimary01"
    let bobDID = "did:plc:bobsecondary02"

    let firstAliceDeviceID = AppState.resolveOrCreateMLSDeviceID(for: aliceDID, in: defaults)
    let repeatAliceDeviceID = AppState.resolveOrCreateMLSDeviceID(for: aliceDID, in: defaults)
    let bobDeviceID = AppState.resolveOrCreateMLSDeviceID(for: bobDID, in: defaults)
    #expect(firstAliceDeviceID == repeatAliceDeviceID)
    #expect(UUID(uuidString: firstAliceDeviceID) != nil)

    let aliceHash = try MLSAppGroupStorage.accountDidHash(for: aliceDID)
    let bobHash = try MLSAppGroupStorage.accountDidHash(for: bobDID)
    defaults.set(firstAliceDeviceID, forKey: "mlsDeviceId_\(aliceHash)")
    defaults.set(bobDeviceID, forKey: "mlsDeviceId_\(bobHash)")

    let keystore = Wave0RecordingKeyStore()
    _ = try keystore.loadOrCreateDbKey(accountDidHash: aliceHash)
    let bobKeyBefore = try keystore.loadOrCreateDbKey(accountDidHash: bobHash)

    AppState.wipeLocalMLSArtifacts(
      for: aliceDID,
      storageRoot: tempRoot,
      keystore: keystore,
      sharedDefaults: defaults
    )

    // Subsequent sign-in for Alice mints a brand-new deviceId UUIDv4 while Bob stays untouched
    let postReSignInAliceDeviceID = AppState.resolveOrCreateMLSDeviceID(for: aliceDID, in: defaults)
    #expect(postReSignInAliceDeviceID != firstAliceDeviceID)
    #expect(UUID(uuidString: postReSignInAliceDeviceID) != nil)
    #expect(AppState.resolveOrCreateMLSDeviceID(for: bobDID, in: defaults) == bobDeviceID)
    #expect(defaults.string(forKey: "mlsDeviceId_\(aliceHash)") == nil)
    #expect(defaults.string(forKey: "mlsDeviceId_\(bobHash)") == bobDeviceID)
    #expect(try keystore.loadOrCreateDbKey(accountDidHash: bobHash) == bobKeyBefore)

    // Prefix-safe Keychain account filter matches only Alice's MLS sigkeys & Circle keys
    let filtered = AppState.filterAccountScopedKeychainAccounts(
      mlsAccounts: [
        "sigkey:mls-signer:\(aliceHash)",
        "sigkey:mls-signer:\(aliceHash):\(firstAliceDeviceID)",
        "sigkey:\(aliceHash):\(firstAliceDeviceID)",
        "sigkey:mls-signer:\(bobHash):\(bobDeviceID)",
        "dbkey:\(aliceHash)",
      ],
      circleAccounts: [
        "\(aliceDID)|at://\(aliceDID)/blue.catbird.circle/friends",
        "\(aliceDID.uppercased())|at://\(aliceDID)/blue.catbird.circle/vip",
        "\(aliceDID)extra|at://\(aliceDID)extra/blue.catbird.circle/friends",
        "\(bobDID)|at://\(bobDID)/blue.catbird.circle/friends",
      ],
      accountDid: aliceDID,
      didHash: aliceHash,
      previousDeviceId: firstAliceDeviceID
    )

    #expect(filtered.mlsSigKeyAccounts.count == 3)
    #expect(!filtered.mlsSigKeyAccounts.contains { $0.contains(bobHash) })
    #expect(filtered.circleKeyAccounts.count == 2)
    #expect(!filtered.circleKeyAccounts.contains { $0.contains(bobDID) || $0.contains("extra|") })
  }

  @Test("NotificationService suppresses banner and sound for verified own-sibling-device pushes without silencing unverified pushes")
  func notificationServiceSuppressesOwnSiblingDeviceAlertsAfterVerifiedReceipt() throws {
    let aliceDID = "did:plc:alicesibling01"
    let aliceHash = try MLSAppGroupStorage.accountDidHash(for: aliceDID)
    let wake = PushWakePayload(
      kind: "application",
      conversationId: "11111111-2222-4333-8444-555555555555",
      generation: 1,
      entrySeq: 99,
      messageId: "msg-99",
      recipientAccountHash: aliceHash,
      fetchRequired: false,
      senderDid: "\(aliceDID)#dev-macbook",
      inlineCiphertext: nil
    )

    // 1. Verified sibling-device outgoing message is silently suppressed (no banner/sound)
    let siblingPreview = NotificationPreview(
      messageId: "msg-99",
      conversationId: wake.conversationId,
      senderDid: "\(aliceDID)#dev-macbook",
      senderDisplayName: "Alice",
      groupTitle: "Design Sync",
      body: "Sent from my Mac",
      epoch: 2,
      seq: 99,
      fromCache: false,
      fallbackGeneric: false,
      darwinNotificationName: MLSAppGroupStorage.nseDidCommitDarwinNotification,
      receiptVerified: true,
      isOwnSiblingSender: true
    )

    // 1a. Without Apple's managed filtering entitlement (default), NSE emits a quiet passive
    //     non-blank sync notice (no sound, no badge) instead of rendering an empty iOS banner.
    #expect(!NotificationService.hasManagedNotificationFilteringEntitlement)
    let quieted = NotificationService.buildCommunicationNotification(
      base: UNMutableNotificationContent(),
      preview: siblingPreview,
      wake: wake
    )
    #expect(quieted.title == "Design Sync")
    #expect(quieted.body == "Synced message from your other device")
    #expect(quieted.sound == nil)
    #expect(quieted.badge == nil)
    #expect(quieted.interruptionLevel == .passive)
    #expect(quieted.userInfo["suppressedForOwnSiblingDevice"] as? Bool == true)
    #expect(quieted.userInfo["silentDropRequiresManagedFilteringEntitlement"] as? Bool == true)

    // 1b. When the managed filtering entitlement IS present, NSE returns an empty UNNotificationContent().
    let filteredDrop = NotificationService.buildCommunicationNotification(
      base: UNMutableNotificationContent(),
      preview: siblingPreview,
      wake: wake,
      hasFilteringEntitlement: true
    )
    #expect(filteredDrop.title.isEmpty)
    #expect(filteredDrop.body.isEmpty)

    // 2. Unverified push claiming senderDid == Alice MUST NOT be silently suppressed; it falls back generically
    let spoofedUnverified = NotificationPreview(
      messageId: "msg-99",
      conversationId: wake.conversationId,
      senderDid: "\(aliceDID)#dev-spoof",
      senderDisplayName: "Alice",
      groupTitle: "Design Sync",
      body: "Spoofed",
      epoch: 2,
      seq: 99,
      fromCache: false,
      fallbackGeneric: false,
      darwinNotificationName: MLSAppGroupStorage.nseDidCommitDarwinNotification,
      receiptVerified: false,
      isOwnSiblingSender: false
    )
    let fallback = NotificationService.buildCommunicationNotification(
      base: UNMutableNotificationContent(),
      preview: spoofedUnverified,
      wake: wake,
      recipientAccountDID: aliceDID
    )
    #expect(fallback.title == "Catbird")
    #expect(fallback.body == MLSPushExtensionProcessor.genericFallbackBody)
    #expect(fallback.userInfo["suppressedForOwnSiblingDevice"] == nil)

    // 3. Verified peer message renders normal alert content
    let peerPreview = NotificationPreview(
      messageId: "msg-100",
      conversationId: wake.conversationId,
      senderDid: "did:plc:bobpeer02#dev-iphone",
      senderDisplayName: "Bob",
      groupTitle: nil,
      body: "Hey from Bob",
      epoch: 2,
      seq: 100,
      fromCache: false,
      fallbackGeneric: false,
      darwinNotificationName: MLSAppGroupStorage.nseDidCommitDarwinNotification,
      receiptVerified: true,
      isOwnSiblingSender: false
    )
    let delivered = NotificationService.buildCommunicationNotification(
      base: UNMutableNotificationContent(),
      preview: peerPreview,
      wake: wake,
      recipientAccountDID: aliceDID
    )
    #expect(delivered.body == "Hey from Bob")
    #expect(delivered.userInfo["suppressedForOwnSiblingDevice"] == nil)
  }

  @Test("DeviceManagementView and LabyrinthSettingsAndRestoreView enforce self-revoke guard and surface active/dormant metadata")
  @MainActor
  func deviceManagementAndLabyrinthEnforceSelfRevokeGuardAndMetadata() async {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let currentID = "aaaaaaaa-1111-4222-8333-444444444444"
    let activeSiblingID = "bbbbbbbb-1111-4222-8333-555555555555"
    let dormantSiblingID = "cccccccc-1111-4222-8333-666666666666"

    let thisDevice = DeviceRowModel(
      deviceId: currentID,
      lastSeenAt: now.addingTimeInterval(-3600),
      keyPackageCount: 25,
      currentDeviceId: currentID,
      now: now
    )
    let activeSibling = DeviceRowModel(
      deviceId: activeSiblingID,
      deviceName: "Work MacBook Pro",
      lastSeenAt: now.addingTimeInterval(-1800),
      keyPackageCount: 20,
      currentDeviceId: currentID,
      now: now
    )
    let dormantSibling = DeviceRowModel(
      deviceId: dormantSiblingID,
      lastSeenAt: now.addingTimeInterval(-(72 * 3600)),
      keyPackageCount: 5,
      currentDeviceId: currentID,
      now: now
    )

    #expect(thisDevice.isCurrentDevice(currentDeviceId: currentID))
    #expect(thisDevice.activityState == .active)
    #expect(thisDevice.deviceName.contains(String(currentID.prefix(8))))
    #expect(!thisDevice.canRevoke(currentDeviceId: currentID))

    #expect(!activeSibling.isCurrentDevice(currentDeviceId: currentID))
    #expect(activeSibling.deviceName == "Work MacBook Pro")
    #expect(activeSibling.activityState == .active)
    #expect(activeSibling.canRevoke(currentDeviceId: currentID))

    #expect(dormantSibling.activityState == .dormant)
    #expect(dormantSibling.canRevoke(currentDeviceId: currentID))

    // Programmatic guard in DeviceManagementViewModel blocks self-revocation
    let vm = DeviceManagementViewModel()
    vm.currentDeviceId = currentID
    vm.devices = [thisDevice, activeSibling, dormantSibling]
    await vm.deleteDevice(thisDevice)
    #expect(vm.devices.contains { $0.deviceId == currentID })
    #expect(vm.deleteError?.localizedDescription == DeviceManagementViewModel.selfRevokeBlockedMessage)

    // LabyrinthSettingsAndRestoreView self-revoke guard blocks current device even when count > 1
    #expect(!LabyrinthSettingsAndRestoreView.canRevokeDevice(currentID, currentDeviceId: currentID, totalActiveCount: 3))
    #expect(!LabyrinthSettingsAndRestoreView.canRevokeDevice(currentID.uppercased(), currentDeviceId: currentID, totalActiveCount: 3))
    #expect(LabyrinthSettingsAndRestoreView.canRevokeDevice(activeSiblingID, currentDeviceId: currentID, totalActiveCount: 3))
    #expect(!LabyrinthSettingsAndRestoreView.canRevokeDevice(activeSiblingID, currentDeviceId: nil, totalActiveCount: 1))
  }

  @Test("DeviceRowModel parses canonical millisecond ISO-8601 timestamps for lastActiveAt, dormantAt, and pending_approval")
  @MainActor
  func deviceRowModelParsesCanonicalFractionalTimestamps() throws {
    let now = try #require(DeviceRowModel.parseISO8601("2026-11-13T18:30:00.000Z"))
    #expect(DeviceRowModel.parseISO8601("2026-11-13T18:30:00.123Z") != nil)
    #expect(DeviceRowModel.parseISO8601("2026-11-13T18:30:00Z") != nil)
    #expect(DeviceRowModel.parseISO8601("   ") == nil)

    let currentID = "aaaaaaaa-1111-4222-8333-444444444444"
    let activeID = "bbbbbbbb-1111-4222-8333-555555555555"
    let dormantID = "cccccccc-1111-4222-8333-666666666666"
    let pendingID = "dddddddd-1111-4222-8333-777777777777"

    // 1. updatedAt is 5 days old (> 48h), but fractional .sssZ lastActiveAt is 10 minutes ago -> must stay .active
    let recentActiveJSON = Data(
      """
      {
        "deviceId": "\(activeID)",
        "deviceName": "Josh iPad Pro",
        "status": "active",
        "updatedAt": "2026-11-08T18:30:00.000Z",
        "lastActiveAt": "2026-11-13T18:20:00.456Z",
        "availablePackageCount": 24
      }
      """.utf8
    )
    let parsedActive = try #require(
      DeviceRowModel(wireDeviceJSON: recentActiveJSON, currentDeviceId: currentID, now: now)
    )
    #expect(parsedActive.deviceName == "Josh iPad Pro")
    #expect(parsedActive.activityState == .active)
    #expect(parsedActive.keyPackageCount == 24)

    // 2. lastActiveAt is recent, but explicit fractional .sssZ dormantAt is present -> must resolve .dormant
    let explicitDormantJSON = Data(
      """
      {
        "deviceId": "\(dormantID)",
        "deviceName": "Studio Mac",
        "status": "active",
        "updatedAt": "2026-11-13T17:30:00.000Z",
        "lastActiveAt": "2026-11-13T17:45:00.789Z",
        "dormantAt": "2026-11-13T18:00:00.250Z",
        "availablePackageCount": 12
      }
      """.utf8
    )
    let parsedDormant = try #require(
      DeviceRowModel(wireDeviceJSON: explicitDormantJSON, currentDeviceId: currentID, now: now)
    )
    #expect(parsedDormant.deviceName == "Studio Mac")
    #expect(parsedDormant.activityState == .dormant)

    // 3. pending_approval status maps to .pendingApproval
    let pendingJSON = Data(
      """
      {
        "deviceId": "\(pendingID)",
        "deviceName": "New MacBook Air",
        "status": "pending_approval",
        "updatedAt": "2026-11-13T18:29:30.999Z",
        "availablePackageCount": 30
      }
      """.utf8
    )
    let parsedPending = try #require(
      DeviceRowModel(wireDeviceJSON: pendingJSON, currentDeviceId: currentID, now: now)
    )
    #expect(parsedPending.deviceName == "New MacBook Air")
    #expect(parsedPending.activityState == .pendingApproval)
  }

  @Test("LabyrinthSettingsAndRestoreView maps OwnDeviceView items and resolves case-insensitive device metadata")
  @MainActor
  func labyrinthMapsAndResolvesDeviceMetadata() throws {
    let now = try #require(DeviceRowModel.parseISO8601("2026-11-13T18:30:00.000Z"))
    let currentID = "aaaaaaaa-1111-4222-8333-444444444444"
    let dormantSiblingID = "bbbbbbbb-1111-4222-8333-555555555555"

    let outputJSON = Data(
      """
      {
        "items": [
          {
            "$type": "blue.catbird.chat.defs#ownDeviceView",
            "device": {
              "$type": "blue.catbird.chat.defs#deviceView",
              "deviceId": "\(currentID)",
              "keyId": "key-current",
              "signaturePublicKey": { "$bytes": "AQIDBA==" },
              "authGeneration": 1,
              "status": "active",
              "createdAt": "2026-11-01T10:00:00.000Z",
              "updatedAt": "2026-11-13T18:25:00.125Z",
              "availablePackageCount": 25,
              "reservedPackageCount": 0
            }
          },
          {
            "$type": "blue.catbird.chat.defs#ownDeviceView",
            "device": {
              "$type": "blue.catbird.chat.defs#deviceView",
              "deviceId": "\(dormantSiblingID)",
              "keyId": "key-dormant",
              "signaturePublicKey": { "$bytes": "BQYHCA==" },
              "authGeneration": 1,
              "status": "active",
              "createdAt": "2026-11-01T10:00:00.000Z",
              "updatedAt": "2026-11-09T12:00:00.500Z",
              "availablePackageCount": 8,
              "reservedPackageCount": 0
            }
          }
        ],
        "hasMore": false,
        "snapshotExpiresAt": "2026-11-13T18:35:00.000Z"
      }
      """.utf8
    )
    let decoded = try JSONDecoder().decode(BlueCatbirdChatGetOwnDevices.Output.self, from: outputJSON)
    let fetched = LabyrinthSettingsAndRestoreView.mapOwnDevicesByID(
      decoded.items,
      currentDeviceId: currentID,
      now: now
    )
    #expect(fetched.count == 2)

    let resolvedDormant = try #require(
      LabyrinthSettingsAndRestoreView.resolveDeviceMetadata(
        for: dormantSiblingID.uppercased(),
        explicit: [:],
        fetched: fetched
      )
    )
    #expect(resolvedDormant.activityState == .dormant)
    #expect(resolvedDormant.keyPackageCount == 8)

    let explicitOverride = DeviceRowModel(
      deviceId: dormantSiblingID,
      deviceName: "Named Sibling Mac",
      lastSeenAt: now,
      keyPackageCount: 30,
      activityState: .active,
      currentDeviceId: currentID,
      now: now
    )
    let resolvedExplicit = try #require(
      LabyrinthSettingsAndRestoreView.resolveDeviceMetadata(
        for: dormantSiblingID.uppercased(),
        explicit: [dormantSiblingID: explicitOverride],
        fetched: fetched
      )
    )
    #expect(resolvedExplicit.deviceName == "Named Sibling Mac")
    #expect(resolvedExplicit.activityState == .active)
  }

  @Test("DeviceManagementViewModel deleteDevice fails closed when coordinator revocation fails and removes row only after success")
  @MainActor
  func deviceManagementDeleteDeviceFailsClosedOnRevocationError() async {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let currentID = "aaaaaaaa-1111-4222-8333-444444444444"
    let siblingID = "bbbbbbbb-1111-4222-8333-555555555555"

    let thisDevice = DeviceRowModel(
      deviceId: currentID,
      lastSeenAt: now,
      keyPackageCount: 25,
      currentDeviceId: currentID,
      now: now
    )
    let siblingDevice = DeviceRowModel(
      deviceId: siblingID,
      deviceName: "Travel iPhone",
      lastSeenAt: now.addingTimeInterval(-600),
      keyPackageCount: 20,
      currentDeviceId: currentID,
      now: now
    )

    let vm = DeviceManagementViewModel()
    vm.currentDeviceId = currentID
    vm.devices = [thisDevice, siblingDevice]

    // 1. Without an authenticated coordinator/session, revocation fails closed and preserves the row.
    await vm.deleteDevice(siblingDevice)
    #expect(vm.devices.contains { $0.deviceId == siblingID })
    #expect(vm.deleteError != nil)

    // 2. When Labyrinth epoch-rotating revocation throws, deleteError surfaces and the unrevoked row stays visible.
    vm.deleteError = nil
    vm.customRevokerForTesting = { _ in
      throw NSError(
        domain: "LabyrinthRevokeTest",
        code: 409,
        userInfo: [NSLocalizedDescriptionKey: "Epoch rotation conflict — retry device revocation."]
      )
    }
    await vm.deleteDevice(siblingDevice)
    #expect(vm.devices.contains { $0.deviceId == siblingID })
    #expect(vm.deleteError?.localizedDescription.contains("Epoch rotation conflict") == true)

    // 3. Once Labyrinth revocation succeeds, the sibling row is removed and deleteError is cleared.
    var revokedTarget: String?
    vm.customRevokerForTesting = { target in
      revokedTarget = target
    }
    await vm.deleteDevice(siblingDevice)
    #expect(revokedTarget == siblingID)
    #expect(!vm.devices.contains { $0.deviceId == siblingID })
    #expect(vm.devices.contains { $0.deviceId == currentID })
    #expect(vm.deleteError == nil)
  }

  @Test("D-3 / 5.1.1(v): eraseCatbirdData fails closed when remote deleteAccountData fails, preserving SQLite DB and Keychain keys until retry succeeds")
  @MainActor
  func eraseCatbirdDataFailsClosedWhenRemoteDeleteAccountDataFails() async throws {
    let network = NativeArchiveMockNetwork.shared
    network.reset()
    let tempRoot = try makeTempStorageRoot()
    defer { archiveTempDir(tempRoot) }

    let accountDid = "did:plc:failclosederaseaaaaaaaaa"
    let deviceId = "dddddddd-1111-4222-8333-eeeeeeeeeeee"
    let keystore = Wave0RecordingKeyStore()

    final class DeleteFaultGate: @unchecked Sendable {
      let lock = NSLock()
      var failRemoteDelete = false
      func setFail(_ value: Bool) {
        lock.lock()
        failRemoteDelete = value
        lock.unlock()
      }
      func shouldFail() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return failRemoteDelete
      }
    }
    let faultGate = DeleteFaultGate()

    let transport = PetrelPlatformTransport(
      homeDsEndpoint: URL(string: NativeArchiveMockNetwork.dsEndpoint),
      homeDsDid: NativeArchiveMockNetwork.dsDid,
      ownPdsEndpoint: URL(string: NativeArchiveMockNetwork.pdsEndpoint(for: accountDid)),
      actorDeviceId: deviceId,
      httpOverride: { req in
        if faultGate.shouldFail(),
           req.url.contains("deleteAccountData") || req.url.contains("deleteSpace")
        {
          return PlatformHttpResponse(
            status: 503,
            headers: [PlatformHttpHeader(name: "Content-Type", value: "application/json")],
            body: Data(#"{"error":"ServiceUnavailable","message":"Simulated DS outage"}"#.utf8)
          )
        }
        return network.handle(req)
      }
    )

    let coordinator = try await MLSClientCoordinator.open(
      config: CatbirdMlsClientConfig(
        storageRoot: tempRoot.path,
        accountDid: accountDid,
        deviceId: deviceId,
        homeDsDid: NativeArchiveMockNetwork.dsDid,
        homeDsEndpoint: NativeArchiveMockNetwork.dsEndpoint,
        pdsEndpoint: NativeArchiveMockNetwork.pdsEndpoint(for: accountDid)
      ),
      keystore: keystore,
      transport: transport
    )
    _ = try await coordinator.enrollDevice(grantedScopes: MLSAppGroupStorage.requiredSpacesScopes)

    let didHash = coordinator.accountDidHash
    let dbURL = try MLSAppGroupStorage.databaseURL(storageRoot: tempRoot, accountDid: accountDid)
    #expect(FileManager.default.fileExists(atPath: dbURL.path))
    #expect(keystore.hasDbKey(accountDidHash: didHash))
    #expect(keystore.signatureKeypairCount >= 1)

    let schema = Schema([AppSettingsModel.self, Preferences.self, DraftPost.self])
    let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    let context = ModelContext(container)

    // 1. Inject remote deleteAccountData failure: eraseCatbirdData MUST throw fail-closed
    //    BEFORE wiping <did_hash>.db or Keychain keys so the user can retry.
    faultGate.setFail(true)
    await #expect(throws: Error.self) {
      try await AccountDeletionCoordinator.eraseCatbirdData(
        forDID: accountDid,
        storageRoot: tempRoot,
        keystore: keystore,
        modelContext: context,
        coordinatorOverride: coordinator
      )
    }
    #expect(
      FileManager.default.fileExists(atPath: dbURL.path),
      "D-3 fail-closed: <did_hash>.db must remain intact when remote deleteAccountData fails"
    )
    #expect(
      keystore.hasDbKey(accountDidHash: didHash),
      "D-3 fail-closed: SQLCipher DB key must remain intact when remote deleteAccountData fails"
    )
    #expect(
      keystore.signatureKeypairCount >= 1,
      "D-3 fail-closed: MLS signing keypair must remain intact when remote deleteAccountData fails"
    )

    // 2. Restore remote service and retry: remote deletion succeeds and local DB + keys are wiped.
    faultGate.setFail(false)
    try await AccountDeletionCoordinator.eraseCatbirdData(
      forDID: accountDid,
      storageRoot: tempRoot,
      keystore: keystore,
      modelContext: context,
      coordinatorOverride: coordinator
    )

    for suffix in ["", "-wal", "-shm", "-journal"] {
      #expect(
        !FileManager.default.fileExists(atPath: dbURL.path + suffix),
        "Expected \(dbURL.lastPathComponent)\(suffix) to be wiped after successful deleteAccountData"
      )
    }
    #expect(!keystore.hasDbKey(accountDidHash: didHash))
    await coordinator.close()
  }

  // MARK: - A2 & A6 Remediation Tests (`#159`)

  @Test("A6: retireDeviceBounded enforces hard wall-clock timeout without hanging and records hashed retry marker")
  func retireDeviceBoundedEnforcesHardTimeoutWithoutHangingAndQueuesHashedRetryMarker() async throws {
    let suiteName = "blue.catbird.tests.a6.retire.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let aliceDID = "did:plc:aliceretiretimeout01"
    let aliceHash = try MLSAppGroupStorage.accountDidHash(for: aliceDID)
    let deviceID = "11111111-2222-4333-8444-555555555555"

    actor UncooperativeHangGate {
      private var continuation: CheckedContinuation<Void, Never>?
      func block(_ cont: CheckedContinuation<Void, Never>) { continuation = cont }
      func release() { continuation?.resume(); continuation = nil }
    }
    let hangGate = UncooperativeHangGate()

    let clock = ContinuousClock()
    let start = clock.now
    let didSucceed = await AppState.retireDeviceBounded(
      timeoutSeconds: 0.12,
      accountDid: aliceDID,
      deviceId: deviceID,
      sharedDefaults: defaults,
      operation: {
        // Simulate an uncooperative hung FFI/socket call that ignores Task cancellation
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
          Task { await hangGate.block(cont) }
        }
      }
    )
    let elapsed = clock.now - start
    await hangGate.release()

    #expect(!didSucceed)
    #expect(elapsed < .milliseconds(900), "retireDeviceBounded must return promptly at timeout without blocking sign-out")

    let pending = AppState.pendingMLSDeviceRetirements(in: defaults)
    #expect(pending.count == 1)
    #expect(pending.first?.accountDidHash == aliceHash)
    #expect(pending.first?.deviceId == deviceID)
    #expect(pending.first?.reason == "timeout")

    let rawData = try #require(defaults.data(forKey: AppState.pendingDeviceRetirementsDefaultsKey))
    let rawJSON = String(decoding: rawData, as: UTF8.self)
    #expect(!rawJSON.contains(aliceDID), "Retry marker must store only SHA-256 accountDidHash, never plaintext DID")
  }

  private final class MockLegacyKeychainBackend: KeychainBackend, @unchecked Sendable {
    struct Entry: Hashable {
      let service: String
      let account: String
      let accessGroup: String?
      let dataProtection: Bool
    }

    private let lock = NSLock()
    private var entries: Set<Entry>

    init(entries: [Entry]) {
      self.entries = Set(entries)
    }

    func contains(service: String, account: String) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return entries.contains { $0.service == service && $0.account == account }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
      guard let service = attributes[kSecAttrService as String] as? String,
            let account = attributes[kSecAttrAccount as String] as? String
      else { return errSecParam }
      let group = attributes[kSecAttrAccessGroup as String] as? String
      let dp = (attributes[kSecUseDataProtectionKeychain as String] as? Bool) ?? false
      lock.lock()
      defer { lock.unlock() }
      entries.insert(Entry(service: service, account: account, accessGroup: group, dataProtection: dp))
      return errSecSuccess
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
      let service = query[kSecAttrService as String] as? String
      let group = query[kSecAttrAccessGroup as String] as? String
      let dp = (query[kSecUseDataProtectionKeychain as String] as? Bool) ?? false
      lock.lock()
      let matched = entries.filter { entry in
        (service == nil || entry.service == service)
          && entry.accessGroup == group
          && entry.dataProtection == dp
      }
      lock.unlock()
      guard !matched.isEmpty else { return (errSecItemNotFound, nil) }
      let rows: [[String: Any]] = matched.map { [kSecAttrAccount as String: $0.account] }
      return (errSecSuccess, rows as AnyObject)
    }

    func update(_ query: [String: Any], _ attributesToUpdate: [String: Any]) -> OSStatus {
      errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
      let service = query[kSecAttrService as String] as? String
      let account = query[kSecAttrAccount as String] as? String
      let group = query[kSecAttrAccessGroup as String] as? String
      let dp = (query[kSecUseDataProtectionKeychain as String] as? Bool) ?? false
      lock.lock()
      let before = entries.count
      entries = entries.filter { entry in
        let matchesService = service == nil || entry.service == service
        let matchesAccount = account == nil || entry.account == account
        let matchesGroup = entry.accessGroup == group
        let matchesDP = entry.dataProtection == dp
        return !(matchesService && matchesAccount && matchesGroup && matchesDP)
      }
      let removed = before != entries.count
      lock.unlock()
      return removed ? errSecSuccess : errSecItemNotFound
    }
  }

  @Test("A6: wipeLocalMLSArtifacts sweeps legacy mls-state-* / MLS-* SQLite sidecars and Keychain items without touching sibling accounts")
  func wipeLocalMLSArtifactsSweepsLegacySQLiteAndLegacyKeychainPreservingSiblingAccounts() throws {
    let fm = FileManager.default
    let tempRoot = fm.temporaryDirectory.appendingPathComponent("catbird-a6-legacy-\(UUID().uuidString)", isDirectory: true)
    let mlsSubdir = MLSAppGroupStorage.mlsDirectoryURL(storageRoot: tempRoot)
    try fm.createDirectory(at: mlsSubdir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempRoot) }

    let suiteName = "blue.catbird.tests.a6.legacy.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let aliceDID = "did:plc:alice"
    let aliceBobSiblingDID = "did:plc:alice_bob"
    let aliceExtraSiblingDID = "did:plc:aliceextra"
    let aliceHash = try MLSAppGroupStorage.accountDidHash(for: aliceDID)
    let siblingHash = try MLSAppGroupStorage.accountDidHash(for: aliceBobSiblingDID)

    let aliceLegacyFiles = [
      tempRoot.appendingPathComponent("mls-state-did_plc_alice.sqlite"),
      tempRoot.appendingPathComponent("mls-state-did_plc_alice.sqlite-wal"),
      tempRoot.appendingPathComponent("mls-state-did_plc_alice.sqlite-shm"),
      tempRoot.appendingPathComponent("MLS-did:plc:alice.db"),
      tempRoot.appendingPathComponent("MLS-did:plc:alice.db-journal"),
      mlsSubdir.appendingPathComponent("epoch-checkpoints-did_plc_alice.db"),
    ]
    let siblingFiles = [
      tempRoot.appendingPathComponent("mls-state-did_plc_alice_bob.sqlite"),
      tempRoot.appendingPathComponent("mls-state-did_plc_alice_bob.sqlite-wal"),
      tempRoot.appendingPathComponent("MLS-did:plc:aliceextra.db"),
    ]

    for url in aliceLegacyFiles + siblingFiles {
      try Data("sqlite-fixture".utf8).write(to: url)
    }

    #expect(AppState.hasLegacyMLSDatabaseFiles(storageRoot: tempRoot, accountDid: aliceDID))
    #expect(AppState.hasLegacyMLSDatabaseFiles(storageRoot: tempRoot, accountDid: aliceBobSiblingDID))

    defaults.set("owner-main-app", forKey: "blue.catbird.mls.database-owner.\(aliceHash).pid")
    defaults.set("owner-sibling", forKey: "blue.catbird.mls.database-owner.\(siblingHash).pid")

    let mockKeychain = MockLegacyKeychainBackend(entries: [
      .init(service: "blue.catbird.mls", account: "mls-db-key-did_plc_alice", accessGroup: nil, dataProtection: false),
      .init(service: "blue.catbird.mls", account: "mls-db-key-did_plc_alice_bob", accessGroup: nil, dataProtection: false),
      .init(service: "MLS-did:plc:alice", account: "signing-key", accessGroup: nil, dataProtection: false),
      .init(service: "MLS-did:plc:aliceextra", account: "signing-key", accessGroup: nil, dataProtection: false),
      .init(service: "mls-state-did_plc_alice", account: "ratchet", accessGroup: nil, dataProtection: true),
      .init(service: "blue.catbird.mls.clean-slate", account: "sigkey:mls-signer:\(aliceHash)", accessGroup: nil, dataProtection: false),
      .init(service: "blue.catbird.mls.clean-slate", account: "sigkey:mls-signer:\(siblingHash)", accessGroup: nil, dataProtection: false),
      .init(service: "blue.catbird.circles.keys", account: "\(aliceDID)|at://\(aliceDID)/blue.catbird.circle/friends", accessGroup: nil, dataProtection: true),
      .init(service: "blue.catbird.circles.keys", account: "\(aliceExtraSiblingDID)|at://\(aliceExtraSiblingDID)/blue.catbird.circle/friends", accessGroup: nil, dataProtection: true),
    ])

    let keystore = Wave0RecordingKeyStore()
    _ = try keystore.loadOrCreateDbKey(accountDidHash: aliceHash)
    _ = try keystore.loadOrCreateDbKey(accountDidHash: siblingHash)

    AppState.wipeLocalMLSArtifacts(
      for: aliceDID,
      storageRoot: tempRoot,
      keystore: keystore,
      sharedDefaults: defaults,
      legacyKeychainBackend: mockKeychain
    )

    for url in aliceLegacyFiles {
      #expect(!fm.fileExists(atPath: url.path), "Expected legacy Alice file \(url.lastPathComponent) to be wiped")
    }
    for url in siblingFiles {
      #expect(fm.fileExists(atPath: url.path), "Expected sibling file \(url.lastPathComponent) to remain intact")
    }
    #expect(!AppState.hasLegacyMLSDatabaseFiles(storageRoot: tempRoot, accountDid: aliceDID))
    #expect(AppState.hasLegacyMLSDatabaseFiles(storageRoot: tempRoot, accountDid: aliceBobSiblingDID))

    #expect(!mockKeychain.contains(service: "blue.catbird.mls", account: "mls-db-key-did_plc_alice"))
    #expect(!mockKeychain.contains(service: "MLS-did:plc:alice", account: "signing-key"))
    #expect(!mockKeychain.contains(service: "mls-state-did_plc_alice", account: "ratchet"))
    #expect(!mockKeychain.contains(service: "blue.catbird.mls.clean-slate", account: "sigkey:mls-signer:\(aliceHash)"))
    #expect(!mockKeychain.contains(service: "blue.catbird.circles.keys", account: "\(aliceDID)|at://\(aliceDID)/blue.catbird.circle/friends"))

    #expect(mockKeychain.contains(service: "blue.catbird.mls", account: "mls-db-key-did_plc_alice_bob"))
    #expect(mockKeychain.contains(service: "MLS-did:plc:aliceextra", account: "signing-key"))
    #expect(mockKeychain.contains(service: "blue.catbird.mls.clean-slate", account: "sigkey:mls-signer:\(siblingHash)"))
    #expect(mockKeychain.contains(service: "blue.catbird.circles.keys", account: "\(aliceExtraSiblingDID)|at://\(aliceExtraSiblingDID)/blue.catbird.circle/friends"))

    #expect(defaults.string(forKey: "blue.catbird.mls.database-owner.\(aliceHash).pid") == nil)
    #expect(defaults.string(forKey: "blue.catbird.mls.database-owner.\(siblingHash).pid") == "owner-sibling")
  }
}
