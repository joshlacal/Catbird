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
  private static let activeAccountDIDKey = "activeAccountDID"

  /// The DID of the currently active account, if any account has signed in
  /// and been synced to the app group store.
  static func activeDID() -> String? {
    UserDefaults(suiteName: appGroupSuiteName)?.string(forKey: activeAccountDIDKey)
  }
}
