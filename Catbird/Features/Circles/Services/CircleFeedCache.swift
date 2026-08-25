import Foundation
import Petrel
import PetrelCatbird

/// Memory-only cache for Circle feed pages, keyed by active account DID and
/// Space URI. This namespace is intentionally separate from public feed
/// persistence (`CachedFeedViewPost`, `DatabaseModelActor`); Circle content
/// never enters the public cache.
final class CircleFeedCache: @unchecked Sendable {
  static let shared = CircleFeedCache()

  struct Key: Hashable, Sendable {
    let accountDID: String
    let spaceURI: String?
  }

  private let lock = NSLock()
  private var pages: [Key: CircleFeedPage] = [:]

  #if DEBUG
  private var onPageFetch: (@Sendable () async -> Void)?

  func setOnPageFetch(_ hook: (@Sendable () async -> Void)?) {
    lock.withLock {
      self.onPageFetch = hook
    }
  }
  #endif

  func store(_ page: CircleFeedPage, accountDID: String, space: SpaceRef?) async {
    let spaceURI = space.map { $0.description }
    lock.withLock {
      pages[Key(accountDID: accountDID, spaceURI: spaceURI)] = page
    }
  }

  func page(accountDID: String, space: SpaceRef?) async -> CircleFeedPage? {
    #if DEBUG
    let hook = lock.withLock { onPageFetch }
    if let hook {
      await hook()
    }
    #endif
    let spaceURI = space.map { $0.description }
    return lock.withLock {
      pages[Key(accountDID: accountDID, spaceURI: spaceURI)]
    }
  }

  /// Purge every cached page for an account (called on switch, logout, removal).
  func purge(accountDID: String) async {
    lock.withLock {
      pages = pages.filter { $0.key.accountDID != accountDID }
    }
  }

  /// Purge cached pages for one account in one Space.
  func purge(accountDID: String, space: SpaceRef) async {
    lock.withLock {
      pages.removeValue(forKey: Key(accountDID: accountDID, spaceURI: space.description))
    }
  }

  /// Purge cached posts for a muted Space from the unified feed cache (space: nil).
  func purgeMutedSpaceFromUnified(accountDID: String, space: SpaceRef) async {
    lock.withLock {
      let key = Key(accountDID: accountDID, spaceURI: nil)
      if let unifiedPage = pages[key] {
        let filteredItems = unifiedPage.items.filter { $0.circle.uri != space }
        pages[key] = CircleFeedPage(items: filteredItems, cursor: unifiedPage.cursor)
      }
    }
  }
}
