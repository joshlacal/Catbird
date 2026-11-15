import CatbirdMLS
import CatbirdMLSCore
import Foundation
import Petrel
import Security
import Testing
@testable import Catbird
#if os(macOS)
import SwiftUI
#endif

private final class InMemoryKeyStore: PlatformKeyStore, @unchecked Sendable {
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
    let generated = Data((0..<32).map { UInt8(($0 &* 17 &+ 3) & 0xff) })
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
}

private final class InMemoryTransport: PlatformTransport, @unchecked Sendable {
  func executeHttp(request _: PlatformHttpRequest) throws -> PlatformHttpResponse {
    PlatformHttpResponse(status: 200, headers: [], body: Data("{}".utf8))
  }

  func connectRealtimeStream(homeDsEndpoint _: String, cursorSeq _: Int64?) throws {}
  func disconnectRealtimeStream() throws {}
}

private struct StubPushWakeKeys: PushWakeKeyLookup {
  let record: PushWakeKeyRecord?

  func pushWakeKey(forKid kid: String) -> PushWakeKeyRecord? {
    record?.kid == kid ? record : nil
  }
}

@Suite("MLS Clean-Slate DataSource, Spaces Gate, & Labyrinth Tests", .serialized)
struct MLSCleanSlateDataSourceAndGateTests {
  private func makeMockTransport(
    network: NativeArchiveMockNetwork,
    accountDid: String,
    deviceId: String
  ) -> PetrelPlatformTransport {
    PetrelPlatformTransport(
      homeDsEndpoint: URL(string: NativeArchiveMockNetwork.dsEndpoint),
      homeDsDid: NativeArchiveMockNetwork.dsDid,
      ownPdsEndpoint: URL(string: NativeArchiveMockNetwork.pdsEndpoint(for: accountDid)),
      actorDeviceId: deviceId,
      httpOverride: { req in network.handle(req) }
    )
  }

  private func makeTempStorageRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("CatbirdAppCleanSlate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func archiveTempStorageRoot(_ dir: URL) {
    let trash = FileManager.default.temporaryDirectory
      .appendingPathComponent("_trash-CatbirdAppCleanSlate", isDirectory: true)
    try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    try? FileManager.default.moveItem(
      at: dir,
      to: trash.appendingPathComponent(dir.lastPathComponent)
    )
  }

  @Test("MLSConversationDataSource loads, sends, reconciles, and closes cleanly on background (I8, I9, I11)")
  @MainActor
  func dataSourceRoundtripAndLifecycle() async throws {
    let network = NativeArchiveMockNetwork.shared
    network.reset()
    let tempRoot = try makeTempStorageRoot()
    defer { archiveTempStorageRoot(tempRoot) }

    let accountDid = "did:plc:alicecleanslateaaaaaaaaa"
    let deviceId = "11111111-2222-4333-8444-555555555555"
    let config = CatbirdMlsClientConfig(
      storageRoot: tempRoot.path,
      accountDid: accountDid,
      deviceId: deviceId,
      homeDsDid: NativeArchiveMockNetwork.dsDid,
      homeDsEndpoint: NativeArchiveMockNetwork.dsEndpoint,
      pdsEndpoint: NativeArchiveMockNetwork.pdsEndpoint(for: accountDid)
    )
    let coordinator = try MLSClientCoordinator(
      config: config,
      keystore: InMemoryKeyStore(),
      transport: makeMockTransport(network: network, accountDid: accountDid, deviceId: deviceId)
    )
    _ = try await coordinator.enrollDevice(grantedScopes: MLSAppGroupStorage.requiredSpacesScopes)

    let conversationId = UUID().uuidString.lowercased()
    let created = try await coordinator.createGroup(
      conversationId: conversationId,
      sequencerDid: NativeArchiveMockNetwork.dsDid,
      title: "Spaces Team",
      description: "Clean-slate group"
    )
    #expect(created.conversationId == conversationId)

    let dataSource = MLSConversationDataSource(
      conversationId: conversationId,
      currentUserDID: accountDid,
      appState: nil,
      mlsCoordinator: coordinator
    )
    await dataSource.loadMessages()
    #expect(dataSource.messages.isEmpty)

    await dataSource.sendMessage(text: "Hello over Spaces PQ MLS!")
    #expect(dataSource.messages.count == 1)
    #expect(dataSource.messages.first?.text == "Hello over Spaces PQ MLS!")

    let beforeWakeups = coordinator.darwinWakeupCount
    MLSPushExtensionProcessor.postNseDidCommitDarwinNotification()
    for _ in 0..<80 where coordinator.darwinWakeupCount < beforeWakeups + 1 {
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(coordinator.darwinWakeupCount >= beforeWakeups + 1)

    let checkpoint = try await coordinator.prepareForBackground()
    #expect(checkpoint.handleClosed)
    #expect(coordinator.isHandleClosed)

    try await coordinator.resumeFromBackground()
    #expect(!coordinator.isHandleClosed)

    let persisted = try await coordinator.listMessages(conversationId: conversationId, limit: 10)
    #expect(persisted.count == 1)
    await coordinator.close()
  }

  @Test("Spaces eligibility gate keeps Bluesky DMs available when PDS lacks Spaces or OAuth scopes are missing (I15)")
  func spacesEligibilityGateInvariants() {
    let unsupportedPDS = MLSClientCoordinator.evaluateEligibility(
      accountDid: "did:plc:bskyuser123",
      pdsEndpoint: "https://bsky.social",
      pdsSupportsSpaces: false,
      grantedScopes: MLSAppGroupStorage.requiredSpacesScopes
    )
    #expect(!unsupportedPDS.eligible)
    #expect(unsupportedPDS.blueskyDmsAvailable)
    if case .pdsDoesNotSupportSpaces = unsupportedPDS.reason {
      // Expected
    } else {
      Issue.record("Expected .pdsDoesNotSupportSpaces, got \(unsupportedPDS.reason)")
    }

    let missingScopes = MLSClientCoordinator.evaluateEligibility(
      accountDid: "did:plc:catbirduser123",
      pdsEndpoint: "https://pds.catbird.blue",
      pdsSupportsSpaces: true,
      grantedScopes: ["atproto"]
    )
    #expect(!missingScopes.eligible)
    #expect(missingScopes.blueskyDmsAvailable)
    if case .missingOAuthScopes(let scopes) = missingScopes.reason {
      #expect(!scopes.isEmpty)
    } else {
      Issue.record("Expected .missingOAuthScopes, got \(missingScopes.reason)")
    }

    let eligible = MLSClientCoordinator.evaluateEligibility(
      accountDid: "did:plc:catbirduser123",
      pdsEndpoint: "https://pds.catbird.blue",
      pdsSupportsSpaces: true,
      grantedScopes: MLSAppGroupStorage.requiredSpacesScopes
    )
    #expect(eligible.eligible)
    #expect(eligible.blueskyDmsAvailable)
  }

  @Test("Labyrinth backup is enabled by default with optional recovery code and PQ OTC pairing (D4, I16)")
  @MainActor
  func labyrinthRecoveryAndPqOtcPairing() async throws {
    let network = NativeArchiveMockNetwork.shared
    network.reset()
    let tempRoot = try makeTempStorageRoot()
    defer { archiveTempStorageRoot(tempRoot) }

    let accountDid = "did:plc:labyrinthaliceaaaaaaaaaa"
    let device1Id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let companionId = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
    let restoreId = "cccccccc-dddd-4eee-8fff-111111111111"

    let dev1Root = tempRoot.appendingPathComponent("dev1", isDirectory: true)
    let companionRoot = tempRoot.appendingPathComponent("companion", isDirectory: true)
    let restoreRoot = tempRoot.appendingPathComponent("restore", isDirectory: true)
    try FileManager.default.createDirectory(at: dev1Root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: companionRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: restoreRoot, withIntermediateDirectories: true)

    let coordinator = try MLSClientCoordinator(
      config: CatbirdMlsClientConfig(
        storageRoot: dev1Root.path,
        accountDid: accountDid,
        deviceId: device1Id,
        homeDsDid: NativeArchiveMockNetwork.dsDid,
        homeDsEndpoint: NativeArchiveMockNetwork.dsEndpoint,
        pdsEndpoint: NativeArchiveMockNetwork.pdsEndpoint(for: accountDid)
      ),
      keystore: InMemoryKeyStore(),
      transport: makeMockTransport(network: network, accountDid: accountDid, deviceId: device1Id)
    )
    _ = try await coordinator.enrollDevice(grantedScopes: MLSAppGroupStorage.requiredSpacesScopes)

    let initialStatus = try await coordinator.labyrinthStatus()
    #expect(initialStatus.backupEnabled)
    #expect(!initialStatus.hasRecoveryCode)

    let companion = try MLSClientCoordinator(
      config: CatbirdMlsClientConfig(
        storageRoot: companionRoot.path,
        accountDid: accountDid,
        deviceId: companionId,
        homeDsDid: NativeArchiveMockNetwork.dsDid,
        homeDsEndpoint: NativeArchiveMockNetwork.dsEndpoint,
        pdsEndpoint: NativeArchiveMockNetwork.pdsEndpoint(for: accountDid)
      ),
      keystore: InMemoryKeyStore(),
      transport: makeMockTransport(network: network, accountDid: accountDid, deviceId: companionId)
    )
    _ = try await companion.enrollDevice(grantedScopes: MLSAppGroupStorage.requiredSpacesScopes)

    let offer = try await coordinator.initiateOtcPairing()
    #expect(offer.sixDigitCode.count == 6)

    let otcInitiated = try await companion.startOtcPairing(sixDigitCode: offer.sixDigitCode)
    try await coordinator.respondOtcPairing(sessionIdHex: otcInitiated.sessionIdHex, sixDigitCode: nil)
    let completion = try await companion.completeOtcPairing(sixDigitCode: offer.sixDigitCode)
    #expect(completion.initiatorMlkem768EkLen == 1184)
    #expect(completion.responderMlkem768CtLen == 1088)
    #expect(completion.newEpochSeq >= 1)
    await companion.close()

    let code = try await coordinator.setupRecoveryCode()
    let bareChars = code.filter { !$0.isWhitespace && $0 != "-" }
    #expect(bareChars.count == 40)

    let restoreDevice = try MLSClientCoordinator(
      config: CatbirdMlsClientConfig(
        storageRoot: restoreRoot.path,
        accountDid: accountDid,
        deviceId: restoreId,
        homeDsDid: NativeArchiveMockNetwork.dsDid,
        homeDsEndpoint: NativeArchiveMockNetwork.dsEndpoint,
        pdsEndpoint: NativeArchiveMockNetwork.pdsEndpoint(for: accountDid)
      ),
      keystore: InMemoryKeyStore(),
      transport: makeMockTransport(network: network, accountDid: accountDid, deviceId: restoreId)
    )
    _ = try await restoreDevice.enrollDevice(grantedScopes: MLSAppGroupStorage.requiredSpacesScopes)
    let restored = try await restoreDevice.restoreWithRecoveryCode(code)
    #expect(restored.backupEnabled)
    #expect(restored.epochSeq >= 2)

    await restoreDevice.close()
    await coordinator.close()
  }

  @Test("Space-scoped blob locator parses canonical pipe and hash locators and rejects malformed strings (I14)")
  func spaceBlobLocatorParsing() throws {
    let spaceURI = "at://did:web:chat.catbird.blue/space/blue.catbird.labyrinth.conversation/convo-0"
    let repoDID = "did:plc:alice1234567890abcdefghij"
    let cid = "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"

    let pipeLocator = MLSSpaceBlobLocator.makeLocator(spaceURI: spaceURI, repoDID: repoDID, cid: cid)
    let parsedPipe = try MLSSpaceBlobLocator.parse(pipeLocator)
    #expect(parsedPipe.space.uriString() == spaceURI)
    #expect(parsedPipe.repo.didString() == repoDID)
    #expect(parsedPipe.cid.string == cid)

    let hashLocator = "\(spaceURI)/\(repoDID)#\(cid)"
    let parsedHash = try MLSSpaceBlobLocator.parse(hashLocator)
    #expect(parsedHash.space.uriString() == spaceURI)
    #expect(parsedHash.repo.didString() == repoDID)
    #expect(parsedHash.cid.string == cid)

    #expect(throws: MLSSpaceBlobLocatorError.self) {
      _ = try MLSSpaceBlobLocator.parse("not-a-space-locator")
    }
  }

  @Test("MLS runtime gate keeps coordinator, DB, and Spaces checks dormant when MLS is disabled (ctl #2)")
  @MainActor
  func disabledMLSAccountStaysCompletelyDormant() async throws {
    let did = "did:plc:disabledmls\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased())"
    ExperimentalSettings.shared.disableMLSChat(for: did)

    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: did, client: client)
    defer { appState.cleanup() }

    #expect(!ExperimentalSettings.shared.isMLSChatEnabled(for: did))
    #expect(!appState.isMLSRuntimeAllowed)

    let coordinator = await appState.getOrOpenMLSCoordinator()
    #expect(coordinator == nil)
    #expect(appState.mlsCoordinator == nil)
    #expect(appState.spacesEligibility == nil)

    try await appState.initializeMLS()
    await appState.loadMLSConversations()

    #expect(appState.mlsCoordinator == nil)
    #expect(appState.spacesEligibility == nil)
    #expect(appState.mlsConversations.isEmpty)

    if let storageRoot = try? MLSAppGroupStorage.defaultStorageRoot(),
       let dbURL = try? MLSAppGroupStorage.databaseURL(storageRoot: storageRoot, accountDid: did) {
      #expect(!FileManager.default.fileExists(atPath: dbURL.path))
    }
  }

  @Test("Signed push gateway registration uses enrolled 43-char keyId thumbprint and NSE decodes nest APNs catbird wake (D2, I10)")
  @MainActor
  func pushGatewaySigningAndApnsWakeDecoding() async throws {
    let tempRoot = try makeTempStorageRoot()
    defer { archiveTempStorageRoot(tempRoot) }

    let deviceId = "11111111-2222-4333-8444-555555555555"
    let coordinator = try MLSClientCoordinator(
      config: CatbirdMlsClientConfig(
        storageRoot: tempRoot.path,
        accountDid: "did:plc:pushgwuser001",
        deviceId: deviceId,
        homeDsDid: MLSEnvironment.production.bareServiceDID,
        homeDsEndpoint: "https://chat.catbird.blue",
        pdsEndpoint: "https://pds.catbird.blue"
      ),
      keystore: InMemoryKeyStore(),
      transport: InMemoryTransport()
    )
    #expect(MLSEnvironment.production.bareServiceDID == "did:web:chat.catbird.blue")

    _ = try await coordinator.enrollDevice(grantedScopes: MLSAppGroupStorage.requiredSpacesScopes)
    let signed = try await coordinator.buildSignedPushGatewayRegistration(
      gatewayUrl: "https://api.catbird.blue/xrpc/blue.catbird.push.deliver",
      appId: "blue.catbird",
      pushKey: "push-key-opaque-123",
      enabled: true
    )
    #expect(signed.deviceId == deviceId)
    #expect(signed.keyId.count == 43)
    #expect(!signed.keyId.hasPrefix("sig-"))
    #expect(signed.signatureBytes.count == 64)

    let apnsUserInfo: [AnyHashable: Any] = [
      "aps": ["mutable-content": 1],
      "catbird": [
        "recipientAccountHash": coordinator.accountDidHash,
        "wakeKind": "application",
        "conversationId": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        "generation": 1,
        "seq": 9,
        "epoch": 2,
        "fetchRequired": true,
      ] as [String: Any],
    ]
    let wake = MLSPushExtensionProcessor.decodePushWakePayload(from: apnsUserInfo)
    #expect(wake?.kind == "application")
    #expect(wake?.entrySeq == 9)
    #expect(wake?.recipientAccountHash == coordinator.accountDidHash)

    // The same wake sealed as version 2: only `v`, `kid` and `sealed` are visible, and the
    // account hash is recovered from the stored pushKey's `kid -> account DID` index.
    let pushKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    let wakeKeys = StubPushWakeKeys(
      record: PushWakeKeyRecord(pushKey: pushKey, appId: "blue.catbird", accountDid: "did:plc:pushgwuser001")
    )
    let sealed = try PushWakeEnvelope.seal(
      header: Data(
        #"{"wakeKind":"application","conversationId":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","generation":1,"seq":9,"epoch":2,"fetchRequired":true}"#
          .utf8
      ),
      ciphertext: nil,
      keys: PushWakeEnvelope.Keys(pushKey: pushKey),
      appId: "blue.catbird"
    )
    #expect(Set(sealed.keys) == ["v", "kid", "sealed"])
    let sealedUserInfo: [AnyHashable: Any] = ["aps": ["mutable-content": 1], "catbird": sealed]
    let sealedWake = MLSPushExtensionProcessor.decodePushWakePayload(from: sealedUserInfo, wakeKeys: wakeKeys)
    #expect(sealedWake?.kind == wake?.kind)
    #expect(sealedWake?.conversationId == wake?.conversationId)
    #expect(sealedWake?.generation == wake?.generation)
    #expect(sealedWake?.entrySeq == 9)
    #expect(sealedWake?.fetchRequired == true)
    #expect(sealedWake?.inlineCiphertext == nil)
    #expect(sealedWake?.recipientAccountHash == coordinator.accountDidHash)
    #expect(
      MLSPushExtensionProcessor.decodePushWakePayload(
        from: sealedUserInfo,
        wakeKeys: StubPushWakeKeys(record: nil)
      ) == nil
    )

    await coordinator.close()
  }

  @Test("SyncIncomplete marks only the conversations it names, without its failure text; a completed sync clears them (R4)")
  @MainActor
  func syncIncompleteMarksOnlyTheNamedConversations() async throws {
    let tempRoot = try makeTempStorageRoot()
    defer { archiveTempStorageRoot(tempRoot) }
    let accountDid = "did:plc:syncincompletemarksaaaaa"
    let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:1")!)
    let appState = AppState(userDID: accountDid, client: client)
    defer { appState.cleanup() }

    let failed = UUID().uuidString.lowercased()
    let healthy = UUID().uuidString.lowercased()
    appState.recordMLSSyncFailure(MlsError.SyncIncomplete(
      message: "sync incomplete (1 applied): conversation \(failed): Cryptography(\"receipt does not verify\")"
    ))
    #expect(appState.mlsSyncIncompleteConversationIDs == [failed])
    // A whole-sync failure verified nothing: the marks stay.
    appState.recordMLSSyncFailure(MlsError.Internal(message: "conversation \(healthy): offline"))
    #expect(appState.mlsSyncIncompleteConversationIDs == [failed])

    // The conversation data source syncs through the same state; an unenrolled device's sync
    // completes with nothing to apply, which clears the marks.
    let coordinator = try MLSClientCoordinator(
      config: CatbirdMlsClientConfig(
        storageRoot: tempRoot.path,
        accountDid: accountDid,
        deviceId: UUID().uuidString.lowercased(),
        homeDsDid: "did:web:chat.catbird.blue",
        homeDsEndpoint: "https://chat.catbird.blue",
        pdsEndpoint: "https://pds.catbird.blue"
      ),
      keystore: InMemoryKeyStore(),
      transport: InMemoryTransport()
    )
    let dataSource = MLSConversationDataSource(
      conversationId: healthy,
      currentUserDID: accountDid,
      appState: appState,
      mlsCoordinator: coordinator
    )
    await dataSource.loadMessages()
    #expect(appState.mlsSyncIncompleteConversationIDs.isEmpty)
    dataSource.stopObserving()
    await coordinator.close()
  }

  @Test("T7-SEND-RETRY-1: retryFailedSend preserves identical clientMessageID across failure and recovery")
  @MainActor
  func retryFailedSendPreservesIdempotentClientMessageID() async throws {
    let network = NativeArchiveMockNetwork.shared
    network.reset()
    let tempRoot = try makeTempStorageRoot()
    defer { archiveTempStorageRoot(tempRoot) }

    let accountDid = "did:plc:tsevsendretryuseraaaaaaa"
    let deviceId = "22222222-3333-4444-8555-666666666666"
    let coordinator = try await MLSClientCoordinator.open(
      config: CatbirdMlsClientConfig(
        storageRoot: tempRoot.path,
        accountDid: accountDid,
        deviceId: deviceId,
        homeDsDid: NativeArchiveMockNetwork.dsDid,
        homeDsEndpoint: NativeArchiveMockNetwork.dsEndpoint,
        pdsEndpoint: NativeArchiveMockNetwork.pdsEndpoint(for: accountDid)
      ),
      keystore: InMemoryKeyStore(),
      transport: makeMockTransport(network: network, accountDid: accountDid, deviceId: deviceId)
    )
    _ = try await coordinator.enrollDevice(grantedScopes: MLSAppGroupStorage.requiredSpacesScopes)

    let conversationId = UUID().uuidString.lowercased()
    _ = try await coordinator.createGroup(
      conversationId: conversationId,
      sequencerDid: NativeArchiveMockNetwork.dsDid,
      title: "Retry Idempotency",
      description: nil
    )

    let dataSource = MLSConversationDataSource(
      conversationId: conversationId,
      currentUserDID: accountDid,
      appState: nil,
      mlsCoordinator: coordinator
    )
    await dataSource.loadMessages()

    // Simulate transient background/handle suspension causing send attempt #1 to fail.
    _ = try await coordinator.prepareForBackground()
    await dataSource.sendMessage(text: "Idempotent retry message")
    #expect(dataSource.pendingSends.count == 1)
    let firstPending = try #require(dataSource.pendingSends.first)
    let originalClientMessageID = firstPending.clientMessageID
    #expect(!originalClientMessageID.isEmpty)
    if case .failed = firstPending.state {
      // Expected failed state on attempt #1
    } else {
      Issue.record("Expected failed state on attempt #1, got \(firstPending.state)")
    }

    // Retry #1 while still suspended: must keep the exact same clientMessageID.
    await dataSource.retryFailedSend(pendingID: firstPending.id)
    #expect(dataSource.pendingSends.count == 1)
    let secondPending = try #require(dataSource.pendingSends.first)
    #expect(secondPending.clientMessageID == originalClientMessageID)

    // Resume coordinator and retry #2: committed SQLite row must carry originalClientMessageID.
    try await coordinator.resumeFromBackground()
    await dataSource.retryFailedSend(pendingID: secondPending.id)

    let persisted = try await coordinator.listMessages(conversationId: conversationId, limit: 10)
    #expect(persisted.count == 1)
    #expect(persisted.first?.messageId == originalClientMessageID)
    #expect(dataSource.messages.first?.id == originalClientMessageID)

    dataSource.stopObserving()
    await coordinator.close()
  }

  #if os(macOS)
  @Test("macOS sidebar row draws the sync-incomplete indicator only for a marked conversation (R4)")
  @MainActor
  func macOSSidebarRowShowsSyncIncompleteIndicator() async throws {
    let accountDid = "did:plc:macsyncincompleteaaaaaa"
    let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:1")!)
    let appState = AppState(userDID: accountDid, client: client)
    defer { appState.cleanup() }
    let failed = UUID().uuidString.lowercased()
    let healthy = UUID().uuidString.lowercased()
    appState.recordMLSSyncFailure(MlsError.SyncIncomplete(
      message: "sync incomplete (1 applied): conversation \(failed): Cryptography(\"receipt does not verify\")"
    ))

    // In-process AppKit accessibility exposes no SwiftUI children without an assistive client, so
    // this renders the row: the indicator is its only orange element (no member change shown).
    func orangePixels(_ conversationID: String) throws -> Int {
      let row = MacOSUnifiedConversationRow(
        item: .mls(
          conversation: MLSConversationModel(
            conversationID: conversationID, currentUserDID: accountDid, groupID: Data([1])),
          participants: [], unreadCount: 0, lastMessage: nil, memberChange: nil,
          lastActivityDate: Date()),
        currentUserDID: accountDid
      )
      let renderer = ImageRenderer(content: row.environment(appState).frame(width: 320))
      renderer.scale = 2
      let image = try #require(renderer.cgImage)
      let width = image.width, height = image.height
      var pixels = [UInt8](repeating: 0, count: width * height * 4)
      let context = try #require(CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return stride(from: 0, to: pixels.count, by: 4).filter { i in
        pixels[i + 3] > 200 && pixels[i] > 200 && (100..<190).contains(pixels[i + 1]) && pixels[i + 2] < 80
      }.count
    }

    #expect(try orangePixels(failed) > 20)
    #expect(try orangePixels(healthy) == 0)
  }
  #endif
}
