import CatbirdMLSCore
import CatbirdMLSService
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
  case degraded(ModelContainer, reason: String)  // In-memory fallback mode
  case failed(Error)

  /// Returns the container if available (either ready or degraded)
  var container: ModelContainer? {
    switch self {
    case .ready(let container), .degraded(let container, _):
      return container
    case .loading, .failed:
      return nil
    }
  }

  /// Whether the app is running in degraded (in-memory) mode
  var isDegraded: Bool {
    if case .degraded = self { return true }
    return false
  }
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
  
  /// E2E test mode flag (detected from launch arguments)
  var isE2EMode: Bool = false
  
  /// E2E run ID (from launch arguments)
  var e2eRunId: String?
  
  /// E2E user credentials (from launch arguments)
  private var e2eUser: String?
  private var e2ePass: String?
  
  /// E2E PDS URL (optional, for custom domains)
  private var e2ePdsURL: String?

  // MARK: - Initialization

  private init() {
    logger.info("AppStateManager initialized")
    
    // Detect E2E mode from launch arguments
    let args = ProcessInfo.processInfo.arguments
    
    // Log argument count (always, for E2E debugging)
    logger.info("[E2E-DEBUG] Launch arguments count: \(args.count)")
    for (index, arg) in args.enumerated() {
      // Log ALL args but redact potential passwords
      if arg.lowercased().contains("pass") || arg.lowercased().contains("secret") {
        logger.info("[E2E-DEBUG] arg[\(index)]: [REDACTED]")
      } else {
        logger.info("[E2E-DEBUG] arg[\(index)]: \(arg)")
      }
    }
    
    if args.contains("--e2e-mode") {
      isE2EMode = true
      // Extract run ID
      if let runIdArg = args.first(where: { $0.hasPrefix("--run-id=") }) {
        e2eRunId = String(runIdArg.dropFirst("--run-id=".count))
      }
      // Extract E2E user
      if let userArg = args.first(where: { $0.hasPrefix("--e2e-user=") }) {
        e2eUser = String(userArg.dropFirst("--e2e-user=".count))
      }
      // Extract E2E password
      if let passArg = args.first(where: { $0.hasPrefix("--e2e-pass=") }) {
        e2ePass = String(passArg.dropFirst("--e2e-pass=".count))
      }
      // Extract E2E PDS URL (optional, for custom domains)
      if let pdsArg = args.first(where: { $0.hasPrefix("--e2e-pds=") }) {
        e2ePdsURL = String(pdsArg.dropFirst("--e2e-pds=".count))
      }
      let runIdStr = self.e2eRunId ?? "unknown"
      let userStr = self.e2eUser ?? "none"
      let pdsStr = self.e2ePdsURL ?? "default"
      logger.info("[E2E] E2E mode detected, run_id=\(runIdStr), user=\(userStr), pds=\(pdsStr)")
    } else {
      logger.info("[E2E-DEBUG] E2E mode not detected (--e2e-mode not in args)")
    }
    
    Task { await MLSClient.shared.setStorageMaintenanceCoordinator(self) }
  }

  /// Initialize the app - check for saved session and transition to appropriate state
  func initialize() async {
    logger.info("🚀 Initializing AppStateManager")
    
    // Log E2E mode startup if enabled
    if isE2EMode, let runId = e2eRunId {
      MLSDiagnosticLogger.shared.logE2EModeStarted(runId: runId)
    }

    // E2E mode with credentials: prioritize fresh login over saved sessions
    // This ensures deterministic test behavior regardless of keychain state
    if isE2EMode, let user = e2eUser, let pass = e2ePass {
      logger.info("[E2E] E2E mode with credentials - performing fresh login for: \(user)")
      do {
        // Pass PDS URL if specified (for custom domains)
        let pdsURL = e2ePdsURL.flatMap { URL(string: $0) }
        try await authManager.loginWithPasswordForE2E(identifier: user, password: pass, pdsURL: pdsURL)
        if case .authenticated(let userDID) = authManager.state {
          logger.info("[E2E] Auto-login successful for: \(userDID)")
          await transitionToAuthenticated(userDID: userDID)
          MLSDiagnosticLogger.shared.logMLSReady(userDID: userDID)
        } else {
          logger.error("[E2E] Login completed but auth state is not authenticated")
          lifecycle = .unauthenticated
        }
      } catch {
        logger.error("[E2E] Auto-login failed: \(error)")
        lifecycle = .unauthenticated
      }
      
      startAuthStateObservationIfNeeded()
      return
    }

    // Normal mode: Initialize auth manager (checks for saved session, attempts token refresh)
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

    // Guard against re-entrancy - prevents duplicate calls from racing
    guard !isTransitioning else {
      logger.warning("⚠️ Already transitioning - skipping duplicate call for: \(userDID)")
      return
    }

    // Set transition flag to prevent operations during switch
    // Using defer ensures cleanup on ALL exit paths (normal return, early return, throw)
    isTransitioning = true
    defer { isTransitioning = false }

    let wasAuthenticated = lifecycle.userDID != nil
    
    // OOM FIX: Close the previous account's database BEFORE switching
    // This prevents the race condition where two databases are open simultaneously
    // with potential key mismatch or WAL corruption
    if let previousUserDID = lifecycle.userDID, previousUserDID != userDID {
      logger.info("🔒 Closing previous account's MLS database before switch: \(previousUserDID.prefix(20))")
      
      // Prepare the previous AppState for storage reset if it exists
      if let previousAppState = authenticatedStates[previousUserDID] {
        // FIX #5: Stop all streams and pause sync BEFORE database closure
        previousAppState.stopMLSStreams()

        // DEFENSIVE TIMEOUT: Wrap MLS shutdown in 5-second timeout
        let shutdownOk = await withTaskGroup(of: Bool.self) { group in
          group.addTask {
            await previousAppState.prepareMLSStorageReset()
            return true
          }
          group.addTask {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return false
          }
          let result = await group.next() ?? false
          group.cancelAll()
          return result
        }
        if !shutdownOk {
          logger.critical("🚨 [transitionToAuthenticated] MLS shutdown timed out - forcing ahead")
        }
      }
      
      // Ensure the database is fully closed and checkpointed
      let closeSuccess = await MLSGRDBManager.shared.closeDatabaseAndDrain(for: previousUserDID, timeout: 5.0)
      if !closeSuccess {
        logger.critical("🚨 Previous database drain failed - aborting account transition to prevent corruption")
        authManager.pendingAuthAlert = AuthenticationManager.AuthAlert(
          title: "Restart Required",
          message: "Catbird couldn’t safely close the encrypted database for the previous account. Please restart the app and try switching again."
        )
        return
      }
    }

    // CRITICAL: Switch AuthManager to the target account FIRST before getting client
    // This ensures we get the correct client for the account we're switching to
    do {
      logger.info("🔄 Switching AuthManager to account: \(userDID)")
      try await authManager.switchToAccount(did: userDID)
      logger.info("✅ AuthManager switched successfully")
    } catch {
      logger.error("❌ Failed to switch AuthManager: \(error.localizedDescription)")
      // If we were mid-account-switch, keep the current authenticated lifecycle instead of logging out.
      if !wasAuthenticated {
        lifecycle = .unauthenticated
      }
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
      // Reuse existing AppState
      logger.debug("♻️ Using existing AppState for: \(userDID)")
      appState = existing
      isCachedAccount = true
      updateAccessOrder(userDID)

      // CRITICAL FIX: Update client reference to ensure cached state uses current client
      // After account switching, AuthManager may have a new client instance. The cached
      // AppState must use this updated client, otherwise API calls will fail with stale tokens.
      logger.debug("♻️ Updating cached AppState client reference")
      appState.updateClient(client)

      // Ensure model context is set (might not be if AppState was created before container was ready)
      if let container = modelContainerState.container {
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
      
      // OOM FIX: Await eviction to ensure databases are properly closed before proceeding
      await evictLRUIfNeeded()
      
      // Initialize model context for draft persistence
      if let container = modelContainerState.container {
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
  /// - Parameter isManual: If true, this is a user-initiated logout (from Settings).
  ///   This prevents auto-triggering re-authentication on the login screen.
  func logout(isManual: Bool = true) async {
    logger.info("🚪 Logging out (isManual: \(isManual))")

    // Clear auth manager session - pass isManual to control re-auth behavior
    await authManager.logout(isManual: isManual)

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
    
    let previousUserDID = lifecycle.userDID

    // ═══════════════════════════════════════════════════════════════════════════
    // CRITICAL FIX: Signal account switch FIRST, before ANY other work
    // ═══════════════════════════════════════════════════════════════════════════
    // This tells the NSE to skip decryption for BOTH the old and new user during
    // the entire switch window. Without this, the NSE can race in and access
    // the database with the wrong encryption key, causing HMAC check failures.
    // ═══════════════════════════════════════════════════════════════════════════
    MLSAppActivityState.beginAccountSwitch(from: previousUserDID, to: userDID)
    MLSCoordinationStore.shared.updatePhase(.switching)
    MLSCoordinationStore.shared.incrementGeneration(for: userDID)
    if let previousUserDID = previousUserDID {
      MLSCoordinationStore.shared.incrementGeneration(for: previousUserDID)
    }
    
    // Ensure we clear the switch state even if we fail
    defer {
      MLSAppActivityState.endAccountSwitch()
      MLSCoordinationStore.shared.updatePhase(.active)
    }

    // Set transition flag to prevent operations during switch
    isTransitioning = true
    
    // CRITICAL FIX: Properly shutdown MLS resources for the OLD account BEFORE switching
    // This prevents:
    // 1. SQLite database exhaustion from unclosed connections
    // 2. Race conditions where old managers continue polling with wrong account
    // 3. Account mismatch errors in MLS sync operations
    // 4. HMAC check failures from using wrong encryption key
    if let oldUserDID = previousUserDID, oldUserDID != userDID {
      logger.info("MLS: 🛑 Preparing to shutdown MLS for previous user \(oldUserDID)")
      
      #if os(iOS)
        // Mark old user as under storage maintenance to block any new DB access.
        // Keep this flag set for the full duration of the switch (including transitionToAuthenticated).
        beginStorageMaintenance(for: oldUserDID)
        defer { endStorageMaintenance(for: oldUserDID) }
        
        // Get the old AppState and properly shutdown its MLS resources
        if let oldState = authenticatedStates[oldUserDID] {
          logger.info("MLS: Initiating graceful shutdown for previous account")

          // DEFENSIVE TIMEOUT: Wrap MLS shutdown in 5-second timeout to prevent account switch hangs
          // If prepareMLSStorageReset() never completes, we proceed anyway - better a degraded MLS
          // state than a frozen app. The user can restart if MLS is broken.
          let shutdownCompleted = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
              // FIX #5: Stop all streams and pause sync BEFORE database closure
              // This prevents new events from hitting the closing database
              self.logger.info("MLS: 🛑 Stopping all network streams for old account")
              oldState.stopMLSStreams()

              await oldState.prepareMLSStorageReset()
              return true
            }
            group.addTask {
              try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
              return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
          }

          if shutdownCompleted {
            logger.info("MLS: ✅ Previous account MLS shutdown complete")
          } else {
            logger.critical("🚨 MLS shutdown timed out after 5s - forcing ahead with account switch")
          }
        }
      #endif
      
      logger.info("MLS: SQLite storage for previous user \(oldUserDID) is automatically persisted")
    }

    // Store draft for transfer
    if let draft = draft {
      pendingComposerDraft = draft
      logger.info("📝 Stored composer draft for transfer - Text length: \(draft.postText.count)")
    }

    // CRITICAL: Clear isTransitioning BEFORE calling transitionToAuthenticated.
    // transitionToAuthenticated has a guard `!isTransitioning` that returns early if true.
    // The MLS shutdown work above is complete, so it's safe to clear the flag now.
    // transitionToAuthenticated will set its own isTransitioning flag with a defer to clear it.
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
  /// NOTE: This is now async to properly await database closure
  private func evictLRUIfNeeded() async {
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

      // OOM FIX: AWAIT database closure to prevent race conditions
      // Previously this was fire-and-forget which caused OOM errors during account switching
      await MLSGRDBManager.shared.closeDatabaseAndDrain(for: lruDID, timeout: 3.0)
      logger.debug("Closed MLS database for evicted account: \(lruDID)")
    }
  }
  
  /// Synchronous wrapper for evictLRUIfNeeded (for use in non-async contexts)
  /// Schedules the eviction but doesn't wait - use sparingly
  private func scheduleEvictLRUIfNeeded() {
    Task {
      await evictLRUIfNeeded()
    }
  }

  /// Manually clear all cached accounts except active
  /// NOTE: This is now async to properly await database closure
  func clearInactiveAccounts() async {
    let activeUserDID = lifecycle.userDID
    let inactiveAccounts = authenticatedStates.keys.filter { $0 != activeUserDID }

    for did in inactiveAccounts {
      // Cleanup tasks before removal
      if let appState = authenticatedStates[did] {
        appState.cleanup()
      }

      authenticatedStates.removeValue(forKey: did)
      accessOrder.removeAll { $0 == did }
    }
    
    // OOM FIX: Close all inactive databases in one call
    // This is more efficient and ensures proper serialization
    if let activeUserDID = activeUserDID {
      await MLSGRDBManager.shared.closeAllExcept(keepUserDID: activeUserDID)
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
  
  // MARK: - E2E Re-login
  
  /// Perform a fresh login for E2E mode when tokens have expired
  /// This is needed for PDSs with very short token lifetimes where refresh tokens also expire
  /// - Returns: true if re-login succeeded, false otherwise
  func e2eRelogin() async -> Bool {
    guard isE2EMode, let user = e2eUser, let pass = e2ePass else {
      logger.error("[E2E-RELOGIN] Not in E2E mode or missing credentials")
      return false
    }
    
    logger.info("[E2E-RELOGIN] Performing fresh login for: \(user) (token refresh only, no state transition)")
    do {
      let pdsURL = e2ePdsURL.flatMap { URL(string: $0) }
      try await authManager.loginWithPasswordForE2E(identifier: user, password: pass, pdsURL: pdsURL)
      
      if case .authenticated(let userDID) = authManager.state {
        logger.info("[E2E-RELOGIN] Re-login successful for: \(userDID)")
        
        // CRITICAL: Update the cached AppState's client with the fresh one from authManager
        // This ensures subsequent API calls use the new session tokens
        if let cachedAppState = authenticatedStates[userDID], let freshClient = authManager.client {
          cachedAppState.updateClient(freshClient)
          logger.info("[E2E-RELOGIN] Updated cached AppState with fresh client")
        }
        
        return true
      } else {
        logger.error("[E2E-RELOGIN] Re-login completed but auth state is not authenticated")
        return false
      }
    } catch {
      logger.error("[E2E-RELOGIN] Re-login failed: \(error)")
      return false
    }
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

extension AppStateManager: MLSStorageMaintenanceCoordinating {}
