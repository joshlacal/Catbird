import Petrel

/// Projects in-app notification visibility without changing push, pagination, or read state.
enum NotificationListVisibilityPolicy {
  static func allows(
    _ notification: AppBskyNotificationListNotifications.Notification,
    preferences: NotificationPreferences
  ) -> Bool {
    switch notification.reason {
    case "follow":
      return allows(preferences.follow, author: notification.author)
    case "like":
      return allows(preferences.like, author: notification.author)
    case "like-via-repost":
      return allows(preferences.likeViaRepost, author: notification.author)
    case "mention":
      return allows(preferences.mention, author: notification.author)
    case "quote":
      return allows(preferences.quote, author: notification.author)
    case "reply":
      return allows(preferences.reply, author: notification.author)
    case "repost":
      return allows(preferences.repost, author: notification.author)
    case "repost-via-repost":
      return allows(preferences.repostViaRepost, author: notification.author)
    case "starterpack-joined":
      return preferences.starterpackJoined.list
    case "subscribed-post":
      return preferences.subscribedPost.list
    case "unverified":
      return preferences.unverified.list
    case "verified":
      return preferences.verified.list
    default:
      // Contact matches and future reasons have no corresponding preference here.
      return true
    }
  }

  /// Returns a filtered projection without changing the original groups or their members.
  /// Callers must group notifications by their hydrated subject before projecting them.
  static func visibleGroups(
    _ groups: [GroupedNotification],
    preferences: NotificationPreferences
  ) -> [GroupedNotification] {
    let visible = groups.enumerated().compactMap { index, group -> (index: Int, group: GroupedNotification)? in
      let notifications = group.notifications.filter {
        allows($0, preferences: preferences)
      }
      guard !notifications.isEmpty else { return nil }

      let projected = GroupedNotification(
        id: group.id,
        type: group.type,
        notifications: notifications,
        subjectPost: group.subjectPost,
        parentPost: group.parentPost,
        pageNumber: group.pageNumber
      )
      return (index, projected)
    }

    return visible.sorted { lhs, rhs in
      if lhs.group.pageNumber != rhs.group.pageNumber {
        return lhs.group.pageNumber < rhs.group.pageNumber
      }
      let lhsDate = lhs.group.latestNotification.indexedAt.date
      let rhsDate = rhs.group.latestNotification.indexedAt.date
      if lhsDate != rhsDate {
        return lhsDate > rhsDate
      }
      return lhs.index < rhs.index
    }.map { $0.group }
  }

  private static func allows(
    _ preference: AppBskyNotificationDefs.FilterablePreference,
    author: AppBskyActorDefs.ProfileView
  ) -> Bool {
    guard preference.list else { return false }
    // Unknown include values follow the upstream fallback to "all".
    guard preference.include == "follows" else { return true }
    // Missing relationship data cannot establish that the viewer follows this author.
    return author.viewer?.following != nil
  }
}
