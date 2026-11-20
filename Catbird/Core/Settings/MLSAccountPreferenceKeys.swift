import CryptoKit
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

/// Where the app keeps small copies of encrypted-chat members' profile pictures for the
/// Notification Service Extension.
///
/// The extension shows who sent a message. Fetching the sender's picture at that moment would
/// tell the image server that this device just received a message from that person, so the
/// app saves the pictures ahead of time and the extension only ever reads these files.
enum ChatAvatarFiles {
  static let directoryName = "chat-avatars"

  static func directory(in container: URL) -> URL {
    container.appendingPathComponent(directoryName, isDirectory: true)
  }

  /// The picture for `did`. Named by a hash of the account DID, device fragment dropped.
  static func fileURL(forDID did: String, container: URL) -> URL {
    let trimmed = did.trimmingCharacters(in: .whitespacesAndNewlines)
    let root = trimmed.split(separator: "#", maxSplits: 1).first.map(String.init) ?? trimmed
    let name = SHA256.hash(data: Data(root.lowercased().utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return directory(in: container).appendingPathComponent("\(name).jpg")
  }

  /// Records which remote picture a saved file was made from, so an unchanged picture is not
  /// downloaded again.
  static func sourceRecordURL(for file: URL) -> URL {
    file.appendingPathExtension("source")
  }
}
