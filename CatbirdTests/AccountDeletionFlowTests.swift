import Foundation
import Testing
@testable import Catbird

@Suite("Account deletion provider handoff")
struct AccountDeletionFlowTests {
  private let did = "did:plc:local-deletion-fixture"
  private let providerPage = URL(string: "https://provider.example/account")!

  private func makeFlow(handle: String? = "fixture.example") -> AccountDeletionFlow {
    var flow = AccountDeletionFlow(target: AccountDeletionTarget(did: did, handle: handle))
    flow.resolveDestination(providerPage)
    return flow
  }

  private func openingAttempt(for flow: inout AccountDeletionFlow) throws -> AccountDeletionFlow.OpeningAttempt {
    let pending = flow.prepareToOpen(currentDID: did)
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
    opener.open(flow.prepareToOpen(currentDID: did))
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
    var flow = AccountDeletionFlow(target: AccountDeletionTarget(did: did, handle: "fixture.example"))
    #expect(flow.isResolvingDestination)
    #expect(!flow.canOpen)
    #expect(flow.prepareToOpen(currentDID: did) == nil)
    #expect(flow.phase == .ready)
  }

  @Test("Only plain HTTPS provider pages are accepted",
        arguments: ["http://provider.example/account", "https://user:pass@provider.example/account",
                    "https://provider.example/account?did=fixture", "https://provider.example/account#x", "catbird://account"])
  func rejectsUnsafeDestination(address: String) throws {
    var flow = AccountDeletionFlow(target: AccountDeletionTarget(did: did, handle: nil))
    flow.resolveDestination(try #require(URL(string: address)))
    #expect(flow.destination == nil)
    #expect(!flow.canOpen)
  }

  @Test("Repeated taps dispatch only one opening attempt")
  func repeatedTaps() throws {
    var flow = makeFlow()
    var opener = FakeURLOpener()
    opener.open(try openingAttempt(for: &flow))
    opener.open(flow.prepareToOpen(currentDID: did))
    #expect(opener.urls.count == 1)
    #expect(!flow.canOpen)
  }

  @Test("OS URL acceptance records only that the link opened")
  func acceptedLink() throws {
    var flow = makeFlow()
    let attempt = try openingAttempt(for: &flow)
    flow.finishOpening(attempt.id, accepted: true, currentDID: did)
    #expect(flow.phase == .opened)
    #expect(flow.target.did == did)
    #expect(flow.canOpen)
  }

  @Test("Failed opening permits retry and ignores a stale completion")
  func retryAfterFailure() throws {
    var flow = makeFlow()
    let first = try openingAttempt(for: &flow)
    flow.finishOpening(first.id, accepted: false, currentDID: did)
    #expect(flow.phase == .failed)
    let retry = try openingAttempt(for: &flow)
    flow.finishOpening(first.id, accepted: true, currentDID: did)
    #expect(flow.phase == .opening(retry.id))
    flow.finishOpening(retry.id, accepted: true, currentDID: did)
    #expect(flow.phase == .opened)
  }

  @Test("Cancel ignores an in-flight opening completion")
  func cancelDuringOpening() throws {
    var flow = makeFlow()
    let attempt = try openingAttempt(for: &flow)
    flow.cancel()
    flow.finishOpening(attempt.id, accepted: true, currentDID: did)
    #expect(flow.phase == .cancelled)
    #expect(!flow.canOpen)
  }

  @Test("An account switch before opening prevents dispatch, even after switching back")
  func switchBeforeOpening() {
    var flow = makeFlow()
    var opener = FakeURLOpener()
    opener.open(flow.prepareToOpen(currentDID: "did:plc:other-local-fixture"))
    opener.open(flow.prepareToOpen(currentDID: did))
    #expect(opener.urls.isEmpty)
    #expect(flow.phase == .accountChanged)
  }

  @Test("A sign-out during opening cannot record successful handoff")
  func signOutDuringOpening() throws {
    var flow = makeFlow()
    let attempt = try openingAttempt(for: &flow)
    flow.finishOpening(attempt.id, accepted: true, currentDID: "")
    #expect(flow.phase == .accountChanged)
    #expect(!flow.canOpen)
  }

  @Test("Account change invalidates the sheet before any callback")
  func observedAccountChange() throws {
    var flow = makeFlow()
    let attempt = try openingAttempt(for: &flow)
    flow.accountDidChange(to: "did:plc:other-local-fixture")
    flow.finishOpening(attempt.id, accepted: true, currentDID: did)
    #expect(flow.phase == .accountChanged)
  }

  @Test("A missing account cannot start a handoff")
  func missingAccount() {
    var flow = AccountDeletionFlow(target: AccountDeletionTarget(did: "", handle: nil))
    let pending = flow.prepareToOpen(currentDID: "")
    #expect(pending == nil)
    #expect(!flow.canOpen)
  }
}

@Suite("Account management page discovery")
struct AccountManagementPageResolverTests {
  private struct FetchFailure: Error {}

  private func resolver(_ body: String?, recordInto log: FetchLog? = nil) -> AccountManagementPageResolver {
    AccountManagementPageResolver { url in
      await log?.record(url)
      guard let body else { throw FetchFailure() }
      return Data(body.utf8)
    }
  }

  private actor FetchLog {
    private(set) var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
  }

  @Test("Uses the issuer from the PDS's protected-resource metadata")
  func discoversIssuer() async {
    let log = FetchLog()
    let page = await resolver(#"{"resource":"https://morel.us-east.host.bsky.network","authorization_servers":["https://bsky.social"]}"#, recordInto: log)
      .accountPageURL(forPDS: URL(string: "https://morel.us-east.host.bsky.network/xrpc/x?y=1"))
    #expect(page.absoluteString == "https://bsky.social/account")
    #expect(await log.urls.map(\.absoluteString) == ["https://morel.us-east.host.bsky.network/.well-known/oauth-protected-resource"])
  }

  @Test("A self-hosted PDS that is its own issuer keeps its port")
  func selfHostedIssuer() async {
    let page = await resolver(#"{"authorization_servers":["https://pds.example:8443/"]}"#)
      .accountPageURL(forPDS: URL(string: "https://pds.example:8443"))
    #expect(page.absoluteString == "https://pds.example:8443/account")
  }

  @Test("Falls back to the PDS account page when discovery fails or the issuer isn't a bare HTTPS origin",
        arguments: [nil, "not json", #"{}"#, #"{"authorization_servers":[]}"#,
                    #"{"authorization_servers":["http://issuer.example"]}"#,
                    #"{"authorization_servers":["https://issuer.example/oauth"]}"#,
                    #"{"authorization_servers":["https://issuer.example?x=1"]}"#,
                    #"{"authorization_servers":["https://user@issuer.example"]}"#] as [String?])
  func fallsBackToPDS(body: String?) async {
    let page = await resolver(body).accountPageURL(forPDS: URL(string: "https://pds.example"))
    #expect(page.absoluteString == "https://pds.example/account")
  }

  @Test("Falls back to Bluesky's account settings when the PDS is unknown or not HTTPS",
        arguments: [nil, "http://pds.example", "https://user:pass@pds.example"] as [String?])
  func fallsBackToBluesky(pds: String?) async {
    let log = FetchLog()
    let page = await resolver(#"{"authorization_servers":["https://bsky.social"]}"#, recordInto: log)
      .accountPageURL(forPDS: pds.flatMap(URL.init(string:)))
    #expect(page == AccountManagementPageResolver.fallbackURL)
    #expect(await log.urls.isEmpty)
  }

  @Test("Display host omits the default port")
  func displayHost() {
    #expect(AccountManagementPageResolver.displayHost(of: URL(string: "https://bsky.social/account")!) == "bsky.social")
    #expect(AccountManagementPageResolver.displayHost(of: URL(string: "https://pds.example:8443/account")!) == "pds.example:8443")
  }
}
