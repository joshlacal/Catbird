import CatbirdMLS
import CatbirdMLSCore
import Foundation
import Petrel
import Security
import Testing
@testable import Catbird

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

@Suite("MLS Clean-Slate DataSource, Spaces Gate, & Labyrinth Tests")
struct MLSCleanSlateDataSourceAndGateTests {
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
    let tempRoot = try makeTempStorageRoot()
    defer { archiveTempStorageRoot(tempRoot) }

    let accountDid = "did:plc:alicecleanslate001"
    let config = CatbirdMlsClientConfig(
      storageRoot: tempRoot.path,
      accountDid: accountDid,
      deviceId: "11111111-2222-4333-8444-555555555555",
      homeDsDid: "did:web:chat.catbird.blue",
      homeDsEndpoint: "https://chat.catbird.blue",
      pdsEndpoint: "https://pds.catbird.blue"
    )
    let coordinator = try MLSClientCoordinator(
      config: config,
      keystore: InMemoryKeyStore(),
      transport: InMemoryTransport()
    )

    let conversationId = UUID().uuidString.lowercased()
    let created = try await coordinator.createGroup(
      conversationId: conversationId,
      sequencerDid: "did:web:chat.catbird.blue",
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
    try await Task.sleep(for: .milliseconds(100))
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
    let tempRoot = try makeTempStorageRoot()
    defer { archiveTempStorageRoot(tempRoot) }

    let coordinator = try MLSClientCoordinator(
      config: CatbirdMlsClientConfig(
        storageRoot: tempRoot.path,
        accountDid: "did:plc:labyrinthalice99",
        deviceId: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        homeDsDid: "did:web:chat.catbird.blue",
        homeDsEndpoint: "https://chat.catbird.blue",
        pdsEndpoint: "https://pds.catbird.blue"
      ),
      keystore: InMemoryKeyStore(),
      transport: InMemoryTransport()
    )

    let initialStatus = try await coordinator.labyrinthStatus()
    #expect(initialStatus.backupEnabled)
    #expect(!initialStatus.hasRecoveryCode)

    let code = try await coordinator.setupRecoveryCode()
    let bareChars = code.filter { !$0.isWhitespace && $0 != "-" }
    #expect(bareChars.count == 40)

    let restored = try await coordinator.restoreWithRecoveryCode(code)
    #expect(restored.hasRecoveryCode)

    let offer = try await coordinator.initiateOtcPairing()
    #expect(offer.sixDigitCode.count == 6)

    let completion = try await coordinator.completeOtcPairing(sixDigitCode: offer.sixDigitCode)
    #expect(completion.initiatorMlkem768EkLen == 1184)
    #expect(completion.responderMlkem768CtLen == 1088)
    #expect(completion.newEpochSeq >= 1)

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

    await coordinator.close()
  }
}
