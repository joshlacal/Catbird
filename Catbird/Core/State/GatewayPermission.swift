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

  /// Scope for Circle Spaces on the user's own PDS: read_self plus record
  /// create/update/delete in any `blue.catbird.circle` space, and space
  /// create/update/delete management. Raw value is the jacquard-normalized
  /// form (params sorted, `authority=self`/`skey=*` defaults omitted) so it
  /// string-matches the gateway's normalized granted scopes.
  case circleSpaces = "space:blue.catbird.circle?action=create&action=delete&action=read_self&action=update&authority=*&collection=*&manage=create&manage=delete&manage=update"

  /// Same grant as `circleSpaces`, for end-to-end encrypted Circles
  /// (`blue.catbird.circle.encrypted`); scopes are granted per space type.
  case circleEncryptedSpaces = "space:blue.catbird.circle.encrypted?action=create&action=delete&action=read_self&action=update&authority=*&collection=*&manage=create&manage=delete&manage=update"

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
      return String(localized: "Sign in again to continue.", comment: "Permission upgrade error when signed out.")
    case .clientUnavailable:
      return String(localized: "Something went wrong. Please try again.", comment: "Permission upgrade error when client is unavailable.")
    case .stateChanged:
      return String(localized: "Your account changed while this was in progress. Please try again.", comment: "Permission upgrade error when active account changed.")
    case .permissionDenied, .missingGrantedScope:
      return String(localized: "Catbird needs your permission to make this change. Try again and tap Allow when asked.", comment: "Permission upgrade error when OAuth scope grant was denied.")
    case .cancelled:
      return String(localized: "The permission request was cancelled.", comment: "Permission upgrade error when user cancelled.")
    case .alreadyInProgress:
      return String(localized: "Finish the open permission request first.", comment: "Permission upgrade error when another flow is already open.")
    case .upgradeFailed:
      return String(localized: "Couldn’t get permission from your server. Please try again.", comment: "Permission upgrade error when server grant failed.")
    case .invalidCallbackURL:
      return String(localized: "The permission request didn’t finish. Please try again.", comment: "Permission upgrade error when OAuth callback URL is invalid.")
    }
  }
}

