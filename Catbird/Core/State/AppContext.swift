import Foundation
import Petrel

/// A lightweight, thread-safe snapshot of AppState context for background services
///
/// Background services should capture an AppContext instance on the main actor
/// rather than directly accessing AppStateManager.shared.activeState from background threads.
///
/// Usage:
/// ```swift
/// // On main actor (e.g., when scheduling background work)
/// let context = await MainActor.run {
///   AppContext.from(appState)
/// }
///
/// // Later, in background task
/// Task.detached {
///   await context.performBackgroundRefresh()
/// }
/// ```
struct AppContext: Sendable {
  // MARK: - Core Properties

  /// User DID for this context
  let userDID: String

  /// Whether the user is authenticated
  let isAuthenticated: Bool

  /// User's handle (e.g., "@username.bsky.social")
  let userHandle: String?

  /// Whether notifications are enabled for this user
  let notificationsEnabled: Bool

  // MARK: - Service References (Sendable)

  /// Notification manager reference (if available and sendable)
  /// Note: This is nonisolated(unsafe) - callers must ensure thread-safe usage
  nonisolated(unsafe) let notificationManager: NotificationManager?

  /// Graph manager reference (if available and sendable)
  /// Note: This is nonisolated(unsafe) - callers must ensure thread-safe usage
  nonisolated(unsafe) let graphManager: GraphManager?

  /// Auth manager for token access
  /// Note: This is nonisolated(unsafe) - callers must ensure thread-safe usage
  nonisolated(unsafe) let authManager: AuthenticationManager?

  // MARK: - Initialization

  /// Create an AppContext from an AppState instance
  /// Must be called on @MainActor
  @MainActor
  static func from(_ appState: AppState) -> AppContext {
    return AppContext(
      userDID: appState.userDID,
      isAuthenticated: appState.isAuthenticated,
      userHandle: appState.currentUserProfile?.handle.description,
      notificationsEnabled: appState.notificationManager.notificationsEnabled,
      notificationManager: appState.notificationManager,
      graphManager: appState.graphManager,
      authManager: AppStateManager.shared.authentication
    )
  }

  /// Create an empty context for when no user is authenticated
  static var unauthenticated: AppContext {
    return AppContext(
      userDID: "",
      isAuthenticated: false,
      userHandle: nil,
      notificationsEnabled: false,
      notificationManager: nil,
      graphManager: nil,
      authManager: nil
    )
  }
}

// MARK: - Background Operation Helpers

extension AppContext {
  /// Check if this context is valid for background operations
  var isValidForBackgroundWork: Bool {
    return isAuthenticated && !userDID.isEmpty
  }

  /// Get an ATProtoClient for API operations
  /// Returns nil if not authenticated or auth manager unavailable
  func createClient() async -> ATProtoClient? {
    guard let authManager = authManager,
          authManager.state.isAuthenticated else {
      return nil
    }

    // Return existing client if available
    return await authManager.client
  }
}
