import Foundation
import Petrel

// MARK: - TrendingFeedEligibility

/// Decides which feed carries the trending interstitial: only the user's default
/// feed, the first pinned one, which is the feed the app opens on. Every other
/// feed stays free of it.
enum TrendingFeedEligibility {
  /// The feed identifier the app opens on for `pinnedFeeds`, using the same rules
  /// as the launch path (`ContentView.loadDefaultFeed`): a list URI opens a list,
  /// any other AT URI opens a feed, and anything else (the "following" timeline,
  /// or no pins at all) opens the timeline.
  static func defaultFeedIdentifier(pinnedFeeds: [String]) -> String {
    guard let first = pinnedFeeds.first,
      !SystemFeedTypes.isTimelineFeed(first),
      let uri = try? ATProtocolURI(uriString: first)
    else {
      return FetchType.timeline.identifier
    }
    if first.contains("/app.bsky.graph.list/") {
      return FetchType.list(uri).identifier
    }
    return FetchType.feed(uri).identifier
  }

  static func isEligible(feed: FetchType, pinnedFeeds: [String]) -> Bool {
    switch feed {
    case .author, .likes:
      return false
    case .timeline, .feed, .list:
      return feed.identifier == defaultFeedIdentifier(pinnedFeeds: pinnedFeeds)
    }
  }
}
