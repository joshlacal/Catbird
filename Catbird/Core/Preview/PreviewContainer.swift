import Foundation
import OSLog

/// Centralized container for preview app state with real network access.
///
/// Authentication priority:
/// 1. PreviewAuthManager (xcconfig credentials) → self-contained, no running app needed
/// 2. AppStateManager.shared (if app is running and logged in) → reuses existing session
/// 3. nil → triggers skeleton/placeholder UI in preview modifiers
///
/// Usage:
/// ```swift
/// #Preview {
///   MyView()
///     .previewWithAuthenticatedState()
/// }
/// ```
@MainActor
final class PreviewContainer {
  static let shared = PreviewContainer()

  private let logger = Logger(subsystem: "blue.catbird", category: "Preview")
  private var cachedAppState: AppState?
  private var hasAttemptedAuth = false

  private init() {}

  /// Main entry point: returns an authenticated AppState for previews.
  /// Tries xcconfig credentials first, then falls back to running app session.
  var appState: AppState? {
    get async {
      if let cached = cachedAppState { return cached }
      if hasAttemptedAuth { return nil }
      hasAttemptedAuth = true

      // Strategy 1: Self-authenticate via PreviewAuthManager (xcconfig credentials)
      if PreviewAuthManager.shared.isConfigured {
        if let client = await PreviewAuthManager.shared.getClient(),
          let did = PreviewAuthManager.shared.cachedUserDID
        {
          let state = AppState(userDID: did, client: client)
          cachedAppState = state
          logger.info("Preview using xcconfig-authenticated AppState for: \(did)")
          return state
        }
      }

      // Strategy 2: Fall back to AppStateManager.shared (requires running app login)
      await AppStateManager.shared.initialize()
      if case .authenticated(let state) = AppStateManager.shared.lifecycle {
        cachedAppState = state
        logger.info("Preview using running app AppState for: \(state.userDID)")
        return state
      }

      logger.warning("No preview authentication available — configure PreviewSecrets.xcconfig")
      return nil
    }
  }

  /// Access to the app state manager
  var appStateManager: AppStateManager {
    AppStateManager.shared
  }

  /// Access to auth manager
  var authManager: AuthenticationManager {
    AppStateManager.shared.authentication
  }
}
