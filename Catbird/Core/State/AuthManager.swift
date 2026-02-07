import CatbirdMLSCore
import CatbirdMLSService
import Foundation
import LocalAuthentication
import OSLog
import Petrel
import SwiftUI

/// Represents the current state of authentication
enum AuthState: Equatable {
  case initializing
  case unauthenticated
  case authenticating(progress: AuthProgress)
  case authenticated(userDID: String)
  case error(message: String)

  /// Helper computed property to easily check if authenticated
  var isAuthenticated: Bool {
    if case .authenticated = self {
      return true
    }
    return false
  }

  /// Helper computed property to check if currently authenticating
  var isAuthenticating: Bool {
    if case .authenticating = self {
      return true
    }
    return false
  }

  /// Get the user DID if available
  var userDID: String? {
    if case .authenticated(let did) = self {
      return did
    }
    return nil
  }

  // Basic error description
  var errorMessage: String? {
    if case .error(let message) = self {
      return message
    }
    return nil
  }

  /// Get the current authentication progress if authenticating
  var authProgress: AuthProgress? {
    if case .authenticating(let progress) = self {
      return progress
    }
    return nil
  }
}

/// Detailed authentication progress states
enum AuthProgress: Equatable, Sendable {
  case initializingClient
  case resolvingHandle(handle: String)
  case fetchingMetadata(url: String)
  case generatingAuthURL
  case openingBrowser
  case waitingForCallback
  case exchangingTokens
  case creatingSession
  case finalizing
  case retrying(step: String, attempt: Int, maxAttempts: Int)

  /// User-friendly description of the current progress
  var userDescription: String {
    switch self {
    case .initializingClient:
      return "Initializing authentication client"
    case .resolvingHandle(let handle):
      return "Resolving handle \(handle)"
    case .fetchingMetadata(let url):
      let domain = URL(string: url)?.host ?? url
      return "Connecting to \(domain)"
    case .generatingAuthURL:
      return "Preparing authentication"
    case .openingBrowser:
      return "Opening browser for secure login"
    case .waitingForCallback:
      return "Waiting for authentication"
    case .exchangingTokens:
      return "Processing authentication"
    case .creatingSession:
      return "Creating secure session"
    case .finalizing:
      return "Finalizing login"
    case .retrying(let step, let attempt, let maxAttempts):
      return "Retrying \(step) (attempt \(attempt)/\(maxAttempts))"
    }
  }

  /// Technical description for debugging
  var technicalDescription: String {
    switch self {
    case .initializingClient:
      return "Creating ATProtoClient instance"
    case .resolvingHandle(let handle):
      return "Resolving \(handle) to DID via .well-known/atproto_did"
    case .fetchingMetadata(let url):
      return "Fetching OAuth metadata from \(url)"
    case .generatingAuthURL:
      return "Generating PKCE parameters and authorization URL"
    case .openingBrowser:
      return "Launching ASWebAuthenticationSession"
    case .waitingForCallback:
      return "Waiting for OAuth callback with authorization code"
    case .exchangingTokens:
      return "Exchanging authorization code for access tokens"
    case .creatingSession:
      return "Creating authenticated session and storing tokens"
    case .finalizing:
      return "Completing authentication setup"
    case .retrying(let step, let attempt, let maxAttempts):
      return "Retrying failed step: \(step) (attempt \(attempt) of \(maxAttempts))"
    }
  }
}

/// Handles all authentication-related operations with a clean state machine approach
@Observable
final class AuthenticationManager: AuthProgressDelegate {
  // MARK: - Properties

  private let logger = Logger(subsystem: "blue.catbird", category: "Authentication")

  // Authentication timeout configuration
  private let authenticationTimeout: TimeInterval = 60.0  // 60 seconds
  private let networkTimeout: TimeInterval = 30.0  // 30 seconds for individual network calls

  // Current authentication state - the source of truth
  private(set) var state: AuthState = .initializing

  // Handle storage for multi-account support
  private let handleStorageKey = "catbird_account_handles"
  private let accountOrderKey = "catbird_account_order"

  // State change handling with async streams
  @ObservationIgnored
  private let stateSubject = AsyncStream<AuthState>.makeStream()

  // The ATProtoClient used for authentication and API calls
  private(set) var client: ATProtoClient?

  // Track current authentication task for cancellation
  @ObservationIgnored
  private var currentAuthTask: Task<Void, Never>?

  // Flag to indicate if authentication was cancelled by user
  @ObservationIgnored
  private var isAuthenticationCancelled = false

  // User information
  private(set) var handle: String?

  // Alert to surface critical auth transitions (e.g., auto-logout)
  struct AuthAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
  }
  var pendingAuthAlert: AuthAlert?

  // Available accounts
  var availableAccounts: [AccountInfo] = []
  var isSwitchingAccount = false

  // Track expired account for automatic re-authentication
  private(set) var expiredAccountInfo: AccountInfo?

  /// True when we can present the account switcher instead of forcing the login flow.
  var hasRegisteredAccounts: Bool {
    if !availableAccounts.isEmpty {
      return true
    }

    return !getStoredHandles().isEmpty
  }

  // Biometric authentication
  private(set) var biometricAuthEnabled = false
  private(set) var biometricType: LABiometryType = .none
  private(set) var lastBiometricError: LAError?

  // OAuth configuration
  private let oauthConfig = OAuthConfiguration(
    clientId: "https://catbird.blue/oauth-client-metadata.json",
    redirectUri: "https://catbird.blue/oauth/callback",
    scope: "atproto transition:generic transition:chat.bsky"
  )

  // MARK: - Debounce Flag for Auth Expiration

  /// Prevents multiple simultaneous auth expiration handlers from triggering.
  /// When true, additional calls to handleAutoLogoutFromPetrel are ignored until
  /// re-authentication completes or is cancelled.
  private var isHandlingAuthExpiration = false

  /// Fast-fail flag set immediately on 401 detection to short-circuit pending requests.
  /// This prevents "401 storms" where hundreds of requests fail before transitioning to login.
  /// Network clients can check this flag to fast-fail rather than making doomed requests.
  private(set) var isAuthInvalid: Bool = false

  // Service DID configuration - can be customized before authentication
  var customAppViewDID: String = "did:web:api.bsky.app#bsky_appview"
  var customChatDID: String = "did:web:api.bsky.chat#bsky_chat"

  // MARK: - Timeout Utility

  /// Executes an async operation with a timeout, throwing TimeoutError if exceeded
  private func withTimeout<T>(
    timeout: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask {
        try await operation()
      }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        throw AuthError.timeout
      }
      defer { group.cancelAll() }
      return try await group.next()!
    }
  }

  // MARK: - Initialization

  init() {
    logger.debug("AuthenticationManager initialized")

    // Configure biometric authentication asynchronously off the main actor
    Task.detached(priority: .background) { [weak self] in
      guard let self else { return }
      await self.configureBiometricAuthentication()
    }
  }

  // MARK: - State Management

  /// Access state changes as an AsyncSequence
  var stateChanges: AsyncStream<AuthState> {
    return stateSubject.stream
  }

  // MARK: - Auto-logout handling from Petrel

  /// Called when Petrel detects a terminal auth failure (e.g., invalid_grant) and performs a logout.
  @MainActor
  func handleAutoLogoutFromPetrel(did: String?, reason: String?) async {
    // FAST PATH: Set invalid flag IMMEDIATELY to short-circuit pending requests
    // This prevents "401 storms" where hundreds of requests fail before transitioning to login
    isAuthInvalid = true

    // DEBOUNCE: If we're already handling an auth expiration, skip duplicate triggers.
    // This prevents the "death spiral" where dozens of parallel network requests all
    // fail and each tries to trigger logout simultaneously.
    if isHandlingAuthExpiration {
      logger.warning(
        "Already handling auth expiration, skipping duplicate trigger (reason: \(reason ?? "nil"))")
      return
    }

    logger.error("Auto logout from Petrel: did=\(did ?? "nil") reason=\(reason ?? "nil")")

    // Mark that we're handling an expiration to block further triggers
    isHandlingAuthExpiration = true

    if let did {
      let storedHandle = getStoredHandle(for: did)
      expiredAccountInfo = AccountInfo(did: did, handle: storedHandle, isActive: false)
      logger.info(
        "Stored expired account info for automatic re-authentication: \(storedHandle ?? did)")
    }

    Task {
      if case .authenticated(let appState) = AppStateManager.shared.lifecycle {
        await appState.notificationManager.cleanupNotifications(previousClient: client)
      }
    }

    // Clear handle if this was the active account (check before state change)
    let wasActiveAccount =
      if let did, case .authenticated(let current) = state {
        current == did
      } else {
        false
      }

    updateState(.unauthenticated)

    client = nil

    if wasActiveAccount {
      handle = nil
    }

    updateAvailableAccountsFromStoredHandles(activeDID: nil)

    // CRITICAL: Do NOT set pendingAuthAlert if we have expiredAccountInfo.
    // We want ContentView to auto-trigger the browser flow immediately.
    // Setting an alert here blocks the ASWebAuthenticationSession from presenting.
    if expiredAccountInfo == nil {
      let reasonText: String = {
        switch (reason ?? "").lowercased() {
        case "invalid_grant":
          return "Your session expired or was revoked. Please sign in again."
        case "invalid_token":
          return "Your session token is no longer valid. Please sign in again."
        default:
          return reason.map { "Signed out: \($0). Please sign in again." }
            ?? "You were signed out. Please sign in again."
        }
      }()
      pendingAuthAlert = AuthAlert(title: "Signed Out", message: reasonText)
    } else {
      // Clear any existing alert so it doesn't block the sheet
      pendingAuthAlert = nil
      logger.info("Skipping alert - expiredAccountInfo is set, will auto-trigger re-auth flow")
    }
  }

  @MainActor
  func clearPendingAuthAlert() {
    pendingAuthAlert = nil
  }

  /// Clear expired account info
  @MainActor
  func clearExpiredAccountInfo() {
    expiredAccountInfo = nil
    isHandlingAuthExpiration = false  // Reset debounce flag when user dismisses/cancels
  }

  /// Start OAuth flow for the expired account (if available)
  @MainActor
  func startOAuthFlowForExpiredAccount() async throws -> URL? {
    guard let expiredAccount = expiredAccountInfo,
      let handle = expiredAccount.handle
    else {
      logger.warning("No expired account information available for automatic re-authentication")
      return nil
    }

    logger.info("Starting OAuth flow for expired account: \(handle)")
    return try await login(handle: handle)
  }

  /// Update the authentication state and emit the change
  /// NOTE: State emission is synchronous to prevent race conditions between state property
  /// update and observer notification. Wrapping in Task created timing gaps that caused
  /// double state transitions on OAuth login.
  @MainActor
  private func updateState(_ newState: AuthState) {
    guard newState != state else { return }
    logger.debug(
      "Updating auth state: \(String(describing: self.state)) -> \(String(describing: newState))")
    self.state = newState
    // Emit synchronously - no Task wrapper to eliminate race windows
    stateSubject.continuation.yield(newState)
  }

  /// Validate a DID coming from user input or client session state.
  private func validatedUserDID(_ rawDID: String, source: String) throws -> String {
    let did = rawDID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !did.isEmpty, did.hasPrefix("did:") else {
      logger.critical("🚨 [\(source)] Invalid DID encountered: '\(rawDID, privacy: .private)'")
      throw AuthError.invalidUserDID
    }
    return did
  }

  // MARK: - Public API

  /// Initialize the client and check authentication state
  @MainActor
  func initialize() async {
    logger.info("Initializing authentication system")
    isAuthenticationCancelled = false
    updateState(.initializing)

    if client == nil {
      logger.info("ATTEMPTING to create ATProtoClient...")
      updateState(.authenticating(progress: .initializingClient))
      logger.debug(">>> Calling await ATProtoClient(...) off main actor")

      #if targetEnvironment(simulator)
        let accessGroup: String? = nil
      #else
        let accessGroup: String? = MLSKeychainManager.resolvedAccessGroup(
          suffix: "blue.catbird.shared")
      #endif

      // Create client off main actor to avoid blocking UI (50-80ms operation)
      let oauthCfg = self.oauthConfig
      let appViewDID = self.customAppViewDID
      let chatDID = self.customChatDID

      let newClient = await Task.detached(priority: .userInitiated) {
        try? await ATProtoClient(
          oauthConfig: oauthCfg,
          namespace: "blue.catbird",
          authMode: .gateway,
          gatewayURL: URL(string: "https://api.catbird.blue")!,
          userAgent: "Catbird/1.0",
          bskyAppViewDID: appViewDID,
          bskyChatDID: chatDID,
          accessGroup: accessGroup
        )
      }.value

      // Update state on main actor
      client = newClient
      await client?.applicationDidBecomeActive()

      if client == nil {
        logger.critical("❌❌❌ FAILED to create ATProtoClient ❌❌❌")
        updateState(.error(message: "Failed to initialize client"))
        return
      } else {
        logger.info("✅✅✅ ATProtoClient CREATED SUCCESSFULLY ✅✅✅")
        await client?.setAuthProgressDelegate(self)
        await client?.setFailureDelegate(self)
        if let client = client { await client.setAuthenticationDelegate(self) }
      }

    } else {
      logger.info(
        "ATProtoClient already exists, updating service DIDs to: bskyAppViewDID=\(self.customAppViewDID), bskyChatDID=\(self.customChatDID)"
      )
      await client?.updateServiceDIDs(bskyAppViewDID: customAppViewDID, bskyChatDID: customChatDID)
    }

    logger.debug(
      "Client state before checkAuthenticationState: \(self.client == nil ? "NIL" : "Exists")")
    await checkAuthenticationState()
  }

  /// Check the current authentication state with enhanced token refresh
  @MainActor
  func checkAuthenticationState() async {
    guard !isAuthenticationCancelled else {
      logger.debug("Skipping auth state check - authentication was cancelled by user")
      return
    }
    guard let client = client else {
      updateState(.unauthenticated)
      return
    }

    logger.debug("Checking authentication state")

//    if await client.hasValidSession() {
//      let refreshSuccess = await refreshTokenWithRetry(client: client)
//      if !refreshSuccess {
//        logger.warning("Token refresh failed after retries; will verify session validity next")
//      }
//    }

    let hasValidSession = await client.hasValidSession()

    if hasValidSession {
      do {
        // Parallelize independent async calls for faster authentication
        async let didTask = client.getDid()
        async let handleTask = client.getHandle()

        let (resolvedDid, userHandle) = try await (didTask, handleTask)
        let userDid = try validatedUserDID(resolvedDid, source: "checkAuthenticationState")

        self.handle = userHandle
        logger.info("User is authenticated with DID: \(String(describing: userDid))")

        if let handle = self.handle {
          storeHandle(handle, for: userDid)
        }

        await MainActor.run {
          updateState(.authenticated(userDID: userDid))
          logger.info("Auth state updated to authenticated via proper channels")
          logger.info("Current state after update: \(String(describing: self.state))")
        }
      } catch {
        logger.error("Error fetching user identity: \(error.localizedDescription)")
        if !isAuthenticationCancelled {
          updateState(.unauthenticated)
        }
      }
    } else {
      logger.info("No valid session found")

      // If we know which account likely expired, prime re-auth so LoginView auto-starts OAuth.
      if expiredAccountInfo == nil {  // don’t overwrite if already set (e.g., auto-logout path)
        await prepareExpiredAccountInfoForReauth(using: client)
      }

      if !isAuthenticationCancelled {
        updateState(.unauthenticated)
      }
    }
  }

  /// Enhanced token refresh with retry logic and exponential backoff
  @MainActor
  private func refreshTokenWithRetry(client: ATProtoClient) async -> Bool {
    let maxRetries = 3
    var lastError: Error?

    for attempt in 1...maxRetries {
      do {
        logger.debug("Token refresh attempt \(attempt) of \(maxRetries)")
        let success = try await client.refreshToken()
        if success {
          logger.info("Token refresh successful on attempt \(attempt)")
          return true
        } else {
          logger.warning("Token refresh returned false on attempt \(attempt)")
          lastError = AuthError.invalidSession
        }
      } catch {
        lastError = error
        logger.warning("Token refresh attempt \(attempt) failed: \(error.localizedDescription)")

        if let nsError = error as NSError? {
          if nsError.code == 401 || nsError.code == 403 {
            logger.info(
              "Authentication error detected (\(nsError.code)); not retrying token refresh")
            // Mark the current account as expired to route UI to re-auth.
            await markCurrentAccountExpiredForReauth(
              client: client, reason: "unauthorized_\(nsError.code)")
            break
          }
          if nsError.domain == NSURLErrorDomain
            && [
              NSURLErrorTimedOut,
              NSURLErrorCannotConnectToHost,
              NSURLErrorNetworkConnectionLost,
            ].contains(nsError.code)
          {
            if attempt < maxRetries {
              logger.info("Network error during token refresh, retrying in \(attempt) seconds...")
              try? await Task.sleep(nanoseconds: UInt64(attempt * 1_000_000_000))
              continue
            }
          }
        }
        if attempt == maxRetries {
          break
        }
        try? await Task.sleep(nanoseconds: UInt64(attempt * 1_000_000_000))
      }
    }

    if let error = lastError {
      logger.error(
        "Token refresh failed after \(maxRetries) attempts: \(error.localizedDescription)")
      // If we didn’t already tag an expired account above, try once more here
      if expiredAccountInfo == nil {
        await markCurrentAccountExpiredForReauth(client: client, reason: "refresh_failed")
      }
    }
    return false
  }

  // MARK: - Expired-session helpers

  /// If there’s a single plausible account or an active DID, set expiredAccountInfo so LoginView can auto-reauth.
  @MainActor
  private func prepareExpiredAccountInfoForReauth(using client: ATProtoClient) async {
    // Strategy: Determine the most likely account that needs re-authentication.
    // Order of preference:
    // 1. Currently active AppState user (if in-memory)
    // 2. The client's current account (the account the client was initialized with)
    // 3. The first account in the persistent specific account order (most recently used/sorted)
    // 4. Any single available account from client list
    // 5. Any single available account from stored handles

    var candidateDID: String? = nil

    // 1. Check currently active lifecycle user
    if let activeUserDID = AppStateManager.shared.lifecycle.userDID, !activeUserDID.isEmpty {
      candidateDID = activeUserDID
      logger.info("Found active lifecycle user DID for re-auth: \(activeUserDID)")
    }

    // 2. Check the client's current account (this is the account that needs reauth, not just the first in order)
    if candidateDID == nil {
      if let currentAccount = await client.getCurrentAccount() {
        candidateDID = currentAccount.did
        logger.info("Found current account from client for re-auth: \(currentAccount.did)")
      }
    }

    // 3. Check persistent account order (first item is naturally the best candidate if no active user)
    if candidateDID == nil {
      let order = getAccountOrder()
      if let firstDID = order.first, !firstDID.isEmpty {
        candidateDID = firstDID
        logger.info("Found most recent account from storage order for re-auth: \(firstDID)")
      }
    }

    // 4. Fallback: Ask client for its current DID (though likely nil if session expired)
    if candidateDID == nil {
      if let did = try? await client.getDid() {
        candidateDID = did
        logger.info("Found DID from client session: \(did)")
      }
    }

    // 5. Fallback: Single account check
    if candidateDID == nil {
      let accounts = await client.listAccounts()
      if accounts.count == 1 {
        candidateDID = accounts.first?.did
        logger.info("Found single account from client list: \(candidateDID!)")
      } else if accounts.isEmpty {
        // Last resort: stored handles
        let stored = getStoredHandles()
        if stored.count == 1 {
          candidateDID = stored.keys.first
          logger.info("Found single account from stored handles: \(candidateDID!)")
        }
      }
    }

    guard let did = candidateDID else {
      logger.warning("Could not determine a candidate account for automatic re-authentication.")
      return
    }

    let storedHandle = getStoredHandle(for: did)
    expiredAccountInfo = AccountInfo(did: did, handle: storedHandle, isActive: false)
    logger.info(
      "Prepared expiredAccountInfo for DID=\(did) handle=\(storedHandle ?? "nil") to trigger re-auth"
    )

    // Keep the account list fresh for Account Switcher fallback
    await refreshAvailableAccounts()
  }

  /// Marks the current account as expired (when we can resolve DID) to drive re-auth UI.
  @MainActor
  private func markCurrentAccountExpiredForReauth(client: ATProtoClient, reason: String?) async {
    // Do not clobber if already set via auto-logout log bridge
    guard expiredAccountInfo == nil else { return }

    let did = (try? await client.getDid()) ?? ""
    guard !did.isEmpty else {
      // Prefer the currently-active lifecycle DID if Petrel can no longer resolve identity.
      if let activeDID = AppStateManager.shared.lifecycle.userDID, !activeDID.isEmpty {
        let storedHandle = getStoredHandle(for: activeDID)
        expiredAccountInfo = AccountInfo(did: activeDID, handle: storedHandle, isActive: false)
        logger.warning(
          "Session expired for DID=\(activeDID); reason=\(reason ?? "unknown"). Prompting re-auth (lifecycle fallback)."
        )
        return
      }

      // Fallback: try to infer a plausible account from locally-stored accounts/handles.
      await prepareExpiredAccountInfoForReauth(using: client)
      return
    }

    let storedHandle = getStoredHandle(for: did)
    expiredAccountInfo = AccountInfo(did: did, handle: storedHandle, isActive: false)
    logger.warning(
      "Session expired for DID=\(did); reason=\(reason ?? "unknown"). Prompting re-auth.")
  }

  /// Start the OAuth authentication flow with improved error handling
  @MainActor
  func login(handle: String) async throws -> URL {
    logger.info("Starting OAuth flow for handle: \(handle)")

    currentAuthTask?.cancel()
    currentAuthTask = nil

    isAuthenticationCancelled = false
    updateState(.authenticating(progress: .resolvingHandle(handle: handle)))

    if client == nil {
      logger.info("Client not found, initializing for login")

      #if targetEnvironment(simulator)
        let accessGroup: String? = nil
      #else
        let accessGroup: String? = MLSKeychainManager.resolvedAccessGroup(
          suffix: "blue.catbird.shared")
      #endif

      client = try? await ATProtoClient(
        oauthConfig: oauthConfig,
        namespace: "blue.catbird",
        authMode: .gateway,
        gatewayURL: URL(string: "https://api.catbird.blue")!,
        userAgent: "Catbird/1.0",
        bskyAppViewDID: customAppViewDID,
        bskyChatDID: customChatDID,
        accessGroup: accessGroup
      )
      await client?.applicationDidBecomeActive()
      await client?.setAuthProgressDelegate(self)
      await client?.setFailureDelegate(self)
      if let client = client { await client.setAuthenticationDelegate(self) }

    } else {
      logger.info(
        "Client exists, updating service DIDs to: bskyAppViewDID=\(self.customAppViewDID), bskyChatDID=\(self.customChatDID)"
      )
      await client?.updateServiceDIDs(bskyAppViewDID: customAppViewDID, bskyChatDID: customChatDID)
    }

    guard let client = client else {
      let error = AuthError.clientNotInitialized
      updateState(.error(message: error.localizedDescription))
      throw error
    }

    do {
      var lastError: Error?
      let maxRetries = 3

      for attempt in 1...maxRetries {
        try Task.checkCancellation()
        do {
          self.logger.debug("OAuth flow attempt \(attempt) of \(maxRetries)")

          if attempt > 1 {
            await self.updateState(
              .authenticating(
                progress: .retrying(step: "OAuth setup", attempt: attempt, maxAttempts: maxRetries))
            )
          } else {
            await self.updateState(.authenticating(progress: .generatingAuthURL))
          }

          let authURL = try await withTimeout(timeout: networkTimeout) {
            // Pass custom service DIDs to OAuth flow
            try await client.startOAuthFlow(
              identifier: handle,
              bskyAppViewDID: self.customAppViewDID,
              bskyChatDID: self.customChatDID
            )
          }

          logger.info("OAuth URL generated successfully: \(authURL.absoluteString)")
          await self.updateState(.authenticating(progress: .openingBrowser))
          return authURL
        } catch {
          lastError = error
          self.logger.warning("OAuth flow attempt \(attempt) failed: \(error.localizedDescription)")

          if let nsError = error as NSError? {
            if nsError.domain == NSURLErrorDomain
              && [
                NSURLErrorTimedOut,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
              ].contains(nsError.code)
            {
              if attempt < maxRetries {
                self.logger.info("Retrying OAuth flow after network error in \(attempt) seconds...")
                try? await Task.sleep(nanoseconds: UInt64(attempt * 1_000_000_000))
                continue
              }
            } else if nsError.code == 401 || nsError.code == 403 {
              break
            }
          }
          if attempt == maxRetries {
            break
          }
          try? await Task.sleep(nanoseconds: UInt64(attempt * 1_000_000_000))
        }
      }

      let finalError = lastError ?? AuthError.unknown(NSError(domain: "OAuth", code: -1))
      throw finalError
    } catch {
      let finalError: AuthError
      if error is CancellationError {
        finalError = AuthError.cancelled
      } else if case AuthError.timeout = error {
        finalError = AuthError.timeout
      } else if let authError = error as? AuthError {
        finalError = authError
      } else {
        finalError = AuthError.unknown(error)
      }

      logger.error("OAuth flow failed: \(finalError.localizedDescription)")
      updateState(.error(message: finalError.localizedDescription))
      throw finalError
    }
  }

  // MARK: - E2E Testing Support
  
  /// Login with username/password for E2E testing only
  /// This bypasses OAuth and uses direct password authentication (legacy mode)
  /// - Parameters:
  ///   - identifier: Username or handle
  ///   - password: Password or app password
  ///   - pdsURL: Optional PDS URL for custom domains (bypasses handle resolution)
  @MainActor
  func loginWithPasswordForE2E(identifier: String, password: String, pdsURL: URL? = nil) async throws {
    logger.info("[E2E] Starting password login for: \(identifier), pds: \(pdsURL?.absoluteString ?? "default")")
    
    updateState(.authenticating(progress: .initializingClient))
    
    // For E2E password login, we need a legacy-mode client (not gateway)
    #if targetEnvironment(simulator)
      let accessGroup: String? = nil
    #else
      let accessGroup: String? = MLSKeychainManager.resolvedAccessGroup(
        suffix: "blue.catbird.shared")
    #endif
    
    // CRITICAL: Clear any existing E2E namespace keychain data to ensure fresh login
    // This prevents stale sessions from interfering with E2E tests
    // TEMPORARY: Using logger.error for E2E debugging (logs otherwise filtered)
    logger.error("[E2E-DEBUG] Clearing E2E keychain namespace before fresh login")
    clearE2EKeychainData(accessGroup: accessGroup)
    
    // Create a separate legacy-mode client for password auth
    // If PDS URL is specified, use it directly as the base URL
    let baseURL = pdsURL ?? URL(string: "https://bsky.social")!
    logger.error("[E2E-DEBUG] Creating ATProtoClient with baseURL: \(baseURL.absoluteString)")
    logger.error("[E2E-DEBUG] authMode: legacy, namespace: blue.catbird.e2e")
    
    let legacyClient: ATProtoClient
    do {
      legacyClient = try await ATProtoClient(
        baseURL: baseURL,
        oauthConfig: oauthConfig,
        namespace: "blue.catbird.e2e",
        authMode: .legacy,  // Use legacy mode for password auth
        userAgent: "Catbird/1.0-E2E",
        bskyAppViewDID: customAppViewDID,
        bskyChatDID: customChatDID,
        accessGroup: accessGroup
      )
      logger.error("[E2E-DEBUG] ATProtoClient created successfully")
    } catch {
      logger.error("[E2E] Failed to create ATProtoClient: \(error)")
      throw error
    }
    
    do {
      updateState(.authenticating(progress: .creatingSession))
      logger.error("[E2E-DEBUG] Calling loginWithPassword for: \(identifier)")
      
      logger.error("[E2E-DEBUG] About to call loginWithPassword...")
      let accountInfo = try await legacyClient.loginWithPassword(
        identifier: identifier,
        password: password,
        bskyAppViewDID: customAppViewDID,
        bskyChatDID: customChatDID
      )
      logger.error("[E2E-DEBUG] loginWithPassword SUCCESS, DID: \(accountInfo.did)")
      
      let did = try validatedUserDID(accountInfo.did, source: "loginWithPasswordForE2E")
      logger.info("[E2E] Password login successful for DID: \(did)")

      // Replace the main client with the authenticated legacy client
      client = legacyClient
      await client?.applicationDidBecomeActive()
      await client?.setAuthProgressDelegate(self)
      await client?.setFailureDelegate(self)
      await client?.setAuthenticationDelegate(self)

      // Store handle
      handle = accountInfo.handle
      storeHandle(accountInfo.handle ?? identifier, for: did)

      // Reset auth flags on successful login
      isAuthInvalid = false
      isHandlingAuthExpiration = false

      updateState(.authenticated(userDID: did))
      
    } catch {
      // Log detailed error info
      let nsError = error as NSError
      logger.error("[E2E] Password login failed: \(error)")
      logger.error("[E2E] Error domain: \(nsError.domain), code: \(nsError.code)")
      if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
        logger.error("[E2E] Underlying error: \(underlying)")
      }
      updateState(.error(message: error.localizedDescription))
      throw error
    }
  }
  
  /// Clear E2E keychain namespace data to ensure fresh login
  /// This removes any stored sessions, tokens, and DPoP keys for the E2E namespace
  private func clearE2EKeychainData(accessGroup: String?) {
    let e2eNamespace = "blue.catbird.e2e"
    
    // Query to find all items that start with the E2E namespace
    // The keychain stores items with kSecAttrAccount = "namespace.key"
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecMatchLimit as String: kSecMatchLimitAll,
      kSecReturnAttributes as String: true
    ]
    
    if let group = accessGroup {
      query[kSecAttrAccessGroup as String] = group
    }
    
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    
    if status == errSecSuccess, let items = result as? [[String: Any]] {
      for item in items {
        if let account = item[kSecAttrAccount as String] as? String,
           account.hasPrefix("\(e2eNamespace).") {
          // Delete this item
          var deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
          ]
          if let group = accessGroup {
            deleteQuery[kSecAttrAccessGroup as String] = group
          }
          let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
          if deleteStatus == errSecSuccess {
            logger.info("[E2E] Deleted keychain item: \(account)")
          }
        }
      }
    } else if status == errSecItemNotFound {
      logger.info("[E2E] No keychain items to clear")
    } else {
      logger.warning("[E2E] Failed to query keychain: \(status)")
    }
  }

  /// Handle the OAuth callback after web authentication with timeout support
  @MainActor
  func handleCallback(_ url: URL) async throws {
    logger.info("🔗 [CALLBACK] Processing OAuth callback: \(url.absoluteString)")
    logger.debug("🔗 [CALLBACK] URL scheme: \(url.scheme ?? "none"), host: \(url.host ?? "none")")
    logger.debug("🔗 [CALLBACK] Current state: \(String(describing: self.state))")
    updateState(.authenticating(progress: .exchangingTokens))

    if case .authenticating = state {
      logger.debug("✅ [CALLBACK] State is .authenticating as expected")
    } else {
      logger.warning(
        "⚠️ [CALLBACK] Received callback in unexpected state: \(String(describing: self.state))")
    }

    guard let client = client else {
      logger.error("❌ [CALLBACK] Client not available")
      let error = AuthError.clientNotInitialized
      updateState(.error(message: error.localizedDescription))
      throw error
    }
    logger.debug("✅ [CALLBACK] Client is available")

    do {
      logger.debug("🔄 [CALLBACK] Starting OAuth callback processing with timeout")
      try await withTimeout(timeout: networkTimeout) {
        try Task.checkCancellation()

        self.logger.debug("🔄 [CALLBACK] Calling client.handleOAuthCallback")
        try await client.handleOAuthCallback(url: url)
        self.logger.info("✅ [CALLBACK] client.handleOAuthCallback completed")

        // DEBUG: Test API call immediately after OAuth callback
        self.logger.info("🔍 [DEBUG] Testing API call RIGHT after handleOAuthCallback...")
        do {
          let did = try await client.getDid()
          let atId = try ATIdentifier(string: did)
          let params = AppBskyActorGetProfile.Parameters(actor: atId)
          let result = try await client.app.bsky.actor.getProfile(input: params)
          self.logger.info(
            "🔍 [DEBUG] Immediate API call SUCCESS: \(result.data?.handle.description ?? "no handle")"
          )
        } catch {
          self.logger.error("🔍 [DEBUG] Immediate API call FAILED: \(error)")
        }

        await self.updateState(.authenticating(progress: .creatingSession))

        self.logger.debug("🔄 [CALLBACK] Checking if session is valid")
        let hasValidSession = await client.hasValidSession()
        if !hasValidSession {
          self.logger.error("❌ [CALLBACK] Session invalid after OAuth callback processing")
          throw AuthError.invalidSession
        }
        self.logger.debug("✅ [CALLBACK] Session is valid")

        await self.updateState(.authenticating(progress: .finalizing))

        self.logger.debug("🔄 [CALLBACK] Getting DID from client")
        let did = try self.validatedUserDID(
          try await client.getDid(),
          source: "handleOAuthCallback"
        )
        self.logger.debug("✅ [CALLBACK] Got DID: \(did)")

        self.logger.debug("🔄 [CALLBACK] Getting handle from client")
        self.handle = try await client.getHandle()
        self.logger.debug("✅ [CALLBACK] Got handle: \(self.handle ?? "nil")")

        if let handle = self.handle {
          self.storeHandle(handle, for: did)
        }

        await client.clearTemporaryAccountStorage()

        self.isAuthenticationCancelled = false
        self.isHandlingAuthExpiration = false  // Reset debounce flag on successful auth
        self.isAuthInvalid = false  // Reset fast-fail flag on successful auth
        self.expiredAccountInfo = nil
        await self.updateState(.authenticated(userDID: did))
      }

      // Get DID after timeout block completes
      let did = try validatedUserDID(
        try await client.getDid(),
        source: "handleOAuthCallback.postValidation"
      )

      // DEBUG: Test a simple API call to verify gateway connectivity
      logger.info("🔍 [DEBUG] Testing API call after auth...")
      do {
        let atId = try ATIdentifier(string: did)
        let params = AppBskyActorGetProfile.Parameters(actor: atId)
        let result = try await client.app.bsky.actor.getProfile(input: params)
        logger.info(
          "🔍 [DEBUG] API call succeeded! Got profile for: \(result.data?.handle.description ?? "no handle")"
        )
      } catch {
        logger.error("🔍 [DEBUG] API call FAILED: \(error)")
      }

      // NOTE: AppState transition is handled by AppStateManager's auth state observation
      // when it observes .authenticated state. No explicit switchAccount call needed here.

      self.logger.info("Authentication successful for user \(self.handle ?? "unknown")")
    } catch {
      let finalError: AuthError
      if error is CancellationError {
        finalError = AuthError.cancelled
      } else if case AuthError.timeout = error {
        finalError = AuthError.timeout
      } else if let authError = error as? AuthError {
        finalError = authError
      } else {
        finalError = AuthError.unknown(error)
      }

      logger.error("OAuth callback processing failed: \(finalError.localizedDescription)")
      updateState(.error(message: finalError.localizedDescription))
      throw finalError
    }
  }

  /// Handle OAuth callback from gateway BFF (session_id in URL fragment)
  /// The gateway redirects to: https://catbird.blue/oauth/callback#session_id=<uuid>
  @MainActor
  func handleGatewayCallback(_ url: URL) async throws {
    logger.info("🔗 [GATEWAY] Processing gateway callback: \(url.absoluteString)")
    updateState(.authenticating(progress: .exchangingTokens))

    // Ensure client exists (cold start scenario)
    if client == nil {
      logger.info("Client not found, initializing for gateway callback")
      await initialize()

      guard client != nil else {
        logger.error("❌ [GATEWAY] Failed to initialize client")
        let error = AuthError.clientNotInitialized
        updateState(.error(message: error.localizedDescription))
        throw error
      }
    }

    // Parse session_id from URL fragment
    guard let fragment = url.fragment,
      let sessionId = parseGatewaySessionId(from: fragment)
    else {
      logger.error("❌ [GATEWAY] Invalid callback URL - missing session_id in fragment")
      let error = AuthError.invalidCallbackURL
      updateState(.error(message: error.localizedDescription))
      throw error
    }

    logger.debug("✅ [GATEWAY] Parsed session_id from fragment")

    do {
      updateState(.authenticating(progress: .creatingSession))

      // Delegate to Petrel's gateway callback handler (which fetches /auth/session)
      guard let activeClient = client else {
        throw AuthError.clientNotInitialized
      }
      try await activeClient.handleOAuthCallback(url: url)

      updateState(.authenticating(progress: .finalizing))

      // Get account info from client after OAuth callback
      let accountInfo = await activeClient.getActiveAccountInfo()
      guard let resolvedUserDID = accountInfo.did else {
        throw AuthError.unknown(NSError(domain: "AuthManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No account info after OAuth callback"]))
      }
      let userDID = try validatedUserDID(
        resolvedUserDID,
        source: "handleGatewayCallback"
      )

      self.handle = accountInfo.handle
      if let handle = self.handle {
        storeHandle(handle, for: userDID)
      }

      isAuthenticationCancelled = false
      isHandlingAuthExpiration = false
      isAuthInvalid = false  // Reset fast-fail flag on successful auth
      expiredAccountInfo = nil

      updateState(.authenticated(userDID: userDID))

      // NOTE: AppState transition is handled by AppStateManager's auth state observation
      // when it observes .authenticated state. No explicit switchAccount call needed here.

      logger.info("✅ [GATEWAY] Authentication successful for user \(self.handle ?? "unknown")")
    } catch {
      let finalError: AuthError
      if let authError = error as? AuthError {
        finalError = authError
      } else {
        finalError = AuthError.unknown(error)
      }

      logger.error("❌ [GATEWAY] Callback processing failed: \(finalError.localizedDescription)")
      updateState(.error(message: finalError.localizedDescription))
      throw finalError
    }
  }

  /// Parse session_id from URL fragment (e.g., "session_id=abc123&foo=bar")
  private func parseGatewaySessionId(from fragment: String) -> String? {
    let pairs = fragment.split(separator: "&").map { $0.split(separator: "=", maxSplits: 1) }
    for pair in pairs where pair.count == 2 && pair[0] == "session_id" {
      return String(pair[1])
    }
    return nil
  }

  /// Logout the current user
  /// - Parameter isManual: If true, this is a user-initiated logout and we should clear expiredAccountInfo
  ///   to prevent auto-triggering re-authentication. If false (auto-logout), preserve expiredAccountInfo
  ///   to enable seamless re-auth flow.
  @MainActor
  func logout(isManual: Bool = false) async {
    logger.info("Logging out user (isManual: \(isManual))")

    isAuthenticationCancelled = false
    updateState(.unauthenticated)

    // Cleanup notifications before logging out
    Task {
      if case .authenticated(let appState) = AppStateManager.shared.lifecycle {
        await appState.notificationManager.cleanupNotifications(previousClient: client)
      }
    }

    // Note: AppStateManager calls this method, so we don't call back to avoid infinite loop

    if let client = client {
      do {
        try await client.logout()
        logger.info("Logout successful")
      } catch {
        logger.error("Error during logout: \(error.localizedDescription)")
      }
    }

    self.client = nil
    handle = nil
    
    // For manual (user-initiated) logout, clear expiredAccountInfo to prevent
    // LoginView from auto-triggering re-authentication with prefilled credentials.
    // For auto-logout (session expiry), preserve expiredAccountInfo to enable
    // seamless re-authentication flow.
    if isManual {
      expiredAccountInfo = nil
      isHandlingAuthExpiration = false
      pendingAuthAlert = nil
      logger.info("Manual logout: cleared expiredAccountInfo and pendingAuthAlert to prevent auto-reauth")
    }
    // NOTE: For auto-logout, do NOT clear expiredAccountInfo here!
    // When auto-logout occurs via handleAutoLogoutFromPetrel, expiredAccountInfo is set
    // to enable automatic re-authentication. Clearing it here would break that flow.
    // expiredAccountInfo is cleared only on:
    // 1. Successful re-authentication (handleCallback)
    // 2. User explicitly dismisses the expired account error (LoginView X button)
    // 3. User cancels re-authentication (LoginView cancel)

    updateAvailableAccountsFromStoredHandles(activeDID: nil)
  }

  /// Reset after an error or cancellation
  @MainActor
  func resetError() {
    currentAuthTask?.cancel()
    currentAuthTask = nil

    if let client = client {
      Task {
        await client.cancelOAuthFlow()
      }
    }

    isAuthenticationCancelled = true
    isHandlingAuthExpiration = false  // Reset debounce flag so future failures can trigger

    if case .error = state {
      updateState(.unauthenticated)
    } else if case .authenticating = state {
      updateState(.unauthenticated)
    }
  }

  // MARK: - Account Management

  /// Account information struct
  struct AccountInfo: Identifiable, Equatable {
    let did: String
    let handle: String?
    var isActive: Bool = false
    var cachedHandle: String?
    var cachedDisplayName: String?
    var cachedAvatarURL: URL?

    var id: String { did }

    static func == (lhs: AccountInfo, rhs: AccountInfo) -> Bool {
      lhs.did == rhs.did
    }
  }

  // MARK: - Handle Storage

  /// Store handle for a specific DID
  private func storeHandle(_ handle: String, for did: String) {
    var handles = getStoredHandles()
    handles[did] = handle

    if let data = try? JSONEncoder().encode(handles) {
      UserDefaults.standard.set(data, forKey: handleStorageKey)
    }
  }

  /// Get stored handle for a specific DID
  private func getStoredHandle(for did: String) -> String? {
    let handles = getStoredHandles()
    return handles[did]
  }

  /// Get all stored handles
  private func getStoredHandles() -> [String: String] {
    guard let data = UserDefaults.standard.data(forKey: handleStorageKey),
      let handles = try? JSONDecoder().decode([String: String].self, from: data)
    else {
      return [:]
    }
    return handles
  }

  /// Remove stored handle for a specific DID
  private func removeStoredHandle(for did: String) {
    var handles = getStoredHandles()
    handles.removeValue(forKey: did)

    if let data = try? JSONEncoder().encode(handles) {
      UserDefaults.standard.set(data, forKey: handleStorageKey)
    }

    // Also remove from account order
    var order = getAccountOrder()
    order.removeAll { $0 == did }
    saveAccountOrder(order)
  }

  /// Get stored account order (array of DIDs)
  private func getAccountOrder() -> [String] {
    guard let data = UserDefaults.standard.data(forKey: accountOrderKey),
      let order = try? JSONDecoder().decode([String].self, from: data)
    else {
      return []
    }
    return order
  }

  /// Save account order
  private func saveAccountOrder(_ order: [String]) {
    if let data = try? JSONEncoder().encode(order) {
      UserDefaults.standard.set(data, forKey: accountOrderKey)
    }
  }

  /// Update account order (called from UI when user reorders)
  @MainActor
  func updateAccountOrder(_ orderedDIDs: [String]) {
    logger.info("Updating account order with \(orderedDIDs.count) accounts")
    saveAccountOrder(orderedDIDs)
  }

  /// Cache profile data for an account to avoid showing DID during switches
  @MainActor
  func cacheProfileData(for did: String, handle: String?, displayName: String?, avatarURL: URL?) {
    let key = "cached_profile_\(did)"
    let profileData: [String: String?] = [
      "handle": handle,
      "displayName": displayName,
      "avatarURL": avatarURL?.absoluteString,
    ]

    if let data = try? JSONEncoder().encode(profileData) {
      UserDefaults.standard.set(data, forKey: key)
      logger.debug("Cached profile data for DID: \(did)")
    }
  }

  /// Get cached profile data for an account
  nonisolated func getCachedProfileData(for did: String) -> (
    handle: String?, displayName: String?, avatarURL: URL?
  )? {
    let key = "cached_profile_\(did)"
    guard let data = UserDefaults.standard.data(forKey: key),
      let profileData = try? JSONDecoder().decode([String: String?].self, from: data)
    else {
      return nil
    }

    let avatarURL: URL? =
      if let urlString = profileData["avatarURL"] as? String {
        URL(string: urlString)
      } else {
        nil
      }

    return (
      handle: profileData["handle"] as? String,
      displayName: profileData["displayName"] as? String,
      avatarURL: avatarURL
    )
  }

  /// Remove an account completely (including stored handle)
  @MainActor
  func removeAccount(did: String) async {
    logger.info("Removing account: \(did)")

    removeStoredHandle(for: did)

    if let client = client {
      do {
        try await client.removeAccount(did: did)
        logger.info("Account removed successfully")
      } catch {
        logger.error("Error removing account: \(error.localizedDescription)")
      }
    }

    await refreshAvailableAccounts()
  }

  /// Get list of all available accounts
  @MainActor
  func refreshAvailableAccounts() async {
    await ensureClientInitializedForAccountOperations()

    let currentDID: String?
    if case .authenticated(let did) = state {
      currentDID = did
    } else {
      currentDID = nil
    }

    guard let client = client else {
      updateAvailableAccountsFromStoredHandles(activeDID: currentDID)
      return
    }

    let accounts = await client.listAccounts()
    logger.info("Found \(accounts.count) available accounts")

    var accountInfos: [AccountInfo] = []
    accountInfos.reserveCapacity(accounts.count)

    for account in accounts {
      var handle: String?

      if account.did == currentDID {
        handle = try? await client.getHandle()
        if let handle {
          storeHandle(handle, for: account.did)
        }
      } else {
        handle = getStoredHandle(for: account.did)
      }

      let cachedProfile = getCachedProfileData(for: account.did)
      accountInfos.append(
        AccountInfo(
          did: account.did,
          handle: handle,
          isActive: account.did == currentDID,
          cachedHandle: cachedProfile?.handle,
          cachedDisplayName: cachedProfile?.displayName,
          cachedAvatarURL: cachedProfile?.avatarURL
        )
      )
    }

    let storedHandles = getStoredHandles()
    for (storedDID, storedHandle) in storedHandles
    where !accountInfos.contains(where: { $0.did == storedDID }) {
      let cachedProfile = getCachedProfileData(for: storedDID)
      accountInfos.append(
        AccountInfo(
          did: storedDID,
          handle: storedHandle,
          isActive: storedDID == currentDID,
          cachedHandle: cachedProfile?.handle,
          cachedDisplayName: cachedProfile?.displayName,
          cachedAvatarURL: cachedProfile?.avatarURL
        )
      )
    }

    // Apply custom ordering if available
    let savedOrder = getAccountOrder()
    if !savedOrder.isEmpty {
      // Sort by saved order, with unordered accounts at the end (alphabetically)
      availableAccounts = accountInfos.sorted { lhs, rhs in
        let lhsIndex = savedOrder.firstIndex(of: lhs.did)
        let rhsIndex = savedOrder.firstIndex(of: rhs.did)

        switch (lhsIndex, rhsIndex) {
        case (.some(let lIdx), .some(let rIdx)):
          return lIdx < rIdx
        case (.some, .none):
          return true
        case (.none, .some):
          return false
        case (.none, .none):
          let lhsHandle = lhs.handle ?? lhs.did
          let rhsHandle = rhs.handle ?? rhs.did
          return lhsHandle.localizedCaseInsensitiveCompare(rhsHandle) == .orderedAscending
        }
      }
    } else {
      // No custom order, sort alphabetically
      availableAccounts = accountInfos.sorted { lhs, rhs in
        let lhsHandle = lhs.handle ?? lhs.did
        let rhsHandle = rhs.handle ?? rhs.did
        return lhsHandle.localizedCaseInsensitiveCompare(rhsHandle) == .orderedAscending
      }
    }
  }

  @MainActor
  private func ensureClientInitializedForAccountOperations() async {
    guard client == nil else { return }

    logger.info("Recreating ATProtoClient for account operations")

    #if targetEnvironment(simulator)
      let accessGroup: String? = nil
    #else
      let accessGroup: String? = MLSKeychainManager.resolvedAccessGroup(
        suffix: "blue.catbird.shared")
    #endif

    client = try? await ATProtoClient(
      oauthConfig: oauthConfig,
      namespace: "blue.catbird",
      authMode: .gateway,
      gatewayURL: URL(string: "https://api.catbird.blue")!,
      userAgent: "Catbird/1.0",
      bskyAppViewDID: customAppViewDID,
      bskyChatDID: customChatDID,
      accessGroup: accessGroup
    )

    await client?.applicationDidBecomeActive()
    await client?.setAuthProgressDelegate(self)
    await client?.setFailureDelegate(self)
    if let client = client { await client.setAuthenticationDelegate(self) }
  }

  /// Update the available accounts list from locally stored handles when the client is unavailable.
  private func updateAvailableAccountsFromStoredHandles(activeDID: String?) {
    let storedHandles = getStoredHandles()

    guard !storedHandles.isEmpty else {
      availableAccounts = []
      return
    }

    let infos = storedHandles.map { did, handle in
      let cachedProfile = getCachedProfileData(for: did)
      return AccountInfo(
        did: did,
        handle: handle,
        isActive: did == activeDID,
        cachedHandle: cachedProfile?.handle,
        cachedDisplayName: cachedProfile?.displayName,
        cachedAvatarURL: cachedProfile?.avatarURL
      )
    }

    // Apply custom ordering if available
    let savedOrder = getAccountOrder()
    if !savedOrder.isEmpty {
      availableAccounts = infos.sorted { lhs, rhs in
        let lhsIndex = savedOrder.firstIndex(of: lhs.did)
        let rhsIndex = savedOrder.firstIndex(of: rhs.did)

        switch (lhsIndex, rhsIndex) {
        case (.some(let lIdx), .some(let rIdx)):
          return lIdx < rIdx
        case (.some, .none):
          return true
        case (.none, .some):
          return false
        case (.none, .none):
          let lhsHandle = lhs.handle ?? lhs.did
          let rhsHandle = rhs.handle ?? rhs.did
          return lhsHandle.localizedCaseInsensitiveCompare(rhsHandle) == .orderedAscending
        }
      }
    } else {
      availableAccounts = infos.sorted { lhs, rhs in
        let lhsHandle = lhs.handle ?? lhs.did
        let rhsHandle = rhs.handle ?? rhs.did
        return lhsHandle.localizedCaseInsensitiveCompare(rhsHandle) == .orderedAscending
      }
    }
  }

  /// Switch to a different account
  @MainActor
  func switchToAccount(did: String) async throws {
    let targetDID = try validatedUserDID(did, source: "switchToAccount.request")

    logger.info("🔄 [AUTHMAN-SWITCH] Starting switchToAccount for DID: \(targetDID)")
    logger.debug("🔄 [AUTHMAN-SWITCH] Current state: \(String(describing: self.state))")

    // ═══════════════════════════════════════════════════════════════════════════
    // CRITICAL FIX (2024-12): Prevent re-entrancy during account switching
    // ═══════════════════════════════════════════════════════════════════════════
    //
    // Problem: Rapid account switching causes "death spiral":
    // 1. Switch A → B starts, opens B's database
    // 2. User taps switch B → C before A→B completes
    // 3. A's database still closing, B's opening, C's requested
    // 4. WAL files get corrupted, "SQLite error 7: out of memory"
    //
    // Solution: Guard against re-entrancy and wait for previous switch to complete
    //
    // ═══════════════════════════════════════════════════════════════════════════
    guard !isSwitchingAccount else {
      logger.warning("⚠️ [AUTHMAN-SWITCH] Account switch already in progress - ignoring request")
      logger.warning("   Requested DID: \(targetDID)")
      throw AuthError.accountSwitchInProgress
    }

    logger.debug("🔄 [AUTHMAN-SWITCH] Ensuring client initialized...")
    await ensureClientInitializedForAccountOperations()

    guard let client = client else {
      logger.error(
        "❌ [AUTHMAN-SWITCH] Client not initialized after ensureClientInitializedForAccountOperations"
      )
      throw AuthError.clientNotInitialized
    }
    logger.debug("✅ [AUTHMAN-SWITCH] Client is available")

    if case .authenticated(let currentDid) = state, currentDid == targetDID {
      logger.info("ℹ️ [AUTHMAN-SWITCH] Already using account with DID: \(targetDID)")
      return
    }

    logger.info("🔄 [AUTHMAN-SWITCH] Proceeding with account switch to DID: \(targetDID)")
    logger.debug("🔄 [AUTHMAN-SWITCH] Setting isSwitchingAccount = true")
    isSwitchingAccount = true

    // ═══════════════════════════════════════════════════════════════════════════
    // CRITICAL FIX (2024-12): Close current user's MLS databases before switching
    // ═══════════════════════════════════════════════════════════════════════════
    //
    // BOTH databases must be properly closed and checkpointed BEFORE opening
    // the new user's database:
    //
    // 1. **MLS FFI Context (Rust layer)** - Contains OpenMLS cryptographic state
    //    - Secret tree, epoch keys, ratchet state
    //    - Uses its own SQLite database (via rusqlite)
    //    - If not flushed: SecretReuseError on reload (ratchet advanced but not persisted)
    //
    // 2. **MLSGRDBManager (Swift layer)** - Contains message cache and metadata
    //    - Decrypted plaintexts, conversation records
    //    - Uses GRDB/SQLCipher
    //    - If not checkpointed: WAL grows unbounded, "SQLite error 7"
    //
    // Without proper closing of BOTH:
    // - WAL files grow unbounded (no checkpoint)
    // - File descriptors exhausted ("SQLite error 7")
    // - HMAC verification fails (reading wrong user's WAL)
    // - SecretReuseError (MLS ratchet advanced in memory but not persisted)
    //
    // ═══════════════════════════════════════════════════════════════════════════
    if case .authenticated(let currentDid) = state {
      // ═══════════════════════════════════════════════════════════════════════════
      // Use MLSShutdownCoordinator for proper shutdown sequence
      // ═══════════════════════════════════════════════════════════════════════════
      // The coordinator enforces the correct order:
      // 1. Close FFI context (flush Rust ratchet state)
      // 2. Checkpoint WAL (flush Swift database writes)
      // 3. Close Swift DB (close GRDB pool)
      // 4. Sleep 200ms (let OS reclaim mlocked memory)
      //
      // This prevents SQLite error 21, SecretReuseError, and HMAC check failures.
      // ═══════════════════════════════════════════════════════════════════════════

      logger.info("🔄 [AUTHMAN-SWITCH] Using MLSShutdownCoordinator for proper close sequence...")

      // DEFENSIVE TIMEOUT: Wrap entire MLS cleanup in 10-second hard timeout
      // If any operation hangs, we force ahead. Better degraded MLS than frozen app.
      let mlsCleanupOk = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
          // First bump generation to invalidate stale tasks
          await MLSClient.shared.bumpGeneration(for: currentDid)

          // Close app-layer MLSClient context (separate from core package)
          let ffiClosed = await MLSClient.shared.closeContext(for: currentDid)
          if ffiClosed {
            self.logger.info("✅ [AUTHMAN-SWITCH] MLSClient (app layer) context closed")
          }

          // Use the centralized shutdown coordinator (single attempt, no retries)
          let result = await MLSShutdownCoordinator.shared.shutdown(
            for: currentDid, databaseManager: .shared, timeout: 5.0)

          switch result {
          case .success(let durationMs):
            self.logger.info("✅ [AUTHMAN-SWITCH] Core shutdown complete in \(durationMs)ms")
          case .successWithWarnings(let durationMs, let warnings):
            self.logger.warning("⚠️ [AUTHMAN-SWITCH] Core shutdown in \(durationMs)ms with \(warnings.count) warnings")
          case .timedOut(let durationMs, let phase):
            self.logger.warning("⏱️ [AUTHMAN-SWITCH] Core shutdown timed out at \(phase.rawValue) after \(durationMs)ms")
          case .failed(let error):
            self.logger.error("❌ [AUTHMAN-SWITCH] Core shutdown failed: \(error.localizedDescription)")
          }
          return true
        }
        group.addTask {
          try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10 second hard timeout
          return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
      }

      if !mlsCleanupOk {
        logger.critical("🚨 [AUTHMAN-SWITCH] MLS cleanup timed out after 10s - forcing ahead with switch")
        // Don't abort - force ahead. User can restart if MLS is broken.
      }
    }

    // Prewarm the target account's database now that the previous account is fully drained.
    // Set the target as active BEFORE prewarming to avoid OOM-blocking rejection.
    do {
      await MLSGRDBManager.shared.setActiveUser(targetDID)
      _ = try await MLSGRDBManager.shared.getDatabasePool(for: targetDID)
      logger.debug("⚡️ [AUTHMAN-SWITCH] Prewarmed MLS database for target account")
    } catch {
      logger.debug("⚠️ [AUTHMAN-SWITCH] Prewarm failed (non-fatal): \(error.localizedDescription)")
    }

    do {
      logger.debug("🔄 [AUTHMAN-SWITCH] Updating state to .initializing")
      updateState(.initializing)

      logger.info("🔄 [AUTHMAN-SWITCH] Calling client.switchToAccount(did: \(targetDID))")
      try await client.switchToAccount(did: targetDID)
      logger.info("✅ [AUTHMAN-SWITCH] client.switchToAccount completed")

      // ═══════════════════════════════════════════════════════════════════════════
      // CRITICAL FIX: Validate session before transitioning to authenticated state
      // ═══════════════════════════════════════════════════════════════════════════
      // The account exists but may have an expired/missing session. We must verify
      // the session is valid (or can be refreshed) before declaring authenticated.
      // Otherwise the app transitions to authenticated state but all API calls fail.
      // ═══════════════════════════════════════════════════════════════════════════
      logger.debug("🔄 [AUTHMAN-SWITCH] Validating session for switched account...")
      let hasValidSession = await client.hasValidSession()
      if !hasValidSession {
        logger.warning("⚠️ [AUTHMAN-SWITCH] Account has no valid session - triggering re-auth flow")
        let storedHandle = getStoredHandle(for: targetDID)
        expiredAccountInfo = AccountInfo(did: targetDID, handle: storedHandle, isActive: false)
        logger.info(
          "🔄 [AUTHMAN-SWITCH] Set expiredAccountInfo for DID=\(targetDID) handle=\(storedHandle ?? "nil") to trigger re-auth"
        )
        isSwitchingAccount = false
        updateState(.unauthenticated)
        throw AuthError.invalidSession
      }
      logger.info("✅ [AUTHMAN-SWITCH] Session validated successfully")

      logger.debug("🔄 [AUTHMAN-SWITCH] Fetching DID from client")
      let newDid = try validatedUserDID(
        try await client.getDid(),
        source: "switchToAccount.resolved"
      )
      logger.debug("✅ [AUTHMAN-SWITCH] Got DID: \(newDid)")
      if newDid != targetDID {
        logger.warning(
          "⚠️ [AUTHMAN-SWITCH] Resolved DID differs from requested target (requested: \(targetDID), resolved: \(newDid))"
        )
      }

      logger.debug("🔄 [AUTHMAN-SWITCH] Fetching handle from client")
      self.handle = try await client.getHandle()
      logger.debug("✅ [AUTHMAN-SWITCH] Got handle: \(self.handle ?? "nil")")

      logger.debug("🔄 [AUTHMAN-SWITCH] Updating state to .authenticated")
      updateState(.authenticated(userDID: newDid))
      MLSAppActivityState.updateActiveUserDID(newDid)

      // Account switching is now handled by AppStateManager.transitionToAuthenticated()
      // which is called automatically when the AuthManager state changes to .authenticated

      logger.info(
        "✅ [AUTHMAN-SWITCH] Successfully switched to account: \(self.handle ?? "unknown") with DID: \(newDid)"
      )
    } catch {
      logger.error("❌ [AUTHMAN-SWITCH] Error switching accounts: \(error.localizedDescription)")
      logger.error("❌ [AUTHMAN-SWITCH] Error type: \(String(describing: type(of: error)))")

      // Reset switching flag since we failed
      isSwitchingAccount = false

      // Set expired account info so LoginView/AccountSwitcherView can trigger re-authentication
      // This allows automatic re-auth flow when switching to an account with expired tokens
      let storedHandle = getStoredHandle(for: targetDID)
      expiredAccountInfo = AccountInfo(did: targetDID, handle: storedHandle, isActive: false)
      logger.info(
        "🔄 [AUTHMAN-SWITCH] Set expiredAccountInfo for DID=\(targetDID) handle=\(storedHandle ?? "nil") to enable re-authentication"
      )

      // Set state to unauthenticated so the auth UI can handle re-auth
      logger.debug("🔄 [AUTHMAN-SWITCH] Updating state to .unauthenticated for re-auth flow")
      updateState(.unauthenticated)
      throw error
    }

    logger.debug("🔄 [AUTHMAN-SWITCH] Setting isSwitchingAccount = false")
    isSwitchingAccount = false
    logger.debug("🔄 [AUTHMAN-SWITCH] Refreshing available accounts")
    await refreshAvailableAccounts()
    logger.info("✅ [AUTHMAN-SWITCH] Account switch process completed")
  }

  /// Add a new account
  @MainActor
  func addAccount(handle: String) async throws -> URL {
    logger.info("Adding new account with handle: \(handle)")

    await ensureClientInitializedForAccountOperations()

    guard let client = client else {
      let error = AuthError.clientNotInitialized
      updateState(.error(message: error.localizedDescription))
      throw error
    }

    do {
      try Task.checkCancellation()
      let authURL = try await withTimeout(timeout: networkTimeout) {
        try await client.startOAuthFlow(identifier: handle)
      }
      self.logger.debug("OAuth URL generated for new account: \(authURL)")

      updateState(.authenticating(progress: .openingBrowser))
      return authURL
    } catch {
      let finalError: AuthError
      if error is CancellationError {
        finalError = AuthError.cancelled
      } else if case AuthError.timeout = error {
        finalError = AuthError.timeout
      } else if let authError = error as? AuthError {
        finalError = authError
      } else {
        finalError = AuthError.unknown(error)
      }

      logger.error("Failed to start OAuth flow for new account: \(finalError.localizedDescription)")
      updateState(.error(message: "Failed to add account: \(finalError.localizedDescription)"))
      throw finalError
    }
  }

  /// Get current active account info
  @MainActor
  func getCurrentAccountInfo() async -> AccountInfo? {
    guard case .authenticated(let did) = state, let currentHandle = handle else {
      return nil
    }

    return AccountInfo(did: did, handle: currentHandle, isActive: true)
  }

  // MARK: - Biometric Authentication

  /// Check if biometric authentication is available and configure it
  func configureBiometricAuthentication() async {
    // Do work off the main actor
    let context = LAContext()
    var error: NSError?
    let isAvailable = context.canEvaluatePolicy(
      .deviceOwnerAuthenticationWithBiometrics, error: &error)
    let detectedBiometryType: LABiometryType = isAvailable ? context.biometryType : .none
    let preference = await getBiometricAuthPreference()

    await MainActor.run {
      self.biometricType = detectedBiometryType
      if isAvailable {
        self.biometricAuthEnabled = preference
        self.logger.info("Biometric authentication available: \(self.biometricType.description)")
      } else {
        self.biometricAuthEnabled = false
        if let error {
          self.logger.warning(
            "Biometric authentication not available: \(error.localizedDescription)")
        } else {
          self.logger.info("Biometric authentication not available on this device")
        }
      }
    }
  }

  /// Enable or disable biometric authentication
  @MainActor
  func setBiometricAuthEnabled(_ enabled: Bool) async {
    lastBiometricError = nil

    guard biometricType != .none else {
      logger.warning("Cannot enable biometric auth: not available on device")
      return
    }

    if enabled {
      let success = await authenticateWithBiometrics(
        reason: "Enable biometric authentication for Catbird")
      if success {
        biometricAuthEnabled = true
        await saveBiometricAuthPreference(enabled: true)
        logger.info("Biometric authentication enabled")
      } else {
        logger.warning("Failed to enable biometric authentication")
      }
    } else {
      biometricAuthEnabled = false
      await saveBiometricAuthPreference(enabled: false)
      logger.info("Biometric authentication disabled")
    }
  }

  /// Authenticate using biometrics
  @MainActor
  func authenticateWithBiometrics(reason: String) async -> Bool {
    guard biometricType != .none else {
      logger.warning("Biometric authentication not available")
      return false
    }

    let context = LAContext()
    context.localizedFallbackTitle = "Use Password"

    do {
      let success = try await context.evaluatePolicy(
        .deviceOwnerAuthenticationWithBiometrics,
        localizedReason: reason
      )

      if success {
        logger.info("Biometric authentication successful")
        return true
      } else {
        logger.warning("Biometric authentication failed")
        return false
      }
    } catch let error as LAError {
      lastBiometricError = error
      switch error.code {
      case .userCancel:
        logger.info("User cancelled biometric authentication")
      case .userFallback:
        logger.info("User chose to use fallback authentication")
      case .biometryNotAvailable:
        logger.warning("Biometric authentication not available")
      case .biometryNotEnrolled:
        logger.warning("No biometric credentials enrolled")
      case .biometryLockout:
        logger.warning("Biometric authentication locked out")
      default:
        logger.error("Biometric authentication error: \(error.localizedDescription)")
      }
      return false
    } catch {
      logger.error("Unexpected biometric authentication error: \(error.localizedDescription)")
      return false
    }
  }

  /// Quick authentication check for app unlock
  @MainActor
  func quickAuthenticationCheck() async -> Bool {
    guard biometricAuthEnabled && biometricType != .none else {
      return true  // No biometric auth required, proceed
    }

    return await authenticateWithBiometrics(reason: "Unlock Catbird")
  }

  // MARK: - Biometric Preferences

  private func getBiometricAuthPreference() async -> Bool {
    return UserDefaults.standard.bool(forKey: "biometric_auth_enabled")
  }

  private func saveBiometricAuthPreference(enabled: Bool) async {
    UserDefaults.standard.set(enabled, forKey: "biometric_auth_enabled")
  }

  // MARK: - AuthProgressDelegate

  /// Handles authentication progress events from Petrel
  func authenticationProgress(_ event: AuthProgressEvent) async {
    let progress: AuthProgress
    switch event {
    case .resolvingHandle(let handle):
      progress = .resolvingHandle(handle: handle)
    case .fetchingMetadata(let url):
      progress = .fetchingMetadata(url: url)
    case .generatingParameters:
      progress = .generatingAuthURL
    case .exchangingTokens:
      progress = .exchangingTokens
    case .creatingSession:
      progress = .creatingSession
    case .retrying(let operation, let attempt, let maxAttempts):
      progress = .retrying(step: operation, attempt: attempt, maxAttempts: maxAttempts)
    }

    await MainActor.run {
      self.updateState(.authenticating(progress: progress))
    }
  }

  // MARK: - Error Recovery Methods

  /// Attempts to recover from auth failures when connectivity is restored
  @MainActor
  func attemptRecoveryFromNetworkIssues() async {
    logger.info("Attempting recovery from network issues")

    guard let client = self.client else {
      logger.error("Cannot attempt recovery - no client available")
      return
    }

    do {
      try await client.attemptRecoveryFromServerFailures()
      logger.info("Recovery successful - checking authentication state")
      await checkAuthenticationState()
    } catch {
      logger.error("Recovery attempt failed: \(error)")
      updateState(AuthState.error(message: "Recovery failed: \(error.localizedDescription)"))
    }
  }
}

// MARK: - AuthenticationDelegate

extension AuthenticationManager: AuthenticationDelegate {
  // Called by Petrel when a refresh fails or auth is otherwise required again.
  func authenticationRequired(client: ATProtoClient) {
    logger.error("AuthenticationDelegate.authenticationRequired received from Petrel")
    Task { @MainActor in
      // DEBOUNCE: Avoid multiple triggers
      if self.isHandlingAuthExpiration {
        logger.warning("Already handling auth expiration, skipping duplicate trigger")
        return
      }
      self.isHandlingAuthExpiration = true

      await self.markCurrentAccountExpiredForReauth(
        client: client, reason: "authentication_required")

      // Only show alert if we couldn't identify the account for auto-reauth
      if self.expiredAccountInfo == nil {
        if self.pendingAuthAlert == nil {
          self.pendingAuthAlert = AuthAlert(
            title: "Signed Out", message: "Your session has expired. Please sign in again.")
        }
      } else {
        // Clear any existing alert so it doesn't block the auto-reauth flow
        self.pendingAuthAlert = nil
        logger.info(
          "Skipping alert in authenticationRequired - expiredAccountInfo is set, will auto-trigger re-auth flow"
        )
      }

      self.updateState(.unauthenticated)
    }
  }
}

// MARK: - AuthFailureDelegate

extension AuthenticationManager: AuthFailureDelegate {
  @MainActor
  func handleCatastrophicAuthFailure(did: String, error: Error, isRetryable: Bool) async {
    logger.error(
      "AuthFailureDelegate.catastrophic did=\(did) retryable=\(isRetryable) error=\(error.localizedDescription)"
    )

    // DEBOUNCE
    if isHandlingAuthExpiration {
      logger.warning("Already handling auth expiration, skipping duplicate trigger (catastrophic)")
      return
    }
    isHandlingAuthExpiration = true

    // Prime re-auth for the specified DID
    let storedHandle = getStoredHandle(for: did)
    if expiredAccountInfo == nil {
      expiredAccountInfo = AccountInfo(did: did, handle: storedHandle, isActive: false)
    }

    if isRetryable {
      if pendingAuthAlert == nil {
        let message = "The server is temporarily unavailable. Please try again shortly."
        pendingAuthAlert = AuthAlert(title: "Authentication Unavailable", message: message)
      }
    } else {
      // Terminal failure - prefer auto-reauth without alert if possible
      if expiredAccountInfo != nil {
        pendingAuthAlert = nil
        logger.info(
          "Skipping alert in catastrophic failure - expiredAccountInfo is set, will auto-trigger re-auth flow"
        )
      } else if pendingAuthAlert == nil {
        pendingAuthAlert = AuthAlert(
          title: "Signed Out", message: "Your session is no longer valid. Please sign in again.")
      }
    }

    updateState(.unauthenticated)
  }

  @MainActor
  func handleCircuitBreakerOpen(did: String) async {
    logger.warning("AuthFailureDelegate.circuitBreakerOpen did=\(did)")
    if pendingAuthAlert == nil {
      pendingAuthAlert = AuthAlert(
        title: "Authentication Temporarily Paused",
        message:
          "We’re seeing repeated failures contacting your server. We’ll retry shortly, or you can sign in again now."
      )
    }
  }
}

// MARK: - Error Types

enum AuthError: Error, LocalizedError {
  case clientNotInitialized
  case invalidSession
  case invalidCredentials
  case invalidCallbackURL
  case networkError(Error)
  case badResponse(Int)
  case timeout
  case cancelled
  case unknown(Error)
  /// Received an empty or malformed DID from auth/session resolution.
  case invalidUserDID
  /// Account switch is already in progress - prevents re-entrancy
  case accountSwitchInProgress
  /// Database drain failed during account switch; do not proceed to avoid corruption.
  case databaseDrainFailed

  var errorDescription: String? {
    switch self {
    case .clientNotInitialized:
      return "Authentication client not initialized"
    case .invalidSession:
      return "Invalid session"
    case .invalidCallbackURL:
      return "Invalid OAuth callback URL"
    case .invalidCredentials:
      return "Invalid credentials"
    case .networkError(let error):
      return "Network error: \(error.localizedDescription)"
    case .badResponse(let code):
      return "Bad response code: \(code)"
    case .timeout:
      return "Authentication timed out. Please try again."
    case .cancelled:
      return "Authentication was cancelled"
    case .unknown(let error):
      return "Unknown error: \(error.localizedDescription)"
    case .invalidUserDID:
      return "Received an invalid account identifier"
    case .accountSwitchInProgress:
      return "Please wait for the current account switch to complete"
    case .databaseDrainFailed:
      return "Could not safely close the database. Please restart the app and try again."
    }
  }

  var failureReason: String? {
    switch self {
    case .clientNotInitialized:
      return "The authentication system has not been properly set up."
    case .invalidSession:
      return "Your authentication session is no longer valid or has been corrupted."
    case .invalidCredentials:
      return "The provided username, password, or authentication token is incorrect."
    case .networkError:
      return "Unable to connect to the authentication server."
    case .badResponse(let code) where code >= 500:
      return "The authentication server is experiencing technical difficulties."
    case .badResponse(let code) where code == 429:
      return "Too many authentication attempts. Rate limit exceeded."
    case .badResponse(let code) where code >= 400:
      return "The authentication request was rejected by the server."
    case .timeout:
      return "The authentication process took too long to complete."
    case .cancelled:
      return "Authentication was cancelled by the user."
    case .unknown:
      return "An unexpected error occurred during authentication."
    case .invalidUserDID:
      return "The authentication response did not include a usable account identifier."
    case .databaseDrainFailed:
      return
        "The app couldn’t acquire exclusive access to the encrypted database to flush and close it safely."
    default:
      return nil
    }
  }

  var recoverySuggestion: String? {
    switch self {
    case .clientNotInitialized:
      return "Please restart the app. If the problem persists, contact support."
    case .invalidSession:
      return "Please log out and log back in to refresh your session."
    case .invalidCredentials:
      return "Please check your username and password, then try again."
    case .networkError:
      return "Check your internet connection and try again."
    case .badResponse(let code) where code >= 500:
      return "Please wait a moment and try again. If the problem persists, contact support."
    case .badResponse(let code) where code == 429:
      return "Please wait a few minutes before trying to authenticate again."
    case .badResponse(let code) where code >= 400:
      return "Check your login credentials and try again."
    case .timeout:
      return "Please try again with a stable internet connection."
    case .cancelled:
      return "You can try logging in again when ready."
    case .unknown:
      return "Please try again or contact support if the problem persists."
    case .invalidUserDID:
      return "Sign in again to re-establish a valid account session."
    case .accountSwitchInProgress:
      return "Wait a moment for the current account switch to finish, then try again."
    case .databaseDrainFailed:
      return "Restart the app, then try switching accounts again."
    default:
      return "Please try again or contact support if the problem persists."
    }
  }
}

// MARK: - AsyncStream Extension

extension AsyncStream {
  /// Create a stream with its continuation
  static func makeStream() -> (
    stream: AsyncStream<Element>, continuation: AsyncStream<Element>.Continuation
  ) {
    var continuation: AsyncStream<Element>.Continuation!
    let stream = AsyncStream<Element> { cont in
      continuation = cont
    }
    return (stream, continuation)
  }
}

// MARK: - LABiometryType Extension

extension LABiometryType {
  var description: String {
    switch self {
    case .none:
      return "None"
    case .touchID:
      return "Touch ID"
    case .faceID:
      return "Face ID"
    case .opticID:
      return "Optic ID"
    @unknown default:
      return "Unknown"
    }
  }

  var displayName: String {
    switch self {
    case .none:
      return "No biometric authentication"
    case .touchID:
      return "Touch ID"
    case .faceID:
      return "Face ID"
    case .opticID:
      return "Optic ID"
    @unknown default:
      return "Biometric authentication"
    }
  }
}
