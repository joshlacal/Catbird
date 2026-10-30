#if os(iOS)
import Foundation
import Petrel
import Testing
import UIKit
@testable import Catbird

@Suite("Feed initial response state", .serialized)
@MainActor
struct FeedInitialResponseTests {
  @Test("Empty cache restoration cannot establish a successful response")
  func emptyCacheIsUnresolved() async {
    let (appState, model) = await makeModel()
    defer { appState.cleanup() }
    #expect(!model.hasLoadedInitialResponse)
    await model.restorePersistedPosts([], cursor: nil)
    #expect(!model.hasLoadedInitialResponse)
    await model.setCachedFeed([], cursor: nil)
    #expect(!model.hasLoadedInitialResponse)
  }

  @Test("A failed initial request is not a successful empty feed")
  func failedInitialRequest() async {
    let (appState, model) = await makeModel()
    defer { appState.cleanup() }
    await model.loadFeed(fetch: .timeline)
    #expect(model.error != nil)
    #expect(!model.hasLoadedInitialResponse)
    #expect(!model.isLoading)
  }

  @Test("Canceling initial preparation cannot publish success or error")
  func cancelledInitialPreparation() async {
    let gate = PreparationGate()
    let (appState, model) = await makeModel(gate: gate)
    defer { appState.cleanup() }
    appState.prewarmingFeedData = []
    let loading = Task { await model.loadFeed(fetch: .timeline) }
    await gate.waitUntilStarted()
    #expect(model.isLoading)
    #expect(!model.hasLoadedInitialResponse)
    loading.cancel()
    await gate.release()
    await loading.value
    #expect(!model.hasLoadedInitialResponse)
    #expect(model.error == nil)
    #expect(!model.isLoading)
  }

  @Test("A prewarmed response is account and feed scoped, while supplement failures remain errors")
  func responseScopeAndSupplementFailure() async {
    let (appState, model) = await makeModel()
    defer { appState.cleanup() }
    appState.prewarmingFeedData = []
    await model.loadFeed(fetch: .timeline)
    #expect(model.hasLoadedInitialResponse)
    #expect(model.error != nil)
    await model.handleStateInvalidation(.accountSwitched)
    #expect(!model.hasLoadedInitialResponse)
    appState.prewarmingFeedData = []
    await model.loadFeed(fetch: .timeline)
    #expect(model.hasLoadedInitialResponse)
    await model.loadFeed(fetch: .author("did:plc:otherfeed"))
    #expect(!model.hasLoadedInitialResponse)
  }

  @Test("An empty first page exposes transient failures", arguments: [URLError.Code.timedOut, .networkConnectionLost])
  func transientInitialFailure(code: URLError.Code) async {
    let (appState, model) = await makeModel(preparationFailure: code)
    defer { appState.cleanup() }
    appState.prewarmingFeedData = []
    await model.loadFeed(fetch: .timeline)
    #expect((model.error as? URLError)?.code == code)
    #expect(!model.hasLoadedInitialResponse)
    #expect(!model.isLoading)
  }

  @Test("A canceled first page does not publish a user-facing error")
  func cancelledInitialError() async {
    let (appState, model) = await makeModel(preparationFailure: .cancelled)
    defer { appState.cleanup() }
    appState.prewarmingFeedData = []
    await model.loadFeed(fetch: .timeline)
    #expect(model.error == nil)
    #expect(!model.hasLoadedInitialResponse)
    #expect(!model.isLoading)
  }

  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal { .none }
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }

  private func makeModel(gate: PreparationGate? = nil,
    preparationFailure: URLError.Code? = nil) async -> (AppState, FeedModel) {
    let client = await ATProtoClient(baseURL: URL(string: "https://feed-initial-response.invalid")!)
    let appState = AppState(userDID: "did:plc:feedinitialresponse", client: client,
      regulatoryChecker: NoAgePrompt())
    let model = FeedModel(feedManager: FeedManager(client: nil, fetchType: .timeline),
      appState: appState, prepareSlices: { slices in
        if let gate { await gate.hold() }
        if let preparationFailure { throw URLError(preparationFailure) }
        return try await PreparedFeedSlice.prepare(slices)
      })
    return (appState, model)
  }

  private actor PreparationGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func hold() async {
      started = true
      startWaiter?.resume()
      startWaiter = nil
      await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilStarted() async {
      if started { return }
      await withCheckedContinuation { startWaiter = $0 }
    }

    func release() {
      releaseWaiter?.resume()
      releaseWaiter = nil
    }
  }
}
#endif
