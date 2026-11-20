import CryptoKit
import Foundation

/// Matches the account hash a push carries (`recipient_account`, the SHA-256 of the account
/// DID) to an account signed in on this device.
enum PushAccountMatching {
  static let appGroupSuiteName = "group.blue.catbird.shared"
  /// The signed-in account DIDs the app publishes for its extensions.
  static let knownAccountDIDsKey = "knownAccountDIDs"

  /// The first of `candidates` whose DID hashes to `hash`, or nil.
  static func accountDID(matchingHash hash: String, among candidates: [String]) -> String? {
    let wanted = hash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard wanted.count == 64 else { return nil }
    for did in candidates {
      let normalized = did.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if sha256Hex(did) == wanted || sha256Hex(normalized) == wanted {
        return did
      }
    }
    return nil
  }

  /// The account DIDs last published to the App Group. Readable before the account list has
  /// loaded, which is the state the app is in when a notification tap launches it.
  static func publishedAccountDIDs(
    defaults: UserDefaults? = UserDefaults(suiteName: appGroupSuiteName)
  ) -> [String] {
    defaults?.stringArray(forKey: knownAccountDIDsKey) ?? []
  }

  private static func sha256Hex(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
