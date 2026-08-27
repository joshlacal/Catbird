import SwiftUI
import Petrel

public struct TrendingFeedInterstitialView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    @State private var trends: [AppBskyUnspeccedDefs.TrendView] = []
    @State private var videos: [AppBskyFeedDefs.FeedViewPost] = []
    @State private var isLoadingTrends = false
    @State private var isLoadingVideos = false
    @State private var hasLoaded = false

    public init() {}

    private var showTopics: Bool {
        appState.appSettings.showTrendingTopics
    }

    private var showVideos: Bool {
        appState.appSettings.showTrendingVideos
    }

    private var hasContent: Bool {
        (showTopics && !trends.isEmpty) || (showVideos && !videos.isEmpty)
    }

    public var body: some View {
        if !showTopics && !showVideos {
            EmptyView()
        } else if hasLoaded && !hasContent {
            EmptyView()
        } else if !hasContent {
            Color.clear
                .frame(height: 0)
                .task {
                    await loadDataIfNeeded()
                }
        } else {
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
                if showTopics && !trends.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(trends.prefix(6), id: \.topic) { trend in
                                Button {
                                    openTopic(trend.topic)
                                } label: {
                                    HStack(spacing: 6) {
                                        Text("#\(trend.topic)")
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
                if showVideos && !videos.isEmpty {
                    TrendingVideosSection(
                        videos: videos,
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
            .background(Color.dynamicGroupedBackground(appState.themeManager, currentScheme: colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .padding(.horizontal)
            .task {
                await loadDataIfNeeded()
            }
            .onChange(of: showTopics) { _, newValue in
                if newValue && trends.isEmpty {
                    Task { await loadTrends() }
                }
            }
            .onChange(of: showVideos) { _, newValue in
                if newValue && videos.isEmpty {
                    Task { await loadVideos() }
                }
            }
        }
    }

    private func openTopic(_ topic: String) {
        appState.navigationManager.navigate(to: .topic(topic))
    }

    private func openVideoFeed() {
        appState.navigationManager.navigate(to: .videoFeed)
    }

    private func openPost(_ post: AppBskyFeedDefs.PostView) {
        appState.navigationManager.navigate(to: .post(post.uri))
    }

    private func loadDataIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        async let trendsTask: () = loadTrends()
        async let videosTask: () = loadVideos()
        _ = await (trendsTask, videosTask)
    }

    private func loadTrends() async {
        guard showTopics, let client = appState.atProtoClient else {
            trends = []
            return
        }
        isLoadingTrends = true
        do {
            let (_, output) = try await client.app.bsky.unspecced.getTrends(input: .init(limit: 10))
            if let trendsList = output?.trends {
                self.trends = trendsList
            }
        } catch {
            self.trends = []
        }
        isLoadingTrends = false
    }

    private func loadVideos() async {
        guard showVideos, let client = appState.atProtoClient else {
            videos = []
            return
        }
        isLoadingVideos = true
        do {
            let input = AppBskyFeedGetFeed.Parameters(
                feed: try ATProtocolURI(uriString: TrendingVideosSection.thevidsURI),
                limit: 10,
                cursor: nil
            )
            let (_, response) = try await client.app.bsky.feed.getFeed(input: input)
            if let feedResponse = response {
                self.videos = feedResponse.feed
            }
        } catch {
            self.videos = []
        }
        isLoadingVideos = false
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}
