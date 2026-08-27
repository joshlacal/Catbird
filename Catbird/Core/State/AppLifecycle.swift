import Foundation

/// Application lifecycle state machine
/// Represents the high-level state of the application from launch to authentication
@MainActor
enum AppLifecycle: Equatable, CustomStringConvertible {
  /// App is initializing, checking for saved session
  case launching

  /// No authenticated account - show login or account picker
  case unauthenticated

  /// Authenticated with active AppState containing all account data
  case authenticated(AppState)

  /// Authenticated session is deactivated - requires reactivation interstitial
  case deactivated(AppState)

  /// Authenticated session is taken down / suspended - requires takedown & appeal screen
  case takendown(AppState)

  /// Convenience accessor for the active AppState (if any session is loaded)
  var appState: AppState? {
    switch self {
    case .authenticated(let state), .deactivated(let state), .takendown(let state):
      return state
    case .launching, .unauthenticated:
      return nil
    }
  }

  /// Check if currently fully authenticated (interactive app content permitted)
  var isAuthenticated: Bool {
    if case .authenticated = self {
      return true
    }
    return false
  }

  /// Check if currently restricted (deactivated or taken down)
  var isRestricted: Bool {
    switch self {
    case .deactivated, .takendown:
      return true
    case .launching, .unauthenticated, .authenticated:
      return false
    }
  }

  /// Get the current user DID if available
  var userDID: String? {
    appState?.userDID
  }

  // MARK: - CustomStringConvertible

  var description: String {
    switch self {
    case .launching:
      return "launching"
    case .unauthenticated:
      return "unauthenticated"
    case .authenticated(let appState):
      return "authenticated(\(appState.userDID))"
    case .deactivated(let appState):
      return "deactivated(\(appState.userDID))"
    case .takendown(let appState):
      return "takendown(\(appState.userDID))"
    }
  }

  // MARK: - Equatable

  static func == (lhs: AppLifecycle, rhs: AppLifecycle) -> Bool {
    switch (lhs, rhs) {
    case (.launching, .launching):
      return true
    case (.unauthenticated, .unauthenticated):
      return true
    case (.authenticated(let lhsState), .authenticated(let rhsState)):
      return lhsState.userDID == rhsState.userDID
    case (.deactivated(let lhsState), .deactivated(let rhsState)):
      return lhsState.userDID == rhsState.userDID
    case (.takendown(let lhsState), .takendown(let rhsState)):
      return lhsState.userDID == rhsState.userDID
    default:
      return false
    }
  }
}
