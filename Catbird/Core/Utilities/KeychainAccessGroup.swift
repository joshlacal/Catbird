import Foundation
import OSLog
import Security

/// Resolves the fully-qualified shared keychain access group (`{TeamID}.{suffix}`)
/// used by the app and its extensions.
enum KeychainAccessGroup {
  private static let logger = Logger(subsystem: "blue.catbird", category: "KeychainAccessGroup")

  /// The Team ID prefix, remembered in memory and in the app's own defaults.
  /// Only `resolved(suffix:)` on iOS reads it; macOS asks the entitlement directly.
  static let teamPrefixStore = TeamPrefixStore(
    defaults: .standard,
    key: "keychain_team_prefix_\(Bundle.main.bundleIdentifier ?? "blue.catbird")",
    plistPrefix: Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String
  )

  /// Clears in-memory and persisted team prefix cache (e.g. on keychain entitlement failure)
  static func invalidateCache() {
    teamPrefixStore.invalidate()
  }

  /// - Parameter suffix: The access group suffix (e.g. "blue.catbird.shared")
  /// - Returns: The fully-qualified access group, or nil if resolution fails
  static func resolved(suffix: String) -> String? {
    #if os(macOS) || targetEnvironment(macCatalyst)
      guard let task = SecTaskCreateFromSelf(nil),
            let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil),
            let groups = value as? [String]
      else {
        logger.error("Failed to read keychain-access-groups entitlement")
        return nil
      }
      return groups.first(where: { $0.hasSuffix(suffix) })
    #else
      let prefix = teamPrefixStore.prefix(
        isEntitled: { candidate in isEntitled(toGroup: candidate + suffix, prefix: candidate) },
        probe: probeTeamPrefix
      )
      return prefix.map { $0 + suffix }
    #endif
  }

  /// Caches the Team ID prefix ("ABCDE12345."). It holds no keychain code, so
  /// tests can drive it with stand-in checks.
  ///
  /// Order: the in-memory value; a non-empty Info.plist `AppIdentifierPrefix`;
  /// the stored prefix, if well formed and `isEntitled` accepts it (otherwise it
  /// is cleared); then `probe`, whose result is remembered only when it succeeds.
  /// The lock is never held while `isEntitled` or `probe` run, so the main
  /// thread doesn't wait on another thread's keychain call.
  final class TeamPrefixStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let plistPrefix: String?
    private let lock = NSLock()
    private var cached: String?

    init(defaults: UserDefaults, key: String, plistPrefix: String?) {
      self.defaults = defaults
      self.key = key
      self.plistPrefix = plistPrefix
    }

    func prefix(isEntitled: (String) -> Bool, probe: () -> String?) -> String? {
      if let cached = cachedPrefix() {
        return cached
      }

      if let plistPrefix = Self.normalizedPlistPrefix(plistPrefix) {
        setCachedPrefix(plistPrefix)
        return plistPrefix
      }

      if let stored = defaults.string(forKey: key), !stored.isEmpty {
        if Self.isWellFormed(stored), isEntitled(stored) {
          setCachedPrefix(stored)
          return stored
        }
        if !Self.isWellFormed(stored) {
          KeychainAccessGroup.logger.warning("Cached keychain team prefix is malformed; clearing cache")
        }
        defaults.removeObject(forKey: key)
        setCachedPrefix(nil)
      }

      guard let probed = probe(), Self.isWellFormed(probed) else { return nil }
      setCachedPrefix(probed)
      defaults.set(probed, forKey: key)
      return probed
    }

    func invalidate() {
      setCachedPrefix(nil)
      defaults.removeObject(forKey: key)
    }

    private func cachedPrefix() -> String? {
      lock.lock()
      defer { lock.unlock() }
      return cached
    }

    private func setCachedPrefix(_ prefix: String?) {
      lock.lock()
      cached = prefix
      lock.unlock()
    }

    /// The plist value with a trailing dot, or nil when it is missing, empty or
    /// still the unexpanded build-setting literal.
    private static func normalizedPlistPrefix(_ value: String?) -> String? {
      guard let value, !value.isEmpty, !value.contains("$(") else { return nil }
      let normalized = value.hasSuffix(".") ? value : value + "."
      return isWellFormed(normalized) ? normalized : nil
    }

    /// One dot-free segment followed by a dot, as the probe produces.
    private static func isWellFormed(_ prefix: String) -> Bool {
      prefix.count > 1 && prefix.hasSuffix(".") && !prefix.dropLast().contains(".")
    }
  }

  #if !(os(macOS) || targetEnvironment(macCatalyst))
  /// Checks a stored prefix cheaply: a read query returns errSecMissingEntitlement
  /// (-34018) when the group isn't one this app may use.
  private static func isEntitled(toGroup group: String, prefix: String) -> Bool {
    let validateQuery: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrAccessGroup: group,
      kSecMatchLimit: kSecMatchLimitOne,
      kSecReturnAttributes: false,
    ]
    let status = SecItemCopyMatching(validateQuery as CFDictionary, nil)
    if status == errSecMissingEntitlement {
      logger.warning("Cached keychain team prefix \(prefix) invalid (status \(status)); clearing cache")
      return false
    }
    return true
  }

  /// SecTask APIs are unavailable on iOS; infer the Team ID prefix from the
  /// default access group assigned to a throwaway probe item as fallback.
  private static func probeTeamPrefix() -> String? {
    logger.info("Probing keychain for access group prefix (cache miss)")
    let probeService = "blue.catbird.accessGroupProbe"
    let probeAccount = UUID().uuidString

    let addQuery: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: probeService,
      kSecAttrAccount: probeAccount,
      kSecValueData: Data([0]),
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    if addStatus != errSecSuccess && addStatus != errSecDuplicateItem {
      logger.error("Access group probe SecItemAdd failed: \(addStatus)")
    }

    defer {
      let deleteQuery: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: probeService,
        kSecAttrAccount: probeAccount,
      ]
      SecItemDelete(deleteQuery as CFDictionary)
    }

    let matchQuery: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: probeService,
      kSecAttrAccount: probeAccount,
      kSecReturnAttributes: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(matchQuery as CFDictionary, &item) == errSecSuccess,
          let attributes = item as? [CFString: Any],
          let defaultAccessGroup = attributes[kSecAttrAccessGroup] as? String,
          let dot = defaultAccessGroup.firstIndex(of: ".")
    else {
      logger.error("Failed to resolve default keychain access group")
      return nil
    }

    return String(defaultAccessGroup[...dot])
  }
  #endif
}
