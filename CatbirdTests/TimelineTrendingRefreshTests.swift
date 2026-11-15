import Foundation
import Petrel
import Testing
import UIKit
@testable import Catbird

/// The timeline interstitial's use of the per-account trend lists shared with Search.
@Suite("Timeline trending refresh", .serialized)
@MainActor
struct TimelineTrendingRefreshTests {
  private let accountDID = "did:plc:timelinetrendingrefresh"
  private let suspendedAccountDID = "did:plc:timelinetrendingsuspend"

  @Test("An account admits trend requests until it is suspended or retired")
  func accountSuspensionClosesTrendRequests() async throws {
    let appState = try await makeAppState(did: suspendedAccountDID)
    #expect(appState.trendingTopicMediaStore.lists.admitsRequests())

    appState.cleanup()

    #expect(!appState.trendingTopicMediaStore.lists.admitsRequests(),
      "A retired or switching account's client may already carry another account's credentials")
  }

  @Test("Pull to refresh asks for new trends even when Search fetched some minutes ago")
  func pullToRefreshSkipsTheFreshList() async throws {
    TrendingTopicsDiskCache.remove(accountDID: accountDID)
    let appState = try await makeAppState(did: accountDID)
    let settings = appState.appSettings
    let previous = (settings.showTrendingTopics, settings.showTrendingVideos)
    settings.showTrendingTopics = true
    settings.showTrendingVideos = false
    let model = FeedModel(feedManager: FeedManager(client: nil, fetchType: .timeline), appState: appState)
    let manager = FeedStateManager(appState: appState, feedModel: model, feedType: .timeline)
    defer {
      manager.cleanup()
      appState.cancelTopicPreviewPrefetch(owner: .timeline)
      settings.showTrendingTopics = previous.0
      settings.showTrendingVideos = previous.1
      appState.cleanup()
      TrendingTopicsDiskCache.remove(accountDID: accountDID)
    }
    try #require(settings.showTrendingTopics)

    // Search fetched this list a moment ago.
    let store = appState.trendingTopicMediaStore
    let fromSearch = makeTrend("from-search")
    _ = try await store.fetchOrCoalesceTrends(for: accountDID) { [fromSearch] }
    try #require(store.cachedTrends(for: accountDID)?.isFresh == true)
    // A test sends no request: a refused one stands in for it and answers with an empty list,
    // so an empty interstitial below proves the load went past the fresh list to the network.
    store.lists.admitsRequests = { false }

    let requestID = "\(accountDID)|timeline|true|false"
    await manager.loadTrendingIfNeeded(requestID: requestID, displayScale: 3)
    #expect(manager.trendingContent(for: requestID).trends == [fromSearch],
      "The first appear reuses the list Search fetched instead of requesting it again")

    await manager.loadTrendingIfNeeded(requestID: requestID, displayScale: 3)
    #expect(manager.trendingContent(for: requestID).trends == [fromSearch], "A reappear keeps the set on screen")

    await manager.loadTrendingIfNeeded(requestID: requestID, displayScale: 3, force: true)
    #expect(manager.trendingContent(for: requestID).trends.isEmpty,
      "Pull to refresh must request new trends, not return the fresh cached list")
  }

  // MARK: Helpers

  private func makeAppState(did: String) async throws -> AppState {
    let client = await ATProtoClient(baseURL: try #require(URL(string: "https://timeline-trending-refresh.invalid")))
    return AppState(userDID: did, client: client, regulatoryChecker: TrendingRefreshAgeChecker())
  }

  private func makeTrend(_ topic: String) -> AppBskyUnspeccedDefs.TrendView {
    .init(
      topic: topic, displayName: topic.capitalized, description: nil,
      link: "/profile/trending.example.invalid/feed/\(topic)",
      startedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_761_000_000)),
      postCount: 1200, status: "hot", category: "science", actors: [])
  }
}

private struct TrendingRefreshAgeChecker: AgeRegulatoryChecking {
  func preflight() async -> PlatformAgeSignal {
    .init(requirement: .none, ageBand: nil, significantChangeConsentRequired: false)
  }

  @MainActor
  func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
}
