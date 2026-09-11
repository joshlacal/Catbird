import SwiftUI
import Petrel

public struct TrendingFeedInterstitialView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    let content: TrendingFeedContent

    init(content: TrendingFeedContent) {
        self.content = content
    }

    private var showTopics: Bool {
        appState.appSettings.showTrendingTopics
    }

    private var showVideos: Bool {
        appState.appSettings.showTrendingVideos
    }

    private var hasContent: Bool {
        (showTopics && !content.trends.isEmpty) || (showVideos && !content.videos.isEmpty)
    }

    public var body: some View {
        if hasContent {
            VStack(alignment: .leading, spacing: 14) {
                // Header with title and options menu
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.subheadline.bold())
                            .foregroundColor(.orange)
                        Text("Trending on Bluesky")
                            .font(.headline)
                    }

                    Spacer()

                    Menu {
                        if showTopics {
                            Button(role: .destructive) {
                                appState.appSettings.showTrendingTopics = false
                            } label: {
                                Label("Hide Trending Topics", systemImage: "eye.slash")
                            }
                        }
                        if showVideos {
                            Button(role: .destructive) {
                                appState.appSettings.showTrendingVideos = false
                            } label: {
                                Label("Hide Trending Videos", systemImage: "eye.slash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                            .padding(6)
                    }
                }
                .padding(.horizontal)

                // Topics section
                if showTopics && !content.trends.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(content.trends.prefix(6), id: \.topic) { trend in
                                Button {
                                    openTopic(trend)
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(trend.displayName)
                                            .font(.subheadline.bold())
                                            .foregroundColor(.primary)

                                        if trend.postCount > 0 {
                                            Text(formatCount(trend.postCount))
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.dynamicSecondaryBackground(appState.themeManager, currentScheme: colorScheme))
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                // Videos section (reusing WS-A G03 TrendingVideosSection)
                if showVideos && !content.videos.isEmpty {
                    TrendingVideosSection(
                        videos: content.videos,
                        onSelectPost: { post in
                            openPost(post)
                        },
                        onSeeAll: {
                            openVideoFeed()
                        }
                    )
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.separator)
                    .frame(height: 0.5)
            }
        }
    }

    private func openTopic(_ trend: AppBskyUnspeccedDefs.TrendView) {
        guard let url = URL(string: trend.link, relativeTo: URL(string: "https://bsky.app")) else { return }
        _ = appState.urlHandler.handle(url.absoluteURL)
    }

    private func openVideoFeed() {
        appState.navigationManager.navigate(to: .videoFeed)
    }

    private func openPost(_ post: AppBskyFeedDefs.PostView) {
        appState.navigationManager.navigate(to: .post(post.uri))
    }


    private func formatCount(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
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
