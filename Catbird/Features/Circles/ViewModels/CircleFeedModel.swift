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
@MainActor
@Observable
final class CircleFeedModel {
  private(set) var items: [BlueCatbirdCircleDefs.FeedItem] = []
  private(set) var cursor: String?
  private(set) var accessState: CircleAccessState = .active
  private(set) var isLoading: Bool = false
  private(set) var error: CircleError?
  private(set) var isInvalidated: Bool = false
  let service: CircleService
  let space: SpaceRef?
  let accountDID: String
  private let cache: CircleFeedCache
  private let activeDIDProvider: (@MainActor () -> String?)?
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
    activeDIDProvider: (@MainActor () -> String?)? = nil
  ) {
    self.service = service
    self.space = space
    self.accountDID = accountDID
    self.cache = cache
    self.activeDIDProvider = activeDIDProvider

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

  /// Initial load or pull-to-refresh. Restores memory cache if items are empty.
  func load(activeAccountCheck: (@MainActor () -> String?)? = nil) async throws {
    guard !isInvalidated, !isLoading else { return }
    isLoading = true
    defer { isLoading = false }

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
      await cache.store(storedPage, accountDID: accountDID, space: space)
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
      default:
        break
      }
      throw typedError
    }
  }

  /// Paging load for infinite scroll.
  func loadMore(activeAccountCheck: (@MainActor () -> String?)? = nil) async throws {
    guard !isInvalidated, let currentCursor = cursor, !currentCursor.isEmpty, !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
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

      let existingURIs = Set(self.items.map { $0.post.post.uri.uriString() })
      let filteredNewItems: [BlueCatbirdCircleDefs.FeedItem]
      if space == nil {
        filteredNewItems = nextPage.items.filter { !($0.circle.muted ?? false) && !existingURIs.contains($0.post.post.uri.uriString()) }
      } else {
        filteredNewItems = nextPage.items.filter { !existingURIs.contains($0.post.post.uri.uriString()) }
      }
      self.items.append(contentsOf: filteredNewItems)
      self.cursor = nextPage.cursor
      self.error = nil

      let updatedPage = CircleFeedPage(items: self.items, cursor: self.cursor)
      await cache.store(updatedPage, accountDID: accountDID, space: space)
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
  /// Purges in-memory cached posts and images for an unavailable Space.
  func purgeUnavailableSpace(_ space: SpaceRef) async {
    guard !isInvalidated else { return }
    currentGeneration += 1
    items.removeAll(where: { $0.circle.uri == space })
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
      Task { [accountDID, cache] in
        await cache.purgeMutedSpaceFromUnified(accountDID: accountDID, space: space)
      }
    }
  }

  /// Synchronous purge for `.circleDeleted` lifecycle notification.
  private func handleCircleDeletedSync(space deletedSpace: SpaceRef) {
    currentGeneration += 1
    if self.space == nil {
      items.removeAll(where: { $0.circle.uri.uriString() == deletedSpace.uriString() })
      Task { [accountDID, cache] in
        await cache.purge(accountDID: accountDID, space: deletedSpace)
      }
    } else if self.space?.uriString() == deletedSpace.uriString() {
      items.removeAll()
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
    cursor = nil
    error = nil
  }
}
