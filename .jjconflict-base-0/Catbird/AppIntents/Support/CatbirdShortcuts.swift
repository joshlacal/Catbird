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
      shortTitle: "Create Post",
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
      shortTitle: "Timeline",
      systemImageName: "list.bullet.rectangle"
    )
    AppShortcut(
      intent: SearchPostsIntent(),
      phrases: [
        "Search \(.applicationName) posts",
        "Search posts on \(.applicationName)",
      ],
      shortTitle: "Search Posts",
      systemImageName: "magnifyingglass"
    )
    AppShortcut(
      intent: SearchProfilesIntent(),
      phrases: [
        "Search \(.applicationName) profiles",
        "Find someone on \(.applicationName)",
      ],
      shortTitle: "Search Profiles",
      systemImageName: "person.crop.circle.badge.magnifyingglass"
    )
    AppShortcut(
      intent: UnreadNotificationCountIntent(),
      phrases: [
        "How many unread \(.applicationName) notifications",
        "Check my \(.applicationName) notifications",
      ],
      shortTitle: "Unread Notifications",
      systemImageName: "bell.badge"
    )
    AppShortcut(
      intent: SendDirectMessageIntent(),
      phrases: [
        "Send a \(.applicationName) message",
        "Send a direct message on \(.applicationName)",
        "DM someone on \(.applicationName)",
      ],
      shortTitle: "Send Message",
      systemImageName: "paperplane"
    )
    AppShortcut(
      intent: GetUnreadDMCountIntent(),
      phrases: [
        "Check my \(.applicationName) messages",
        "How many unread \(.applicationName) messages",
      ],
      shortTitle: "Unread Messages",
      systemImageName: "bubble.left.and.bubble.right"
    )
    AppShortcut(
      intent: BlockProfileIntent(),
      phrases: [
        "Block someone on \(.applicationName)",
        "Block this person on \(.applicationName)",
        "Block this guy on \(.applicationName)",
      ],
      shortTitle: "Block Profile",
      systemImageName: "hand.raised"
    )
    AppShortcut(
      intent: LikePostIntent(),
      phrases: [
        "Like this post in \(.applicationName)",
        "Like this \(.applicationName) post",
        "Like a post on \(.applicationName)",
      ],
      shortTitle: "Like Post",
      systemImageName: "heart"
    )
    AppShortcut(
      intent: RepostPostIntent(),
      phrases: [
        "Repost this in \(.applicationName)",
        "Repost this \(.applicationName) post",
        "Repost a post on \(.applicationName)",
      ],
      shortTitle: "Repost",
      systemImageName: "arrow.2.squarepath"
    )
  }
}

