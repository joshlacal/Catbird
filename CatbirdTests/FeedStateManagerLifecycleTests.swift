#if os(iOS)
import Foundation
import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird

@Suite("Feed manager scene lifecycle")
@MainActor
struct FeedStateManagerLifecycleTests {
  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal { .none }
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }

  @Test("Scene transitions preserve an initial load owned by its caller")
  func initialLoadSurvivesSceneTransitions() async throws {
    let client = await ATProtoClient(baseURL: URL(string: "https://feed-lifecycle.invalid")!)
    let appState = AppState(userDID: "did:plc:feedlifecyclefixture", client: client,
      regulatoryChecker: NoAgePrompt())
    let model = FeedModel(feedManager: FeedManager(client: nil, fetchType: .timeline), appState: appState)
    let manager = FeedStateManager(appState: appState, feedModel: model, feedType: .timeline)
    defer {
      manager.cleanup()
      appState.cleanup()
    }

    // The real account-availability retry holds the caller's initial load open.
    // No session exists and the model has no transport, so no feed request runs.
    let loading = Task { await manager.loadInitialData() }
    do {
      let deadline = ContinuousClock.now + .seconds(1)
      while !manager.isLoading && ContinuousClock.now < deadline { await Task.yield() }
      try #require(manager.loadingState == .loading)
      let hasSession = await client.hasValidSession()
      #expect(!hasSession)

      let inactiveResumed = await manager.handleScenePhaseTransition(.inactive)
      #expect(!inactiveResumed)
      #expect(manager.loadingState == .loading)
      let interruptionResumed = await manager.handleScenePhaseTransition(.active)
      #expect(!interruptionResumed)
      #expect(manager.loadingState == .loading)

      let backgroundResumed = await manager.handleScenePhaseTransition(.background)
      #expect(!backgroundResumed)
      #expect(manager.loadingState == .loading)
      #expect(!loading.isCancelled)
      let actualResumed = await manager.handleScenePhaseTransition(.active)
      #expect(actualResumed)
      #expect(manager.loadingState == .loading)
      let repeatedResumed = await manager.handleScenePhaseTransition(.active)
      #expect(!repeatedResumed)
      #expect(manager.loadingState == .loading)
      #expect(!loading.isCancelled)
    } catch {
      loading.cancel()
      await loading.value
      throw error
    }
    loading.cancel()
    await loading.value
  }
}
#endif
