//
//  CircleNotificationsModel.swift
//  Catbird
//

import Foundation
import Observation
import Petrel
import PetrelCatbird

/// View model managing private Circle notifications.
///
/// Backed strictly by in-memory caching (`CircleNotificationCache`). Never routes
/// through public notification models, database tables, or public AppView calls.
@MainActor
@Observable
final class CircleNotificationsModel {
  private(set) var notifications: [BlueCatbirdCircleDefs.Notification] = []
  private(set) var cursor: String?
  private(set) var isLoading: Bool = false
  private(set) var isRefreshing: Bool = false
  private(set) var error: CircleError?

  let service: any CircleNotificationServiceProtocol
  let accountDID: String
  private let cache: CircleNotificationCache
  private var currentGeneration: Int = 0

  init(
    service: any CircleNotificationServiceProtocol,
    accountDID: String = "",
    cache: CircleNotificationCache = .shared
  ) {
    self.service = service
    self.accountDID = accountDID
    self.cache = cache

    NotificationCenter.default.addObserver(
      forName: .circleMuteStateChanged,
      object: nil,
      queue: nil
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
      self.handleMuteStateChangedSync(space: space)
    }
  }

  /// Initial load or cache restore.
  func load() async throws {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }

    let requestGeneration = currentGeneration
    let requestAccountDID = accountDID

    // Restore from memory cache first if empty
    if notifications.isEmpty, let cached = await cache.page(accountDID: accountDID) {
      self.notifications = cached.notifications.filter { !($0.circle.muted ?? false) }
      self.cursor = cached.cursor
    }

    do {
      let page = try await service.listNotifications(cursor: nil)

      guard requestGeneration == self.currentGeneration,
            requestAccountDID == self.accountDID else {
        return
      }

      self.notifications = page.notifications.filter { !($0.circle.muted ?? false) }
      self.cursor = page.cursor
      self.error = nil

      let storedPage = CircleNotificationPage(notifications: self.notifications, cursor: self.cursor)
      await cache.store(storedPage, accountDID: accountDID)
    } catch {
      guard requestGeneration == self.currentGeneration,
            requestAccountDID == self.accountDID else {
        return
      }
      let typedError = circleError(from: error)
      self.error = typedError
      throw typedError
    }
  }

  /// Pull-to-refresh or push-triggered refresh.
  func refresh() async throws {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }

    let requestGeneration = currentGeneration
    let requestAccountDID = accountDID

    do {
      let page = try await service.refresh()

      guard requestGeneration == self.currentGeneration,
            requestAccountDID == self.accountDID else {
        return
      }

      self.notifications = page.notifications.filter { !($0.circle.muted ?? false) }
      self.cursor = page.cursor
      self.error = nil

      let storedPage = CircleNotificationPage(notifications: self.notifications, cursor: self.cursor)
      await cache.store(storedPage, accountDID: accountDID)
    } catch {
      guard requestGeneration == self.currentGeneration,
            requestAccountDID == self.accountDID else {
        return
      }
      let typedError = circleError(from: error)
      self.error = typedError
      throw typedError
    }
  }

  /// Paging load for infinite scroll.
  func loadMore() async throws {
    guard let currentCursor = cursor, !currentCursor.isEmpty, !isLoading else { return }
    isLoading = true
    defer { isLoading = false }

    let requestGeneration = currentGeneration
    let requestAccountDID = accountDID

    do {
      let nextPage = try await service.listNotifications(cursor: currentCursor)

      guard requestGeneration == self.currentGeneration,
            requestAccountDID == self.accountDID else {
        return
      }

      let existingIDs = Set(self.notifications.map { $0.id })
      let filteredNewItems = nextPage.notifications.filter {
        !($0.circle.muted ?? false) && !existingIDs.contains($0.id)
      }
      self.notifications.append(contentsOf: filteredNewItems)
      self.cursor = nextPage.cursor
      self.error = nil

      let updatedPage = CircleNotificationPage(notifications: self.notifications, cursor: self.cursor)
      await cache.store(updatedPage, accountDID: accountDID)
    } catch {
      guard requestGeneration == self.currentGeneration,
            requestAccountDID == self.accountDID else {
        return
      }
      let typedError = circleError(from: error)
      self.error = typedError
      throw typedError
    }
  }

  /// Purge notifications for a specific Space (membership removal or Space deletion).
  func purge(space: SpaceRef) async {
    currentGeneration += 1
    notifications.removeAll(where: { $0.circle.uri == space })
    cursor = nil
    error = nil
    await cache.purge(accountDID: accountDID, space: space)
  }

  /// Purge notifications for the active account (logout or account removal).
  func purgeAccount() async {
    currentGeneration += 1
    notifications.removeAll()
    cursor = nil
    error = nil
    await cache.purge(accountDID: accountDID)
  }

  /// Purges in-memory cached notifications for a muted Circle Space.
  func purgeMutedCircle(_ space: SpaceRef) async {
    notifications.removeAll(where: { $0.circle.uri.uriString() == space.uriString() })
    await cache.purgeMutedSpace(accountDID: accountDID, space: space)
  }

  /// Non-isolated synchronous trigger for NotificationCenter handler.
  private func handleMuteStateChangedSync(space: SpaceRef) {
    notifications.removeAll(where: { $0.circle.uri.uriString() == space.uriString() })
    Task { [accountDID, cache] in
      await cache.purgeMutedSpace(accountDID: accountDID, space: space)
    }
  }
}
