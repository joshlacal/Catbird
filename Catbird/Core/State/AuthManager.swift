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
    guard newState != state else { return }  // Avoid duplicate updates

    logger.debug("Updating auth state: \(String(describing: self.state)) -> \(String(describing: newState))")
      
    // To ensure SwiftUI detects the state change properly, we update on the MainActor
    Task { @MainActor in
      // This explicit task and temporary variable ensures proper invalidation
      // of SwiftUI's dependency tracking system
      let _ = self.state
      self.state = newState
//        logger.debug("State change from \(previousState) to \(self.state) completed")
      
      // Also emit through the continuation for other observers
      stateSubject.continuation.yield(newState)
    }
  }

  // MARK: - Public API

  /// Initialize the client and check authentication state
  @MainActor
  func initialize() async {
    logger.info("Initializing authentication system")

    // Set initializing state immediately
    updateState(.initializing)

    // Create client if needed
    if client == nil {
      logger.info("Creating ATProtoClient")
      do {
        client = await ATProtoClient(
          authMethod: .oauth,
          oauthConfig: oauthConfig,
          namespace: "blue.catbird",
          environment: .production
        )
        logger.debug("ATProtoClient created successfully")
      } catch {
        logger.error("Failed to create ATProtoClient: \(error.localizedDescription)")
        updateState(.error(message: "Failed to initialize client: \(error.localizedDescription)"))
        return
      }
    }

    // Check if we already have a valid session
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
        _ = try? await client.refreshToken()
      }
      
      // After potential refresh, check session validity
      let hasValidSession = await client.hasValidSession()
      
      if hasValidSession {
      // Get user DID
      do {
        let did = try await client.getDid()
        self.handle = try await client.getHandle()
        logger.info("User is authenticated with DID: \(did)")

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
      logger.warning("Received callback in unexpected state: \(String(describing: self.state))")
      // Continue anyway, but log the issue
    }

    // Ensure client exists
    guard let client = client else {
      let error = AuthError.clientNotInitialized
      updateState(.error(message: error.localizedDescription))
      throw error
    }

    // Handle callback
    do {
      // Process callback with client
      try await client.handleOAuthCallback(url: url)
      logger.info("OAuth callback processed successfully")
      
      // Explicitly refresh token to ensure we have the latest
      let refreshResult = try? await client.refreshToken()
      logger.info("Token refresh result: \(refreshResult == true ? "success" : "failed or not needed")")

      // Verify session is valid after the refresh attempt
      let hasValidSession = await client.hasValidSession()
      if !hasValidSession {
        logger.error("Session invalid after OAuth callback processing")
        let error = AuthError.invalidSession
        updateState(.error(message: error.localizedDescription))
        throw error
      }

      // Get user info
      let did = try await client.getDid()
      self.handle = try await client.getHandle()

      // Update state
      updateState(.authenticated(userDID: did))
      logger.info("Authentication successful for user \(self.handle ?? "unknown")")

    } catch {
      logger.error("Authentication failed: \(error.localizedDescription)")
      updateState(.error(message: "Authentication failed: \(error.localizedDescription)"))
      throw error
    }
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
