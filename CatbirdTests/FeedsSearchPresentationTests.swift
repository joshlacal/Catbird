#if os(iOS)
import Foundation
@testable import Petrel
import SwiftData
import SwiftUI
import Testing
import UIKit
import Vision

@testable import Catbird

/// UIKit-hosted production components, with local data and no discovery lifecycle loads.
/// The opt-in transport fixture exercises individual discovery fetch failures through Petrel.
/// Full Dynamic Type evidence requires separate fresh launches with the simulator's system
/// category matching CATBIRD_PRESENTATION_SYSTEM_CATEGORY; environment-only cases are limited.
/// These receipts qualify presentation; they do not qualify authenticated actions or the
/// FeedsStartPage preference-loading lifecycle, account switching, or a physical device.
@Suite("Feeds and Search presentation", .serialized)
@MainActor
struct FeedsSearchPresentationTests {
  @Test("Search shows a long trending description through its final words and grows the row")
  func trendingSearchDescriptionWrapsFully() async throws {
    let appState = try await makeAppState()
    let description = String(repeating: "People are sharing photographs of community gardens and discussing the plants they grow together. ", count: 5)
      + "EVERGREEN FINISH"
    for (name, width, scheme, typeSize, direction) in [
      ("narrow-light", CGFloat(320), ColorScheme.light, DynamicTypeSize.large, LayoutDirection.leftToRight),
      ("wide-dark", CGFloat(680), ColorScheme.dark, DynamicTypeSize.large, LayoutDirection.leftToRight),
      ("narrow-large", CGFloat(320), ColorScheme.light, DynamicTypeSize.accessibility1, LayoutDirection.leftToRight),
      ("rtl-large", CGFloat(320), ColorScheme.dark, DynamicTypeSize.accessibility1, LayoutDirection.rightToLeft),
    ] {
      var shortRowBottom: CGFloat?
      for (stage, text) in [("short", "A brief garden summary."), ("long", description)] {
        try await withHost(
          VStack(alignment: .leading, spacing: 0) {
            TrendingTopicsSection(topics: [makeTopic(description: text)], onSelect: { _ in }, onSeeAll: {})
            Text("NEXT TOPIC").padding(16)
          }.environment(\.layoutDirection, direction),
          appState: appState, size: CGSize(width: width, height: 1800), scheme: scheme, typeSize: typeSize
        ) { host in
          let required = stage == "long" ? ["EVERGREEN", "FINISH", "NEXT TOPIC"] : ["NEXT TOPIC"]
          let receipt = try await host.capture("trending-description-\(name)-\(stage)", requiring: required)
          let next = try #require(receipt.lines.first { $0.text.contains("NEXT TOPIC") })
          if stage == "short" {
            shortRowBottom = next.rect.minY
          } else {
            let tail = try #require(receipt.lines.last { $0.text.contains("FINISH") })
            let metadata = try #require(receipt.lines.first { $0.text.contains("posts") })
            #expect(tail.rect.maxY < metadata.rect.minY, "Metadata must follow the complete rendered description")
            #expect(metadata.rect.maxY < next.rect.minY, "The next item must follow the expanded row")
            #expect(next.rect.minY > (try #require(shortRowBottom)) + 40, "Long descriptions must increase intrinsic row height")
          }
        }
      }
    }
  }

  @Test("Account identity stays readable below busy artwork across constrained containers")
  func accountHeaderAcrossSizes() async throws {
    let appState = try await makeAppState()
    let cases: [(String, CGSize, ColorScheme, DynamicTypeSize)] = [
      ("narrow-light", CGSize(width: 320, height: 600), .light, .large),
      ("wide-dark", CGSize(width: 680, height: 500), .dark, .large),
      ("square-light", CGSize(width: 500, height: 500), .light, .large),
      ("short-light", CGSize(width: 430, height: 320), .light, .xxLarge),
      ("narrow-tall-dark", CGSize(width: 320, height: 760), .dark, .accessibility1),
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
        if let defaultLabel = receipt.lines.first(where: { $0.text.contains("Default Feed") }) {
          #expect(identity.rect.maxY < defaultLabel.rect.minY, "The default control must not overlap account identity")
        }
        if let scroll = host.verticalScrollView {
          scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
        }
        _ = try await host.capture("feeds-header-\(name)-controls", requiring: ["Default Feed", "Following"])
      }
    }
  }

  @Test("Video bylines honor app font size and line spacing as well as Dynamic Type")
  func videoBylinesWithAppFontPreferences() async throws {
    let appState = try await makeAppState()
    appState.fontManager.fontStyle = "system"
    appState.fontManager.fontSize = "extraLarge"
    appState.fontManager.lineSpacing = "relaxed"
    appState.fontManager.dynamicTypeEnabled = true
    appState.fontManager.maxDynamicTypeSize = "accessibility1"
    let video = try makeVideo(authorName: "River Garden Films")
    let systemCategory = try PresentationSystemCategory.fromEnvironment()
    let typeSizes = systemCategory.map { [$0.dynamicTypeSize] } ?? [.large, .accessibility1]
    for typeSize in typeSizes {
      try await withHost(
        VStack(alignment: .leading, spacing: 0) {
          TrendingVideosSection(videos: [video], presentation: .timeline,
            onSelectPost: { _ in }, onSeeAll: {})
          Text("NEXT POST").padding(16)
        }, appState: appState, size: CGSize(width: 320, height: 760), typeSize: typeSize
      ) { host in
        let receipt = try await host.capture("video-byline-app-font-\(typeSize)",
          requiring: ["River Garden Films", "NEXT POST"], measuringWord: "Films")
        let lastAuthorLine = try #require(receipt.lines.first { $0.text.contains("Films") })
        let nextPost = try #require(receipt.lines.first { $0.text.contains("NEXT POST") })
        #expect(lastAuthorLine.rect.maxY < nextPost.rect.minY, "The full byline must fit above the next timeline item")
        let glyph = try #require(receipt.measuredWordRect, "Measure the same rendered word across fresh system-category runs")
        let measurement: [String: Any] = [
          "byline": "River Garden Films", "measuredWord": "Films", "units": "points",
          "glyphRect": ["x": glyph.minX, "y": glyph.minY, "width": glyph.width, "height": glyph.height],
          "typographyContext": host.typographyContext,
          "fontManagerSystemCategory": appState.fontManager.currentContentSizeCategory.rawValue,
          "fontPreferences": ["style": appState.fontManager.fontStyle, "size": appState.fontManager.fontSize,
            "lineSpacing": appState.fontManager.lineSpacing, "letterSpacing": appState.fontManager.letterSpacing,
            "dynamicTypeEnabled": appState.fontManager.dynamicTypeEnabled,
            "maximumDynamicTypeSize": appState.fontManager.maxDynamicTypeSize]
        ]
        Attachment.record(Array(try JSONSerialization.data(withJSONObject: measurement, options: [.sortedKeys, .prettyPrinted])),
          named: "video-byline-font-scale-\(systemCategory?.rawValue ?? String(describing: typeSize)).json")
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

  @Test("Trending topics and complete counts fit the receiving timeline width")
  func trendingTimelineAcrossSizes() async throws {
    let appState = try await makeTrendingAppState()
    let content = TrendingFeedContent(trends: [makeTopic()], videos: [try makeVideo()])
    for (name, width, scheme, typeSize, horizontalInset, direction) in [
      ("narrow-light", CGFloat(320), ColorScheme.light, DynamicTypeSize.large, CGFloat(0), LayoutDirection.leftToRight),
      ("wide-dark", CGFloat(680), ColorScheme.dark, DynamicTypeSize.large, CGFloat(0), LayoutDirection.leftToRight),
      ("narrow-dark", CGFloat(320), ColorScheme.dark, DynamicTypeSize.accessibility1, CGFloat(0), LayoutDirection.leftToRight),
      ("inset-narrow-dark", CGFloat(320), ColorScheme.dark, DynamicTypeSize.accessibility1, CGFloat(20), LayoutDirection.leftToRight),
      ("narrow-rtl", CGFloat(320), ColorScheme.dark, DynamicTypeSize.accessibility1, CGFloat(0), LayoutDirection.rightToLeft),
    ] {
      try await withHost(
        trending(content, topics: true, videos: true, appState: appState)
          .padding(.horizontal, horizontalInset)
          .environment(\.layoutDirection, direction), appState: appState,
        size: CGSize(width: width, height: 850), scheme: scheme, typeSize: typeSize
      ) { host in
        let receipt = try await host.capture(
          "trending-timeline-\(name)",
          requiring: ["Trending on Bluesky", "Moon Garden", "astronomy", "1.2K posts", "Trending Videos", "Open The Vids", "River Films"],
          measuringWord: "posts", measuringInkFor: .init(readings: ["1.2K posts"], foreground: .neutral)
        )
        // The constrained title may wrap; order from its final rendered line.
        let topic = try #require(receipt.lines.last { $0.text.contains("Garden") })
        let description = try #require(receipt.lines.first { $0.text.contains("astronomy") })
        let author = try #require(receipt.lines.first { $0.text.contains("River Films") })
        let countTail = try #require(receipt.measuredWordRect, "The full final word of the count must be rendered")
        let countInk = try #require(receipt.measuredTextInk, "The complete count needs unambiguous painted glyph bounds")
        let videoHeading = try #require(receipt.lines.first { $0.text.contains("Trending Videos") })
        // Vision identifies the complete count, but its inferred boxes can extend
        // beyond the painted glyphs. Check actual ink against unchanged padding.
        let contentBounds = host.actualSafeAreaFrame.insetBy(
          dx: horizontalInset + 16 + DesignTokens.Spacing.base, dy: 0)
        #expect(countInk.rect.minX >= contentBounds.minX - 1 && countInk.rect.maxX <= contentBounds.maxX + 1,
          "The full count must fit inside both carousel and card padding, including inset and RTL containers")
        #expect(countTail.minY > description.rect.maxY && countTail.maxY < videoHeading.rect.minY,
          "The complete count must follow the description and precede the video section")
        #expect(description.rect.minY > topic.rect.maxY, "The description must follow the topic heading")
        #expect(author.rect.minY > description.rect.maxY, "Video byline must remain below the topic description")
      }
    }
  }

  @Test("Timeline descriptions omit missing and markup-only text without a reserved gap")
  func trendingTimelineDescriptionAvailability() async throws {
    let appState = try await makeTrendingAppState()
    var emptyBottom: CGFloat?
    let cases: [(String, String?)] = [
      ("missing", nil), ("blank", "  "), ("markup", "<p> \n </p>"),
      ("supplied", "<p>A brief garden summary.</p>"),
      ("long", "<p>A long garden summary about night-blooming plants, the moons that rise over them, and the astronomers who visit after dark to watch both through borrowed telescopes.</p>")
    ]
    for (name, description) in cases {
      let content = TrendingFeedContent(trends: [makeTopic(description: description)])
      try await withHost(
        VStack(alignment: .leading, spacing: 0) {
          trending(content, topics: true, videos: false, appState: appState)
          Text("TIMELINE CONTINUES").padding(16)
        }, appState: appState, size: CGSize(width: 320, height: 900)
      ) { host in
        let required = name == "supplied"
          ? ["brief garden summary", "TIMELINE CONTINUES"] : ["Moon Garden", "TIMELINE CONTINUES"]
        let receipt = try await host.capture("timeline-description-\(name)", requiring: required)
        let next = try #require(receipt.lines.first { $0.text.contains("TIMELINE CONTINUES") })
        if name == "missing" {
          emptyBottom = next.rect.minY
        } else if name == "supplied" {
          // Two lines fit beside the 86pt media fan, so the card keeps its height.
          let summary = try #require(receipt.lines.first { $0.text.contains("summary") })
          #expect(summary.rect.maxY < next.rect.minY, "Supplied text must be visible above the next row")
          #expect(abs(next.rect.minY - (try #require(emptyBottom))) <= 1,
            "A description that fits beside the media fan must not grow the card")
        } else if name == "long" {
          #expect(next.rect.minY > (try #require(emptyBottom)) + 10,
            "A description taller than the media fan must grow the card and move the next row")
        } else {
          #expect(abs(next.rect.minY - (try #require(emptyBottom))) <= 1,
            "Empty or markup-only descriptions must not reserve a phantom row")
        }
      }
    }
  }

  @Test("Late media and unavailable images keep the following timeline row in place")
  func trendingArtworkKeepsReservedGeometry() async throws {
    let appState = try await makeAppState()
    let state = TrendingArtworkGeometryState()
    let url = URL(fileURLWithPath: "/nonexistent/trending-preview-fixture.png")
    let stages: [(String, TrendingTopicPreview)] = [
      ("empty", .init()),
      ("one-unavailable", .init(media: [.init(id: "one", url: url)])),
      ("three-unavailable", .init(media: (0..<3).map { .init(id: "card-\($0)", url: url) },
        participants: (0..<3).map { .init(id: "author-\($0)", avatar: url) })),
      ("moderated-back-to-empty", .init()),
    ]
    for showParticipants in [false, true] {
      state.preview = .init()
      try await withHost(
        TrendingArtworkGeometryFixture(state: state, showParticipants: showParticipants),
        appState: appState, size: CGSize(width: 320, height: 500)
      ) { host in
        var baseline: CGFloat?
        for (name, preview) in stages {
          state.preview = preview
          let receipt = try await host.capture("trending-reserved-\(showParticipants)-\(name)",
            requiring: ["TITLE STAYS", "TIMELINE CONTINUES"])
          let next = try #require(receipt.lines.first { $0.text.contains("TIMELINE CONTINUES") })
          if let baseline {
            #expect(abs(next.rect.minY - baseline) <= 1, "Late media and fallback must not change the next row's position")
          } else {
            baseline = next.rect.minY
          }
        }
      }
    }
  }

  @Test("Category marks and wide Search titles fit narrow, dark, large-text and RTL containers")
  func trendingCategoryHeadingAcrossLayouts() async throws {
    let appState = try await makeAppState()
    for (name, scheme, typeSize, direction) in [
      ("light", ColorScheme.light, DynamicTypeSize.large, LayoutDirection.leftToRight),
      ("dark", ColorScheme.dark, DynamicTypeSize.large, LayoutDirection.leftToRight),
      ("rtl-large", ColorScheme.dark, DynamicTypeSize.accessibility1, LayoutDirection.rightToLeft),
    ] {
      try await withHost(
        VStack(alignment: .leading, spacing: 20) {
          TrendingTopicHeading(title: "Moon Garden", category: "science")
          TrendingTopicHeading(title: "Community Sports", category: "sports")
          Text("TIMELINE CONTINUES")
        }.padding(16).environment(\.layoutDirection, direction),
        appState: appState, size: CGSize(width: 320, height: 760), scheme: scheme, typeSize: typeSize
      ) { host in
        _ = try await host.capture("trending-category-\(name)",
          requiring: ["Moon Garden", "Community Sports", "Science", "Sports", "TIMELINE CONTINUES"])
      }
    }
  }

  @Test("Empty or hidden interstitials leave the next timeline row immediately available")
  func hiddenTrendingDoesNotReserveAVisibleCell() async throws {
    let appState = try await makeTrendingAppState()
    let loaded = TrendingFeedContent(trends: [makeTopic()], videos: [try makeVideo()])
    for (name, content, topics, videos) in [
      ("empty", TrendingFeedContent(), true, true),
      ("preferences-hidden", loaded, false, false),
    ] {
      try await withHost(
        VStack(alignment: .leading, spacing: 0) {
          trending(content, topics: topics, videos: videos, appState: appState)
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
    // This case covers empty presentation independently of the opt-in transport fixture.
    try await withHost(
      TrendingTopicsSection(topics: [], onSelect: { _ in }, onSeeAll: {}),
      appState: appState, size: CGSize(width: 320, height: 480), typeSize: .accessibility1
    ) { host in
      let receipt = try await host.capture("discovery-topics-empty", requiring: ["No trending topics", "Pull to refresh"])
      #expect(!receipt.contains("Loading"))
    }
  }

  // Petrel's protocol hook is process-global; .serialized coordinates only this suite.
  // Enable only in a focused run containing this suite and tests that do not use network
  // hooks: CATBIRD_PRESENTATION_TRANSPORT_FIXTURE=1. Broad test runs skip this case.
  @Test("Discovery transport failures show recovery and preserve same-category refresh content",
    .enabled(if: ProcessInfo.processInfo.environment["CATBIRD_PRESENTATION_TRANSPORT_FIXTURE"] == "1"))
  func discoveryTransportFailurePresentation() async throws {
    DiscoveryFailureURLProtocol.reset()
    defer { DiscoveryFailureURLProtocol.reset() }
    let appState = try await makeTransportFailureAppState()
    let previousShowVideos = appState.appSettings.showTrendingVideos
    appState.appSettings.showTrendingVideos = true
    defer { appState.appSettings.showTrendingVideos = previousShowVideos }
    try #require(appState.appSettings.showTrendingVideos)
    let model = RefinedSearchViewModel(appState: appState)
    let topic = makeTopic()
    let video = try makeVideo()
    let profile = try makeSuggestedProfile()

    for isRefresh in [false, true] {
      if isRefresh {
        model.trendingTopics = [topic]
        model.trendingVideos = [video]
        model.suggestedProfiles = [profile]
      }
      await model.fetchTrendingTopics(client: appState.client, displayScale: 3)
      await model.fetchSuggestedUsers(category: nil, client: appState.client)
      await model.fetchTrendingVideos(client: appState.client)

      let urls = DiscoveryFailureURLProtocol.urls
      for endpoint in ["app.bsky.unspecced.getTrends", "app.bsky.unspecced.getSuggestedUsers", "app.bsky.feed.getFeed"] {
        #expect(urls.filter { $0.path == "/xrpc/\(endpoint)" }.count == (isRefresh ? 2 : 1),
          "Each fetch must reach the injected failure once, without retries; a second topics request also proves its loading guard reset")
      }
      #expect(urls.allSatisfy { $0.host == "127.0.0.1" })
      #expect(!model.isSuggestedProfilesLoading)
      #expect(!model.isTrendingVideosLoading)
      #expect(model.selectedSuggestedCategory == nil)
      #expect(model.trendingTopics == (isRefresh ? [topic] : []))
      #expect(model.trendingVideos == (isRefresh ? [video] : []))
      #expect(model.suggestedProfiles == (isRefresh ? [profile] : []))
      let phase = isRefresh ? "refresh-retained" : "first-load-empty"
      Attachment.record(Array(urls.map(\.absoluteString).joined(separator: "\n").utf8),
        named: "discovery-transport-\(phase)-requests.txt")
      try await withHost(
        discoveryFailurePresentation(model), appState: appState,
        size: CGSize(width: 320, height: 1400), scheme: .dark
      ) { host in
        let receipt = try await host.capture("discovery-transport-\(phase)", requiring: isRefresh
          ? ["Moon Garden", "River Films", "Garden Society", "Open The Vids"]
          : ["No trending topics", "Pull to refresh", "No video previews", "No suggestions right now", "Try Again", "Open The Vids"])
        #expect(!receipt.contains("Loading"))
      }
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

  @Test("Search tools keep action titles readable in a narrow container")
  func discoveryToolsAtLargeText() async throws {
    let appState = try await makeAppState()
    try await withHost(
      DiscoveryToolsSection(onFindFriends: {}, onInviteFriends: {}, onScanQR: {}, onExploreFeeds: {}, onOpenTopics: {}),
      appState: appState, size: CGSize(width: 320, height: 1500), scheme: .dark, typeSize: .accessibility1
    ) { host in
      _ = try await host.capture("search-tools-narrow", requiring: ["Find Friends", "Invite Friends", "Scan QR", "Custom Feeds", "All Trending Topics"])
    }
  }

  @Test("Saved searches and interests keep their content and actions reachable across widths")
  func savedSearchesAndInterestsAcrossSizes() async throws {
    let appState = try await makeAppState()
    // The native walk below reads SwiftUI's accessibility tree, which the hosting view vends only
    // while app accessibility is on.
    let restoreAccessibility = AppAccessibility.enable()
    defer { restoreAccessibility() }
    let searches = [
      SavedSearch(name: "Garden Journal", query: "gardening", filters: SearchFilterState(hasMedia: true)),
      SavedSearch(name: "Night Sky", query: "astronomy", filters: SearchFilterState()),
      SavedSearch(name: "River Walks", query: "rivers", filters: SearchFilterState()),
      SavedSearch(name: "Local Trails", query: "trails", filters: SearchFilterState())
    ]
    var nativeResults: [(name: String, passed: Bool)] = []
    for (name, width) in [("narrow", CGFloat(320)), ("wide", CGFloat(768))] {
      // Retain UIKit's natural safe area so this standalone scroll fixture's first header
      // stays below the native top region; this does not qualify the full Search shell.
      try await withHost(
        ScrollView {
          VStack(alignment: .leading, spacing: 28) {
            SavedSearchesSection(savedSearches: searches,
              onSelect: { _ in }, onDelete: { _ in }, onShowAll: {})
            ExploreInterestsCard(userInterests: ["Science", "Gardening"], onEditInterests: {}, onDismiss: {})
          }
          .padding(.vertical, 16)
        }, appState: appState, size: CGSize(width: width, height: 800), scheme: .dark,
        additionalSafeAreaInsets: .zero
      ) { host in
        // The link draws its chevron after the title (DisclosureLinkLabelStyle), which Vision
        // reads as ">" or "›".
        let allSavedReadings = ["All Saved >", "All Saved ›"]
        let top = try await host.capture("saved-interests-\(name)-top",
          requiring: ["Saved Searches", "Garden Journal"],
          measuringInkFor: .init(readings: allSavedReadings, foreground: .tinted))
        struct NativeSavedButton {
          let traits: UIAccessibilityTraits
          let frame: CGRect
        }
        // Keep dynamically vended elements alive; identity addresses cannot be reused mid-walk.
        var retainedObjects: [ObjectIdentifier: NSObject] = [:]
        var exposedVisits: [ObjectIdentifier: Bool] = [:]
        var records: [[String: Any]] = []
        var buttons: [NativeSavedButton] = []
        var traversalComplete = true
        let maximumNodes = 4096
        let maximumChildren = 512
        let maximumDepth = 64
        let viewport = host.controller.view.bounds
        let safeArea = host.actualSafeAreaFrame
        let screenSpace = host.window.windowScene?.screen.coordinateSpace
        if screenSpace == nil { traversalComplete = false }

        func finite(_ rect: CGRect) -> Bool {
          [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
            .allSatisfy { $0.isFinite } && rect.width > 0 && rect.height > 0
        }

        @MainActor
        func visit(_ object: NSObject, path: String, depth: Int, exposed: Bool) {
          let identity = ObjectIdentifier(object)
          if let previouslyExposed = exposedVisits[identity] {
            records.append(["path": path, "identity": String(describing: identity),
              "revisited": true, "exposedPath": exposed, "previouslyExposed": previouslyExposed])
            // A diagnostic-only visit must not swallow a later actually exposed path.
            if previouslyExposed || !exposed { return }
          }
          guard depth <= maximumDepth,
            retainedObjects[identity] != nil || retainedObjects.count < maximumNodes else {
            traversalComplete = false
            records.append(["path": path, "error": "traversal-bound-exceeded"])
            return
          }
          retainedObjects[identity] = object
          exposedVisits[identity] = exposed
          var ancestors = Set<ObjectIdentifier>()
          var provenance: [[String: Any]] = []
          var ancestor: NSObject? = object
          var hidden = false
          while let current = ancestor {
            guard ancestors.count < maximumDepth,
              ancestors.insert(ObjectIdentifier(current)).inserted else {
              traversalComplete = false
              hidden = true
              provenance.append(["error": "ancestor-cycle-or-bound-exceeded"])
              break
            }
            let view = current as? UIView
            let excluded = current.accessibilityElementsHidden || view?.isHidden == true
              || (view.map { !$0.alpha.isFinite || $0.alpha <= 0.01 } ?? false)
            provenance.append(["class": String(describing: type(of: current)),
              "accessibilityElementsHidden": current.accessibilityElementsHidden,
              "viewHidden": view?.isHidden ?? false, "viewAlpha": String(describing: view?.alpha ?? 1),
              "excluded": excluded])
            hidden = hidden || excluded
            if let view {
              ancestor = view.superview
            } else if let element = current as? UIAccessibilityElement {
              if let container = element.accessibilityContainer {
                ancestor = container as? NSObject
                if ancestor == nil {
                  traversalComplete = false
                  hidden = true
                  provenance.append(["error": "unsupported-accessibility-container"])
                }
              } else {
                ancestor = nil
              }
            } else {
              ancestor = nil
            }
          }
          let screenFrame = object.accessibilityFrame
          let frame: CGRect
          if let screenSpace {
            let windowFrame = host.window.convert(screenFrame, from: screenSpace)
            frame = host.controller.view.convert(windowFrame, from: host.window)
          } else {
            frame = .null
          }
          let label = object.accessibilityLabel
          let traits = object.accessibilityTraits
          records.append(["path": path, "identity": String(describing: identity),
            "class": String(describing: type(of: object)), "label": label.map { $0 as Any } ?? NSNull(),
            "isAccessibilityElement": object.isAccessibilityElement, "traits": String(traits.rawValue),
            "exposedPath": exposed, "excludedByHiddenState": hidden, "hiddenProvenance": provenance,
            "screenFrame": NSCoder.string(for: screenFrame), "hostFrame": NSCoder.string(for: frame)])
          guard !hidden else { return }
          if exposed, object.isAccessibilityElement, label == "All Saved" {
            buttons.append(NativeSavedButton(traits: traits, frame: frame))
          }

          @MainActor
          func visitChildren(_ children: [Any], source: String, exposed: Bool) {
            guard children.count <= maximumChildren else {
              traversalComplete = false
              records.append(["path": path, "error": "child-bound-exceeded", "source": source])
              return
            }
            for (index, child) in children.enumerated() {
              guard let child = child as? NSObject else {
                traversalComplete = false
                records.append(["path": path, "error": "non-NSObject-child", "source": source])
                continue
              }
              visit(child, path: "\(path)/\(source)[\(index)]", depth: depth + 1, exposed: exposed)
            }
          }
          // Accessible elements are leaves. Explicit container children override view children.
          let childPathExposed = exposed && !object.isAccessibilityElement
          let explicitElements = object.accessibilityElements
          var defaultViewChildren = false
          if let elements = explicitElements {
            visitChildren(elements, source: "accessibilityElements", exposed: childPathExposed)
          } else {
            let count = object.accessibilityElementCount()
            defaultViewChildren = count == NSNotFound
            if count != NSNotFound {
              if count < 0 || count > maximumChildren {
                traversalComplete = false
                records.append(["path": path, "error": "invalid-container-count", "count": count])
              } else {
                for index in 0..<count {
                  guard let element = object.accessibilityElement(at: index) as? NSObject else {
                    traversalComplete = false
                    records.append(["path": path, "error": "missing-indexed-child", "index": index])
                    continue
                  }
                  visit(element, path: "\(path)/indexed[\(index)]", depth: depth + 1, exposed: childPathExposed)
                }
              }
            }
          }
          if let view = object as? UIView {
            visitChildren(view.subviews, source: "subviews",
              exposed: childPathExposed && defaultViewChildren)
          }
        }

        visit(host.window, path: "window", depth: 0, exposed: true)
        // Additional view diagnostics cannot bypass the window's exposed container semantics.
        visit(host.controller.view, path: "hostingViewDiagnostics", depth: 0, exposed: false)
        let uniqueButton = buttons.count == 1 ? buttons.first : nil
        let nativePrerequisite = traversalComplete && screenSpace != nil && (uniqueButton.map {
          $0.traits.contains(.button) && !$0.traits.contains(.notEnabled)
            && finite($0.frame) && viewport.contains($0.frame) && safeArea.contains($0.frame)
        } ?? false)
        // Native semantics and geometry must succeed before the observed OCR reading is accepted.
        // Vision's inferred box can extend past the painted glyphs, so the reading's measured ink
        // must lie inside the button's frame.
        let associatedLines = top.lines.filter { line in
          guard nativePrerequisite, let button = uniqueButton, let ink = top.measuredTextInk,
            allSavedReadings.contains(line.text), finite(line.rect),
            viewport.contains(line.rect), safeArea.contains(line.rect) else { return false }
          return button.frame.insetBy(dx: -1, dy: -1).contains(ink.rect)
        }
        let corroborated = nativePrerequisite && associatedLines.count == 1
        let attachment: [String: Any] = [
          "png": "saved-interests-\(name)-top.png", "typography": host.typographyContext,
          "screenCoordinateSpaceAvailable": screenSpace != nil, "traversalComplete": traversalComplete,
          "visitedCount": retainedObjects.count, "nativeMatchCount": buttons.count,
          "nativePrerequisite": nativePrerequisite, "viewport": NSCoder.string(for: viewport),
          "safeArea": NSCoder.string(for: safeArea), "nativeRecords": records,
          "ocrLines": top.lines.map { ["text": $0.text, "rect": NSCoder.string(for: $0.rect)] },
          "associatedLines": associatedLines.map { ["text": $0.text, "rect": NSCoder.string(for: $0.rect)] },
          "measuredInk": top.measuredTextInk.map { NSCoder.string(for: $0.rect) as Any } ?? NSNull(),
          "measuredInkEvidence": top.measuredTextInk.map { $0.evidence as Any } ?? NSNull(),
          "associationTolerancePoints": 1, "corroborated": corroborated
        ]
        do {
          let data = try JSONSerialization.data(withJSONObject: attachment, options: [.prettyPrinted, .sortedKeys])
          Attachment.record(Array(data), named: "saved-interests-\(name)-native-ax-association.json")
          nativeResults.append((name: name, passed: corroborated))
        } catch {
          Attachment.record(Array(String(describing: error).utf8),
            named: "saved-interests-\(name)-native-ax-serialization-error.txt")
          nativeResults.append((name: name, passed: false))
        }
        var collected = top.transcript
        if let scroll = host.verticalScrollView {
          let maximumOffset = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
          var offset: CGFloat = 0
          var page = 0
          while offset < maximumOffset {
            offset = min(offset + max(100, scroll.bounds.height * 0.7), maximumOffset)
            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            let receipt = try await host.capture("saved-interests-\(name)-scroll-\(page)")
            collected += "\n" + receipt.transcript
            page += 1
          }
        }
        for label in ["Garden Journal", "gardening", "Night Sky", "astronomy", "River Walks", "rivers",
          "Your Interests", "Choose the topics you love", "Science", "Gardening", "Edit Interests"] {
          #expect(PresentationHost.normalized(collected).contains(PresentationHost.normalized(label)),
            "Missing reachable saved-search or interest content: \(label); see scroll receipts")
        }
      }
    }
    // Record both widths before asserting the new native/OCR conjunction.
    #expect(nativeResults.count == 2, "Both width diagnostics must be retained")
    for result in nativeResults {
      #expect(result.passed,
        "Require exact unique enabled All Saved native semantics and contained full OCR at \(result.name); see native-ax-association receipt")
    }
  }

}

extension FeedsSearchPresentationTests {
  /// The production timeline interstitial: the native cell the feed registers, sized by its layout.
  private func trending(
    _ content: TrendingFeedContent, topics: Bool, videos: Bool, appState: AppState
  ) -> some View {
    appState.appSettings.showTrendingTopics = topics
    appState.appSettings.showTrendingVideos = videos
    return NativeTrendingInterstitial(
      content: content, appState: appState, sceneContext: SceneNavigationContext(appState: appState, sceneID: UUID()))
  }

  /// The timeline interstitial reads trending visibility from the account's persisted settings,
  /// so its cases need an in-memory settings store that accepts changes. The store outlives the
  /// test (`TestSettingsStores`) because the app state's bootstrap work can run after it returns.
  private func makeTrendingAppState() async throws -> AppState {
    let accountDID = "did:plc:feedssearchpresentationfixture"
    let container = try ModelContainer(
      for: AppSettingsModel.self, Preferences.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    container.mainContext.insert(AppSettingsModel(accountDID: accountDID))
    try container.mainContext.save()
    TestSettingsStores.retain(container)
    let appState = try await makeAppState()
    appState.initializePreferencesManager(with: container.mainContext)
    for _ in 0..<150 where !appState.appSettings.canEditPersistedSettings {
      try await Task.sleep(for: .milliseconds(20))
    }
    try #require(appState.appSettings.canEditPersistedSettings)
    // The cell draws the feed's themed background. Ink checks need a neutral backdrop, and the
    // dim theme's gray is slightly blue, so these cases use the black dark theme.
    appState.themeManager.applyTheme(
      theme: appState.appSettings.theme, darkThemeMode: "black", accentColor: appState.appSettings.accentColor)
    try #require(appState.themeManager.darkThemeMode == .black)
    return appState
  }

  private func makeAppState(baseURL: String = "https://example.invalid") async throws -> AppState {
    let client = await ATProtoClient(baseURL: try #require(URL(string: baseURL)))
    return AppState(userDID: "did:plc:feedssearchpresentationfixture", client: client, regulatoryChecker: PresentationAgeChecker())
  }

  private func makeTransportFailureAppState() async throws -> AppState {
    let previousProtocols = NetworkService.getNetworkTestProtocolClasses()
    try #require(previousProtocols == nil, "The focused transport fixture requires exclusive use of Petrel's network hook")
    NetworkService.setNetworkTestProtocolClasses([DiscoveryFailureURLProtocol.self])
    defer { NetworkService.setNetworkTestProtocolClasses(previousProtocols) }
    // A loopback literal passes URL validation without DNS. Petrel copies the protocol
    // into its sessions during construction, so restore the global hook before fetching.
    return try await makeAppState(baseURL: "https://127.0.0.1")
  }

  private func discoveryFailurePresentation(_ model: RefinedSearchViewModel) -> some View {
    VStack(spacing: 28) {
      TrendingTopicsSection(topics: model.trendingTopics, onSelect: { _ in }, onSeeAll: {})
      TrendingVideosSection(videos: model.trendingVideos, isLoading: model.isTrendingVideosLoading,
        onSelectPost: { _ in }, onSeeAll: {})
      SuggestedProfilesSection(profiles: model.suggestedProfiles, isLoading: model.isSuggestedProfilesLoading,
        onSelectCategory: { _ in }, onSelectProfile: { _ in }, onRefresh: {})
    }
  }

  private func makeTopic(description: String? = "A community conversation about plants and astronomy.") -> AppBskyUnspeccedDefs.TrendView {
    .init(topic: "moon-garden", displayName: "Moon Garden", description: description,
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
    let systemCategory = try PresentationSystemCategory.fromEnvironment()
    let effectiveTypeSize = systemCategory?.dynamicTypeSize ?? typeSize
    if let systemCategory {
      try #require(UIApplication.shared.preferredContentSizeCategory == systemCategory.uiCategory,
        "Set simulator content_size before a fresh test-process launch; environment values cannot change UIKit-resolved app fonts")
    }
    let previousScheme = appState.themeManager.colorSchemeOverride
    appState.themeManager.colorSchemeOverride = scheme
    defer { appState.themeManager.colorSchemeOverride = previousScheme }
    let host = try PresentationHost(content: content.environment(appState).environment(SceneNavigationContext(appState: appState, sceneID: UUID())).fontManager(appState.fontManager).environment(\.colorScheme, scheme)
      .environment(\.dynamicTypeSize, effectiveTypeSize).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(scheme == .light ? Color.white : Color.black)
      .ignoresSafeArea(.container, edges: additionalSafeAreaInsets == nil ? .all : []), size: size, scheme: scheme,
      requestedTypeSize: typeSize, effectiveTypeSize: effectiveTypeSize, systemCategory: systemCategory)
    defer { host.close() }
    if let additionalSafeAreaInsets {
      try await host.applySyntheticSafeAreaInsets(additionalSafeAreaInsets)
    }
    try await body(host)
  }
}

/// Hosts `TrendingInterstitialCell` the way the feed sizes it: full width, layout height.
private struct NativeTrendingInterstitial: UIViewRepresentable {
  let content: TrendingFeedContent
  let appState: AppState
  let sceneContext: SceneNavigationContext

  func makeUIView(context: Context) -> TrendingInterstitialCell {
    TrendingInterstitialCell(frame: .zero)
  }

  func updateUIView(_ cell: TrendingInterstitialCell, context: Context) {
    cell.configure(.init(content: content, appState: appState, sceneContext: sceneContext))
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: TrendingInterstitialCell, context: Context) -> CGSize? {
    guard let width = proposal.width, width.isFinite else { return nil }
    return uiView.systemLayoutSizeFitting(
      CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel)
  }
}

@Observable @MainActor
private final class TrendingArtworkGeometryState {
  var preview = TrendingTopicPreview()
}

private struct TrendingArtworkGeometryFixture: View {
  let state: TrendingArtworkGeometryState
  let showParticipants: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("TITLE STAYS")
      TrendingTopicArtworkPresentation(preview: state.preview, showParticipants: showParticipants)
      Text("TIMELINE CONTINUES")
    }
    .padding(16)
  }
}

private enum PresentationSystemCategory: String {
  case large
  case accessibilityMedium = "accessibility-medium"

  var dynamicTypeSize: DynamicTypeSize { self == .large ? .large : .accessibility1 }
  var uiCategory: UIContentSizeCategory { self == .large ? .large : .accessibilityMedium }

  static func fromEnvironment() throws -> Self? {
    guard let value = ProcessInfo.processInfo.environment["CATBIRD_PRESENTATION_SYSTEM_CATEGORY"] else { return nil }
    return try #require(Self(rawValue: value), "Expected system category large or accessibility-medium")
  }
}

/// Intercepts every request on the fixture client's sessions; no request is dispatched.
private final class DiscoveryFailureURLProtocol: URLProtocol, @unchecked Sendable {
  private nonisolated(unsafe) static var requestURLs: [URL] = []
  private static let lock = NSLock()

  static var urls: [URL] { lock.withLock { requestURLs } }

  static func reset() { lock.withLock { requestURLs = [] } }

  override static func canInit(with request: URLRequest) -> Bool { true }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.withLock {
      if let url = request.url { Self.requestURLs.append(url) }
    }
    // This error bypasses Petrel's timeout/connection retry policy and fails immediately.
    client?.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse))
  }

  override func stopLoading() {}
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
    var measuredWordRect: CGRect?
    var measuredTextInk: TextInkMeasurement?
    var transcript: String { lines.map(\.text).joined(separator: "\n") }
    func contains(_ text: String) -> Bool {
      PresentationHost.normalized(transcript).contains(PresentationHost.normalized(text))
    }
  }

  struct TextInkMeasurement: CustomStringConvertible {
    let rect: CGRect
    let evidence: String
    var description: String { evidence }
  }

  /// How ink is told apart from a uniform neutral backdrop.
  enum InkForeground {
    /// A neutral caption; a colored pixel means other content shares the region.
    case neutral
    /// Text in an accent color, such as a link. Any contrasting pixel counts as ink: other content in
    /// the region can only widen the measured bounds, never shrink them.
    case tinted
  }

  /// One rendered line whose painted ink a capture measures: Vision reads it as one of `readings`
  /// (compared normalized), drawn in `foreground`.
  struct InkTarget {
    let readings: [String]
    let foreground: InkForeground
  }

  private struct InkFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  /// Painted-ink oracle for one line of text on a uniform neutral fill (the trending count, the All
  /// Saved link). Vision locates the whole line; it does not determine its painted edges.
  private static func measureTextInk(
    image: UIImage, text: String, seed: CGRect, foreground: InkForeground
  ) throws -> TextInkMeasurement {
    guard image.imageOrientation == .up, let cg = image.cgImage,
          cg.colorSpace?.model == .rgb, cg.bitsPerComponent == 8,
          image.size.width > 0, image.size.height > 0,
          let data = cg.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else {
      throw InkFailure("Ink measurement requires an upright eight-bit RGB renderer image")
    }
    let scaleX = CGFloat(cg.width) / image.size.width
    let scaleY = CGFloat(cg.height) / image.size.height
    guard abs(scaleX - scaleY) < 0.000001, abs(scaleX - image.scale) < 0.000001 else {
      throw InkFailure("Inconsistent CGImage pixel-to-point scale")
    }
    let stride = cg.bitsPerPixel / 8
    let order = cg.bitmapInfo.intersection(.byteOrderMask)
    let channels: (Int, Int, Int)
    switch (cg.bitsPerPixel, cg.alphaInfo, order) {
    case (24, .none, _): channels = (0, 1, 2)
    case (32, .premultipliedFirst, .byteOrder32Little), (32, .first, .byteOrder32Little),
         (32, .noneSkipFirst, .byteOrder32Little): channels = (2, 1, 0)
    case (32, .premultipliedLast, .byteOrder32Little), (32, .last, .byteOrder32Little),
         (32, .noneSkipLast, .byteOrder32Little): channels = (3, 2, 1)
    case (32, .premultipliedFirst, .byteOrder32Big), (32, .first, .byteOrder32Big),
         (32, .noneSkipFirst, .byteOrder32Big): channels = (1, 2, 3)
    case (32, .premultipliedLast, .byteOrder32Big), (32, .last, .byteOrder32Big),
         (32, .noneSkipLast, .byteOrder32Big): channels = (0, 1, 2)
    default: throw InkFailure("Unsupported renderer bitmap: \(cg.bitsPerPixel)bpp, info=\(cg.bitmapInfo.rawValue)")
    }
    guard cg.bytesPerRow >= cg.width * stride, CFDataGetLength(data) >= cg.bytesPerRow * cg.height else {
      throw InkFailure("Incomplete renderer pixel storage")
    }
    // CGImage scanlines and Vision's converted seed both use top-left coordinates.
    // Read the provider directly: no CGContext draw/transform can flip these rows.
    let bytes = Array(UnsafeBufferPointer(start: pointer, count: CFDataGetLength(data)))
    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
      let offset = y * cg.bytesPerRow + x * stride
      return (Int(bytes[offset + channels.0]), Int(bytes[offset + channels.1]), Int(bytes[offset + channels.2]))
    }
    let expanded = seed.insetBy(dx: -6, dy: -6)
    guard [expanded.minX, expanded.minY, expanded.maxX, expanded.maxY].allSatisfy({ $0.isFinite }) else {
      throw InkFailure("Nonfinite OCR seed")
    }
    let x0 = Int(floor(expanded.minX * scaleX)), x1 = Int(ceil(expanded.maxX * scaleX))
    let y0 = Int(floor(expanded.minY * scaleY)), y1 = Int(ceil(expanded.maxY * scaleY))
    // Do not intersect with the expected content bounds: that would hide overflow.
    guard x0 > 0, y0 > 0, x1 < cg.width, y1 < cg.height, x1 > x0, y1 > y0 else {
      throw InkFailure("Expanded text ROI touches or crosses the rendered viewport")
    }
    var histogram: [Int: Int] = [:]
    for y in y0..<y1 { for x in x0..<x1 {
      let (r, g, b) = rgb(x, y)
      histogram[(r << 16) | (g << 8) | b, default: 0] += 1
    } }
    guard let modal = histogram.max(by: { $0.value < $1.value }), modal.value > (x1 - x0) * (y1 - y0) / 2 else {
      throw InkFailure("Text ROI has no unambiguous uniform backdrop")
    }
    let background = ((modal.key >> 16) & 255, (modal.key >> 8) & 255, modal.key & 255)
    guard max(background.0, background.1, background.2) - min(background.0, background.1, background.2) <= 2 else {
      throw InkFailure("Text backdrop is not neutral")
    }
    // Independent contrast cutoffs must agree on horizontal ink edges. This
    // rejects threshold-sensitive noise instead of tuning a passing tolerance.
    let thresholds = [16, 24, 32]
    var pixelBounds: [CGRect] = []
    for threshold in thresholds {
      var minX = x1, minY = y1, maxX = x0 - 1, maxY = y0 - 1
      for y in y0..<y1 { for x in x0..<x1 {
        let (r, g, b) = rgb(x, y)
        guard max(abs(r - background.0), abs(g - background.1), abs(b - background.2)) > threshold else { continue }
        if foreground == .neutral, max(r, g, b) - min(r, g, b) > 20 {
          throw InkFailure("Colored foreground makes the neutral text ROI ambiguous")
        }
        minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
      } }
      guard maxX >= minX, maxY >= minY else { throw InkFailure("No text ink at contrast \(threshold)") }
      guard minX > x0, minY > y0, maxX < x1 - 1, maxY < y1 - 1 else {
        throw InkFailure("Text ink reaches the ROI edge at contrast \(threshold)")
      }
      pixelBounds.append(CGRect(x: CGFloat(minX), y: CGFloat(minY),
        width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1)))
    }
    let ink = pixelBounds[0]
    guard pixelBounds.allSatisfy({ $0.minX == ink.minX && $0.maxX == ink.maxX }) else {
      throw InkFailure("Text horizontal ink bounds disagree across contrasts \(thresholds): \(pixelBounds)")
    }
    let rect = CGRect(x: ink.minX / scaleX, y: ink.minY / scaleY, width: ink.width / scaleX, height: ink.height / scaleY)
    return TextInkMeasurement(rect: rect, evidence:
      "text=\(text); foreground=\(foreground); pointSize=\(image.size); pixelSize=\(cg.width)x\(cg.height); scale=\(scaleX),\(scaleY); "
      + "seed=\(seed); roiPixels=[\(x0),\(y0),\(x1),\(y1)); backgroundRGB=\(background); "
      + "thresholds=\(thresholds); inkPixelRects=\(pixelBounds); inkPoints=\(rect); edges=max-exclusive; "
      + "bitmapInfo=\(cg.bitmapInfo.rawValue); bitsPerPixel=\(cg.bitsPerPixel); bytesPerRow=\(cg.bytesPerRow)")
  }

  let window: UIWindow
  let controller: UIViewController
  private let requestedSize: CGSize
  private let requestedTypeSize: DynamicTypeSize
  private let effectiveTypeSize: DynamicTypeSize
  private let systemCategory: PresentationSystemCategory?
  private var requestedAdditionalSafeAreaInsets: UIEdgeInsets?
  private var baselineSafeAreaInsets = UIEdgeInsets.zero
  private weak var previousKeyWindow: UIWindow?

  init<Content: View>(
    content: Content, size: CGSize, scheme: ColorScheme,
    requestedTypeSize: DynamicTypeSize, effectiveTypeSize: DynamicTypeSize,
    systemCategory: PresentationSystemCategory?
  ) throws {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    requestedSize = size
    self.requestedTypeSize = requestedTypeSize
    self.effectiveTypeSize = effectiveTypeSize
    self.systemCategory = systemCategory
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

  var typographyContext: [String: String] {
    ["mode": systemCategory == nil ? "synthetic-environment-only-limited" : "system-category-fresh-launch",
      "requestedSystemCategory": systemCategory?.rawValue ?? "not-set",
      "requestedSwiftUITypeSize": String(describing: requestedTypeSize),
      "effectiveSwiftUITypeSize": String(describing: effectiveTypeSize),
      "systemCategory": UIApplication.shared.preferredContentSizeCategory.rawValue,
      "controllerCategory": controller.traitCollection.preferredContentSizeCategory.rawValue,
      "viewCategory": controller.view.traitCollection.preferredContentSizeCategory.rawValue]
  }

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

  func capture(_ name: String, requiring expected: [String] = [], measuringWord: String? = nil,
               measuringInkFor inkTarget: InkTarget? = nil) async throws -> Receipt {
    let deadline = ContinuousClock.now + .seconds(3)
    var png = Data()
    var receipt = Receipt(lines: [])
    var didDraw = false
    var errorText = ""
    var inkError = ""
    repeat {
      try await Task.sleep(for: .milliseconds(80))
      window.layoutIfNeeded()
      controller.view.layoutIfNeeded()
      let format = UIGraphicsImageRendererFormat()
      format.scale = 3
      format.opaque = true
      if inkTarget != nil { format.preferredRange = .standard }
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
        var measuredWordRect: CGRect?
        var inkSeeds: [(text: String, rect: CGRect)] = []
        receipt = Receipt(lines: (request.results ?? []).compactMap { observation in
          guard let candidate = observation.topCandidates(1).first else { return nil }
          let text = candidate.string
          if let inkTarget, inkTarget.readings.contains(where: { Self.normalized($0) == Self.normalized(text) }) {
            // Each target renders on one otherwise empty line.
            // Do not accept an observation that also includes unrelated content.
            let bounds = observation.boundingBox
            inkSeeds.append((text, CGRect(x: bounds.minX * image.size.width, y: (1 - bounds.maxY) * image.size.height,
              width: bounds.width * image.size.width, height: bounds.height * image.size.height)))
          }
          if let measuringWord, let range = text.range(of: measuringWord),
            let word = try? candidate.boundingBox(for: range) {
            let bounds = word.boundingBox
            measuredWordRect = CGRect(x: bounds.minX * image.size.width, y: (1 - bounds.maxY) * image.size.height,
              width: bounds.width * image.size.width, height: bounds.height * image.size.height)
          }
          let bounds = observation.boundingBox
          return Line(text: text, rect: CGRect(x: bounds.minX * image.size.width,
            y: (1 - bounds.maxY) * image.size.height, width: bounds.width * image.size.width, height: bounds.height * image.size.height))
        })
        receipt.measuredWordRect = measuredWordRect
        if let inkTarget {
          inkError = ""
          if inkSeeds.count == 1 {
            do {
              receipt.measuredTextInk = try Self.measureTextInk(
                image: image, text: inkSeeds[0].text, seed: inkSeeds[0].rect, foreground: inkTarget.foreground)
            } catch { inkError = String(describing: error) }
          } else {
            inkError = "Expected one complete text observation; found \(inkSeeds.count)"
          }
        }
      } catch { errorText = String(describing: error) }
      if didDraw && expected.allSatisfy({ receipt.contains($0) })
        && (measuringWord == nil || receipt.measuredWordRect != nil)
        && (inkTarget == nil || receipt.measuredTextInk != nil) { break }
    } while ContinuousClock.now < deadline

    Attachment.record(Array(png), named: "\(name).png")
    let typographyData = try JSONSerialization.data(withJSONObject: typographyContext, options: .sortedKeys)
    let typographyText = try #require(String(data: typographyData, encoding: .utf8))
    let details = "requestedSize=\(requestedSize), actualWindow=\(window.bounds), renderedView=\(controller.view.bounds), scale=3, drawHierarchy=\(didDraw)\n"
      + "syntheticAdditionalInsets=\(String(describing: requestedAdditionalSafeAreaInsets)), baselineInsets=\(baselineSafeAreaInsets), actualInsets=\(controller.view.safeAreaInsets), actualSafeAreaFrame=\(actualSafeAreaFrame)\n"
      + "typography=\(typographyText)\n"
      + "measuringWord=\(measuringWord ?? "none"), measuredWordRect=\(String(describing: receipt.measuredWordRect))\n"
      + "measuringInkFor=\(inkTarget.map { "\($0.readings) (\($0.foreground))" } ?? "none"), measuredTextInk=\(String(describing: receipt.measuredTextInk)), inkError=\(inkError)\n"
      + "error=\(errorText)\n" + receipt.lines.map { "\($0.rect): \($0.text)" }.joined(separator: "\n")
    Attachment.record(Array(details.utf8), named: "\(name)-geometry-ocr.txt")
    #expect(!png.isEmpty && didDraw, "UIKit must produce a real rendered image")
    #expect(abs(requestedSize.width - controller.view.bounds.width) < 1, "The receiving width must equal the requested fixture width")
    #expect(abs(requestedSize.height - controller.view.bounds.height) < 1, "The receiving height must equal the requested fixture height")
    if let systemCategory {
      #expect(UIApplication.shared.preferredContentSizeCategory == systemCategory.uiCategory)
      #expect(controller.traitCollection.preferredContentSizeCategory == systemCategory.uiCategory)
      #expect(controller.view.traitCollection.preferredContentSizeCategory == systemCategory.uiCategory)
    }
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
      // OCR rects are normalized floats; tolerate sub-point rounding at the edges (e.g. minY = -6e-8).
      #expect(line.rect.minX >= -0.5 && line.rect.maxX <= controller.view.bounds.width + 1)
      #expect(line.rect.minY >= -0.5 && line.rect.maxY <= controller.view.bounds.height + 1)
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
