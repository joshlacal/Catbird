import Foundation
import Petrel

/// Progressive OAuth gateway permissions requested just-in-time on user action.
public enum GatewayPermission: String, CaseIterable, Sendable, Hashable, Equatable {
  /// Scope for updating account handle (`com.atproto.identity.updateHandle`).
  case identityHandle = "identity:handle"

  /// Scope for managing account email and email 2FA settings (`com.atproto.server.updateEmail`, etc.).
  case accountEmailManage = "account:email?action=manage"

  /// Scope for managing account status such as deactivation (`com.atproto.server.deactivateAccount`).
  case accountStatusManage = "account:status?action=manage"

  /// The raw OAuth scope string requested from the authorization server.
  public var scopeString: String {
    rawValue
  }

  /// The fixed callback URL redirected by the Nest gateway on completion of scope upgrade.
  public static let permissionCallbackURL = URL(string: "https://catbird.blue/oauth/permission-callback")!
}

/// Errors that may occur during progressive gateway permission requests.
public enum GatewayPermissionError: LocalizedError, Equatable, Sendable {
  /// The user is not currently authenticated.
  case unauthenticated

  /// The ATProto client is unavailable.
  case clientUnavailable

  /// The active account, client, or AppState changed during the upgrade flow (e.g., account switch or logout).
  case stateChanged

  /// The requested permission was denied by the server or authorization server.
  case permissionDenied

  /// The specific permission scope was missing in the returned grant.
  case missingGrantedScope(GatewayPermission)

  /// The permission flow was cancelled by the user.
  case cancelled

  /// Another permission upgrade flow is currently in progress.
  case alreadyInProgress

  /// The upgrade failed with an underlying message or reason.
  case upgradeFailed(String)

  /// The returned callback URL was invalid.
  case invalidCallbackURL

  public var errorDescription: String? {
    switch self {
    case .unauthenticated:
      return "Cannot request permission without an active authenticated session."
    case .clientUnavailable:
      return "Authentication client is not available."
    case .stateChanged:
      return "The active account or authentication state changed during permission upgrade."
    case .permissionDenied:
      return "The requested permission was not granted."
    case .missingGrantedScope(let permission):
      return "The required scope '\(permission.rawValue)' was not granted by the server."
    case .cancelled:
      return "Permission request was cancelled."
    case .alreadyInProgress:
      return "A permission upgrade flow is already in progress."
    case .upgradeFailed(let message):
      return "Permission upgrade failed: \(message)"
    case .invalidCallbackURL:
      return "The permission callback URL was invalid or malformed."
    }
  }
}

