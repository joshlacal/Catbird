//
//  AccountEntity.swift
//  Catbird
//
//  App-target copy of CatbirdFeedWidget/Shared/AccountEntity.swift. The widget's
//  copy is only shared into the CatbirdFeedWidgetExtension and
//  NotificationServiceExtension targets (see project.pbxproj membership
//  exceptions), not the main app target, so App Intents living in the app
//  target need their own AppEntity backed by the same app-group UserDefaults
//  contract ("widgetAccounts" / "activeAccountDID" in group.blue.catbird.shared).
//

import AppIntents
import Foundation

/// An account App Intents can resolve as a parameter (e.g. "post as Account").
@available(iOS 18.0, *)
struct AccountEntity: AppEntity {
  static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Account")
  static var defaultQuery = AccountEntityQuery()

  let id: String  // DID
  let handle: String
  let displayName: String
  let avatarURL: URL?

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: "\(displayName)",
      subtitle: "@\(handle)"
    )
  }
}

@available(iOS 18.0, *)
struct AccountEntityQuery: EntityQuery {
  func entities(for identifiers: [String]) async throws -> [AccountEntity] {
    Self.allAccounts().filter { identifiers.contains($0.id) }
  }

  func suggestedEntities() async throws -> [AccountEntity] {
    Self.allAccounts()
  }

  func defaultResult() async -> AccountEntity? {
    let accounts = Self.allAccounts()
    if let activeDID = IntentAccountResolver.activeDID(),
      let active = accounts.first(where: { $0.id == activeDID })
    {
      return active
    }
    return accounts.first
  }

  fileprivate static func allAccounts() -> [AccountEntity] {
    let defaults = UserDefaults(suiteName: IntentAccountResolver.appGroupSuiteName)
    guard let data = defaults?.data(forKey: "widgetAccounts") else { return [] }

    guard let accounts = try? JSONDecoder().decode([IntentWidgetAccount].self, from: data) else {
      return []
    }
    return accounts.map {
      AccountEntity(
        id: $0.did,
        handle: $0.handle,
        displayName: $0.displayName,
        avatarURL: $0.avatarURL.flatMap(URL.init)
      )
    }
  }
}

/// Decoding mirror of `WidgetAccount` (CatbirdFeedWidget/FeedWidgetModels.swift),
/// which lives in a target this one doesn't share code with. Field layout must
/// stay in sync with the widget's copy since both decode the same app-group blob.
struct IntentWidgetAccount: Codable {
  let did: String
  let handle: String
  let displayName: String
  let avatarURL: String?
}
