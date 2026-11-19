import Foundation
import Petrel

/// Human-friendly feed posting pace derived cheaply from fetched preview post timestamps.
struct FeedVelocityEstimate: Equatable, Sendable {
  let shortLabel: String
  let detailLabel: String
  let symbolName: String

  static let empty = FeedVelocityEstimate(
    shortLabel: "—",
    detailLabel: "No recent posts",
    symbolName: "minus.circle"
  )

  static let quiet = FeedVelocityEstimate(
    shortLabel: "Quiet",
    detailLabel: "Last post >2w ago",
    symbolName: "moon.zzz"
  )
}

/// Pure velocity calculator over preview posts so the product page immediately communicates
/// whether a feed is a firehose, active hourly/daily, or quiet.
enum FeedVelocityEstimator {
  static func estimate(
    from posts: [AppBskyFeedDefs.FeedViewPost],
    now: Date = Date()
  ) -> FeedVelocityEstimate {
    let timestamps: [Date] = posts.map { item in
      if case .knownType(let raw) = item.post.record, let feedPost = raw as? AppBskyFeedPost {
        return feedPost.createdAt.date
      }
      return item.post.indexedAt.date
    }
    return estimate(from: timestamps, now: now)
  }

  static func estimate(
    from timestamps: [Date],
    now: Date = Date()
  ) -> FeedVelocityEstimate {
    guard !timestamps.isEmpty else { return .empty }

    let sorted = timestamps.sorted(by: >)
    let newest = sorted[0]
    let oldest = sorted[sorted.count - 1]
    let ageOfNewest = max(0, now.timeIntervalSince(newest))
    if ageOfNewest > 14 * 86_400 {
      return .quiet
    }

    if sorted.count == 1 {
      return singlePostEstimate(ageSeconds: ageOfNewest)
    }

    // Use the larger of (now - oldest) and (newest - oldest) so a burst of 5 posts
    // from days ago isn't misreported as a live hourly firehose.
    let effectiveSpanSeconds = max(
      max(0, now.timeIntervalSince(oldest)),
      max(0, newest.timeIntervalSince(oldest)),
      60
    )
    let postsPerHour = Double(sorted.count) / (effectiveSpanSeconds / 3_600.0)
    return formatRate(postsPerHour: postsPerHour)
  }

  private static func singlePostEstimate(ageSeconds: TimeInterval) -> FeedVelocityEstimate {
    if ageSeconds <= 3_600 {
      return FeedVelocityEstimate(shortLabel: "Active", detailLabel: "Posted <1h ago", symbolName: "bolt.fill")
    } else if ageSeconds <= 86_400 {
      return FeedVelocityEstimate(shortLabel: "~1/day", detailLabel: "Recent post", symbolName: "clock.fill")
    }
    return FeedVelocityEstimate(shortLabel: "~1/wk", detailLabel: "Occasional", symbolName: "calendar")
  }

  private static func formatRate(postsPerHour: Double) -> FeedVelocityEstimate {
    if postsPerHour >= 100 {
      return FeedVelocityEstimate(shortLabel: "100+/hr", detailLabel: "Firehose pace", symbolName: "flame.fill")
    }
    if postsPerHour >= 0.95 {
      let rounded = max(1, Int(postsPerHour.rounded()))
      return FeedVelocityEstimate(
        shortLabel: "~\(rounded)/hr",
        detailLabel: rounded >= 20 ? "Very active" : "Active hourly",
        symbolName: rounded >= 20 ? "flame.fill" : "bolt.fill"
      )
    }

    let postsPerDay = postsPerHour * 24.0
    if postsPerDay >= 0.85 {
      let rounded = max(1, Int(postsPerDay.rounded()))
      return FeedVelocityEstimate(shortLabel: "~\(rounded)/day", detailLabel: "Daily posts", symbolName: "clock.fill")
    }

    let postsPerWeek = postsPerDay * 7.0
    if postsPerWeek >= 1.0 {
      let rounded = max(1, Int(postsPerWeek.rounded()))
      return FeedVelocityEstimate(shortLabel: "~\(rounded)/wk", detailLabel: "Weekly pace", symbolName: "calendar")
    }

    return FeedVelocityEstimate(shortLabel: "<1/wk", detailLabel: "Slow pace", symbolName: "calendar")
  }
}
