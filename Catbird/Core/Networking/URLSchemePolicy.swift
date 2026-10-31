import Foundation

/// Dispatch policy for links received from posts, profiles, and message embeds.
/// Petrel preserves the original wire URL; deciding which schemes can leave the
/// app belongs here rather than in URI decoding.
enum URLSchemePolicy {
  static func isWeb(_ url: URL) -> Bool {
    switch url.scheme?.lowercased() {
    case "http", "https": return true
    default: return false
    }
  }

  static func allowsSystemOpen(_ url: URL) -> Bool {
    switch url.scheme?.lowercased() {
    case "http", "https", "mailto", "tel", "sms": return true
    default: return false
    }
  }

  static func isBluesky(_ url: URL) -> Bool {
    if url.scheme?.lowercased() == "bluesky" { return true }
    guard isWeb(url) else { return false }
    switch url.host?.lowercased() {
    case "bsky.app", "main.bsky.dev", "staging.bsky.app", "go.bsky.app": return true
    default: return false
    }
  }
}
