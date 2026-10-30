import Foundation
import Testing
@testable import Catbird

@MainActor
struct SettingsFeedRefreshGateTests {
  @Test("A busy feed keeps the latest relaxation until loading finishes")
  func coalescesBusyRequests() async {
    let context = SettingsFeedRefreshContext(accountDID: "did:fixture", accountRevision: 1, clientIdentity: nil)
    var busy = true
    var pauses = 0
    var prepared = 0
    var reloads = 0
    let gate = SettingsFeedRefreshGate(pause: {
      pauses += 1
      try Task.checkCancellation()
      await Task.yield()
    })
    func request() {
      gate.request(context: context, isCurrentContext: { $0 == context }, isLoading: { busy },
        prepare: { isCurrent in if isCurrent() { prepared += 1 } }, reload: { reloads += 1 })
    }
    request()
    await waitUntil { pauses > 0 }
    #expect(reloads == 0)
    request()
    await waitUntil { prepared == 2 }
    busy = false
    await waitUntil { reloads == 1 }
    #expect(reloads == 1)
  }

  @Test("Returning to the same DID after a switch does not admit a stale request")
  func activationFence() async {
    let origin = SettingsFeedRefreshContext(accountDID: "did:fixture", accountRevision: 1, clientIdentity: nil)
    var active = origin
    var busy = true
    var pauses = 0
    var reloads = 0
    let gate = SettingsFeedRefreshGate(pause: {
      pauses += 1
      try Task.checkCancellation()
      await Task.yield()
    })
    gate.request(context: origin, isCurrentContext: { $0 == active }, isLoading: { busy },
      prepare: { _ in }, reload: { reloads += 1 })
    await waitUntil { pauses > 0 }
    active = .init(accountDID: "did:fixture", accountRevision: 3, clientIdentity: nil)
    busy = false
    for _ in 0..<100 { await Task.yield() }
    #expect(reloads == 0)
  }

  @Test("Only effective reading-language changes alter the refresh signature")
  func readingSignature() {
    let origin = ReadingLanguageFilterSignature(hideOtherLanguages: true, preferredLanguages: ["en-US"])
    #expect(origin == .init(hideOtherLanguages: true, preferredLanguages: ["EN_gb", "zz-unknown"]))
    #expect(origin != .init(hideOtherLanguages: false, preferredLanguages: ["en-US"]))
    #expect(ReadingLanguageFilterSignature(hideOtherLanguages: false, preferredLanguages: ["en"])
      == .init(hideOtherLanguages: false, preferredLanguages: ["fr"]))
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<20_000 {
      if condition() { return }
      await Task.yield()
    }
    Issue.record("The refresh-gate fixture did not reach its expected state")
  }
}
