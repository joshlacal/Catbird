import Foundation
import os.log

/// Client-side push suppression policy for accounts whose session ended.
///
/// When an account's session ends (via auth-driven rejection, logout, or account removal),
/// Nest stops server push delivery. Client push suppression provides defense in depth:
/// it hides foreground notifications and neutralizes extension content while server
/// cleanup catches up, while preserving multi-account delivery for active and signed-in
/// inactive accounts.
enum SignedOutPushSuppression {
  enum Presence: Equatable, Sendable {
    /// Launching or switching accounts: nothing is decided, so nothing is suppressed.
    case unknown
    /// No account is active, but a stored account whose session never ended can still
    /// receive pushes: only recipients whose session ended are suppressed.
    case noActiveAccount
    /// No account on this device is signed in: every push is for a signed-out account.
    case signedOut
    case signedIn(accountDID: String)
  }

  static let appGroupSuiteName = "group.blue.catbird.shared"
  /// The active account as push suppression sees it, published only by `publish`. Kept apart
  /// from `activeAccountDID`, which the widgets and App Intents read as "an account is signed in"
  /// and which `writeAccountsToAppGroup` removes on sign-out.
  static let pushActiveAccountDIDKey = "pushActiveAccountDID"
  static let signedOutKey = "signedOutForPush"
  static let sessionEndedAccountDIDsKey = "sessionEndedPushAccountDIDs"
  static let sessionEndedAccountLimit = 16

  private static let logger = Logger(
    subsystem: "blue.catbird", category: "SignedOutPushSuppression")

  /// Presence for a lifecycle. The sign-in screen is not "every account signed out": signing
  /// out of one account, or its session expiring, leaves the other stored accounts signed in
  /// with their push registrations intact. It is `.signedOut` only when every stored account's
  /// session ended (or none is stored).
  @MainActor
  static func presence(
    for lifecycle: AppLifecycle,
    registeredAccountDIDs: [String],
    sessionEndedAccountDIDs: [String]
  ) -> Presence {
    switch lifecycle {
    case .launching:
      return .unknown
    case .unauthenticated:
      let hasSignedInAccount = registeredAccountDIDs.contains { !sessionEndedAccountDIDs.contains($0) }
      return hasSignedInAccount ? .noActiveAccount : .signedOut
    case .authenticated(let state), .deactivated(let state), .takendown(let state):
      return .signedIn(accountDID: state.userDID)
    }
  }

  static func suppresses(
    recipientDID: String?,
    presence: Presence,
    sessionEndedAccountDIDs: [String]
  ) -> Bool {
    switch presence {
    case .unknown:
      return false
    case .signedOut:
      return true
    case .noActiveAccount:
      return isEndedRecipient(recipientDID, activeDID: nil, sessionEndedAccountDIDs: sessionEndedAccountDIDs)
    case .signedIn(let activeDID):
      return isEndedRecipient(recipientDID, activeDID: activeDID, sessionEndedAccountDIDs: sessionEndedAccountDIDs)
    }
  }

  /// Whether a named recipient is an account whose session ended and that is not the active
  /// account. A recipient that is not named is never guessed.
  static func isEndedRecipient(
    _ recipientDID: String?,
    activeDID: String?,
    sessionEndedAccountDIDs: [String]
  ) -> Bool {
    guard let recipientDID, !recipientDID.isEmpty, recipientDID != activeDID else {
      return false
    }
    return sessionEndedAccountDIDs.contains(recipientDID)
  }

  /// The recipient a push names outright: the extension writes `recipientDid` once it resolves
  /// one, and older payloads carry `recipient_did`.
  static func namedRecipientDID(in userInfo: [AnyHashable: Any]) -> String? {
    (userInfo["recipientDid"] as? String) ?? (userInfo["recipient_did"] as? String)
  }

  static func sessionEndedAccountDIDs(in defaults: UserDefaults?) -> [String] {
    defaults?.stringArray(forKey: sessionEndedAccountDIDsKey) ?? []
  }

  /// Publishes presence for the extension. A presence change never records an ended session:
  /// the lifecycle also reaches sign-in after a failed switch or a launch without a current
  /// account, when every stored session is intact. Only `recordSessionEndedAccount` records one.
  static func publish(_ presence: Presence, in defaults: UserDefaults?) {
    guard let defaults else { return }

    switch presence {
    case .signedOut:
      defaults.set(true, forKey: signedOutKey)
      defaults.removeObject(forKey: pushActiveAccountDIDKey)

    case .noActiveAccount:
      defaults.removeObject(forKey: signedOutKey)
      defaults.removeObject(forKey: pushActiveAccountDIDKey)

    case .signedIn(let activeDID):
      defaults.removeObject(forKey: signedOutKey)
      defaults.set(activeDID, forKey: pushActiveAccountDIDKey)
      removeEndedAccount(activeDID, in: defaults)

    case .unknown:
      break
    }
  }

  /// Records an account whose session really ended (logout, removal, expiry), so its pushes
  /// stay hidden until it signs in again.
  static func recordSessionEndedAccount(_ accountDID: String, in defaults: UserDefaults?) {
    guard let defaults else { return }
    appendEndedAccount(accountDID, in: defaults)
  }

  private static func appendEndedAccount(_ did: String, in defaults: UserDefaults) {
    let trimmed = did.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("did:") else { return }

    var list = defaults.stringArray(forKey: sessionEndedAccountDIDsKey) ?? []
    list.removeAll { $0 == trimmed }
    list.append(trimmed)
    if list.count > sessionEndedAccountLimit {
      list = Array(list.suffix(sessionEndedAccountLimit))
    }
    defaults.set(list, forKey: sessionEndedAccountDIDsKey)
  }

  private static func removeEndedAccount(_ did: String, in defaults: UserDefaults) {
    let trimmed = did.trimmingCharacters(in: .whitespacesAndNewlines)
    var list = defaults.stringArray(forKey: sessionEndedAccountDIDsKey) ?? []
    if list.contains(trimmed) {
      list.removeAll { $0 == trimmed }
      defaults.set(list, forKey: sessionEndedAccountDIDsKey)
    }
  }
}
