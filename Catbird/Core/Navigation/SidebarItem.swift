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

  /// Localized display label resource for sidebar row
  var localizedLabel: LocalizedStringResource {
    switch self {
    case .search: return LocalizedStringResource("Search", comment: "macOS sidebar item label for Search.")
    case .notifications: return LocalizedStringResource("Notifications", comment: "macOS sidebar item label for Notifications.")
    case .chat: return LocalizedStringResource("Chat", comment: "macOS sidebar item label for Chat.")
    case .profile: return LocalizedStringResource("Profile", comment: "macOS sidebar item label for Profile.")
    case .feed: return LocalizedStringResource("Feed", comment: "macOS sidebar fallback item label for a feed.")
    }
  }

  /// Display label for sidebar row
  var label: String {
    String(localized: localizedLabel)
  }
}
#endif
