import Foundation
import OSLog
import Petrel
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
enum AccountSwitchError: LocalizedError, Equatable {
  case invalidDID
  case authSwitchFailed(String)
  case clientUnavailable
  case transitionInProgress
  case authenticatedAccountMismatch
  case accountRestricted
  case recoveryFailed

  var errorDescription: String? {
    switch self {
    case .invalidDID:
      return "Couldn’t switch accounts. Try again."
    case .authSwitchFailed:
      // The underlying reason is logged where the switch fails.
      return "Couldn’t switch to this account. If this keeps happening, sign in to it again."
    case .clientUnavailable:
      return "Couldn’t switch accounts. Try again."
    case .transitionInProgress:
      return "Another account switch is already in progress. Try again in a moment."
    case .authenticatedAccountMismatch:
      return "Sign-in finished for a different account. Try again."
    case .accountRestricted:
      return "This account is deactivated or suspended, so it can’t post right now."
    case .recoveryFailed:
      return "Restart Catbird to finish switching accounts."
    }
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
  private(set) var lifecycle: AppLifecycle = .launching {
    didSet {
      if lifecycle.userDID != oldValue.userDID || lifecycle.isAuthenticated != oldValue.isAuthenticated {
        settingsAccountContextRevision &+= 1
      }
      if !composerSwitchQueue.isSwitching,
         !lifecycle.isAuthenticated || lifecycle.userDID != oldValue.userDID {
        composerSwitchQueue.invalidate()
      }
    }
  }

  #if DEBUG
  func setLifecycleForTesting(_ newLifecycle: AppLifecycle) {
    self.lifecycle = newLifecycle
  }
  #endif

  /// Observes auth state changes and keeps lifecycle in sync (e.g. session expiry → login/reauth)
  @ObservationIgnored
  private var authStateObservationTask: Task<Void, Never>? = nil

  /// Pool of authenticated AppState instances, keyed by user DID
  /// NO GUEST STATES - only authenticated accounts are cached
  private var authenticatedStates: [String: AppState] = [:]

  /// Fences Settings callbacks when an account leaves and later returns.
  private(set) var settingsAccountContextRevision: UInt64 = 0
  private let composerSwitchQueue = ComposerAccountSwitchQueue()
  private let accountSwitchOperationBarrier = AccountSwitchOperationBarrier()
  private var isLoggingOut = false
  private var accountSwitchRequiresRestart = false
  private var retiredComposerSwitchAttempts: Set<UUID> = []
  /// Preserve the source while the visible lifecycle is `.launching`, including logout races.
  private var admittedSwitchSource: (attemptID: UUID, state: AppState)?

  /// Observed by stable scene coordinators, including newly mounted account views.
  var pendingComposerReopenRevision: UInt64 { composerSwitchQueue.revision }

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

    // Test-harness launch arguments are compiled out of release builds.
    #if DEBUG
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
    #endif
  }

  /// Initialize the app - check for saved session and transition to appropriate state
  func initialize() async {
    logger.info("🚀 Initializing AppStateManager")

    #if os(iOS)
    if isE2EMode {
      UIView.setAnimationsEnabled(false)
    }
    #endif
    #if DEBUG
    if isE2EMode, ProcessInfo.processInfo.arguments.contains("--e2e-fixture-account") {
      let fixtureDID = "did:plc:alicee2efixture"
      let bobDID = "did:plc:bobe2efixture"
      let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
      authManager.setClientForTesting(client)
      authManager.storeHandle("alice.test", for: fixtureDID)
      authManager.storeHandle("bob.test", for: bobDID)
      authManager.cacheProfileData(for: fixtureDID, handle: "alice.test", displayName: "Alice", avatarURL: nil)
      authManager.cacheProfileData(for: bobDID, handle: "bob.test", displayName: "Bob", avatarURL: nil)
      authManager.updateAccountOrder([fixtureDID, bobDID])

      setAppStateFactoryForTesting { did, cli in
        let state = AppState(userDID: did, client: cli)
        let isBob = (did == bobDID)
        let author = AppBskyActorDefs.ProfileViewBasic(
          did: try! DID(didString: did),
          handle: try! Handle(handleString: isBob ? "bob.test" : "alice.test"),
          displayName: isBob ? "Bob" : "Alice",
          pronouns: nil,
          avatar: nil,
          associated: nil,
          viewer: nil,
          labels: nil,
          createdAt: nil,
          verification: nil,
          status: nil,
          debug: nil
        )
        let publicPostURI = try! ATProtocolURI(uriString: "at://\(did)/app.bsky.feed.post/publicpost1")
        let publicPost = AppBskyFeedDefs.PostView(
          uri: publicPostURI,
          cid: CID.fromDAGCBOR(Data("publicpost1-cid".utf8)),
          author: author,
          record: .knownType(
            AppBskyFeedPost(
              text: isBob ? "Hello public world from Bob" : "Hello public world from Alice",
              entities: nil,
              facets: nil,
              reply: nil,
              embed: nil,
              langs: [LanguageCodeContainer(languageCode: "en")],
              labels: nil,
              tags: nil,
              createdAt: ATProtocolDate(date: Date())
            )
          ),
          embed: nil,
          bookmarkCount: nil,
          replyCount: 0,
          repostCount: 0,
          likeCount: 0,
          quoteCount: nil,
          indexedAt: ATProtocolDate(date: Date()),
          viewer: nil,
          labels: nil,
          threadgate: nil,
          debug: nil
        )
        let publicFeedViewPost = AppBskyFeedDefs.FeedViewPost(post: publicPost, reply: nil, reason: nil, feedContext: nil, reqId: nil)
        if let cachedPublicPost = CachedFeedViewPost(feedViewPost: publicFeedViewPost) {
          let timelineModel = FeedModelContainer.shared.getModel(for: .timeline, appState: state)
          timelineModel.posts = [cachedPublicPost]
          let stateManager = FeedStateStore.shared.stateManager(for: .timeline, appState: state)
          Task { @MainActor in
            await stateManager.restorePersistedPosts([cachedPublicPost], cursor: nil)
          }
        }
        return state
      }

      AuthenticationManager.switchAccountOverride = { targetDID in
        if targetDID == fixtureDID {
          return (fixtureDID, "alice.test")
        } else if targetDID == bobDID {
          return (bobDID, "bob.test")
        } else {
          throw AuthError.invalidUserDID
        }
      }

      let appState = makeAppState(userDID: fixtureDID, client: client)
      authenticatedStates[fixtureDID] = appState
      updateAccessOrder(fixtureDID)
      authManager.updateState(.authenticated(userDID: fixtureDID))
      lifecycle = .authenticated(appState)
      startAuthStateObservationIfNeeded()
      await authManager.refreshAvailableAccounts()
      return
    }
    #endif

    #if DEBUG
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
          do {
            try await transitionToAuthenticated(userDID: userDID)
          } catch {
            logger.error("[E2E] Transition failed: \(error)")
            lifecycle = .unauthenticated
          }
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
    #endif

    // Normal mode: Initialize auth manager (checks for saved session, attempts token refresh)
    await authManager.initialize()

    // Check if we have an authenticated session
    if case .authenticated(let userDID) = authManager.state {
      logger.info("✅ Found authenticated session for: \(userDID)")
      do {
        try await transitionToAuthenticated(userDID: userDID)
      } catch {
        logger.error("Failed to transition to authenticated state: \(error.localizedDescription)")
        await recoverFromSwitchFailure()
      }
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
        // Explicit switches own authentication and recovery until their outcome is final.
        guard state == self.authManager.state,
              !self.isTransitioning,
              !self.isLoggingOut,
              !self.accountSwitchRequiresRestart,
              !self.composerSwitchQueue.isSwitching else { continue }
        switch state {
        case .authenticated(let userDID):
          guard self.lifecycle.userDID != userDID else { continue }
          self.logger.info("🔔 Auth became authenticated for: \(userDID) - transitioning")
          do {
            try await self.transitionToAuthenticated(userDID: userDID)
          } catch AccountSwitchError.transitionInProgress {
            continue
          } catch {
            self.logger.error("🔔 Failed to transition: \(error.localizedDescription)")
            await self.recoverFromSwitchFailure()
          }

        case .unauthenticated:
          guard self.lifecycle != .unauthenticated else { continue }
          self.logger.info("🔔 Auth became unauthenticated - transitioning")
          self.composerSwitchQueue.invalidate()
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

  private func normalizedUserDID(_ rawUserDID: String) -> String? {
    let userDID = rawUserDID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !userDID.isEmpty, userDID.hasPrefix("did:") else {
      return nil
    }
    return userDID
  }

  /// Transition to authenticated state with a specific user
  /// Creates or retrieves AppState for the user and updates lifecycle
  /// - Parameter userDID: The DID of the user to authenticate as
  func transitionToAuthenticated(
    userDID: String,
    previousUserDID: String? = nil,
    composerSwitchAttemptID: UUID? = nil
  ) async throws {
    guard !isTransitioning, !isLoggingOut else { throw AccountSwitchError.transitionInProgress }
    guard !accountSwitchRequiresRestart else { throw AccountSwitchError.recoveryFailed }
    try validateSwitchAttempt(composerSwitchAttemptID)
    try checkSwitchTaskCancellation(composerSwitchAttemptID)
    guard let userDID = normalizedUserDID(userDID) else {
      logger.critical(
        "🚨 Refusing authenticated transition for invalid DID: \(userDID, privacy: .private)")
      authManager.pendingAuthAlert = AuthenticationManager.AuthAlert(
        title: "Couldn’t Sign In",
        message:
          "Catbird couldn’t confirm which account you signed in to, so it stopped to keep your data safe. Try signing in again."
      )
      lifecycle = .unauthenticated
      throw AccountSwitchError.invalidDID
    }

    logger.info("🔐 Transitioning to authenticated state for: \(userDID)")

    // Set transition flag to prevent operations during switch
    // Using defer ensures cleanup on ALL exit paths (normal return, early return, throw)
    isTransitioning = true
    accountSwitchOperationBarrier.begin()
    defer {
      isTransitioning = false
      accountSwitchOperationBarrier.end()
    }

    let effectivePreviousDID = previousUserDID ?? lifecycle.userDID
    // Stop source polling before the shared client's account changes, preserving its editor/storage.
    if let previousDID = effectivePreviousDID, previousDID != userDID {
      try await authenticatedStates[previousDID]?.suspendForAccountSwitch()
      try validateSwitchAttempt(composerSwitchAttemptID)
      try checkSwitchTaskCancellation(composerSwitchAttemptID)
    }

    // CRITICAL: Switch AuthManager to the target account FIRST before getting client
    // This ensures we get the correct client for the account we're switching to
    do {
      logger.info("🔄 Switching AuthManager to account: \(userDID)")
      try await authManager.switchToAccount(did: userDID)
      logger.info("✅ AuthManager switched successfully")
    } catch {
      logger.error("❌ Failed to switch AuthManager: \(error.localizedDescription)")
      throw AccountSwitchError.authSwitchFailed(error.localizedDescription)
    }

    try validateSwitchAttempt(composerSwitchAttemptID)
    try checkSwitchTaskCancellation(composerSwitchAttemptID)
    guard case .authenticated(let authenticatedDID) = authManager.state,
          authenticatedDID == userDID else {
      throw AccountSwitchError.authenticatedAccountMismatch
    }

    // Now get the client for the target account
    guard let client = authManager.client else {
      logger.error("❌ Cannot transition to authenticated - no client available after switch")
      throw AccountSwitchError.clientUnavailable
    }
    let targetStatus = await readAccountStatus(client: client, userDID: userDID)
    try validateSwitchAttempt(composerSwitchAttemptID)
    try checkSwitchTaskCancellation(composerSwitchAttemptID)
    guard case .authenticated(let checkedDID) = authManager.state, checkedDID == userDID else {
      throw AccountSwitchError.authenticatedAccountMismatch
    }
    if targetStatus != .active {
      // A composer switch rolls back without ever publishing a restricted destination.
      if let previousDID = effectivePreviousDID, previousDID != userDID {
        throw AccountSwitchError.accountRestricted
      }
      let restrictedState = authenticatedStates[userDID] ?? makeAppState(userDID: userDID, client: client)
      authenticatedStates[userDID] = restrictedState
      setLifecycle(targetStatus == .deactivated ? .deactivated(restrictedState) : .takendown(restrictedState))
      throw AccountSwitchError.accountRestricted
    }
    try checkSwitchTaskCancellation(composerSwitchAttemptID)
    if let composerSwitchAttemptID,
       !composerSwitchQueue.beginCommit(id: composerSwitchAttemptID) { throw CancellationError() }
    if let previousDID = effectivePreviousDID, previousDID != userDID {
      // Once admitted, retirement settles independently of the requesting picker's cancellation.
      try await Task { @MainActor in
        try await self.retireAccountAfterVerifiedSwitch(
          previousDID, targetDID: userDID, composerSwitchAttemptID: composerSwitchAttemptID
        )
      }.value
      try validateSwitchAttempt(composerSwitchAttemptID)
      try checkSwitchTaskCancellation(composerSwitchAttemptID)
      guard case .authenticated(let retiredDID) = authManager.state, retiredDID == userDID else {
        throw AccountSwitchError.authenticatedAccountMismatch
      }
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
      appState = makeAppState(userDID: userDID, client: client)
      authenticatedStates[userDID] = appState
      isCachedAccount = false
      updateAccessOrder(userDID)

      evictLRUIfNeeded()

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

    var authenticatedStatePublished = false
    defer {
      if !authenticatedStatePublished, !isCachedAccount,
         authenticatedStates[userDID] === appState {
        appState.cleanup()
        authenticatedStates.removeValue(forKey: userDID)
        accessOrder.removeAll { $0 == userDID }
      }
    }

    setLifecycle(.authenticated(appState))
    authenticatedStatePublished = true
    accountSwitchRequiresRestart = false

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

    // Configure widget data provider with active account DID
    FeedWidgetDataProvider.shared.configure(accountDID: userDID)

    // Write account list to App Group for widget extension
    writeAccountsToAppGroup()

    logger.info("✅ Transitioned to authenticated state")
  }

  /// Log out the current user and transition to unauthenticated state
  /// - Parameter isManual: If true, this is a user-initiated logout (from Settings).
  ///   This prevents auto-triggering re-authentication on the login screen.
  func logout(isManual: Bool = true) async {
    guard !isLoggingOut else { return }
    isLoggingOut = true
    defer { isLoggingOut = false }
    logger.info("🚪 Logging out (isManual: \(isManual))")
    let interruptedSwitchSource = admittedSwitchSource?.state
    let loggingOutState = lifecycle.appState ?? interruptedSwitchSource
    let loggingOutDID = loggingOutState?.userDID
    composerSwitchQueue.invalidate()
    lifecycle = .unauthenticated
    // An older switch/rollback must settle before its retained source is retired.
    await accountSwitchOperationBarrier.waitUntilIdle()
    // Clear the outgoing account's app badge and push registration while its services still exist.
    await loggingOutState?.notificationManager.cleanupNotifications(previousClient: authManager.client)
    if let currentUserDID = loggingOutDID {
      if let currentState = loggingOutState ?? authenticatedStates[currentUserDID] {
        if currentState === interruptedSwitchSource {
          do {
            try await currentState.retireAfterAccountSwitch()
          } catch {
            logger.error("Could not retire the interrupted switch source during logout: \(error.localizedDescription)")
            accountSwitchRequiresRestart = true
          }
        } else {
          currentState.cleanup()
        }
      }
      authenticatedStates.removeValue(forKey: currentUserDID)
      accessOrder.removeAll { $0 == currentUserDID }
    }
    await authManager.logout(isManual: isManual)
    lifecycle = .unauthenticated

    // Update widget account list after logout
    writeAccountsToAppGroup()
    // Stop showing the signed-out account's posts in widgets and Spotlight
    if let loggingOutDID {
      FeedWidgetDataProvider.shared.clearWidgetData(for: loggingOutDID)
      await SpotlightEntityDonator.shared.removeAll()
    }

    logger.info("✅ Logged out successfully")
  }

  // MARK: - Account Restriction & Reactivation

  private enum AccountStatus: Equatable {
    case active
    case deactivated
    case takendown
  }

  /// This preflight performs no target AppState construction or service initialization.
  private func readAccountStatus(client: ATProtoClient?, userDID: String) async -> AccountStatus {
    guard let client else { return .active }
    do {
      let (code, session) = try await client.com.atproto.server.getSession()
      if code >= 200 && code < 300, let session {
        if session.active == false || session.status == "deactivated" {
          logger.warning("Account is deactivated for DID: \(userDID)")
          return .deactivated
        } else if session.status == "takendown" || session.status == "suspended" {
          logger.warning("Account is taken down for DID: \(userDID)")
          return .takendown
        }
      }
    } catch {
      logger.debug("Session check failed: \(error.localizedDescription)")
    }
    return .active
  }

  func checkAccountStatus(for appState: AppState) async -> AppLifecycle {
    switch await readAccountStatus(client: appState.atProtoClient, userDID: appState.userDID) {
    case .active: return .authenticated(appState)
    case .deactivated: return .deactivated(appState)
    case .takendown: return .takendown(appState)
    }
  }

  /// Attempts to reactivate a deactivated account and verifies confirmed active status
  func reactivateAccount(appState: AppState) async throws {
    guard let client = appState.atProtoClient else {
      throw GatewayPermissionError.clientUnavailable
    }

    guard !isTransitioning, !isLoggingOut, !composerSwitchQueue.isSwitching,
          !accountSwitchRequiresRestart else { throw AccountSwitchError.transitionInProgress }
    guard lifecycle.appState === appState,
          case .authenticated(let sourceDID) = authManager.state,
          sourceDID == appState.userDID,
          authManager.client === client else { throw AccountSwitchError.authenticatedAccountMismatch }
    // Reactivation owns source readiness until resume settles; logout waits for this operation.
    isTransitioning = true
    accountSwitchOperationBarrier.begin()
    defer {
      isTransitioning = false
      accountSwitchOperationBarrier.end()
    }

    // Call com.atproto.server.activateAccount
    let statusCode = try await client.com.atproto.server.activateAccount()
    guard statusCode >= 200 && statusCode < 300 else {
      throw NSError(
        domain: "blue.catbird.server",
        code: statusCode,
        userInfo: [
          NSLocalizedDescriptionKey: "Failed to reactivate account (server responded with code \(statusCode))."
        ]
      )
    }

    // Verify session status after activation - require 2xx, non-nil session with explicit active status and no restricted status
    let (getSessionCode, session) = try await client.com.atproto.server.getSession()
    guard getSessionCode >= 200 && getSessionCode < 300,
          let session = session,
          session.active == true,
          session.status == nil || session.status?.lowercased() == "active" else {
      let failureCode = (getSessionCode >= 200 && getSessionCode < 300) ? -1 : getSessionCode
      throw NSError(
        domain: "blue.catbird.server",
        code: failureCode,
        userInfo: [
          NSLocalizedDescriptionKey: "Account is not confirmed active after reactivation request."
        ]
      )
    }
    guard !isLoggingOut, lifecycle.appState === appState,
          case .authenticated(let verifiedDID) = authManager.state,
          verifiedDID == appState.userDID,
          authManager.client === client else { throw AccountSwitchError.authenticatedAccountMismatch }
    try await appState.resumeAfterInterruptedAccountSwitch(using: client)
    guard !isLoggingOut, lifecycle.appState === appState,
          case .authenticated(let resumedDID) = authManager.state,
          resumedDID == appState.userDID,
          authManager.client === client else { throw AccountSwitchError.authenticatedAccountMismatch }
    // Transition to active authenticated lifecycle only after its retained services resume.
    setLifecycle(.authenticated(appState))

    // Initialize the app state now that the account is active
    await appState.initialize()
  }

  /// Updates lifecycle state directly for testing or explicit restriction handling
  func setLifecycle(_ newLifecycle: AppLifecycle) {
    if #available(iOS 17.0, macOS 14.0, *) {
      withAnimation(.snappy(duration: 0.32, extraBounce: 0.0)) {
        self.lifecycle = newLifecycle
      }
    } else {
      withAnimation(.easeInOut(duration: 0.25)) {
        self.lifecycle = newLifecycle
      }
    }
  }

  // MARK: - Account Management

  private func retireAccountAfterVerifiedSwitch(
    _ previousDID: String, targetDID: String, composerSwitchAttemptID: UUID?
  ) async throws {
    accountSwitchRequiresRestart = true
    if let composerSwitchAttemptID { retiredComposerSwitchAttempts.insert(composerSwitchAttemptID) }
    guard let previousState = authenticatedStates[previousDID] else {
      throw AccountSwitchError.recoveryFailed
    }
    try await previousState.retireAfterAccountSwitch()
    authenticatedStates.removeValue(forKey: previousDID)
    accessOrder.removeAll { $0 == previousDID }
  }

  private func markAccountSwitchRestartRequired(
    message: String = "Catbird couldn’t finish switching accounts. Your draft is saved. Quit and reopen Catbird to continue."
  ) {
    accountSwitchRequiresRestart = true
    authManager.pendingAuthAlert = AuthenticationManager.AuthAlert(title: "Restart Required", message: message)
    lifecycle = .unauthenticated
  }

  /// Switch admission is synchronous, before lifecycle or pending handoffs change.
  @discardableResult
  func switchAccount(
    to userDID: String,
    composerTransfer: ComposerEditingSnapshot? = nil
  ) async -> AccountSwitchOutcome {
    guard !isTransitioning, !isLoggingOut, !composerSwitchQueue.isSwitching else { return .busy }
    guard !Task.isCancelled else { return .cancelled }
    guard !accountSwitchRequiresRestart else {
      return .failed("Restart Catbird before switching accounts again. Your draft has been preserved.")
    }
    guard let userDID = normalizedUserDID(userDID) else {
      return .failed(AccountSwitchError.invalidDID.localizedDescription)
    }

    guard SettingsAccountOperationGate.activeAccountDID == nil else { return .busy }

    let admission = composerSwitchQueue.begin(
      to: userDID,
      transfer: composerTransfer,
      authenticatedAccountDID: readyAuthenticatedAccountDID,
      isTransitioning: isTransitioning
    )
    guard case .accepted(let attempt) = admission else {
      if case .rejected(let outcome) = admission { return outcome }
      return .busy
    }
    defer { retiredComposerSwitchAttempts.remove(attempt.id) }
    let previousLifecycle = lifecycle
    if let source = previousLifecycle.appState {
      admittedSwitchSource = (attempt.id, source)
    }
    defer {
      if admittedSwitchSource?.attemptID == attempt.id { admittedSwitchSource = nil }
    }
    lifecycle = .launching

    do {
      let attemptID = attempt.id
      try await withTaskCancellationHandler {
        try await transitionToAuthenticated(
          userDID: userDID,
          previousUserDID: previousLifecycle.userDID,
          composerSwitchAttemptID: attemptID
        )
      } onCancel: {
        Task { @MainActor in self.composerSwitchQueue.requestCancellation(id: attemptID) }
      }
      try checkSwitchTaskCancellation(attempt.id)
      guard readyAuthenticatedAccountDID == userDID else {
        throw AccountSwitchError.authenticatedAccountMismatch
      }
      return composerSwitchQueue.finish(id: attempt.id, authenticatedAccountDID: userDID)
    } catch {
      logger.error("Failed to switch account: \(error.localizedDescription)")
      // Logout or explicit invalidation may revoke this attempt while authentication suspends.
      guard composerSwitchQueue.isCurrent(id: attempt.id) else { return .cancelled }
      if accountSwitchRequiresRestart || retiredComposerSwitchAttempts.contains(attempt.id) {
        markAccountSwitchRestartRequired()
        composerSwitchQueue.fail(id: attempt.id)
        return .failed("Catbird could not finish switching accounts safely. Restart the app; your draft has been preserved.")
      }
      // Recovery must finish even when the requesting picker task was cancelled.
      await Task { @MainActor in
        await self.recoverFromSwitchFailure(
          previousLifecycle: previousLifecycle, switchAttemptID: attempt.id
        )
      }.value
      guard composerSwitchQueue.isCurrent(id: attempt.id) else { return .cancelled }
      composerSwitchQueue.fail(id: attempt.id)
      if accountSwitchRequiresRestart {
        return .failed("Catbird could not restore the previous account safely. Restart the app; your draft has been preserved.")
      }
      if error is SettingsAccountSwitchError {
        return .blockedBySettings(error.localizedDescription)
      }
      return error is CancellationError ? .cancelled : .failed(error.localizedDescription)
    }
  }

  private var readyAuthenticatedAccountDID: String? {
    guard !isTransitioning,
          case .authenticated(let appState) = lifecycle,
          case .authenticated(let authDID) = authManager.state,
          appState.userDID == authDID else { return nil }
    return authDID
  }

  private func validateSwitchAttempt(_ id: UUID?) throws {
    guard !isLoggingOut else { throw CancellationError() }
    if let id, !composerSwitchQueue.canContinue(id: id) { throw CancellationError() }
  }

  private func checkSwitchTaskCancellation(_ id: UUID?) throws {
    if let id, composerSwitchQueue.hasBegunCommit(id: id) { return }
    try Task.checkCancellation()
  }

  private func recoverFromSwitchFailure(
    previousLifecycle: AppLifecycle? = nil,
    switchAttemptID: UUID? = nil
  ) async {
    guard !isLoggingOut else { return }
    guard !accountSwitchRequiresRestart else {
      markAccountSwitchRestartRequired()
      return
    }
    if let switchAttemptID, !composerSwitchQueue.isCurrent(id: switchAttemptID) { return }
    accountSwitchOperationBarrier.begin()
    defer { accountSwitchOperationBarrier.end() }
    if let previousLifecycle, let previousState = previousLifecycle.appState {
      if authManager.state.userDID != previousState.userDID {
        do {
          try await authManager.switchToAccount(did: previousState.userDID)
        } catch {
          logger.error("Could not restore the previous account: \(error.localizedDescription)")
        }
      }
      if let switchAttemptID, !composerSwitchQueue.isCurrent(id: switchAttemptID) { return }
      if case .authenticated(let authDID) = authManager.state,
         authDID == previousState.userDID,
         let client = authManager.client,
         previousState.atProtoClient === client {
        previousState.isTransitioningAccounts = false
        authenticatedStates[authDID] = previousState
        updateAccessOrder(authDID)
        // Restricted source accounts retain their interstitial and cannot resume normal services.
        lifecycle = previousLifecycle
        if previousLifecycle.isAuthenticated {
          do {
            try await previousState.resumeAfterInterruptedAccountSwitch(using: client)
          } catch {
            markAccountSwitchRestartRequired(
              message: "Catbird could not safely resume the previous account's services. Your draft has been preserved. Restart the app to continue."
            )
          }
        }
        return
      }
      markAccountSwitchRestartRequired(
        message: "Catbird could not restore the original account after the switch failed. Your draft has been preserved. Restart the app to continue."
      )
      return
    }

    if case let .authenticated(authDID) = authManager.state, let client = authManager.client {
      // Do not turn a restricted session into an unrestricted one during recovery.
      if lifecycle.isRestricted, lifecycle.userDID == authDID { return }
      authenticatedStates.removeValue(forKey: authDID)
      let newAppState = makeAppState(userDID: authDID, client: client)
      if let container = modelContainerState.container {
        newAppState.composerDraftManager.setModelContext(container.mainContext)
        newAppState.notificationManager.setModelContext(container.mainContext)
      }
      authenticatedStates[authDID] = newAppState
      updateAccessOrder(authDID)
      lifecycle = .authenticated(newAppState)
    } else {
      lifecycle = .unauthenticated
    }
  }

  func pendingComposerReopen(sourceSceneID: UUID, accountDID: String) -> PendingComposerReopen? {
    composerSwitchQueue.pendingReopen(
      sourceSceneID: sourceSceneID,
      accountDID: accountDID,
      authenticatedAccountDID: readyAuthenticatedAccountDID
    )
  }

  func claimComposerReopen(
    id: UUID, sourceSceneID: UUID, accountDID: String
  ) -> PendingComposerReopen? {
    composerSwitchQueue.claim(
      id: id,
      sourceSceneID: sourceSceneID,
      accountDID: accountDID,
      authenticatedAccountDID: readyAuthenticatedAccountDID
    )
  }

  /// Remove a specific account's cached state
  /// - Parameter userDID: The DID of the account to remove
  func removeAccount(_ userDID: String) async throws {
    logger.info("🗑️ Removing account state: \(userDID)")

    if let appState = authenticatedStates[userDID] {
      appState.cleanup()
    }

    authenticatedStates.removeValue(forKey: userDID)
    accessOrder.removeAll { $0 == userDID }

    // Update widget account list after removal
    writeAccountsToAppGroup()
    // Stop showing the removed account's posts in widgets and Spotlight
    FeedWidgetDataProvider.shared.clearWidgetData(for: userDID)
    await SpotlightEntityDonator.shared.removeAll()
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

  /// All DIDs that have cached authenticated state
  var authenticatedDIDs: [String] {
    return Array(authenticatedStates.keys)
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
    }
  }

  /// Manually clear all cached accounts except active
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

    logger.info("🗑️ Cleared \(inactiveAccounts.count) inactive account(s)")
  }

  // MARK: - Public Accessors

  /// Access the authentication manager (for login flows, account management)
  var authentication: AuthenticationManager {
    authManager
  }

  // MARK: - E2E Re-login

  #if DEBUG
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
  #endif

  // MARK: - Widget Data

  /// Write current account list to App Group for widget extension
  private func writeAccountsToAppGroup() {
    let defaults = UserDefaults(suiteName: "group.blue.catbird.shared")

    struct WidgetAccountDTO: Codable {
      let did: String
      let handle: String
      let displayName: String
      let avatarURL: String?
    }

    let accounts = authManager.availableAccounts.map { info in
      WidgetAccountDTO(
        did: info.did,
        handle: info.cachedHandle ?? info.handle ?? info.did,
        displayName: info.cachedDisplayName ?? info.cachedHandle ?? info.handle ?? info.did,
        avatarURL: info.cachedAvatarURL?.absoluteString
      )
    }

    if let data = try? JSONEncoder().encode(accounts) {
      defaults?.set(data, forKey: "widgetAccounts")
    }

    // Published for the Notification Service Extension: it matches the
    // `recipient_account` push-payload hash against these DIDs to target the
    // right account on notification tap.
    defaults?.set(accounts.map { $0.did }, forKey: "knownAccountDIDs")

    if let activeDID = lifecycle.userDID {
      defaults?.set(activeDID, forKey: "activeAccountDID")
    } else {
      defaults?.removeObject(forKey: "activeAccountDID")
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

#if DEBUG
  @ObservationIgnored
  private var appStateFactoryForTesting: (@MainActor (String, ATProtoClient) -> AppState)?

  func setAppStateFactoryForTesting(_ factory: (@MainActor (String, ATProtoClient) -> AppState)?) {
    self.appStateFactoryForTesting = factory
  }
#endif

  @MainActor
  private func makeAppState(userDID: String, client: ATProtoClient) -> AppState {
    #if DEBUG
    if let factory = appStateFactoryForTesting {
      return factory(userDID, client)
    }
    #endif
    return AppState(userDID: userDID, client: client)
  }
}
