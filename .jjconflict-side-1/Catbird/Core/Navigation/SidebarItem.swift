#if os(macOS)
import Foundation

/// Represents a selectable item in the macOS unified sidebar.
/// Functional items (search, notifications, chat, profile) are fixed at the top.
/// Feed items are dynamic based on the user's pinned/saved feeds.
enum SidebarItem: Hashable, Sendable {
  case search
  case notifications
  case chat
  case profile
  case feed(FetchType)

  /// SF Symbol name for sidebar row icon
  var systemImage: String {
    switch self {
    case .search: return "magnifyingglass"
    case .notifications: return "bell"
    case .chat: return "bubble.left.and.bubble.right"
    case .profile: return "person"
    case .feed: return "number"
    }
  }

  /// Display label for sidebar row
  var label: String {
    switch self {
    case .search: return "Search"
    case .notifications: return "Notifications"
    case .chat: return "Chat"
    case .profile: return "Profile"
    case .feed: return "Feed" // Overridden by feed-specific name in sidebar
    }
  }
}
#endif
