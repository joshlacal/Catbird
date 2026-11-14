import Foundation
import Petrel
import PetrelCatbird

/// Memory-only cache for Circle feed pages, keyed by active account DID and
/// Space URI. This namespace is intentionally separate from public feed
/// persistence (`CachedFeedViewPost`, `DatabaseModelActor`); Circle content
/// never enters the public cache.
///
/// Encrypted Circles: stored pages hold envelopes only. Decrypted posts live in
/// the separate per-account `opened` store, keyed by `(uri, cid)`, which is the
/// ONLY place decrypted Circle content is kept. It is memory-only and is purged
/// with the account (logout, switch, removal) and with its Space.
final class CircleFeedCache: @unchecked Sendable {
  static let shared = CircleFeedCache()

  struct Key: Hashable, Sendable {
    let accountDID: String
    let spaceURI: String?
  }

  struct OpenedKey: Hashable, Sendable {
    let accountDID: String
    let uri: String
    let cid: String
  }

  private struct OpenedEntry {
    let spaceURI: String
    let payload: CircleOpenedPayload
  }

  private let lock = NSLock()
  private var pages: [Key: CircleFeedPage] = [:]
  private var opened: [OpenedKey: OpenedEntry] = [:]
  private var generations: [String: UUID] = [:]

  /// The decrypted payload for `(uri, cid)`, if this account opened it before
  /// in `space`. A payload opened under another Space is never returned.
  func openedPayload(accountDID: String, space: SpaceRef, uri: ATProtocolURI, cid: CID) -> CircleOpenedPayload? {
    openedPayload(accountDID: accountDID, space: space, uri: uri, cid: CIDString(cid))
  }

  func openedPayload(accountDID: String, space: SpaceRef, uri: ATProtocolURI, cid: CIDString) -> CircleOpenedPayload? {
    lock.withLock {
      guard let entry = opened[OpenedKey(accountDID: accountDID, uri: uri.uriString(), cid: cid.string)],
            entry.spaceURI == space.description
      else { return nil }
      return entry.payload
    }
  }

  /// Memoizes an opened payload. Dropped when the account or Space was purged
  /// since `generation` was read, so an in-flight open cannot repopulate it.
  func storeOpened(
    _ payload: CircleOpenedPayload, accountDID: String, space: SpaceRef, uri: ATProtocolURI, cid: CID, generation: UUID
  ) {
    storeOpened(payload, accountDID: accountDID, space: space, uri: uri, cid: CIDString(cid), generation: generation)
  }

  func storeOpened(
    _ payload: CircleOpenedPayload, accountDID: String, space: SpaceRef, uri: ATProtocolURI, cid: CIDString, generation: UUID
  ) {
    lock.withLock {
      guard generations[accountDID] == generation else { return }
      opened[OpenedKey(accountDID: accountDID, uri: uri.uriString(), cid: cid.string)] =
        OpenedEntry(spaceURI: space.description, payload: payload)
    }
  }

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

  func store(_ page: CircleFeedPage, accountDID: String, space: SpaceRef?, generation: UUID) async {
    let spaceURI = space.map { $0.description }
    lock.withLock {
      guard generations[accountDID] == generation else { return }
      pages[Key(accountDID: accountDID, spaceURI: spaceURI)] = page
    }
  }

  func page(accountDID: String, space: SpaceRef?) async -> CircleFeedPage? {
    let spaceURI = space.map { $0.description }
    let (cachedPage, generation) = lock.withLock {
      (pages[Key(accountDID: accountDID, spaceURI: spaceURI)], generations[accountDID])
    }
    #if DEBUG
    let hook = lock.withLock { onPageFetch }
    if let hook {
      await hook()
    }
    #endif
    return lock.withLock { generations[accountDID] == generation ? cachedPage : nil }
  }

  /// Purge every cached page for an account (called on switch, logout, removal).
  func purge(accountDID: String) async {
    lock.withLock {
      generations[accountDID] = UUID()
      pages = pages.filter { $0.key.accountDID != accountDID }
      opened = opened.filter { $0.key.accountDID != accountDID }
    }
  }

  /// Remove a Space from both its dedicated page and the aggregate page.
  func purge(accountDID: String, space: SpaceRef) async {
    lock.withLock {
      generations[accountDID] = UUID()
      pages.removeValue(forKey: Key(accountDID: accountDID, spaceURI: space.description))
      opened = opened.filter { $0.key.accountDID != accountDID || $0.value.spaceURI != space.description }
      let aggregateKey = Key(accountDID: accountDID, spaceURI: nil)
      if let aggregate = pages[aggregateKey] {
        pages[aggregateKey] = CircleFeedPage(
          items: aggregate.items.filter { $0.circle.uri != space }, cursor: nil
        )
      }
    }
  }

  /// Purge cached posts for a muted Space from the unified feed cache (space: nil).
  func purgeMutedSpaceFromUnified(accountDID: String, space: SpaceRef) async {
    lock.withLock {
      generations[accountDID] = UUID()
      let key = Key(accountDID: accountDID, spaceURI: nil)
      if let unifiedPage = pages[key] {
        let filteredItems = unifiedPage.items.filter { $0.circle.uri != space }
        pages[key] = CircleFeedPage(items: filteredItems, cursor: unifiedPage.cursor)
      }
    }
  }
}
