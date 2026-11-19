import Foundation

/// The OAuth scopes the gateway last reported for an account's session, kept so encrypted
/// chat can still be checked when the gateway cannot be reached.
///
/// Only a real gateway answer is ever stored here. The key differs from the retired
/// `blue.catbird.oauth.scopes.<did>`, which held the scopes chat needs rather than the scopes
/// the session holds, so a value left under the old key is never read as a grant.
enum MLSGrantedScopeCache {
  static func key(for did: String) -> String {
    "blue.catbird.oauth.grantedScopes.\(did.lowercased())"
  }

  /// The last gateway answer for `did`, or `nil` when the gateway has never answered.
  static func load(for did: String, defaults: UserDefaults) -> [String]? {
    guard let stored = defaults.stringArray(forKey: key(for: did)), !stored.isEmpty else {
      return nil
    }
    return stored
  }

  static func store(_ scopes: Set<String>, for did: String, defaults: UserDefaults) {
    defaults.set(scopes.sorted(), forKey: key(for: did))
  }
}
