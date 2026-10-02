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
        sceneContext.navigationManager.navigate(to: .post(post.uri))
      },
      onOpenVideos: {
        sceneContext.navigationManager.navigate(to: .videoFeed)
      },
      onHideTopics: { appState.appSettings.showTrendingTopics = false },
      onHideVideos: { appState.appSettings.showTrendingVideos = false }
    )
    .background(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
  }
}

/// The production presentation is independent of account services so fixture hosts can exercise it.
struct TrendingFeedPresentation: View {
  let content: TrendingFeedContent
  let showTopics: Bool
  let showVideos: Bool
  let onSelectTopic: (AppBskyUnspeccedDefs.TrendView) -> Void
  let onSelectPost: (AppBskyFeedDefs.PostView) -> Void
  let onOpenVideos: () -> Void
  let onHideTopics: () -> Void
  let onHideVideos: () -> Void

  @State private var hideTarget: HideTarget?
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
            HStack(spacing: DesignTokens.Spacing.sm) {
              ForEach(content.trends.prefix(6), id: \.topic) { trend in
                Button { onSelectTopic(trend) } label: {
                  VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text(trend.displayName)
                      .appFont(size: Typography.Size.subheadline, weight: .semibold, relativeTo: .subheadline)
                      .foregroundStyle(.primary)
                      .lineLimit(2)
                      .fixedSize(horizontal: false, vertical: true)
                    if trend.postCount > 0 {
                      Text("\(trend.postCount.formatted(.number.notation(.compactName))) posts")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                    }
                  }
                  .multilineTextAlignment(.leading)
                  .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 260 : 200, alignment: .leading)
                  .padding(.horizontal, DesignTokens.Spacing.base)
                  .padding(.vertical, DesignTokens.Spacing.md)
                  .frame(minHeight: 44, alignment: .leading)
                  .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: DesignTokens.Size.radiusMD))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Open posts about this topic")
              }
            }
            .padding(.horizontal, 16)
          }
        }

        if showVideos && !content.videos.isEmpty {
          TrendingVideosSection(
            videos: content.videos,
            presentation: .timeline,
            onSelectPost: onSelectPost,
            onSeeAll: onOpenVideos
          )
        }
      }
      .padding(.vertical, DesignTokens.Spacing.base)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .bottom) { Divider() }
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
        Text("This hides \(target.name) for this account in Feeds and Search. You can show \(target.name) again in Settings → Content & Media.")
      }
    }
  }
}

struct TrendingFeedContent: Equatable {
    var trends: [AppBskyUnspeccedDefs.TrendView] = []
    var videos: [AppBskyFeedDefs.FeedViewPost] = []

    var isEmpty: Bool { trends.isEmpty && videos.isEmpty }

    @MainActor
    static func load(appState: AppState) async -> Self {
        async let trends = loadTrends(appState: appState)
        async let videos = loadVideos(appState: appState)
        return await Self(trends: trends, videos: videos)
    }

    @MainActor
    private static func loadTrends(appState: AppState) async -> [AppBskyUnspeccedDefs.TrendView] {
        guard appState.appSettings.showTrendingTopics, let client = appState.atProtoClient else {
            return []
        }
        do {
            let (_, output) = try await client.app.bsky.unspecced.getTrends(input: .init(limit: 10))
            return output?.trends ?? []
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
            return response?.feed ?? []
        } catch {
            return []
        }
    }
}
