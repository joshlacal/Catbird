import AuthenticationServices
import CatbirdMLSCore
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

  /// Finite case label for safe, content-free logging
  var caseLabel: String {
    switch self {
    case .initializing: return "initializing"
    case .unauthenticated: return "unauthenticated"
    case .authenticating: return "authenticating"
    case .authenticated: return "authenticated"
    case .error: return "error"
    }
  }
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
/// Finite set of content-free log events for AuthenticationManager.
/// Guarantees at compile time that no DID, handle, URL, reason, token, or error text is emitted in auth logs.
public enum AuthLogEvent: Sendable, Equatable {
  case initialized
  case stateUpdated
  case autoLogoutDuplicateTrigger
  case autoLogoutTriggered
  case autoLogoutExpiredAccountStored
  case autoLogoutSkipAlertReauth
  case expiredAccountReauthMissingInfo
  case expiredAccountReauthMissingHandle
  case expiredAccountOAuthStarted
  case invalidDIDEncountered
  case systemInitializing
  case clientInitializing
  case clientCreated
  case clientCreationFailed
  case clientExists
  case checkingAuthState
  case checkAuthStateCancelled
  case authStateCheckAuthenticated
  case authStateCheckFailed
  case noValidSessionFound
  case tokenRefreshAttempt
  case tokenRefreshSuccessful
  case tokenRefreshReturnedFalse
  case tokenRefreshFailed
  case tokenRefreshAuthErrorDetected
  case tokenRefreshNetworkErrorRetrying
  case tokenRefreshExhausted
  case candidateAccountFound
  case candidateAccountMissing
  case expiredAccountInfoPrepared
  case sessionExpiredPromptingReauth
  case oauthFlowStarted
  case oauthFlowAttempt
  case oauthURLGenerated
  case oauthFlowAttemptFailed
  case oauthFlowNetworkErrorRetrying
  case oauthFlowFailed
  case e2ePasswordLoginStarted
  case e2eKeychainCleared
  case e2eClientCreated
  case e2eClientCreationFailed
  case e2ePasswordLoginAttempt
  case e2ePasswordLoginSuccess
  case e2ePasswordLoginFailed
  case e2eKeychainDeletedItem
  case e2eKeychainNoItems
  case e2eKeychainQueryFailed
  case callbackProcessingStarted
  case callbackURLDetails
  case callbackStateVerified
  case callbackUnexpectedState
  case callbackClientUnavailable
  case callbackClientAvailable
  case callbackTokenExchangeStarted
  case callbackTokenExchangeCompleted
  case callbackImmediateAPISuccess
  case callbackImmediateAPIFailed
  case callbackSessionInvalid
  case callbackSessionValid
  case callbackDIDResolved
  case callbackHandleResolved
  case callbackConnectivityCheckSuccess
  case callbackConnectivityCheckFailed
  case callbackCompleted
  case callbackFailed
  case gatewayCallbackProcessingStarted
  case gatewayCallbackClientInitializing
  case gatewayCallbackClientUnavailable
  case gatewayCallbackCompleted
  case gatewayCallbackFailed
  case logoutStarted
  case logoutSuccessful
  case logoutFailed
  case manualLogoutStateCleared
  case invalidHandleIgnored
  case accountOrderUpdated
  case profileDataCached
  case accountRemovalStarted
  case accountRemovalSuccessful
  case accountRemovalFailed
  case accountsListed
  case clientRecreatedForAccountOps
  case accountSwitchStarted
  case accountSwitchAlreadyInProgress
  case accountSwitchClientInitializing
  case accountSwitchClientUnavailable
  case accountSwitchAlreadyActive
  case accountSwitchProceeding
  case accountSwitchMLSCleanupStarted
  case accountSwitchMLSContextClosed
  case accountSwitchMLSCoreShutdownSuccess
  case accountSwitchMLSCoreShutdownWarning
  case accountSwitchMLSCoreShutdownTimeout
  case accountSwitchMLSCoreShutdownFailed
  case accountSwitchMLSCleanupTimedOut
  case accountSwitchDatabasePrewarmed
  case accountSwitchDatabasePrewarmFailed
  case accountSwitchClientSwitchCalled
  case accountSwitchClientSwitchCompleted
  case accountSwitchSessionInvalid
  case accountSwitchSessionValid
  case accountSwitchResolvedDIDMismatch
  case accountSwitchSuccessful
  case accountSwitchFailed
  case accountSwitchCompleted
  case addAccountStarted
  case addAccountOAuthURLGenerated
  case addAccountFailed
  case biometricAuthAvailable
  case biometricAuthNotAvailable
  case biometricAuthEnabled
  case biometricAuthEnableFailed
  case biometricAuthDisabled
  case biometricAuthSuccess
  case biometricAuthFailed
  case biometricAuthCancelled
  case biometricAuthFallback
  case biometricAuthNotEnrolled
  case biometricAuthLockout
  case biometricAuthError
  case networkRecoveryAttemptStarted
  case networkRecoveryClientUnavailable
  case networkRecoverySuccessful
  case networkRecoveryFailed
  case authenticationRequiredReceived
  case authenticationRequiredDuplicateTrigger
  case authenticationRequiredSkipAlert
  case catastrophicAuthFailure
  case catastrophicDuplicateTrigger
  case catastrophicSkipAlert
  case circuitBreakerOpen

  public var staticCode: String {
    switch self {
    case .initialized: "AUTH_INITIALIZED"
    case .stateUpdated: "AUTH_STATE_UPDATED"
    case .autoLogoutDuplicateTrigger: "AUTH_AUTO_LOGOUT_DUPLICATE_TRIGGER"
    case .autoLogoutTriggered: "AUTH_AUTO_LOGOUT_TRIGGERED"
    case .autoLogoutExpiredAccountStored: "AUTH_AUTO_LOGOUT_EXPIRED_ACCOUNT_STORED"
    case .autoLogoutSkipAlertReauth: "AUTH_AUTO_LOGOUT_SKIP_ALERT_REAUTH"
    case .expiredAccountReauthMissingInfo: "AUTH_REAUTH_MISSING_EXPIRED_ACCOUNT"
    case .expiredAccountReauthMissingHandle: "AUTH_REAUTH_MISSING_HANDLE"
    case .expiredAccountOAuthStarted: "AUTH_REAUTH_OAUTH_STARTED"
    case .invalidDIDEncountered: "AUTH_INVALID_DID"
    case .systemInitializing: "AUTH_SYSTEM_INITIALIZING"
    case .clientInitializing: "AUTH_CLIENT_INITIALIZING"
    case .clientCreated: "AUTH_CLIENT_CREATED"
    case .clientCreationFailed: "AUTH_CLIENT_CREATION_FAILED"
    case .clientExists: "AUTH_CLIENT_EXISTS"
    case .checkingAuthState: "AUTH_CHECKING_STATE"
    case .checkAuthStateCancelled: "AUTH_CHECK_STATE_CANCELLED"
    case .authStateCheckAuthenticated: "AUTH_CHECK_STATE_AUTHENTICATED"
    case .authStateCheckFailed: "AUTH_CHECK_STATE_FAILED"
    case .noValidSessionFound: "AUTH_NO_VALID_SESSION"
    case .tokenRefreshAttempt: "AUTH_TOKEN_REFRESH_ATTEMPT"
    case .tokenRefreshSuccessful: "AUTH_TOKEN_REFRESH_SUCCESSFUL"
    case .tokenRefreshReturnedFalse: "AUTH_TOKEN_REFRESH_RETURNED_FALSE"
    case .tokenRefreshFailed: "AUTH_TOKEN_REFRESH_FAILED"
    case .tokenRefreshAuthErrorDetected: "AUTH_TOKEN_REFRESH_AUTH_ERROR"
    case .tokenRefreshNetworkErrorRetrying: "AUTH_TOKEN_REFRESH_RETRYING"
    case .tokenRefreshExhausted: "AUTH_TOKEN_REFRESH_EXHAUSTED"
    case .candidateAccountFound: "AUTH_CANDIDATE_ACCOUNT_FOUND"
    case .candidateAccountMissing: "AUTH_CANDIDATE_ACCOUNT_MISSING"
    case .expiredAccountInfoPrepared: "AUTH_EXPIRED_ACCOUNT_PREPARED"
    case .sessionExpiredPromptingReauth: "AUTH_SESSION_EXPIRED_PROMPTING_REAUTH"
    case .oauthFlowStarted: "AUTH_OAUTH_FLOW_STARTED"
    case .oauthFlowAttempt: "AUTH_OAUTH_FLOW_ATTEMPT"
    case .oauthURLGenerated: "AUTH_OAUTH_URL_GENERATED"
    case .oauthFlowAttemptFailed: "AUTH_OAUTH_FLOW_ATTEMPT_FAILED"
    case .oauthFlowNetworkErrorRetrying: "AUTH_OAUTH_FLOW_RETRYING"
    case .oauthFlowFailed: "AUTH_OAUTH_FLOW_FAILED"
    case .e2ePasswordLoginStarted: "AUTH_E2E_LOGIN_STARTED"
    case .e2eKeychainCleared: "AUTH_E2E_KEYCHAIN_CLEARED"
    case .e2eClientCreated: "AUTH_E2E_CLIENT_CREATED"
    case .e2eClientCreationFailed: "AUTH_E2E_CLIENT_CREATION_FAILED"
    case .e2ePasswordLoginAttempt: "AUTH_E2E_LOGIN_ATTEMPT"
    case .e2ePasswordLoginSuccess: "AUTH_E2E_LOGIN_SUCCESS"
    case .e2ePasswordLoginFailed: "AUTH_E2E_LOGIN_FAILED"
    case .e2eKeychainDeletedItem: "AUTH_E2E_KEYCHAIN_DELETED_ITEM"
    case .e2eKeychainNoItems: "AUTH_E2E_KEYCHAIN_NO_ITEMS"
    case .e2eKeychainQueryFailed: "AUTH_E2E_KEYCHAIN_QUERY_FAILED"
    case .callbackProcessingStarted: "AUTH_CALLBACK_PROCESSING_STARTED"
    case .callbackURLDetails: "AUTH_CALLBACK_URL_DETAILS"
    case .callbackStateVerified: "AUTH_CALLBACK_STATE_VERIFIED"
    case .callbackUnexpectedState: "AUTH_CALLBACK_UNEXPECTED_STATE"
    case .callbackClientUnavailable: "AUTH_CALLBACK_CLIENT_UNAVAILABLE"
    case .callbackClientAvailable: "AUTH_CALLBACK_CLIENT_AVAILABLE"
    case .callbackTokenExchangeStarted: "AUTH_CALLBACK_TOKEN_EXCHANGE_STARTED"
    case .callbackTokenExchangeCompleted: "AUTH_CALLBACK_TOKEN_EXCHANGE_COMPLETED"
    case .callbackImmediateAPISuccess: "AUTH_CALLBACK_IMMEDIATE_API_SUCCESS"
    case .callbackImmediateAPIFailed: "AUTH_CALLBACK_IMMEDIATE_API_FAILED"
    case .callbackSessionInvalid: "AUTH_CALLBACK_SESSION_INVALID"
    case .callbackSessionValid: "AUTH_CALLBACK_SESSION_VALID"
    case .callbackDIDResolved: "AUTH_CALLBACK_DID_RESOLVED"
    case .callbackHandleResolved: "AUTH_CALLBACK_HANDLE_RESOLVED"
    case .callbackConnectivityCheckSuccess: "AUTH_CALLBACK_CONNECTIVITY_SUCCESS"
    case .callbackConnectivityCheckFailed: "AUTH_CALLBACK_CONNECTIVITY_FAILED"
    case .callbackCompleted: "AUTH_CALLBACK_COMPLETED"
    case .callbackFailed: "AUTH_CALLBACK_FAILED"
    case .gatewayCallbackProcessingStarted: "AUTH_GATEWAY_CALLBACK_STARTED"
    case .gatewayCallbackClientInitializing: "AUTH_GATEWAY_CALLBACK_CLIENT_INITIALIZING"
    case .gatewayCallbackClientUnavailable: "AUTH_GATEWAY_CALLBACK_CLIENT_UNAVAILABLE"
    case .gatewayCallbackCompleted: "AUTH_GATEWAY_CALLBACK_COMPLETED"
    case .gatewayCallbackFailed: "AUTH_GATEWAY_CALLBACK_FAILED"
    case .logoutStarted: "AUTH_LOGOUT_STARTED"
    case .logoutSuccessful: "AUTH_LOGOUT_SUCCESSFUL"
    case .logoutFailed: "AUTH_LOGOUT_FAILED"
    case .manualLogoutStateCleared: "AUTH_MANUAL_LOGOUT_STATE_CLEARED"
    case .invalidHandleIgnored: "AUTH_INVALID_HANDLE_IGNORED"
    case .accountOrderUpdated: "AUTH_ACCOUNT_ORDER_UPDATED"
    case .profileDataCached: "AUTH_PROFILE_DATA_CACHED"
    case .accountRemovalStarted: "AUTH_ACCOUNT_REMOVAL_STARTED"
    case .accountRemovalSuccessful: "AUTH_ACCOUNT_REMOVAL_SUCCESSFUL"
    case .accountRemovalFailed: "AUTH_ACCOUNT_REMOVAL_FAILED"
    case .accountsListed: "AUTH_ACCOUNTS_LISTED"
    case .clientRecreatedForAccountOps: "AUTH_CLIENT_RECREATED_FOR_ACCOUNT_OPS"
    case .accountSwitchStarted: "AUTH_SWITCH_STARTED"
    case .accountSwitchAlreadyInProgress: "AUTH_SWITCH_ALREADY_IN_PROGRESS"
    case .accountSwitchClientInitializing: "AUTH_SWITCH_CLIENT_INITIALIZING"
    case .accountSwitchClientUnavailable: "AUTH_SWITCH_CLIENT_UNAVAILABLE"
    case .accountSwitchAlreadyActive: "AUTH_SWITCH_ALREADY_ACTIVE"
    case .accountSwitchProceeding: "AUTH_SWITCH_PROCEEDING"
    case .accountSwitchMLSCleanupStarted: "AUTH_SWITCH_MLS_CLEANUP_STARTED"
    case .accountSwitchMLSContextClosed: "AUTH_SWITCH_MLS_CONTEXT_CLOSED"
    case .accountSwitchMLSCoreShutdownSuccess: "AUTH_SWITCH_MLS_CORE_SHUTDOWN_SUCCESS"
    case .accountSwitchMLSCoreShutdownWarning: "AUTH_SWITCH_MLS_CORE_SHUTDOWN_WARNING"
    case .accountSwitchMLSCoreShutdownTimeout: "AUTH_SWITCH_MLS_CORE_SHUTDOWN_TIMEOUT"
    case .accountSwitchMLSCoreShutdownFailed: "AUTH_SWITCH_MLS_CORE_SHUTDOWN_FAILED"
    case .accountSwitchMLSCleanupTimedOut: "AUTH_SWITCH_MLS_CLEANUP_TIMED_OUT"
    case .accountSwitchDatabasePrewarmed: "AUTH_SWITCH_DB_PREWARMED"
    case .accountSwitchDatabasePrewarmFailed: "AUTH_SWITCH_DB_PREWARM_FAILED"
    case .accountSwitchClientSwitchCalled: "AUTH_SWITCH_CLIENT_SWITCH_CALLED"
    case .accountSwitchClientSwitchCompleted: "AUTH_SWITCH_CLIENT_SWITCH_COMPLETED"
    case .accountSwitchSessionInvalid: "AUTH_SWITCH_SESSION_INVALID"
    case .accountSwitchSessionValid: "AUTH_SWITCH_SESSION_VALID"
    case .accountSwitchResolvedDIDMismatch: "AUTH_SWITCH_RESOLVED_DID_MISMATCH"
    case .accountSwitchSuccessful: "AUTH_SWITCH_SUCCESSFUL"
    case .accountSwitchFailed: "AUTH_SWITCH_FAILED"
    case .accountSwitchCompleted: "AUTH_SWITCH_COMPLETED"
    case .addAccountStarted: "AUTH_ADD_ACCOUNT_STARTED"
    case .addAccountOAuthURLGenerated: "AUTH_ADD_ACCOUNT_OAUTH_URL_GENERATED"
    case .addAccountFailed: "AUTH_ADD_ACCOUNT_FAILED"
    case .biometricAuthAvailable: "AUTH_BIOMETRIC_AVAILABLE"
    case .biometricAuthNotAvailable: "AUTH_BIOMETRIC_NOT_AVAILABLE"
    case .biometricAuthEnabled: "AUTH_BIOMETRIC_ENABLED"
    case .biometricAuthEnableFailed: "AUTH_BIOMETRIC_ENABLE_FAILED"
    case .biometricAuthDisabled: "AUTH_BIOMETRIC_DISABLED"
    case .biometricAuthSuccess: "AUTH_BIOMETRIC_SUCCESS"
    case .biometricAuthFailed: "AUTH_BIOMETRIC_FAILED"
    case .biometricAuthCancelled: "AUTH_BIOMETRIC_CANCELLED"
    case .biometricAuthFallback: "AUTH_BIOMETRIC_FALLBACK"
    case .biometricAuthNotEnrolled: "AUTH_BIOMETRIC_NOT_ENROLLED"
    case .biometricAuthLockout: "AUTH_BIOMETRIC_LOCKOUT"
    case .biometricAuthError: "AUTH_BIOMETRIC_ERROR"
    case .networkRecoveryAttemptStarted: "AUTH_NETWORK_RECOVERY_STARTED"
    case .networkRecoveryClientUnavailable: "AUTH_NETWORK_RECOVERY_CLIENT_UNAVAILABLE"
    case .networkRecoverySuccessful: "AUTH_NETWORK_RECOVERY_SUCCESSFUL"
    case .networkRecoveryFailed: "AUTH_NETWORK_RECOVERY_FAILED"
    case .authenticationRequiredReceived: "AUTH_AUTHENTICATION_REQUIRED_RECEIVED"
    case .authenticationRequiredDuplicateTrigger: "AUTH_AUTHENTICATION_REQUIRED_DUPLICATE"
    case .authenticationRequiredSkipAlert: "AUTH_AUTHENTICATION_REQUIRED_SKIP_ALERT"
    case .catastrophicAuthFailure: "AUTH_CATASTROPHIC_FAILURE"
    case .catastrophicDuplicateTrigger: "AUTH_CATASTROPHIC_DUPLICATE"
    case .catastrophicSkipAlert: "AUTH_CATASTROPHIC_SKIP_ALERT"
    case .circuitBreakerOpen: "AUTH_CIRCUIT_BREAKER_OPEN"
    }
  }
}

/// Log handler interface for AuthenticationManager
public protocol AuthLogHandler: Sendable {
  func log(level: OSLogType, event: AuthLogEvent)
}

/// Default production log handler that logs content-free static codes to OSLog
public struct DefaultAuthLogHandler: AuthLogHandler {
  private let osLogger: Logger

  public init(osLogger: Logger = Logger(subsystem: "blue.catbird", category: "Authentication")) {
    self.osLogger = osLogger
  }

  public func log(level: OSLogType, event: AuthLogEvent) {
    let code = event.staticCode
    switch level {
    case .debug:
      osLogger.debug("\(code)")
    case .info:
      osLogger.info("\(code)")
    case .error:
      osLogger.error("\(code)")
    case .fault:
      osLogger.fault("\(code)")
    default:
      osLogger.log("\(code)")
    }
    AuthenticationManager.capturedLogHook?(code)
  }
}

/// Logger wrapper for AuthenticationManager accepting only finite AuthLogEvent cases
struct AuthLogger: Sendable {
  let handler: any AuthLogHandler
  private let osLogger = Logger(subsystem: "blue.catbird", category: "Authentication")

  init(handler: any AuthLogHandler = DefaultAuthLogHandler()) {
    self.handler = handler
  }

  func debug(_ event: AuthLogEvent) {
    handler.log(level: .debug, event: event)
  }

  func info(_ event: AuthLogEvent) {
    handler.log(level: .info, event: event)
  }

  func warning(_ event: AuthLogEvent) {
    handler.log(level: .default, event: event)
  }

  func error(_ event: AuthLogEvent) {
    handler.log(level: .error, event: event)
  }

  func critical(_ event: AuthLogEvent) {
    handler.log(level: .fault, event: event)
  }

  func debug(_ message: String) {
    osLogger.debug("\(message)")
  }

  func info(_ message: String) {
    osLogger.info("\(message)")
  }

  func warning(_ message: String) {
    osLogger.warning("\(message)")
  }

  func error(_ message: String) {
    osLogger.error("\(message)")
  }

  func critical(_ message: String) {
    osLogger.fault("\(message)")
  }
}

/// Injectable dependency overrides for AuthenticationManager unit testing.
public struct AuthenticationDependencyOverrides: Sendable {
  public var startOAuth: (@Sendable (ATProtoClient, String, String, String) async throws -> URL)?
  public var prepareGatewayLogin: (@Sendable (URL) async throws -> URL)?
  public var handleOAuthCallback: (@Sendable (ATProtoClient, URL) async throws -> Void)?
  public var redeemGatewayCallback: (@Sendable (URL) async throws -> String)?
  public var switchAccount: (@Sendable (ATProtoClient, String) async throws -> Void)?

  public init(
    startOAuth: (@Sendable (ATProtoClient, String, String, String) async throws -> URL)? = nil,
    prepareGatewayLogin: (@Sendable (URL) async throws -> URL)? = nil,
    handleOAuthCallback: (@Sendable (ATProtoClient, URL) async throws -> Void)? = nil,
    redeemGatewayCallback: (@Sendable (URL) async throws -> String)? = nil,
    switchAccount: (@Sendable (ATProtoClient, String) async throws -> Void)? = nil
  ) {
    self.startOAuth = startOAuth
    self.prepareGatewayLogin = prepareGatewayLogin
    self.handleOAuthCallback = handleOAuthCallback
    self.redeemGatewayCallback = redeemGatewayCallback
    self.switchAccount = switchAccount
  }
}

/// Handles all authentication-related operations with a clean state machine approach
@Observable
final class AuthenticationManager: AuthProgressDelegate {
  static let gatewayURL = CatbirdGatewayConfiguration.current.origin

  // MARK: - Properties
  /// Optional capture hook for privacy testing of auth logs.
  /// When non-nil, every message logged by AuthenticationManager is forwarded to this closure.
  nonisolated(unsafe) static var capturedLogHook: (@Sendable (String) -> Void)?

  fileprivate let logger: AuthLogger
  @ObservationIgnored
  private let dependencyOverrides: AuthenticationDependencyOverrides
  // Authentication timeout configuration
  private let authenticationTimeout: TimeInterval = 60.0  // 60 seconds
  private let networkTimeout: TimeInterval = 30.0  // 30 seconds for individual network calls

  // Current authentication state - the source of truth
  private(set) var state: AuthState = .initializing

  // Handle storage for multi-account support
  private let handleStorageKey = "catbird_account_handles"
  private let accountOrderKey = "catbird_account_order"
  private let userDefaults: UserDefaults
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

  @ObservationIgnored
  private let gatewayOAuthExchange = GatewayOAuthExchange(
    gatewayURL: AuthenticationManager.gatewayURL,
    callbackURL: URL(string: "https://catbird.blue/oauth/callback")!
  )

  // MARK: - Progressive Gateway Permissions

  /// Continuity snapshot capturing authentication identity and context before and across upgrade steps.
  private struct GatewayPermissionContinuitySnapshot {
    let did: String
    let client: ATProtoClient
    let appState: AppState?
    let appStateUserDID: String?
  }

  /// Struct representing an in-flight gateway permission upgrade request.
  private struct InFlightPermissionRequest {
    let id: UUID
    let permission: GatewayPermission
    let did: String
    let task: Task<Void, Error>
  }

/// Thread-safe cancellation-aware waiter that awaits a shared Task without cancelling it upon waiter cancellation.
private final class CoalescedPermissionWaiter: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Error>?
  private var isResolved = false

  func wait(for task: Task<Void, Error>) async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        self.lock.lock()
        if Task.isCancelled || self.isResolved {
          self.isResolved = true
          self.lock.unlock()
          continuation.resume(throwing: GatewayPermissionError.cancelled)
          return
        }
        self.continuation = continuation
        self.lock.unlock()

        Task {
          do {
            try await task.value
            self.resolve(with: .success(()))
          } catch {
            self.resolve(with: .failure(error))
          }
        }
      }
    } onCancel: {
      self.resolve(with: .failure(GatewayPermissionError.cancelled))
    }
  }

  private func resolve(with result: Result<Void, Error>) {
    lock.lock()
    guard !isResolved else {
      lock.unlock()
      return
    }
    isResolved = true
    let cont = continuation
    continuation = nil
    lock.unlock()
    if let cont {
      switch result {
      case .success:
        cont.resume()
      case .failure(let error):
        cont.resume(throwing: error)
      }
    }
  }
}

  @ObservationIgnored
  private var inFlightPermission: InFlightPermissionRequest?

  // Internal test / dependency injection hooks
  @ObservationIgnored
  var fetchGrantedScopesHook: ((_ did: String?) async throws -> Set<String>)?
  @ObservationIgnored
  var startGatewayScopeUpgradeHook: ((_ requesting: Set<String>, _ expectedDID: String, _ callbackURL: URL) async throws -> URL)?
  @ObservationIgnored
  var completeGatewayScopeUpgradeHook: ((_ callbackURL: URL, _ expectedDID: String) async throws -> Set<String>)?

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
      guard let result = try await group.next() else { throw AuthError.timeout }
      return result
    }
  }

  // MARK: - Initialization

  init(
    userDefaults: UserDefaults = .standard,
    logHandler: any AuthLogHandler = DefaultAuthLogHandler(),
    dependencyOverrides: AuthenticationDependencyOverrides = .init()
  ) {
    self.userDefaults = userDefaults
    self.logger = AuthLogger(handler: logHandler)
    self.dependencyOverrides = dependencyOverrides
    logger.debug(.initialized)
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
  #if DEBUG
  nonisolated(unsafe) static var switchAccountOverride: (@Sendable (String) async throws -> (did: String, handle: String))?

  func resetDebounceForTesting() {
    self.isHandlingAuthExpiration = false
  }
  #endif

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
      logger.warning(.autoLogoutDuplicateTrigger)
      return
    }

    logger.error(.autoLogoutTriggered)

    // Mark that we're handling an expiration to block further triggers
    isHandlingAuthExpiration = true

    if let did {
      expiredAccountInfo = makeExpiredAccountInfo(for: did)
      logger.info(.autoLogoutExpiredAccountStored)
    }

    if case .authenticated(let appState) = AppStateManager.shared.lifecycle {
      await appState.notificationManager.cleanupNotifications(previousClient: client)
    }

    // Clear handle if this was the active account (check before state change)
    let wasActiveAccount =
      if let did, case .authenticated(let current) = state {
        current == did
      } else {
        false
      }

    let departingDID = did ?? state.userDID
    if let departingDID {
      NotificationCenter.default.post(
        name: .circleAccountInvalidated,
        object: nil,
        userInfo: ["accountDID": departingDID]
      )
    }

    updateState(.unauthenticated)
    if let departingDID {
      await CircleFeedCache.shared.purge(accountDID: departingDID)
      await CircleMediaLoader.shared.purge(accountDID: departingDID)
      await CircleNotificationCache.shared.purge(accountDID: departingDID)
    }
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
          return "You were signed out. Please sign in again."
        }
      }()
      pendingAuthAlert = AuthAlert(title: "Signed Out", message: reasonText)
    } else {
      // Clear any existing alert so it doesn't block the sheet
      pendingAuthAlert = nil
      logger.info(.autoLogoutSkipAlertReauth)
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
    cancelInFlightPermissionUpgrade()
    guard let expiredAccount = expiredAccountInfo else {
      logger.warning(.expiredAccountReauthMissingInfo)
      return nil
    }

    guard let handle = expiredAccount.loginHandle else {
      logger.warning(.expiredAccountReauthMissingHandle)
      return nil
    }

    logger.info(.expiredAccountOAuthStarted)
    return try await login(handle: handle)
  }

  /// Update the authentication state and emit the change
  /// NOTE: State emission is synchronous to prevent race conditions between state property
  /// update and observer notification. Wrapping in Task created timing gaps that caused
  /// double state transitions on OAuth login.
  @MainActor
  func updateState(_ newState: AuthState) {
    guard newState != state else { return }
    logger.debug(.stateUpdated)
    self.state = newState
    // Emit synchronously - no Task wrapper to eliminate race windows
    stateSubject.continuation.yield(newState)
  }

  #if DEBUG
  @MainActor
  func setClientForTesting(_ client: ATProtoClient?) {
    self.client = client
  }

  @MainActor
  func setAuthenticatedForTesting(did: String, client: ATProtoClient? = nil) {
    if let client = client {
      self.client = client
    }
    updateState(.authenticated(userDID: did))
  }
  #endif

  /// Validate a DID coming from user input or client session state.
  private func validatedUserDID(_ rawDID: String, source: String) throws -> String {
    let did = rawDID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !did.isEmpty, did.hasPrefix("did:") else {
      logger.critical(.invalidDIDEncountered)
      throw AuthError.invalidUserDID
    }
    return did
  }

  // MARK: - Public API

  /// Initialize the client and check authentication state
  @MainActor
  func initialize() async {
    logger.info(.systemInitializing)
    isAuthenticationCancelled = false
    updateState(.initializing)

    if client == nil {
      logger.info(.clientInitializing)
      updateState(.authenticating(progress: .initializingClient))
      logger.debug(.clientInitializing)
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

#if DEBUG
        let newClient = await Task.detached(priority: .userInitiated) {
          try? await ATProtoClient(
            oauthConfig: oauthCfg,
            namespace: "blue.catbird",
            authMode: .gateway,
            gatewayURL: AuthenticationManager.gatewayURL,
            userAgent: "Catbird/1.0",
            bskyAppViewDID: appViewDID,
            bskyChatDID: chatDID,
            accessGroup: accessGroup
          )
        }.value
#else
      let newClient = await Task.detached(priority: .userInitiated) {
        try? await ATProtoClient(
          oauthConfig: oauthCfg,
          namespace: "blue.catbird",
          authMode: .gateway,
          gatewayURL: AuthenticationManager.gatewayURL,
          userAgent: "Catbird/1.0",
          bskyAppViewDID: appViewDID,
          bskyChatDID: chatDID,
          accessGroup: accessGroup
        )
      }.value
#endif
      // Update state on main actor
      client = newClient
      await client?.applicationDidBecomeActive()

      if client == nil {
        logger.critical(.clientCreationFailed)
        updateState(.error(message: "Failed to initialize client"))
        return
      } else {
        logger.info(.clientCreated)
        await client?.setFailureDelegate(self)
        if let client = client { await client.setAuthenticationDelegate(self) }
      }

    } else {
      logger.info(.clientExists)
      await client?.updateServiceDIDs(bskyAppViewDID: customAppViewDID, bskyChatDID: customChatDID)
    }

    logger.debug(.checkingAuthState)
    await checkAuthenticationState()
  }

  /// Check the current authentication state with enhanced token refresh
  @MainActor
  func checkAuthenticationState() async {
    guard !isAuthenticationCancelled else {
      logger.debug(.checkAuthStateCancelled)
      return
    }
    guard let client = client else {
      updateState(.unauthenticated)
      return
    }

    logger.debug(.checkingAuthState)
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
        logger.info(.authStateCheckAuthenticated)

        if let handle = self.handle {
          storeHandle(handle, for: userDid)
        }

        await MainActor.run {
          updateState(.authenticated(userDID: userDid))
          logger.info(.stateUpdated)
        }
      } catch {
        logger.error(.authStateCheckFailed)
        if !isAuthenticationCancelled {
          updateState(.unauthenticated)
        }
      }
    } else {
      logger.info(.noValidSessionFound)

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
        logger.debug(.tokenRefreshAttempt)
        let success = try await client.refreshToken()
        if success {
          logger.info(.tokenRefreshSuccessful)
          return true
        } else {
          logger.warning(.tokenRefreshReturnedFalse)
          lastError = AuthError.invalidSession
        }
      } catch {
        lastError = error
        logger.warning(.tokenRefreshFailed)

        if let nsError = error as NSError? {
          if nsError.code == 401 || nsError.code == 403 {
            logger.info(.tokenRefreshAuthErrorDetected)
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
              logger.info(.tokenRefreshNetworkErrorRetrying)
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
      logger.error(.tokenRefreshExhausted)
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
      logger.info(.candidateAccountFound)
    }

    // 2. Check the client's current account (this is the account that needs reauth, not just the first in order)
    if candidateDID == nil {
      if let currentAccount = await client.getCurrentAccount() {
        candidateDID = currentAccount.did
        logger.info(.candidateAccountFound)
      }
    }

    // 3. Check persistent account order (first item is naturally the best candidate if no active user)
    if candidateDID == nil {
      let order = getAccountOrder()
      if let firstDID = order.first, !firstDID.isEmpty {
        candidateDID = firstDID
        logger.info(.candidateAccountFound)
      }
    }

    // 4. Fallback: Ask client for its current DID (though likely nil if session expired)
    if candidateDID == nil {
      if let did = try? await client.getDid() {
        candidateDID = did
        logger.info(.candidateAccountFound)
      }
    }

    // 5. Fallback: Single account check
    if candidateDID == nil {
      let accounts = await client.listAccounts()
      if accounts.count == 1 {
        candidateDID = accounts.first?.did
        logger.info(.candidateAccountFound)
      } else if accounts.isEmpty {
        // Last resort: stored handles
        let stored = getStoredHandles()
        if stored.count == 1 {
          candidateDID = stored.keys.first
          logger.info(.candidateAccountFound)
        }
      }
    }

    guard let did = candidateDID else {
      logger.warning(.candidateAccountMissing)
      return
    }

    expiredAccountInfo = makeExpiredAccountInfo(for: did)
    logger.info(.expiredAccountInfoPrepared)

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
        expiredAccountInfo = makeExpiredAccountInfo(for: activeDID)
        logger.warning(.sessionExpiredPromptingReauth)
        return
      }

      // Fallback: try to infer a plausible account from locally-stored accounts/handles.
      await prepareExpiredAccountInfoForReauth(using: client)
      return
    }

    expiredAccountInfo = makeExpiredAccountInfo(for: did)
    logger.warning(.sessionExpiredPromptingReauth)
  }

  /// Start the OAuth authentication flow with improved error handling
  @MainActor
  func login(handle: String) async throws -> URL {
    logger.info(.oauthFlowStarted)

    currentAuthTask?.cancel()
    currentAuthTask = nil
    cancelInFlightPermissionUpgrade()
    isAuthenticationCancelled = false
    updateState(.authenticating(progress: .resolvingHandle(handle: handle)))

    if client == nil {
      logger.info(.clientInitializing)
      #if targetEnvironment(simulator)
        let accessGroup: String? = nil
      #else
        let accessGroup: String? = MLSKeychainManager.resolvedAccessGroup(
          suffix: "blue.catbird.shared")
      #endif

        #if DEBUG
          
      client = try? await ATProtoClient(
        oauthConfig: oauthConfig,
        namespace: "blue.catbird",
        authMode: .gateway,
        gatewayURL: AuthenticationManager.gatewayURL,
        userAgent: "Catbird/1.0",
        bskyAppViewDID: customAppViewDID,
        bskyChatDID: customChatDID,
        accessGroup: accessGroup
      )
        
        #else
        client = try? await ATProtoClient(
          oauthConfig: oauthConfig,
          namespace: "blue.catbird",
          authMode: .gateway,
          gatewayURL: AuthenticationManager.gatewayURL,
          userAgent: "Catbird/1.0",
          bskyAppViewDID: customAppViewDID,
          bskyChatDID: customChatDID,
          accessGroup: accessGroup
        )

        #endif
      await client?.applicationDidBecomeActive()
      await client?.setAuthProgressDelegate(self)
      await client?.setFailureDelegate(self)
      if let client = client { await client.setAuthenticationDelegate(self) }

    } else {
      logger.info(.clientExists)
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
          self.logger.debug(.oauthFlowAttempt)

          if attempt > 1 {
            await self.updateState(
              .authenticating(
                progress: .retrying(step: "OAuth setup", attempt: attempt, maxAttempts: maxRetries))
            )
          } else {
            await self.updateState(.authenticating(progress: .generatingAuthURL))
          }

          let authURL = try await withTimeout(timeout: networkTimeout) {
            if let startOAuth = self.dependencyOverrides.startOAuth {
              return try await startOAuth(client, handle, self.customAppViewDID, self.customChatDID)
            } else {
              // Pass custom service DIDs to OAuth flow
              return try await client.startOAuthFlow(
                identifier: handle,
                bskyAppViewDID: self.customAppViewDID,
                bskyChatDID: self.customChatDID
              )
            }
          }

          let boundAuthURL: URL
          if let prepare = self.dependencyOverrides.prepareGatewayLogin {
            boundAuthURL = try await prepare(authURL)
          } else {
            boundAuthURL = try await gatewayOAuthExchange.prepareLogin(authURL)
          }
          logger.info(.oauthURLGenerated)
          await self.updateState(.authenticating(progress: .openingBrowser))
          return boundAuthURL
        } catch {
          lastError = error
          self.logger.warning(.oauthFlowAttemptFailed)

          if let nsError = error as NSError? {
            if nsError.domain == NSURLErrorDomain
              && [
                NSURLErrorTimedOut,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
              ].contains(nsError.code)
            {
              if attempt < maxRetries {
                self.logger.info(.oauthFlowNetworkErrorRetrying)
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

      logger.error(.oauthFlowFailed)
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
    cancelInFlightPermissionUpgrade()
    logger.info(.e2ePasswordLoginStarted)
    
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
    logger.error(.e2eKeychainCleared)
    clearE2EKeychainData(accessGroup: accessGroup)
    
    // Create a separate legacy-mode client for password auth
    // If PDS URL is specified, use it directly as the base URL
    let baseURL = pdsURL ?? URL(string: "https://bsky.social")!
    logger.error(.e2eClientCreated)
    logger.error(.e2eClientCreated)
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
      logger.error(.e2eClientCreated)
    } catch {
      logger.error(.e2eClientCreationFailed)
      throw error
    }
    
    do {
      updateState(.authenticating(progress: .creatingSession))
      logger.error(.e2ePasswordLoginAttempt)
      let accountInfo = try await legacyClient.loginWithPassword(
        identifier: identifier,
        password: password,
        bskyAppViewDID: customAppViewDID,
        bskyChatDID: customChatDID
      )
      logger.error(.e2ePasswordLoginSuccess)
      
      let did = try validatedUserDID(accountInfo.did, source: "loginWithPasswordForE2E")
      logger.info(.e2ePasswordLoginSuccess)

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
      logger.error(.e2ePasswordLoginFailed)
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
            logger.info(.e2eKeychainDeletedItem)
          }
        }
      }
    } else if status == errSecItemNotFound {
      logger.info(.e2eKeychainNoItems)
    } else {
      logger.warning(.e2eKeychainQueryFailed)
    }
  }

  /// Handle the OAuth callback after web authentication with timeout support
  @MainActor
  func handleCallback(_ url: URL) async throws {
    cancelInFlightPermissionUpgrade()
    logger.info(.callbackProcessingStarted)
    logger.debug(.callbackURLDetails)
    logger.debug(.callbackStateVerified)
    updateState(.authenticating(progress: .exchangingTokens))

    if case .authenticating = state {
      logger.debug(.callbackStateVerified)
    } else {
      logger.warning(.callbackUnexpectedState)
    }

    guard let client = client else {
      logger.error(.callbackClientUnavailable)
      let error = AuthError.clientNotInitialized
      updateState(.error(message: error.localizedDescription))
      throw error
    }
    logger.debug(.callbackClientAvailable)
    do {
      logger.debug(.callbackProcessingStarted)
      try await withTimeout(timeout: networkTimeout) {
        try Task.checkCancellation()

        self.logger.debug(.callbackTokenExchangeStarted)
        if let handleCallback = self.dependencyOverrides.handleOAuthCallback {
          try await handleCallback(client, url)
        } else {
          try await client.handleOAuthCallback(url: url)
        }
        self.logger.info(.callbackTokenExchangeCompleted)
        self.logger.info(.callbackImmediateAPISuccess)
        do {
          let did = try await client.getDid()
          let atId = try ATIdentifier(string: did)
          let params = AppBskyActorGetProfile.Parameters(actor: atId)
          let result = try await client.app.bsky.actor.getProfile(input: params)
          self.logger.info(.callbackImmediateAPISuccess)
        } catch {
          self.logger.error(.callbackImmediateAPIFailed)
        }

        await self.updateState(.authenticating(progress: .creatingSession))

        self.logger.debug(.callbackSessionValid)
        let hasValidSession = await client.hasValidSession()
        if !hasValidSession {
          self.logger.error(.callbackSessionInvalid)
          throw AuthError.invalidSession
        }
        self.logger.debug(.callbackSessionValid)
        await self.updateState(.authenticating(progress: .finalizing))

        self.logger.debug(.callbackDIDResolved)
        let did = try self.validatedUserDID(
          try await client.getDid(),
          source: "handleOAuthCallback"
        )
        self.logger.debug(.callbackDIDResolved)

        self.logger.debug(.callbackHandleResolved)
        self.handle = try await client.getHandle()
        self.logger.debug(.callbackHandleResolved)
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
      logger.info(.callbackConnectivityCheckSuccess)
      do {
        let atId = try ATIdentifier(string: did)
        let params = AppBskyActorGetProfile.Parameters(actor: atId)
        let result = try await client.app.bsky.actor.getProfile(input: params)
        logger.info(.callbackConnectivityCheckSuccess)
      } catch {
        logger.error(.callbackConnectivityCheckFailed)
      }

      // NOTE: AppState transition is handled by AppStateManager's auth state observation
      // when it observes .authenticated state. No explicit switchAccount call needed here.
      self.logger.info(.callbackCompleted)
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

      logger.error(.callbackFailed)
      updateState(.error(message: finalError.localizedDescription))
      throw finalError
    }
  }

  /// Handle a gateway callback by atomically exchanging its one-time code.
  @MainActor
  func handleGatewayCallback(_ url: URL) async throws {
    cancelInFlightPermissionUpgrade()
    logger.info(.gatewayCallbackProcessingStarted)
    updateState(.authenticating(progress: .exchangingTokens))

    // Ensure client exists (cold start scenario)
    if client == nil {
      logger.info(.gatewayCallbackClientInitializing)
      await initialize()

      guard client != nil else {
        logger.error(.gatewayCallbackClientUnavailable)
        let error = AuthError.clientNotInitialized
        updateState(.error(message: error.localizedDescription))
        throw error
      }
    }

    do {
      updateState(.authenticating(progress: .creatingSession))

      let sessionID: String
      if let redeem = dependencyOverrides.redeemGatewayCallback {
        sessionID = try await redeem(url)
      } else {
        sessionID = try await gatewayOAuthExchange.redeem(url)
      }
      var internalCallback = URLComponents()
      internalCallback.scheme = "https"
      internalCallback.host = "catbird.blue"
      internalCallback.path = "/oauth/callback"
      internalCallback.fragment = "session_id=\(sessionID)"
      guard let sessionCallbackURL = internalCallback.url else {
        throw AuthError.invalidCallbackURL
      }

      guard let activeClient = client else {
        throw AuthError.clientNotInitialized
      }
      try await activeClient.handleOAuthCallback(url: sessionCallbackURL)

      updateState(.authenticating(progress: .finalizing))

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

      logger.info(.gatewayCallbackCompleted)
    } catch {
      let finalError: AuthError
      if let authError = error as? AuthError {
        finalError = authError
      } else {
        finalError = AuthError.unknown(error)
      }

      logger.error(.gatewayCallbackFailed)
      updateState(.error(message: finalError.localizedDescription))
      throw finalError
    }
  }

  @MainActor
  func cancelGatewayOAuthFlow() async {
    cancelInFlightPermissionUpgrade()
    await gatewayOAuthExchange.cancelPendingLogin()
  }
  /// Logout the current user
  /// - Parameter isManual: If true, this is a user-initiated logout and we should clear expiredAccountInfo
  ///   to prevent auto-triggering re-authentication. If false (auto-logout), preserve expiredAccountInfo
  ///   to enable seamless re-auth flow.
  @MainActor
  func logout(isManual: Bool = false) async {
    logger.info(.logoutStarted)
    let departingDID = state.userDID
    isAuthenticationCancelled = false
    cancelInFlightPermissionUpgrade()
    updateState(.unauthenticated)

    if let departingDID {
      NotificationCenter.default.post(
        name: .circleAccountInvalidated,
        object: nil,
        userInfo: ["accountDID": departingDID]
      )
    }
    // Cleanup notifications before logging out
    Task {
      if case .authenticated(let appState) = AppStateManager.shared.lifecycle {
        await appState.notificationManager.cleanupNotifications(previousClient: client)
      }
    }

    // Purge memory-only Circle caches for the logged-out account so a future
    // login never reuses a previous account's permissioned responses.
    if let departingDID {
      await CircleFeedCache.shared.purge(accountDID: departingDID)
      await CircleMediaLoader.shared.purge(accountDID: departingDID)
      await CircleNotificationCache.shared.purge(accountDID: departingDID)
    }

    // Note: AppStateManager calls this method, so we don't call back to avoid infinite loop

    if let client = client {
      do {
        try await client.logout()
        logger.info(.logoutSuccessful)
      } catch {
        logger.error(.logoutFailed)
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
      logger.info(.manualLogoutStateCleared)
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
    cancelInFlightPermissionUpgrade()
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

  // MARK: - Progressive Gateway Permission Coordinator

  /// Cancels any in-flight gateway permission upgrade.
  @MainActor
  func cancelInFlightPermissionUpgrade() {
    if let inFlight = inFlightPermission {
      logger.info("Cancelling in-flight gateway permission upgrade for \(inFlight.permission.rawValue) (id: \(inFlight.id))")
      inFlight.task.cancel()
      inFlightPermission = nil
    }
  }

  @MainActor
  private func capturePermissionContinuitySnapshot() throws -> GatewayPermissionContinuitySnapshot {
    guard !isSwitchingAccount else {
      logger.error("ensureGatewayPermission called while switching accounts")
      throw GatewayPermissionError.stateChanged
    }

    guard case .authenticated(let expectedDID) = self.state, !expectedDID.isEmpty else {
      logger.error("ensureGatewayPermission called while not authenticated")
      throw GatewayPermissionError.unauthenticated
    }

    guard let expectedClient = self.client else {
      logger.error("ensureGatewayPermission called with client unavailable")
      throw GatewayPermissionError.clientUnavailable
    }

    if isAuthenticationCancelled {
      throw GatewayPermissionError.cancelled
    }

    let expectedAppState = AppStateManager.shared.getState(for: expectedDID)
    let expectedAppStateUserDID = AppStateManager.shared.lifecycle.userDID

    return GatewayPermissionContinuitySnapshot(
      did: expectedDID,
      client: expectedClient,
      appState: expectedAppState,
      appStateUserDID: expectedAppStateUserDID
    )
  }

  @MainActor
  private func validatePermissionContinuity(against snapshot: GatewayPermissionContinuitySnapshot) throws {
    if Task.isCancelled {
      throw GatewayPermissionError.cancelled
    }

    if isAuthenticationCancelled {
      logger.error("Authentication was cancelled during permission upgrade")
      throw GatewayPermissionError.cancelled
    }

    if isSwitchingAccount {
      logger.error("Account switch began during permission upgrade")
      throw GatewayPermissionError.stateChanged
    }

    // Verify DID state is unchanged and still authenticated
    guard case .authenticated(let currentDID) = self.state, currentDID == snapshot.did else {
      logger.error("Auth state changed during permission upgrade (expected \(snapshot.did))")
      throw GatewayPermissionError.stateChanged
    }

    // Verify client instance is unchanged
    guard let currentClient = self.client, currentClient === snapshot.client else {
      logger.error("Client instance changed during permission upgrade")
      throw GatewayPermissionError.stateChanged
    }

    // Verify AppState lifecycle userDID is unchanged (including nil transitions)
    let currentLifecycleUserDID = AppStateManager.shared.lifecycle.userDID
    guard currentLifecycleUserDID == snapshot.appStateUserDID else {
      logger.error("AppState lifecycle userDID changed during permission upgrade (expected \(String(describing: snapshot.appStateUserDID)), got \(String(describing: currentLifecycleUserDID)))")
      throw GatewayPermissionError.stateChanged
    }

    // Verify AppState instance is unchanged
    let currentAppState = AppStateManager.shared.getState(for: snapshot.did)
    guard currentAppState === snapshot.appState else {
      logger.error("AppState instance changed during permission upgrade")
      throw GatewayPermissionError.stateChanged
    }
  }

  /// Ensures that the specified gateway permission is granted for the currently authenticated user.
  /// If the permission is already granted, returns immediately without opening a browser.
  /// Otherwise, initiates a progressive JIT OAuth upgrade flow via Nest and the Petrel client.
  ///
  /// - Parameters:
  ///   - permission: The progressive gateway permission scope to ensure.
  ///   - present: A closure that presents the authorization URL (e.g. via `ASWebAuthenticationSession`)
  ///              and returns the resulting callback URL.
  /// - Throws: `GatewayPermissionError` if unauthenticated, cancelled, denied, state changed, or upgrade failed.
  @MainActor
  public func ensureGatewayPermission(
    _ permission: GatewayPermission,
    present: @escaping @MainActor (URL) async throws -> URL
  ) async throws {
    // Check Task cancellation at start
    if Task.isCancelled {
      throw GatewayPermissionError.cancelled
    }

    // 1. Snapshot authenticated DID / client / current AppState
    let snapshot = try capturePermissionContinuitySnapshot()

    // 2. Fetch granted scopes (throwing - transport errors throw and never mean an empty grant)
    let currentScopes: Set<String>
    do {
      if let hook = fetchGrantedScopesHook {
        currentScopes = try await hook(snapshot.did)
      } else {
        currentScopes = try await snapshot.client.fetchGrantedScopes(for: snapshot.did)
      }
    } catch {
      if Task.isCancelled || error is CancellationError {
        throw GatewayPermissionError.cancelled
      }
      throw error
    }

    // Validate continuity snapshot before already-granted return
    try validatePermissionContinuity(against: snapshot)

    // 3. Skip browser if grant present
    if currentScopes.contains(permission.rawValue) {
      logger.info("Gateway permission \(permission.rawValue) is already granted for \(snapshot.did)")
      return
    }

    // 4. Coalesce / reject concurrent flow
    // Discard a cancelled in-flight record before coalescing/rejecting so a new
    // request for the same permission can proceed.
    if let existing = inFlightPermission, existing.task.isCancelled {
      inFlightPermission = nil
    }

    if let existing = inFlightPermission {
      if existing.permission == permission && existing.did == snapshot.did {
        logger.info("Coalescing concurrent permission request for \(permission.rawValue)")
        do {
          let waiter = CoalescedPermissionWaiter()
          try await waiter.wait(for: existing.task)
        } catch {
          if Task.isCancelled || error is CancellationError || (error as? GatewayPermissionError) == .cancelled {
            throw GatewayPermissionError.cancelled
          }
          throw error
        }
        if Task.isCancelled {
          throw GatewayPermissionError.cancelled
        }
        return
      } else {
        logger.warning("Rejecting concurrent permission request for \(permission.rawValue) (active: \(existing.permission.rawValue))")
        throw GatewayPermissionError.alreadyInProgress
      }
    }

    // 5. Create unique request generation ID and structured in-flight task
    let requestID = UUID()
    let upgradeTask = Task { @MainActor [weak self] () -> Void in
      guard let self = self else { throw GatewayPermissionError.clientUnavailable }
      try await self.performGatewayScopeUpgrade(
        permission: permission,
        snapshot: snapshot,
        present: present
      )
    }

    self.inFlightPermission = InFlightPermissionRequest(
      id: requestID,
      permission: permission,
      did: snapshot.did,
      task: upgradeTask
    )

    defer {
      if self.inFlightPermission?.id == requestID {
        self.inFlightPermission = nil
      }
    }

    do {
      try await withTaskCancellationHandler {
        try await upgradeTask.value
      } onCancel: {
        upgradeTask.cancel()
        Task { @MainActor [weak self] in
          if self?.inFlightPermission?.id == requestID {
            self?.inFlightPermission = nil
          }
        }
      }
    } catch {
      if Task.isCancelled || error is CancellationError || (error as? GatewayPermissionError) == .cancelled {
        throw GatewayPermissionError.cancelled
      }
      throw error
    }
  }

  @MainActor
  private func performGatewayScopeUpgrade(
    permission: GatewayPermission,
    snapshot: GatewayPermissionContinuitySnapshot,
    present: @MainActor (URL) async throws -> URL
  ) async throws {
    let callbackURL = GatewayPermission.permissionCallbackURL

    // Check Task cancellation at start
    if Task.isCancelled {
      throw GatewayPermissionError.cancelled
    }

    // Start gateway scope upgrade
    let authURL: URL
    do {
      if let hook = startGatewayScopeUpgradeHook {
        authURL = try await hook(Set([permission.rawValue]), snapshot.did, callbackURL)
      } else {
        authURL = try await snapshot.client.startGatewayScopeUpgrade(
          requesting: Set([permission.rawValue]),
          for: snapshot.did,
          callbackURL: callbackURL
        )
      }
    } catch {
      if Task.isCancelled || error is CancellationError {
        logger.info("Gateway permission upgrade start cancelled for \(permission.rawValue)")
        throw GatewayPermissionError.cancelled
      }
      throw error
    }

    // Validate continuity snapshot before presentation
    try validatePermissionContinuity(against: snapshot)

    // Present auth URL via presentation handler
    let returnedCallbackURL: URL
    do {
      returnedCallbackURL = try await present(authURL)
    } catch {
      if Task.isCancelled || error is CancellationError {
        logger.info("Gateway permission upgrade cancelled by user for \(permission.rawValue)")
        throw GatewayPermissionError.cancelled
      }
      #if canImport(AuthenticationServices)
      if let asError = error as? ASWebAuthenticationSessionError, asError.code == .canceledLogin {
        logger.info("Gateway permission upgrade ASWebAuthenticationSession cancelled by user for \(permission.rawValue)")
        throw GatewayPermissionError.cancelled
      }
      #endif
      if let authError = error as? AuthError, authError == .cancelled {
        logger.info("Gateway permission upgrade AuthError.cancelled for \(permission.rawValue)")
        throw GatewayPermissionError.cancelled
      }
      if let gwError = error as? GatewayPermissionError, gwError == .cancelled {
        throw gwError
      }
      logger.error("Gateway permission presentation failed: \(error.localizedDescription)")
      throw error
    }

    // Validate continuity snapshot before complete/redeem
    try validatePermissionContinuity(against: snapshot)

    // Complete gateway scope upgrade
    let grantedScopes: Set<String>
    do {
      if let hook = completeGatewayScopeUpgradeHook {
        grantedScopes = try await hook(returnedCallbackURL, snapshot.did)
      } else {
        grantedScopes = try await snapshot.client.completeGatewayScopeUpgrade(
          callbackURL: returnedCallbackURL,
          for: snapshot.did
        )
      }
    } catch {
      if Task.isCancelled || error is CancellationError {
        logger.info("Gateway permission upgrade complete cancelled for \(permission.rawValue)")
        throw GatewayPermissionError.cancelled
      }
      throw error
    }

    // Validate continuity snapshot after completion
    try validatePermissionContinuity(against: snapshot)

    // Verify actual returned grant contains requested permission
    guard grantedScopes.contains(permission.rawValue) else {
      logger.error("Returned scopes missing requested permission \(permission.rawValue): \(grantedScopes)")
      throw GatewayPermissionError.missingGrantedScope(permission)
    }

    logger.info("Successfully upgraded gateway permission for \(permission.rawValue)")
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

    var loginHandle: String? {
      Self.loginHandleCandidate(handle) ?? Self.loginHandleCandidate(cachedHandle)
    }

    static func loginHandleCandidate(_ value: String?) -> String? {
      guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
        !trimmed.isEmpty,
        !trimmed.lowercased().hasPrefix("did:")
      else {
        return nil
      }

      return trimmed
    }

    static func == (lhs: AccountInfo, rhs: AccountInfo) -> Bool {
      lhs.did == rhs.did
    }
  }

  // MARK: - Handle Storage

  #if DEBUG
  nonisolated(unsafe) private static var ephemeralHandles: [String: String] = [:]
  nonisolated(unsafe) private static var ephemeralAccountOrder: [String] = []
  nonisolated(unsafe) private static var ephemeralProfileData: [String: [String: String?]] = [:]

  private var isE2EMode: Bool {
    ProcessInfo.processInfo.arguments.contains("--e2e-mode")
  }
  #endif

  /// Records a local handle transition for the currently authenticated account.
  /// Validates that the manager is authenticated for the expected DID with an active client,
  /// validates that the handle is a canonical nonempty non-DID string, and updates local
  /// state and persistent handle storage atomically enough that future JIT / expired reauth / account switching uses the new handle.
  ///
  /// - Parameters:
  ///   - newHandle: The new handle string.
  ///   - expectedDID: The DID expected to be currently authenticated.
  /// - Throws: `AuthError.invalidSession` if not authenticated or DID mismatch,
  ///           `AuthError.clientNotInitialized` if client is missing,
  ///           `AuthError.invalidHandle` if handle is empty, malformed, or starts with `did:`.
  @MainActor
  func recordCurrentHandleChange(_ newHandle: String, for expectedDID: String) throws {
    guard case .authenticated(let currentDID) = self.state, currentDID == expectedDID, !expectedDID.isEmpty else {
      logger.error("Handle change rejected: auth state is not authenticated for expected DID: \(expectedDID)")
      throw AuthError.invalidSession
    }

    guard self.client != nil else {
      logger.error("Handle change rejected: client not initialized")
      throw AuthError.clientNotInitialized
    }

    var trimmed = newHandle.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("@") {
      trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    trimmed = trimmed.lowercased()

    guard !trimmed.isEmpty,
      !trimmed.hasPrefix("did:"),
      let parsedHandle = try? Handle(handleString: trimmed)
    else {
      logger.error("Handle change rejected invalid handle: '\(newHandle)'")
      throw AuthError.invalidHandle
    }

    let canonicalHandle = parsedHandle.value
    // 1. Update in-memory current handle
    self.handle = canonicalHandle

    // 2. Update persistent handle storage for this DID
    storeHandle(canonicalHandle, for: expectedDID)

    // 3. Update cached profile data handle
    let existingProfile = getCachedProfileData(for: expectedDID)
    cacheProfileData(
      for: expectedDID,
      handle: canonicalHandle,
      displayName: existingProfile?.displayName,
      avatarURL: existingProfile?.avatarURL
    )

    // 4. Ensure DID is present in account order metadata
    var order = getAccountOrder()
    if !order.contains(expectedDID) {
      order.insert(expectedDID, at: 0)
      saveAccountOrder(order)
    }

    // 5. Update in-memory availableAccounts entry if present
    if let index = availableAccounts.firstIndex(where: { $0.did == expectedDID }) {
      let existing = availableAccounts[index]
      availableAccounts[index] = AccountInfo(
        did: existing.did,
        handle: canonicalHandle,
        isActive: existing.isActive,
        cachedHandle: canonicalHandle,
        cachedDisplayName: existing.cachedDisplayName,
        cachedAvatarURL: existing.cachedAvatarURL
      )
    }

    // 6. Update expiredAccountInfo if it targets this DID
    if expiredAccountInfo?.did == expectedDID {
      expiredAccountInfo = makeExpiredAccountInfo(for: expectedDID, isActive: expiredAccountInfo?.isActive ?? false)
    }

    logger.info("Successfully recorded handle transition to '\(canonicalHandle)' for DID: \(expectedDID)")
  }
  /// Store handle for a specific DID
  func storeHandle(_ handle: String, for did: String) {
    guard let loginHandle = AccountInfo.loginHandleCandidate(handle) else {
      logger.warning(.invalidHandleIgnored)
      return
    }

    #if DEBUG
    if isE2EMode {
      Self.ephemeralHandles[did] = loginHandle
      return
    }
    #endif

    var handles = getStoredHandles()
    handles[did] = loginHandle

    if let data = try? JSONEncoder().encode(handles) {
      userDefaults.set(data, forKey: handleStorageKey)
    }
  }

  /// Get stored handle for a specific DID
  func getStoredHandle(for did: String) -> String? {
    let handles = getStoredHandles()
    return AccountInfo.loginHandleCandidate(handles[did])
  }

  /// Get all stored handles
  func getStoredHandles() -> [String: String] {
    #if DEBUG
    if isE2EMode {
      return Self.ephemeralHandles.compactMapValues { AccountInfo.loginHandleCandidate($0) }
    }
    #endif

    guard let data = userDefaults.data(forKey: handleStorageKey),
      let handles = try? JSONDecoder().decode([String: String].self, from: data)
    else {
      return [:]
    }
    return handles.compactMapValues { AccountInfo.loginHandleCandidate($0) }
  }

  /// Remove stored handle for a specific DID
  private func removeStoredHandle(for did: String) {
    #if DEBUG
    if isE2EMode {
      Self.ephemeralHandles.removeValue(forKey: did)
      Self.ephemeralAccountOrder.removeAll { $0 == did }
      return
    }
    #endif

    var handles = getStoredHandles()
    handles.removeValue(forKey: did)

    if let data = try? JSONEncoder().encode(handles) {
      userDefaults.set(data, forKey: handleStorageKey)
    }

    // Also remove from account order
    var order = getAccountOrder()
    order.removeAll { $0 == did }
    saveAccountOrder(order)
  }

  /// Get stored account order (array of DIDs)
  private func getAccountOrder() -> [String] {
    #if DEBUG
    if isE2EMode {
      return Self.ephemeralAccountOrder
    }
    #endif

    guard let data = userDefaults.data(forKey: accountOrderKey),
      let order = try? JSONDecoder().decode([String].self, from: data)
    else {
      return []
    }
    return order
  }

  /// Save account order
  private func saveAccountOrder(_ order: [String]) {
    #if DEBUG
    if isE2EMode {
      Self.ephemeralAccountOrder = order
      return
    }
    #endif

    if let data = try? JSONEncoder().encode(order) {
      userDefaults.set(data, forKey: accountOrderKey)
    }
  }

  /// Update account order (called from UI when user reorders)
  @MainActor
  func updateAccountOrder(_ orderedDIDs: [String]) {
    logger.info(.accountOrderUpdated)
    saveAccountOrder(orderedDIDs)
  }

  /// Cache profile data for an account to avoid showing DID during switches
  @MainActor
  func cacheProfileData(for did: String, handle: String?, displayName: String?, avatarURL: URL?) {
    let key = "cached_profile_\(did)"
    let profileData: [String: String?] = [
      "handle": AccountInfo.loginHandleCandidate(handle),
      "displayName": displayName,
      "avatarURL": avatarURL?.absoluteString,
    ]

    #if DEBUG
    if isE2EMode {
      Self.ephemeralProfileData[did] = profileData
      logger.debug(.profileDataCached)
      return
    }
    #endif

    if let data = try? JSONEncoder().encode(profileData) {
      userDefaults.set(data, forKey: key)
      logger.debug(.profileDataCached)
    }
  }

  /// Get cached profile data for an account
  nonisolated func getCachedProfileData(for did: String) -> (
    handle: String?, displayName: String?, avatarURL: URL?
  )? {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("--e2e-mode") {
      if let profileData = Self.ephemeralProfileData[did] {
        let handle = AccountInfo.loginHandleCandidate(profileData["handle"] as? String)
        let displayName = profileData["displayName"] as? String
        let avatarURL = (profileData["avatarURL"] as? String).flatMap { URL(string: $0) }
        return (handle: handle, displayName: displayName, avatarURL: avatarURL)
      }
      return nil
    }
    #endif

    let key = "cached_profile_\(did)"
    guard let data = userDefaults.data(forKey: key),
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
      handle: AccountInfo.loginHandleCandidate(profileData["handle"] as? String),
      displayName: profileData["displayName"] as? String,
      avatarURL: avatarURL
    )
  }

  private func makeExpiredAccountInfo(for did: String, isActive: Bool = false) -> AccountInfo {
    let cachedProfile = getCachedProfileData(for: did)
    return AccountInfo(
      did: did,
      handle: getStoredHandle(for: did),
      isActive: isActive,
      cachedHandle: cachedProfile?.handle,
      cachedDisplayName: cachedProfile?.displayName,
      cachedAvatarURL: cachedProfile?.avatarURL
    )
  }

  /// Remove an account completely (including stored handle and on-disk/keychain MLS data)
  @MainActor
  func removeAccount(did: String) async {
    logger.info(.accountRemovalStarted)

    NotificationCenter.default.post(
      name: .circleAccountInvalidated,
      object: nil,
      userInfo: ["accountDID": did]
    )

    removeStoredHandle(for: did)
    if inFlightPermission?.did == did {
      cancelInFlightPermissionUpgrade()
    }
    if let client = client {
      do {
        try await client.removeAccount(did: did)
        logger.info(.accountRemovalSuccessful)
      } catch {
        logger.error(.accountRemovalFailed)
      }
    }

    // Clean up cached AppState and completely destroy all persistent MLS files, databases, and Keychain materials
    await AppStateManager.shared.removeAccount(did)

    // Purge memory-only Circle caches for the removed account.
    await CircleFeedCache.shared.purge(accountDID: did)
    await CircleMediaLoader.shared.purge(accountDID: did)
    await CircleNotificationCache.shared.purge(accountDID: did)
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
    logger.info(.accountsListed)

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

    logger.info(.clientRecreatedForAccountOps)

    #if targetEnvironment(simulator)
      let accessGroup: String? = nil
    #else
      let accessGroup: String? = MLSKeychainManager.resolvedAccessGroup(
        suffix: "blue.catbird.shared")
    #endif

      #if DEBUG
    client = try? await ATProtoClient(
      oauthConfig: oauthConfig,
      namespace: "blue.catbird",
      authMode: .gateway,
      gatewayURL: AuthenticationManager.gatewayURL,
      userAgent: "Catbird/1.0",
      bskyAppViewDID: customAppViewDID,
      bskyChatDID: customChatDID,
      accessGroup: accessGroup
    )
      #else
      client = try? await ATProtoClient(
        oauthConfig: oauthConfig,
        namespace: "blue.catbird",
        authMode: .gateway,
        gatewayURL: AuthenticationManager.gatewayURL,
        userAgent: "Catbird/1.0",
        bskyAppViewDID: customAppViewDID,
        bskyChatDID: customChatDID,
        accessGroup: accessGroup
      )
      #endif
      
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

    logger.info(.accountSwitchStarted)
    logger.debug(.accountSwitchStarted)

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
      logger.warning(.accountSwitchAlreadyInProgress)
      throw AuthError.accountSwitchInProgress
    }

    logger.debug(.accountSwitchClientInitializing)
    await ensureClientInitializedForAccountOperations()

    guard let client = client else {
      logger.error(.accountSwitchClientUnavailable)
      throw AuthError.clientNotInitialized
    }
    logger.debug(.accountSwitchProceeding)

    if case .authenticated(let currentDid) = state, currentDid == targetDID {
      logger.info(.accountSwitchAlreadyActive)
      return
    }

    logger.info(.accountSwitchProceeding)
    logger.debug(.accountSwitchProceeding)
    isSwitchingAccount = true
    cancelInFlightPermissionUpgrade()
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

      logger.info(.accountSwitchMLSCleanupStarted)

      // DEFENSIVE TIMEOUT: Wrap entire MLS cleanup in 10-second hard timeout
      // If any operation hangs, we force ahead. Better degraded MLS than frozen app.
      let mlsCleanupOk = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
          // First bump generation to invalidate stale tasks
          await MLSClient.shared.bumpGeneration(for: currentDid)

          // Close app-layer MLSClient context (separate from core package)
          let ffiClosed = await MLSClient.shared.closeContext(for: currentDid)
          if ffiClosed {
            self.logger.info(.accountSwitchMLSContextClosed)
          }

          // Use the centralized shutdown coordinator (single attempt, no retries)
          let result = await MLSShutdownCoordinator.shared.shutdown(
            for: currentDid, databaseManager: .shared, timeout: 5.0)

          switch result {
          case .success:
            self.logger.info(.accountSwitchMLSCoreShutdownSuccess)
          case .successWithWarnings:
            self.logger.warning(.accountSwitchMLSCoreShutdownWarning)
          case .timedOut:
            self.logger.warning(.accountSwitchMLSCoreShutdownTimeout)
          case .failed:
            self.logger.error(.accountSwitchMLSCoreShutdownFailed)
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
        logger.critical(.accountSwitchMLSCleanupTimedOut)
        // Don't abort - force ahead. User can restart if MLS is broken.
      }
    }

    // Purge memory-only Circle caches for the previous account so the target
    // account never reuses the prior account's permissioned responses.
    if let previousDID = state.userDID, previousDID != targetDID {
      NotificationCenter.default.post(
        name: .circleAccountInvalidated,
        object: nil,
        userInfo: ["accountDID": previousDID]
      )
      await CircleFeedCache.shared.purge(accountDID: previousDID)
      await CircleMediaLoader.shared.purge(accountDID: previousDID)
      await CircleNotificationCache.shared.purge(accountDID: previousDID)
    }

    // Prewarm the target account's database now that the previous account is fully drained.
    // Set the target as active BEFORE prewarming to avoid OOM-blocking rejection.
    do {
      await MLSGRDBManager.shared.setActiveUser(targetDID)
      _ = try await MLSGRDBManager.shared.getDatabasePool(for: targetDID)
      logger.debug(.accountSwitchDatabasePrewarmed)
    } catch {
      logger.debug(.accountSwitchDatabasePrewarmFailed)
    }

    cancelInFlightPermissionUpgrade()
    do {
      logger.debug(.accountSwitchProceeding)
      updateState(.initializing)

      #if DEBUG
      if let override = Self.switchAccountOverride {
        let (resolvedDID, resolvedHandle) = try await override(targetDID)
        self.handle = resolvedHandle
        updateState(.authenticated(userDID: resolvedDID))
        MLSNotificationCoordinator.updateActiveUserDID(resolvedDID)
        logger.info(.accountSwitchSuccessful)
        isSwitchingAccount = false
        await refreshAvailableAccounts()
        return
      }
      #endif

      logger.info(.accountSwitchClientSwitchCalled)
      if let switchAccount = dependencyOverrides.switchAccount {
        try await switchAccount(client, targetDID)
      } else {
        try await client.switchToAccount(did: targetDID)
      }
      logger.info(.accountSwitchClientSwitchCompleted)

      logger.debug(.accountSwitchSessionValid)
      let hasValidSession = await client.hasValidSession()
      if !hasValidSession {
        logger.warning(.accountSwitchSessionInvalid)
        expiredAccountInfo = makeExpiredAccountInfo(for: targetDID)
        logger.info(.expiredAccountInfoPrepared)
        isSwitchingAccount = false
        updateState(.unauthenticated)
        throw AuthError.invalidSession
      }
      logger.info(.accountSwitchSessionValid)

      logger.debug(.callbackDIDResolved)
      let newDid = try validatedUserDID(
        try await client.getDid(),
        source: "switchToAccount.resolved"
      )
      logger.debug(.callbackDIDResolved)
      if newDid != targetDID {
        logger.warning(.accountSwitchResolvedDIDMismatch)
      }

      logger.debug(.callbackHandleResolved)
      self.handle = try await client.getHandle()
      logger.debug(.callbackHandleResolved)

      logger.debug(.stateUpdated)
      updateState(.authenticated(userDID: newDid))
      MLSNotificationCoordinator.updateActiveUserDID(newDid)

      logger.info(.accountSwitchSuccessful)
    } catch {
      logger.error(.accountSwitchFailed)

      // Reset switching flag since we failed
      isSwitchingAccount = false

      // Set expired account info so LoginView/AccountSwitcherView can trigger re-authentication
      // This allows automatic re-auth flow when switching to an account with expired tokens
      expiredAccountInfo = makeExpiredAccountInfo(for: targetDID)
      logger.info(.expiredAccountInfoPrepared)

      // Set state to unauthenticated so the auth UI can handle re-auth
      logger.debug(.stateUpdated)
      updateState(.unauthenticated)
      throw error
    }

    logger.debug(.accountSwitchCompleted)
    isSwitchingAccount = false
    logger.debug(.accountSwitchCompleted)
    await refreshAvailableAccounts()
    logger.info(.accountSwitchCompleted)
  }

  /// Add a new account
  @MainActor
  func addAccount(handle: String) async throws -> URL {
    cancelInFlightPermissionUpgrade()
    logger.info(.addAccountStarted)

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
      let boundAuthURL = try await gatewayOAuthExchange.prepareLogin(authURL)
      self.logger.debug(.addAccountOAuthURLGenerated)

      updateState(.authenticating(progress: .openingBrowser))
      return boundAuthURL
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

      logger.error(.addAccountFailed)
      updateState(.error(message: "Failed to add account: \(finalError.localizedDescription)"))
      throw finalError
    }
  }

  /// Start gateway account creation with the same native nonce binding as login.
  @MainActor
  func startSignUp(pdsURL: URL) async throws -> URL {
    guard let client else {
      throw AuthError.clientNotInitialized
    }
    let authURL = try await client.startSignUpFlow(pdsURL: pdsURL)
    return try await gatewayOAuthExchange.prepareLogin(authURL)
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
        self.logger.info(.biometricAuthAvailable)
      } else {
        self.biometricAuthEnabled = false
        if error != nil {
          self.logger.warning(.biometricAuthNotAvailable)
        } else {
          self.logger.info(.biometricAuthNotAvailable)
        }
      }
    }
  }

  /// Enable or disable biometric authentication
  @MainActor
  func setBiometricAuthEnabled(_ enabled: Bool) async {
    lastBiometricError = nil

    guard biometricType != .none else {
      logger.warning(.biometricAuthNotAvailable)
      return
    }

    if enabled {
      let success = await authenticateWithBiometrics(
        reason: "Enable biometric authentication for Catbird")
      if success {
        biometricAuthEnabled = true
        await saveBiometricAuthPreference(enabled: true)
        logger.info(.biometricAuthEnabled)
      } else {
        logger.warning(.biometricAuthEnableFailed)
      }
    } else {
      biometricAuthEnabled = false
      await saveBiometricAuthPreference(enabled: false)
      logger.info(.biometricAuthDisabled)
    }
  }

  /// Authenticate using biometrics
  @MainActor
  func authenticateWithBiometrics(reason: String) async -> Bool {
    guard biometricType != .none else {
      logger.warning(.biometricAuthNotAvailable)
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
        logger.info(.biometricAuthSuccess)
        return true
      } else {
        logger.warning(.biometricAuthFailed)
        return false
      }
    } catch let error as LAError {
      lastBiometricError = error
      switch error.code {
      case .userCancel:
        logger.info(.biometricAuthCancelled)
      case .userFallback:
        logger.info(.biometricAuthFallback)
      case .biometryNotAvailable:
        logger.warning(.biometricAuthNotAvailable)
      case .biometryNotEnrolled:
        logger.warning(.biometricAuthNotEnrolled)
      case .biometryLockout:
        logger.warning(.biometricAuthLockout)
      default:
        logger.error(.biometricAuthError)
      }
      return false
    } catch {
      logger.error(.biometricAuthError)
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
    return userDefaults.bool(forKey: "biometric_auth_enabled")
  }

  private func saveBiometricAuthPreference(enabled: Bool) async {
    userDefaults.set(enabled, forKey: "biometric_auth_enabled")
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
    logger.info(.networkRecoveryAttemptStarted)

    guard let client = self.client else {
      logger.error(.networkRecoveryClientUnavailable)
      return
    }

    do {
      try await client.attemptRecoveryFromServerFailures()
      logger.info(.networkRecoverySuccessful)
      await checkAuthenticationState()
    } catch {
      logger.error(.networkRecoveryFailed)
      updateState(AuthState.error(message: "Recovery failed: \(error.localizedDescription)"))
    }
  }
}

// MARK: - AuthenticationDelegate

extension AuthenticationManager: AuthenticationDelegate {
  // Called by Petrel when a refresh fails or auth is otherwise required again.
  func authenticationRequired(client: ATProtoClient) {
    logger.error(.authenticationRequiredReceived)
    Task { @MainActor in
      // DEBOUNCE: Avoid multiple triggers
      if self.isHandlingAuthExpiration {
        logger.warning(.authenticationRequiredDuplicateTrigger)
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
        logger.info(.authenticationRequiredSkipAlert)
      }

      self.updateState(.unauthenticated)
    }
  }
}

// MARK: - AuthFailureDelegate

extension AuthenticationManager: AuthFailureDelegate {
  @MainActor
  func handleCatastrophicAuthFailure(did: String, error: Error, isRetryable: Bool) async {
    logger.error(.catastrophicAuthFailure)

    // DEBOUNCE
    if isHandlingAuthExpiration {
      logger.warning(.catastrophicDuplicateTrigger)
      return
    }
    isHandlingAuthExpiration = true
    // Prime re-auth for the specified DID
    if expiredAccountInfo == nil {
      expiredAccountInfo = makeExpiredAccountInfo(for: did)
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
        logger.info(.catastrophicSkipAlert)
      } else if pendingAuthAlert == nil {
        pendingAuthAlert = AuthAlert(
          title: "Signed Out", message: "Your session is no longer valid. Please sign in again.")
      }
    }

    updateState(.unauthenticated)
  }

  @MainActor
  func handleCircuitBreakerOpen(did: String) async {
    logger.warning(.circuitBreakerOpen)
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
  /// Received an empty, DID-formatted, or malformed handle.
  case invalidHandle

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
    case .invalidHandle:
      return "Received an invalid handle"
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
    case .invalidHandle:
      return "The handle is empty, malformed, or formatted as a DID."
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
    case .invalidHandle:
      return "Please check the handle format and try again."
    default:
      return "Please try again or contact support if the problem persists."
    }
  }
}

extension AuthError: Equatable {
  public static func == (lhs: AuthError, rhs: AuthError) -> Bool {
    switch (lhs, rhs) {
    case (.clientNotInitialized, .clientNotInitialized),
      (.invalidSession, .invalidSession),
      (.invalidCredentials, .invalidCredentials),
      (.invalidCallbackURL, .invalidCallbackURL),
      (.timeout, .timeout),
      (.cancelled, .cancelled),
      (.invalidUserDID, .invalidUserDID),
      (.accountSwitchInProgress, .accountSwitchInProgress),
      (.databaseDrainFailed, .databaseDrainFailed),
      (.invalidHandle, .invalidHandle):
      return true
    case (.badResponse(let l), .badResponse(let r)):
      return l == r
    case (.networkError(let l), .networkError(let r)):
      return (l as NSError) == (r as NSError)
    case (.unknown(let l), .unknown(let r)):
      return (l as NSError) == (r as NSError)
    default:
      return false
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
