//
//  CircleFeedModel.swift
//  Catbird
//

import Foundation
import Observation
import Petrel
import PetrelCatbird

/// View model for unified or per-Circle feeds.
///
/// Backed exclusively by memory caching (`CircleFeedCache`). Never routes
/// through public feed persistence (`FeedModel`, `CachedFeedViewPost`, or
/// `DatabaseModelActor`). Access state transitions (.expired, .removed,
/// .unsupported) are modeled explicitly.
///
/// Encrypted Circles (spec §4.5, §6 rule 9, Review Focus 5): `items` keep the
/// envelopes; after every page the encrypted ones are opened through the
/// account's `CirclePostOpener` into `opened`. Items sealed under a key version
/// this device lacks are `.pendingKey`: each page load triggers one key
/// refresh per Circle and re-opens the items the refresh made openable.
/// Decrypted posts are cached only in `CircleFeedCache`'s per-account opened
/// store, never in stored pages, the public feed cache or on disk.
@MainActor
@Observable
final class CircleFeedModel {
  private(set) var items: [BlueCatbirdCircleDefs.FeedItem] = []
  private(set) var cursor: String?
  private(set) var accessState: CircleAccessState = .active
  private(set) var isLoading: Bool = false
  private(set) var error: CircleError?
  private(set) var isInvalidated: Bool = false
  /// Opening results for encrypted items, by post URI. Plaintext items are
  /// never entered here.
  private(set) var opened: [ATProtocolURI: CircleOpenedItem] = [:]
  /// Owner handles (by DID) for the "waiting for access" row.
  private(set) var ownerHandles: [String: String] = [:]
  let service: CircleService
  let space: SpaceRef?
  let accountDID: String
  private let cache: CircleFeedCache
  private let activeDIDProvider: (@MainActor () -> String?)?
  @ObservationIgnored private let openerProvider: (@MainActor () -> CirclePostOpener?)?
  @ObservationIgnored private let ownerHandleResolver: (@Sendable (DID) async -> String?)?
  private var currentGeneration: Int = 0
  @ObservationIgnored private var muteObserver: NSObjectProtocol?
  @ObservationIgnored private var deleteObserver: NSObjectProtocol?
  @ObservationIgnored private var accountInvalidatedObserver: NSObjectProtocol?
  @ObservationIgnored private var postPublishedObserver: NSObjectProtocol?

  init(
    service: CircleService,
    space: SpaceRef? = nil,
    accountDID: String = "",
    cache: CircleFeedCache = .shared,
    activeDIDProvider: (@MainActor () -> String?)? = nil,
    openerProvider: (@MainActor () -> CirclePostOpener?)? = nil,
    ownerHandleResolver: (@Sendable (DID) async -> String?)? = nil
  ) {
    self.service = service
    self.space = space
    self.accountDID = accountDID
    self.cache = cache
    self.activeDIDProvider = activeDIDProvider
    self.openerProvider = openerProvider
    self.ownerHandleResolver = ownerHandleResolver

    if space == nil {
      self.muteObserver = NotificationCenter.default.addObserver(
        forName: .circleMuteStateChanged,
        object: nil,
        queue: nil
      ) { [weak self] notification in
        guard let self else { return }
        let targetAccountDID = notification.userInfo?["accountDID"] as? String ?? ""
        guard targetAccountDID.isEmpty || targetAccountDID == self.accountDID else {
          return
        }
        guard let spaceURIString = notification.userInfo?["spaceURI"] as? String,
              let space = try? SpaceRef(uriString: spaceURIString) else {
          return
        }
        self.purgeMutedCircle(space)
      }
    }

    self.deleteObserver = NotificationCenter.default.addObserver(
      forName: .circleDeleted,
      object: nil,
      queue: nil
    ) { [weak self] notification in
      guard let self else { return }
      let targetAccountDID = notification.userInfo?["accountDID"] as? String ?? ""
      guard !targetAccountDID.isEmpty, targetAccountDID == self.accountDID else {
        return
      }
      guard let spaceURIString = notification.userInfo?["spaceURI"] as? String,
            let deletedSpace = try? SpaceRef(uriString: spaceURIString) else {
        return
      }
      self.handleCircleDeletedSync(space: deletedSpace)
    }

    self.accountInvalidatedObserver = NotificationCenter.default.addObserver(
      forName: .circleAccountInvalidated,
      object: nil,
      queue: nil
    ) { [weak self] notification in
      guard let self else { return }
      let targetAccountDID = notification.userInfo?["accountDID"] as? String ?? ""
      guard !targetAccountDID.isEmpty, targetAccountDID == self.accountDID else {
        return
      }
      self.handleAccountInvalidatedSync()
    }

    self.postPublishedObserver = NotificationCenter.default.addObserver(
      forName: .circlePostPublished,
      object: nil,
      queue: nil
    ) { [weak self] notification in
      guard let self else { return }
      let targetAccountDID = notification.userInfo?["accountDID"] as? String ?? ""
      guard targetAccountDID.isEmpty || targetAccountDID == self.accountDID else {
        return
      }
      Task { @MainActor in
        try? await self.load()
      }
    }
  }

  deinit {
    if let muteObserver {
      NotificationCenter.default.removeObserver(muteObserver)
    }
    if let deleteObserver {
      NotificationCenter.default.removeObserver(deleteObserver)
    }
    if let accountInvalidatedObserver {
      NotificationCenter.default.removeObserver(accountInvalidatedObserver)
    }
    if let postPublishedObserver {
      NotificationCenter.default.removeObserver(postPublishedObserver)
    }
  }

  private func resolveActiveDID(override: (@MainActor () -> String?)? = nil) -> String? {
    if let override {
      return override()
    }
    if let provider = activeDIDProvider {
      return provider()
    }
    return accountDID
  }

  /// Initial load or pull-to-refresh. Restores memory cache if items are empty,
  /// then opens the page's encrypted items.
  func load(activeAccountCheck: (@MainActor () -> String?)? = nil) async throws {
    guard !isInvalidated, !isLoading else { return }
    let requestGeneration = currentGeneration
    do {
      try await fetchFirstPage(activeAccountCheck: activeAccountCheck)
    } catch {
      await openEncryptedItems(generation: requestGeneration, activeAccountCheck: activeAccountCheck)
      throw error
    }
    await openEncryptedItems(generation: requestGeneration, activeAccountCheck: activeAccountCheck)
  }

  /// Paging load for infinite scroll; opens the new page's encrypted items.
  func loadMore(activeAccountCheck: (@MainActor () -> String?)? = nil) async throws {
    guard !isInvalidated, let currentCursor = cursor, !currentCursor.isEmpty, !isLoading else { return }
    let requestGeneration = currentGeneration
    try await fetchNextPage(activeAccountCheck: activeAccountCheck)
    await openEncryptedItems(generation: requestGeneration, activeAccountCheck: activeAccountCheck)
  }

  /// The owner handle shown on a `.pendingKey` row, once resolved.
  func ownerHandle(for circle: CircleSummary) -> String? {
    ownerHandles[circle.owner.didString()]
  }

  private func fetchFirstPage(activeAccountCheck: (@MainActor () -> String?)?) async throws {
    guard !isInvalidated, !isLoading else { return }
    isLoading = true
    defer { isLoading = false }

    let cacheGeneration = cache.generation(accountDID: accountDID)
    let requestGeneration = currentGeneration
    let requestAccountDID = accountDID
    let requestSpace = space
    // Restore from memory cache first if empty
    if items.isEmpty, let cachedPage = await cache.page(accountDID: accountDID, space: space) {
      guard !self.isInvalidated,
            requestGeneration == self.currentGeneration,
            let activeDID = resolveActiveDID(override: activeAccountCheck),
            activeDID == requestAccountDID,
            requestSpace == self.space else {
        return
      }
      if space == nil {
        self.items = cachedPage.items.filter { !($0.circle.muted ?? false) }
      } else {
        self.items = cachedPage.items
      }
      self.cursor = cachedPage.cursor
    }

    do {
      let page = try await service.getFeed(space: space, cursor: nil)

      guard !self.isInvalidated,
            requestGeneration == self.currentGeneration,
            let activeDID = resolveActiveDID(override: activeAccountCheck),
            activeDID == requestAccountDID,
            requestSpace == self.space else {
        return
      }

      if space == nil {
        self.items = page.items.filter { !($0.circle.muted ?? false) }
      } else {
        self.items = page.items
      }
      self.cursor = page.cursor
      self.accessState = .active
      self.error = nil
      let storedPage = CircleFeedPage(items: self.items, cursor: self.cursor)
      await cache.store(storedPage, accountDID: accountDID, space: space, generation: cacheGeneration)
    } catch {
      guard !self.isInvalidated,
            requestGeneration == self.currentGeneration,
            let activeDID = resolveActiveDID(override: activeAccountCheck),
            activeDID == requestAccountDID,
            requestSpace == self.space else {
        return
      }
      let typedError = circleError(from: error)
      self.error = typedError
      switch typedError {
      case .accessExpired:
        self.accessState = .expired
      case .accessRemoved:
        self.accessState = .removed
        if let space {
          await purgeUnavailableSpace(space)
        }
      case .unsupportedPDS, .protocolRevisionMismatch:
        self.accessState = .unsupported
      case .authRequired, .notAuthorized:
        // The AppView holds no grant for this account. Recoverable by
        // authorizing it; explicitly NOT a purge and NOT a Space deletion.
        self.accessState = .needsAuthorization
      default:
        break
      }
      throw typedError
    }
  }

  private func fetchNextPage(activeAccountCheck: (@MainActor () -> String?)?) async throws {
    guard !isInvalidated, let currentCursor = cursor, !currentCursor.isEmpty, !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    let cacheGeneration = cache.generation(accountDID: accountDID)
    let requestGeneration = currentGeneration
    let requestAccountDID = accountDID
    let requestSpace = space

    do {
      let nextPage = try await service.getFeed(space: space, cursor: currentCursor)
      guard !self.isInvalidated,
            requestGeneration == self.currentGeneration,
            let activeDID = resolveActiveDID(override: activeAccountCheck),
            activeDID == requestAccountDID,
            requestSpace == self.space else {
        return
      }

      let existingURIs = Set(self.items.compactMap { $0.post.postURI?.uriString() })
      let filteredNewItems: [BlueCatbirdCircleDefs.FeedItem]
      if space == nil {
        filteredNewItems = nextPage.items.filter { !($0.circle.muted ?? false) && !existingURIs.contains($0.post.postURI?.uriString() ?? "") }
      } else {
        filteredNewItems = nextPage.items.filter { !existingURIs.contains($0.post.postURI?.uriString() ?? "") }
      }
      self.items.append(contentsOf: filteredNewItems)
      self.cursor = nextPage.cursor
      self.error = nil

      let updatedPage = CircleFeedPage(items: self.items, cursor: self.cursor)
      await cache.store(updatedPage, accountDID: accountDID, space: space, generation: cacheGeneration)
    } catch {
      guard !self.isInvalidated,
            requestGeneration == self.currentGeneration,
            let activeDID = resolveActiveDID(override: activeAccountCheck),
            activeDID == requestAccountDID,
            requestSpace == self.space else {
        return
      }
      let typedError = circleError(from: error)
      switch typedError {
      case .accessExpired:
        self.accessState = .expired
      case .accessRemoved:
        self.accessState = .removed
        if let space {
          await purgeUnavailableSpace(space)
        }
      case .unsupportedPDS, .protocolRevisionMismatch:
        self.accessState = .unsupported
      default:
        break
      }
      throw typedError
    }
  }
  // MARK: - Encrypted items

  /// Opens every encrypted item on each load, with one key refresh per Circle
  /// for pending items (inside `CirclePostOpener.openBatch`). Items already
  /// opened cost a memo lookup and pick up the current envelope's counts and
  /// viewer state. Results are dropped if the model was purged, switched or
  /// invalidated meanwhile.
  private func openEncryptedItems(
    generation: Int,
    activeAccountCheck: (@MainActor () -> String?)?
  ) async {
    guard !isInvalidated, generation == currentGeneration else { return }
    let targets = items.filter { $0.post.isEncrypted && $0.post.postURI != nil }
    guard !targets.isEmpty else { return }
    // No opener yet (the MLS client is still starting): the items stay
    // unopened ("Opening…") and are opened by the next load.
    guard let opener = openerProvider?() else { return }

    let requestAccountDID = accountDID
    let results = await opener.openBatch(targets.map { .feedItem($0) })
    guard !isInvalidated, generation == currentGeneration,
          resolveActiveDID(override: activeAccountCheck) == requestAccountDID else { return }
    let liveURIs = Set(items.compactMap { $0.post.postURI })
    for (uri, item) in results where liveURIs.contains(uri) {
      opened[uri] = item
    }
    await resolveOwnerHandles(for: targets.filter { opened[$0.post.postURI ?? CirclePostOpener.unknownURI]?.isPendingKey == true })
  }

  private func resolveOwnerHandles(for pendingItems: [BlueCatbirdCircleDefs.FeedItem]) async {
    var owners: [String: DID] = [:]
    for item in pendingItems where ownerHandles[item.circle.owner.didString()] == nil {
      owners[item.circle.owner.didString()] = item.circle.owner
    }
    for (key, did) in owners {
      // An item the owner wrote already carries their hydrated profile.
      if let handle = items.lazy.compactMap({ Self.author(of: $0) }).first(where: { $0.did == did })?.handle {
        ownerHandles[key] = handle.description
      } else if let handle = await ownerHandleResolver?(did) {
        guard !isInvalidated else { return }
        ownerHandles[key] = handle
      }
    }
  }

  private static func author(of item: BlueCatbirdCircleDefs.FeedItem) -> AppBskyActorDefs.ProfileViewBasic? {
    item.post.feedViewPost?.post.author ?? item.post.encryptedPostView?.author
  }

  /// Drops opened results whose item is gone.
  private func pruneOpened() {
    let live = Set(items.compactMap { $0.post.postURI })
    opened = opened.filter { live.contains($0.key) }
  }

  /// Purges in-memory cached posts and images for an unavailable Space.
  func purgeUnavailableSpace(_ space: SpaceRef) async {
    guard !isInvalidated else { return }
    currentGeneration += 1
    items.removeAll(where: { $0.circle.uri == space })
    pruneOpened()
    cursor = nil
    await service.retireSpace(space)
    NotificationCenter.default.post(name: .circleDeleted, object: nil,
      userInfo: ["accountDID": accountDID, "spaceURI": space.uriString()])
    await cache.purge(accountDID: accountDID, space: space)
    await CircleMediaLoader.shared.purge(accountDID: accountDID, space: space)
    await CircleNotificationCache.shared.purge(accountDID: accountDID, space: space)
    if self.space == space {
      self.accessState = .removed
    }
  }

  /// Purges in-memory cached posts for a muted Circle Space from unified feed.
  func purgeMutedCircle(_ space: SpaceRef) {
    guard !isInvalidated else { return }
    if self.space == nil {
      currentGeneration += 1
      items.removeAll(where: { $0.circle.uri.uriString() == space.uriString() })
      pruneOpened()
      Task { [accountDID, cache] in
        await cache.purgeMutedSpaceFromUnified(accountDID: accountDID, space: space)
      }
    }
  }

  /// Synchronous purge for `.circleDeleted` lifecycle notification.
  private func handleCircleDeletedSync(space deletedSpace: SpaceRef) {
    currentGeneration += 1
    cursor = nil
    Task { [service] in await service.retireSpace(deletedSpace) }
    if self.space == nil {
      items.removeAll(where: { $0.circle.uri.uriString() == deletedSpace.uriString() })
      pruneOpened()
      Task { [accountDID, cache] in
        await cache.purge(accountDID: accountDID, space: deletedSpace)
      }
    } else if self.space?.uriString() == deletedSpace.uriString() {
      items.removeAll()
      opened.removeAll()
      accessState = .removed
      cursor = nil
      Task { [accountDID, cache] in
        await cache.purge(accountDID: accountDID, space: deletedSpace)
      }
    }
  }

  /// Synchronous purge for `.circleAccountInvalidated` lifecycle notification.
  private func handleAccountInvalidatedSync() {
    isInvalidated = true
    currentGeneration += 1
    items.removeAll()
    opened.removeAll()
    ownerHandles.removeAll()
    cursor = nil
    error = nil
  }
}
