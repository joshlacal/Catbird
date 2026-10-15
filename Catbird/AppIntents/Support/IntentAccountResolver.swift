//
//  IntentAccountResolver.swift
//  Catbird
//
//  Resolves the active account DID from the shared app-group UserDefaults store
//  written by the main app / widgets, without touching AppState/AppStateManager
//  (App Intents can run out-of-process from the host app).
//

import Foundation

/// Resolves account identity for App Intents from the shared app group store.
enum IntentAccountResolver {
  static let appGroupSuiteName = "group.blue.catbird.shared"
  static let activeAccountDIDKey = "activeAccountDID"

  /// The store the active account is read from: the shared app group. Tests bind a private store
  /// for a task (`$store.withValue`) rather than writing the group the app, widgets and
  /// extensions share.
  @TaskLocal static var store: UserDefaults? = UserDefaults(suiteName: appGroupSuiteName)

  /// The DID of the currently active account, if any account has signed in
  /// and been synced to the app group store.
  static func activeDID() -> String? {
    store?.string(forKey: activeAccountDIDKey)
  }
}
