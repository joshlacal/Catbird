#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird

@MainActor
@Suite("Feed refresh completion", .serialized)
struct FeedRefreshCompletionTests {
  @Test("A snapshot update keeps the pull indicator active until refresh failure completes")
  func pendingRefreshSurvivesSnapshotUpdate() async throws {
    let fixture = try await Fixture()
    defer { fixture.close() }
    let originalIDs = fixture.state.posts.map(\.id)
    let control = try await fixture.startRefresh()

    // This is the same snapshot path reached by loading-state, footer and post
    // observations; it must not complete the pull operation that requested it.
    await fixture.controller.performUpdate()
    #expect(control.isRefreshing,
      "An intermediate snapshot must not finish the refresh control's operation")
    #expect(fixture.refreshIsOwned == true)
    #expect(fixture.state.posts.map(\.id) == originalIDs)
    #expect(fixture.controller.collectionView.numberOfItems(inSection: 0) == originalIDs.count + 1)

    try await Self.waitUntil { !control.isRefreshing }
    #expect(fixture.refreshIsOwned == false)
    #expect(fixture.state.feedLoadError != nil)
    #expect(fixture.state.posts.map(\.id) == originalIDs)
    try fixture.recordRenderedContent(named: "feed-refresh-failure-preserves-content")
  }

  @Test("A skipped refresh ends the pull indicator and preserves existing rows")
  func skippedRefreshFinishes() async throws {
    let fixture = try await Fixture(initialScenePhase: .background)
    defer { fixture.close() }
    let originalIDs = fixture.state.posts.map(\.id)
    let control = try #require(fixture.controller.collectionView.refreshControl)

    control.beginRefreshing()
    control.sendActions(for: .valueChanged)
    try await Self.waitUntil { !control.isRefreshing }

    #expect(fixture.refreshIsOwned == false)
    #expect(fixture.state.loadingState == .idle)
    #expect(fixture.state.posts.map(\.id) == originalIDs)
    #expect(fixture.controller.collectionView.numberOfItems(inSection: 0) == originalIDs.count + 1)
  }

  @Test("Replacing the manager invalidates a refresh before its queued task starts")
  func replacementInvalidatesRefreshBeforeDispatch() async throws {
    let fixture = try await Fixture()
    defer { fixture.close() }
    let replacement = try fixture.makeState(prefix: "replacement", count: 2, scenePhase: .background)
    defer { replacement.cleanup() }
    let replacementIDs = replacement.posts.map(\.id)
    let originalIDs = fixture.state.posts.map(\.id)
    let control = try #require(fixture.controller.collectionView.refreshControl)

    // Keep dispatch and replacement in the same main-actor turn. The target
    // reserves ownership synchronously, but its asynchronous work cannot start.
    control.beginRefreshing()
    control.sendActions(for: .valueChanged)
    #expect(fixture.refreshIsOwned == true)
    fixture.controller.updateStateManager(replacement, viewportState: FeedViewportState())
    #expect(!control.isRefreshing, "A feed replacement must release the old pull indicator immediately")
    #expect(fixture.refreshIsOwned == false)
    await fixture.controller.performUpdate()

    #expect(fixture.controller.stateManager === replacement)
    #expect(fixture.state.loadingState == .idle)
    #expect(fixture.state.posts.map(\.id) == originalIDs)
    #expect(replacement.loadingState == .idle)
    #expect(replacement.posts.map(\.id) == replacementIDs)
    #expect(fixture.controller.collectionView.numberOfItems(inSection: 0) == replacementIDs.count + 1)
    #expect(!control.isRefreshing)
    #expect(fixture.refreshIsOwned == false)
    try fixture.recordRenderedContent(named: "feed-refresh-replacement-content")
  }

  private static func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(predicate(), "The expected refresh lifecycle boundary did not complete")
  }

  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal { .none }
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }

  @MainActor
  private final class Fixture {
    let appState: AppState
    let sceneContext: SceneNavigationContext
    let state: FeedStateManager
    let controller: FeedCollectionViewControllerIntegrated
    let window: UIWindow
    private weak var previousKeyWindow: UIWindow?

    init(initialScenePhase: ScenePhase = .active) async throws {
      let client = await ATProtoClient(baseURL: URL(string: "https://feed-refresh-completion.invalid")!)
      appState = AppState(userDID: "did:plc:feedrefreshfixture", client: client,
        regulatoryChecker: NoAgePrompt())
      sceneContext = SceneNavigationContext(appState: appState, sceneID: UUID())
      let model = FeedModel(feedManager: FeedManager(client: nil, fetchType: .timeline), appState: appState)
      model.posts = try Self.makePosts(prefix: "original", count: 1)
      state = FeedStateManager(appState: appState, feedModel: model, feedType: .timeline,
        initialScenePhase: initialScenePhase)
      state.hasReachedEnd = true
      controller = FeedCollectionViewControllerIntegrated(stateManager: state,
        viewportState: FeedViewportState(), sceneContext: sceneContext,
        navigationPath: .constant(NavigationPath()))
      let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
      window = UIWindow(windowScene: scene)
      window.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
      window.backgroundColor = .systemBackground
      window.rootViewController = controller
      controller.loadViewIfNeeded()
      controller.collectionView.isPrefetchingEnabled = false
      window.isHidden = false
      await controller.performUpdate()
      window.layoutIfNeeded()
      controller.collectionView.layoutIfNeeded()
      let hasSession = await client.hasValidSession()
      #expect(!hasSession, "The fixture must never use an authenticated session")
    }

    // Reflection is local to the test so production does not expose its private
    // operation ownership merely to wait for the target/action task to enter.
    var refreshIsOwned: Bool? {
      Mirror(reflecting: controller).children.first { $0.label == "isRefreshing" }?.value as? Bool
    }

    func startRefresh() async throws -> UIRefreshControl {
      _ = try #require(refreshIsOwned, "The controller's private refresh ownership must be observable by this fixture")
      let control = try #require(controller.collectionView.refreshControl)
      control.beginRefreshing()
      control.sendActions(for: .valueChanged)
      try await FeedRefreshCompletionTests.waitUntil { self.refreshIsOwned == true }
      return control
    }

    func makeState(prefix: String, count: Int, scenePhase: ScenePhase) throws -> FeedStateManager {
      let model = FeedModel(feedManager: FeedManager(client: nil, fetchType: .timeline), appState: appState)
      model.posts = try Self.makePosts(prefix: prefix, count: count)
      let manager = FeedStateManager(appState: appState, feedModel: model, feedType: .timeline,
        initialScenePhase: scenePhase)
      manager.hasReachedEnd = true
      return manager
    }

    func recordRenderedContent(named name: String) throws {
      window.layoutIfNeeded()
      controller.view.layoutIfNeeded()
      controller.collectionView.layoutIfNeeded()
      let cell = try #require(controller.collectionView.cellForItem(at: IndexPath(item: 0, section: 0)))
      #expect(cell.window === window)
      // A post row is a native cell showing its post, or hosted SwiftUI content.
      #expect(cell.contentConfiguration != nil || (cell as? NativeFeedPostCell)?.postURI != nil)
      #expect(cell.bounds.width > 0 && cell.bounds.height > 0)
      let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
      var drewHierarchy = false
      let image = renderer.image { _ in
        drewHierarchy = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      #expect(drewHierarchy)
      Attachment.record(Array(try #require(image.pngData())), named: "\(name).png")
    }

    func close() {
      let becameKey = window.isKeyWindow
      window.isHidden = true
      window.rootViewController = nil
      state.cleanup()
      sceneContext.invalidate()
      appState.cleanup()
      if becameKey { previousKeyWindow?.makeKey() }
    }

    private static func makePosts(prefix: String, count: Int) throws -> [CachedFeedViewPost] {
      try (0..<count).map { index in
        let timestamp = ATProtocolDate(date: Date(timeIntervalSince1970: 1_700_000_000))
        let author = AppBskyActorDefs.ProfileViewBasic(
          did: try DID(didString: "did:plc:refreshfixtureauthor"),
          handle: try Handle(handleString: "refresh-author.test"), displayName: "Refresh fixture",
          pronouns: nil, avatar: nil, associated: nil, viewer: nil, labels: nil,
          createdAt: nil, verification: nil, status: nil, debug: nil)
        let record = AppBskyFeedPost(text: "\(prefix) refresh fixture post \(index)",
          entities: nil, facets: nil, reply: nil, embed: nil, langs: nil, labels: nil,
          tags: nil, createdAt: timestamp)
        let post = AppBskyFeedDefs.PostView(
          uri: try ATProtocolURI(uriString: "at://did:plc:refreshfixtureauthor/app.bsky.feed.post/\(prefix)\(index)"),
          cid: CID.fromDAGCBOR(Data("\(prefix)-\(index)".utf8)), author: author,
          record: .knownType(record), embed: nil, bookmarkCount: nil,
          replyCount: 0, repostCount: 0, likeCount: 0, quoteCount: nil,
          indexedAt: timestamp, viewer: nil, labels: nil, threadgate: nil, debug: nil)
        let feedPost = AppBskyFeedDefs.FeedViewPost(post: post, reply: nil, reason: nil,
          feedContext: nil, reqId: nil)
        return try #require(CachedFeedViewPost(from: feedPost, feedType: "timeline"))
      }
    }
  }
}
#endif
