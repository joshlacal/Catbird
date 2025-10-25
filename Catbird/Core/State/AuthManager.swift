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
  private let authenticationTimeout: TimeInterval = 60.0 // 60 seconds
  private let networkTimeout: TimeInterval = 30.0 // 30 seconds for individual network calls

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
    clientId: "https://catbird.blue/oauth/client-metadata.json",
    redirectUri: "https://catbird.blue/oauth/callback",
    scope: "atproto transition:generic transition:chat.bsky"
  )
  
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
    logger.error("Auto logout from Petrel: did=\(did ?? "nil") reason=\(reason ?? "nil")")

    if let did {
      let storedHandle = getStoredHandle(for: did)
      expiredAccountInfo = AccountInfo(did: did, handle: storedHandle, isActive: false)
      logger.info("Stored expired account info for automatic re-authentication: \(storedHandle ?? did)")
    }

    Task {
      await AppState.shared.notificationManager.cleanupNotifications(previousClient: client)
    }

    updateState(.unauthenticated)

    client = nil

    if let did, case .authenticated(let current) = state, current == did {
      handle = nil
    }

    updateAvailableAccountsFromStoredHandles(activeDID: nil)

    let reasonText: String = {
      switch (reason ?? "").lowercased() {
      case "invalid_grant":
        return "Your session expired or was revoked. Please sign in again."
      case "invalid_token":
        return "Your session token is no longer valid. Please sign in again."
      default:
        return reason.map { "Signed out: \($0). Please sign in again." } ?? "You were signed out. Please sign in again."
      }
    }()
    pendingAuthAlert = AuthAlert(title: "Signed Out", message: reasonText)
  }

  @MainActor
  func clearPendingAuthAlert() {
    pendingAuthAlert = nil
  }

  /// Clear expired account info
  @MainActor
  func clearExpiredAccountInfo() {
    expiredAccountInfo = nil
  }

  /// Start OAuth flow for the expired account (if available)
  @MainActor
  func startOAuthFlowForExpiredAccount() async throws -> URL? {
    guard let expiredAccount = expiredAccountInfo,
          let handle = expiredAccount.handle else {
      logger.warning("No expired account information available for automatic re-authentication")
      return nil
    }

    logger.info("Starting OAuth flow for expired account: \(handle)")
    return try await login(handle: handle)
  }

  /// Update the authentication state and emit the change
  @MainActor
  private func updateState(_ newState: AuthState) {
    guard newState != state else { return }
    logger.debug("Updating auth state: \(String(describing: self.state)) -> \(String(describing: newState))")
    self.state = newState
    Task {
      stateSubject.continuation.yield(newState)
    }
  }
    
  /// Special method for FaultOrdering to skip expensive initialization
  @MainActor
  func setAuthenticatedStateForFaultOrdering() {
    logger.info("⚡ FaultOrdering: Setting authenticated state without full initialization")
    updateState(.authenticated(userDID: AppState.shared.currentUserDID ?? ""))
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
      logger.debug(">>> Calling await ATProtoClient(...)")

      client = await ATProtoClient(
        oauthConfig: oauthConfig,
        namespace: "blue.catbird",
        userAgent: "Catbird/1.0",
        bskyAppViewDID: customAppViewDID,
        bskyChatDID: customChatDID
      )
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
        logger.info("ATProtoClient already exists, updating service DIDs to: bskyAppViewDID=\(self.customAppViewDID), bskyChatDID=\(self.customChatDID)")
      await client?.updateServiceDIDs(bskyAppViewDID: customAppViewDID, bskyChatDID: customChatDID)
    }

    logger.debug("Client state before checkAuthenticationState: \(self.client == nil ? "NIL" : "Exists")")
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

    if ProcessInfo.processInfo.environment["FAULT_ORDERING_ENABLE"] == "1" {
      logger.info("⚡ FaultOrdering mode - skipping token refresh, using existing session")
      if await client.hasValidSession() {
        updateState(.authenticated(userDID: AppState.shared.currentUserDID ?? ""))
        logger.info("✅ Using existing valid session for FaultOrdering")
      } else {
        if !isAuthenticationCancelled {
          updateState(.unauthenticated)
        }
        logger.info("❌ No valid session found for FaultOrdering")
      }
      return
    }

    if await client.hasValidSession() {
      let refreshSuccess = await refreshTokenWithRetry(client: client)
      if !refreshSuccess {
        logger.warning("Token refresh failed after retries; will verify session validity next")
      }
    }

    let hasValidSession = await client.hasValidSession()

    if hasValidSession {
      do {
        let did = try await client.getDid()
        self.handle = try await client.getHandle()
        logger.info("User is authenticated with DID: \(String(describing: did))")

        if let handle = self.handle {
          storeHandle(handle, for: did)
        }

        await MainActor.run {
          updateState(.authenticated(userDID: did))
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
      if expiredAccountInfo == nil { // don’t overwrite if already set (e.g., auto-logout path)
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
            logger.info("Authentication error detected (\(nsError.code)); not retrying token refresh")
            // Mark the current account as expired to route UI to re-auth.
            await markCurrentAccountExpiredForReauth(client: client, reason: "unauthorized_\(nsError.code)")
            break
          }
          if nsError.domain == NSURLErrorDomain && [
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost
          ].contains(nsError.code) {
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
      logger.error("Token refresh failed after \(maxRetries) attempts: \(error.localizedDescription)")
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
    // Prefer the active account DID if we can get it
    var chosenDID: String? = nil
    if let did = try? await client.getDid() { chosenDID = did }

    // Fallback: if exactly one stored/listed account exists, choose it
    if chosenDID == nil {
      let accounts = await client.listAccounts()
      if accounts.count == 1 { chosenDID = accounts.first?.did }
      else if accounts.isEmpty {
        // Last resort: use stored handles cache
        let stored = getStoredHandles()
        if stored.count == 1 { chosenDID = stored.keys.first }
      }
    }

    guard let did = chosenDID else { return }
    let storedHandle = getStoredHandle(for: did)
    expiredAccountInfo = AccountInfo(did: did, handle: storedHandle, isActive: false)
    logger.info("Prepared expiredAccountInfo for DID=\(did) handle=\(storedHandle ?? "nil") to trigger re-auth")

    // Keep the account list fresh for Account Switcher fallback
    await refreshAvailableAccounts()
  }

  /// Marks the current account as expired (when we can resolve DID) to drive re-auth UI.
  @MainActor
  private func markCurrentAccountExpiredForReauth(client: ATProtoClient, reason: String?) async {
    // Do not clobber if already set via auto-logout log bridge
    guard expiredAccountInfo == nil else { return }
    let did = (try? await client.getDid()) ?? ""
    if !did.isEmpty {
      let storedHandle = getStoredHandle(for: did)
      expiredAccountInfo = AccountInfo(did: did, handle: storedHandle, isActive: false)
      logger.warning("Session expired for DID=\(did); reason=\(reason ?? "unknown"). Prompting re-auth.")
    }
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
      client = await ATProtoClient(
        oauthConfig: oauthConfig,
        namespace: "blue.catbird",
        userAgent: "Catbird/1.0",
        bskyAppViewDID: customAppViewDID,
        bskyChatDID: customChatDID
      )
      await client?.applicationDidBecomeActive()
      await client?.setAuthProgressDelegate(self)
      await client?.setFailureDelegate(self)
      if let client = client { await client.setAuthenticationDelegate(self) }
    } else {
        logger.info("Client exists, updating service DIDs to: bskyAppViewDID=\(self.customAppViewDID), bskyChatDID=\(self.customChatDID)")
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
            await self.updateState(.authenticating(progress: .retrying(step: "OAuth setup", attempt: attempt, maxAttempts: maxRetries)))
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
            if nsError.domain == NSURLErrorDomain && [
              NSURLErrorTimedOut,
              NSURLErrorCannotConnectToHost,
              NSURLErrorNetworkConnectionLost
            ].contains(nsError.code) {
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
      logger.warning("⚠️ [CALLBACK] Received callback in unexpected state: \(String(describing: self.state))")
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
        let did = try await client.getDid()
        self.logger.debug("✅ [CALLBACK] Got DID: \(did)")
        
        self.logger.debug("🔄 [CALLBACK] Getting handle from client")
        self.handle = try await client.getHandle()
        self.logger.debug("✅ [CALLBACK] Got handle: \(self.handle ?? "nil")")

        if let handle = self.handle {
          self.storeHandle(handle, for: did)
        }

        await client.clearTemporaryAccountStorage()
        
        await MainActor.run {
          self.isAuthenticationCancelled = false
          self.expiredAccountInfo = nil
          self.updateState(.authenticated(userDID: did))
        }
        self.logger.info("Authentication successful for user \(self.handle ?? "unknown")")
      }
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

  /// Logout the current user
  @MainActor
  func logout() async {
    logger.info("Logging out user")

    isAuthenticationCancelled = false
    updateState(.unauthenticated)

    Task {
      await AppState.shared.notificationManager.cleanupNotifications(previousClient: client)
    }

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
    expiredAccountInfo = nil

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
          let handles = try? JSONDecoder().decode([String: String].self, from: data) else {
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
          let order = try? JSONDecoder().decode([String].self, from: data) else {
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

      accountInfos.append(
        AccountInfo(
          did: account.did,
          handle: handle,
          isActive: account.did == currentDID
        )
      )
    }

    let storedHandles = getStoredHandles()
    for (storedDID, storedHandle) in storedHandles where !accountInfos.contains(where: { $0.did == storedDID }) {
      accountInfos.append(
        AccountInfo(
          did: storedDID,
          handle: storedHandle,
          isActive: storedDID == currentDID
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
        case let (.some(lIdx), .some(rIdx)):
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
    client = await ATProtoClient(
      oauthConfig: oauthConfig,
      namespace: "blue.catbird",
      userAgent: "Catbird/1.0",
      bskyAppViewDID: customAppViewDID,
      bskyChatDID: customChatDID
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
      AccountInfo(
        did: did,
        handle: handle,
        isActive: did == activeDID
      )
    }

    // Apply custom ordering if available
    let savedOrder = getAccountOrder()
    if !savedOrder.isEmpty {
      availableAccounts = infos.sorted { lhs, rhs in
        let lhsIndex = savedOrder.firstIndex(of: lhs.did)
        let rhsIndex = savedOrder.firstIndex(of: rhs.did)
        
        switch (lhsIndex, rhsIndex) {
        case let (.some(lIdx), .some(rIdx)):
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
    logger.info("🔄 [AUTHMAN-SWITCH] Starting switchToAccount for DID: \(did)")
      logger.debug("🔄 [AUTHMAN-SWITCH] Current state: \(String(describing: self.state))")
    logger.debug("🔄 [AUTHMAN-SWITCH] Ensuring client initialized...")
    await ensureClientInitializedForAccountOperations()

    guard let client = client else {
      logger.error("❌ [AUTHMAN-SWITCH] Client not initialized after ensureClientInitializedForAccountOperations")
      throw AuthError.clientNotInitialized
    }
    logger.debug("✅ [AUTHMAN-SWITCH] Client is available")

    if case .authenticated(let currentDid) = state, currentDid == did {
      logger.info("ℹ️ [AUTHMAN-SWITCH] Already using account with DID: \(did)")
      return
    }

    logger.info("🔄 [AUTHMAN-SWITCH] Proceeding with account switch to DID: \(did)")
    logger.debug("🔄 [AUTHMAN-SWITCH] Setting isSwitchingAccount = true")
    isSwitchingAccount = true

    do {
      logger.debug("🔄 [AUTHMAN-SWITCH] Updating state to .initializing")
      updateState(.initializing)
      
      logger.info("🔄 [AUTHMAN-SWITCH] Calling client.switchToAccount(did: \(did))")
      try await client.switchToAccount(did: did)
      logger.info("✅ [AUTHMAN-SWITCH] client.switchToAccount completed")

      logger.debug("🔄 [AUTHMAN-SWITCH] Fetching DID from client")
      let newDid = try await client.getDid()
      logger.debug("✅ [AUTHMAN-SWITCH] Got DID: \(newDid)")
      
      logger.debug("🔄 [AUTHMAN-SWITCH] Fetching handle from client")
      self.handle = try await client.getHandle()
      logger.debug("✅ [AUTHMAN-SWITCH] Got handle: \(self.handle ?? "nil")")

      logger.debug("🔄 [AUTHMAN-SWITCH] Updating state to .authenticated")
      updateState(.authenticated(userDID: newDid))
      logger.info("✅ [AUTHMAN-SWITCH] Successfully switched to account: \(self.handle ?? "unknown") with DID: \(newDid)")
    } catch {
      logger.error("❌ [AUTHMAN-SWITCH] Error switching accounts: \(error.localizedDescription)")
      logger.error("❌ [AUTHMAN-SWITCH] Error type: \(String(describing: type(of: error)))")
      
      // Clear expired account info when switch fails
      // This prevents automatic re-authentication of the wrong account
      logger.debug("🔄 [AUTHMAN-SWITCH] Clearing expiredAccountInfo")
      expiredAccountInfo = nil
      
      logger.debug("🔄 [AUTHMAN-SWITCH] Updating state to .error")
      updateState(.error(message: "Failed to switch accounts: \(error.localizedDescription)"))
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
    let isAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
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
          self.logger.warning("Biometric authentication not available: \(error.localizedDescription)")
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
      let success = await authenticateWithBiometrics(reason: "Enable biometric authentication for Catbird")
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
      return true // No biometric auth required, proceed
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
      await self.markCurrentAccountExpiredForReauth(client: client, reason: "authentication_required")
      // Surface a gentle alert once; LoginView will auto-start reauth for expiredAccountInfo
      if self.pendingAuthAlert == nil {
        self.pendingAuthAlert = AuthAlert(title: "Signed Out", message: "Your session has expired. Please sign in again.")
      }
      self.updateState(.unauthenticated)
    }
  }
}

// MARK: - AuthFailureDelegate

extension AuthenticationManager: AuthFailureDelegate {
  @MainActor
  func handleCatastrophicAuthFailure(did: String, error: Error, isRetryable: Bool) async {
    logger.error("AuthFailureDelegate.catastrophic did=\(did) retryable=\(isRetryable) error=\(error.localizedDescription)")
    // Prime re-auth for the specified DID
    let storedHandle = getStoredHandle(for: did)
    if expiredAccountInfo == nil {
      expiredAccountInfo = AccountInfo(did: did, handle: storedHandle, isActive: false)
    }
    if pendingAuthAlert == nil {
      let title = isRetryable ? "Authentication Unavailable" : "Signed Out"
      let message = isRetryable ? "The server is temporarily unavailable. Please try again shortly." : "Your session is no longer valid. Please sign in again."
      pendingAuthAlert = AuthAlert(title: title, message: message)
    }
    updateState(.unauthenticated)
  }

  @MainActor
  func handleCircuitBreakerOpen(did: String) async {
    logger.warning("AuthFailureDelegate.circuitBreakerOpen did=\(did)")
    if pendingAuthAlert == nil {
      pendingAuthAlert = AuthAlert(title: "Authentication Temporarily Paused", message: "We’re seeing repeated failures contacting your server. We’ll retry shortly, or you can sign in again now.")
    }
  }
}

// MARK: - Error Types

enum AuthError: Error, LocalizedError {
  case clientNotInitialized
  case invalidSession
  case invalidCredentials
  case networkError(Error)
  case badResponse(Int)
  case timeout
  case cancelled
  case unknown(Error)

  var errorDescription: String? {
    switch self {
    case .clientNotInitialized:
      return "Authentication client not initialized"
    case .invalidSession:
      return "Invalid session"
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
