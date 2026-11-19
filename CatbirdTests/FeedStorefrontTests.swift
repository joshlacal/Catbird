import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("App Store Feed Discovery Storefront & Product Page")
@MainActor
struct FeedStorefrontTests {
  // MARK: - Category Classifier

  @Test func categoryClassifierMatchesWordBoundariesAndAvoidsFalsePositives() {
    #expect(FeedDiscoveryCategoryClassifier.primaryCategory(
      displayName: "Earth & Planetary Photos",
      description: "Views from orbit and geology notes"
    ) == .science)

    #expect(FeedDiscoveryCategoryClassifier.primaryCategory(
      displayName: "Party Vibes",
      description: "Weekend hangout posts"
    ) == nil)

    #expect(FeedDiscoveryCategoryClassifier.primaryCategory(
      displayName: "SwiftUI & Rust Builders",
      description: "Shipping native iOS and systems code"
    ) == .dev)

    #expect(FeedDiscoveryCategoryClassifier.primaryCategory(
      displayName: "Digital Art & Illustration",
      description: "Sketches, watercolor, and comics"
    ) == .art)

    #expect(FeedDiscoveryCategoryClassifier.primaryCategory(
      displayName: "Breaking World News",
      description: "Journalists and live dispatches"
    ) == .news)

    #expect(FeedDiscoveryCategoryClassifier.primaryCategory(
      displayName: "Formula 1 & NBA Highlights",
      description: "Race weekend and playoff threads"
    ) == .sports)

    #expect(FeedDiscoveryCategoryClassifier.primaryCategory(
      displayName: "Indie Games Radar",
      description: "Steam Next Fest demos and tabletop RPGs"
    ) == .games)

    #expect(FeedDiscoveryCategoryClassifier.primaryCategory(
      displayName: "BookSky Reading Club",
      description: "Sci-fi novels and literature"
    ) == .books)
  }

  // MARK: - Velocity Estimator

  @Test func velocityEstimatorClassifiesFirehoseHourlyDailyWeeklyStaleAndEmpty() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    #expect(FeedVelocityEstimator.estimate(from: [Date](), now: now) == .empty)

    // 5 posts in 2 minutes -> 150/hr -> 100+/hr Firehose
    let firehose = (0..<5).map { now.addingTimeInterval(-Double($0 * 30)) }
    #expect(FeedVelocityEstimator.estimate(from: firehose, now: now).shortLabel == "100+/hr")

    // 5 posts in 7.5 minutes (450s) -> 40/hr
    let hourly = [0, 90, 180, 300, 450].map { now.addingTimeInterval(-Double($0)) }
    #expect(FeedVelocityEstimator.estimate(from: hourly, now: now).shortLabel == "~40/hr")

    // 5 posts over 15 hours -> ~8/day
    let daily = [1, 4, 8, 12, 15].map { now.addingTimeInterval(-Double($0) * 3_600) }
    #expect(FeedVelocityEstimator.estimate(from: daily, now: now).shortLabel == "~8/day")

    // 5 posts over 12 days -> ~3/wk
    let weekly = [1, 3, 6, 9, 12].map { now.addingTimeInterval(-Double($0) * 86_400) }
    #expect(FeedVelocityEstimator.estimate(from: weekly, now: now).shortLabel == "~3/wk")

    // Burst-then-dead immunity: 5 posts within 5 minutes, but 5 days ago -> ~1/day (NOT 60/hr!)
    let burstFiveDaysAgo = (0..<5).map { now.addingTimeInterval(-(5 * 86_400 + Double($0 * 60))) }
    #expect(FeedVelocityEstimator.estimate(from: burstFiveDaysAgo, now: now).shortLabel == "~1/day")

    // Stale (>14 days) -> Quiet
    let stale = [20, 21, 22].map { now.addingTimeInterval(-Double($0) * 86_400) }
    #expect(FeedVelocityEstimator.estimate(from: stale, now: now) == .quiet)
  }

  // MARK: - Follow-Liked Ranking & Social Proof Copy

  @Test func followLikedSocialProofFormattingAndRanking() throws {
    let alphaFeed = try makeFeed("alpha", displayName: "Alpha", likes: 500)
    let betaFeed = try makeFeed("beta", displayName: "Beta", likes: 5000)
    let gammaFeed = try makeFeed("gamma", displayName: "Gamma", likes: 100)

    let single = FollowLikedFeed(feed: alphaFeed, likedByHandles: ["alice.bsky.social"], isPersonalizedSuggestion: false)
    #expect(single.socialProofSubtitle == "Liked by @alice.bsky.social")

    let pair = FollowLikedFeed(feed: betaFeed, likedByHandles: ["alice.bsky.social", "bob.bsky.social"], isPersonalizedSuggestion: false)
    #expect(pair.socialProofSubtitle == "Liked by @alice.bsky.social & @bob.bsky.social")

    let many = FollowLikedFeed(feed: gammaFeed, likedByHandles: ["a.test", "b.test", "c.test", "d.test"], isPersonalizedSuggestion: false)
    #expect(many.socialProofSubtitle == "Liked by @a.test & 3 others")

    let ranked = FeedDiscoveryProvider.rankFollowLikedFeeds(
      matches: [single, many],
      suggestedFallback: [alphaFeed, betaFeed]
    )
    // Follow-liked matches lead sorted by follow-liker count descending; deduplicated suggestions trail.
    #expect(ranked.map(\.feed.displayName) == ["Gamma", "Alpha", "Beta"])
    #expect(ranked.last?.socialProofSubtitle == "Suggested for you")
  }

  // MARK: - Storefront ViewModel & 3-Row Column Chunking

  @Test func chunkIntoThreeRowColumnsMatchesAppStoreLayout() {
    #expect(FeedStorefrontViewModel.chunkIntoColumns([Int](), rowsPerColumn: 3).isEmpty)
    #expect(FeedStorefrontViewModel.chunkIntoColumns([1], rowsPerColumn: 3) == [[1]])
    #expect(FeedStorefrontViewModel.chunkIntoColumns([1, 2, 3], rowsPerColumn: 3) == [[1, 2, 3]])
    #expect(FeedStorefrontViewModel.chunkIntoColumns([1, 2, 3, 4, 5, 6, 7], rowsPerColumn: 3) == [[1, 2, 3], [4, 5, 6], [7]])
  }

  @Test func storefrontLoadsShelvesBucketsCategoriesAndRejectsStaleAccountResponses() async throws {
    let provider = MockStorefrontProvider()
    let science = try makeFeed("science", displayName: "Science", description: "Astronomy and biology research", likes: 2000)
    let dev = try makeFeed("swift", displayName: "SwiftUI Dev", description: "iOS programming and software", likes: 1500)
    let art = try makeFeed("art", displayName: "Illustration", description: "Drawing and digital art", likes: 1800)
    let catbird = try makeFeed("discover", displayName: "Catbird Discover", description: "First-party feed", likes: 900)
    let extraScience = try makeFeed("nasa", displayName: "Space & NASA", description: "Astronomy missions", likes: 1100)

    provider.popularPage = FeedDiscoveryPage(feeds: [science, dev, art], cursor: "next")
    provider.catbird = [catbird]
    provider.followLiked = [FollowLikedFeed(feed: dev, likedByHandles: ["alice.test"], isPersonalizedSuggestion: false)]
    provider.categoryPages[.science] = FeedDiscoveryPage(feeds: [science, extraScience], cursor: nil)

    let viewModel = FeedStorefrontViewModel(provider: provider, accountDID: "did:plc:acct1")
    viewModel.load()
    await settle()

    #expect(viewModel.popularFeeds.map(\.displayName) == ["Science", "SwiftUI Dev", "Illustration"])
    #expect(viewModel.catbirdFeeds.map(\.displayName) == ["Catbird Discover"])
    #expect(viewModel.hasDirectFollowLikes)
    #expect(viewModel.followLikedShelfTitle == "Liked by People You Follow")
    #expect(viewModel.categoryBuckets[.science]?.map(\.displayName) == ["Science"])
    #expect(viewModel.categoryBuckets[.dev]?.map(\.displayName) == ["SwiftUI Dev"])
    #expect(viewModel.categoryBuckets[.art]?.map(\.displayName) == ["Illustration"])

    viewModel.loadCategoryIfNeeded(.science)
    await settle()
    #expect(viewModel.feeds(for: .science).map(\.displayName) == ["Science", "Space & NASA"])

    // Switching accounts clears previous account shelves cleanly.
    let secondProvider = MockStorefrontProvider()
    secondProvider.popularPage = FeedDiscoveryPage(feeds: [art], cursor: nil)
    viewModel.updateAccount(provider: secondProvider, accountDID: "did:plc:acct2")
    await settle()
    #expect(viewModel.accountDID == "did:plc:acct2")
    #expect(viewModel.popularFeeds.map(\.displayName) == ["Illustration"])
    #expect(viewModel.followLikedShelfTitle == "Suggested for You")
  }

  private func settle() async {
    for _ in 0..<25 { await Task.yield() }
  }

  private func makeFeed(
    _ rkey: String,
    displayName: String,
    description: String = "",
    likes: Int = 100
  ) throws -> AppBskyFeedDefs.GeneratorView {
    try JSONDecoder().decode(AppBskyFeedDefs.GeneratorView.self, from: Data("""
      {"uri":"at://did:plc:creator1234567890123456/app.bsky.feed.generator/\(rkey)",
       "cid":"bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku",
       "did":"did:plc:feedservice1234567890",
       "creator":{"did":"did:plc:creator1234567890123456","handle":"creator.test"},
       "displayName":"\(displayName)","description":"\(description)","likeCount":\(likes),
       "indexedAt":"2026-11-18T12:00:00Z"}
      """.utf8))
  }
}

@MainActor
private final class MockStorefrontProvider: FeedStorefrontProviding {
  var popularPage = FeedDiscoveryPage(feeds: [], cursor: nil)
  var catbird: [AppBskyFeedDefs.GeneratorView] = []
  var followLiked: [FollowLikedFeed] = []
  var categoryPages: [FeedDiscoveryCategory: FeedDiscoveryPage] = [:]

  func fetchPopularFeeds(cursor: String?, limit: Int) async throws -> FeedDiscoveryPage {
    popularPage
  }

  func fetchCatbirdFeeds() async -> [AppBskyFeedDefs.GeneratorView] {
    catbird
  }

  func fetchFollowLikedFeeds(candidates: [AppBskyFeedDefs.GeneratorView]) async -> [FollowLikedFeed] {
    followLiked
  }

  func fetchCategoryFeeds(category: FeedDiscoveryCategory, cursor: String?) async throws -> FeedDiscoveryPage {
    categoryPages[category] ?? FeedDiscoveryPage(feeds: [], cursor: nil)
  }
}
