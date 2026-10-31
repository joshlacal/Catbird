#if os(iOS)
import Foundation
import Nuke
@testable import Petrel
import SwiftData
import Testing
import UIKit
@testable import Catbird

@MainActor
@Suite("Trending interstitial cell", .serialized)
struct TrendingInterstitialCellTests {
  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal { .none }
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }

  /// An account with in-memory persisted settings, so trending settings can change during a test.
  /// The store outlives the test: the preferences load `configure` schedules and debounced settings
  /// saves can run after a test that never suspends has returned.
  private func makeAppState() async throws -> AppState {
    let accountDID = "did:plc:trendingcellfixture"
    let container = try ModelContainer(
      for: AppSettingsModel.self, Preferences.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    container.mainContext.insert(AppSettingsModel(accountDID: accountDID))
    try container.mainContext.save()
    TestSettingsStores.retain(container)
    // The reserved invalid domain keeps the fixture from reaching a real service.
    let client = await ATProtoClient(baseURL: try #require(URL(string: "https://trending-cell.invalid")))
    let appState = AppState(userDID: accountDID, client: client, regulatoryChecker: NoAgePrompt())
    appState.initializePreferencesManager(with: container.mainContext)
    for _ in 0..<150 where !appState.appSettings.canEditPersistedSettings {
      try await Task.sleep(for: .milliseconds(20))
    }
    try #require(appState.appSettings.canEditPersistedSettings)
    appState.appSettings.showTrendingTopics = true
    appState.appSettings.showTrendingVideos = true
    TrendingInterstitialCell.clearSharedCardPoolsForTesting()
    return appState
  }

  private func makeTopic(_ name: String = "Moon Garden", postCount: Int = 1200) -> AppBskyUnspeccedDefs.TrendView {
    .init(topic: name.lowercased(), displayName: name,
      description: "A community conversation about plants and astronomy.",
      link: "/profile/did:plc:trendingcellcreator/feed/\(name.lowercased().replacingOccurrences(of: " ", with: "-"))",
      startedAt: ATProtocolDate(date: Date()), postCount: postCount, status: "hot", category: "science", actors: [])
  }

  private func makeVideo(authorName: String = "River Films", alt: String? = "A river through a garden",
    thumbnail: URL? = nil, avatar: URL? = nil)
    throws -> AppBskyFeedDefs.FeedViewPost {
    let cid = CID.fromDAGCBOR(Data("trending-cell-video-\(authorName)".utf8))
    let author = AppBskyActorDefs.ProfileViewBasic(
      did: try DID(didString: "did:plc:trendingcellauthor"), handle: try Handle(handleString: "river.example.invalid"),
      displayName: authorName, pronouns: nil, avatar: avatar.map { URI(uriString: $0.absoluteString) }, associated: nil, viewer: nil,
      labels: nil, createdAt: nil, verification: nil, status: nil, debug: nil)
    let postRKey = thumbnail != nil || avatar != nil ? "with-media" : "\(authorName.count)"
    let post = AppBskyFeedDefs.PostView(
      uri: try ATProtocolURI(uriString: "at://did:plc:trendingcellauthor/app.bsky.feed.post/\(postRKey)"),
      cid: cid, author: author,
      record: .knownType(AppBskyFeedPost(text: "Fixture video", createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 0)))),
      embed: .appBskyEmbedVideoView(.init(cid: cid, playlist: URI(uriString: "file:///nonexistent/fixture.m3u8"),
        thumbnail: thumbnail.map { URI(uriString: $0.absoluteString) }, alt: alt, aspectRatio: .init(width: 9, height: 16))),
      bookmarkCount: nil, replyCount: 0, repostCount: 0, likeCount: 0, quoteCount: nil,
      indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 0)), viewer: nil,
      labels: nil, threadgate: nil, debug: nil)
    return .init(post: post, reply: nil, reason: nil, feedContext: nil, reqId: nil)
  }

  /// Configures and lays out a cell at `width`, sized the way the feed's list layout sizes it.
  private func layOut(
    _ cell: TrendingInterstitialCell, content: TrendingFeedContent, appState: AppState, width: CGFloat = 390
  ) -> CGFloat {
    cell.configure(.init(
      content: content, appState: appState, sceneContext: SceneNavigationContext(appState: appState, sceneID: UUID())))
    let height = cell.systemLayoutSizeFitting(
      CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel).height
    cell.frame = CGRect(x: 0, y: 0, width: width, height: height)
    cell.layoutIfNeeded()
    return height
  }

  private func descendants<T: UIView>(of type: T.Type, in view: UIView) -> [T] {
    view.subviews.flatMap { subview -> [T] in
      (subview.isHidden ? [] : [subview as? T].compactMap { $0 }) + descendants(of: type, in: subview)
    }
  }

  @Test("The cell is as tall as its layout and exposes the presentation's accessibility")
  func sizeAndAccessibility() async throws {
    let appState = try await makeAppState()
    let cell = TrendingInterstitialCell(frame: .zero)
    let height = layOut(cell, content: TrendingFeedContent(trends: [makeTopic()], videos: [try makeVideo()]), appState: appState)
    #expect(height > 0)
    let preferred = cell.preferredLayoutAttributesFitting(
      UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 6, section: 0)).with(width: 390))
    #expect(preferred.size.height == height)

    let topic = try #require(descendants(of: TrendingTopicCardView.self, in: cell).first)
    #expect(topic.isAccessibilityElement)
    #expect(topic.accessibilityLabel == "Science, Moon Garden, A community conversation about plants and astronomy., 1.2K posts")
    #expect(topic.accessibilityHint == "Open posts about this topic")
    #expect(topic.accessibilityTraits.contains(.button))

    let video = try #require(descendants(of: TrendingVideoCardView.self, in: cell).first)
    #expect(video.accessibilityLabel == "Video by River Films, A river through a garden")
    #expect(video.accessibilityHint == "Play this video in The Vids")
    #expect(video.accessibilityTraits.contains(.button))

    let buttons = descendants(of: UIControl.self, in: cell)
    #expect(buttons.contains { $0.accessibilityLabel == "Trending options" })
    let openVideos = try #require(buttons.first { $0.accessibilityLabel == "Open The Vids" })
    #expect(openVideos.accessibilityHint == "Open the full-screen Bluesky video feed")
    #expect(openVideos.accessibilityTraits.contains(.button))
  }

  @Test("Offscreen first-display preparation never starts thumbnail or avatar requests")
  func warmupDoesNotLoadVideoImages() async throws {
    let appState = try await makeAppState()
    let base = "https://warmup-images.invalid/\(UUID().uuidString)"
    let thumb = URL(string: base + "/video.jpg")!
    let avatar = URL(string: base + "/avatar.jpg")!
    let video = try makeVideo(thumbnail: thumb, avatar: avatar)
    let content = TrendingFeedContent(videos: [video])
    let requests = TrendingInterstitialCell.prepareFirstDisplay(.init(content: content, appState: appState,
      sceneContext: SceneNavigationContext(appState: appState, sceneID: UUID())),
      width: 390, traits: UITraitCollection(displayScale: 3))
    #expect(requests == 0, "Offscreen preparation must not even enqueue pipeline image work")
    let cell = TrendingInterstitialCell(frame: .zero)
    _ = layOut(cell, content: content, appState: appState)
    #expect(cell.startedImageRequestCountForTesting == 2)
    _ = layOut(cell, content: TrendingFeedContent(), appState: appState)
  }

  @Test("Cached-only topic art does not start a pipeline request on a cache miss")
  func warmupDoesNotLoadTopicImages() async throws {
    let appState = try await makeAppState()
    let url = URL(string: "https://warmup-images.invalid/\(UUID().uuidString)/topic.jpg")!
    let view = UIImageView()
    let slot = TrendingImageSlot(imageView: view)
    let images = TrendingTopicImages(appState: appState, displayScale: 3, allowsImageLoading: false)
    let request = images.mediaRequest(url)
    images.load(request, into: slot)
    #expect(slot.startedRequestCountForTesting == 0)
    TrendingTopicImages(appState: appState, displayScale: 3).load(request, into: slot)
    #expect(slot.startedRequestCountForTesting == 1,
      "A cache-only miss must not suppress the later normal request for that same identity")
    slot.cancel()
    let cachedURL = URL(string: "https://warmup-images.invalid/\(UUID().uuidString)/cached.jpg")!
    let cachedRequest = images.mediaRequest(cachedURL)
    let cachedImage = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }
    ImageLoadingManager.shared.pipeline.cache[cachedRequest] = ImageContainer(image: cachedImage)
    defer { ImageLoadingManager.shared.pipeline.cache[cachedRequest] = nil }
    let cachedView = UIImageView()
    let cachedSlot = TrendingImageSlot(imageView: cachedView)
    images.load(cachedRequest, into: cachedSlot)
    #expect(cachedSlot.startedRequestCountForTesting == 0)
    let rendered = try #require(cachedView.image)
    #expect(rendered.pngData() == cachedImage.pngData())
    cachedSlot.cancel()
  }

  @Test("Hidden or empty trending content collapses the row")
  func hiddenCollapses() async throws {
    let appState = try await makeAppState()
    let cell = TrendingInterstitialCell(frame: .zero)
    #expect(layOut(cell, content: TrendingFeedContent(), appState: appState) == 0)

    appState.appSettings.showTrendingTopics = false
    appState.appSettings.showTrendingVideos = false
    #expect(layOut(cell, content: TrendingFeedContent(trends: [makeTopic()], videos: [try makeVideo()]), appState: appState) == 0)
  }

  @Test("Videos alone render without the topics carousel")
  func videosOnly() async throws {
    let appState = try await makeAppState()
    let cell = TrendingInterstitialCell(frame: .zero)
    let both = layOut(TrendingInterstitialCell(frame: .zero),
      content: TrendingFeedContent(trends: [makeTopic()], videos: [try makeVideo()]), appState: appState)
    let videos = layOut(cell, content: TrendingFeedContent(videos: [try makeVideo()]), appState: appState)
    #expect(videos > 0 && videos < both)
    #expect(descendants(of: TrendingTopicCardView.self, in: cell).isEmpty)
    #expect(descendants(of: TrendingVideoCardView.self, in: cell).count == 1)
  }

  @Test("A reused cell shows its new content, and identical content keeps its card views")
  func reuse() async throws {
    let appState = try await makeAppState()
    let cell = TrendingInterstitialCell(frame: .zero)
    let first = TrendingFeedContent(trends: [makeTopic()], videos: [try makeVideo()])
    _ = layOut(cell, content: first, appState: appState)
    let card = try #require(descendants(of: TrendingTopicCardView.self, in: cell).first)

    cell.prepareForReuse()
    _ = layOut(cell, content: first, appState: appState)
    #expect(descendants(of: TrendingTopicCardView.self, in: cell).first === card,
      "Scrolling the same row back in must not rebuild its cards")

    cell.prepareForReuse()
    _ = layOut(cell, content: TrendingFeedContent(
      trends: [makeTopic("Comet Night", postCount: 0)], videos: [try makeVideo(authorName: "Sky Reels", alt: nil)]),
      appState: appState)
    let topics = descendants(of: TrendingTopicCardView.self, in: cell)
    #expect(topics.count == 1)
    #expect(topics.first?.accessibilityLabel == "Science, Comet Night, A community conversation about plants and astronomy.")
    #expect(descendants(of: TrendingVideoCardView.self, in: cell).first?.accessibilityLabel == "Video by Sky Reels")
  }

  @Test("Turning a section off in settings refreshes a configured cell")
  func observesSettings() async throws {
    let appState = try await makeAppState()
    let cell = TrendingInterstitialCell(frame: .zero)
    let content = TrendingFeedContent(trends: [makeTopic()], videos: [try makeVideo()])
    let both = layOut(cell, content: content, appState: appState)
    appState.appSettings.showTrendingVideos = false
    // The observation change is delivered on the main actor after this turn.
    for _ in 0..<20 where !descendants(of: TrendingVideoCardView.self, in: cell).isEmpty {
      try await Task.sleep(for: .milliseconds(10))
      cell.layoutIfNeeded()
    }
    #expect(descendants(of: TrendingVideoCardView.self, in: cell).isEmpty)
    let topicsOnly = cell.systemLayoutSizeFitting(
      CGSize(width: 390, height: 0), withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel).height
    #expect(topicsOnly < both)
  }

  @Test("Card views allocated during prepareFirstDisplay are reused by a subsequent dequeued cell")
  func cardViewsFromWarmupAreReusedBySubsequentCell() async throws {
    TrendingInterstitialCell.clearSharedCardPoolsForTesting()
    defer { TrendingInterstitialCell.clearSharedCardPoolsForTesting() }
    let appState = try await makeAppState()
    let topic = makeTopic()
    let video = try makeVideo()
    let content = TrendingFeedContent(trends: [topic], videos: [video])
    _ = TrendingInterstitialCell.prepareFirstDisplay(
      .init(content: content, appState: appState,
            sceneContext: SceneNavigationContext(appState: appState, sceneID: UUID())),
      width: 390, traits: UITraitCollection(displayScale: 3))

    let liveCell = TrendingInterstitialCell(frame: .zero)
    _ = layOut(liveCell, content: content, appState: appState)
    let topicCard = descendants(of: TrendingTopicCardView.self, in: liveCell).first
    let videoCard = descendants(of: TrendingVideoCardView.self, in: liveCell).first
    #expect(topicCard != nil, "Live cell must have a topic card")
    #expect(videoCard != nil, "Live cell must have a video card")
  }
}

private extension UICollectionViewLayoutAttributes {
  func with(width: CGFloat) -> UICollectionViewLayoutAttributes {
    size = CGSize(width: width, height: 44)
    return self
  }
}
/// In-memory settings stores used by this test process. `AppState` schedules work against its
/// store (the preferences load in `PreferencesManager.configure`, debounced `AppSettings` saves)
/// that can run after a test returns, so the stores are never released mid-process.
@MainActor
enum TestSettingsStores {
  private static var containers: [ModelContainer] = []

  static func retain(_ container: ModelContainer) {
    containers.append(container)
  }
}
#endif
