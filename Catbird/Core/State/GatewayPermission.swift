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

  /// Plain-language text shown to users. The underlying detail (scope names, server
  /// messages) is logged where the error is thrown.
  public var errorDescription: String? {
    switch self {
    case .unauthenticated:
      return "Sign in again to continue."
    case .clientUnavailable:
      return "Something went wrong. Please try again."
    case .stateChanged:
      return "Your account changed while this was in progress. Please try again."
    case .permissionDenied, .missingGrantedScope:
      return "Catbird needs your permission to make this change. Try again and tap Allow when asked."
    case .cancelled:
      return "The permission request was cancelled."
    case .alreadyInProgress:
      return "Finish the open permission request first."
    case .upgradeFailed:
      return "Couldn’t get permission from your server. Please try again."
    case .invalidCallbackURL:
      return "The permission request didn’t finish. Please try again."
    }
  }
}

