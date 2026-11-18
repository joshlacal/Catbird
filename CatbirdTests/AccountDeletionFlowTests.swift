import Foundation
import CatbirdMLS
import CatbirdMLSCore
import os
import SwiftData
import Testing
@testable import Catbird


@Suite("Account deletion Catbird data erasure", .serialized)
struct AccountDeletionCoordinatorTests {
  @Test("Erase Catbird data removes SwiftData records for the specified account while preserving others")
  @MainActor
  func swiftDataErasure() async throws {
    let schema = Schema([AppSettingsModel.self, Preferences.self, DraftPost.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [config])
    let context = ModelContext(container)

    let testRunID = UUID().uuidString.lowercased()
    let targetDID = "did:plc:target-delete-\(testRunID)"
    let preservedDID = "did:plc:keep-intact-\(testRunID)"

    // Seed models
    let targetSettings = AppSettingsModel(accountDID: targetDID)
    let preservedSettings = AppSettingsModel(accountDID: preservedDID)
    context.insert(targetSettings)
    context.insert(preservedSettings)

    let targetPref = Preferences()
    targetPref.accountDID = targetDID
    let preservedPref = Preferences()
    preservedPref.accountDID = preservedDID
    context.insert(targetPref)
    context.insert(preservedPref)

    let targetDraft = DraftPost(
      id: UUID(),
      accountDID: targetDID,
      draftData: Data("{}".utf8),
      previewText: "Target Draft",
      hasMedia: false,
      isReply: false,
      isQuote: false,
      isThread: false
    )
    let preservedDraft = DraftPost(
      id: UUID(),
      accountDID: preservedDID,
      draftData: Data("{}".utf8),
      previewText: "Keep Draft",
      hasMedia: false,
      isReply: false,
      isQuote: false,
      isThread: false
    )
    context.insert(targetDraft)
    context.insert(preservedDraft)
    try context.save()

    // Execute the scoped erasure without touching the process-wide account store.
    try await AccountDeletionCoordinator.eraseCatbirdData(
      forDID: targetDID,
      modelContext: context,
      skipRemoteMLSErasure: true,
      accountRemovalOverride: { _ in }
    )

    // Verify target rows deleted
    let targetSettingsDesc = FetchDescriptor<AppSettingsModel>(predicate: #Predicate { $0.id == "app_settings_\(targetDID)" })
    #expect(try context.fetch(targetSettingsDesc).isEmpty)

    let targetPrefDesc = FetchDescriptor<Preferences>(predicate: #Predicate { $0.accountDID == targetDID })
    #expect(try context.fetch(targetPrefDesc).isEmpty)

    let targetDraftDesc = FetchDescriptor<DraftPost>(predicate: #Predicate { $0.accountDID == targetDID })
    #expect(try context.fetch(targetDraftDesc).isEmpty)

    // Verify preserved rows untouched
    let preservedSettingsDesc = FetchDescriptor<AppSettingsModel>(predicate: #Predicate { $0.id == "app_settings_\(preservedDID)" })
    #expect(try context.fetch(preservedSettingsDesc).count == 1)

    let preservedPrefDesc = FetchDescriptor<Preferences>(predicate: #Predicate { $0.accountDID == preservedDID })
    #expect(try context.fetch(preservedPrefDesc).count == 1)

    let preservedDraftDesc = FetchDescriptor<DraftPost>(predicate: #Predicate { $0.accountDID == preservedDID })
    #expect(try context.fetch(preservedDraftDesc).count == 1)
  }

  private final class DirectPDSMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private static func readBody(_ request: URLRequest) -> Data {
      if let body = request.httpBody { return body }
      guard let stream = request.httpBodyStream else { return Data() }
      stream.open()
      defer { stream.close() }
      var out = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        out.append(buffer, count: count)
      }
      return out
    }

    override func startLoading() {
      guard let handler = Self.handler else {
        client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        return
      }
      do {
        let body = Self.readBody(request)
        let (status, responseData) = try handler(request, body)
        let response = HTTPURLResponse(
          url: request.url ?? URL(string: "https://pds.example")!,
          statusCode: status,
          httpVersion: "HTTP/1.1",
          headerFields: [
            "Content-Type": "application/json",
            "Set-Cookie": "pds_session=should_not_persist",
          ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
      } catch {
        client?.urlProtocol(self, didFailWithError: error)
      }
    }

    override func stopLoading() {}
  }

  @Test("A3 + A4: direct PDS deletion requires explicit pre-delete backup-erasure consent and remains retryable")
  @MainActor
  func directPDSDeletionPreValidatesPasswordBeforeBackupWipe() async throws {
    let targetDID = "did:plc:a3a4hosteddelete01"
    let pdsURL = URL(string: "https://morel.us-east.host.bsky.network")!

    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.urlCache = nil
    config.urlCredentialStorage = nil
    config.protocolClasses = [DirectPDSMockURLProtocol.self]
    let mockSession = URLSession(configuration: config)
    defer { mockSession.finishTasksAndInvalidate() }
    let directClient = PDSDirectDeletionClient(session: mockSession)

    var events: [String] = []
    DirectPDSMockURLProtocol.handler = { request, body in
      let path = request.url?.path ?? ""
      switch path {
      case "/xrpc/com.atproto.server.createSession":
        events.append("createSession")
        let json = (try? JSONSerialization.jsonObject(with: body) as? [String: String]) ?? [:]
        guard json["identifier"] == targetDID, json["password"] == "correct-horse-battery" else {
          return (
            401,
            Data(#"{"error":"AuthenticationRequired","message":"Invalid identifier or password"}"#.utf8)
          )
        }
        return (
          200,
          Data(#"{"did":"\#(targetDID)","handle":"alice.bsky.social","accessJwt":"ephemeral-pds-jwt-123","refreshJwt":"discarded-refresh-jwt"}"#.utf8)
        )
      case "/xrpc/com.atproto.server.requestAccountDelete":
        events.append("requestAccountDelete")
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer ephemeral-pds-jwt-123" else {
          return (
            403,
            Data(#"{"error":"Forbidden","message":"OAuth credentials are not supported for this endpoint"}"#.utf8)
          )
        }
        return (200, Data())
      case "/xrpc/com.atproto.server.deleteAccount":
        events.append("deleteAccount")
        let json = (try? JSONSerialization.jsonObject(with: body) as? [String: String]) ?? [:]
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer ephemeral-pds-jwt-123",
              json["did"] == targetDID,
              json["password"] == "correct-horse-battery",
              json["token"] == "EMAIL-CODE-999"
        else {
          return (400, Data(#"{"error":"InvalidToken","message":"Bad confirmation code"}"#.utf8))
        }
        return (200, Data())
      default:
        return (404, Data())
      }
    }

    // 1. A3: requestHostedAccountDeletionCode obtains ephemeral Bearer JWT via createSession (bypassing OAuth 403)
    try await AccountDeletionCoordinator.requestHostedAccountDeletionCode(
      forDID: targetDID,
      password: "correct-horse-battery",
      pdsURL: pdsURL,
      directClient: directClient
    )
    #expect(events == ["createSession", "requestAccountDelete"])
    #expect(mockSession.configuration.httpCookieStorage == nil)
    #expect(mockSession.configuration.urlCache == nil)

    // 2. A4 Regression: Mistyped password MUST fail at createSession BEFORE remoteMLSErasure runs!
    events.removeAll()
    var remoteEraseCount = 0
    var localEraseCount = 0
    await #expect(throws: PDSDirectDeletionError.self) {
      try await AccountDeletionCoordinator.performHostedAccountDeletion(
        forDID: targetDID,
        password: "wrong-password-typo",
        confirmationToken: "EMAIL-CODE-999",
        remoteErasureConsent: .explicitlyConfirmed,
        pdsURL: pdsURL,
        remoteMLSErasure: { _ in
          remoteEraseCount += 1
          events.append("remoteMLSErasure")
        },
        localErasureOverride: { _ in
          localEraseCount += 1
          events.append("localErasure")
        },
        directClient: directClient
      )
    }
    #expect(remoteEraseCount == 0, "A4: Encrypted Labyrinth/MLS server backups MUST NOT be wiped when password validation fails")
    #expect(localEraseCount == 0)
    #expect(events == ["createSession"])

    events.removeAll()
    await #expect(throws: AccountErasureRecoveryRequired.self) {
      try await AccountDeletionCoordinator.performHostedAccountDeletion(
        forDID: targetDID,
        password: "correct-horse-battery",
        confirmationToken: "EMAIL-CODE-999",
        remoteErasureConsent: .explicitlyConfirmed,
        pdsURL: pdsURL,
        localErasureOverride: { _ in events.append("localErasure") },
        directClient: directClient
      )
    }
    #expect(events == ["createSession"], "The provider account and local receipts must remain usable for recovery")

    // 3. AT Protocol has no token-prevalidation endpoint. After the dedicated UI consent,
    //    a bad email code can leave the account intact after encrypted-history erasure. Remaining
    //    local account cleanup must not run, and deletion must remain retryable with a replacement code.
    events.removeAll()
    await #expect(throws: PDSDirectDeletionError.self) {
      try await AccountDeletionCoordinator.performHostedAccountDeletion(
        forDID: targetDID,
        password: "correct-horse-battery",
        confirmationToken: "WRONG-EMAIL-CODE",
        remoteErasureConsent: .explicitlyConfirmed,
        pdsURL: pdsURL,
        remoteMLSErasure: { _ in
          remoteEraseCount += 1
          events.append("remoteMLSErasure")
        },
        localErasureOverride: { _ in
          localEraseCount += 1
          events.append("localErasure")
        },
        directClient: directClient
      )
    }
    #expect(remoteEraseCount == 1)
    #expect(localEraseCount == 0)
    #expect(events == ["createSession", "remoteMLSErasure", "deleteAccount"])

    // 4. A replacement code retries the complete sequence and cleans up locally only after
    //    the provider confirms permanent deletion.
    events.removeAll()
    try await AccountDeletionCoordinator.performHostedAccountDeletion(
      forDID: targetDID,
      password: "correct-horse-battery",
      confirmationToken: "EMAIL-CODE-999",
      remoteErasureConsent: .explicitlyConfirmed,
      pdsURL: pdsURL,
      remoteMLSErasure: { _ in
        remoteEraseCount += 1
        events.append("remoteMLSErasure")
      },
      localErasureOverride: { _ in
        localEraseCount += 1
        events.append("localErasure")
      },
      directClient: directClient
    )
    #expect(remoteEraseCount == 2)
    #expect(localEraseCount == 1)
    #expect(events == ["createSession", "remoteMLSErasure", "deleteAccount", "localErasure"])
  }

  @Test("Hosted deletion waits for peer confirmation and retains its device across a rejected provider code")
  @MainActor
  func hostedDeletionWaitsForPeerProof() async throws {
    let did = "did:plc:hostedpeerprooftest"
    let device = UUID().uuidString.lowercased()
    let root = FileManager.default.temporaryDirectory.appending(path: "hosted-peer-proof-\(device)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let network = NativeArchiveMockNetwork()
    let keys = Wave0RecordingKeyStore()
    let reply = OSAllocatedUnfairLock(initialState: (status: 202, body: "{}"))
    let transport = PetrelPlatformTransport(
      homeDsEndpoint: URL(string: NativeArchiveMockNetwork.dsEndpoint),
      homeDsDid: NativeArchiveMockNetwork.dsDid,
      ownPdsEndpoint: URL(string: NativeArchiveMockNetwork.pdsEndpoint(for: did)),
      actorDeviceId: device,
      httpOverride: { request in
        guard request.url.hasSuffix("/blue.catbird.labyrinth.deleteAccountData") else { return network.handle(request) }
        guard request.headers.contains(where: { $0.name.lowercased() == "catbird-require-erasure-completion" && $0.value == "1" })
        else { throw URLError(.badServerResponse) }
        let response = reply.withLock { $0 }
        return PlatformHttpResponse(status: UInt16(response.status), headers: [], body: Data(response.body.utf8))
      }
    )
    let coordinator = try await MLSClientCoordinator.open(
      config: CatbirdMlsClientConfig(storageRoot: root.path, accountDid: did, deviceId: device,
        homeDsDid: NativeArchiveMockNetwork.dsDid, homeDsEndpoint: NativeArchiveMockNetwork.dsEndpoint,
        pdsEndpoint: NativeArchiveMockNetwork.pdsEndpoint(for: did)),
      keystore: keys, transport: transport
    )
    _ = try await coordinator.enrollDevice(grantedScopes: MLSAppGroupStorage.requiredSpacesScopes)
    let accountDB = try MLSAppGroupStorage.databaseURL(storageRoot: root, accountDid: did)
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DirectPDSMockURLProtocol.self]
    let session = URLSession(configuration: config)
    defer {
      session.invalidateAndCancel()
      DirectPDSMockURLProtocol.handler = nil
    }
    DirectPDSMockURLProtocol.handler = { request, data in
      switch request.url?.lastPathComponent {
      case "com.atproto.server.createSession":
        return (200, Data(#"{"accessJwt":"synthetic-ephemeral"}"#.utf8))
      case "com.atproto.server.deleteAccount":
        calls.withLock { $0 += 1 }
        let body = try JSONSerialization.jsonObject(with: data) as? [String: String]
        return body?["token"] == "valid" ? (200, Data()) : (400, Data(#"{"error":"InvalidToken"}"#.utf8))
      default:
        throw URLError(.unsupportedURL)
      }
    }
    let provider = PDSDirectDeletionClient(session: session)
    var localErasureCount = 0
    func deleteHostedAccount(token: String) async throws {
      try await AccountDeletionCoordinator.performHostedAccountDeletion(
        forDID: did, password: "fixture-password", confirmationToken: token,
        remoteErasureConsent: .explicitlyConfirmed, pdsURL: URL(string: "https://hosted.example.org")!,
        storageRoot: root, keystore: keys, coordinatorOverride: coordinator,
        localErasureOverride: { _ in localErasureCount += 1 }, directClient: provider
      )
    }
    for (status, body) in [
      (202, #"{"erasureCompletion":"confirmed"}"#), (200, "{}"), (200, #"{"erasureCompletion":"unknown"}"#),
      (409, #"{"error":"PeerErasurePending"}"#), (409, #"{"error":"PeerErasureUnverified"}"#)
    ] {
      reply.withLock { $0 = (status, body) }
      await #expect(throws: HostedPeerErasureError.self) { try await deleteHostedAccount(token: "valid") }
      #expect(calls.withLock { $0 } == 0)
      #expect(localErasureCount == 0)
      #expect(!coordinator.isHandleClosed)
      #expect(FileManager.default.fileExists(atPath: accountDB.path))
      #expect(keys.hasDbKey(accountDidHash: coordinator.accountDidHash))
    }
    reply.withLock { $0 = (200, #"{"erasureCompletion":"confirmed"}"#) }
    await #expect(throws: PDSDirectDeletionError.self) { try await deleteHostedAccount(token: "expired") }
    #expect(calls.withLock { $0 } == 1)
    #expect(localErasureCount == 0)
    #expect(!coordinator.isHandleClosed)
    try await deleteHostedAccount(token: "valid")
    #expect(calls.withLock { $0 } == 2)
    #expect(localErasureCount == 1)
    #expect(coordinator.isHandleClosed)
  }

  @Test("Fresh-device erasure preserves the hosted account when remote authority is unavailable; explicit local-only erasure works offline")
  @MainActor
  func freshDeviceCannotSkipRemoteErasureAndLocalOnlyEscapeHatchWorksOffline() async throws {
    let nonMLSDID = "did:plc:nonmls-\(UUID().uuidString.lowercased())"
    let fm = FileManager.default
    let emptyRoot = fm.temporaryDirectory.appendingPathComponent("catbird-nonmls-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: emptyRoot) }

    await #expect(throws: AccountErasureRecoveryRequired.self) {
      try await AccountDeletionCoordinator.eraseServerSideLabyrinthDataIfAuthenticated(
        forDID: nonMLSDID,
        storageRoot: emptyRoot
      )
    }

    // 2. When server is unreachable, fail-closed primary erasure throws, while explicit local-only escape hatch (`skipRemoteMLSErasure: true`) succeeds
    let schema = Schema([AppSettingsModel.self, Preferences.self, DraftPost.self])
    let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    let context = ModelContext(container)
    context.insert(AppSettingsModel(accountDID: nonMLSDID))
    try context.save()

    await #expect(throws: URLError.self) {
      try await AccountDeletionCoordinator.eraseCatbirdData(
        forDID: nonMLSDID,
        storageRoot: emptyRoot,
        modelContext: context,
        skipRemoteMLSErasure: false,
        remoteMLSErasure: { _ in throw URLError(.cannotConnectToHost) },
        accountRemovalOverride: { _ in }
      )
    }

    try await AccountDeletionCoordinator.eraseCatbirdData(
      forDID: nonMLSDID,
      storageRoot: emptyRoot,
      modelContext: context,
      skipRemoteMLSErasure: true,
      remoteMLSErasure: { _ in throw URLError(.cannotConnectToHost) },
      accountRemovalOverride: { _ in }
    )
    let remaining = try context.fetch(
      FetchDescriptor<AppSettingsModel>(predicate: #Predicate { $0.id == "app_settings_\(nonMLSDID)" })
    )
    #expect(remaining.isEmpty)
  }

  private final class LivePDSLoopbackBridgeURLProtocol: URLProtocol {
    nonisolated(unsafe) static var targetLoopbackBaseURL: URL?

    override class func canInit(with request: URLRequest) -> Bool {
      request.url?.host == "live-pds.catbird.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private static func readBody(_ request: URLRequest) -> Data? {
      if let body = request.httpBody { return body }
      guard let stream = request.httpBodyStream else { return nil }
      stream.open()
      defer { stream.close() }
      var out = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        out.append(buffer, count: count)
      }
      return out
    }

    override func startLoading() {
      guard let base = Self.targetLoopbackBaseURL,
            let incomingURL = request.url,
            var targetComponents = URLComponents(url: base, resolvingAgainstBaseURL: false)
      else {
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        return
      }
      targetComponents.path = incomingURL.path
      targetComponents.percentEncodedQuery = incomingURL.query
      guard let targetURL = targetComponents.url else {
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        return
      }

      var forwarded = URLRequest(url: targetURL)
      forwarded.httpMethod = request.httpMethod
      forwarded.allHTTPHeaderFields = request.allHTTPHeaderFields
      forwarded.httpBody = Self.readBody(request)

      let rawSession = URLSession(configuration: .ephemeral)
      let task = rawSession.dataTask(with: forwarded) { [weak self] data, response, error in
        defer { rawSession.finishTasksAndInvalidate() }
        guard let self else { return }
        if let error {
          self.client?.urlProtocol(self, didFailWithError: error)
          return
        }
        if let http = response as? HTTPURLResponse,
           let rewritten = HTTPURLResponse(
             url: incomingURL,
             statusCode: http.statusCode,
             httpVersion: "HTTP/1.1",
             headerFields: http.allHeaderFields as? [String: String]
           ) {
          self.client?.urlProtocol(self, didReceive: rewritten, cacheStoragePolicy: .notAllowed)
        } else if let response {
          self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        if let data {
          self.client?.urlProtocol(self, didLoad: data)
        }
        self.client?.urlProtocolDidFinishLoading(self)
      }
      task.resume()
    }

    override func stopLoading() {}
  }

  private struct SeededLivePDSAccount: Decodable {
    let pdsUrl: String
    let did: String
    let handle: String
    let email: String
    let password: String
    let oauthAccessToken: String
  }

  private struct DPoPProofEnvelope: Decodable {
    let dpopProof: String
  }

  private struct DeletionTokenEnvelope: Decodable {
    let token: String
  }

  @Test(
    "A3 + A4 Live Reference PDS: OAuth DPoP fails 403 while PDSDirectDeletionClient createSession -> requestAccountDelete -> deleteAccount succeeds 200",
    .enabled(if: ProcessInfo.processInfo.environment["CATBIRD_LIVE_PDS_CONTROL_URL"] != nil)
  )
  @MainActor
  func liveReferencePDSDirectDeletionWireProof() async throws {
    let controlURLString = try #require(ProcessInfo.processInfo.environment["CATBIRD_LIVE_PDS_CONTROL_URL"])
    let controlBaseURL = try #require(URL(string: controlURLString))
    let rawHTTP = URLSession(configuration: .ephemeral)
    defer { rawHTTP.finishTasksAndInvalidate() }

    // 1. Seed a real account + stored DPoP-bound OAuth access token on live @atproto/pds
    var seedReq = URLRequest(url: controlBaseURL.appendingPathComponent("seed"))
    seedReq.httpMethod = "POST"
    let (seedData, seedResp) = try await rawHTTP.data(for: seedReq)
    #expect((seedResp as? HTTPURLResponse)?.statusCode == 200)
    let seeded = try JSONDecoder().decode(SeededLivePDSAccount.self, from: seedData)
    let livePDSBaseURL = try #require(URL(string: seeded.pdsUrl))

    // 2. Prove live @atproto/pds rejects OAuth DPoP credentials on requestAccountDelete with HTTP 403 Forbidden
    let requestDeleteURL = livePDSBaseURL.appendingPathComponent("xrpc/com.atproto.server.requestAccountDelete")
    func fetchDPoPProof(nonce: String?) async throws -> String {
      var comps = try #require(URLComponents(url: controlBaseURL.appendingPathComponent("dpop-proof"), resolvingAgainstBaseURL: false))
      var items = [
        URLQueryItem(name: "did", value: seeded.did),
        URLQueryItem(name: "htm", value: "POST"),
        URLQueryItem(name: "htu", value: requestDeleteURL.absoluteString),
      ]
      if let nonce {
        items.append(URLQueryItem(name: "nonce", value: nonce))
      }
      comps.queryItems = items
      let (proofData, proofResp) = try await rawHTTP.data(from: try #require(comps.url))
      #expect((proofResp as? HTTPURLResponse)?.statusCode == 200)
      return try JSONDecoder().decode(DPoPProofEnvelope.self, from: proofData).dpopProof
    }

    var oauthReq = URLRequest(url: requestDeleteURL)
    oauthReq.httpMethod = "POST"
    oauthReq.setValue("DPoP \(seeded.oauthAccessToken)", forHTTPHeaderField: "Authorization")
    oauthReq.setValue(try await fetchDPoPProof(nonce: nil), forHTTPHeaderField: "DPoP")
    var (oauthData, oauthResp) = try await rawHTTP.data(for: oauthReq)
    var oauthHTTP = try #require(oauthResp as? HTTPURLResponse)
    if (oauthHTTP.statusCode == 401 || oauthHTTP.statusCode == 400),
       let dpopNonce = oauthHTTP.value(forHTTPHeaderField: "DPoP-Nonce") {
      oauthReq.setValue(try await fetchDPoPProof(nonce: dpopNonce), forHTTPHeaderField: "DPoP")
      (oauthData, oauthResp) = try await rawHTTP.data(for: oauthReq)
      oauthHTTP = try #require(oauthResp as? HTTPURLResponse)
    }
    let oauthJSON = (try? JSONSerialization.jsonObject(with: oauthData) as? [String: String]) ?? [:]
    #expect(oauthHTTP.statusCode == 403)
    #expect(oauthJSON["error"] == "Forbidden")
    #expect(oauthJSON["message"] == "OAuth credentials are not supported for this endpoint")

    // 3. Prove AccountDeletionCoordinator + PDSDirectDeletionClient succeeds 200 against the live @atproto/pds instance
    LivePDSLoopbackBridgeURLProtocol.targetLoopbackBaseURL = livePDSBaseURL
    defer { LivePDSLoopbackBridgeURLProtocol.targetLoopbackBaseURL = nil }

    let bridgedConfig = URLSessionConfiguration.ephemeral
    bridgedConfig.httpCookieStorage = nil
    bridgedConfig.urlCache = nil
    bridgedConfig.urlCredentialStorage = nil
    bridgedConfig.protocolClasses = [LivePDSLoopbackBridgeURLProtocol.self]
    let bridgedSession = URLSession(configuration: bridgedConfig)
    defer { bridgedSession.finishTasksAndInvalidate() }

    let directClient = PDSDirectDeletionClient(session: bridgedSession)
    let httpsAliasPDSURL = URL(string: "https://live-pds.catbird.test")!

    try await AccountDeletionCoordinator.requestHostedAccountDeletionCode(
      forDID: seeded.did,
      password: seeded.password,
      pdsURL: httpsAliasPDSURL,
      directClient: directClient
    )

    var tokenComps = try #require(URLComponents(url: controlBaseURL.appendingPathComponent("latest-token"), resolvingAgainstBaseURL: false))
    tokenComps.queryItems = [URLQueryItem(name: "did", value: seeded.did)]
    let (tokenData, tokenResp) = try await rawHTTP.data(from: try #require(tokenComps.url))
    #expect((tokenResp as? HTTPURLResponse)?.statusCode == 200)
    let emailConfirmationToken = try JSONDecoder().decode(DeletionTokenEnvelope.self, from: tokenData).token
    #expect(!emailConfirmationToken.isEmpty)

    // 4. Prove A4 against live @atproto/pds: mistyped password fails 401 at createSession BEFORE Labyrinth remote backup wipe runs
    var remoteEraseCount = 0
    var localEraseCount = 0
    await #expect(throws: PDSDirectDeletionError.self) {
      try await AccountDeletionCoordinator.performHostedAccountDeletion(
        forDID: seeded.did,
        password: "mistyped-password-should-not-wipe-backups",
        confirmationToken: emailConfirmationToken,
        remoteErasureConsent: .explicitlyConfirmed,
        pdsURL: httpsAliasPDSURL,
        remoteMLSErasure: { _ in remoteEraseCount += 1 },
        localErasureOverride: { _ in localEraseCount += 1 },
        directClient: directClient
      )
    }
    #expect(remoteEraseCount == 0)
    #expect(localEraseCount == 0)

    // 5. Prove full hosted deletion succeeds 200 on live @atproto/pds and removes the account from PDS
    try await AccountDeletionCoordinator.performHostedAccountDeletion(
      forDID: seeded.did,
      password: seeded.password,
      confirmationToken: emailConfirmationToken,
      remoteErasureConsent: .explicitlyConfirmed,
      pdsURL: httpsAliasPDSURL,
      remoteMLSErasure: { _ in remoteEraseCount += 1 },
      localErasureOverride: { _ in localEraseCount += 1 },
      directClient: directClient
    )
    #expect(remoteEraseCount == 1)
    #expect(localEraseCount == 1)

    var postDeleteLogin = URLRequest(url: livePDSBaseURL.appendingPathComponent("xrpc/com.atproto.server.createSession"))
    postDeleteLogin.httpMethod = "POST"
    postDeleteLogin.setValue("application/json", forHTTPHeaderField: "Content-Type")
    postDeleteLogin.httpBody = try JSONSerialization.data(withJSONObject: [
      "identifier": seeded.did,
      "password": seeded.password,
    ])
    let (_, postDeleteResp) = try await rawHTTP.data(for: postDeleteLogin)
    #expect((postDeleteResp as? HTTPURLResponse)?.statusCode == 401)
  }
}
