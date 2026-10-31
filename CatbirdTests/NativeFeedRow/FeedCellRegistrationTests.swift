#if os(iOS)
import Foundation
import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird

/// The feed's header and trending interstitial come from reuse-identifier registrations, which do
/// not bridge an item to Objective-C on dequeue the way a `CellRegistration` does.
@MainActor
@Suite("Feed cell registrations", .serialized)
struct FeedCellRegistrationTests {
  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal { .none }
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }

  @Test("The header and the trending interstitial are dequeued by reuse identifier")
  func headerAndTrendingUseReuseIdentifiers() async throws {
    let client = await ATProtoClient(baseURL: try #require(URL(string: "https://feed-cell-registration.invalid")))
    let appState = AppState(
      userDID: "did:plc:feedcellregistration", client: client, regulatoryChecker: NoAgePrompt())
    defer { appState.cleanup() }
    appState.appSettings.showTrendingTopics = true
    let posts = try (0..<12).map { try FeedRowTestPosts.cachedPost(text: "Post \($0)", postKey: "registration\($0)") }
    let host = try NativeFeedRowControllerHost(appState: appState, posts: posts)
    defer { host.tearDown() }
    host.controller.setHeaderView(AnyView(Text("Feed header").frame(maxWidth: .infinity, minHeight: 44)))
    let topic = AppBskyUnspeccedDefs.TrendView(
      topic: "registration", displayName: "Registration Trend", description: "Fixture",
      link: "/search?q=registration", startedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 0)),
      postCount: 42, status: "hot", category: "technology", actors: [])
    host.controller.setTrendingContent(TrendingFeedContent(trends: [topic]))
    await host.controller.performUpdate()

    let collectionView = host.controller.collectionView!
    // The header is the first item and the interstitial follows the sixth post.
    let headerPath = IndexPath(item: 0, section: 0)
    let trendingPath = IndexPath(item: 7, section: 0)
    let header = try #require(try await cell(at: headerPath, in: host, as: UICollectionViewListCell.self))
    #expect(header.reuseIdentifier == FeedCollectionViewControllerIntegrated.headerReuseIdentifier)
    #expect(header.contentConfiguration != nil)

    collectionView.scrollToItem(at: trendingPath, at: .top, animated: false)
    let trending = try #require(try await cell(at: trendingPath, in: host, as: TrendingInterstitialCell.self))
    #expect(trending.reuseIdentifier == TrendingInterstitialCell.reuseIdentifier)
  }

  private func cell<Cell: UICollectionViewCell>(
    at indexPath: IndexPath, in host: NativeFeedRowControllerHost, as type: Cell.Type
  ) async throws -> Cell? {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      host.window.layoutIfNeeded()
      host.controller.collectionView.layoutIfNeeded()
      if let cell = host.controller.collectionView.cellForItem(at: indexPath) as? Cell { return cell }
      try await Task.sleep(for: .milliseconds(20))
    }
    return nil
  }
}
#endif
