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
    case unknown
    case signedOut
    case signedIn(accountDID: String)
  }

  static let appGroupSuiteName = "group.blue.catbird.shared"
  static let activeAccountDIDKey = "activeAccountDID"
  static let signedOutKey = "signedOutForPush"
  static let sessionEndedAccountDIDsKey = "sessionEndedPushAccountDIDs"
  static let sessionEndedAccountLimit = 16

  private static let logger = Logger(
    subsystem: "blue.catbird", category: "SignedOutPushSuppression")

  @MainActor
  static func presence(for lifecycle: AppLifecycle) -> Presence {
    switch lifecycle {
    case .launching:
      return .unknown
    case .unauthenticated:
      return .signedOut
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
    case .signedIn(let activeDID):
      guard let recipientDID, !recipientDID.isEmpty else {
        return false
      }
      guard recipientDID != activeDID else {
        return false
      }
      return sessionEndedAccountDIDs.contains(recipientDID)
    }
  }

  static func sessionEndedAccountDIDs(in defaults: UserDefaults?) -> [String] {
    defaults?.stringArray(forKey: sessionEndedAccountDIDsKey) ?? []
  }

  static func publish(from old: Presence, to new: Presence, in defaults: UserDefaults?) {
    guard let defaults else { return }

    switch new {
    case .signedOut:
      defaults.set(true, forKey: signedOutKey)
      var didToRecord: String? = nil
      if case .signedIn(let oldDID) = old {
        didToRecord = oldDID
      } else if let persistedDID = defaults.string(forKey: activeAccountDIDKey),
        persistedDID.hasPrefix("did:")
      {
        didToRecord = persistedDID
      }
      if let didToRecord {
        appendEndedAccount(didToRecord, in: defaults)
      }
      // Note: activeAccountDID is preserved for widget display continuity.

    case .signedIn(let activeDID):
      defaults.removeObject(forKey: signedOutKey)
      defaults.set(activeDID, forKey: activeAccountDIDKey)
      removeEndedAccount(activeDID, in: defaults)

    case .unknown:
      break
    }
  }

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
