//
//  CatbirdShortcuts.swift
//  Catbird
//
//  Central registry of Catbird's App Shortcuts (Siri / Spotlight / Shortcuts app).
//  Xcode's appintentsmetadataprocessor rejects an empty appShortcuts builder body
//  even though it typechecks, so the provider must always carry at least one
//  real shortcut. Apple enforces a hard cap of 10 shortcuts per provider.
//

import AppIntents

@available(iOS 18.0, *)
struct CatbirdShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: ComposePostIntent(),
      phrases: [
        "Compose a post in \(.applicationName)",
        "Write a \(.applicationName) post",
        "Post to \(.applicationName)",
      ],
      shortTitle: "Compose Post",
      systemImageName: "square.and.pencil"
    )
    AppShortcut(
      intent: OpenTimelineIntent(),
      phrases: [
        "Open \(.applicationName) timeline",
        "Show my \(.applicationName) feed",
        "Open \(.applicationName)",
      ],
      shortTitle: "Open Timeline",
      systemImageName: "list.bullet"
    )
    AppShortcut(
      intent: LikePostIntent(),
      phrases: [
        "Like this post in \(.applicationName)",
        "Like this \(.applicationName) post",
        "Heart this post in \(.applicationName)",
      ],
      shortTitle: "Like Post",
      systemImageName: "heart"
    )
    AppShortcut(
      intent: RepostPostIntent(),
      phrases: [
        "Repost this in \(.applicationName)",
        "Repost this \(.applicationName) post",
        "Repost in \(.applicationName)",
      ],
      shortTitle: "Repost",
      systemImageName: "repeat"
    )
  }
}
