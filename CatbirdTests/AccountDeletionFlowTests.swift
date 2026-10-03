import Foundation
import Testing
@testable import Catbird

@Suite("Account deletion provider handoff")
struct AccountDeletionFlowTests {
  private let did = "did:plc:local-deletion-fixture"

  private func makeFlow(handle: String? = "fixture.example") -> AccountDeletionFlow {
    AccountDeletionFlow(target: AccountDeletionTarget(did: did, handle: handle))
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

  @Test("Bluesky and custom handles use the same fixed settings route without account data",
        arguments: ["fixture.bsky.social", "fixture.custom.example", "bsky.social.evil.example", "https://evil.example/?token=fixture"])
  func fixedDestination(handle: String) throws {
    var flow = makeFlow(handle: handle)
    var opener = FakeURLOpener()
    let attempt = try openingAttempt(for: &flow)
    opener.open(attempt)
    #expect(opener.urls.map(\.absoluteString) == ["https://bsky.app/settings/account"])
    #expect(attempt.url.query == nil)
    #expect(attempt.url.fragment == nil)
    #expect(attempt.url.user == nil)
    #expect(attempt.url.password == nil)
    #expect(!attempt.url.absoluteString.contains(did))
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
