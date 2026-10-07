import Foundation

/// How long ago a trending topic started: "just now", "45 mins ago", "3 hours ago",
/// "11 days ago". Long-running trends roll over to days instead of "264 hours ago".
enum TrendStartedLabel {
  static func text(since date: Date, now: Date = Date()) -> String {
    let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
    let hours = minutes / 60
    let days = hours / 24
    if days > 0 {
      return days == 1 ? "1 day ago" : "\(days) days ago"
    } else if hours > 0 {
      return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
    } else if minutes > 0 {
      return minutes == 1 ? "1 min ago" : "\(minutes) mins ago"
    } else {
      return "just now"
    }
  }
}
