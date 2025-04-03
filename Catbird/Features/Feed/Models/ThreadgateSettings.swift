import Foundation
import Petrel

struct ThreadgateSettings: Equatable {
  enum ReplyOption: String, CaseIterable, Identifiable {
    case everybody = "Everybody"
    case nobody = "Nobody"
    case mentioned = "Mentioned users"
    case following = "Users you follow"
    case followers = "Your followers"

    var id: String { self.rawValue }

    var iconName: String {
      switch self {
      case .everybody: return "globe"
      case .nobody: return "person.crop.circle.badge.xmark"
      case .mentioned: return "at"
      case .following: return "person.2"
      case .followers: return "person.3"
      }
    }
  }

  var allowEverybody: Bool = true
  var allowNobody: Bool = false
  var allowMentioned: Bool = false
  var allowFollowing: Bool = false
  var allowFollowers: Bool = false

  // Convert settings to AppBskyFeedThreadgateAllowUnion array
  func toAllowUnions() -> [AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion] {
    var allowUnions: [AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion] = []

    if allowMentioned {
      allowUnions.append(.appBskyFeedThreadgateMentionRule(AppBskyFeedThreadgate.MentionRule()))
    }
    if allowFollowing {
      allowUnions.append(.appBskyFeedThreadgateFollowingRule(AppBskyFeedThreadgate.FollowingRule()))
    }
    if allowFollowers {
      allowUnions.append(.appBskyFeedThreadgateFollowerRule(AppBskyFeedThreadgate.FollowerRule()))
    }

    return allowUnions
  }

  // Determine if posting is allowed based on settings
  var isReplyingAllowed: Bool {
    return allowEverybody || allowMentioned || allowFollowing || allowFollowers
  }

  // Get the primary option for display
  var primaryOption: ReplyOption {
    if allowEverybody {
      return .everybody
    } else if allowNobody {
      return .nobody
    } else if allowMentioned || allowFollowing || allowFollowers {
      // Return the first enabled option for display purposes
      if allowMentioned { return .mentioned }
      if allowFollowing { return .following }
      if allowFollowers { return .followers }
    }

    // Default
    return .everybody
  }

  // Get all enabled options for multiple selection
  var enabledOptions: [ReplyOption] {
    var options: [ReplyOption] = []

    if allowMentioned { options.append(.mentioned) }
    if allowFollowing { options.append(.following) }
    if allowFollowers { options.append(.followers) }

    return options
  }

  // Update based on selected option
  mutating func selectOption(_ option: ReplyOption) {
    // Reset all settings
    allowEverybody = false
    allowNobody = false
    allowMentioned = false
    allowFollowing = false
    allowFollowers = false

    // Set the selected option
    switch option {
    case .everybody:
      allowEverybody = true
    case .nobody:
      allowNobody = true
    case .mentioned:
      allowMentioned = true
    case .following:
      allowFollowing = true
    case .followers:
      allowFollowers = true
    }
  }

  // Toggle individual settings for combined options
  mutating func toggleOption(_ option: ReplyOption) {
    switch option {
    case .mentioned:
      allowMentioned.toggle()
      updateAfterToggle()
    case .following:
      allowFollowing.toggle()
      updateAfterToggle()
    case .followers:
      allowFollowers.toggle()
      updateAfterToggle()
    case .everybody:
      selectOption(.everybody)
    case .nobody:
      selectOption(.nobody)
    }
  }

  // Helper to update state after toggling an option
  private mutating func updateAfterToggle() {
    // If any option is selected, we're not in "everybody" or "nobody" mode
    allowEverybody = false
    allowNobody = false

    // If no options are selected, default back to everybody
    if !allowMentioned && !allowFollowing && !allowFollowers {
      allowEverybody = true
    }
  }
}
