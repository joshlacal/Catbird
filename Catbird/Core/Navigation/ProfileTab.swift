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
  case videos
  case more

  var localizedTitle: LocalizedStringResource {
    switch self {
    case .labelerInfo: return LocalizedStringResource("Labels", comment: "Profile tab title for moderation labeler definitions.")
    case .posts: return LocalizedStringResource("Posts", comment: "Profile tab title for authored posts.")
    case .replies: return LocalizedStringResource("Replies", comment: "Profile tab title for replies.")
    case .media: return LocalizedStringResource("Media", comment: "Profile tab title for photos and videos.")
    case .likes: return LocalizedStringResource("Likes", comment: "Profile tab title for liked posts.")
    case .lists: return LocalizedStringResource("Lists", comment: "Profile tab title for user lists.")
    case .starterPacks: return LocalizedStringResource("Starter Packs", comment: "Profile tab title for starter packs.")
    case .feeds: return LocalizedStringResource("Feeds", comment: "Profile tab title for custom feeds.")
    case .videos: return LocalizedStringResource("Streamplace Videos", comment: "Profile tab title for Streamplace videos.")
    case .more: return LocalizedStringResource("More", comment: "Profile tab title for additional sections.")
    }
  }

  var title: String {
    String(localized: localizedTitle)
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
    case .videos: return "play.rectangle.fill"
    case .more: return "ellipsis"
    }
  }
  
  var localizedSubtitle: LocalizedStringResource {
    switch self {
    case .labelerInfo: return LocalizedStringResource("Labels and settings", comment: "Profile tab subtitle for labeler info.")
    case .posts: return LocalizedStringResource("View all posts", comment: "Profile tab subtitle for posts.")
    case .replies: return LocalizedStringResource("Replies to others", comment: "Profile tab subtitle for replies.")
    case .media: return LocalizedStringResource("Photos and videos", comment: "Profile tab subtitle for media.")
    case .likes: return LocalizedStringResource("Liked posts", comment: "Profile tab subtitle for likes.")
    case .lists: return LocalizedStringResource("User lists", comment: "Profile tab subtitle for lists.")
    case .starterPacks: return LocalizedStringResource("Curated starter packs", comment: "Profile tab subtitle for starter packs.")
    case .feeds: return LocalizedStringResource("Custom feeds", comment: "Profile tab subtitle for custom feeds.")
    case .videos: return LocalizedStringResource("Streamplace Video-on-Demand", comment: "Profile tab subtitle for Streamplace videos.")
    case .more: return LocalizedStringResource("Additional options", comment: "Profile tab subtitle for extra profile sections.")
    }
  }

  var subtitle: String {
    String(localized: localizedSubtitle)
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
