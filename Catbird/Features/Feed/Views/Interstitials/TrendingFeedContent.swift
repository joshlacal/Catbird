import Petrel
import SwiftUI

/// Trending topics and videos shown inside the home feed (`TrendingInterstitialCell`).
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
        let viewerDID = appState.userDID
        do {
            let trends = try await appState.trendingTopicMediaStore.fetchOrCoalesceTrends(for: viewerDID) {
                let (_, output) = try await client.app.bsky.unspecced.getTrends(input: .init(limit: 10))
                guard !Task.isCancelled, !appState.isAccountSwitchSuspended, appState.userDID == viewerDID else { return [] }
                return output?.trends ?? []
            }
            guard !Task.isCancelled, !appState.isAccountSwitchSuspended, appState.userDID == viewerDID else { return [] }
            appState.prefetchTopicPreviews(trends: trends, displayScale: displayScale, owner: .timeline)
            return trends
        } catch {
            return appState.trendingTopicMediaStore.cachedTrends(for: viewerDID)?.trends ?? []
        }
    }

    @MainActor
    private static func loadVideos(appState: AppState) async -> [AppBskyFeedDefs.FeedViewPost] {
        guard appState.appSettings.showTrendingVideos, let client = appState.atProtoClient else {
            return []
        }
        let viewerDID = appState.userDID
        do {
            let posts = try await appState.trendingTopicMediaStore.fetchOrCoalesceVideos(for: viewerDID) {
                let input = AppBskyFeedGetFeed.Parameters(
                    feed: try ATProtocolURI(uriString: TrendingVideosSection.thevidsURI),
                    limit: 10,
                    cursor: nil
                )
                let (_, response) = try await client.app.bsky.feed.getFeed(input: input)
                // An empty answer is never cached: a response for an account that was switched away from is dropped.
                guard !Task.isCancelled, !appState.isAccountSwitchSuspended, appState.userDID == viewerDID else { return [] }
                return response?.feed ?? []
            }
            // Previews the account's policy filters from lists are not kept; the
            // section re-filters with the live policy and covers moderated thumbnails.
            return TrendingVideoModeration.listed(posts, policy: appState.moderationPolicy)
        } catch {
            let cached = appState.trendingTopicMediaStore.cachedVideos(for: viewerDID)?.videos ?? []
            return TrendingVideoModeration.listed(cached, policy: appState.moderationPolicy)
        }
    }
}
