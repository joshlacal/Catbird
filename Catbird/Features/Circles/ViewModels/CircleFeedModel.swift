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

  let service: CircleService
  let space: SpaceRef?
  let accountDID: String
  private let cache: CircleFeedCache

  init(
    service: CircleService,
    space: SpaceRef? = nil,
    accountDID: String = "",
    cache: CircleFeedCache = .shared
  ) {
    self.service = service
    self.space = space
    self.accountDID = accountDID
    self.cache = cache

    if space == nil {
      NotificationCenter.default.addObserver(
        forName: .circleMuteStateChanged,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        guard let self else { return }
        let targetAccountDID = notification.userInfo?["accountDID"] as? String ?? ""
        guard targetAccountDID.isEmpty || self.accountDID.isEmpty || targetAccountDID == self.accountDID else {
          return
        }
        guard let spaceURIString = notification.userInfo?["spaceURI"] as? String,
              let space = try? SpaceRef(uriString: spaceURIString) else {
          return
        }
        self.purgeMutedCircle(space)
      }
    }
  }

  /// Initial load or pull-to-refresh. Restores memory cache if items are empty.
  func load() async throws {
    isLoading = true
    defer { isLoading = false }

    // Restore from memory cache first if empty
    if items.isEmpty, let cachedPage = await cache.page(accountDID: accountDID, space: space) {
      if space == nil {
        self.items = cachedPage.items.filter { !($0.circle.muted ?? false) }
      } else {
        self.items = cachedPage.items
      }
      self.cursor = cachedPage.cursor
    }

    do {
      let page = try await service.getFeed(space: space, cursor: nil)
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
  func loadMore() async throws {
    guard let currentCursor = cursor, !currentCursor.isEmpty, !isLoading else { return }
    isLoading = true
    defer { isLoading = false }

    do {
      let nextPage = try await service.getFeed(space: space, cursor: currentCursor)
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

  /// Purges in-memory cached posts and images for an unavailable Space.
  func purgeUnavailableSpace(_ space: SpaceRef) async {
    items.removeAll(where: { $0.circle.uri == space })
    await cache.purge(accountDID: accountDID, space: space)
    await CircleMediaLoader.shared.purge(accountDID: accountDID, space: space)
    if self.space == space {
      self.accessState = .removed
    }
  }

  /// Purges in-memory cached posts for a muted Circle Space from unified feed.
  func purgeMutedCircle(_ space: SpaceRef) {
    if self.space == nil {
      items.removeAll(where: { $0.circle.uri.uriString() == space.uriString() })
      Task { [accountDID, cache] in
        await cache.purgeMutedSpaceFromUnified(accountDID: accountDID, space: space)
      }
    }
  }
}
