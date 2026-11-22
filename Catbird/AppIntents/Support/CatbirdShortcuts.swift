//
//  CatbirdShortcuts.swift
//  Catbird
//
//  Central registry of Catbird's App Shortcuts (Siri / Spotlight / Shortcuts app).
//  Xcode's appintentsmetadataprocessor rejects an empty appShortcuts builder body
//  even though it typechecks, so the provider must always carry at least one
//  real shortcut. The curated MVP phrase set lands with the generated intents.
//

import AppIntents

@available(iOS 18.0, *)
struct CatbirdShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: CreatePostIntent(),
      phrases: [
        "Post to \(.applicationName)",
        "Write a \(.applicationName) post",
        "Create a post in \(.applicationName)",
      ],
      shortTitle: LocalizedStringResource(
        "Create Post",
        comment: "Short tile title for the Create Post App Shortcut."
      ),
      systemImageName: "square.and.pencil"
    )
    AppShortcut(
      intent: OpenTimelineIntent(),
      phrases: [
        "Show my \(.applicationName) timeline",
        "Open my \(.applicationName) timeline",
        "Get my \(.applicationName) feed",
        "What's new on \(.applicationName)",
      ],
      shortTitle: LocalizedStringResource(
        "Timeline",
        comment: "Short tile title for the Open Timeline App Shortcut."
      ),
      systemImageName: "list.bullet.rectangle"
    )
    AppShortcut(
      intent: SearchPostsIntent(),
      phrases: [
        "Search \(.applicationName) posts",
        "Search posts on \(.applicationName)",
      ],
      shortTitle: LocalizedStringResource(
        "Search Posts",
        comment: "Short tile title for the Search Posts App Shortcut."
      ),
      systemImageName: "magnifyingglass"
    )
    AppShortcut(
      intent: SearchProfilesIntent(),
      phrases: [
        "Search \(.applicationName) profiles",
        "Find someone on \(.applicationName)",
      ],
      shortTitle: LocalizedStringResource(
        "Search Profiles",
        comment: "Short tile title for the Search Profiles App Shortcut."
      ),
      systemImageName: "person.crop.circle.badge.magnifyingglass"
    )
    AppShortcut(
      intent: UnreadNotificationCountIntent(),
      phrases: [
        "How many unread \(.applicationName) notifications",
        "Check my \(.applicationName) notifications",
      ],
      shortTitle: LocalizedStringResource(
        "Unread Notifications",
        comment: "Short tile title for the Unread Notification Count App Shortcut."
      ),
      systemImageName: "bell.badge"
    )
    AppShortcut(
      intent: SendDirectMessageIntent(),
      phrases: [
        "Send a \(.applicationName) message",
        "Send a direct message on \(.applicationName)",
        "DM someone on \(.applicationName)",
      ],
      shortTitle: LocalizedStringResource(
        "Send Message",
        comment: "Short tile title for the Send Direct Message App Shortcut."
      ),
      systemImageName: "paperplane"
    )
    AppShortcut(
      intent: GetUnreadDMCountIntent(),
      phrases: [
        "Check my \(.applicationName) messages",
        "How many unread \(.applicationName) messages",
      ],
      shortTitle: LocalizedStringResource(
        "Unread Messages",
        comment: "Short tile title for the Unread Message Count App Shortcut."
      ),
      systemImageName: "bubble.left.and.bubble.right"
    )
    AppShortcut(
      intent: BlockProfileIntent(),
      phrases: [
        "Block someone on \(.applicationName)",
        "Block this person on \(.applicationName)",
        "Block this account on \(.applicationName)",
      ],
      shortTitle: LocalizedStringResource(
        "Block Profile",
        comment: "Short tile title for the Block Profile App Shortcut."
      ),
      systemImageName: "hand.raised"
    )
    AppShortcut(
      intent: LikePostIntent(),
      phrases: [
        "Like this post in \(.applicationName)",
        "Like this \(.applicationName) post",
        "Like a post on \(.applicationName)",
      ],
      shortTitle: LocalizedStringResource(
        "Like Post",
        comment: "Short tile title for the Like Post App Shortcut."
      ),
      systemImageName: "heart"
    )
    AppShortcut(
      intent: RepostPostIntent(),
      phrases: [
        "Repost this in \(.applicationName)",
        "Repost this \(.applicationName) post",
        "Repost a post on \(.applicationName)",
      ],
      shortTitle: LocalizedStringResource(
        "Repost",
        comment: "Short tile title (verb) for the Repost App Shortcut."
      ),
      systemImageName: "arrow.2.squarepath"
    )
  }
}

