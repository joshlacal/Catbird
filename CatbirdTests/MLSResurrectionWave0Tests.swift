import CatbirdMLS
import CatbirdMLSCore
import CryptoKit
import SwiftCBOR
import Foundation
@testable import Petrel
import PetrelCatbird
import Security
import SwiftData
import Testing
import UserNotifications
@testable import Catbird
#if os(iOS)
import SwiftUI
import UIKit
#endif

final class Wave0RecordingKeyStore: PlatformKeyStore, @unchecked Sendable {
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

private final class RevocationReceiptKeychainBackend: KeychainBackend, @unchecked Sendable {
  private struct Key: Hashable {
    let service: String
    let account: String
  }

  private let lock = NSLock()
  private var entries: [Key: Data] = [:]
  private var receiptDeletionUnavailable = false

  func setReceiptDeletionUnavailable(_ unavailable: Bool) {
    lock.withLock { receiptDeletionUnavailable = unavailable }
  }
  private(set) var lastAccessibility: String?
  private(set) var lastSynchronizable: Bool?

  private func key(from attributes: [String: Any]) -> Key? {
    guard let service = attributes[kSecAttrService as String] as? String,
          let account = attributes[kSecAttrAccount as String] as? String
    else { return nil }
    return Key(service: service, account: account)
  }

  func add(_ attributes: [String: Any]) -> OSStatus {
    guard let key = key(from: attributes),
          let data = attributes[kSecValueData as String] as? Data
    else { return errSecParam }
    lock.lock()
    defer { lock.unlock() }
    guard entries[key] == nil else { return errSecDuplicateItem }
    entries[key] = data
    lastAccessibility = attributes[kSecAttrAccessible as String] as? String
    lastSynchronizable = attributes[kSecAttrSynchronizable as String] as? Bool
    return errSecSuccess
  }

  func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
    guard let key = key(from: query) else { return (errSecParam, nil) }
    lock.lock()
    defer { lock.unlock() }
    guard let data = entries[key] else { return (errSecItemNotFound, nil) }
    return (errSecSuccess, data as NSData)
  }

  func update(_ query: [String: Any], _ attributesToUpdate: [String: Any]) -> OSStatus {
    guard let key = key(from: query),
          let data = attributesToUpdate[kSecValueData as String] as? Data
    else { return errSecParam }
    lock.lock()
    defer { lock.unlock() }
    guard entries[key] != nil else { return errSecItemNotFound }
    entries[key] = data
    return errSecSuccess
  }

  func delete(_ query: [String: Any]) -> OSStatus {
    guard let key = key(from: query) else { return errSecParam }
    lock.lock()
    defer { lock.unlock() }
    if receiptDeletionUnavailable { return errSecInteractionNotAllowed }
    return entries.removeValue(forKey: key) == nil ? errSecItemNotFound : errSecSuccess
  }

  func storedData(service: String, account: String) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return entries[Key(service: service, account: account)]
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
      modelContext: context,
      skipRemoteMLSErasure: true,
      accountRemovalOverride: { _ in }
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

  @Test("NotificationService shows nothing from a generic fallback preview")
  func notificationServiceFailsClosedOnGenericFallback() {
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
      fallbackGeneric: true,
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

  @Test("Passkey recovery requires an eligible credential from the selected relying party")
  func passkeyRecoveryRequiresBackupEligibility() throws {
    #expect(LabyrinthPasskeyPolicy.relyingParty == "passkey.catbird.blue")
    let rpHash = Array(SHA256.hash(data: Data(LabyrinthPasskeyPolicy.relyingParty.utf8)))
    func authenticatorData(flags: UInt8) -> Data {
      Data(rpHash + [flags, 0, 0, 0, 0])
    }
    func attestation(flags: UInt8) -> Data {
      let key = CBOR.map([.unsignedInt(1): .unsignedInt(2), .unsignedInt(3): .negativeInt(6),
                          .negativeInt(0): .unsignedInt(1), .negativeInt(1): .byteString([UInt8](repeating: 1, count: 32)),
                          .negativeInt(2): .byteString([UInt8](repeating: 2, count: 32))]).encode()
      let attested = Array(authenticatorData(flags: flags)) + [UInt8](repeating: 0, count: 16) + [0, 1, 42] + key
      return Data(CBOR.map([.utf8String("fmt"): .utf8String("none"), .utf8String("attStmt"): .map([:]),
                            .utf8String("authData"): .byteString(attested)]).encode())
    }
    #expect(LabyrinthPasskeyPolicy.isBackupEligible(attestation: attestation(flags: 0x4d)))
    #expect(LabyrinthPasskeyPolicy.isBackupEligible(authenticatorData: authenticatorData(flags: 0x0d), registration: false))
    #expect(!LabyrinthPasskeyPolicy.isBackupEligible(attestation: attestation(flags: 0x49)))
    #expect(!LabyrinthPasskeyPolicy.isBackupEligible(authenticatorData: authenticatorData(flags: 0x09), registration: false))
    #expect(!LabyrinthPasskeyPolicy.isBackupEligible(attestation: attestation(flags: 0x45)))
    #expect(!LabyrinthPasskeyPolicy.isBackupEligible(authenticatorData: authenticatorData(flags: 0x4d), registration: true))
    #expect(!LabyrinthPasskeyPolicy.isBackupEligible(attestation: Data([0xff])))
    #expect(!LabyrinthPasskeyPolicy.isBackupEligible(attestation: nil))
    #expect(!LabyrinthPasskeyPolicy.isBackupEligible(authenticatorData: Data(repeating: 0, count: 37), registration: false))
    #expect(LabyrinthPasskeyPolicy.newUserHandle().count == 32)
    #expect(LabyrinthPasskeyPolicy.newUserHandle() != LabyrinthPasskeyPolicy.newUserHandle())
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

    let receipts = RevocationReceiptKeychainBackend()
    for hash in [aliceHash, bobHash] {
      try AppState.storePendingMLSRecoveryCodeReceipt(
        .init(recoveryCode: "test-code", accountDidHash: hash, recoveryGeneration: 1), backend: receipts
      )
    }

    AppState.wipeLocalMLSArtifacts(
      for: aliceDID,
      storageRoot: tempRoot,
      keystore: keystore,
      sharedDefaults: defaults,
      legacyKeychainBackend: receipts
    )

    #expect(try AppState.loadPendingMLSRecoveryCodeReceipt(forDID: aliceDID, backend: receipts) == nil)
    #expect(try AppState.loadPendingMLSRecoveryCodeReceipt(forDID: bobDID, backend: receipts) != nil)
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

  @Test("A backup counts as passkey-linked only while a passkey method is unrevoked")
  func passkeyLinkedReadsServerMethods() {
    #expect(!LabyrinthPasskeyPolicy.hasUsablePasskey([]))
    #expect(!LabyrinthPasskeyPolicy.hasUsablePasskey([("code", false), ("passkey", true)]))
    #expect(LabyrinthPasskeyPolicy.hasUsablePasskey([("passkey", true), ("passkey", false)]))
    let stopped = LabyrinthPasskeyPolicy.unreachableBackupMessage("HTTP 400")
    #expect(stopped.hasPrefix("No passkey was created"))
    #expect(stopped.hasSuffix("HTTP 400"))
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

    // 2. A generic fallback claiming senderDid == Alice MUST NOT be silently suppressed
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
      fallbackGeneric: true,
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

  @Test("DeviceManagementViewModel fails closed on revocation error and preserves the replacement recovery report on success")
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

    // 3. A returned per-step report is not treated as success unless the directory confirms revoke.
    let incompleteReceipt = AppState.PendingMLSDeviceRevocationReceipt(
      report: DeviceRevocationReport(
        targetDeviceId: siblingID,
        dsRevoked: false,
        groupsUpdated: 0,
        labyrinthRotated: false,
        newEpochSeq: nil,
        pdsRecordDeleted: false,
        rekeyedRecoveryCode: nil,
        rekeyedPasskeyIds: []
      ),
      accountDidHash: String(repeating: "a", count: 64),
      recordedAtEpochSeconds: 1_749_999_999
    )
    vm.customRevokerForTesting = { _ in incompleteReceipt }
    await vm.deleteDevice(siblingDevice)
    #expect(vm.devices.contains { $0.deviceId == siblingID })
    #expect(vm.deleteError?.localizedDescription == DeviceManagementViewModel.incompleteRevocationMessage)
    #expect(vm.revocationReceipt == incompleteReceipt)

    // 4. Once unified revocation succeeds, the sibling row is removed and its complete replacement
    //    recovery report remains available for the non-dismissible acknowledgement sheet.
    let expectedReceipt = AppState.PendingMLSDeviceRevocationReceipt(
      report: DeviceRevocationReport(
        targetDeviceId: siblingID,
        dsRevoked: true,
        groupsUpdated: 3,
        labyrinthRotated: true,
        newEpochSeq: 9,
        pdsRecordDeleted: true,
        rekeyedRecoveryCode: "ABCD-EFGH-IJKL-MNOP",
        rekeyedPasskeyIds: [Data([0x01, 0x02])]
      ),
      accountDidHash: String(repeating: "a", count: 64),
      recordedAtEpochSeconds: 1_750_000_000
    )
    var revokedTarget: String?
    vm.customRevokerForTesting = { target in
      revokedTarget = target
      return expectedReceipt
    }
    await vm.deleteDevice(siblingDevice)
    #expect(revokedTarget == siblingID)
    #expect(!vm.devices.contains { $0.deviceId == siblingID })
    #expect(vm.devices.contains { $0.deviceId == currentID })
    #expect(vm.deleteError == nil)
    #expect(vm.revocationReceipt == expectedReceipt)
    #expect(vm.revocationReceipt?.replacementRecoveryCode == "ABCD-EFGH-IJKL-MNOP")
    #expect(vm.revocationReceipt?.rekeyedPasskeyCount == 1)
    #expect(vm.recoveryNeedsAttention)
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
        coordinatorOverride: coordinator,
        accountRemovalOverride: { _ in }
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
      coordinatorOverride: coordinator,
      accountRemovalOverride: { _ in }
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

  @Test("Account removal suppresses both receipts across restart until Keychain unlocks, without erasing new or sibling receipts")
  func unavailableKeychainRetainsAccountScopedReceiptPurge() throws {
    let suite = "CatbirdReceiptPurge-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = try makeTempStorageRoot()
    defer { archiveTempDir(root) }
    let backend = RevocationReceiptKeychainBackend()
    let alice = "did:plc:lockedreceiptalice"
    let bob = "did:plc:lockedreceiptbob"
    let aliceHash = try MLSAppGroupStorage.accountDidHash(for: alice)
    let bobHash = try MLSAppGroupStorage.accountDidHash(for: bob)
    let old = AppState.PendingMLSRecoveryCodeReceipt(recoveryCode: "OLD", accountDidHash: aliceHash, recoveryGeneration: 1)
    let fresh = AppState.PendingMLSRecoveryCodeReceipt(recoveryCode: "FRESH", accountDidHash: aliceHash, recoveryGeneration: 2)
    let sibling = AppState.PendingMLSRecoveryCodeReceipt(recoveryCode: "SIBLING", accountDidHash: bobHash, recoveryGeneration: 1)
    try AppState.storePendingMLSRecoveryCodeReceipt(old, backend: backend, purgeDefaults: defaults)
    try AppState.storePendingMLSRecoveryCodeReceipt(sibling, backend: backend, purgeDefaults: defaults)
    let report = AppState.PendingMLSDeviceRevocationReceipt(report: DeviceRevocationReport(
      targetDeviceId: UUID().uuidString, dsRevoked: true, groupsUpdated: 1, labyrinthRotated: true,
      newEpochSeq: 1, pdsRecordDeleted: true, rekeyedRecoveryCode: "OLD", rekeyedPasskeyIds: []
    ), accountDidHash: aliceHash)
    try AppState.storePendingMLSDeviceRevocationReceipt(report, backend: backend, purgeDefaults: defaults)
    backend.setReceiptDeletionUnavailable(true)
    AppState.wipeLocalMLSArtifacts(for: alice, storageRoot: root, keystore: Wave0RecordingKeyStore(),
      sharedDefaults: defaults, legacyKeychainBackend: backend, receiptPurgeDefaults: defaults)

    let reopened = try #require(UserDefaults(suiteName: suite))
    #expect(reopened.persistentDomain(forName: suite)?.keys.sorted() == ["blue.catbird.mls.receipt-purge.\(aliceHash)"])
    #expect(throws: Error.self) { try AppState.loadPendingMLSRecoveryCodeReceipt(forDID: alice, backend: backend, purgeDefaults: reopened) }
    #expect(throws: Error.self) { try AppState.loadPendingMLSDeviceRevocationReceipt(forDID: alice, backend: backend, purgeDefaults: reopened) }
    #expect(throws: Error.self) { try AppState.storePendingMLSRecoveryCodeReceipt(fresh, backend: backend, purgeDefaults: reopened) }
    #expect(try AppState.loadPendingMLSRecoveryCodeReceipt(forDID: bob, backend: backend, purgeDefaults: reopened) == sibling)

    backend.setReceiptDeletionUnavailable(false)
    try AppState.storePendingMLSRecoveryCodeReceipt(fresh, backend: backend, purgeDefaults: reopened)
    #expect(try AppState.loadPendingMLSDeviceRevocationReceipt(forDID: alice, backend: backend, purgeDefaults: reopened) == nil)
    #expect(try AppState.loadPendingMLSRecoveryCodeReceipt(forDID: alice, backend: backend, purgeDefaults: reopened) == fresh)
    #expect(try AppState.loadPendingMLSRecoveryCodeReceipt(forDID: bob, backend: backend, purgeDefaults: reopened) == sibling)
    #expect(reopened.persistentDomain(forName: suite)?.isEmpty != false)
  }

  @Test("Lost-device reports round-trip only through this-device-only Keychain storage until acknowledgement")
  func deviceRevocationReceiptUsesDurableDeviceOnlyStorage() throws {
    let did = "did:plc:revocationreceipt01"
    let didHash = try MLSAppGroupStorage.accountDidHash(for: did)
    let backend = RevocationReceiptKeychainBackend()
    let receipt = AppState.PendingMLSDeviceRevocationReceipt(
      report: DeviceRevocationReport(
        targetDeviceId: "aaaaaaaa-2222-4333-8444-bbbbbbbbbbbb",
        dsRevoked: true,
        groupsUpdated: 4,
        labyrinthRotated: true,
        newEpochSeq: 12,
        pdsRecordDeleted: true,
        rekeyedRecoveryCode: "REPLACEMENT-CODE-ONLY",
        rekeyedPasskeyIds: [Data([0xA1]), Data([0xB2])]
      ),
      accountDidHash: didHash,
      recordedAtEpochSeconds: 1_760_000_000
    )

    try AppState.storePendingMLSDeviceRevocationReceipt(receipt, backend: backend)
    let restored = try AppState.loadPendingMLSDeviceRevocationReceipt(forDID: did, backend: backend)
    #expect(restored == receipt)
    #expect(restored?.replacementRecoveryCode == "REPLACEMENT-CODE-ONLY")
    #expect(restored?.rekeyedPasskeyCount == 2)
    #expect(backend.lastAccessibility == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))
    #expect(backend.lastSynchronizable == false)

    let raw = try #require(
      backend.storedData(
        service: AppState.deviceRevocationReceiptKeychainService,
        account: didHash
      )
    )
    let rawJSON = String(decoding: raw, as: UTF8.self)
    #expect(!rawJSON.contains(did))
    #expect(!rawJSON.localizedCaseInsensitiveContains("accessToken"))
    #expect(!rawJSON.localizedCaseInsensitiveContains("bearer"))

    try AppState.clearPendingMLSDeviceRevocationReceipt(forDID: did, backend: backend)
    #expect(try AppState.loadPendingMLSDeviceRevocationReceipt(forDID: did, backend: backend) == nil)
  }

  @Test("Recovery acknowledgement commits native attention before clearing the only durable code")
  @MainActor
  func deviceRevocationAcknowledgementOrderIsFailClosed() async throws {
    struct NativeFailure: Error {}
    var events: [String] = []

    do {
      try await AppState.completeMLSDeviceRevocationAcknowledgement(
        nativeAcknowledger: {
          events.append("native")
          throw NativeFailure()
        },
        receiptClearer: {
          events.append("clear-keychain")
        }
      )
      Issue.record("Expected native acknowledgement failure")
    } catch is NativeFailure {
      #expect(events == ["native"])
    } catch {
      Issue.record("Unexpected acknowledgement error: \(error)")
    }

    events.removeAll()
    try await AppState.completeMLSDeviceRevocationAcknowledgement(
      nativeAcknowledger: {
        events.append("native")
      },
      receiptClearer: {
        events.append("clear-keychain")
      }
    )
    #expect(events == ["native", "clear-keychain"])
  }

  @Test("Generated recovery code survives relaunch and acknowledgement crash windows")
  @MainActor
  func generatedRecoveryCodeReceiptIsCrashDurableAndFailClosed() async throws {
    struct SimulatedKeychainClearCrash: Error {}

    let did = "did:plc:generatedrecovery01"
    let didHash = try MLSAppGroupStorage.accountDidHash(for: did)
    let backend = RevocationReceiptKeychainBackend()
    let receipt = AppState.PendingMLSRecoveryCodeReceipt(
      recoveryCode: "GENERATED-RECOVERY-CODE-ONLY",
      accountDidHash: didHash,
      requiresDeviceSafetyConfirmation: true,
      recordedAtEpochSeconds: 1_760_000_100
    )

    try AppState.storePendingMLSRecoveryCodeReceipt(receipt, backend: backend)
    #expect(try AppState.loadPendingMLSRecoveryCodeReceipt(forDID: did, backend: backend) == receipt)
    #expect(backend.lastAccessibility == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))
    #expect(backend.lastSynchronizable == false)

    let raw = try #require(
      backend.storedData(
        service: AppState.recoveryCodeReceiptKeychainService,
        account: didHash
      )
    )
    let rawJSON = String(decoding: raw, as: UTF8.self)
    #expect(!rawJSON.contains(did))
    #expect(!rawJSON.localizedCaseInsensitiveContains("accessToken"))
    #expect(!rawJSON.localizedCaseInsensitiveContains("bearer"))

    var events: [String] = []
    do {
      try await AppState.completeMLSDeviceRevocationAcknowledgement(
        nativeAcknowledger: {
          events.append("native")
        },
        receiptClearer: {
          events.append("clear-keychain")
          throw SimulatedKeychainClearCrash()
        }
      )
      Issue.record("Expected simulated crash while clearing the local receipt")
    } catch is SimulatedKeychainClearCrash {
      #expect(events == ["native", "clear-keychain"])
    } catch {
      Issue.record("Unexpected acknowledgement error: \(error)")
    }

    #expect(
      try AppState.loadPendingMLSRecoveryCodeReceipt(forDID: did, backend: backend) == receipt,
      "A native-success/local-clear failure must leave the one-shot code reloadable for idempotent re-acknowledgement"
    )

    events.removeAll()
    try await AppState.completeMLSDeviceRevocationAcknowledgement(
      nativeAcknowledger: {
        events.append("native")
      },
      receiptClearer: {
        events.append("clear-keychain")
        try AppState.clearPendingMLSRecoveryCodeReceipt(forDID: did, backend: backend)
      }
    )
    #expect(events == ["native", "clear-keychain"])
    #expect(try AppState.loadPendingMLSRecoveryCodeReceipt(forDID: did, backend: backend) == nil)
  }

  #if os(iOS)
  @Test("Hosted deletion renders the separate non-atomic backup-erasure warning before any request")
  @MainActor
  func hostedDeletionIrreversibleBoundaryHasSimulatorSurfaceProof() async throws {
    let restoreAccessibility = AppAccessibility.enable()
    defer { restoreAccessibility() }
    try #require(ProcessInfo.processInfo.arguments.contains("--settings-ui-fixture"))
    let manager = AppStateManager.shared
    let startupIsIsolated =
      manager.authentication.client == nil
      && manager.authentication.state.userDID == nil
      && !manager.authentication.state.isAuthenticating
      && manager.lifecycle.appState == nil
      && manager.lifecycle.userDID == nil
    try #require(startupIsIsolated, "Settings fixture must not restore authentication or an app lifecycle")
    try #require(SecuritySurfaceRefusalURLProtocol.install())
    defer { SecuritySurfaceRefusalURLProtocol.uninstall() }
    #if DEBUG
    let previousNetworkProtocols = NetworkService.getNetworkTestProtocolClasses()
    try #require(previousNetworkProtocols == nil)
    NetworkService.setNetworkTestProtocolClasses([SecuritySurfaceRefusalURLProtocol.self])
    defer { NetworkService.setNetworkTestProtocolClasses(previousNetworkProtocols) }
    #endif
    let priorLifecycle = manager.lifecycle
    let client = await ATProtoClient(baseURL: URL(string: "https://127.0.0.1")!)
    let did = "did:plc:deletionsurfaceproof"
    let appState = AppState(userDID: did, client: client)
    manager.setLifecycleForTesting(.authenticated(appState))

    var host: SecuritySurfaceHost?
    defer {
      host?.close()
      manager.setLifecycleForTesting(priorLifecycle)
      appState.cleanup()
    }

    let schema = Schema([AppSettingsModel.self, Preferences.self, DraftPost.self])
    let container = try ModelContainer(
      for: schema,
      configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
    )
    let target = AccountDeletionTarget(
      did: did,
      handle: "surface-proof.test",
      accountRevision: manager.settingsAccountContextRevision
    )
    let rendered = AccountDeletionSheet(target: target)
      .environment(appState)
      .modelContainer(container)
    let surface = try makeSecuritySurfaceHost(rendered)
    host = surface
    await settleSecuritySurface(surface)
    try captureSecuritySurface(
      surface,
      name: "hosted-deletion-initial",
      detail: "Initial production account-deletion sheet before local fixture input or any destructive confirmation."
    )

    let password = try #require(
      securityTextField(
        identifier: "AccountDeletion.Password",
        placeholder: "Account password",
        in: surface
      )
    )
    password.text = "local-fixture-password"
    password.sendActions(for: .editingChanged)
    await settleSecuritySurface(surface)

    let manualCode = try #require(
      await revealSecurityElement(identifier: "AccountDeletion.ToggleCodeEntry", in: surface)
    )
    #expect(manualCode.object.accessibilityActivate())
    await settleSecuritySurface(surface)

    _ = try #require(
      await revealSecurityElement(identifier: "AccountDeletion.ConfirmationToken", in: surface)
    )
    let confirmationCode = try #require(
      securityTextField(
        identifier: "AccountDeletion.ConfirmationToken",
        placeholder: "Email confirmation code",
        in: surface
      )
    )
    confirmationCode.text = "local-fixture-code"
    confirmationCode.sendActions(for: .editingChanged)

    _ = try #require(
      await revealSecurityElement(identifier: "AccountDeletion.ConfirmDelete", in: surface)
    )
    let deleteButton = try #require(
      await waitForSecurityElement(
        identifier: "AccountDeletion.ConfirmDelete",
        enabled: true,
        in: surface
      )
    )
    #expect(deleteButton.object.accessibilityActivate())

    let warningVisible = await waitForSecuritySurface(in: surface) {
      let warningText = securityLabels(in: surface).joined(separator: " ")
      return warningText.localizedCaseInsensitiveContains("cannot validate the email code")
        && warningText.localizedCaseInsensitiveContains("erase encrypted cloud backups first")
    }
    #expect(warningVisible)
    let warningPresentationSettled = await waitForSecuritySurface(in: surface) {
      guard let presented = surface.controller.presentedViewController else { return false }
      return presented.viewIfLoaded?.window != nil
        && !presented.isBeingPresented
        && presented.transitionCoordinator == nil
    }
    #expect(warningPresentationSettled)
    #expect(
      securityLabels(in: surface).contains {
        $0.localizedCaseInsensitiveContains("I Understand the Risk")
      }
    )
    #expect(SecuritySurfaceRefusalURLProtocol.attemptedWrites == 0)
    try captureSecuritySurface(
      surface,
      name: "hosted-deletion-non-atomic-warning",
      detail: "Dedicated warning is visible before the irreversible action; the fixture activated no confirmation action and observed zero HTTP writes."
    )
  }

  @Test("Recovery attention renders the durable code and becomes ready only after the real acknowledgement path")
  @MainActor
  func recoveryAttentionToSavedAcknowledgementHasSimulatorSurfaceProof() async throws {
    let restoreAccessibility = AppAccessibility.enable()
    defer { restoreAccessibility() }
    try #require(ProcessInfo.processInfo.arguments.contains("--settings-ui-fixture"))
    let startupManager = AppStateManager.shared
    let startupIsIsolated =
      startupManager.authentication.client == nil
      && startupManager.authentication.state.userDID == nil
      && !startupManager.authentication.state.isAuthenticating
      && startupManager.lifecycle.appState == nil
      && startupManager.lifecycle.userDID == nil
    try #require(startupIsIsolated, "Settings fixture must not restore authentication or an app lifecycle")
    try #require(SecuritySurfaceRefusalURLProtocol.install())
    defer { SecuritySurfaceRefusalURLProtocol.uninstall() }
    #if DEBUG
    let previousNetworkProtocols = NetworkService.getNetworkTestProtocolClasses()
    try #require(previousNetworkProtocols == nil)
    NetworkService.setNetworkTestProtocolClasses([SecuritySurfaceRefusalURLProtocol.self])
    defer { NetworkService.setNetworkTestProtocolClasses(previousNetworkProtocols) }
    #endif

    let network = NativeArchiveMockNetwork.shared
    network.reset()
    defer { network.reset() }
    let tempRoot = try makeTempStorageRoot()
    defer { archiveTempDir(tempRoot) }
    let accountDid = "did:plc:recoverysurfaceproofaaaa"
    let deviceId = UUID().uuidString.lowercased()
    try? AppState.clearPendingMLSRecoveryCodeReceipt(forDID: accountDid)
    defer { try? AppState.clearPendingMLSRecoveryCodeReceipt(forDID: accountDid) }

    let transport = PetrelPlatformTransport(
      homeDsEndpoint: URL(string: NativeArchiveMockNetwork.dsEndpoint),
      homeDsDid: NativeArchiveMockNetwork.dsDid,
      ownPdsEndpoint: URL(string: NativeArchiveMockNetwork.pdsEndpoint(for: accountDid)),
      actorDeviceId: deviceId,
      httpOverride: { request in network.handle(request) }
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
      keystore: Wave0RecordingKeyStore(),
      transport: transport
    )

    do {
      _ = try await coordinator.enrollDevice(
        grantedScopes: MLSAppGroupStorage.requiredSpacesScopes
      )
      let earlierCode = try await coordinator.setupRecoveryCodeWithReceipt()
      let earlierReceipt = AppState.PendingMLSRecoveryCodeReceipt(
        recoveryCode: earlierCode.code, accountDidHash: coordinator.accountDidHash,
        recoveryGeneration: earlierCode.recoveryGeneration
      )
      let recoveryCode = try await coordinator.setupRecoveryCodeWithReceipt()
      await #expect(throws: Error.self) {
        _ = try await coordinator.acknowledgeRecoveryGeneration(expectedGeneration: earlierCode.recoveryGeneration)
      }
      let statusAfterMint = try await coordinator.labyrinthStatus()
      #expect(statusAfterMint.recoveryGeneration == recoveryCode.recoveryGeneration)
      #expect(!earlierReceipt.isCurrent(for: statusAfterMint))
      #expect(statusAfterMint.recoveryNeedsAttention)

      let client = await ATProtoClient(baseURL: URL(string: "https://127.0.0.1")!)
      let appState = AppState(userDID: accountDid, client: client)
      defer { appState.cleanup() }
      _ = try appState.retainGeneratedMLSRecoveryCode(
        recoveryCode,
        requiresDeviceSafetyConfirmation: false
      )

      var host: SecuritySurfaceHost?
      defer { host?.close() }
      let rendered = NavigationStack {
        LabyrinthSettingsAndRestoreView(coordinator: coordinator)
      }
      .environment(appState)
      let surface = try makeSecuritySurfaceHost(rendered)
      host = surface

      let attentionVisible = await waitForSecuritySurface(in: surface) {
        securityLabels(in: surface).contains {
          $0.localizedCaseInsensitiveContains("Not Ready")
        }
      }
      #expect(attentionVisible)
      try captureSecuritySurface(
        surface,
        name: "recovery-attention-not-ready",
        detail: "The actual coordinator reports recovery attention and both recovery readiness rows render Not Ready."
      )

      _ = try #require(
        await revealSecurityElement(
          identifier: "labyrinth-acknowledge-generated-recovery-code",
          in: surface
        )
      )
      #expect(
        securityLabels(in: surface).contains {
          $0.localizedCaseInsensitiveContains("Save this 40-character recovery code")
        }
      )
      try captureSecuritySurface(
        surface,
        name: "recovery-code-saved-acknowledgement-ready",
        detail: "The synthetic one-shot code is rendered by the production recovery view and the explicit save acknowledgement is enabled."
      )
      let acknowledge = try #require(
        await waitForSecurityElement(
          identifier: "labyrinth-acknowledge-generated-recovery-code",
          enabled: true,
          in: surface
        )
      )
      #expect(acknowledge.object.accessibilityActivate())

      var becameReady = false
      for _ in 0..<120 {
        await settleSecuritySurface(surface, passes: 1)
        let nativeStatus = try? await coordinator.labyrinthStatus()
        if appState.pendingMLSRecoveryCodeReceipt == nil,
           nativeStatus?.recoveryNeedsAttention == false
        {
          becameReady = true
          break
        }
      }
      #expect(becameReady)
      securityScrollView(in: surface)?.setContentOffset(.zero, animated: false)
      await settleSecuritySurface(surface)
      #expect(
        !securityLabels(in: surface).contains {
          $0.localizedCaseInsensitiveContains("Not Ready")
        }
      )
      #expect(try AppState.loadPendingMLSRecoveryCodeReceipt(forDID: accountDid) == nil)
      #expect(SecuritySurfaceRefusalURLProtocol.attemptedWrites == 0)
      try captureSecuritySurface(
        surface,
        name: "recovery-ready-after-native-ack",
        detail: "The production button completed native acknowledgement before Keychain clearing; native attention is false and the durable receipt is absent."
      )
    } catch {
      await coordinator.close()
      throw error
    }
    await coordinator.close()
  }

  @MainActor
  private func makeSecuritySurfaceHost<Content: View>(
    _ content: Content
  ) throws -> SecuritySurfaceHost {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    )
    return SecuritySurfaceHost(scene: scene, content: AnyView(content))
  }

  @MainActor
  private func settleSecuritySurface(
    _ host: SecuritySurfaceHost,
    passes: Int = 12
  ) async {
    for _ in 0..<passes {
      host.window.setNeedsLayout()
      host.window.layoutIfNeeded()
      host.controller.view.layoutIfNeeded()
      try? await Task.sleep(for: .milliseconds(25))
    }
  }

  @MainActor
  private func securityDescendants(of view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap { securityDescendants(of: $0) }
  }

  @MainActor
  private func securityTextField(
    identifier: String,
    placeholder: String,
    in host: SecuritySurfaceHost
  ) -> UITextField? {
    let fields = securityDescendants(of: host.window).compactMap { $0 as? UITextField }
    return fields.first { $0.accessibilityIdentifier == identifier }
      ?? fields.first { $0.placeholder == placeholder }
  }

  @MainActor
  private func securityElements(in host: SecuritySurfaceHost) -> [AppAccessibility.Element] {
    AppAccessibility.elements(in: host.controller.view)
  }

  @MainActor
  private func securityLabels(in host: SecuritySurfaceHost) -> [String] {
    let accessibilityLabels = securityElements(in: host).compactMap(\.label)
    let nativeLabels = securityDescendants(of: host.window).compactMap(\.accessibilityLabel)
    return Array(Set(accessibilityLabels + nativeLabels)).sorted()
  }

  @MainActor
  private func waitForSecuritySurface(
    in host: SecuritySurfaceHost,
    predicate: @MainActor () -> Bool
  ) async -> Bool {
    for _ in 0..<120 {
      await settleSecuritySurface(host, passes: 1)
      if predicate() { return true }
    }
    return false
  }

  @MainActor
  private func waitForSecurityElement(
    identifier: String,
    enabled: Bool? = nil,
    in host: SecuritySurfaceHost
  ) async -> AppAccessibility.Element? {
    for _ in 0..<120 {
      await settleSecuritySurface(host, passes: 1)
      if let element = securityElements(in: host).first(where: { $0.identifier == identifier }) {
        let isEnabled = !element.traits.contains(.notEnabled)
        if enabled.map({ $0 == isEnabled }) ?? true {
          return element
        }
      }
    }
    return nil
  }

  @MainActor
  private func securityScrollView(in host: SecuritySurfaceHost) -> UIScrollView? {
    securityDescendants(of: host.controller.view)
      .compactMap { $0 as? UIScrollView }
      .filter { $0.contentSize.height > $0.bounds.height + 1 }
      .max { $0.contentSize.height < $1.contentSize.height }
  }

  @MainActor
  private func revealSecurityElement(
    identifier: String,
    in host: SecuritySurfaceHost
  ) async -> AppAccessibility.Element? {
    if let visible = securityElements(in: host).first(where: {
      $0.identifier == identifier && host.window.bounds.intersects($0.frame)
    }) {
      return visible
    }
    guard let scrollView = securityScrollView(in: host) else { return nil }
    let maxOffset = max(
      0,
      scrollView.contentSize.height - scrollView.bounds.height
        + scrollView.adjustedContentInset.bottom
    )
    var offset: CGFloat = 0
    while offset <= maxOffset + 1 {
      scrollView.setContentOffset(
        CGPoint(x: scrollView.contentOffset.x, y: min(offset, maxOffset)),
        animated: false
      )
      await settleSecuritySurface(host, passes: 2)
      if let visible = securityElements(in: host).first(where: {
        $0.identifier == identifier && host.window.bounds.intersects($0.frame)
      }) {
        return visible
      }
      offset += 120
    }
    return nil
  }

  @MainActor
  private func captureSecuritySurface(
    _ host: SecuritySurfaceHost,
    name: String,
    detail: String
  ) throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    var drewHierarchy = false
    let image = UIGraphicsImageRenderer(bounds: host.window.bounds, format: format).image { _ in
      drewHierarchy = host.window.drawHierarchy(
        in: host.window.bounds,
        afterScreenUpdates: true
      )
    }
    #expect(drewHierarchy)
    let png = try #require(image.pngData())
    Attachment.record(Array(png), named: "security-surface-\(name).png")

    let elements = securityElements(in: host)
      .prefix(80)
      .map {
        "id=\($0.identifier ?? ""); label=\($0.label ?? ""); traits=\($0.traits.rawValue); frame=\($0.frame)"
      }
      .joined(separator: "\n")
    let receipt = """
    \(detail)
    window=\(host.window.bounds)
    refusalRequests=\(SecuritySurfaceRefusalURLProtocol.requestCount)
    refusalWrites=\(SecuritySurfaceRefusalURLProtocol.attemptedWrites)
    accessibility:
    \(elements)
    """
    Attachment.record(
      Array(receipt.utf8),
      named: "security-surface-\(name)-receipt.txt"
    )

    if let directory = ProcessInfo.processInfo.environment["CATBIRD_SECURITY_SURFACE_DIR"] {
      let output = URL(fileURLWithPath: directory, isDirectory: true)
      try FileManager.default.createDirectory(
        at: output,
        withIntermediateDirectories: true
      )
      try png.write(
        to: output.appendingPathComponent("security-surface-\(name).png"),
        options: .atomic
      )
      try receipt.write(
        to: output.appendingPathComponent("security-surface-\(name)-receipt.txt"),
        atomically: true,
        encoding: .utf8
      )
    }
  }
  #endif

  @Test("Retirement failures persist a fixed reason instead of server or credential-bearing error text")
  func retirementMarkerDoesNotPersistErrorDescription() async throws {
    let suiteName = "blue.catbird.tests.a6.reason.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let did = "did:plc:retirementreason01"

    let didSucceed = await AppState.retireDeviceBounded(
      accountDid: did,
      deviceId: "aaaaaaaa-1111-4222-8333-444444444444",
      sharedDefaults: defaults
    ) {
      throw NSError(
        domain: "RetirementFailure",
        code: 401,
        userInfo: [NSLocalizedDescriptionKey: "Authorization: Bearer secret-that-must-not-persist"]
      )
    }

    #expect(!didSucceed)
    let marker = try #require(AppState.pendingMLSDeviceRetirements(in: defaults).first)
    #expect(marker.reason == "error")
    let raw = String(
      decoding: try #require(defaults.data(forKey: AppState.pendingDeviceRetirementsDefaultsKey)),
      as: UTF8.self
    )
    #expect(!raw.contains("secret-that-must-not-persist"))
    #expect(!raw.localizedCaseInsensitiveContains("bearer"))

    let legacySecret = "error: Authorization: Bearer legacy-secret"
    let legacy = AppState.PendingMLSDeviceRetirementRecord(
      accountDidHash: try MLSAppGroupStorage.accountDidHash(for: did),
      deviceId: "aaaaaaaa-1111-4222-8333-444444444444",
      recordedAtEpochSeconds: 1_700_000_000,
      reason: legacySecret
    )
    defaults.set(
      try JSONEncoder().encode([legacy]),
      forKey: AppState.pendingDeviceRetirementsDefaultsKey
    )
    #expect(AppState.pendingMLSDeviceRetirements(in: defaults).first?.reason == "error")
    let sanitizedRaw = String(
      decoding: try #require(defaults.data(forKey: AppState.pendingDeviceRetirementsDefaultsKey)),
      as: UTF8.self
    )
    #expect(!sanitizedRaw.contains(legacySecret))
  }

  @Test("Pending retirement retries only the matching old device and consumes its marker after durable report storage")
  @MainActor
  func pendingRetirementReconcilesAfterReplacementEnrollment() async throws {
    let suiteName = "blue.catbird.tests.a6.reconcile.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let aliceDID = "did:plc:retirementreconcilealice"
    let bobDID = "did:plc:retirementreconcilebob"
    let oldDevice = "aaaaaaaa-1111-4222-8333-444444444444"
    let currentDevice = "bbbbbbbb-1111-4222-8333-555555555555"
    let bobDevice = "cccccccc-1111-4222-8333-666666666666"
    let aliceHash = try MLSAppGroupStorage.accountDidHash(for: aliceDID)
    let backend = RevocationReceiptKeychainBackend()

    AppState.recordPendingMLSDeviceRetirement(
      accountDid: aliceDID, deviceId: oldDevice, reason: .timeout, in: defaults)
    AppState.recordPendingMLSDeviceRetirement(
      accountDid: aliceDID, deviceId: currentDevice, reason: .timeout, in: defaults)
    AppState.recordPendingMLSDeviceRetirement(
      accountDid: bobDID, deviceId: bobDevice, reason: .timeout, in: defaults)

    let devices = [
      RegisteredDeviceInfo(
        deviceId: oldDevice,
        deviceName: "Lost iPhone",
        signaturePublicKey: Data([0x01]),
        keyId: "old",
        authGeneration: 1,
        status: "active",
        createdAt: "2026-11-01T00:00:00.000Z",
        lastActiveAt: nil,
        dormantAt: nil,
        labyrinthDeviceKeyHex: nil,
        isCurrentDevice: false,
        unrecognized: false
      ),
      RegisteredDeviceInfo(
        deviceId: currentDevice,
        deviceName: "Replacement iPhone",
        signaturePublicKey: Data([0x02]),
        keyId: "current",
        authGeneration: 2,
        status: "active",
        createdAt: "2026-11-16T00:00:00.000Z",
        lastActiveAt: nil,
        dormantAt: nil,
        labyrinthDeviceKeyHex: nil,
        isCurrentDevice: true,
        unrecognized: false
      ),
    ]

    var attempted: [String] = []
    let firstConsumed = await AppState.reconcilePendingMLSDeviceRetirements(
      accountDid: aliceDID,
      currentDeviceId: currentDevice,
      registeredDevices: devices,
      in: defaults
    ) { target in
      attempted.append(target)
      throw NSError(domain: "Offline", code: -1)
    }
    #expect(firstConsumed == 0)
    #expect(attempted == [oldDevice])
    #expect(AppState.pendingMLSDeviceRetirements(in: defaults).count == 3)

    attempted.removeAll()
    let secondConsumed = await AppState.reconcilePendingMLSDeviceRetirements(
      accountDid: aliceDID,
      currentDeviceId: currentDevice,
      registeredDevices: devices,
      in: defaults
    ) { target in
      attempted.append(target)
      let receipt = AppState.PendingMLSDeviceRevocationReceipt(
        report: DeviceRevocationReport(
          targetDeviceId: target,
          dsRevoked: true,
          groupsUpdated: 2,
          labyrinthRotated: true,
          newEpochSeq: 7,
          pdsRecordDeleted: true,
          rekeyedRecoveryCode: "AUTO-RECONCILED-CODE",
          rekeyedPasskeyIds: []
        ),
        accountDidHash: aliceHash,
        recordedAtEpochSeconds: 1_760_000_100
      )
      try AppState.storePendingMLSDeviceRevocationReceipt(receipt, backend: backend)
    }

    #expect(secondConsumed == 1)
    #expect(attempted == [oldDevice])
    let remaining = AppState.pendingMLSDeviceRetirements(in: defaults)
    #expect(remaining.count == 2)
    #expect(remaining.contains { $0.deviceId == currentDevice })
    #expect(remaining.contains { $0.deviceId == bobDevice })
    #expect(!remaining.contains { $0.deviceId == oldDevice })
    let receipt = try AppState.loadPendingMLSDeviceRevocationReceipt(
      forDID: aliceDID,
      backend: backend
    )
    #expect(receipt?.replacementRecoveryCode == "AUTO-RECONCILED-CODE")
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

#if os(iOS)
@MainActor
private final class SecuritySurfaceHost {
  let window: UIWindow
  let controller: UIHostingController<AnyView>
  private let previousKeyWindow: UIWindow?

  init(scene: UIWindowScene, content: AnyView) {
    previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
    window = UIWindow(windowScene: scene)
    window.frame = scene.screen.bounds
    controller = UIHostingController(rootView: content)
    window.rootViewController = controller
    window.backgroundColor = .systemBackground
    window.makeKeyAndVisible()
  }

  func close() {
    window.endEditing(true)
    window.isHidden = true
    window.rootViewController = nil
    previousKeyWindow?.makeKey()
  }
}

private final class SecuritySurfaceRefusalURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var requests = 0
  nonisolated(unsafe) private static var writes = 0

  static func install() -> Bool {
    lock.withLock {
      requests = 0
      writes = 0
    }
    return URLProtocol.registerClass(Self.self)
  }

  static func uninstall() {
    URLProtocol.unregisterClass(Self.self)
  }

  static var requestCount: Int {
    lock.withLock { requests }
  }

  static var attemptedWrites: Int {
    lock.withLock { writes }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "")
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let method = (request.httpMethod ?? "GET").uppercased()
    Self.lock.withLock {
      Self.requests += 1
      if !["GET", "HEAD"].contains(method) {
        Self.writes += 1
      }
    }
    client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
  }

  override func stopLoading() {}
}
#endif
