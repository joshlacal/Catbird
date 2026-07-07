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
      intent: ComposePostIntent(),
      phrases: [
        "Compose a post in \(.applicationName)",
        "Write a \(.applicationName) post",
        "Post to \(.applicationName)",
      ],
      shortTitle: "Compose Post",
      systemImageName: "square.and.pencil"
    )
  }
}
