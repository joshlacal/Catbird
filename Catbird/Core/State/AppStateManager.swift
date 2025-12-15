import CatbirdMLSCore
import Foundation
import OSLog
import SwiftData
import SwiftUI

// MARK: - ModelContainer State
// Moved here from CatbirdApp.swift so it can be stored in AppStateManager
// and persist across App struct recreations
enum ModelContainerState {
  case loading
  case ready(ModelContainer)
  case failed(Error)
}

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

  /// Observes auth state changes and keeps lifecycle in sync (e.g. session expiry → login/reauth)
  @ObservationIgnored
  private var authStateObservationTask: Task<Void, Never>? = nil

  /// Pool of authenticated AppState instances, keyed by user DID
  /// NO GUEST STATES - only authenticated accounts are cached
  private var authenticatedStates: [String: AppState] = [:]
  
  /// Users currently undergoing MLS storage maintenance (prevents DB access)
  private var storageMaintenanceUsers: Set<String> = []

  /// Pending composer draft to be reopened after account switch
  var pendingComposerDraft: PostComposerDraft?

  /// Maximum number of accounts to keep in memory (LRU eviction)
  private let maxCachedAccounts = 3

  /// Track access order for LRU eviction
  private var accessOrder: [String] = []

  /// Flag indicating whether an account transition is currently in progress
  /// Used to prevent operations during the transition window
  private(set) var isTransitioning: Bool = false

  // MARK: - App Initialization State
  // These flags are stored here (instead of @State in CatbirdApp) because @State in App structs
  // does not persist reliably across background/foreground cycles - iOS can recreate the App struct
  // and reset all @State to initial values, causing full re-initialization on every foreground return.
  
  /// ModelContainer state for SwiftData
  var modelContainerState: ModelContainerState = .loading
  
  /// Tracks if the app has been initialized (prevents duplicate initialization)
  var didInitialize: Bool = false
  
  /// Tracks if handleSceneAppear has been called (prevents duplicate scene setup)
  var hasHandledSceneAppear: Bool = false
  
  /// Tracks if state restoration has been performed
  var hasRestoredState: Bool = false

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

    startAuthStateObservationIfNeeded()
  }

  private func startAuthStateObservationIfNeeded() {
    guard authStateObservationTask == nil else { return }

    authStateObservationTask = Task { @MainActor [weak self] in
      guard let self else { return }

      for await state in self.authManager.stateChanges {
        switch state {
        case .authenticated(let userDID):
          guard self.lifecycle.userDID != userDID else { continue }
          self.logger.info("🔔 Auth became authenticated for: \(userDID) - transitioning")
          await self.transitionToAuthenticated(userDID: userDID)

        case .unauthenticated:
          guard self.lifecycle != .unauthenticated else { continue }
          self.logger.info("🔔 Auth became unauthenticated - transitioning")
          if #available(iOS 17.0, macOS 14.0, *) {
            withAnimation(.snappy(duration: 0.32, extraBounce: 0.0)) {
              self.lifecycle = .unauthenticated
            }
          } else {
            withAnimation(.easeInOut(duration: 0.25)) {
              self.lifecycle = .unauthenticated
            }
          }

        default:
          continue
        }
      }
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
      
      // Ensure model context is set (might not be if AppState was created before container was ready)
      if case .ready(let container) = modelContainerState {
        appState.composerDraftManager.setModelContext(container.mainContext)
        appState.notificationManager.setModelContext(container.mainContext)
      }

      // Only show transition overlay for actual account switches, not initial launch
      if case .authenticated = lifecycle {
        appState.isTransitioningAccounts = true
      }

    } else {
      // Create new AppState with authenticated client for THIS account
      logger.info("🆕 Creating new AppState for: \(userDID)")
      appState = AppState(userDID: userDID, client: client)
      authenticatedStates[userDID] = appState
      isCachedAccount = false
      updateAccessOrder(userDID)
      evictLRUIfNeeded()
      
      // Initialize model context for draft persistence
      if case .ready(let container) = modelContainerState {
        appState.composerDraftManager.setModelContext(container.mainContext)
        appState.notificationManager.setModelContext(container.mainContext)
      }
      
      // Only show transition overlay for actual account switches, not initial launch
      if case .authenticated = lifecycle {
        appState.isTransitioningAccounts = true
      }
    }

    // Transfer pending draft if present
    if let draft = pendingComposerDraft {
      logger.info("📝 Transferring composer draft to new account")
      appState.composerDraftManager.currentDraft = draft
      // NOTE: Don't clear pendingComposerDraft here - let ContentView.onChange consume it
      // This ensures the onChange fires reliably and reopens the composer
      logger.debug("📝 pendingComposerDraft kept set for ContentView.onChange detection")
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

    if !isCachedAccount {
      // Initialize the new AppState in the background to unblock UI swap
      logger.info("🔄 Initializing new AppState asynchronously")
      let initLogger = logger
      Task(priority: .userInitiated) { [weak appState] in
        guard let appState else { return }

        // Safety timeout - clear transition state after 15 seconds max
        // Prevents overlay from getting stuck if initialization hangs
        let timeoutTask = Task {
          try? await Task.sleep(for: .seconds(15))
          await MainActor.run {
            if appState.isTransitioningAccounts {
              initLogger.warning("⚠️ Account transition timed out after 15s - clearing overlay")
              appState.isTransitioningAccounts = false
            }
          }
        }

        await appState.initialize()
        timeoutTask.cancel()  // Cancel timeout if init succeeds normally

        await MainActor.run {
          appState.isTransitioningAccounts = false
        }
        initLogger.info("✅ New AppState initialized")
      }
    }

    // Kick off the heavy refresh work for cached states in the background
    if isCachedAccount {
      logger.info("✨ Refreshing cached AppState after immediate switch")
      let refreshContext = CachedAppStateContext(appState: appState)
      let targetAccountDID = userDID
      let transitionLogger = logger

      // Safety timeout for cached account refresh - prevents loading overlay from getting stuck
      let timeoutTask = Task {
        try? await Task.sleep(for: .seconds(15))
        await MainActor.run {
          if appState.isTransitioningAccounts {
            transitionLogger.warning("⚠️ Cached account refresh timed out after 15s - clearing overlay")
            appState.isTransitioningAccounts = false
          }
        }
      }

      Task(priority: .userInitiated) {
        await refreshContext.appState.refreshAfterAccountSwitch()
        timeoutTask.cancel()  // Cancel timeout if refresh succeeds normally
        
        // CRITICAL FIX: Ensure isTransitioningAccounts is cleared after refresh completes
        // Previously this was only done for new accounts, not cached ones
        await MainActor.run {
          if appState.isTransitioningAccounts {
            appState.isTransitioningAccounts = false
            transitionLogger.info("✅ Cleared transition state after cached account refresh")
          }
        }
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

    // Set transition flag to prevent operations during switch
    isTransitioning = true
    
    // CRITICAL FIX: Properly shutdown MLS resources for the OLD account BEFORE switching
    // This prevents:
    // 1. SQLite database exhaustion from unclosed connections
    // 2. Race conditions where old managers continue polling with wrong account
    // 3. Account mismatch errors in MLS sync operations
    // 4. HMAC check failures from using wrong encryption key
    if let oldUserDID = lifecycle.userDID, oldUserDID != userDID {
      logger.info("MLS: 🛑 Preparing to shutdown MLS for previous user \(oldUserDID)")
      
      #if os(iOS)
        // Mark old user as under storage maintenance to block any new DB access
        beginStorageMaintenance(for: oldUserDID)
        
        // Get the old AppState and properly shutdown its MLS resources
        if let oldState = authenticatedStates[oldUserDID] {
          logger.info("MLS: Initiating graceful shutdown for previous account")
          await oldState.prepareMLSStorageReset()
          logger.info("MLS: ✅ Previous account MLS shutdown complete")
        }
        
        // Clear maintenance flag after shutdown is complete
        endStorageMaintenance(for: oldUserDID)
      #endif
      
      logger.info("MLS: SQLite storage for previous user \(oldUserDID) is automatically persisted")
    }

    // Store draft for transfer
    if let draft = draft {
      pendingComposerDraft = draft
      logger.info("📝 Stored composer draft for transfer - Text length: \(draft.postText.count)")
    }

    // Clear transition flag BEFORE calling transitionToAuthenticated 
    // (which sets it again and manages its own lifecycle)
    isTransitioning = false
    
    // Transition to the authenticated account
    await transitionToAuthenticated(userDID: userDID)
  }

  /// Remove a specific account's state from cache
  /// - Parameter userDID: The DID of the account to remove
  func removeAccount(_ userDID: String) async {
    logger.info("🗑️ Removing account state: \(userDID)")

    // CRITICAL FIX: Properly cleanup MLS resources before removing
    if let appState = authenticatedStates[userDID] {
      #if os(iOS)
        // Use async shutdown to properly close database connections
        await appState.prepareMLSStorageReset()
      #endif
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

  // MARK: - MLS Storage Maintenance

  func beginStorageMaintenance(for userDID: String) {
    storageMaintenanceUsers.insert(userDID)
  }

  func endStorageMaintenance(for userDID: String) {
    storageMaintenanceUsers.remove(userDID)
  }

  func isUserUnderStorageMaintenance(_ userDID: String) -> Bool {
    storageMaintenanceUsers.contains(userDID)
  }

  func prepareMLSStorageReset(for userDID: String) async {
    logger.info("MLS: Preparing AppState for storage reset: \(userDID)")
    guard let state = authenticatedStates[userDID] else {
      logger.info("MLS: No cached AppState for \(userDID) - nothing to reset")
      return
    }

    await state.prepareMLSStorageReset()
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
      // CRITICAL FIX: Use closeDatabaseAndDrain to prevent WAL corruption
      Task {
        await MLSGRDBManager.shared.closeDatabaseAndDrain(for: lruDID, timeout: 3.0)
      }
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
      // CRITICAL FIX: Use closeDatabaseAndDrain to prevent WAL corruption
      Task {
        await MLSGRDBManager.shared.closeDatabaseAndDrain(for: did, timeout: 3.0)
      }
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
