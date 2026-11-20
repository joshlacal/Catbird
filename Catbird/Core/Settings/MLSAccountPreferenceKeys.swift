import Foundation

/// App Group keys for per-account encrypted chat state that the app and the Notification
/// Service Extension both read.
///
/// Every key is built from the account DID hash (`MLSAppGroupStorage.accountDidHash(for:)`),
/// the same value a push wake carries, so the extension can look a value up without
/// resolving or storing the raw DID.
enum MLSAccountPreferenceKeys {
  static let appGroupSuiteName = "group.blue.catbird.shared"

  /// `true` once the user has turned encrypted chat off for the account.
  /// Only an explicit user choice writes it; failures never do.
  static func userDisabled(accountHash: String) -> String {
    "mlsUserDisabled_\(normalized(accountHash))"
  }

  /// `true` once the user has continued past the encrypted chat introduction, or turned
  /// encrypted chat on or off themselves.
  static func introAcknowledged(accountHash: String) -> String {
    "mlsIntroAcknowledged_\(normalized(accountHash))"
  }

  /// Time of the first successful device enrollment for the account (seconds since 1970).
  static func enrolledAt(accountHash: String) -> String {
    "mlsEnrolledAt_\(normalized(accountHash))"
  }

  /// The user's encrypted chat notification preference.
  static func chatNotificationsEnabled(accountHash: String) -> String {
    "mlsChatNotificationsEnabled_\(normalized(accountHash))"
  }

  /// Whether notifications for the account's encrypted chats show the sender and the message
  /// text. When off, the extension shows "New encrypted message" and does not open the chat keys.
  static func chatNotificationPreviewsEnabled(accountHash: String) -> String {
    "mlsChatNotificationPreviewsEnabled_\(normalized(accountHash))"
  }

  /// The stored preview preference. On until the user turns it off.
  static func showsChatNotificationPreviews(accountHash: String, defaults: UserDefaults?) -> Bool {
    defaults?.object(forKey: chatNotificationPreviewsEnabled(accountHash: accountHash)) as? Bool ?? true
  }

  static func normalized(_ accountHash: String) -> String {
    accountHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
