//
//  AccountEntity.swift
//  CatbirdFeedWidget
//

#if os(iOS)
import AppIntents
import Foundation

@available(iOS 17.0, *)
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

@available(iOS 17.0, *)
struct AccountEntityQuery: EntityQuery {
  func entities(for identifiers: [String]) async throws -> [AccountEntity] {
    allAccounts().filter { identifiers.contains($0.id) }
  }

  func suggestedEntities() async throws -> [AccountEntity] {
    allAccounts()
  }

  func defaultResult() async -> AccountEntity? {
    let defaults = UserDefaults(suiteName: "group.blue.catbird.shared")
    let activeDID = defaults?.string(forKey: "activeAccountDID")
    let accounts = allAccounts()
    if let activeDID, let active = accounts.first(where: { $0.id == activeDID }) {
      return active
    }
    return accounts.first
  }

  private func allAccounts() -> [AccountEntity] {
    let defaults = UserDefaults(suiteName: "group.blue.catbird.shared")
    guard let data = defaults?.data(forKey: "widgetAccounts") else { return [] }

    // WidgetAccount is defined in FeedWidgetModels.swift
    guard let accounts = try? JSONDecoder().decode([WidgetAccount].self, from: data) else {
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
#endif
