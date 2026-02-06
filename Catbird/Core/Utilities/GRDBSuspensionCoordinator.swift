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
  }

  private static let state = Mutex(State())

  private enum Action: Sendable {
    case suspend(reason: String)
    case resume(reason: String)
    case none
  }

  /// Update lifecycle suspension state (foreground vs inactive/background).
  static func setLifecycleSuspended(_ suspended: Bool, reason: String) {
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

  private static func perform(_ action: Action) {
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
