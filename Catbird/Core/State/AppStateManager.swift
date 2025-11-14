import Foundation
import OSLog
import SwiftUI

/// Lightweight Sendable wrapper so we can hand AppState instances to async tasks safely
private struct CachedAppStateContext: @unchecked Sendable {
  let appState: AppState
}


/// Manages application lifecycle and authenticated AppState instances
/// Owns the AuthenticationManager and orchestrates state transitions
@MainActor
@Observable
final class AppStateManager {
  // MARK: - Singleton

  static let shared = AppStateManager()

  // MARK: - Properties

  private let logger = Logger(subsystem: "blue.catbird", category: "AppStateManager")

  /// The authentication manager (owned by AppStateManager)
  private let authManager = AuthenticationManager()

  /// Current application lifecycle state
  private(set) var lifecycle: AppLifecycle = .launching

  /// Pool of authenticated AppState instances, keyed by user DID
  /// NO GUEST STATES - only authenticated accounts are cached
  private var authenticatedStates: [String: AppState] = [:]

  /// Pending composer draft to be reopened after account switch
  var pendingComposerDraft: PostComposerDraft?

  /// Maximum number of accounts to keep in memory (LRU eviction)
  private let maxCachedAccounts = 3

  /// Track access order for LRU eviction
  private var accessOrder: [String] = []

  /// Flag indicating whether an account transition is currently in progress
  /// Used to prevent operations during the transition window
  private(set) var isTransitioning: Bool = false

  // MARK: - Initialization

  private init() {
    logger.info("AppStateManager initialized")
  }

  /// Initialize the app - check for saved session and transition to appropriate state
  func initialize() async {
    logger.info("🚀 Initializing AppStateManager")

    // Initialize auth manager (checks for saved session, attempts token refresh)
    await authManager.initialize()

    // Check if we have an authenticated session
    if case .authenticated(let userDID) = authManager.state {
      logger.info("✅ Found authenticated session for: \(userDID)")
      await transitionToAuthenticated(userDID: userDID)
    } else {
      logger.info("ℹ️ No authenticated session - transitioning to unauthenticated")
      lifecycle = .unauthenticated
    }
  }

  // MARK: - State Transitions

  /// Transition to authenticated state with a specific user
  /// Creates or retrieves AppState for the user and updates lifecycle
  /// - Parameter userDID: The DID of the user to authenticate as
  func transitionToAuthenticated(userDID: String) async {
    logger.info("🔐 Transitioning to authenticated state for: \(userDID)")

    // Set transition flag to prevent operations during switch
    isTransitioning = true
    defer { isTransitioning = false }

    // CRITICAL: Switch AuthManager to the target account FIRST before getting client
    // This ensures we get the correct client for the account we're switching to
    do {
      logger.info("🔄 Switching AuthManager to account: \(userDID)")
      try await authManager.switchToAccount(did: userDID)
      logger.info("✅ AuthManager switched successfully")
    } catch {
      logger.error("❌ Failed to switch AuthManager: \(error.localizedDescription)")
      lifecycle = .unauthenticated
      return
    }

    // Now get the client for the target account
    guard let client = authManager.client else {
      logger.error("❌ Cannot transition to authenticated - no client available after switch")
      lifecycle = .unauthenticated
      return
    }

    let appState: AppState
    let isCachedAccount: Bool

    if let existing = authenticatedStates[userDID] {
      // Reuse existing AppState (it already has the correct client from when it was created)
      logger.debug("♻️ Using existing AppState for: \(userDID)")
      appState = existing
      isCachedAccount = true
      updateAccessOrder(userDID)

      // Optimistically mark the state as transitioning so the UI can react immediately
      appState.isTransitioningAccounts = true

    } else {
      // Create new AppState with authenticated client for THIS account
      logger.info("🆕 Creating new AppState for: \(userDID)")
      appState = AppState(userDID: userDID, client: client)
      authenticatedStates[userDID] = appState
      isCachedAccount = false
      updateAccessOrder(userDID)
      evictLRUIfNeeded()

      // Initialize the new AppState before presenting it
      logger.info("🔄 Initializing new AppState")
      await appState.initialize()
      logger.info("✅ New AppState initialized")
    }

    // Transfer pending draft if present
    if let draft = pendingComposerDraft {
      logger.info("📝 Transferring composer draft to new account")
      appState.composerDraftManager.currentDraft = draft
      pendingComposerDraft = nil
    }

    // Update lifecycle state with a gentle animation so the UI swaps immediately
    let newLifecycle: AppLifecycle = .authenticated(appState)

    if #available(iOS 17.0, macOS 14.0, *) {
      withAnimation(.snappy(duration: 0.32, extraBounce: 0.0)) {
        lifecycle = newLifecycle
      }
    } else {
      withAnimation(.easeInOut(duration: 0.25)) {
        lifecycle = newLifecycle
      }
    }

    // Kick off the heavy refresh work for cached states in the background
    if isCachedAccount {
      logger.info("✨ Refreshing cached AppState after immediate switch")
      let refreshContext = CachedAppStateContext(appState: appState)
      let targetAccountDID = userDID
      let transitionLogger = logger

      Task(priority: .userInitiated) {
        await refreshContext.appState.refreshAfterAccountSwitch()
        transitionLogger.info("✅ Cached AppState refresh finished for: \(targetAccountDID)")
      }
    }

    logger.info("✅ Transitioned to authenticated state")
  }

  /// Log out the current user and transition to unauthenticated state
  func logout() async {
    logger.info("🚪 Logging out")

    // Clear auth manager session
    await authManager.logout()

    // Transition to unauthenticated
    lifecycle = .unauthenticated

    logger.info("✅ Logged out successfully")
  }

  // MARK: - Account Management

  /// Switch to a different authenticated account
  /// - Parameters:
  ///   - userDID: The DID of the account to switch to
  ///   - draft: Optional composer draft to transfer
  func switchAccount(to userDID: String, withDraft draft: PostComposerDraft? = nil) async {
    logger.info("🔄 Switching to account: \(userDID)")

    // Save MLS state for the current user before switching
    if let oldUserDID = lifecycle.userDID, oldUserDID != userDID {
      logger.info("MLS: Saving storage for previous user \(oldUserDID)")
      do {
        try await MLSClient.shared.saveStorage(for: oldUserDID)
        logger.info("✅ MLS: Saved storage for previous user \(oldUserDID)")
      } catch {
        logger.error("⚠️ MLS: Failed to save storage for previous user: \(error.localizedDescription)")
      }
    }

    // Store draft for transfer
    if let draft = draft {
      pendingComposerDraft = draft
      logger.info("📝 Stored composer draft for transfer - Text length: \(draft.postText.count)")
    }

    // Transition to the authenticated account
    await transitionToAuthenticated(userDID: userDID)
  }

  /// Remove a specific account's state from cache
  /// - Parameter userDID: The DID of the account to remove
  func removeAccount(_ userDID: String) {
    logger.info("🗑️ Removing account state: \(userDID)")

    // Cleanup tasks before removing
    if let appState = authenticatedStates[userDID] {
      appState.cleanup()
    }

    authenticatedStates.removeValue(forKey: userDID)
    accessOrder.removeAll { $0 == userDID }
  }

  /// Get AppState for a specific account without switching to it
  /// - Parameter userDID: The DID of the account
  /// - Returns: The AppState if it exists in cache, nil otherwise
  func getState(for userDID: String) -> AppState? {
    return authenticatedStates[userDID]
  }

  /// Check if an account has cached state
  /// - Parameter userDID: The DID to check
  /// - Returns: True if state exists in memory
  func hasState(for userDID: String) -> Bool {
    return authenticatedStates[userDID] != nil
  }

  // MARK: - Memory Management

  /// Update access order for LRU tracking
  private func updateAccessOrder(_ userDID: String) {
    accessOrder.removeAll { $0 == userDID }
    accessOrder.append(userDID)
  }

  /// Evict least recently used accounts if over limit
  private func evictLRUIfNeeded() {
    guard authenticatedStates.count > maxCachedAccounts else { return }

    // Keep the most recent accounts
    let toEvict = authenticatedStates.count - maxCachedAccounts

    for _ in 0..<toEvict {
      guard let lruDID = accessOrder.first else { break }

      // Don't evict the currently active account
      if lifecycle.userDID == lruDID {
        continue
      }

      logger.debug("♻️ Evicting LRU account: \(lruDID)")

      // Cleanup tasks before eviction
      if let appState = authenticatedStates[lruDID] {
        appState.cleanup()
      }

      authenticatedStates.removeValue(forKey: lruDID)
      accessOrder.removeFirst()

      // Close MLS database for evicted account
      MLSGRDBManager.shared.closeDatabase(for: lruDID)
      logger.debug("Closed MLS database for evicted account: \(lruDID)")
    }
  }

  /// Manually clear all cached accounts except active
  func clearInactiveAccounts() {
    let activeUserDID = lifecycle.userDID
    let inactiveAccounts = authenticatedStates.keys.filter { $0 != activeUserDID }

    for did in inactiveAccounts {
      // Cleanup tasks before removal
      if let appState = authenticatedStates[did] {
        appState.cleanup()
      }

      authenticatedStates.removeValue(forKey: did)
      accessOrder.removeAll { $0 == did }

      // Close MLS database for cleared account
      MLSGRDBManager.shared.closeDatabase(for: did)
    }

    logger.info("🗑️ Cleared \(inactiveAccounts.count) inactive account(s)")
  }

  // MARK: - Public Accessors

  /// Access the authentication manager (for login flows, account management)
  var authentication: AuthenticationManager {
    authManager
  }

  /// Clear the pending composer draft (called after UI consumes it)
  func clearPendingComposerDraft() {
    logger.debug("Clearing pending composer draft")
    pendingComposerDraft = nil
  }

  // MARK: - Debugging

  /// Get statistics about cached accounts
  var stats: String {
    """
    AppStateManager Stats:
    - Lifecycle: \(lifecycle)
    - Total cached accounts: \(authenticatedStates.count)
    - Access order: \(accessOrder.joined(separator: ", "))
    """
  }
}
