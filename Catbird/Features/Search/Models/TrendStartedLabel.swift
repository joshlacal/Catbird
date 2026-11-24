import Foundation

/// How long ago a trending topic started: "just now", "45 mins ago", "3 hours ago",
/// "11 days ago". Long-running trends roll over to days instead of "264 hours ago".
enum TrendStartedLabel {
  static func text(since date: Date, now: Date = Date()) -> String {
    let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
    let hours = minutes / 60
    let days = hours / 24
    if days > 0 {
      return String(
        localized: "\(days) days ago",
        comment: "Relative time since a trending topic started, in days."
      )
    } else if hours > 0 {
      return String(
        localized: "\(hours) hours ago",
        comment: "Relative time since a trending topic started, in hours."
      )
    } else if minutes > 0 {
      return String(
        localized: "\(minutes) mins ago",
        comment: "Relative time since a trending topic started, in minutes."
      )
    } else {
      return String(
        localized: "just now",
        comment: "Relative time when a trending topic started less than a minute ago."
      )
    }
  }
}
