#if os(iOS)
import Darwin
import Petrel
import QuartzCore
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import Catbird

/// Hosted production views with synthetic data. This separates collection and
/// hosting work from authenticated transport, remote images and video playback.
/// Timings are receipts, never pass/fail thresholds on a shared simulator host.
@MainActor
final class FeedLoadPerformanceTests: XCTestCase {
  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal { .none }
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }

  private struct Geometry: Codable {
    let offsetY: Double
    let contentHeight: Double
    let anchorViewportY: Double
    let trendingHeight: Double
  }

  private struct Counters: Codable {
    let updateRequests: Int
    let snapshotApplications: Int
    let skippedSnapshots: Int
    let postConfigurations: Int
    let trendingConfigurations: Int
    let reconfiguredItems: Int

    init(_ value: FeedCollectionUpdateDiagnostics) {
      updateRequests = value.updateRequests
      snapshotApplications = value.snapshotApplications
      skippedSnapshots = value.skippedSnapshots
      postConfigurations = value.postConfigurations
      trendingConfigurations = value.trendingConfigurations
      reconfiguredItems = value.reconfiguredItems
    }
  }

  private struct Phase: Codable {
    let name: String
    let elapsedMilliseconds: Double
    /// Includes all work executed by the main thread during this async phase,
    /// including unrelated callbacks; it is not self CPU time for publication.
    let mainThreadCPUMilliseconds: Double
    let before: Geometry
    let after: Geometry
    let countersBefore: Counters
    let countersAfter: Counters
  }

  private struct Frame: Codable {
    let phase: String
    let callbackGapMilliseconds: Double
    let displayIntervalMilliseconds: Double
    let geometry: Geometry?
  }

  @MainActor
  private final class FrameProbe: NSObject {
    var frames: [Frame] = []
    var phase = "warmup"
    private var previousCallback: CFTimeInterval?
    private var link: CADisplayLink?
    private let geometry: @MainActor () -> Geometry?

    init(geometry: @escaping @MainActor () -> Geometry?) { self.geometry = geometry }

    func start() {
      let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
      link.add(to: .main, forMode: .common)
      self.link = link
    }

    func stop() {
      link?.invalidate()
      link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
      let now = CACurrentMediaTime()
      if let previousCallback {
        frames.append(Frame(phase: phase,
          callbackGapMilliseconds: (now - previousCallback) * 1_000,
          displayIntervalMilliseconds: (link.targetTimestamp - link.timestamp) * 1_000,
          geometry: geometry()))
      }
      previousCallback = now
    }
  }

  @MainActor
  private final class Fixture {
    let appState: AppState
    let model: FeedModel
    let state: FeedStateManager
    let viewportState = FeedViewportState()
    let controller: FeedCollectionViewControllerIntegrated
    let window: UIWindow
    var posts: [CachedFeedViewPost]
    var anchorID: String

    init(videoCards: Bool) async throws {
      // An unauthenticated client creates no account manager or token storage.
      // The reserved invalid domain also prevents accidental real service use.
      let client = await ATProtoClient(baseURL: URL(string: "https://feed-performance.invalid")!)
      appState = AppState(userDID: "did:plc:feedperformancefixture", client: client,
        regulatoryChecker: NoAgePrompt())
      appState.appSettings.showTrendingTopics = true
      appState.appSettings.showTrendingVideos = videoCards
      let manager = FeedManager(client: nil, fetchType: .timeline)
      model = FeedModel(feedManager: manager, appState: appState)
      posts = try Self.makePosts(0..<40)
      anchorID = posts[5].id
      model.posts = posts
      state = FeedStateManager(appState: appState, feedModel: model, feedType: .timeline)
      state.hasReachedEnd = true
      controller = FeedCollectionViewControllerIntegrated(
        stateManager: state, viewportState: viewportState,
        sceneContext: SceneNavigationContext(appState: appState, sceneID: UUID()),
        navigationPath: .constant(NavigationPath()))
      controller.enableUpdateDiagnostics()
      let topic = AppBskyUnspeccedDefs.TrendView(
        topic: "fixture", displayName: "Fixture Trending", description: "Local layout fixture",
        link: "/search?q=fixture", startedAt: ATProtocolDate(date: Self.epoch),
        postCount: 42, status: "hot", category: "technology", actors: [])
      let videos = videoCards ? try Self.rawPosts(200..<204) : []
      controller.setTrendingContent(TrendingFeedContent(trends: [topic], videos: videos))
      let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      window = UIWindow(windowScene: scene)
      window.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
      window.backgroundColor = .systemBackground
      window.rootViewController = controller
      window.isHidden = false
      await controller.performUpdate()
      try await settle()
      let anchor = try XCTUnwrap(controller.collectionView.layoutAttributesForItem(at: index(for: anchorID)))
      controller.collectionView.contentOffset.y = anchor.frame.minY
        - controller.collectionView.adjustedContentInset.top
      try await settle()
    }

    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static func rawPosts(_ range: Range<Int>, text: String? = nil) throws -> [AppBskyFeedDefs.FeedViewPost] {
      try range.map { number in
        let record = AppBskyFeedPost(
          text: text ?? "Fixture post \(number). This stable paragraph exercises the production text row while new posts load.",
          entities: nil, facets: nil, reply: nil, embed: nil, langs: nil, labels: nil,
          tags: nil, createdAt: ATProtocolDate(date: epoch))
        let author = AppBskyActorDefs.ProfileViewBasic(
          did: try DID(didString: "did:plc:fixtureauthor"),
          handle: try Handle(handleString: "author.test"), displayName: "Author",
          pronouns: nil, avatar: nil, associated: nil, viewer: nil, labels: nil,
          createdAt: nil, verification: nil, status: nil, debug: nil)
        let post = AppBskyFeedDefs.PostView(
          uri: try ATProtocolURI(uriString: "at://did:plc:fixtureauthor/app.bsky.feed.post/p\(number)"),
          cid: CID.fromDAGCBOR(Data("cid-test".utf8)), author: author,
          record: .knownType(record), embed: nil, bookmarkCount: nil,
          replyCount: 0, repostCount: 0, likeCount: 0, quoteCount: nil,
          indexedAt: ATProtocolDate(date: epoch), viewer: nil, labels: nil,
          threadgate: nil, debug: nil)
        return AppBskyFeedDefs.FeedViewPost(post: post, reply: nil, reason: nil,
          feedContext: nil, reqId: nil)
      }
    }

    static func makePosts(_ range: Range<Int>, text: String? = nil) throws -> [CachedFeedViewPost] {
      try rawPosts(range, text: text).map { try XCTUnwrap(CachedFeedViewPost(from: $0, feedType: "timeline")) }
    }

    func index(for id: String) throws -> IndexPath {
      let postIndex = try XCTUnwrap(posts.firstIndex { $0.id == id })
      // No header is configured; the production controller inserts Trending at six.
      return IndexPath(item: postIndex < 6 ? postIndex : postIndex + 1, section: 0)
    }

    func geometry() throws -> Geometry {
      let collection = try XCTUnwrap(controller.collectionView)
      let anchor = try XCTUnwrap(collection.layoutAttributesForItem(at: index(for: anchorID)))
      let trending = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: 6, section: 0)))
      return Geometry(offsetY: collection.contentOffset.y, contentHeight: collection.contentSize.height,
        anchorViewportY: anchor.frame.minY - collection.contentOffset.y - collection.adjustedContentInset.top,
        trendingHeight: trending.frame.height)
    }

    func settle() async throws {
      for _ in 0..<6 {
        try await Task.sleep(for: .milliseconds(20))
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        controller.collectionView.layoutIfNeeded()
      }
    }

    func publish(_ next: [CachedFeedViewPost]) async throws {
      posts = next
      model.posts = next
      // Exercise real publication and retained-view-model cleanup with no fetch.
      await state.reapplyFilters()
      await controller.performUpdate()
    }

    func close() {
      window.isHidden = true
      state.cleanup()
      appState.cleanup()
      window.rootViewController = nil
    }
  }

  /// Two hosted windows share data but each receives its own scene viewport.
  /// They use one existing UIWindowScene; this does not exercise OS scene creation.
  @MainActor
  private final class HostedViewport {
    let window: UIWindow
    let state: FeedStateManager
    let viewportState: FeedViewportState
    let sceneContext: SceneNavigationContext
    private(set) var controller: FeedCollectionViewControllerIntegrated

    init(scene: UIWindowScene, state: FeedStateManager, viewportState: FeedViewportState) async throws {
      self.state = state
      self.viewportState = viewportState
      self.sceneContext = SceneNavigationContext(appState: state.appState, sceneID: UUID())
      controller = FeedCollectionViewControllerIntegrated(stateManager: state,
        viewportState: viewportState, sceneContext: sceneContext,
        navigationPath: .constant(NavigationPath()))
      window = UIWindow(windowScene: scene)
      window.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
      window.backgroundColor = .systemBackground
      window.rootViewController = controller
      window.isHidden = false
      await controller.performUpdate()
      try await settle()
      XCTAssertEqual(controller.collectionView.numberOfItems(inSection: 0), state.posts.count,
        "This fixture has only post rows, so its index mapping must be exact")
    }

    func settle() async throws {
      for _ in 0..<6 {
        try await Task.sleep(for: .milliseconds(20))
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        controller.collectionView.layoutIfNeeded()
      }
    }

    func readPost(at index: Int, croppedPoints: CGFloat) async throws {
      let collection = try XCTUnwrap(controller.collectionView)
      controller.scrollViewWillBeginDragging(collection)
      collection.scrollToItem(at: IndexPath(item: index, section: 0), at: .top, animated: false)
      try await settle()
      collection.contentOffset.y += croppedPoints
      try await settle()
      controller.scrollViewDidEndDragging(collection, willDecelerate: false)
      XCTAssertEqual(try XCTUnwrap(viewportState.getScrollAnchor()).postID, state.posts[index].id)
    }

    func viewportY(for postID: String) throws -> CGFloat {
      let index = try XCTUnwrap(state.posts.firstIndex { $0.id == postID })
      let collection = try XCTUnwrap(controller.collectionView)
      let attributes = try XCTUnwrap(collection.layoutAttributesForItem(
        at: IndexPath(item: index, section: 0)))
      return attributes.frame.minY - collection.contentOffset.y - collection.adjustedContentInset.top
    }

    func recreateController() async throws -> FeedCollectionViewControllerIntegrated {
      let outgoing = controller
      // Capture while the outgoing window still has its real effective insets.
      outgoing.viewWillDisappear(false)
      let replacement = FeedCollectionViewControllerIntegrated(stateManager: state,
        viewportState: viewportState, sceneContext: sceneContext,
        navigationPath: .constant(NavigationPath()))
      controller = replacement
      window.rootViewController = replacement
      await replacement.performUpdate()
      try await settle()
      return outgoing
    }

    func waitUntilAtTop() async throws {
      let deadline = ContinuousClock.now + .seconds(2)
      let collection = try XCTUnwrap(controller.collectionView)
      while abs(collection.contentOffset.y + collection.adjustedContentInset.top) > 1,
        ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
        collection.layoutIfNeeded()
      }
      XCTAssertEqual(collection.contentOffset.y, -collection.adjustedContentInset.top, accuracy: 1)
    }

    func close() {
      window.isHidden = true
      window.rootViewController = nil
    }
  }

  private struct ViewportReceipt: Codable {
    let phase: String
    let firstOffsetY: Double
    let secondOffsetY: Double
    let firstAnchorViewportY: Double
    let secondAnchorViewportY: Double
  }

  /// This receipt-only scenario can be transplanted unchanged onto the baseline
  /// with the behavior-neutral diagnostics patch. It intentionally permits old
  /// churn/anchor behavior so both builds produce comparable observations.
  func testLoadingWithTrendingRecordsStallsAndViewport() async throws {
    for videoCards in [false, true] {
      let fixture = try await Fixture(videoCards: videoCards)
      defer { fixture.close() }
      let variant = videoCards ? "topics-and-video-cards" : "topics"
      try attachScreenshot(fixture, named: "\(variant)-before", requireTrending: true,
        requiredText: "fixture post 5")
      let probe = FrameProbe { [weak fixture] in try? fixture?.geometry() }
      probe.start()
      defer { probe.stop() }
      try await fixture.settle()
      var phases: [Phase] = []
      for page in 0..<3 {
        phases.append(try await measure("append-\(page)", fixture: fixture, probe: probe) {
          let start = 40 + page * 10
          try await fixture.publish(fixture.posts + Fixture.makePosts(start..<(start + 10)))
        })
      }
      phases.append(try await measure("prepend", fixture: fixture, probe: probe) {
        try await fixture.publish(Fixture.makePosts(100..<103) + fixture.posts)
      })
      probe.stop()
      try attachJSON(phases, named: "\(variant)-phases.json")
      try attachJSON(probe.frames, named: "\(variant)-frames.json")
      try attachScreenshot(fixture, named: "\(variant)-after", requireTrending: false)
      XCTAssertEqual(fixture.state.posts.map(\.id), fixture.posts.map(\.id))
      XCTAssertEqual(fixture.controller.collectionView.numberOfItems(inSection: 0), 75)
      XCTAssertFalse(probe.frames.isEmpty, "The simulator must deliver display callbacks")
    }
  }

  func testAppendWithVisibleTrendingPreservesAnchorWithoutReconfiguringSurvivors() async throws {
    let fixture = try await Fixture(videoCards: true)
    defer { fixture.close() }
    let before = try fixture.geometry()
    let counts = try XCTUnwrap(fixture.controller.updateDiagnostics)
    let retained = fixture.state.viewModel(for: fixture.posts[5])
    try attachScreenshot(fixture, named: "append-before", requireTrending: true)
    try await fixture.publish(fixture.posts + Fixture.makePosts(40..<50))
    try await fixture.settle()
    let after = try fixture.geometry()
    let next = try XCTUnwrap(fixture.controller.updateDiagnostics)
    try attachScreenshot(fixture, named: "append-after", requireTrending: true)
    XCTAssertEqual(after.anchorViewportY, before.anchorViewportY, accuracy: 1)
    XCTAssertEqual(after.trendingHeight, before.trendingHeight, accuracy: 1)
    XCTAssertTrue(retained === fixture.state.viewModel(for: fixture.posts[5]))
    XCTAssertEqual(next.trendingConfigurations - counts.trendingConfigurations, 0)
    XCTAssertEqual(next.reconfiguredItems - counts.reconfiguredItems, 0)
    XCTAssertEqual(fixture.state.posts.map(\.id), fixture.posts.map(\.id))
  }

  func testNewerPostsKeepThePreviouslyVisiblePostAtItsViewportPosition() async throws {
    let fixture = try await Fixture(videoCards: true)
    defer { fixture.close() }
    let before = try fixture.geometry()
    let anchorID = fixture.anchorID
    try await fixture.publish(Fixture.makePosts(100..<103) + fixture.posts)
    try await fixture.settle()
    let after = try fixture.geometry()
    try attachScreenshot(fixture, named: "prepend-preserved-anchor", requireTrending: false)
    XCTAssertEqual(fixture.anchorID, anchorID)
    XCTAssertEqual(after.anchorViewportY, before.anchorViewportY, accuracy: 1)
    XCTAssertEqual(fixture.state.posts.map(\.id), fixture.posts.map(\.id))
  }

  func testChangedVisiblePostAndTrendingContentStillRender() async throws {
    let fixture = try await Fixture(videoCards: false)
    defer { fixture.close() }
    let before = try XCTUnwrap(fixture.controller.updateDiagnostics)
    let retained = fixture.state.viewModel(for: fixture.posts[5])
    var changed = fixture.posts
    changed[5] = try XCTUnwrap(Fixture.makePosts(5..<6, text: "UPDATED FIXTURE TEXT").first)
    try await fixture.publish(changed)
    try await fixture.settle()
    let afterPost = try XCTUnwrap(fixture.controller.updateDiagnostics)
    XCTAssertTrue(retained === fixture.state.viewModel(for: changed[5]))
    XCTAssertEqual(afterPost.reconfiguredItems - before.reconfiguredItems, 1)
    XCTAssertEqual(afterPost.trendingConfigurations - before.trendingConfigurations, 0)
    try attachScreenshot(fixture, named: "changed-post", requireTrending: true,
      requiredText: "updated fixture text")

    let topic = AppBskyUnspeccedDefs.TrendView(
      topic: "updated", displayName: "Updated Fixture Trend", description: nil,
      link: "/search?q=updated", startedAt: ATProtocolDate(date: Fixture.epoch),
      postCount: 43, status: "hot", category: "technology", actors: [])
    fixture.controller.setTrendingContent(TrendingFeedContent(trends: [topic]))
    await fixture.controller.performUpdate()
    try await fixture.settle()
    let afterTrending = try XCTUnwrap(fixture.controller.updateDiagnostics)
    XCTAssertEqual(afterTrending.trendingConfigurations - afterPost.trendingConfigurations, 1)
    try attachScreenshot(fixture, named: "changed-trending", requireTrending: true,
      requiredText: "updated fixture trend")
  }

  func testCustomFeedLoadingOmitsRecordKey() async throws {
    let recordKey = "raw-record-key-must-stay-hidden"
    let feed = FetchType.feed(try ATProtocolURI(
      uriString: "at://did:plc:fixtureauthor/app.bsky.feed.generator/\(recordKey)"))
    let client = await ATProtoClient(baseURL: URL(string: "https://feed-loading.invalid")!)
    let appState = AppState(userDID: "did:plc:feedloadingfixture", client: client,
      regulatoryChecker: NoAgePrompt())
    let model = FeedModel(feedManager: FeedManager(client: nil, fetchType: feed), appState: appState)
    let state = FeedStateManager(appState: appState, feedModel: model, feedType: feed)
    let controller = FeedCollectionViewControllerIntegrated(
      stateManager: state, viewportState: FeedViewportState(),
      sceneContext: SceneNavigationContext(appState: appState, sceneID: UUID()),
      navigationPath: .constant(NavigationPath()))
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
    window.backgroundColor = .systemBackground
    defer {
      window.isHidden = true
      state.cleanup()
      appState.cleanup()
      window.rootViewController = nil
    }

    // No account/session exists. The normal availability retry keeps the real
    // loading state observable without reaching the nil feed transport.
    let loading = Task { await state.loadInitialData() }
    var captureError: Error?
    do {
      let deadline = ContinuousClock.now + .seconds(1)
      while !state.isLoading && ContinuousClock.now < deadline { await Task.yield() }
      XCTAssertTrue(state.isLoading)
      let hasSession = await client.hasValidSession()
      XCTAssertFalse(hasSession)
      window.rootViewController = controller
      window.isHidden = false
      await controller.performUpdate()
      for _ in 0..<6 {
        try await Task.sleep(for: .milliseconds(20))
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
      }

      let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
      var drewHierarchy = false
      let image = renderer.image { _ in
        drewHierarchy = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      let screenshot = XCTAttachment(image: image)
      screenshot.name = "custom-feed-loading"
      screenshot.lifetime = .keepAlways
      add(screenshot)
      XCTAssertTrue(drewHierarchy)
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.recognitionLanguages = ["en-US"]
      try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage), options: [:]).perform([request])
      let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
      let transcript = XCTAttachment(string: text)
      transcript.name = "custom-feed-loading-ocr"
      transcript.lifetime = .keepAlways
      add(transcript)
      XCTAssertTrue(text.lowercased().contains("loading feed"))
      XCTAssertFalse(text.lowercased().contains(recordKey))
      XCTAssertTrue(state.isLoading, "The capture must represent loading, not the later account error")
    } catch {
      captureError = error
    }
    // Drain the retry task even when screenshot/OCR capture throws.
    loading.cancel()
    await loading.value
    if let captureError { throw captureError }
  }

  func testSharedFeedDataKeepsWindowPositionsAndReplacementCommandsIndependent() async throws {
    let client = await ATProtoClient(baseURL: URL(string: "https://feed-windows.invalid")!)
    let appState = AppState(userDID: "did:plc:feedwindowsfixture", client: client,
      regulatoryChecker: NoAgePrompt())
    appState.appSettings.showTrendingTopics = false
    appState.appSettings.showTrendingVideos = false
    let model = FeedModel(feedManager: FeedManager(client: nil, fetchType: .timeline), appState: appState)
    model.posts = try Fixture.makePosts(0..<40)
    let state = FeedStateManager(appState: appState, feedModel: model, feedType: .timeline)
    state.hasReachedEnd = true
    defer {
      state.cleanup()
      appState.cleanup()
    }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let firstStore = FeedViewportStore()
    let secondStore = FeedViewportStore()
    let firstState = firstStore.state(accountDID: "did:plc:feedwindowsfixture", feedIdentifier: "timeline")
    let secondState = secondStore.state(accountDID: "did:plc:feedwindowsfixture", feedIdentifier: "timeline")
    let first = try await HostedViewport(scene: scene, state: state, viewportState: firstState)
    defer { first.close() }
    let second = try await HostedViewport(scene: scene, state: state, viewportState: secondState)
    defer { second.close() }
    XCTAssertTrue(first.controller.stateManager === second.controller.stateManager)
    XCTAssertFalse(first.controller.viewportState === second.controller.viewportState)

    try await first.readPost(at: 5, croppedPoints: 13)
    try await second.readPost(at: 20, croppedPoints: 27)
    let firstAnchor = try XCTUnwrap(firstState.getScrollAnchor())
    let secondAnchor = try XCTUnwrap(secondState.getScrollAnchor())
    XCTAssertNotEqual(firstAnchor.postID, secondAnchor.postID)
    let firstY = try first.viewportY(for: firstAnchor.postID)
    let secondY = try second.viewportY(for: secondAnchor.postID)
    XCTAssertEqual(firstY, firstAnchor.viewportAnchor.viewportY, accuracy: 1)
    XCTAssertEqual(secondY, secondAnchor.viewportAnchor.viewportY, accuracy: 1)
    var receipts: [ViewportReceipt] = []
    func record(_ phase: String) throws {
      receipts.append(ViewportReceipt(phase: phase,
        firstOffsetY: first.controller.collectionView.contentOffset.y,
        secondOffsetY: second.controller.collectionView.contentOffset.y,
        firstAnchorViewportY: try first.viewportY(for: firstAnchor.postID),
        secondAnchorViewportY: try second.viewportY(for: secondAnchor.postID)))
    }
    try record("independent-reading-positions")
    try attachScreenshot(first.window, named: "first-window-reading", requireTrending: false,
      requiredText: "fixture post 5")
    try attachScreenshot(second.window, named: "second-window-reading", requireTrending: false,
      requiredText: "fixture post 20")

    // One publication reaches both production controllers without unifying their viewports.
    model.posts += try Fixture.makePosts(40..<50)
    await state.reapplyFilters()
    await first.controller.performUpdate()
    await second.controller.performUpdate()
    try await first.settle()
    try await second.settle()
    XCTAssertEqual(first.controller.collectionView.numberOfItems(inSection: 0), 50)
    XCTAssertEqual(second.controller.collectionView.numberOfItems(inSection: 0), 50)
    XCTAssertEqual(try first.viewportY(for: firstAnchor.postID), firstY, accuracy: 1)
    XCTAssertEqual(try second.viewportY(for: secondAnchor.postID), secondY, accuracy: 1)
    try record("shared-publication")

    let secondOffsetBeforeReplacement = second.controller.collectionView.contentOffset.y
    let oldController = try await first.recreateController()
    XCTAssertTrue(first.controller.viewportState === firstStore.state(
      accountDID: "did:plc:feedwindowsfixture", feedIdentifier: "timeline"))
    XCTAssertEqual(try first.viewportY(for: firstAnchor.postID), firstY, accuracy: 1)
    XCTAssertEqual(second.controller.collectionView.contentOffset.y, secondOffsetBeforeReplacement, accuracy: 1)
    XCTAssertEqual(try XCTUnwrap(secondState.getScrollAnchor()).postID, secondAnchor.postID)
    try record("first-controller-recreated")
    try attachScreenshot(first.window, named: "first-window-restored", requireTrending: false,
      requiredText: "fixture post 5")

    // Delay the outgoing controller's teardown until its replacement owns the handler.
    // This must not remove the new registration or send the command to another window.
    let oldOffset = oldController.collectionView.contentOffset.y
    oldController.viewWillDisappear(false)
    firstState.scrollToTop()
    try await first.waitUntilAtTop()
    try await second.settle()
    XCTAssertEqual(oldController.collectionView.contentOffset.y, oldOffset, accuracy: 1)
    XCTAssertEqual(second.controller.collectionView.contentOffset.y, secondOffsetBeforeReplacement, accuracy: 1)
    XCTAssertEqual(try second.viewportY(for: secondAnchor.postID), secondY, accuracy: 1)
    try record("first-command-after-stale-owner-teardown")
    try attachScreenshot(first.window, named: "first-window-command-at-top", requireTrending: false,
      requiredText: "fixture post 0")
    try attachScreenshot(second.window, named: "second-window-unmoved", requireTrending: false,
      requiredText: "fixture post 20")
    try attachJSON(receipts, named: "shared-feed-window-viewport-receipts.json")
  }

  private func measure(_ name: String, fixture: Fixture, probe: FrameProbe,
    operation: () async throws -> Void) async throws -> Phase {
    let before = try fixture.geometry()
    let counts = try XCTUnwrap(fixture.controller.updateDiagnostics)
    probe.phase = name
    XCTAssertTrue(Thread.isMainThread)
    let start = CACurrentMediaTime()
    let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    try await operation()
    XCTAssertTrue(Thread.isMainThread)
    let mainThreadCPUMilliseconds = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000
    let elapsedMilliseconds = (CACurrentMediaTime() - start) * 1_000
    try await fixture.settle()
    return Phase(name: name, elapsedMilliseconds: elapsedMilliseconds,
      mainThreadCPUMilliseconds: mainThreadCPUMilliseconds,
      before: before, after: try fixture.geometry(), countersBefore: Counters(counts),
      countersAfter: Counters(try XCTUnwrap(fixture.controller.updateDiagnostics)))
  }

  private func attachJSON<T: Encodable>(_ value: T, named name: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let attachment = XCTAttachment(data: try encoder.encode(value), uniformTypeIdentifier: "public.json")
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func attachScreenshot(_ fixture: Fixture, named name: String, requireTrending: Bool,
    requiredText: String? = nil) throws {
    try attachScreenshot(fixture.window, named: name, requireTrending: requireTrending,
      requiredText: requiredText)
  }

  private func attachScreenshot(_ window: UIWindow, named name: String, requireTrending: Bool,
    requiredText: String? = nil) throws {
    let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
    var drewHierarchy = false
    let image = renderer.image { _ in
      drewHierarchy = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTAssertTrue(drewHierarchy, "UIKit must render the production collection cells")
    if requireTrending || requiredText != nil {
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.recognitionLanguages = ["en-US"]
      try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage), options: [:]).perform([request])
      let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
      let normalized = text.lowercased()
      let transcript = XCTAttachment(string: text)
      transcript.name = "\(name)-ocr"
      transcript.lifetime = .keepAlways
      add(transcript)
      if requireTrending {
        XCTAssertTrue(normalized.contains("trending on bluesky"), "Trending must be present in captured pixels")
      }
      if let requiredText {
        XCTAssertTrue(normalized.contains(requiredText), "Updated content must be present in captured pixels")
      }
    }
  }
}
#endif
