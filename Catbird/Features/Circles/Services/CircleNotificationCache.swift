//
//  CircleNotificationCache.swift
//  Catbird
//

import Foundation
import Petrel
import PetrelCatbird

/// Memory-only cache for private Circle notifications, keyed by active account DID.
/// This store is strictly in-memory and isolated from public notifications.
final class CircleNotificationCache: @unchecked Sendable {
  static let shared = CircleNotificationCache()

  struct CacheEntry: Sendable {
    let notifications: [BlueCatbirdCircleDefs.Notification]
    let cursor: String?
  }

  private let lock = NSLock()
  private var store: [String: CacheEntry] = [:]
  private var generations: [String: UUID] = [:]

  func generation(accountDID: String) -> UUID {
    lock.withLock {
      if let generation = generations[accountDID] { return generation }
      let generation = UUID()
      generations[accountDID] = generation
      return generation
    }
  }

  #if DEBUG
  private var onPageFetch: (@Sendable () async -> Void)?

  func setOnPageFetch(_ hook: (@Sendable () async -> Void)?) {
    lock.withLock {
      self.onPageFetch = hook
    }
  }
  #endif

  func store(_ page: CircleNotificationPage, accountDID: String, generation: UUID) async {
    lock.withLock {
      guard generations[accountDID] == generation else { return }
      store[accountDID] = CacheEntry(notifications: page.notifications, cursor: page.cursor)
    }
  }

  func page(accountDID: String) async -> CircleNotificationPage? {
    let (cachedPage, generation): (CircleNotificationPage?, UUID?) = lock.withLock {
      let page = store[accountDID].map {
        CircleNotificationPage(notifications: $0.notifications, cursor: $0.cursor)
      }
      return (page, generations[accountDID])
    }
    #if DEBUG
    let hook = lock.withLock { onPageFetch }
    if let hook {
      await hook()
    }
    #endif
    return lock.withLock { generations[accountDID] == generation ? cachedPage : nil }
  }

  /// Purge every cached notification for an account (called on switch, logout, removal).
  func purge(accountDID: String) async {
    lock.withLock {
      generations[accountDID] = UUID()
      store.removeValue(forKey: accountDID)
    }
  }

  /// Purge cached notifications for one account in one Space (called on membership removal or space deletion).
  func purge(accountDID: String, space: SpaceRef) async {
    lock.withLock {
      generations[accountDID] = UUID()
      guard let entry = store[accountDID] else { return }
      let filtered = entry.notifications.filter { $0.circle.uri != space }
      store[accountDID] = CacheEntry(notifications: filtered, cursor: nil)
    }
  }

  /// Purge cached notifications for a Space across all accounts (called on space deletion).
  func purgeSpace(space: SpaceRef) async {
    lock.withLock {
      for accountDID in generations.keys { generations[accountDID] = UUID() }
      for (accountDID, entry) in store {
        let filtered = entry.notifications.filter { $0.circle.uri != space }
        store[accountDID] = CacheEntry(notifications: filtered, cursor: nil)
      }
    }
  }

  /// Purge cached notifications for a muted Space.
  func purgeMutedSpace(accountDID: String, space: SpaceRef) async {
    await purge(accountDID: accountDID, space: space)
  }

  func purgeAll() async {
    lock.withLock {
      for accountDID in generations.keys { generations[accountDID] = UUID() }
      store.removeAll()
    }
  }
}
