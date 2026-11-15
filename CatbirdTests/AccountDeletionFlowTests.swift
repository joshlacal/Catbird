import Foundation
import SwiftData
import Testing
@testable import Catbird

@Suite("Account deletion provider handoff")
struct AccountDeletionFlowTests {
  private let did = "did:plc:local-deletion-fixture"
  private let revision: UInt64 = 42
  private let providerPage = URL(string: "https://provider.example")!

  private func makeFlow(handle: String? = "fixture.example") -> AccountDeletionFlow {
    var flow = AccountDeletionFlow(target: AccountDeletionTarget(did: did, handle: handle, accountRevision: revision))
    flow.resolveDestination(.init(url: providerPage, kind: .providerWebsite), currentDID: did, currentRevision: revision)
    return flow
  }

  private func openingAttempt(for flow: inout AccountDeletionFlow) throws -> AccountDeletionFlow.OpeningAttempt {
    let pending = flow.prepareToOpen(currentDID: did, currentRevision: revision)
    return try #require(pending)
  }

  private struct FakeURLOpener {
    private(set) var urls: [URL] = []

    mutating func open(_ attempt: AccountDeletionFlow.OpeningAttempt?) {
      if let attempt { urls.append(attempt.url) }
    }
  }

  @Test("Review and cancellation do not dispatch a URL")
  func reviewAndCancellation() {
    var flow = makeFlow()
    var opener = FakeURLOpener()
    #expect(flow.phase == .ready)
    #expect(opener.urls.isEmpty)
    flow.cancel()
    opener.open(flow.prepareToOpen(currentDID: did, currentRevision: revision))
    #expect(opener.urls.isEmpty)
    #expect(flow.phase == .cancelled)
  }

  @Test("Opens only the resolved provider page, without account data",
        arguments: ["fixture.bsky.social", "fixture.custom.example", "bsky.social.evil.example", "https://evil.example/?token=fixture"])
  func resolvedDestination(handle: String) throws {
    var flow = makeFlow(handle: handle)
    var opener = FakeURLOpener()
    let attempt = try openingAttempt(for: &flow)
    opener.open(attempt)
    #expect(opener.urls == [providerPage])
    #expect(attempt.url.query == nil)
    #expect(attempt.url.fragment == nil)
    #expect(attempt.url.user == nil)
    #expect(attempt.url.password == nil)
    #expect(!attempt.url.absoluteString.contains(did))
  }

  @Test("Destination with valid login_hint is accepted and scoped")
  func destinationWithLoginHint() throws {
    var flow = AccountDeletionFlow(target: AccountDeletionTarget(did: did, handle: "fixture.handle", accountRevision: revision))
    let destinationURL = URL(string: "https://bsky.social/account?login_hint=fixture.handle")!
    flow.resolveDestination(.init(url: destinationURL, kind: .accountSettings), currentDID: did, currentRevision: revision)
    #expect(flow.canOpen)
    #expect(flow.destination?.url == destinationURL)
  }

  @Test("Nothing opens until the provider page is known")
  func waitsForDestination() {
    var flow = AccountDeletionFlow(target: AccountDeletionTarget(did: did, handle: "fixture.example", accountRevision: revision))
    #expect(flow.isResolvingDestination)
    #expect(!flow.canOpen)
    #expect(flow.prepareToOpen(currentDID: did, currentRevision: revision) == nil)
    #expect(flow.phase == .ready)
  }

  @Test("Only plain HTTPS provider pages are accepted",
        arguments: ["http://provider.example/account", "https://user:pass@provider.example/account",
                    "https://provider.example?did=fixture", "https://provider.example#x", "catbird://account",
                    "https://provider.example?token=secret", "https://provider.example?login_hint=alice&token=secret"])
  func rejectsUnsafeDestination(address: String) throws {
    var flow = AccountDeletionFlow(target: AccountDeletionTarget(did: did, handle: nil, accountRevision: revision))
    flow.resolveDestination(.init(url: try #require(URL(string: address)), kind: .providerWebsite), currentDID: did, currentRevision: revision)
    #expect(flow.destination == nil)
    #expect(!flow.canOpen)
  }

  @Test("Repeated taps dispatch only one opening attempt")
  func repeatedTaps() throws {
    var flow = makeFlow()
    var opener = FakeURLOpener()
    opener.open(try openingAttempt(for: &flow))
    opener.open(flow.prepareToOpen(currentDID: did, currentRevision: revision))
    #expect(opener.urls.count == 1)
    #expect(!flow.canOpen)
  }

  @Test("OS URL acceptance records only that the link opened")
  func acceptedLink() throws {
    var flow = makeFlow()
    let attempt = try openingAttempt(for: &flow)
    flow.finishOpening(attempt.id, accepted: true, currentDID: did, currentRevision: revision)
    #expect(flow.phase == .opened)
    #expect(flow.target.did == did)
    #expect(flow.canOpen)
  }

  @Test("Failed opening permits retry and ignores a stale completion")
  func retryAfterFailure() throws {
    var flow = makeFlow()
    let first = try openingAttempt(for: &flow)
    flow.finishOpening(first.id, accepted: false, currentDID: did, currentRevision: revision)
    #expect(flow.phase == .failed)
    let retry = try openingAttempt(for: &flow)
    flow.finishOpening(first.id, accepted: true, currentDID: did, currentRevision: revision)
    #expect(flow.phase == .opening(retry.id))
    flow.finishOpening(retry.id, accepted: true, currentDID: did, currentRevision: revision)
    #expect(flow.phase == .opened)
  }

  @Test("Cancel ignores an in-flight opening completion")
  func cancelDuringOpening() throws {
    var flow = makeFlow()
    let attempt = try openingAttempt(for: &flow)
    flow.cancel()
    flow.finishOpening(attempt.id, accepted: true, currentDID: did, currentRevision: revision)
    #expect(flow.phase == .cancelled)
    #expect(!flow.canOpen)
  }

  @Test("An account switch before opening prevents dispatch, even after switching back")
  func switchBeforeOpening() {
    var flow = makeFlow()
    var opener = FakeURLOpener()
    opener.open(flow.prepareToOpen(currentDID: "did:plc:other-local-fixture", currentRevision: revision))
    opener.open(flow.prepareToOpen(currentDID: did, currentRevision: revision))
    #expect(opener.urls.isEmpty)
    #expect(flow.phase == .accountChanged)
  }

  @Test("A sign-out during opening cannot record successful handoff")
  func signOutDuringOpening() throws {
    var flow = makeFlow()
    let attempt = try openingAttempt(for: &flow)
    flow.finishOpening(attempt.id, accepted: true, currentDID: "", currentRevision: revision)
    #expect(flow.phase == .accountChanged)
    #expect(!flow.canOpen)
  }

  @Test("Account change invalidates the sheet before any callback")
  func observedAccountChange() throws {
    var flow = makeFlow()
    let attempt = try openingAttempt(for: &flow)
    flow.accountDidChange(to: "did:plc:other-local-fixture", revision: revision)
    flow.finishOpening(attempt.id, accepted: true, currentDID: did, currentRevision: revision)
    #expect(flow.phase == .accountChanged)
  }

  @Test("A missing account cannot start a handoff")
  func missingAccount() {
    var flow = AccountDeletionFlow(target: AccountDeletionTarget(did: "", handle: nil, accountRevision: revision))
    let pending = flow.prepareToOpen(currentDID: "", currentRevision: revision)
    #expect(pending == nil)
    #expect(!flow.canOpen)
  }

  @Test("Unavailable discovery ends loading without a fallback URL")
  func unavailableDestination() {
    var flow = AccountDeletionFlow(target: .init(did: did, handle: nil, accountRevision: revision))
    flow.resolveDestination(nil, currentDID: did, currentRevision: revision)
    #expect(flow.phase == .unavailable)
    #expect(!flow.isResolvingDestination)
    #expect(!flow.canOpen)
  }

  @Test("Cancelled discovery cannot attach a provider URL")
  func lateResolutionAfterCancel() {
    var flow = AccountDeletionFlow(target: .init(did: did, handle: nil, accountRevision: revision))
    flow.cancel()
    flow.resolveDestination(.init(url: providerPage, kind: .providerWebsite), currentDID: did, currentRevision: revision)
    #expect(flow.destination == nil)
    #expect(flow.phase == .cancelled)
  }

  @Test("A same-DID return in a newer account context invalidates discovery")
  func staleResolutionAfterReturningToAccount() {
    var flow = AccountDeletionFlow(target: .init(did: did, handle: nil, accountRevision: revision))
    flow.resolveDestination(.init(url: providerPage, kind: .providerWebsite), currentDID: did, currentRevision: revision + 2)
    #expect(flow.destination == nil)
    #expect(flow.phase == .accountChanged)
    #expect(!flow.isResolvingDestination)
    #expect(flow.prepareToOpen(currentDID: did, currentRevision: revision + 2) == nil)
  }

  @Test("Changed account discovery stays invalid after returning to the original DID")
  func lateResolutionAfterSwitch() {
    var flow = AccountDeletionFlow(target: .init(did: did, handle: nil, accountRevision: revision))
    flow.accountDidChange(to: "did:plc:other-fixture", revision: revision + 1)
    flow.resolveDestination(.init(url: providerPage, kind: .providerWebsite), currentDID: did, currentRevision: revision + 2)
    #expect(flow.destination == nil)
    #expect(flow.phase == .accountChanged)
  }

  @Test("A newer account revision cannot accept an opening callback")
  func staleOpeningRevision() throws {
    var flow = makeFlow()
    let attempt = try openingAttempt(for: &flow)
    flow.finishOpening(attempt.id, accepted: true, currentDID: did, currentRevision: revision + 2)
    #expect(flow.phase == .accountChanged)
    #expect(flow.destination == nil)
  }
}

@Suite("Account management page discovery")
struct AccountManagementPageResolverTests {
  private struct FetchFailure: Error {}

  private func resolver(
    _ body: String?,
    issuerBody: String? = #"{"issuer":"https://bsky.social"}"#,
    probeResponse: Bool? = nil,
    recordInto log: FetchLog? = nil,
    recordProbeInto probeLog: ProbeLog? = nil
  ) -> AccountManagementPageResolver {
    AccountManagementPageResolver(
      fetch: { url in
        await log?.record(url)
        let response = url.path == "/.well-known/oauth-authorization-server" ? issuerBody : body
        guard let response else { throw FetchFailure() }
        return Data(response.utf8)
      },
      probe: { request in
        await probeLog?.record(request)
        if let probeResponse {
          return probeResponse
        }
        guard request.value(forHTTPHeaderField: "Sec-Fetch-Mode") == "navigate",
              request.value(forHTTPHeaderField: "Sec-Fetch-Dest") == "document" else {
          return false
        }
        if let url = request.url {
          if AccountManagementPageResolver.isKnownBlueskyOrigin(url) || AccountManagementPageResolver.isKnownSwanOrigin(url) {
            return true
          }
        }
        return false
      }
    )
  }

  private actor FetchLog {
    private(set) var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
  }

  private actor ProbeLog {
    private(set) var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
  }

  @Test("A separate known issuer is bound to the PDS and identifies itself")
  func discoversSeparateIssuer() async throws {
    let log = FetchLog()
    let result = await resolver(#"{"resource":"https://morel.us-east.host.bsky.network","authorization_servers":["https://bsky.social"]}"#, recordInto: log)
      .destination(forPDS: URL(string: "https://morel.us-east.host.bsky.network"), accountHandle: "alice.bsky.social")
    let destination = try #require(result)
    #expect(destination.url.absoluteString == "https://bsky.social/account?login_hint=alice.bsky.social")
    #expect(destination.kind == .accountSettings)
    #expect(await log.urls.map(\.absoluteString) == [
      "https://morel.us-east.host.bsky.network/.well-known/oauth-protected-resource",
      "https://bsky.social/.well-known/oauth-authorization-server"
    ])
  }

  @Test("The known Bluesky PDS has an explicit account-page convention with login_hint")
  func knownProvider() async throws {
    let log = FetchLog()
    let result = await resolver(nil, recordInto: log)
      .destination(forPDS: URL(string: "https://bsky.social:443/"), userDID: "did:plc:fixture-user")
    let destination = try #require(result)
    #expect(destination.url.absoluteString == "https://bsky.social/account?login_hint=did%3Aplc%3Afixture-user")
    #expect(destination.kind == .accountSettings)
    #expect(await log.urls.isEmpty)
  }

  @Test("A self-hosted reference PDS with /account support resolves with login_hint and navigation headers")
  func selfHostedProviderWithAccount() async throws {
    let probeLog = ProbeLog()
    let result = await resolver(
      #"{"resource":"https://pds.example:8443","authorization_servers":["https://pds.example:8443/"]}"#,
      probeResponse: true,
      recordProbeInto: probeLog
    ).destination(
      forPDS: URL(string: "https://pds.example:8443"),
      accountHandle: "bob.example"
    )
    let destination = try #require(result)
    #expect(destination.url.absoluteString == "https://pds.example:8443/account?login_hint=bob.example")
    #expect(destination.kind == .accountSettings)
    let probedRequests = await probeLog.requests
    #expect(probedRequests.count == 1)
    let request = try #require(probedRequests.first)
    #expect(request.value(forHTTPHeaderField: "Sec-Fetch-Mode") == "navigate")
    #expect(request.value(forHTTPHeaderField: "Sec-Fetch-Dest") == "document")
  }

  @Test("A self-hosted provider without /account support falls back to website root")
  func selfHostedProviderFallback() async throws {
    let result = await resolver(
      #"{"resource":"https://pds.example:8443","authorization_servers":["https://pds.example:8443/"]}"#,
      probeResponse: false
    ).destination(forPDS: URL(string: "https://pds.example:8443"))
    let destination = try #require(result)
    #expect(destination.url.absoluteString == "https://pds.example:8443")
    #expect(destination.kind == .providerWebsite)
  }

  @Test("Swan provider resolves /account with login_hint when probed")
  func swanProvider() async throws {
    let probeLog = ProbeLog()
    let result = await resolver(
      #"{"resource":"https://pds.swan.place","authorization_servers":["https://swan.place"]}"#,
      issuerBody: #"{"issuer":"https://swan.place"}"#,
      probeResponse: true,
      recordProbeInto: probeLog
    ).destination(
      forPDS: URL(string: "https://pds.swan.place"),
      userDID: "did:plc:swan-user"
    )
    let destination = try #require(result)
    #expect(destination.url.absoluteString == "https://swan.place/account?login_hint=did%3Aplc%3Aswan-user")
    #expect(destination.kind == .accountSettings)
  }

  @Test("An unknown separate issuer does not become an invented management page")
  func unknownIssuer() async throws {
    let log = FetchLog()
    let result = await resolver(#"{"resource":"https://pds.example","authorization_servers":["https://entryway.example"]}"#, recordInto: log)
      .destination(forPDS: URL(string: "https://pds.example"))
    let destination = try #require(result)
    #expect(destination.url.absoluteString == "https://pds.example")
    #expect(destination.kind == .providerWebsite)
    #expect(await log.urls.map(\.host) == ["pds.example"])
  }

  @Test("Unusable or mismatched resource metadata preserves only the PDS website",
        arguments: [nil, "not json", #"{}"#,
                    #"{"resource":"https://other.example","authorization_servers":["https://bsky.social"]}"#,
                    #"{"resource":"https://pds.example","authorization_servers":[]}"#,
                    #"{"resource":"https://pds.example","authorization_servers":["https://bsky.social","https://other.example"]}"#,
                    #"{"resource":"https://pds.example","authorization_servers":["http://bsky.social"]}"#,
                    #"{"resource":"https://pds.example","authorization_servers":["https://bsky.social/oauth"]}"#,
                    #"{"resource":"https://pds.example","authorization_servers":["https://bsky.social?x=1"]}"#,
                    #"{"resource":"https://pds.example","authorization_servers":["https://user@bsky.social"]}"#,
                    #"{"resource":"https://pds.example","authorization_servers":["https://bsky.social.evil.example"]}"#,
                    #"{"resource":"https://pds.example","authorization_servers":["https://bsky.social:8443"]}"#] as [String?])
  func fallsBackToWebsite(body: String?) async throws {
    let result = await resolver(body).destination(forPDS: URL(string: "https://pds.example"))
    let destination = try #require(result)
    #expect(destination.url.absoluteString == "https://pds.example")
    #expect(destination.kind == .providerWebsite)
  }

  @Test("A separate known issuer must match its own metadata",
        arguments: [nil, "not json", #"{}"#, #"{"issuer":"https://other.example"}"#,
                    #"{"issuer":"https://bsky.social/account"}"#, #"{"issuer":"https://bsky.social?x=1"}"#] as [String?])
  func rejectsMismatchedIssuer(issuerBody: String?) async throws {
    let result = await resolver(#"{"resource":"https://pds.example","authorization_servers":["https://bsky.social"]}"#, issuerBody: issuerBody)
      .destination(forPDS: URL(string: "https://pds.example"))
    let destination = try #require(result)
    #expect(destination.url.absoluteString == "https://pds.example")
    #expect(destination.kind == .providerWebsite)
  }

  @Test("Missing or unsafe PDS information is unavailable with no network or Bluesky fallback",
        arguments: [nil, "http://pds.example", "https://user:pass@pds.example",
                    "https://pds.example?token=fixture", "https://pds.example#fixture",
                    "https://pds.example/xrpc/x", "https://pds.example:70000"] as [String?])
  func unavailablePDS(pds: String?) async {
    let log = FetchLog()
    let destination = await resolver(nil, recordInto: log)
      .destination(forPDS: pds.flatMap(URL.init(string:)))
    #expect(destination == nil)
    #expect(await log.urls.isEmpty)
  }

  @Test("Display host omits the default port")
  func displayHost() {
    #expect(AccountManagementPageResolver.displayHost(of: URL(string: "https://bsky.social/account")!) == "bsky.social")
    #expect(AccountManagementPageResolver.displayHost(of: URL(string: "https://pds.example:8443")!) == "pds.example:8443")
  }
}

@Suite("Account deletion Catbird data erasure")
struct AccountDeletionCoordinatorTests {
  @Test("Erase Catbird data removes SwiftData records for the specified account while preserving others")
  @MainActor
  func swiftDataErasure() async throws {
    let schema = Schema([AppSettingsModel.self, Preferences.self, DraftPost.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [config])
    let context = ModelContext(container)

    let targetDID = "did:plc:target-delete"
    let preservedDID = "did:plc:keep-intact"

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

    // Execute erasure
    try await AccountDeletionCoordinator.eraseCatbirdData(forDID: targetDID, token: "test-token", modelContext: context)

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

  @Test("A3 + A4: Direct PDS deletion uses in-memory createSession Bearer JWT and pre-validates password BEFORE wiping Labyrinth backups")
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

    // 3. Valid password + token executes in exact fail-safe order:
    //    createSession -> remoteMLSErasure -> deleteAccount -> localErasure
    events.removeAll()
    try await AccountDeletionCoordinator.performHostedAccountDeletion(
      forDID: targetDID,
      password: "correct-horse-battery",
      confirmationToken: "EMAIL-CODE-999",
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
    #expect(remoteEraseCount == 1)
    #expect(localEraseCount == 1)
    #expect(events == ["createSession", "remoteMLSErasure", "deleteAccount", "localErasure"])
  }

  @Test("A3: Non-MLS/non-Circles account skips remote deleteAccountData and local-only escape hatch succeeds when server is unreachable")
  @MainActor
  func nonMLSAccountSkipsRemoteDeleteAndLocalOnlyEscapeHatchWorksOffline() async throws {
    let nonMLSDID = "did:plc:nonmlsregularuser01"
    let fm = FileManager.default
    let emptyRoot = fm.temporaryDirectory.appendingPathComponent("catbird-nonmls-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: emptyRoot) }

    // 1. Account with no MLS opt-in, no local MLS DB, and no Circle keys skips remote deleteAccountData cleanly
    ExperimentalSettings.shared.disableMLSChat(for: nonMLSDID)
    try await AccountDeletionCoordinator.eraseServerSideLabyrinthDataIfAuthenticated(
      forDID: nonMLSDID,
      storageRoot: emptyRoot
    )

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
        remoteMLSErasure: { _ in throw URLError(.cannotConnectToHost) }
      )
    }

    try await AccountDeletionCoordinator.eraseCatbirdData(
      forDID: nonMLSDID,
      storageRoot: emptyRoot,
      modelContext: context,
      skipRemoteMLSErasure: true,
      remoteMLSErasure: { _ in throw URLError(.cannotConnectToHost) }
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
