import SwiftUI
import Petrel

public struct TrendingFeedInterstitialView: View {
  @Environment(SceneNavigationContext.self) private var sceneContext
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme

  let content: TrendingFeedContent

  init(content: TrendingFeedContent) {
    self.content = content
  }

  public var body: some View {
    TrendingFeedPresentation(
      content: content,
      showTopics: appState.appSettings.showTrendingTopics,
      showVideos: appState.appSettings.showTrendingVideos,
      onSelectTopic: { trend in
        guard let url = URL(string: trend.link, relativeTo: URL(string: "https://bsky.app")) else { return }
        _ = sceneContext.urlHandler.handle(url.absoluteURL)
      },
      onSelectPost: { post in
        sceneContext.navigationManager.navigate(to: .videoFeedStartingAt(post))
      },
      onOpenVideos: {
        sceneContext.navigationManager.navigate(to: .videoFeed)
      },
      onHideTopics: { appState.appSettings.showTrendingTopics = false },
      onHideVideos: { appState.appSettings.showTrendingVideos = false },
      onNavigateVideo: { destination in
        sceneContext.navigationManager.navigate(to: destination)
      }
    )
    .background(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
    .onChange(of: appState.appSettings.showTrendingTopics) { _, showTopics in
      if !showTopics { appState.cancelTopicPreviewPrefetch(owner: .timeline) }
    }
  }
}

/// Shared production layout; topic artwork reads the enclosing account’s moderated preview cache.
struct TrendingFeedPresentation: View {
  let content: TrendingFeedContent
  let showTopics: Bool
  let showVideos: Bool
  let onSelectTopic: (AppBskyUnspeccedDefs.TrendView) -> Void
  let onSelectPost: (AppBskyFeedDefs.PostView) -> Void
  let onOpenVideos: () -> Void
  let onHideTopics: () -> Void
  let onHideVideos: () -> Void
  var onNavigateVideo: ((NavigationDestination) -> Void)? = nil

  @State private var hideTarget: HideTarget?

  private enum HideTarget {
    case topics, videos

    var name: String { self == .topics ? "trending topics" : "trending videos" }
  }

  private var hasContent: Bool {
    (showTopics && !content.trends.isEmpty) || (showVideos && !content.videos.isEmpty)
  }

  var body: some View {
    if hasContent {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.base) {
        DiscoverySectionHeader("Trending on Bluesky") {
          Menu {
            if showTopics {
              Button { hideTarget = .topics } label: {
                Label("Hide trending topics…", systemImage: "eye.slash")
              }
            }
            if showVideos {
              Button { hideTarget = .videos } label: {
                Label("Hide trending videos…", systemImage: "eye.slash")
              }
            }
          } label: {
            Image(systemName: "ellipsis")
              .appFont(AppTextRole.subheadline)
              .foregroundStyle(.secondary)
              .frame(width: 44, height: 44)
              .contentShape(Rectangle())
          }
          .accessibilityLabel("Trending options")
        }

        if showTopics && !content.trends.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            // At most six cards: measure them together so descriptions and larger text
            // cannot change the carousel height as another card scrolls into view.
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
              ForEach(content.trends.prefix(6), id: \.topic) { trend in
                TrendingTimelineTopicCard(trend: trend, onSelect: { onSelectTopic(trend) })
              }
            }
            .padding(.horizontal, 16)
          }
          .fixedSize(horizontal: false, vertical: true)
        }

        if showVideos && !content.videos.isEmpty {
          TrendingVideosSection(
            videos: content.videos,
            presentation: .timeline,
            onSelectPost: onSelectPost,
            onSeeAll: onOpenVideos,
            onNavigateVideo: onNavigateVideo
          )
        }
      }
      .padding(.vertical, DesignTokens.Spacing.base)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .bottom) { Divider() }
      .modifier(TrendingTimelinePreviewPrefetch(trends: showTopics ? content.trends : []))
      .confirmationDialog(
        "Hide \(hideTarget?.name ?? "trending content")?",
        isPresented: Binding(
          get: { hideTarget != nil },
          set: { if !$0 { hideTarget = nil } }
        ),
        titleVisibility: .visible,
        presenting: hideTarget
      ) { target in
        Button("Hide in Feeds and Search", role: .destructive) {
          if target == .topics { onHideTopics() } else { onHideVideos() }
        }
        Button("Cancel", role: .cancel) {}
      } message: { target in
        Text("This hides \(target.name) for this account in Feeds and Search. You can turn them back on in Settings › Feeds & Discovery › Discovery.")
      }
    }
  }
}

struct TrendingFeedContent: Equatable {
    var trends: [AppBskyUnspeccedDefs.TrendView] = []
    var videos: [AppBskyFeedDefs.FeedViewPost] = []

    var isEmpty: Bool { trends.isEmpty && videos.isEmpty }

    @MainActor
    static func load(appState: AppState, displayScale: CGFloat) async -> Self {
        async let trends = loadTrends(appState: appState, displayScale: displayScale)
        async let videos = loadVideos(appState: appState)
        return await Self(trends: trends, videos: videos)
    }

    @MainActor
    private static func loadTrends(appState: AppState, displayScale: CGFloat) async -> [AppBskyUnspeccedDefs.TrendView] {
        guard appState.appSettings.showTrendingTopics, let client = appState.atProtoClient else {
            return []
        }
        do {
            let viewerDID = appState.userDID
            let (_, output) = try await client.app.bsky.unspecced.getTrends(input: .init(limit: 10))
            guard !Task.isCancelled, !appState.isAccountSwitchSuspended, appState.userDID == viewerDID else { return [] }
            let trends = output?.trends ?? []
            appState.prefetchTopicPreviews(trends: trends, displayScale: displayScale, owner: .timeline)
            return trends
        } catch {
            return []
        }
    }

    @MainActor
    private static func loadVideos(appState: AppState) async -> [AppBskyFeedDefs.FeedViewPost] {
        guard appState.appSettings.showTrendingVideos, let client = appState.atProtoClient else {
            return []
        }
        do {
            let input = AppBskyFeedGetFeed.Parameters(
                feed: try ATProtocolURI(uriString: TrendingVideosSection.thevidsURI),
                limit: 10,
                cursor: nil
            )
            let (_, response) = try await client.app.bsky.feed.getFeed(input: input)
            // Previews the account's policy filters from lists are not kept; the
            // section re-filters with the live policy and covers moderated thumbnails.
            return TrendingVideoModeration.listed(response?.feed ?? [], policy: appState.moderationPolicy)
        } catch {
            return []
        }
    }
}

private struct TrendingTimelinePreviewPrefetch: ViewModifier {
  @Environment(AppState.self) private var appState
  @Environment(\.displayScale) private var displayScale
  let trends: [AppBskyUnspeccedDefs.TrendView]

  func body(content: Content) -> some View {
    content.task(id: appState.topicPreviewPrefetchIdentity(links: trends.map(\.link))) {
      appState.prefetchTopicPreviews(trends: trends, displayScale: displayScale, owner: .timeline)
    }
  }
}

/// Topic cards: the title always wraps in full, the media fan sits beside the description
/// (stacked above it at accessibility sizes), and the card grows vertically with its content.
/// Every card stretches to the tallest card in the carousel so the row stays aligned.
private struct TrendingTimelineTopicCard: View {
  let trend: AppBskyUnspeccedDefs.TrendView
  let onSelect: () -> Void
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  /// Fixed media geometry, kept in step with `TrendingTopicArtworkPresentation` (108pt wide).
  private let mediaWidth: CGFloat = 108
  private let mediaHeight: CGFloat = 86

  var body: some View {
    Button(action: onSelect) {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
          TrendingTopicCategoryMark(category: trend.category, diameter: 28)
          VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            if let category = trend.category {
              Text(TrendingTopicCategoryStyle.name(for: category))
                .appFont(AppTextRole.caption.weight(.medium))
                .foregroundStyle(TrendingTopicCategoryStyle.color(for: category))
                .fixedSize(horizontal: false, vertical: true)
            }
            TrendingTopicTitle(title: trend.displayName, size: 18, lineLimit: nil)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        previewAndDescription
        footer
      }
      .multilineTextAlignment(.leading)
      .containerRelativeFrame(.horizontal, alignment: .topLeading) { viewportWidth, _ in
        // Keep the whole card inside the carousel, including both 16pt scroll
        // insets and the card's own horizontal padding.
        let preferredWidth: CGFloat = 300
        return min(preferredWidth, max(0, viewportWidth - 32 - 2 * DesignTokens.Spacing.base))
      }
      .padding(.horizontal, DesignTokens.Spacing.base)
      .padding(.vertical, DesignTokens.Spacing.md)
      .frame(maxHeight: .infinity, alignment: .topLeading)
      .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: DesignTokens.Size.radiusMD))
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityHint("Open posts about this topic")
  }

  @ViewBuilder
  private var previewAndDescription: some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
        mediaFan
        descriptionText
      }
    } else {
      HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
        mediaFan
        descriptionText
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  /// Decorative media only; avatars are shown in the footer instead.
  private var mediaFan: some View {
    TrendingTopicArtwork(link: trend.link, actors: trend.actors, showParticipants: false)
      .frame(width: mediaWidth, height: mediaHeight, alignment: .topLeading)
  }

  @ViewBuilder
  private var descriptionText: some View {
    if let description = TrendingTopicPresentation.description(for: trend) {
      Text(description)
        .appFont(AppTextRole.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var footer: some View {
    HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
      TrendingTopicParticipants(link: trend.link, actors: trend.actors)
      Spacer(minLength: 0)
      if trend.postCount > 0 {
        Text(postCountText)
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var postCountText: String {
    "\(trend.postCount.formatted(.number.notation(.compactName))) posts"
  }
}
