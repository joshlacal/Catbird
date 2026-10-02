#if os(iOS)
import Foundation
import Petrel
import SwiftUI
import Testing
import UIKit
import Vision

@testable import Catbird

/// UIKit-hosted production components, with local data and no discovery lifecycle loads.
/// These receipts qualify presentation; they do not qualify authenticated actions or the
/// FeedsStartPage preference-loading lifecycle, account switching, or a physical device.
@Suite("Feeds and Search presentation", .serialized)
@MainActor
struct FeedsSearchPresentationTests {
  @Test("Account identity stays readable below busy artwork across constrained containers")
  func accountHeaderAcrossSizes() async throws {
    let appState = try await makeAppState()
    let cases: [(String, CGSize, ColorScheme, DynamicTypeSize)] = [
      ("narrow-light", CGSize(width: 320, height: 600), .light, .large),
      ("wide-dark", CGSize(width: 680, height: 500), .dark, .large),
      ("square-light", CGSize(width: 500, height: 500), .light, .large),
      ("short-light", CGSize(width: 430, height: 320), .light, .xxLarge),
      ("narrow-larger-text", CGSize(width: 320, height: 760), .dark, .accessibility1),
    ]
    for (name, size, scheme, typeSize) in cases {
      try await withHost(
        FeedsHeaderFixture(size: size), appState: appState,
        size: size, scheme: scheme, typeSize: typeSize
      ) { host in
        let receipt = try await host.capture(
          "feeds-header-\(name)", requiring: ["Alexandra", "Chen"]
        )
        let identity = try #require(receipt.lines.first { $0.text.contains("Alexandra") })
        if let defaultLabel = receipt.lines.first(where: { $0.text.contains("Default feed") }) {
          #expect(identity.rect.maxY < defaultLabel.rect.minY, "The default control must not overlap account identity")
        }
        if let scroll = host.verticalScrollView {
          scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
        }
        _ = try await host.capture("feeds-header-\(name)-controls", requiring: ["Default feed", "Following"])
      }
    }
  }

  @Test("Video bylines honor app font size and line spacing as well as Dynamic Type")
  func videoBylinesWithAppFontPreferences() async throws {
    let appState = try await makeAppState()
    appState.fontManager.fontSize = "extraLarge"
    appState.fontManager.lineSpacing = "relaxed"
    let video = try makeVideo(authorName: "River Garden Films")
    for typeSize in [DynamicTypeSize.large, .accessibility1] {
      try await withHost(
        VStack(alignment: .leading, spacing: 0) {
          TrendingVideosSection(videos: [video], presentation: .timeline,
            onSelectPost: { _ in }, onSeeAll: {})
          Text("NEXT POST").padding(16)
        }, appState: appState, size: CGSize(width: 320, height: 760), typeSize: typeSize
      ) { host in
        let receipt = try await host.capture("video-byline-app-font-\(typeSize)", requiring: ["River Garden Films", "NEXT POST"])
        let lastAuthorLine = try #require(receipt.lines.first { $0.text.contains("Films") })
        let nextPost = try #require(receipt.lines.first { $0.text.contains("NEXT POST") })
        #expect(lastAuthorLine.rect.maxY < nextPost.rect.minY, "The full byline must fit above the next timeline item")
      }
    }
  }

  @Test("Feed grid uses the receiving width and preserves room for interactive cells")
  func feedGridFitsContainers() {
    for width: CGFloat in [240, 280, 320, 375, 430, 600, 768] {
      for largeText in [false, true] {
        let padding: CGFloat = width < 360 ? 12 : 18
        let spacing: CGFloat = width < 360 ? 6 : 12
        let count = FeedsStartPageLayoutMetrics.columnCount(
          width: width, horizontalPadding: padding, spacing: spacing, usesLargeText: largeText
        )
        let itemWidth = (width - 2 * padding - CGFloat(count - 1) * spacing) / CGFloat(count)
        #expect(count > 0)
        #expect(itemWidth >= 44, "Every grid control needs a usable touch width")
        #expect(FeedsStartPageLayoutMetrics.iconSize(itemWidth: itemWidth) <= itemWidth)
        #expect(CGFloat(count) * itemWidth + CGFloat(count - 1) * spacing + padding * 2 <= width + 0.01)
      }
    }
  }

  @Test("Trending shows readable topics and shorter video previews in timeline containers")
  func trendingTimelineAcrossSizes() async throws {
    let appState = try await makeAppState()
    let content = TrendingFeedContent(trends: [makeTopic()], videos: [try makeVideo()])
    for (name, width, scheme, typeSize) in [
      ("narrow-light", CGFloat(320), ColorScheme.light, DynamicTypeSize.large),
      ("wide-dark", CGFloat(680), ColorScheme.dark, DynamicTypeSize.large),
      ("narrow-larger-text", CGFloat(320), ColorScheme.dark, DynamicTypeSize.accessibility1),
    ] {
      try await withHost(
        trending(content, topics: true, videos: true), appState: appState,
        size: CGSize(width: width, height: 850), scheme: scheme, typeSize: typeSize
      ) { host in
        let receipt = try await host.capture(
          "trending-timeline-\(name)", requiring: ["Trending on Bluesky", "Moon Garden", "Open The Vids", "River Films"]
        )
        let topic = try #require(receipt.lines.first { $0.text.contains("Moon Garden") })
        let author = try #require(receipt.lines.first { $0.text.contains("River Films") })
        #expect(author.rect.minY > topic.rect.maxY, "Video byline must remain below the topic content")
      }
    }
  }

  @Test("Empty or hidden interstitials leave the next timeline row immediately available")
  func hiddenTrendingDoesNotReserveAVisibleCell() async throws {
    let appState = try await makeAppState()
    let loaded = TrendingFeedContent(trends: [makeTopic()], videos: [try makeVideo()])
    for (name, content, topics, videos) in [
      ("empty", TrendingFeedContent(), true, true),
      ("preferences-hidden", loaded, false, false),
    ] {
      try await withHost(
        VStack(alignment: .leading, spacing: 0) {
          trending(content, topics: topics, videos: videos)
          Text("TIMELINE CONTINUES").padding(16)
          Spacer()
        }, appState: appState, size: CGSize(width: 320, height: 400)
      ) { host in
        let receipt = try await host.capture("trending-\(name)", requiring: ["TIMELINE CONTINUES"])
        #expect(!receipt.contains("Trending on Bluesky"))
        let nextRow = try #require(receipt.lines.first { $0.text.contains("TIMELINE CONTINUES") })
        #expect(nextRow.rect.minY < 60, "An absent interstitial must not retain its populated cell height")
      }
    }
  }

  @Test("Discovery loading and empty states remain readable with recovery actions")
  func discoveryLoadingAndEmptyStates() async throws {
    let appState = try await makeAppState()
    for isLoading in [true, false] {
      try await withHost(
        VStack(spacing: 28) {
          TrendingVideosSection(videos: [], isLoading: isLoading, onSelectPost: { _ in }, onSeeAll: {})
          SuggestedProfilesSection(
            profiles: [], isLoading: isLoading, onSelectCategory: { _ in },
            onSelectProfile: { _ in }, onRefresh: {}
          )
        }, appState: appState, size: CGSize(width: 320, height: 1000),
        scheme: isLoading ? .light : .dark, typeSize: .accessibility1
      ) { host in
        _ = try await host.capture(
          "discovery-\(isLoading ? "loading" : "empty")",
          requiring: isLoading
            ? ["Loading video previews", "Loading accounts", "Open The Vids"]
            : ["No video previews", "No suggestions right now", "Open The Vids", "Try Again"]
        )
      }
    }
    // An initial failure may leave empty arrays; a failed refresh can retain data.
    // These fixtures render the empty state without injecting a transport failure.
    try await withHost(
      TrendingTopicsSection(topics: [], onSelect: { _ in }, onSeeAll: {}),
      appState: appState, size: CGSize(width: 320, height: 480), typeSize: .accessibility1
    ) { host in
      let receipt = try await host.capture("discovery-topics-empty", requiring: ["No trending topics", "Pull to refresh"])
      #expect(!receipt.contains("Loading"))
    }
  }

  @Test("Complete Search discovery retains its content and all navigation tools when resized")
  func discoveryCompositionAcrossSizes() async throws {
    let appState = try await makeAppState()
    let model = RefinedSearchViewModel(appState: appState)
    model.savedSearches = []
    model.recentSearchEntries = []
    model.recentProfileSearches = []
    model.showExploreInterestsCard = false
    model.trendingTopics = [makeTopic()]
    model.trendingVideos = [try makeVideo()]
    model.suggestedProfiles = [try makeSuggestedProfile()]
    let discovery = DiscoveryView(
      viewModel: model, path: .constant(NavigationPath()),
      showAllTrendingTopics: .constant(false), showAllSavedSearches: .constant(false),
      showSuggestedProfiles: .constant(false), showAddFeedSheet: .constant(false), onQueryLoaded: { _ in }
    )
    // Insets are synthetic additions to this test window's measured UIKit safe area.
    // Swapping each edge checks asymmetry without claiming a natural device pose.
    let cases: [(String, CGSize, ColorScheme, UIEdgeInsets?)] = [
      ("narrow-light", CGSize(width: 320, height: 800), .light, nil),
      ("wide-dark", CGSize(width: 768, height: 650), .dark, nil),
      ("short-light", CGSize(width: 600, height: 340), .light, nil),
      ("square-light", CGSize(width: 500, height: 500), .light, nil),
      ("square-insets-leading", CGSize(width: 500, height: 500), .light,
        UIEdgeInsets(top: 11, left: 37, bottom: 23, right: 7)),
      ("square-insets-trailing", CGSize(width: 500, height: 500), .dark,
        UIEdgeInsets(top: 23, left: 7, bottom: 11, right: 37))
    ]
    for (name, size, scheme, additionalInsets) in cases {
      try await withHost(discovery, appState: appState, size: size, scheme: scheme,
        additionalSafeAreaInsets: additionalInsets
      ) { host in
        let topReceipt = try await host.capture("search-\(name)-top", requiring: ["Trending", "Moon Garden"])
        if additionalInsets != nil {
          let topic = try #require(topReceipt.lines.first { $0.text.contains("Moon Garden") })
          #expect(host.actualSafeAreaFrame.contains(topic.rect), "Topic text must remain inside the actual asymmetric safe area")
        }
        let scrollView = try #require(host.verticalScrollView)
        let maximumOffset = max(-scrollView.adjustedContentInset.top,
          scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        #expect(maximumOffset > 0, "The complete discovery screen must retain scroll access to its lower sections")
        var collected = ""
        let step = max(100, scrollView.bounds.height * 0.7)
        var offset: CGFloat = 0
        var page = 0
        while offset <= maximumOffset {
          scrollView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
          let receipt = try await host.capture("search-\(name)-scroll-\(page)")
          collected += "\n" + receipt.transcript
          if offset == maximumOffset { break }
          offset = min(offset + step, maximumOffset)
          page += 1
        }
        for label in ["Open The Vids", "River Films", "Suggested Accounts", "Find Friends", "Invite Friends", "Scan QR", "Custom Feeds", "All Trending Topics"] {
          #expect(PresentationHost.normalized(collected).contains(PresentationHost.normalized(label)), "Missing reachable discovery feature: \(label); see scroll receipts")
        }
      }
    }
  }

  @Test("Search tools fit large text without clipping the action titles")
  func discoveryToolsAtLargeText() async throws {
    let appState = try await makeAppState()
    try await withHost(
      DiscoveryToolsSection(onFindFriends: {}, onInviteFriends: {}, onScanQR: {}, onExploreFeeds: {}, onOpenTopics: {}),
      appState: appState, size: CGSize(width: 320, height: 1500), scheme: .dark, typeSize: .accessibility1
    ) { host in
      _ = try await host.capture("search-tools-larger-text", requiring: ["Find Friends", "Invite Friends", "Scan QR", "Custom Feeds", "All Trending Topics"])
    }
  }

  private func trending(_ content: TrendingFeedContent, topics: Bool, videos: Bool) -> some View {
    TrendingFeedPresentation(
      content: content, showTopics: topics, showVideos: videos, onSelectTopic: { _ in },
      onSelectPost: { _ in }, onOpenVideos: {}, onHideTopics: {}, onHideVideos: {}
    )
  }

  private func makeAppState() async throws -> AppState {
    let client = await ATProtoClient(baseURL: try #require(URL(string: "https://example.invalid")))
    return AppState(userDID: "did:plc:feedssearchpresentationfixture", client: client, regulatoryChecker: PresentationAgeChecker())
  }

  private func makeTopic() -> AppBskyUnspeccedDefs.TrendView {
    .init(topic: "moon-garden", displayName: "Moon Garden", description: "A community conversation about plants and astronomy.",
      link: "/profile/trending.example.invalid/feed/moon-garden", startedAt: ATProtocolDate(date: Date()),
      postCount: 1200, status: "hot", category: "science", actors: [])
  }

  private func makeVideo(authorName: String = "River Films") throws -> AppBskyFeedDefs.FeedViewPost {
    let cid = CID.fromDAGCBOR(Data("fixture-video".utf8))
    let author = AppBskyActorDefs.ProfileViewBasic(
      did: try DID(didString: "did:plc:presentationauthor"), handle: try Handle(handleString: "river.example.invalid"),
      displayName: authorName, pronouns: nil, avatar: nil, associated: nil, viewer: nil,
      labels: nil, createdAt: nil, verification: nil, status: nil, debug: nil)
    let post = AppBskyFeedDefs.PostView(
      uri: try ATProtocolURI(uriString: "at://did:plc:presentationauthor/app.bsky.feed.post/video"),
      cid: cid, author: author,
      record: .knownType(AppBskyFeedPost(text: "Fixture video", createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_749_000_000)))),
      embed: .appBskyEmbedVideoView(.init(cid: cid, playlist: URI(uriString: "file:///nonexistent/fixture.m3u8"),
        thumbnail: nil, alt: "A river through a garden", aspectRatio: .init(width: 9, height: 16))),
      bookmarkCount: nil, replyCount: 0, repostCount: 0, likeCount: 0, quoteCount: nil,
      indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_749_000_100)), viewer: nil,
      labels: nil, threadgate: nil, debug: nil)
    return .init(post: post, reply: nil, reason: nil, feedContext: nil, reqId: nil)
  }

  private func makeSuggestedProfile() throws -> AppBskyActorDefs.ProfileView {
    .init(did: try DID(didString: "did:plc:presentationgardener"), handle: try Handle(handleString: "garden.example.invalid"),
      displayName: "Garden Society", pronouns: nil, description: "Growing plants and sharing discoveries.", avatar: nil,
      associated: nil, indexedAt: nil, createdAt: nil, viewer: nil, labels: nil, verification: nil, status: nil, debug: nil)
  }

  private func withHost<Content: View>(
    _ content: Content, appState: AppState, size: CGSize, scheme: ColorScheme = .light,
    typeSize: DynamicTypeSize = .large, additionalSafeAreaInsets: UIEdgeInsets? = nil,
    body: (PresentationHost) async throws -> Void
  ) async throws {
    let previousScheme = appState.themeManager.colorSchemeOverride
    appState.themeManager.colorSchemeOverride = scheme
    defer { appState.themeManager.colorSchemeOverride = previousScheme }
    let host = try PresentationHost(content: content.environment(appState).fontManager(appState.fontManager).environment(\.colorScheme, scheme)
      .environment(\.dynamicTypeSize, typeSize).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(scheme == .light ? Color.white : Color.black)
      .ignoresSafeArea(.container, edges: additionalSafeAreaInsets == nil ? .all : []), size: size, scheme: scheme)
    defer { host.close() }
    if let additionalSafeAreaInsets {
      try await host.applySyntheticSafeAreaInsets(additionalSafeAreaInsets)
    }
    try await body(host)
  }
}

private struct PresentationAgeChecker: AgeRegulatoryChecking {
  func preflight() async -> PlatformAgeSignal {
    .init(requirement: .none, ageBand: nil, significantChangeConsentRequired: false)
  }

  @MainActor
  func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
}

/// Composes the extracted production pieces; no app preference, account or profile requests.
private struct FeedsHeaderFixture: View {
  let size: CGSize
  @Namespace private var glassNamespace

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
      FeedBannerArtwork(topInset: 59) {
        Canvas { context, canvasSize in
          for index in 0..<18 {
            let rect = CGRect(x: CGFloat(index) * canvasSize.width / 18, y: 0, width: canvasSize.width / 18 + 1, height: canvasSize.height)
            context.fill(Path(rect), with: .color(index.isMultiple(of: 2) ? .yellow : .purple))
          }
        }
      }
      .frame(height: FeedsStartPageLayoutMetrics.bannerHeight(viewportSize: size) + 59)
      FeedsAccountIdentity(displayName: "Alexandra Chen", handle: "alex.example", avatarSize: 54) {
        Circle().fill(Color.teal).overlay(Text("AC").foregroundStyle(.white))
      }
      .padding(.horizontal, 24)
      FeedsDefaultFeedLabel(name: "Following", isSelected: false) {
        Image(systemName: "person.2.fill").frame(width: 36, height: 36)
      }
      .padding(12)
      .modifier(LaunchpadGlassChip(cornerRadius: 12, isEnabled: true))
      .padding(.horizontal, 16)
      if size.height > 400 {
        HStack(spacing: 12) {
          gridLabel("Garden", selected: true)
          gridLabel("Science", selected: false)
        }
      }
      }
    }
  }

  private func gridLabel(_ title: String, selected: Bool) -> some View {
    FeedsGridFeedLabel(title: title, isSelected: selected, iconSize: 72, itemWidth: 110) {
      RoundedRectangle(cornerRadius: 12).fill(selected ? Color.green.opacity(0.6) : Color.indigo.opacity(0.6))
        .overlay(Image(systemName: selected ? "leaf.fill" : "atom").foregroundStyle(.white))
    }
    .modifier(LaunchpadSelectionGlass(isSelected: selected, isDropTarget: !selected,
      cornerRadius: 12, namespace: glassNamespace, isEnabled: true))
  }
}

@MainActor
private final class PresentationHost {
  struct Line {
    let text: String
    let rect: CGRect
  }

  struct Receipt {
    let lines: [Line]
    var transcript: String { lines.map(\.text).joined(separator: "\n") }
    func contains(_ text: String) -> Bool {
      PresentationHost.normalized(transcript).contains(PresentationHost.normalized(text))
    }
  }

  let window: UIWindow
  let controller: UIViewController
  private let requestedSize: CGSize
  private var requestedAdditionalSafeAreaInsets: UIEdgeInsets?
  private var baselineSafeAreaInsets = UIEdgeInsets.zero
  private weak var previousKeyWindow: UIWindow?

  init<Content: View>(content: Content, size: CGSize, scheme: ColorScheme) throws {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    requestedSize = size
    previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
    window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: size)
    window.overrideUserInterfaceStyle = scheme == .light ? .light : .dark
    controller = UIHostingController(rootView: content)
    controller.view.frame = window.bounds
    window.rootViewController = controller
    window.isHidden = false
  }

  var verticalScrollView: UIScrollView? {
    allViews(controller.view).compactMap { $0 as? UIScrollView }
      .filter { $0.contentSize.height > $0.bounds.height }
      .max { $0.bounds.height < $1.bounds.height }
  }

  var actualSafeAreaFrame: CGRect { controller.view.safeAreaLayoutGuide.layoutFrame }

  func applySyntheticSafeAreaInsets(_ insets: UIEdgeInsets) async throws {
    try await Task.sleep(for: .milliseconds(80))
    window.layoutIfNeeded()
    controller.view.layoutIfNeeded()
    baselineSafeAreaInsets = controller.view.safeAreaInsets
    requestedAdditionalSafeAreaInsets = insets
    controller.additionalSafeAreaInsets = insets
    controller.view.setNeedsLayout()
  }

  func close() {
    let becameKey = window.isKeyWindow
    window.isHidden = true
    window.rootViewController = nil
    if becameKey { previousKeyWindow?.makeKey() }
  }

  func capture(_ name: String, requiring expected: [String] = []) async throws -> Receipt {
    let deadline = ContinuousClock.now + .seconds(3)
    var png = Data()
    var receipt = Receipt(lines: [])
    var didDraw = false
    var errorText = ""
    repeat {
      try await Task.sleep(for: .milliseconds(80))
      window.layoutIfNeeded()
      controller.view.layoutIfNeeded()
      let format = UIGraphicsImageRendererFormat()
      format.scale = 3
      format.opaque = true
      let image = UIGraphicsImageRenderer(bounds: controller.view.bounds, format: format).image { context in
        (window.overrideUserInterfaceStyle == .dark ? UIColor.black : UIColor.white).setFill()
        context.fill(controller.view.bounds)
        didDraw = controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
      }
      png = image.pngData() ?? Data()
      do {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: try #require(image.cgImage), options: [:]).perform([request])
        receipt = Receipt(lines: (request.results ?? []).compactMap { observation in
          guard let text = observation.topCandidates(1).first?.string else { return nil }
          let bounds = observation.boundingBox
          return Line(text: text, rect: CGRect(x: bounds.minX * image.size.width,
            y: (1 - bounds.maxY) * image.size.height, width: bounds.width * image.size.width, height: bounds.height * image.size.height))
        })
      } catch { errorText = String(describing: error) }
      if didDraw && expected.allSatisfy({ receipt.contains($0) }) { break }
    } while ContinuousClock.now < deadline

    Attachment.record(Array(png), named: "\(name).png")
    let details = "requestedSize=\(requestedSize), actualWindow=\(window.bounds), renderedView=\(controller.view.bounds), scale=3, drawHierarchy=\(didDraw)\n"
      + "syntheticAdditionalInsets=\(String(describing: requestedAdditionalSafeAreaInsets)), baselineInsets=\(baselineSafeAreaInsets), actualInsets=\(controller.view.safeAreaInsets), actualSafeAreaFrame=\(actualSafeAreaFrame)\n"
      + "error=\(errorText)\n" + receipt.lines.map { "\($0.rect): \($0.text)" }.joined(separator: "\n")
    Attachment.record(Array(details.utf8), named: "\(name)-geometry-ocr.txt")
    #expect(!png.isEmpty && didDraw, "UIKit must produce a real rendered image")
    #expect(abs(requestedSize.width - controller.view.bounds.width) < 1, "The receiving width must equal the requested fixture width")
    #expect(abs(requestedSize.height - controller.view.bounds.height) < 1, "The receiving height must equal the requested fixture height")
    if let requested = requestedAdditionalSafeAreaInsets {
      let actual = controller.view.safeAreaInsets
      for (edge, delta, expected) in [
        ("top", actual.top - baselineSafeAreaInsets.top, requested.top),
        ("left", actual.left - baselineSafeAreaInsets.left, requested.left),
        ("bottom", actual.bottom - baselineSafeAreaInsets.bottom, requested.bottom),
        ("right", actual.right - baselineSafeAreaInsets.right, requested.right)
      ] {
        #expect(abs(delta - expected) < 1, "The host must apply the requested additional \(edge) inset independently")
      }
      let expectedFrame = controller.view.bounds.inset(by: actual)
      #expect(abs(actualSafeAreaFrame.width - expectedFrame.width) < 1)
      #expect(abs(actualSafeAreaFrame.height - expectedFrame.height) < 1)
      #expect(abs(actualSafeAreaFrame.minX - expectedFrame.minX) < 1)
      #expect(abs(actualSafeAreaFrame.minY - expectedFrame.minY) < 1)
    }
    for text in expected {
      #expect(receipt.contains(text), "Expected complete visible text '\(text)'; see \(name) receipts")
    }
    for line in receipt.lines {
      #expect(line.rect.minX >= 0 && line.rect.maxX <= controller.view.bounds.width + 1)
      #expect(line.rect.minY >= 0 && line.rect.maxY <= controller.view.bounds.height + 1)
    }
    return receipt
  }

  private func allViews(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(allViews)
  }

  nonisolated static func normalized(_ text: String) -> String {
    text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
#endif
