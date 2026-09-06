import Foundation
import GRDB
import OSLog
import Synchronization

/// Coordinates GRDB database suspension/resume to avoid iOS `0xdead10cc` termination.
///
/// This implements GRDB's recommended suspension technique:
/// - Open databases with `Configuration.observesSuspensionNotifications = true`
/// - Post `Database.suspendNotification` when the app is backgrounding
/// - Post `Database.resumeNotification` when database work needs to run again
///
/// We keep a small amount of local state so background tasks can temporarily resume
/// database access while the app lifecycle is in a suspended phase, and then suspend
/// again once all background work has completed.
enum GRDBSuspensionCoordinator {
  private static let logger = Logger(subsystem: "blue.catbird", category: "GRDBSuspension")

  private struct State: Sendable {
    var lifecycleSuspended = false
    var activeWorkCount = 0
    var isSuspended = false
    var isDeliveringNotifications = false
    var pendingAction: Action?
  }

  private static let state = Mutex(State())
  // Keep state transitions and their synchronous notifications in the same
  // critical section, so competing lifecycle/work callbacks cannot reorder them.
  // Notification observers may synchronously reenter the coordinator.
  private static let transitionLock = NSRecursiveLock()

  private enum Action: Sendable {
    case suspend(reason: String)
    case resume(reason: String)
    case none
  }

  /// Update lifecycle suspension state (foreground vs inactive/background).
  static func setLifecycleSuspended(_ suspended: Bool, reason: String) {
    transitionLock.lock()
    defer { transitionLock.unlock() }
    let action: Action = state.withLock { s in
      s.lifecycleSuspended = suspended

      if !suspended {
        guard s.isSuspended else { return .none }
        s.isSuspended = false
        return .resume(reason: "foreground: \(reason)")
      }

      if s.activeWorkCount == 0 {
        guard !s.isSuspended else { return .none }
        s.isSuspended = true
        return .suspend(reason: "lifecycle suspended: \(reason)")
      } else {
        return .none
      }
    }
    perform(action)
  }

  /// Indicate a unit of background work is starting and needs resumed DB access.
  static func beginBackgroundWork(reason: String) {
    transitionLock.lock()
    defer { transitionLock.unlock() }
    let action: Action = state.withLock { s in
      s.activeWorkCount += 1
      guard s.isSuspended else { return .none }
      s.isSuspended = false
      return .resume(reason: "beginBackgroundWork(\(s.activeWorkCount)): \(reason)")
    }
    perform(action)
  }

  /// Indicate a unit of background work has completed.
  static func endBackgroundWork(reason: String) {
    transitionLock.lock()
    defer { transitionLock.unlock() }
    var underflowed = false
    let action: Action = state.withLock { s in
      if s.activeWorkCount > 0 {
        s.activeWorkCount -= 1
      } else {
        underflowed = true
        s.activeWorkCount = 0
      }

      if s.activeWorkCount == 0, s.lifecycleSuspended {
        guard !s.isSuspended else { return .none }
        s.isSuspended = true
        return .suspend(reason: "endBackgroundWork -> lifecycle suspended: \(reason)")
      }
      return .none
    }
    if underflowed {
      logger.warning("endBackgroundWork called with activeWorkCount=0: \(reason, privacy: .public)")
    }
    perform(action)
  }

  /// Admit synchronous initialization only while database access is resumed.
  /// The closure must enable suspension notifications before returning its pool.
  /// Holding the transition lock also protects initial schema writes from a
  /// suspend notification racing with the installation of the pool's observers.
  static func withResumedDatabaseAccess<T>(_ access: () throws -> T) throws -> T {
    transitionLock.lock()
    defer { transitionLock.unlock() }
    guard !state.withLock({ $0.isSuspended }) else {
      throw DatabaseError(resultCode: .SQLITE_ABORT, message: "Database is suspended")
    }
    return try access()
  }

  private static func perform(_ action: Action) {
    if case .none = action { return }
    let shouldDeliver = state.withLock { s in
      s.pendingAction = action
      guard !s.isDeliveringNotifications else { return false }
      s.isDeliveringNotifications = true
      return true
    }
    guard shouldDeliver else { return }

    // A notification observer can change lifecycle state synchronously. Finish
    // delivery to every pool before delivering the latest resulting transition.
    while let nextAction = state.withLock({ s -> Action? in
      let next = s.pendingAction
      s.pendingAction = nil
      if next == nil { s.isDeliveringNotifications = false }
      return next
    }) {
      post(nextAction)
    }
  }

  private static func post(_ action: Action) {
    switch action {
    case .suspend(let reason):
      NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
      logger.debug("Posted GRDB suspend: \(reason, privacy: .public)")
    case .resume(let reason):
      NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
      logger.debug("Posted GRDB resume: \(reason, privacy: .public)")
    case .none:
      break
    }
  }
}
