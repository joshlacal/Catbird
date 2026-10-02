import Foundation
import OSLog

enum SceneRouteCommand: Equatable, Sendable {
  case navigate(NavigationDestination, tabIndex: Int)
  case showTab(Int, resetPath: Bool)

  var tabIndex: Int {
    switch self {
    case .navigate(_, let tabIndex), .showTab(let tabIndex, _): return tabIndex
    }
  }
}

struct SceneRouteRequest: Identifiable, Equatable, Sendable {
  let id: UUID
  let accountDID: String
  let command: SceneRouteCommand
  let preferredSceneID: UUID?

  init(
    id: UUID = UUID(),
    accountDID: String,
    command: SceneRouteCommand,
    preferredSceneID: UUID? = nil
  ) {
    self.id = id
    self.accountDID = accountDID
    self.command = command
    self.preferredSceneID = preferredSceneID
  }

  init(
    id: UUID = UUID(),
    accountDID: String,
    destination: NavigationDestination,
    tabIndex: Int,
    preferredSceneID: UUID? = nil
  ) {
    self.init(
      id: id,
      accountDID: accountDID,
      command: .navigate(destination, tabIndex: tabIndex),
      preferredSceneID: preferredSceneID
    )
  }
}

/// Routes operating-system navigation events to an attached, active scene.
/// Account services and requests never retain a scene through this registry.
@MainActor
final class SceneRouteCoordinator {
  static let shared = SceneRouteCoordinator()
  static let maxPendingRequests = 16
  static let pendingTTL: TimeInterval = 300

  enum DropReason: String, Equatable {
    case expired
    case sceneDisconnected
    case sceneUnavailable
    case capacityExceeded
    case accountDiscarded
    case preparationRejected
  }

  enum DeliveryResult: Equatable {
    case delivered(sceneID: UUID)
    case queued
    case duplicate
    case dropped(reason: DropReason)
  }

  private struct Registration {
    weak var context: SceneNavigationContext?
    var isActive: Bool
    var activityOrdinal: UInt64
  }

  typealias BeforeDelivery = @MainActor (SceneNavigationContext) -> Bool

  private struct PendingRoute {
    let request: SceneRouteRequest
    let enqueuedAt: TimeInterval
    let beforeDelivery: BeforeDelivery?
  }

  private let logger = Logger(subsystem: "blue.catbird", category: "SceneRouteCoordinator")
  private let now: () -> TimeInterval
  private let onDrop: ((SceneRouteRequest, DropReason) -> Void)?
  private var registrations: [UUID: Registration] = [:]
  private var disconnectedAt: [UUID: TimeInterval] = [:]
  private var pending: [PendingRoute] = []
  private var nextActivityOrdinal: UInt64 = 0
  private var isDraining = false
  private var inFlightRequestIDs: Set<UUID> = []

  var pendingRequestCount: Int { pending.count }
  var registeredSceneCount: Int {
    registrations.values.filter { registration in
      guard let context = registration.context else { return false }
      return !context.isInvalidated
    }.count
  }

  init(
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    onDrop: ((SceneRouteRequest, DropReason) -> Void)? = nil
  ) {
    self.now = now
    self.onDrop = onDrop
  }

  /// Replacing an account context preserves the window's identity and queued
  /// routes, but requires a fresh activation event before delivery.
  func register(_ context: SceneNavigationContext) {
    guard !context.isInvalidated else { return }
    let previous = registrations[context.sceneID]
    prune()
    if let previousContext = previous?.context, previousContext === context {
      drainPending()
      return
    }
    previous?.context?.invalidate()
    registrations[context.sceneID] = Registration(
      context: context,
      isActive: false,
      activityOrdinal: previous?.activityOrdinal ?? 0
    )
    disconnectedAt.removeValue(forKey: context.sceneID)
    drainPending()
  }

  func setActive(sceneID: UUID, isActive: Bool) {
    prune()
    guard var registration = registrations[sceneID],
          let context = registration.context, !context.isInvalidated else { return }
    if registration.isActive != isActive {
      registration.isActive = isActive
      if isActive { registration.activityOrdinal = nextOrdinal() }
      registrations[sceneID] = registration
    }
    drainPending()
  }

  /// Call for a real window focus event, not ordinary view recomputation.
  func markFocused(sceneID: UUID) {
    prune()
    guard var registration = registrations[sceneID], registration.isActive,
          let context = registration.context, !context.isInvalidated else { return }
    registration.activityOrdinal = nextOrdinal()
    registrations[sceneID] = registration
    drainPending()
  }

  /// Actual window disconnection cancels explicitly targeted pending actions.
  /// Account replacement within a surviving window uses register instead.
  func disconnect(sceneID: UUID) {
    prune()
    registrations.removeValue(forKey: sceneID)?.context?.invalidate()
    disconnectedAt[sceneID] = now()
    discardPending(where: { $0.preferredSceneID == sceneID }, reason: .sceneDisconnected)
  }

  func discardPending(forAccountDID accountDID: String) {
    prune()
    discardPending(where: { $0.accountDID == accountDID }, reason: .accountDiscarded)
  }

  /// Capture before asynchronous account switching. An inactive historical
  /// target can be captured here, but submit still waits until it is active.
  func preferredSceneIDForExternalEvent() -> UUID? {
    prune()
    if let active = mostRecentContext(activeOnly: true, accountDID: nil) {
      return active.sceneID
    }
    return mostRecentContext(activeOnly: false, accountDID: nil)?.sceneID
  }

  @discardableResult
  func submit(_ request: SceneRouteRequest, beforeDelivery: BeforeDelivery? = nil) -> DeliveryResult {
    prune()
    if inFlightRequestIDs.contains(request.id)
        || pending.contains(where: { $0.request.id == request.id }) { return .duplicate }
    if let preferredID = request.preferredSceneID, disconnectedAt[preferredID] != nil {
      recordDrop(request, reason: .sceneDisconnected)
      return .dropped(reason: .sceneDisconnected)
    }
    if let context = receivingContext(for: request) {
      return deliver(request, to: context, beforeDelivery: beforeDelivery)
    }
    let evicted = pending.count == Self.maxPendingRequests ? pending.removeFirst() : nil
    pending.append(PendingRoute(request: request, enqueuedAt: now(), beforeDelivery: beforeDelivery))
    if let evicted { recordDrop(evicted.request, reason: .capacityExceeded) }
    return .queued
  }

  private func nextOrdinal() -> UInt64 {
    nextActivityOrdinal += 1
    return nextActivityOrdinal
  }

  private func receivingContext(for request: SceneRouteRequest) -> SceneNavigationContext? {
    if let preferredID = request.preferredSceneID {
      guard let registration = registrations[preferredID], registration.isActive,
            let context = registration.context, !context.isInvalidated,
            context.accountDID == request.accountDID else { return nil }
      return context
    }
    return mostRecentContext(activeOnly: true, accountDID: request.accountDID)
  }

  private func mostRecentContext(activeOnly: Bool, accountDID: String?) -> SceneNavigationContext? {
    let candidates = registrations.values.compactMap { registration -> (SceneNavigationContext, UInt64)? in
      guard let context = registration.context, !context.isInvalidated,
            registration.activityOrdinal > 0,
            !activeOnly || registration.isActive,
            accountDID == nil || context.accountDID == accountDID else { return nil }
      return (context, registration.activityOrdinal)
    }
    return candidates.max(by: { $0.1 < $1.1 })?.0
  }

  private func deliver(
    _ request: SceneRouteRequest,
    to context: SceneNavigationContext,
    beforeDelivery: BeforeDelivery?
  ) -> DeliveryResult {
    guard inFlightRequestIDs.insert(request.id).inserted else { return .duplicate }
    defer { inFlightRequestIDs.remove(request.id) }
    if let beforeDelivery, !beforeDelivery(context) {
      recordDrop(request, reason: .preparationRejected)
      return .dropped(reason: .preparationRejected)
    }
    guard isCurrentReceiver(context, for: request) else {
      recordDrop(request, reason: .sceneUnavailable)
      return .dropped(reason: .sceneUnavailable)
    }
    let manager = context.navigationManager
    manager.updateCurrentTab(request.command.tabIndex)
    manager.tabSelection?(request.command.tabIndex)
    // Selection callbacks can synchronously disconnect or replace their scene.
    guard isCurrentReceiver(context, for: request) else {
      recordDrop(request, reason: .sceneUnavailable)
      return .dropped(reason: .sceneUnavailable)
    }
    switch request.command {
    case .navigate(let destination, let tabIndex):
      manager.navigate(to: destination, in: tabIndex)
    case .showTab(let tabIndex, let resetPath):
      if resetPath { manager.clearPath(for: tabIndex) }
    }
    return .delivered(sceneID: context.sceneID)
  }

  private func isCurrentReceiver(_ context: SceneNavigationContext, for request: SceneRouteRequest) -> Bool {
    guard !context.isInvalidated,
          let registration = registrations[context.sceneID], registration.isActive,
          registration.context === context,
          context.accountDID == request.accountDID else { return false }
    return true
  }

  private func drainPending() {
    guard !isDraining else { return }
    isDraining = true
    defer { isDraining = false }
    prune()
    while let index = pending.firstIndex(where: { receivingContext(for: $0.request) != nil }) {
      let route = pending.remove(at: index)
      guard let context = receivingContext(for: route.request) else { continue }
      _ = deliver(route.request, to: context, beforeDelivery: route.beforeDelivery)
    }
  }

  private func prune() {
    let timestamp = now()
    registrations = registrations.filter { _, registration in
      guard let context = registration.context else { return false }
      return !context.isInvalidated
    }
    disconnectedAt = disconnectedAt.filter { timestamp - $0.value < Self.pendingTTL }
    let expired = pending.filter { timestamp - $0.enqueuedAt >= Self.pendingTTL }
    pending.removeAll { timestamp - $0.enqueuedAt >= Self.pendingTTL }
    for route in expired { recordDrop(route.request, reason: .expired) }
  }

  private func discardPending(where predicate: (SceneRouteRequest) -> Bool, reason: DropReason) {
    let discarded = pending.filter { predicate($0.request) }
    pending.removeAll { predicate($0.request) }
    for route in discarded { recordDrop(route.request, reason: reason) }
  }

  private func recordDrop(_ request: SceneRouteRequest, reason: DropReason) {
    logger.info("Dropping scene route \(request.id.uuidString, privacy: .private): \(reason.rawValue, privacy: .public)")
    onDrop?(request, reason)
  }
}
