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

  // Available accounts
   var availableAccounts: [AccountInfo] = [] // Removed private(set) as @Observable handles it
   var isSwitchingAccount = false // Removed private(set)

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
  
  // MARK: - Timeout Utility
  
  /// Executes an async operation with a timeout, throwing TimeoutError if exceeded
  private func withTimeout<T>(
    timeout: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      // Add the main operation
      group.addTask {
        try await operation()
      }
      
      // Add the timeout task
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        throw AuthError.timeout
      }
      
      // Return the first result (either success or timeout)
      defer { group.cancelAll() }
      return try await group.next()!
    }
  }

  // MARK: - Initialization

  init() {
    logger.debug("AuthenticationManager initialized")
    
    // Configure biometric authentication asynchronously
    Task {
      await configureBiometricAuthentication()
    }
  }

  // MARK: - State Management

  /// Access state changes as an AsyncSequence
  var stateChanges: AsyncStream<AuthState> {
    return stateSubject.stream
  }

  /// Update the authentication state and emit the change
    @MainActor
    private func updateState(_ newState: AuthState) {
      guard newState != state else { return }
      
      logger.debug(
        "Updating auth state: \(String(describing: self.state)) -> \(String(describing: newState))")

      // Directly update the state on the MainActor
      self.state = newState
      
      // Then yield to any async observers
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
    
    // Clear cancellation flag on initialize
    isAuthenticationCancelled = false
    
    updateState(.initializing)

    if client == nil {
      logger.info("ATTEMPTING to create ATProtoClient...")  // More specific log
      updateState(.authenticating(progress: .initializingClient))
      
      // Add log immediately before
      logger.debug(">>> Calling await ATProtoClient(...)")

      // Assuming initializer doesn't throw based on compiler error
      client = await ATProtoClient(
        oauthConfig: oauthConfig,
        namespace: "blue.catbird",
        userAgent: "Catbird/1.0"
      )
        
      await client?.applicationDidBecomeActive()

      // Check if client creation succeeded (if it returns optional or has an error state)
      // This part might need adjustment based on ATProtoClient's actual non-throwing failure mechanism
      if client == nil {
          logger.critical("❌❌❌ FAILED to create ATProtoClient (initializer did not throw but returned nil or failed internally) ❌❌❌")
          updateState(.error(message: "Failed to initialize client"))
          return // Exit early
      } else {
          // Add log immediately after *successful* creation
          logger.info("✅✅✅ ATProtoClient CREATED SUCCESSFULLY ✅✅✅")  // Make it stand out
          
          // Set up progress delegate
          await client?.setAuthProgressDelegate(self)
      }

    } else {
      logger.info("ATProtoClient already exists.")
    }

    // Log state *before* checking auth
    logger.debug(
      "Client state before checkAuthenticationState: \(self.client == nil ? "NIL" : "Exists")")
    await checkAuthenticationState()
  }

  /// Check the current authentication state with enhanced token refresh
  @MainActor
  func checkAuthenticationState() async {
    // Don't update state if authentication was cancelled by user
    guard !isAuthenticationCancelled else {
      logger.debug("Skipping auth state check - authentication was cancelled by user")
      return
    }
    
    guard let client = client else {
      updateState(.unauthenticated)
      return
    }

    logger.debug("Checking authentication state")

    // Fast path for FaultOrdering - skip token refresh to prevent network timeout
    if ProcessInfo.processInfo.environment["FAULT_ORDERING_ENABLE"] == "1" {
      logger.info("⚡ FaultOrdering mode - skipping token refresh, using existing session")
      if await client.hasValidSession() {
          updateState(.authenticated(userDID: AppState.shared.currentUserDID ?? ""))
        logger.info("✅ Using existing valid session for FaultOrdering")
      } else {
        // Don't update state if authentication was cancelled
        if !isAuthenticationCancelled {
          updateState(.unauthenticated)
        }
        logger.info("❌ No valid session found for FaultOrdering")
      }
      return
    }

    // First, try to refresh token if it exists with retry logic
    if await client.hasValidSession() {
      let refreshSuccess = await refreshTokenWithRetry(client: client)
      if !refreshSuccess {
        logger.warning("Token refresh failed after retries, proceeding with existing session")
      }
    }

    // After potential refresh, check session validity
    let hasValidSession = await client.hasValidSession()

    if hasValidSession {
      // Get user DID
      do {
        let did = try await client.getDid()

        self.handle = try await client.getHandle()
        logger.info("User is authenticated with DID: \(String(describing: did))")

        // Store handle for multi-account support
        if let handle = self.handle {
          storeHandle(handle, for: did)
        }

        // Update state properly through the state update method
        await MainActor.run {
          updateState(.authenticated(userDID: did))
          logger.info("Auth state updated to authenticated via proper channels")

          // Double check the state was updated properly
          logger.info("Current state after update: \(String(describing: self.state))")
        }
      } catch {
        logger.error("Error fetching user identity: \(error.localizedDescription)")
        // Don't update state if authentication was cancelled
        if !isAuthenticationCancelled {
          updateState(.unauthenticated)
        }
      }
    } else {
      logger.info("No valid session found")
      // Don't update state if authentication was cancelled
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
        
        // Check if this is a non-retryable error
        if let nsError = error as NSError? {
          // Don't retry authentication errors (invalid refresh token)
          if nsError.code == 401 || nsError.code == 403 {
            logger.info("Authentication error detected, not retrying token refresh")
            break
          }
          
          // Network errors - worth retrying
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
        
        // If this was the last attempt, break
        if attempt == maxRetries {
          break
        }
        
        // Wait before retrying with exponential backoff
        try? await Task.sleep(nanoseconds: UInt64(attempt * 1_000_000_000))
      }
    }
    
    // All retries failed
    if let error = lastError {
      logger.error("Token refresh failed after \(maxRetries) attempts: \(error.localizedDescription)")
    }
    return false
  }

  /// Start the OAuth authentication flow with improved error handling
  @MainActor
  func login(handle: String) async throws -> URL {
    logger.info("Starting OAuth flow for handle: \(handle)")

    // Cancel any existing authentication task
    currentAuthTask?.cancel()
    currentAuthTask = nil

    // Clear cancellation flag for new attempt
    isAuthenticationCancelled = false

    // Update state
    updateState(.authenticating(progress: .resolvingHandle(handle: handle)))

    // Ensure client exists, create if needed
    if client == nil {
      logger.info("Client not found, initializing for login")
      client = await ATProtoClient(
        oauthConfig: oauthConfig,
        namespace: "blue.catbird",
        userAgent: "Catbird/1.0"
      )
      await client?.applicationDidBecomeActive()
      await client?.setAuthProgressDelegate(self)
    }
    
    guard let client = client else {
      let error = AuthError.clientNotInitialized
      updateState(.error(message: error.localizedDescription))
      throw error
    }

    // Start OAuth flow with retry logic (no timeout wrapper)
    do {
      var lastError: Error?
      let maxRetries = 3
      
      for attempt in 1...maxRetries {
        // Check for task cancellation before each attempt
        try Task.checkCancellation()
        
        do {
          self.logger.debug("OAuth flow attempt \(attempt) of \(maxRetries)")
          
          if attempt > 1 {
            await self.updateState(.authenticating(progress: .retrying(step: "OAuth setup", attempt: attempt, maxAttempts: maxRetries)))
          } else {
            await self.updateState(.authenticating(progress: .generatingAuthURL))
          }
          
          // Apply timeout only to the network operation
          let authURL = try await withTimeout(timeout: networkTimeout) {
            try await client.startOAuthFlow(identifier: handle)
          }
          self.logger.debug("OAuth URL generated successfully: \(authURL)")
          
          await self.updateState(.authenticating(progress: .openingBrowser))
          return authURL
        } catch {
          lastError = error
          self.logger.warning("OAuth flow attempt \(attempt) failed: \(error.localizedDescription)")
          
          // Don't retry certain types of errors
          if let nsError = error as NSError? {
            // Network timeout or connection errors - worth retrying
            if nsError.domain == NSURLErrorDomain && [
              NSURLErrorTimedOut,
              NSURLErrorCannotConnectToHost,
              NSURLErrorNetworkConnectionLost
            ].contains(nsError.code) {
              if attempt < maxRetries {
                self.logger.info("Retrying OAuth flow after network error in \(attempt) seconds...")
                try? await Task.sleep(nanoseconds: UInt64(attempt * 1_000_000_000)) // Exponential backoff
                continue
              }
            }
            // Authentication errors - don't retry
            else if nsError.code == 401 || nsError.code == 403 {
              break
            }
          }
          
          // If this was the last attempt, break
          if attempt == maxRetries {
            break
          }
          
          // Wait before retrying with exponential backoff
          try? await Task.sleep(nanoseconds: UInt64(attempt * 1_000_000_000))
        }
      }
      
      // All retries failed
      let finalError = lastError ?? AuthError.unknown(NSError(domain: "OAuth", code: -1))
      throw finalError
    } catch {
      // Handle specific error types
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
    logger.info("Processing OAuth callback")
    updateState(.authenticating(progress: .exchangingTokens))

    // Ensure we're in the right state
    if case .authenticating = state {
      // Continue, this is expected
    } else {
      logger.warning("Received callback in unexpected state: \(String(describing: self.state))")
      // Continue anyway, but log the issue
    }

    // Ensure client exists
    guard let client = client else {
      let error = AuthError.clientNotInitialized
      updateState(.error(message: error.localizedDescription))
      throw error
    }

    // Wrap callback processing with timeout
    do {
      try await withTimeout(timeout: networkTimeout) {
        // Check for task cancellation
        try Task.checkCancellation()
        
        // Handle callback - Propagating errors via function signature
        try await client.handleOAuthCallback(url: url)
        self.logger.info("OAuth callback processed successfully")
        
        await self.updateState(.authenticating(progress: .creatingSession))

        // Verify session is valid after OAuth callback (skip unnecessary refresh of fresh token)
        let hasValidSession = await client.hasValidSession()
        if !hasValidSession {
          self.logger.error("Session invalid after OAuth callback processing")
          throw AuthError.invalidSession
        }

        await self.updateState(.authenticating(progress: .finalizing))

        // Get user info
        let did = try await client.getDid() // Propagate error if this fails
        self.handle = try await client.getHandle() // Propagate error if this fails

        // Store handle for multi-account support
        if let handle = self.handle {
          self.storeHandle(handle, for: did)
        }

        // Update state
          await MainActor.run {
              // Clear cancellation flag on successful authentication
              self.isAuthenticationCancelled = false
              self.updateState(.authenticated(userDID: did))
          }
        self.logger.info("Authentication successful for user \(self.handle ?? "unknown")")
      }
    } catch {
      // Handle specific error types
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

    // Clear cancellation flag - this is a deliberate logout
    isAuthenticationCancelled = false

    // Update state first to ensure UI updates immediately
    updateState(.unauthenticated)

    // Clean up
    if let client = client {
      do {
        try await client.logout()
        logger.info("Logout successful")
      } catch {
        logger.error("Error during logout: \(error.localizedDescription)")
        // We still consider the user logged out even if this fails
      }
    }

    // Clear client to prevent circuit breaker state persistence
    self.client = nil

    // Clear user info
    handle = nil
  }

  /// Reset after an error or cancellation
  @MainActor
  func resetError() {
    // Cancel any ongoing authentication task
    currentAuthTask?.cancel()
    currentAuthTask = nil
    
    // Cancel OAuth flow in Petrel
    if let client = client {
      Task {
        await client.cancelOAuthFlow()
      }
    }
    
    // Set cancellation flag to prevent spurious logout from background tasks
    isAuthenticationCancelled = true
    
    if case .error = state {
      updateState(.unauthenticated)
    } else if case .authenticating = state {
      // Also reset if stuck in authenticating state (e.g., user cancelled)
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
  }
  
  /// Remove an account completely (including stored handle)
  @MainActor
  func removeAccount(did: String) async {
    logger.info("Removing account: \(did)")
    
    // Remove stored handle
    removeStoredHandle(for: did)
    
    // Remove from client if available
    if let client = client {
      do {
        try await client.removeAccount(did: did)
        logger.info("Account removed successfully")
      } catch {
        logger.error("Error removing account: \(error.localizedDescription)")
      }
    }
    
    // Refresh available accounts
    await refreshAvailableAccounts()
  }

  /// Get list of all available accounts
  @MainActor
  func refreshAvailableAccounts() async {
    guard let client = client else {
      logger.warning("Cannot list accounts: client is nil")
      availableAccounts = []
      return
    }

      // Get current DID for marking active account
      var currentDID: String?
      if case .authenticated(let did) = state {
        currentDID = did
      }

      // Get list of accounts from client
      let accounts = await client.listAccounts()
      logger.info("Found \(accounts.count) available accounts")

      // Build account info objects
      var accountInfos: [AccountInfo] = []

      for account in accounts {
        // Try to get handle for this account (may require switching to it temporarily)
        var handle: String?

          if account.did == currentDID {
          // For current account, we can get handle directly
          handle = try? await client.getHandle()
          // Also store it for future use
          if let handle = handle {
            storeHandle(handle, for: account.did)
          }
        } else {
          // For other accounts, get from stored handles
          handle = getStoredHandle(for: account.did)
        }

          let isActive = account.did == currentDID
          accountInfos.append(AccountInfo(did: account.did, handle: handle, isActive: isActive))
      }

      // Update state
      availableAccounts = accountInfos
  }

  /// Switch to a different account
  @MainActor
  func switchToAccount(did: String) async throws {
    guard let client = client else {
      throw AuthError.clientNotInitialized
    }

    if case .authenticated(let currentDid) = state, currentDid == did {
      logger.info("Already using account with DID: \(did)")
      return
    }

    logger.info("Switching to account with DID: \(did)")
    isSwitchingAccount = true

    do {
      // First update state to show we're doing something
      updateState(.initializing)

      // Switch account in client
      try await client.switchToAccount(did: did)

        // Get new account info
        let newDid = try await client.getDid()
        self.handle = try await client.getHandle()

        // Update state
        updateState(.authenticated(userDID: newDid))
        logger.info(
          "Successfully switched to account: \(self.handle ?? "unknown") with DID: \(newDid)")
    } catch {
      logger.error("Error switching accounts: \(error.localizedDescription)")
      updateState(.error(message: "Failed to switch accounts: \(error.localizedDescription)"))
      throw error
    }

    isSwitchingAccount = false
    // Refresh account list after switching
    await refreshAvailableAccounts()
  }

  /// Add a new account
  @MainActor
  func addAccount(handle: String) async throws -> URL {
    logger.info("Adding new account with handle: \(handle)")

    // Ensure client exists
    guard let client = client else {
      let error = AuthError.clientNotInitialized
      updateState(.error(message: error.localizedDescription))
      throw error
    }

    // Generate OAuth URL without timeout wrapper
    do {
      // Check for task cancellation
      try Task.checkCancellation()
      
      // Apply timeout only to the network operation
      let authURL = try await withTimeout(timeout: networkTimeout) {
        try await client.startOAuthFlow(identifier: handle)
      }
      self.logger.debug("OAuth URL generated for new account: \(authURL)")

      // Update state
      updateState(.authenticating(progress: .openingBrowser))

      return authURL
    } catch {
      // Handle specific error types
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
  @MainActor
  func configureBiometricAuthentication() async {
    let context = LAContext()
    var error: NSError?
    
    let isAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    
    if isAvailable {
      biometricType = context.biometryType
        logger.info("Biometric authentication available: \(self.biometricType.description)")
      
      // Check if user has enabled biometric auth for this app
      biometricAuthEnabled = await getBiometricAuthPreference()
    } else {
      biometricType = .none
      biometricAuthEnabled = false
      if let error = error {
        logger.warning("Biometric authentication not available: \(error.localizedDescription)")
      } else {
        logger.info("Biometric authentication not available on this device")
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
      // Test biometric authentication before enabling
      let success = await authenticateWithBiometrics(reason: "Enable biometric authentication for Catbird")
      if success {
        biometricAuthEnabled = true
        await saveBiometricAuthPreference(enabled: true)
        logger.info("Biometric authentication enabled")
      } else {
        logger.warning("Failed to enable biometric authentication")
        // Keep biometricAuthEnabled as false, lastBiometricError is already set
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
  /// - Parameter event: The progress event that occurred
  func authenticationProgress(_ event: AuthProgressEvent) async {
    // Map Petrel's progress events to our AuthProgress enum
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
    
    // Update state on main actor
    await MainActor.run {
      self.updateState(.authenticating(progress: progress))
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
