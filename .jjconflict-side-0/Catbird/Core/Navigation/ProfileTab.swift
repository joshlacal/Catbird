import Foundation

/// Enum representing different tabs/sections in a user profile
enum ProfileTab: String, CaseIterable, Hashable {
  case labelerInfo  // First tab for labeler profiles
  case posts
  case replies
  case media
  case likes
  case lists
  case starterPacks
  case feeds
  case more

  var title: String {
    switch self {
    case .labelerInfo: return "Labels"
    case .posts: return "Posts"
    case .replies: return "Replies"
    case .media: return "Media"
    case .likes: return "Likes"
    case .lists: return "Lists"
    case .starterPacks: return "Starter Packs"
    case .feeds: return "Feeds"
    case .more: return "More"
    }
  }
  
  var systemImage: String {
    switch self {
    case .labelerInfo: return "checkmark.shield"
    case .posts: return "doc.text"
    case .replies: return "arrowshape.turn.up.left"
    case .media: return "photo"
    case .likes: return "heart"
    case .lists: return "list.bullet"
    case .starterPacks: return "star.circle"
    case .feeds: return "lines.measurement.horizontal"
    case .more: return "ellipsis"
    }
  }
  
  var subtitle: String {
    switch self {
    case .labelerInfo: return "Labels and settings"
    case .posts: return "View all posts"
    case .replies: return "Replies to others"
    case .media: return "Photos and videos"
    case .likes: return "Liked posts"
    case .lists: return "User lists"
    case .starterPacks: return "Curated starter packs"
    case .feeds: return "Custom feeds"
    case .more: return "Additional options"
    }
  }
  
  /// Returns the tabs visible for a labeler profile
  static var labelerTabs: [ProfileTab] {
    [.labelerInfo, .posts, .replies]
  }
  
  /// Returns the tabs visible for a regular user profile  
  static var userTabs: [ProfileTab] {
    [.posts, .replies, .media, .more]
  }
}
