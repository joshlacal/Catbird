import Foundation
import Petrel

/// What the notifications list needs from the engine: which groups it shows
/// and which authors it moderates. Mirrors `shouldFilterNotif`
/// (`state/queries/notifications/util.ts`) and the subject-post filter in
/// `state/queries/notifications/feed.ts` upstream.
enum NotificationModeration {
  typealias Notification = AppBskyNotificationListNotifications.Notification

  /// The group as the list shows it: `nil` when it is dropped, else the group
  /// with only the notifications whose authors the policy allows.
  static func visibleGroup(_ group: GroupedNotification, policy: ModerationPolicy) -> GroupedNotification? {
    switch group.type {
    case .reply, .mention, .quote:
      if let post = group.subjectPost, policy.listFilter(post: post) { return nil }
    default:
      break
    }
    let kept = group.notifications.filter { !isListFiltered($0, policy: policy) }
    guard !kept.isEmpty else { return nil }
    guard kept.count < group.notifications.count else { return group }
    return GroupedNotification(
      id: group.id, type: group.type, notifications: kept,
      subjectPost: group.subjectPost, parentPost: group.parentPost, pageNumber: group.pageNumber)
  }

  /// A notification is dropped when its author carries `!hide`, and otherwise
  /// when the author's account and profile labels and the notification's own
  /// labels filter it from lists, unless the viewer follows the author.
  ///
  /// Upstream also drops authors labelled `!takedown`. That value has no
  /// definition in the engine and the AppView delivers no notifications from
  /// accounts it has taken down, so it is not evaluated here.
  static func isListFiltered(_ notification: Notification, policy: ModerationPolicy) -> Bool {
    let list = decision(for: notification, policy: policy).ui(.contentList)
    if list.filters.contains(where: { $0.definition.identifier == "!hide" }) { return true }
    if notification.author.viewer?.following != nil { return false }
    return list.filter
  }

  /// `moderateNotification` upstream: the author's account and profile labels
  /// plus the labels on the notification record.
  static func decision(for notification: Notification, policy: ModerationPolicy) -> ModerationDecision {
    var decision = policy.decide(profile: notification.author)
    if let labels = notification.labels, !labels.isEmpty {
      let options = policy.options()
      for label in labels {
        decision.addLabel(label, target: .content, options: options)
      }
    }
    return decision
  }

  /// `ui(.avatar)` for a notification author: a concealed avatar is drawn as
  /// the neutral placeholder and never requested.
  static func concealsAvatar(of author: AppBskyActorDefs.ProfileView, policy: ModerationPolicy) -> Bool {
    policy.decide(profile: author).ui(.avatar).blur
  }
}
