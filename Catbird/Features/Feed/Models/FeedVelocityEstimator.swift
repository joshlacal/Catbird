import Foundation
import Petrel

/// Human-friendly feed posting pace derived cheaply from fetched preview post timestamps.
struct FeedVelocityEstimate: Equatable, Sendable {
  let shortLabel: String
  let detailLabel: String
  let symbolName: String

  static let empty = FeedVelocityEstimate(
    shortLabel: "—",
    detailLabel: String(localized: "No recent posts", comment: "Feed activity detail when there are no recent posts"),
    symbolName: "minus.circle"
  )

  static let quiet = FeedVelocityEstimate(
    shortLabel: String(localized: "Quiet", comment: "Short feed activity badge when a feed rarely posts"),
    detailLabel: String(localized: "Last post >2w ago", comment: "Feed activity detail when the latest post is more than two weeks old"),
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
      return FeedVelocityEstimate(
        shortLabel: String(localized: "Active", comment: "Short feed activity badge when a post appeared within the past hour"),
        detailLabel: String(localized: "Posted <1h ago", comment: "Feed activity detail when the latest post is under an hour old"),
        symbolName: "bolt.fill"
      )
    } else if ageSeconds <= 86_400 {
      return FeedVelocityEstimate(
        shortLabel: String(localized: "~1/day", comment: "Short feed activity badge for roughly one post per day"),
        detailLabel: String(localized: "Recent post", comment: "Feed activity detail when a post appeared within the past day"),
        symbolName: "clock.fill"
      )
    }
    return FeedVelocityEstimate(
      shortLabel: String(localized: "~1/wk", comment: "Short feed activity badge for roughly one post per week"),
      detailLabel: String(localized: "Occasional", comment: "Feed activity detail for an occasionally updated feed"),
      symbolName: "calendar"
    )
  }

  private static func formatRate(postsPerHour: Double) -> FeedVelocityEstimate {
    if postsPerHour >= 100 {
      return FeedVelocityEstimate(
        shortLabel: String(localized: "100+/hr", comment: "Short feed activity badge for 100 or more posts per hour"),
        detailLabel: String(localized: "Firehose pace", comment: "Feed activity detail for an extremely high-volume feed"),
        symbolName: "flame.fill"
      )
    }
    if postsPerHour >= 0.95 {
      let rounded = max(1, Int(postsPerHour.rounded()))
      return FeedVelocityEstimate(
        shortLabel: String(
          localized: "~\(rounded)/hr",
          comment: "Short feed activity badge — variable is approximate posts per hour"
        ),
        detailLabel: rounded >= 20
          ? String(localized: "Very active", comment: "Feed activity detail for 20+ posts per hour")
          : String(localized: "Active hourly", comment: "Feed activity detail for hourly posts"),
        symbolName: rounded >= 20 ? "flame.fill" : "bolt.fill"
      )
    }

    let postsPerDay = postsPerHour * 24.0
    if postsPerDay >= 0.85 {
      let rounded = max(1, Int(postsPerDay.rounded()))
      return FeedVelocityEstimate(
        shortLabel: String(
          localized: "~\(rounded)/day",
          comment: "Short feed activity badge — variable is approximate posts per day"
        ),
        detailLabel: String(localized: "Daily posts", comment: "Feed activity detail for feeds posting daily"),
        symbolName: "clock.fill"
      )
    }

    let postsPerWeek = postsPerDay * 7.0
    if postsPerWeek >= 1.0 {
      let rounded = max(1, Int(postsPerWeek.rounded()))
      return FeedVelocityEstimate(
        shortLabel: String(
          localized: "~\(rounded)/wk",
          comment: "Short feed activity badge — variable is approximate posts per week"
        ),
        detailLabel: String(localized: "Weekly pace", comment: "Feed activity detail for feeds posting weekly"),
        symbolName: "calendar"
      )
    }

    return FeedVelocityEstimate(
      shortLabel: String(localized: "<1/wk", comment: "Short feed activity badge for fewer than one post per week"),
      detailLabel: String(localized: "Slow pace", comment: "Feed activity detail for infrequently updated feeds"),
      symbolName: "calendar"
    )
  }
}
