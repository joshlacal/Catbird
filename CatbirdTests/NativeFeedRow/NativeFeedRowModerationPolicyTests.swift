#if os(iOS)
import Foundation
import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird

/// A moderation policy change only re-filters the feed's posts (`FeedModel`); a post that stays
/// in the feed but gains or loses a label must move between its native cell and the hosted row.
@Suite("Native feed rows follow the moderation policy", .serialized)
@MainActor
struct NativeFeedRowModerationPolicyTests {
  private typealias Fixtures = ModerationStateFixtures

  @Test("A policy change moves a post between the native cell and the hosted row")
  func policyChangeReclassifiesVisibleRows() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let account = try await harness.makeAccount(did: Fixtures.uniqueDID("nativerowpolicy"))
    let appState = account.appState
    let labeler = Fixtures.customLabelerDID
    account.server.publishLabeler(did: labeler)
    // Not subscribed to the labeler: its content-blurring label is ignored.
    try await Self.serverSubscribes(to: [], account: account)

    let post = try Self.cachedPost(labeledBy: labeler)
    let before = Self.classification(of: post, appState: appState)
    #expect(before == .native, "\(before)")

    let host = try FeedControllerHost(appState: appState, posts: [post])
    defer { host.tearDown() }
    await host.controller.performUpdate()
    try await host.waitForPostCell(NativeFeedPostCell.self)

    // Subscribing makes the label blur the post's content: the row must be the hosted one.
    try await Self.serverSubscribes(to: [labeler], account: account)
    let subscribed = Self.classification(of: post, appState: appState)
    #expect(subscribed == .hosted(.moderation), "\(subscribed)")
    try await host.waitForPostCell(FeedPostCollectionViewCell.self)

    // And back to the native cell once the label no longer applies.
    try await Self.serverSubscribes(to: [], account: account)
    let unsubscribed = Self.classification(of: post, appState: appState)
    #expect(unsubscribed == .native, "\(unsubscribed)")
    try await host.waitForPostCell(NativeFeedPostCell.self)
  }

  // MARK: - Helpers

  /// The server changes the account's labeler subscriptions and the app fetches them, as the
  /// preferences poll does. A forced fetch within a few seconds of the last one reuses that read
  /// unless the preference session changed, so the fetch starts a new session with the same client.
  private static func serverSubscribes(to labelers: [String], account: ModerationStateAccount) async throws {
    account.server.setPreferences(adultContentEnabled: false, labelerDIDs: labelers)
    account.appState.preferencesManager.updateClient(account.client)
    try await account.appState.preferencesManager.fetchPreferences(forceRefresh: true)
    await account.appState.awaitModerationDefinitionsLoad()
  }

  private static func cachedPost(labeledBy labeler: String) throws -> CachedFeedViewPost {
    let json = ["post": ModerationStatePosts.json(labeled: Fixtures.customLabelValue, source: labeler, slug: "nativerow")]
    let item = try JSONDecoder().decode(
      AppBskyFeedDefs.FeedViewPost.self, from: JSONSerialization.data(withJSONObject: json))
    return try #require(CachedFeedViewPost(from: item, feedType: "timeline"))
  }

  private static func classification(of post: CachedFeedViewPost, appState: AppState) -> NativeFeedRowSupport {
    guard let item = try? post.feedViewPost else { return .hosted(.decodeFailed) }
    let moderation = PostModerationPresentation.make(
      post: item.post, policy: appState.moderationPolicy, surface: .contentList, listFilterExemptDID: nil)
    let settings = NativeFeedRowSupport.Settings(
      isEnabled: true, deviceLanguageCode: Locale.current.language.baseLanguageCode?.lowercased() ?? "en",
      preferredContentLanguages: Set(appState.appSettings.contentLanguages),
      showLanguageIndicators: appState.appSettings.showLanguageIndicators,
      showReadingTimeEstimates: appState.appSettings.showReadingTimeEstimates)
    return NativeFeedRowSupport.classify(post, moderation: moderation, settings: settings)
  }
}

// MARK: - Feed Controller Host

/// The production feed controller showing `posts` in a window, as `FeedHeaderEnvironmentTests` hosts it.
@MainActor
private final class FeedControllerHost {
  let controller: FeedCollectionViewControllerIntegrated
  private let window: UIWindow
  private let state: FeedStateManager
  private let sceneContext: SceneNavigationContext
  private let previousKeyWindow: UIWindow?

  init(appState: AppState, posts: [CachedFeedViewPost]) throws {
    sceneContext = SceneNavigationContext(appState: appState, sceneID: UUID())
    let viewport = sceneContext.feedViewportStore.state(
      accountDID: appState.userDID, feedIdentifier: FetchType.timeline.identifier)
    let model = FeedModel(feedManager: FeedManager(client: nil, fetchType: .timeline), appState: appState)
    model.posts = posts
    state = FeedStateManager(appState: appState, feedModel: model, feedType: .timeline, initialScenePhase: .background)
    state.hasReachedEnd = true
    controller = FeedCollectionViewControllerIntegrated(
      stateManager: state, viewportState: viewport, sceneContext: sceneContext,
      navigationPath: .constant(NavigationPath()))
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
    window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
    window.rootViewController = controller
    controller.loadViewIfNeeded()
    controller.collectionView.isPrefetchingEnabled = false
    window.isHidden = false
  }

  func tearDown() {
    let becameKey = window.isKeyWindow
    window.isHidden = true
    window.rootViewController = nil
    state.cleanup()
    sceneContext.invalidate()
    if becameKey { previousKeyWindow?.makeKey() }
  }

  /// Waits until the feed's only post is on screen in a cell of type `Cell`.
  func waitForPostCell<Cell: UICollectionViewCell>(_ type: Cell.Type) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    var current: UICollectionViewCell?
    while ContinuousClock.now < deadline {
      window.layoutIfNeeded()
      controller.collectionView.layoutIfNeeded()
      current = controller.collectionView.cellForItem(at: IndexPath(item: 0, section: 0))
      if current is Cell { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("The post's cell is \(current.map { String(describing: Swift.type(of: $0)) } ?? "missing"), not \(Cell.self)")
  }
}
#endif
