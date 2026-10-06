import Foundation
import Observation
import OSLog
import Petrel

enum FeedLibraryDestination: Equatable { case saved, pinned, unpinned }
enum FeedLibraryMembership: Equatable { case absent, saved, pinned }
enum FeedLibraryPersistence { case synced, pendingSync(String) }
enum FeedLibraryActionState: Equatable {
  case idle, saving
  case success(FeedLibraryMembership)
  case pendingSync(String)
  case failed(String)
}

enum FeedLibraryActionError: LocalizedError {
  case pendingSync(String), wrongAccount
  var errorDescription: String? {
    switch self {
    case .pendingSync: return FeedLibraryActions.pendingSyncMessage
    case .wrongAccount: return "You switched accounts. Close this screen and open it again."
    }
  }
}

/// One instance belongs to one AppState and is shared by discovery and preview.
/// Preferences remain the source of truth; the arrays here are a display snapshot.
@MainActor @Observable
final class FeedLibraryActions {
  /// Shown for changes kept locally until the server accepts them; the raw sync
  /// error is logged, never displayed.
  nonisolated static let pendingSyncMessage = "Saved on this device. It will sync when you’re back online."

  let accountDID: String
  @ObservationIgnored private let logger = Logger(subsystem: "blue.catbird", category: "FeedLibraryActions")
  private(set) var savedFeeds: [String] = []
  private(set) var pinnedFeeds: [String] = []
  private(set) var refreshError: String?
  private(set) var orderState: FeedLibraryActionState = .idle
  private var pendingPinnedOrder: FeedLibraryPendingStore.PinnedOrder?
  private enum Intent { case add(FeedLibraryDestination), remove }
  private var intents: [String: Intent] = [:]
  private var states: [String: FeedLibraryActionState] = [:]
  @ObservationIgnored private let pendingStore: FeedLibraryPendingStore?
  @ObservationIgnored private let read: @MainActor () async throws -> Preferences
  @ObservationIgnored private let persist: @MainActor (Preferences) async throws -> FeedLibraryPersistence
  @ObservationIgnored private let invalidate: @MainActor () async -> Void
  @ObservationIgnored private var operations: [String: Task<FeedLibraryMembership, Error>] = [:]
  @ObservationIgnored private var tail: Task<FeedLibraryMembership, Error>?
  @ObservationIgnored private var refreshTask: Task<Void, Never>?

  convenience init(appState: AppState) {
    self.init(accountDID: appState.userDID, pendingStore: FeedLibraryPendingStore(),
      read: { [weak appState] in
        guard let appState else { throw FeedLibraryActionError.wrongAccount }
        return try await appState.preferencesManager.getPreferences()
      },
      persist: { [weak appState] preferences in
        guard let appState else { throw FeedLibraryActionError.wrongAccount }
        return try await appState.preferencesManager.saveFeedLibraryPreferences(preferences)
      },
      invalidate: { [weak appState] in
        await appState?.stateInvalidationBus.notify(.feedListChanged)
      })
  }

  init(accountDID: String,
       pendingStore: FeedLibraryPendingStore? = nil,
       read: @escaping @MainActor () async throws -> Preferences,
       persist: @escaping @MainActor (Preferences) async throws -> FeedLibraryPersistence,
       invalidate: @escaping @MainActor () async -> Void = {}) {
    self.accountDID = accountDID
    self.pendingStore = pendingStore
    self.read = read
    self.persist = persist
    self.invalidate = invalidate
    restorePendingIntents()
  }

  func membership(for uri: ATProtocolURI) -> FeedLibraryMembership {
    membership(for: uri.uriString())
  }

  private func membership(for uri: String) -> FeedLibraryMembership {
    if pinnedFeeds.contains(uri) { return .pinned }
    return savedFeeds.contains(uri) ? .saved : .absent
  }

  func state(for uri: ATProtocolURI) -> FeedLibraryActionState {
    states[uri.uriString()] ?? .idle
  }

  private static func failureMessage(for error: Error) -> String {
    (error as? FeedLibraryActionError)?.errorDescription ?? "Couldn’t save this change. Try again."
  }

  func refresh() async {
    if let refreshTask { await refreshTask.value; return }
    let task = Task { @MainActor in
      do {
        let preferences = try await self.read()
        try self.checkAccount(preferences)
        self.restorePendingIntents()
        self.snapshot(preferences)
        self.refreshError = nil
      } catch {
        self.logger.error("Refreshing feed library failed: \(error.localizedDescription)")
        self.refreshError = (error as? FeedLibraryActionError)?.errorDescription
          ?? "Couldn’t load your feeds. Check your connection and try again."
      }
    }
    refreshTask = task
    await task.value
    refreshTask = nil
  }

  func add(_ uri: ATProtocolURI, to destination: FeedLibraryDestination = .saved) async throws
    -> FeedLibraryMembership {
    try await perform(uri, destination: destination)
  }

  /// Call only from an explicit Remove action in a manage menu.
  func remove(_ uri: ATProtocolURI) async throws {
    _ = try await perform(uri, destination: nil)
  }

  func retry(_ uri: ATProtocolURI) async throws {
    restorePendingIntents()
    switch intents[uri.uriString()] {
    case .add(let destination): _ = try await add(uri, to: destination)
    case .remove: try await remove(uri)
    case nil: await refresh()
    }
  }

  /// The first pinned feed is the existing default-feed contract. Membership stays intact.
  func reorderPinned(_ requested: [String]) async throws {
    let predecessor = tail
    let task = Task { @MainActor in
      if let predecessor { _ = try? await predecessor.value }
      self.orderState = .saving
      do {
        let preferences = try await self.read()
        try self.checkAccount(preferences)
        let original = preferences.pinnedFeeds
        let reordered = FeedLibraryPendingStore.applyingPinnedOrder(requested, to: original)
        let retrying = self.pendingPinnedOrder != nil
        guard reordered != original || retrying else {
          self.orderState = .idle
          return FeedLibraryMembership.pinned
        }
        let previous = self.pendingStore?.pinnedOrder(accountDID: self.accountDID)
        let order = self.pendingStore?.recordPinnedOrder(reordered, accountDID: self.accountDID)
          ?? FeedLibraryPendingStore.PinnedOrder(uris: reordered, revision: UUID())
        self.pendingPinnedOrder = order
        preferences.pinnedFeeds = reordered
        let outcome: FeedLibraryPersistence
        do { outcome = try await self.persist(preferences) }
        catch {
          preferences.pinnedFeeds = original
          self.pendingStore?.completePinnedOrder(order, accountDID: self.accountDID, restoring: previous)
          self.pendingPinnedOrder = order
          self.snapshot(preferences)
          throw error
        }
        self.snapshot(preferences)
        await self.invalidate()
        switch outcome {
        case .synced:
          self.pendingStore?.completePinnedOrder(order, accountDID: self.accountDID)
          self.pendingPinnedOrder = nil
          self.orderState = .success(.pinned)
        case .pendingSync(let message):
          self.logger.error("Feed order kept locally pending sync: \(message)")
          self.orderState = .pendingSync(Self.pendingSyncMessage)
          throw FeedLibraryActionError.pendingSync(message)
        }
        return FeedLibraryMembership.pinned
      } catch {
        if case .pendingSync = self.orderState {} else {
          self.logger.error("Saving feed order failed: \(error.localizedDescription)")
          self.orderState = .failed(Self.failureMessage(for: error))
        }
        throw error
      }
    }
    tail = task
    _ = try await task.value
  }

  func retryPinnedOrder() async throws {
    let order = pendingPinnedOrder ?? pendingStore?.pinnedOrder(accountDID: accountDID)
    if let order { try await reorderPinned(order.uris) } else { await refresh() }
  }

  private func perform(_ uri: ATProtocolURI, destination: FeedLibraryDestination?) async throws
    -> FeedLibraryMembership {
    let key = uri.uriString()
    if let existing = operations[key] { return try await existing.value }
    intents[key] = destination.map { .add($0) } ?? .remove
    let predecessor = tail
    let needsSync: Bool
    if case .pendingSync = states[key] { needsSync = true } else { needsSync = false }
    states[key] = .saving
    let task = Task { @MainActor in
      if let predecessor { _ = try? await predecessor.value }
      do {
        let preferences = try await self.read()
        try self.checkAccount(preferences)
        let oldSaved = preferences.savedFeeds
        let oldPinned = preferences.pinnedFeeds
        switch destination {
        case .saved:
          if !preferences.pinnedFeeds.contains(key) && !preferences.savedFeeds.contains(key) {
            preferences.savedFeeds.append(key)
          }
        case .unpinned:
          preferences.pinnedFeeds.removeAll { $0 == key }
          if !preferences.savedFeeds.contains(key) { preferences.savedFeeds.append(key) }
        case .pinned:
          preferences.savedFeeds.removeAll { $0 == key }
          if !preferences.pinnedFeeds.contains(key) { preferences.pinnedFeeds.append(key) }
        case nil:
          preferences.savedFeeds.removeAll { $0 == key }
          preferences.pinnedFeeds.removeAll { $0 == key }
        }
        let changed = oldSaved != preferences.savedFeeds || oldPinned != preferences.pinnedFeeds
        if changed || needsSync {
          let previous = self.pendingStore?.entries(accountDID: self.accountDID).first { $0.uri == key }
          let durableIntent: FeedLibraryPendingStore.Intent = switch destination {
          case .saved: .saved
          case .pinned: .pinned
          case .unpinned: .unpinned
          case nil: .removed
          }
          let entry = self.pendingStore?.record(uri: key, intent: durableIntent, accountDID: self.accountDID)
          let outcome: FeedLibraryPersistence
          do { outcome = try await self.persist(preferences) }
          catch {
            if let entry { self.pendingStore?.complete(entry, accountDID: self.accountDID, restoring: previous) }
            // Only these two fields belong to this operation. Do not restore a whole snapshot.
            preferences.savedFeeds = oldSaved
            preferences.pinnedFeeds = oldPinned
            self.snapshot(preferences)
            throw error
          }
          self.snapshot(preferences)
          // Invalidation publishes the durable local library, not a server confirmation.
          await self.invalidate()
          switch outcome {
          case .synced:
            if let entry { self.pendingStore?.complete(entry, accountDID: self.accountDID) }
          case .pendingSync(let message):
            self.logger.error("Feed library change kept locally pending sync: \(message)")
            self.states[key] = .pendingSync(Self.pendingSyncMessage)
            throw FeedLibraryActionError.pendingSync(message)
          }
        } else { self.snapshot(preferences) }
        let membership = self.membership(for: key)
        self.states[key] = .success(membership)
        return membership
      } catch {
        if case .pendingSync = self.states[key] {} else {
          self.logger.error("Saving feed library change failed: \(error.localizedDescription)")
          self.states[key] = .failed(Self.failureMessage(for: error))
        }
        throw error
      }
    }
    operations[key] = task
    tail = task
    defer { operations[key] = nil }
    return try await task.value
  }

  private func checkAccount(_ preferences: Preferences) throws {
    guard preferences.accountDID == accountDID else { throw FeedLibraryActionError.wrongAccount }
  }

  private func restorePendingIntents() {
    if let pendingStore {
      if case .failed = orderState {} else { pendingPinnedOrder = pendingStore.pinnedOrder(accountDID: accountDID) }
      if pendingPinnedOrder != nil { orderState = .pendingSync(Self.pendingSyncMessage) }
      else if case .pendingSync = orderState { orderState = .idle }
    }
    let pendingURIs = Set(pendingStore?.entries(accountDID: accountDID).map(\.uri) ?? [])
    if pendingStore != nil {
      for (uri, state) in states where operations[uri] == nil && !pendingURIs.contains(uri) {
        if case .pendingSync = state {
          states[uri] = .idle
          intents[uri] = nil
        }
      }
    }
    for entry in pendingStore?.entries(accountDID: accountDID) ?? [] where operations[entry.uri] == nil {
      switch entry.intent {
      case .saved: intents[entry.uri] = .add(.saved)
      case .unpinned: intents[entry.uri] = .add(.unpinned)
      case .pinned: intents[entry.uri] = .add(.pinned)
      case .removed: intents[entry.uri] = .remove
      }
      states[entry.uri] = .pendingSync(Self.pendingSyncMessage)
    }
  }

  private func snapshot(_ preferences: Preferences) {
    savedFeeds = preferences.savedFeeds
    pinnedFeeds = preferences.pinnedFeeds
    pendingStore?.reconcile(accountDID: accountDID, pinned: &pinnedFeeds, saved: &savedFeeds)
  }
}
