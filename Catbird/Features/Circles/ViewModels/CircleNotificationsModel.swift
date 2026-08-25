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
  private(set) var isInvalidated: Bool = false
  let service: any CircleNotificationServiceProtocol
  let accountDID: String
  private let cache: CircleNotificationCache
  private let activeDIDProvider: (@MainActor () -> String?)?
  private var currentGeneration: Int = 0
  @ObservationIgnored private var muteObserver: NSObjectProtocol?
  @ObservationIgnored private var deleteObserver: NSObjectProtocol?
  @ObservationIgnored private var accountInvalidatedObserver: NSObjectProtocol?

  init(
    service: any CircleNotificationServiceProtocol,
    accountDID: String = "",
    cache: CircleNotificationCache = .shared,
    activeDIDProvider: (@MainActor () -> String?)? = nil
  ) {
    self.service = service
    self.accountDID = accountDID
    self.cache = cache
    self.activeDIDProvider = activeDIDProvider

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
      self.handleMuteStateChangedSync(space: space)
    }

    self.deleteObserver = NotificationCenter.default.addObserver(
      forName: .circleDeleted,
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
      self.handleCircleDeletedSync(space: space)
    }

    self.accountInvalidatedObserver = NotificationCenter.default.addObserver(
      forName: .circleAccountInvalidated,
      object: nil,
      queue: nil
    ) { [weak self] notification in
      guard let self else { return }
      let targetAccountDID = notification.userInfo?["accountDID"] as? String ?? ""
      guard targetAccountDID.isEmpty || targetAccountDID == self.accountDID else {
        return
      }
      self.handleAccountInvalidatedSync()
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
  }

  private func resolveActiveDID(override: (@MainActor () -> String?)?) -> String? {
    if let override {
      return override()
    }
    if let provider = activeDIDProvider {
      return provider()
    }
    return accountDID
  }

  /// Initial load or cache restore.
  func load(activeAccountCheck: (@MainActor () -> String?)? = nil) async throws {
    guard !isInvalidated, !isLoading else { return }
    isLoading = true
    defer { isLoading = false }

    let requestGeneration = currentGeneration
    let requestAccountDID = accountDID

    // Restore from memory cache first if empty
    if notifications.isEmpty, let cached = await cache.page(accountDID: accountDID) {
      guard !self.isInvalidated,
            requestGeneration == self.currentGeneration,
            let activeDID = resolveActiveDID(override: activeAccountCheck),
            activeDID == requestAccountDID else {
        return
      }
      self.notifications = cached.notifications.filter { !($0.circle.muted ?? false) }
      self.cursor = cached.cursor
    }

    do {
      let page = try await service.listNotifications(cursor: nil)

      guard !self.isInvalidated,
            requestGeneration == self.currentGeneration,
            let activeDID = resolveActiveDID(override: activeAccountCheck),
            activeDID == requestAccountDID else {
        return
      }

      self.notifications = page.notifications.filter { !($0.circle.muted ?? false) }
      self.cursor = page.cursor
      self.error = nil

      let storedPage = CircleNotificationPage(notifications: self.notifications, cursor: self.cursor)
      await cache.store(storedPage, accountDID: accountDID)
    } catch {
      guard !self.isInvalidated,
            requestGeneration == self.currentGeneration,
            let activeDID = resolveActiveDID(override: activeAccountCheck),
            activeDID == requestAccountDID else {
        return
      }
      let typedError = circleError(from: error)
      self.error = typedError
      throw typedError
    }
  }

  /// Pull-to-refresh or push-triggered refresh.
  func refresh(activeAccountCheck: (@MainActor () -> String?)? = nil) async throws {
    guard !isInvalidated, !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }

    let requestGeneration = currentGeneration
    let requestAccountDID = accountDID

    do {
      let page = try await service.refresh()

      guard !self.isInvalidated,
            requestGeneration == self.currentGeneration,
            let activeDID = resolveActiveDID(override: activeAccountCheck),
            activeDID == requestAccountDID else {
        return
      }

      self.notifications = page.notifications.filter { !($0.circle.muted ?? false) }
      self.cursor = page.cursor
      self.error = nil

      let storedPage = CircleNotificationPage(notifications: self.notifications, cursor: self.cursor)
      await cache.store(storedPage, accountDID: accountDID)
    } catch {
      guard !self.isInvalidated,
            requestGeneration == self.currentGeneration,
            let activeDID = resolveActiveDID(override: activeAccountCheck),
            activeDID == requestAccountDID else {
        return
      }
      let typedError = circleError(from: error)
      self.error = typedError
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

    do {
      let nextPage = try await service.listNotifications(cursor: currentCursor)

      guard !self.isInvalidated,
            requestGeneration == self.currentGeneration,
            let activeDID = resolveActiveDID(override: activeAccountCheck),
            activeDID == requestAccountDID else {
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
      guard !self.isInvalidated,
            requestGeneration == self.currentGeneration,
            let activeDID = resolveActiveDID(override: activeAccountCheck),
            activeDID == requestAccountDID else {
        return
      }
      let typedError = circleError(from: error)
      self.error = typedError
      throw typedError
    }
  }

  /// Purge notifications for a specific Space (membership removal or Space deletion).
  func purge(space: SpaceRef) async {
    guard !isInvalidated else { return }
    currentGeneration += 1
    notifications.removeAll(where: { $0.circle.uri == space })
    cursor = nil
    error = nil
    await cache.purge(accountDID: accountDID, space: space)
  }

  /// Purge notifications for the active account (logout or account removal).
  func purgeAccount() async {
    guard !isInvalidated else { return }
    currentGeneration += 1
    notifications.removeAll()
    cursor = nil
    error = nil
    await cache.purge(accountDID: accountDID)
  }

  /// Purges in-memory cached notifications for a muted Circle Space.
  func purgeMutedCircle(_ space: SpaceRef) async {
    guard !isInvalidated else { return }
    currentGeneration += 1
    notifications.removeAll(where: { $0.circle.uri.uriString() == space.uriString() })
    await cache.purgeMutedSpace(accountDID: accountDID, space: space)
  }

  /// Non-isolated synchronous trigger for NotificationCenter handler.
  private func handleMuteStateChangedSync(space: SpaceRef) {
    currentGeneration += 1
    notifications.removeAll(where: { $0.circle.uri.uriString() == space.uriString() })
    Task { [accountDID, cache] in
      await cache.purgeMutedSpace(accountDID: accountDID, space: space)
    }
  }

  /// Synchronous purge for `.circleDeleted` lifecycle notification.
  private func handleCircleDeletedSync(space: SpaceRef) {
    currentGeneration += 1
    notifications.removeAll(where: { $0.circle.uri.uriString() == space.uriString() })
    Task { [accountDID, cache] in
      await cache.purge(accountDID: accountDID, space: space)
    }
  }

  /// Synchronous purge for `.circleAccountInvalidated` lifecycle notification.
  private func handleAccountInvalidatedSync() {
    isInvalidated = true
    currentGeneration += 1
    notifications.removeAll()
    cursor = nil
    error = nil
  }
}
