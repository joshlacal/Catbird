import Foundation

/// Enum representing different tabs/sections in a user profile
enum ProfileTab: String, CaseIterable, Hashable {
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
}