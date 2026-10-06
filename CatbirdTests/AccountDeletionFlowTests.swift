import Foundation
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
                    "https://provider.example?did=fixture", "https://provider.example#x", "catbird://account"])
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
    recordInto log: FetchLog? = nil
  ) -> AccountManagementPageResolver {
    AccountManagementPageResolver { url in
      await log?.record(url)
      let response = url.path == "/.well-known/oauth-authorization-server" ? issuerBody : body
      guard let response else { throw FetchFailure() }
      return Data(response.utf8)
    }
  }

  private actor FetchLog {
    private(set) var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
  }

  @Test("A separate known issuer is bound to the PDS and identifies itself")
  func discoversSeparateIssuer() async throws {
    let log = FetchLog()
    let result = await resolver(#"{"resource":"https://morel.us-east.host.bsky.network","authorization_servers":["https://bsky.social"]}"#, recordInto: log)
      .destination(forPDS: URL(string: "https://morel.us-east.host.bsky.network"))
    let destination = try #require(result)
    #expect(destination.url.absoluteString == "https://bsky.social/account")
    #expect(destination.kind == .accountSettings)
    #expect(await log.urls.map(\.absoluteString) == [
      "https://morel.us-east.host.bsky.network/.well-known/oauth-protected-resource",
      "https://bsky.social/.well-known/oauth-authorization-server"
    ])
  }

  @Test("The known Bluesky PDS has an explicit account-page convention")
  func knownProvider() async throws {
    let log = FetchLog()
    let result = await resolver(nil, recordInto: log).destination(forPDS: URL(string: "https://bsky.social:443/"))
    let destination = try #require(result)
    #expect(destination.url.absoluteString == "https://bsky.social/account")
    #expect(destination.kind == .accountSettings)
    #expect(await log.urls.isEmpty)
  }

  @Test("An unknown self-hosted provider keeps its origin and port without guessing a route")
  func selfHostedProvider() async throws {
    let result = await resolver(#"{"resource":"https://pds.example:8443","authorization_servers":["https://pds.example:8443/"]}"#)
      .destination(forPDS: URL(string: "https://pds.example:8443"))
    let destination = try #require(result)
    #expect(destination.url.absoluteString == "https://pds.example:8443")
    #expect(destination.kind == .providerWebsite)
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
