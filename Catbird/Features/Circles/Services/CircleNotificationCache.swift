//
//  CircleNotificationCache.swift
//  Catbird
//

import Foundation
import Petrel
import PetrelCatbird

/// Memory-only cache for private Circle notifications, keyed by active account DID.
/// This store is strictly in-memory and isolated from public notifications.
actor CircleNotificationCache {
  static let shared = CircleNotificationCache()

  struct CacheEntry: Sendable {
    let notifications: [BlueCatbirdCircleDefs.Notification]
    let cursor: String?
  }

  private var store: [String: CacheEntry] = [:]

  func store(_ page: CircleNotificationPage, accountDID: String) {
    store[accountDID] = CacheEntry(notifications: page.notifications, cursor: page.cursor)
  }

  func page(accountDID: String) -> CircleNotificationPage? {
    guard let entry = store[accountDID] else { return nil }
    return CircleNotificationPage(notifications: entry.notifications, cursor: entry.cursor)
  }

  /// Purge every cached notification for an account (called on switch, logout, removal).
  func purge(accountDID: String) {
    store.removeValue(forKey: accountDID)
  }

  /// Purge cached notifications for one account in one Space (called on membership removal or space deletion).
  func purge(accountDID: String, space: SpaceRef) {
    guard let entry = store[accountDID] else { return }
    let filtered = entry.notifications.filter { $0.circle.uri != space }
    store[accountDID] = CacheEntry(notifications: filtered, cursor: entry.cursor)
  }

  /// Purge cached notifications for a Space across all accounts (called on space deletion).
  func purgeSpace(space: SpaceRef) {
    for (accountDID, entry) in store {
      let filtered = entry.notifications.filter { $0.circle.uri != space }
      store[accountDID] = CacheEntry(notifications: filtered, cursor: entry.cursor)
    }
  }

  /// Purge cached notifications for a muted Space.
  func purgeMutedSpace(accountDID: String, space: SpaceRef) {
    purge(accountDID: accountDID, space: space)
  }

  func purgeAll() {
    store.removeAll()
  }
}
