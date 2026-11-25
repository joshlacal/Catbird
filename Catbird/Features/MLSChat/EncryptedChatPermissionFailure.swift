import Foundation

/// Why asking the account's server for encrypted-chat permission didn't work, in two parts:
/// one plain sentence for the person, and the server's own words for support.
struct EncryptedChatPermissionFailure: Equatable, Sendable {
  /// One plain sentence saying what went wrong and whose problem it is.
  let message: String
  /// The underlying error text, shown only under Details.
  let detail: String?

  init(message: String, detail: String? = nil) {
    self.message = message
    let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.detail = (trimmed?.isEmpty ?? true) ? nil : trimmed
  }

  /// The server granted something, but encrypted chat still lacks `missing`.
  static func partialGrant(missing: [String]) -> EncryptedChatPermissionFailure {
    EncryptedChatPermissionFailure(
      message: String(
        localized: "Your server gave only some of the permission encrypted chat needs. Try again, and allow everything it asks for.",
        comment: "Encrypted chat permission: server granted a partial set"
      ),
      detail: missing.isEmpty ? nil : "Still missing:\n" + missing.joined(separator: "\n")
    )
  }

  /// Encrypted chat couldn't start on this device at all.
  static let unavailable = EncryptedChatPermissionFailure(
    message: String(
      localized: "Encrypted chat isn’t available right now. Please try again.",
      comment: "Encrypted chat permission: coordinator unavailable"
    )
  )

  /// Sorts a failed permission request into a sentence that says what happened.
  ///
  /// The upgrade flow reports most failures as `GatewayPermissionError.upgradeFailed` with the
  /// server's message inside, so the message text is what tells the cases apart.
  init(error: Error) {
    let underlying: String? = {
      if case .upgradeFailed(let message)? = error as? GatewayPermissionError {
        return message
      }
      return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }()
    let text = (underlying ?? "").lowercased()

    if let permissionError = error as? GatewayPermissionError {
      switch permissionError {
      case .unauthenticated, .stateChanged, .permissionDenied, .missingGrantedScope,
        .cancelled, .alreadyInProgress, .invalidCallbackURL, .clientUnavailable:
        self.init(message: permissionError.errorDescription ?? "", detail: nil)
        return
      case .upgradeFailed:
        break
      }
    }

    let message: String
    if text.contains("exceeds configured maximum")
      || text.contains("non-allowlisted")
      || text.contains("not allowlisted")
      || text.contains("invalid scope requested")
    {
      message = String(
        localized: "Catbird’s server can’t ask for this permission yet. This is a problem on Catbird’s side, not yours.",
        comment: "Encrypted chat permission: gateway not configured for the scopes"
      )
    } else if text.contains("authorization initiation failed") {
      message = String(
        localized: "Your account’s server turned down the request before asking you. Catbird’s server log says why.",
        comment: "Encrypted chat permission: the account's server rejected the authorization request"
      )
    } else if text.contains("expired") || text.contains("log in again") {
      message = String(
        localized: "Your sign-in has expired. Sign in again to continue.",
        comment: "Encrypted chat permission: gateway session expired"
      )
    } else if text.contains("temporarily unavailable") {
      message = String(
        localized: "Catbird’s server is busy. Try again in a few minutes.",
        comment: "Encrypted chat permission: gateway temporarily unavailable"
      )
    } else if text.contains("network error") {
      message = String(
        localized: "Couldn’t reach Catbird’s server. Check your connection and try again.",
        comment: "Encrypted chat permission: network error"
      )
    } else {
      message = String(
        localized: "Your server didn’t give permission. The details below say what it answered.",
        comment: "Encrypted chat permission: unclassified server failure"
      )
    }
    self.init(message: message, detail: underlying)
  }
}
