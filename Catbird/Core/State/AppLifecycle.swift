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

  /// Convenience accessor for the authenticated AppState
  var appState: AppState? {
    if case .authenticated(let state) = self {
      return state
    }
    return nil
  }

  /// Check if currently authenticated
  var isAuthenticated: Bool {
    if case .authenticated = self {
      return true
    }
    return false
  }

  /// Get the current user DID if authenticated
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
    default:
      return false
    }
  }
}
