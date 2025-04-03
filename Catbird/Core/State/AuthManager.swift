import Foundation
import OSLog
import Petrel
import SwiftUI

/// Represents the current state of authentication
enum AuthState: Equatable {
  case initializing
  case unauthenticated
  case authenticating
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
}

/// Handles all authentication-related operations with a clean state machine approach
@Observable
final class AuthenticationManager {
  // MARK: - Properties

  private let logger = Logger(subsystem: "blue.catbird", category: "Authentication")

  // Current authentication state - the source of truth
  private(set) var state: AuthState = .initializing

  // State change handling with async streams
  @ObservationIgnored
  private let stateSubject = AsyncStream<AuthState>.makeStream()

  // The ATProtoClient used for authentication and API calls
  private(set) var client: ATProtoClient?

  // User information
  private(set) var handle: String?

  // Available accounts
   var availableAccounts: [AccountInfo] = [] // Removed private(set) as @Observable handles it
   var isSwitchingAccount = false // Removed private(set)

  // OAuth configuration
  private let oauthConfig = OAuthConfiguration(
    clientId: "https://catbird.blue/oauth/client-metadata.json",
    redirectUri: "https://catbird.blue/oauth/callback",
    scope: "atproto transition:generic transition:chat.bsky"
  )

  // MARK: - Initialization

  init() {
    logger.debug("AuthenticationManager initialized")
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
    
  // MARK: - Public API

  /// Initialize the client and check authentication state
  @MainActor
  func initialize() async {
    logger.info("Initializing authentication system")
    updateState(.initializing)

    if client == nil {
      logger.info("ATTEMPTING to create ATProtoClient...")  // More specific log
      // Add log immediately before
      logger.debug(">>> Calling await ATProtoClient(...)")

      // Assuming initializer doesn't throw based on compiler error
      client = await ATProtoClient(
        authMethod: .oauth,
        oauthConfig: oauthConfig,
        namespace: "blue.catbird",
        environment: .production,
        userAgent: "Catbird/1.0"
      )

      // Check if client creation succeeded (if it returns optional or has an error state)
      // This part might need adjustment based on ATProtoClient's actual non-throwing failure mechanism
      if client == nil {
          logger.critical("❌❌❌ FAILED to create ATProtoClient (initializer did not throw but returned nil or failed internally) ❌❌❌")
          updateState(.error(message: "Failed to initialize client"))
          return // Exit early
      } else {
          // Add log immediately after *successful* creation
          logger.info("✅✅✅ ATProtoClient CREATED SUCCESSFULLY ✅✅✅")  // Make it stand out
      }

    } else {
      logger.info("ATProtoClient already exists.")
    }

    // Log state *before* checking auth
    logger.debug(
      "Client state before checkAuthenticationState: \(self.client == nil ? "NIL" : "Exists")")
    await checkAuthenticationState()
  }

  /// Check the current authentication state
  @MainActor
  func checkAuthenticationState() async {
    guard let client = client else {
      updateState(.unauthenticated)
      return
    }

    logger.debug("Checking authentication state")

    do {
      // First, try to refresh token if it exists
      if await client.hasValidSession() {
        // Try refreshing the token explicitly
        do {
          _ = try await client.refreshToken()
        } catch {
          logger.warning("Token refresh failed, continuing: \(error.localizedDescription)")
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

          // Update state properly through the state update method
          await MainActor.run {
            updateState(.authenticated(userDID: did))
            logger.info("Auth state updated to authenticated via proper channels")

            // Double check the state was updated properly
            logger.info("Current state after update: \(String(describing:self.state))")
          }
        } catch {
          logger.error("Error fetching user identity: \(error.localizedDescription)")
          updateState(.unauthenticated)
        }
      } else {
        logger.info("No valid session found")
        updateState(.unauthenticated)
      }
    } catch let error {
      logger.error("Error during authentication state check: \(error.localizedDescription)")
      updateState(.unauthenticated)
    }
  }

  /// Start the OAuth authentication flow
  @MainActor
  func login(handle: String) async throws -> URL {
    logger.info("Starting OAuth flow for handle: \(handle)")

    // Update state
    updateState(.authenticating)

    // Ensure client exists
    guard let client = client else {
      let error = AuthError.clientNotInitialized
      updateState(.error(message: error.localizedDescription))
      throw error
    }

    // Start OAuth flow
    do {
      let authURL = try await client.startOAuthFlow(identifier: handle)
      logger.debug("OAuth URL generated: \(authURL)")
      return authURL
    } catch {
      logger.error("Failed to start OAuth flow: \(error.localizedDescription)")
      updateState(.error(message: "Failed to start login: \(error.localizedDescription)"))
      throw error
    }
  }

  /// Handle the OAuth callback after web authentication
  @MainActor
  func handleCallback(_ url: URL) async throws {
    logger.info("Processing OAuth callback")

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

    // Handle callback - Propagating errors via function signature
    // Process callback with client
    try await client.handleOAuthCallback(url: url)
    logger.info("OAuth callback processed successfully")

    // Explicitly refresh token to ensure we have the latest
    // Using try? as failure here might not be critical for the whole callback process
    let refreshResult = try? await client.refreshToken()
    logger.info(
      "Token refresh result: \(refreshResult == true ? "success" : "failed or not needed")")


    // Verify session is valid after the refresh attempt
    let hasValidSession = await client.hasValidSession()
    if !hasValidSession {
      logger.error("Session invalid after OAuth callback processing")
      let error = AuthError.invalidSession
      updateState(.error(message: error.localizedDescription))
      throw error // Propagate critical error
    }

    // Get user info
    let did = try await client.getDid() // Propagate error if this fails
    self.handle = try await client.getHandle() // Propagate error if this fails

    // Update state
    updateState(.authenticated(userDID: did))
    logger.info("Authentication successful for user \(self.handle ?? "unknown")")

  }

  /// Logout the current user
  @MainActor
  func logout() async {
    logger.info("Logging out user")

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

    // Clear user info
    handle = nil
  }

  /// Reset after an error
  @MainActor
  func resetError() {
    if case .error = state {
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

  /// Get list of all available accounts
  @MainActor
  func refreshAvailableAccounts() async {
    guard let client = client else {
      logger.warning("Cannot list accounts: client is nil")
      availableAccounts = []
      return
    }

    do {
      // Get current DID for marking active account
      var currentDID: String? = nil
      if case .authenticated(let did) = state {
        currentDID = did
      }

      // Get list of accounts from client
      let accounts = await client.listAccounts()
      logger.info("Found \(accounts.count) available accounts")

      // Build account info objects
      var accountInfos: [AccountInfo] = []

      for did in accounts {
        // Try to get handle for this account (may require switching to it temporarily)
        var handle: String? = nil

        if did == currentDID {
          // For current account, we can get handle directly
          handle = try? await client.getHandle()
        } else {
          // For other accounts, we'll need to get from stored configuration
          // Handle will be nil, but that's ok for now
        }

        let isActive = did == currentDID
        accountInfos.append(AccountInfo(did: did, handle: handle, isActive: isActive))
      }

      // Update state
      availableAccounts = accountInfos
    } catch {
      logger.error("Error listing accounts: \(error.localizedDescription)")
      availableAccounts = []
    }
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
      let success = try await client.switchToAccount(did: did)

      if success {
        // Get new account info
        let newDid = try await client.getDid()
        self.handle = try await client.getHandle()

        // Update state
        updateState(.authenticated(userDID: newDid))
        logger.info(
          "Successfully switched to account: \(self.handle ?? "unknown") with DID: \(newDid)")
      } else {
        throw AuthError.invalidSession
      }
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

    do {
      // Use client's addAccount method which handles preserving the current account
      let authURL = try await client.addAccount(identifier: handle)
      logger.debug("OAuth URL generated for new account: \(authURL)")

      // Update state
      updateState(.authenticating)

      return authURL
    } catch {
      logger.error("Failed to start OAuth flow for new account: \(error.localizedDescription)")
      updateState(.error(message: "Failed to add account: \(error.localizedDescription)"))
      throw error
    }
  }

  /// Remove an account
  @MainActor
  func removeAccount(did: String) async throws {
    guard let client = client else {
      throw AuthError.clientNotInitialized
    }

    logger.info("Removing account with DID: \(did)")

    // Remove the account using client method - Propagating errors via function signature
    try await client.removeAccount(did: did)

    // If this was the current account, state would have been updated by the client
    // Refresh our available accounts list
    await refreshAvailableAccounts()

    // Check if we need to update our state
    if case .authenticated(let currentDid) = state, currentDid == did {
      if let firstAccount = availableAccounts.first {
        // Switch to another account if available - Propagating errors
        try await switchToAccount(did: firstAccount.did)
      } else {
        // No accounts left, go to unauthenticated state
        updateState(.unauthenticated)
      }
    }

    logger.info("Successfully removed account with DID: \(did)")
  }

  /// Get current active account info
  @MainActor
  func getCurrentAccountInfo() async -> AccountInfo? {
    guard case .authenticated(let did) = state, let currentHandle = handle else {
      return nil
    }

    return AccountInfo(did: did, handle: currentHandle, isActive: true)
  }
}

// MARK: - Error Types

enum AuthError: Error, LocalizedError {
  case clientNotInitialized
  case invalidSession
  case invalidCredentials
  case networkError(Error)
  case badResponse(Int)
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
    case .unknown(let error):
      return "Unknown error: \(error.localizedDescription)"
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
