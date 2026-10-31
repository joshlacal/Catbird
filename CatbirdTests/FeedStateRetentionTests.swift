#if os(iOS)
import Foundation
import Petrel
import Testing
import UIKit
@testable import Catbird

/// FeedStateStore keeps at most four feed managers, skipping attached ones.
/// Views used to attach on several appear paths but detach once, so counts only
/// grew; once every older feed looked attached, a newly created manager was the
/// only eviction candidate and was cleaned up before its view could use it.
@Suite("Feed state retention", .serialized)
@MainActor
struct FeedStateRetentionTests {
  @Test("A lease attaches once per key and detaches when moved or released")
  func leasePairsAttachAndDetach() {
    let store = FeedStateStore.shared
    let first = "lease-test-\(UUID().uuidString)"
    let second = "lease-test-\(UUID().uuidString)"
    let lease = FeedStateLease(store: store)

    lease.hold(cacheKey: first)
    lease.hold(cacheKey: first)
    #expect(store.isAttached(cacheKey: first))

    lease.hold(cacheKey: second)
    #expect(!store.isAttached(cacheKey: first), "Moving the lease must detach the old feed")
    #expect(store.isAttached(cacheKey: second))

    lease.release()
    #expect(!store.isAttached(cacheKey: second), "One release must undo repeated holds")
  }

  @Test("Creating a feed never evicts the manager it just created")
  func newManagerSurvivesRetention() async {
    let store = FeedStateStore.shared
    let client = await ATProtoClient(baseURL: URL(string: "https://feed-state-retention.invalid")!)
    let appState = AppState(userDID: "did:plc:feedstateretention", client: client,
      regulatoryChecker: NoAgePrompt())
    let feeds = (0..<5).map { FetchType.author("did:plc:retentionfeed\($0)") }
    var leases: [FeedStateLease] = []
    defer {
      leases.forEach { $0.release() }
      feeds.forEach { store.clearStateManager(for: $0.identifier) }
      appState.cleanup()
    }

    var managers: [FeedStateManager] = []
    for feed in feeds {
      let manager = store.stateManager(for: feed, appState: appState)
      let lease = FeedStateLease(store: store)
      lease.hold(manager)
      leases.append(lease)
      managers.append(manager)
    }

    #expect(managers.allSatisfy { !$0.isCleanedUp }, "Every feed on screen must keep its manager")
    #expect(store.stateManager(for: feeds[4], appState: appState) === managers[4])
  }

  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal { .none }
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }
}
#endif
