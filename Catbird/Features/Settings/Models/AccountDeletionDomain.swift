import Foundation

/// A local handoff to the provider's account settings, never a deletion request.
struct AccountDeletionTarget: Identifiable, Equatable {
  enum Purpose: Equatable {
    case manageAccount
    case deletionOptions
  }
  let id = UUID()
  let did: String
  let handle: String?
  let accountRevision: UInt64
  var purpose: Purpose = .deletionOptions
}

struct AccountDeletionFlow {
  enum Phase: Equatable {
    case ready
    case opening(UUID)
    case opened
    case failed
    case unavailable
    case accountChanged
    case cancelled
  }

  struct OpeningAttempt {
    let id: UUID
    let url: URL
  }

  let target: AccountDeletionTarget
  private(set) var phase = Phase.ready
  /// The destination never carries account or session details.
  private(set) var destination: AccountManagementPageResolver.Destination?

  var isResolvingDestination: Bool { phase == .ready && destination == nil }

  var canOpen: Bool {
    guard destination != nil else { return false }
    switch phase {
    case .ready, .opened, .failed:
      return !target.did.isEmpty
    case .opening, .unavailable, .accountChanged, .cancelled:
      return false
    }
  }

  /// Verifies destination URL safety: HTTPS, valid host, no credentials/fragments,
  /// and only permits a scoped login_hint query parameter while rejecting sensitive tokens.
  static func isSafeDestinationURL(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.scheme?.lowercased() == "https",
          let host = components.host, !host.isEmpty,
          components.user == nil, components.password == nil,
          components.fragment == nil else {
      return false
    }
    if let queryItems = components.queryItems {
      guard queryItems.count == 1,
            let item = queryItems.first,
            item.name == "login_hint",
            let value = item.value, !value.isEmpty else {
        return false
      }
    }
    return true
  }

  /// Verifies a resolved hosting PDS origin for direct non-OAuth deletion XRPC calls:
  /// strictly HTTPS, valid non-empty host, and zero embedded credentials, query, or fragment.
  static func isSafeDirectPDSEndpoint(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.scheme?.lowercased() == "https",
          let host = components.host, !host.isEmpty,
          components.user == nil, components.password == nil,
          components.query == nil,
          components.fragment == nil
    else {
      return false
    }
    return true
  }

  /// Late discovery cannot attach a destination to a changed or cancelled account context.
  mutating func resolveDestination(
    _ result: AccountManagementPageResolver.Destination?,
    currentDID: String,
    currentRevision: UInt64
  ) {
    accountDidChange(to: currentDID, revision: currentRevision)
    guard phase == .ready, destination == nil else { return }
    guard let result else {
      phase = .unavailable
      return
    }
    guard Self.isSafeDestinationURL(result.url) else {
      phase = .unavailable
      return
    }
    destination = result
  }

  mutating func prepareToOpen(currentDID: String, currentRevision: UInt64) -> OpeningAttempt? {
    accountDidChange(to: currentDID, revision: currentRevision)
    guard canOpen, let destination else { return nil }
    let attempt = OpeningAttempt(id: UUID(), url: destination.url)
    phase = .opening(attempt.id)
    return attempt
  }

  mutating func finishOpening(_ attemptID: UUID, accepted: Bool, currentDID: String, currentRevision: UInt64) {
    guard phase == .opening(attemptID) else { return }
    accountDidChange(to: currentDID, revision: currentRevision)
    guard phase == .opening(attemptID) else { return }
    // OS acceptance of a URL is not confirmation of provider account deletion.
    phase = accepted ? .opened : .failed
  }

  mutating func accountDidChange(to currentDID: String, revision: UInt64) {
    guard phase != .cancelled else { return }
    if target.did.isEmpty || currentDID != target.did || revision != target.accountRevision {
      phase = .accountChanged
      destination = nil
    }
  }

  mutating func cancel() {
    phase = .cancelled
  }
}

enum PDSDirectDeletionError: Error, LocalizedError, Equatable, Sendable {
  case invalidPDSEndpoint
  case missingPassword
  case missingConfirmationToken
  case authFactorTokenRequired(message: String)
  case invalidCredentials(statusCode: Int, errorCode: String?, message: String?)
  case expiredToken(message: String?)
  case invalidToken(message: String?)
  case pdsRejected(statusCode: Int, errorCode: String?, message: String?)

  var errorDescription: String? {
    switch self {
    case .invalidPDSEndpoint:
      return "Your hosting provider endpoint is invalid or insecure."
    case .missingPassword:
      return "Enter your account password to continue."
    case .missingConfirmationToken:
      return "Enter the confirmation code sent to your email."
    case .authFactorTokenRequired:
      return "Two-factor sign-in is enabled on your account. Check your email for a 2FA code, enter it above, and try again."
    case .invalidCredentials(_, _, let message):
      if let message, !message.isEmpty {
        return "Incorrect password or credentials (\(message)). If your hosting provider uses passwordless OAuth only, use the provider website option below."
      }
      return "Incorrect account password. Verify your password or use the provider website option below if your provider uses passwordless sign-in."
    case .expiredToken:
      return "That confirmation code has expired. Request a new email confirmation code and try again."
    case .invalidToken:
      return "That confirmation code is invalid. Check the code from your email and try again."
    case .pdsRejected(let statusCode, _, let message):
      if let message, !message.isEmpty {
        return "Your hosting provider declined the deletion request (HTTP \(statusCode): \(message))."
      }
      return "Your hosting provider declined the deletion request (HTTP \(statusCode))."
    }
  }
}

/// Proof that the app showed the dedicated remote-backup erasure warning before hosted deletion.
///
/// AT Protocol exposes no non-consuming deletion-code validation endpoint. Catbird must erase its
/// remote encrypted data while the account session still exists, and the unified erasure operation
/// also retires the local encrypted-chat store. A rejected code can therefore leave the hosted
/// account intact after that encrypted history is gone. Keeping this as a required argument prevents
/// a caller from silently folding that irreversible tradeoff into a generic account-deletion prompt.
enum HostedAccountDeletionRemoteErasureConsent: Sendable {
  case explicitlyConfirmed
}

/// Fail-closed sequencing for the hosted account deletion boundary.
///
/// AT Protocol has no non-consuming endpoint for validating an email deletion code. After password
/// authentication succeeds, remote encrypted history must be erased while its authenticated session
/// still exists, before the PDS consumes the email code. If the PDS rejects that code, local account
/// state remains available so the user can obtain a replacement code and retry.
@MainActor
enum HostedAccountDeletionSequence {
  static func run<Session>(
    password: String,
    confirmationToken: String,
    remoteErasureConsent: HostedAccountDeletionRemoteErasureConsent,
    authenticateHostedAccount: () async throws -> Session,
    eraseRemoteEncryptedData: () async throws -> Void,
    deleteHostedAccount: (Session, String) async throws -> Void,
    eraseRemainingLocalData: () async throws -> Void
  ) async throws {
    let trimmedToken = confirmationToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedToken.isEmpty else {
      throw PDSDirectDeletionError.missingConfirmationToken
    }
    guard !password.isEmpty else {
      throw PDSDirectDeletionError.missingPassword
    }
    switch remoteErasureConsent {
    case .explicitlyConfirmed:
      break
    }

    let session = try await authenticateHostedAccount()
    try await eraseRemoteEncryptedData()
    try await deleteHostedAccount(session, trimmedToken)
    try await eraseRemainingLocalData()
  }
}

