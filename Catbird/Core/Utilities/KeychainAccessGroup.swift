import Foundation
import OSLog
import Security

/// Resolves the fully-qualified shared keychain access group (`{TeamID}.{suffix}`)
/// used by the app and its extensions.
enum KeychainAccessGroup {
  private static let logger = Logger(subsystem: "blue.catbird", category: "KeychainAccessGroup")
  private static let lock = NSLock()
  private static var cachedTeamPrefix: String?
  /// Clears in-memory and persisted team prefix cache (e.g. on keychain entitlement failure)
  static func invalidateCache() {
    lock.lock()
    cachedTeamPrefix = nil
    lock.unlock()
    let bundleID = Bundle.main.bundleIdentifier ?? "blue.catbird"
    UserDefaults.standard.removeObject(forKey: "keychain_team_prefix_\(bundleID)")
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
      lock.lock()
      if let cached = cachedTeamPrefix {
        lock.unlock()
        return cached + suffix
      }
      lock.unlock()

      // Check Info.plist AppIdentifierPrefix if configured
      if let plistPrefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
         !plistPrefix.isEmpty {
        let normalized = plistPrefix.hasSuffix(".") ? plistPrefix : plistPrefix + "."
        lock.lock()
        cachedTeamPrefix = normalized
        lock.unlock()
        return normalized + suffix
      }

      // Check UserDefaults cache keyed by bundle identifier
      let bundleID = Bundle.main.bundleIdentifier ?? "blue.catbird"
      let cacheKey = "keychain_team_prefix_\(bundleID)"
      if let persisted = UserDefaults.standard.string(forKey: cacheKey), !persisted.isEmpty {
        let candidateGroup = persisted + suffix
        // Validate candidate prefix cheaply: a read query returns errSecMissingEntitlement (-34018) if the group is invalid
        let validateQuery: [CFString: Any] = [
          kSecClass: kSecClassGenericPassword,
          kSecAttrAccessGroup: candidateGroup,
          kSecMatchLimit: kSecMatchLimitOne,
          kSecReturnAttributes: false,
        ]
        let status = SecItemCopyMatching(validateQuery as CFDictionary, nil)
        if status != errSecMissingEntitlement {
          lock.lock()
          cachedTeamPrefix = persisted
          lock.unlock()
          return candidateGroup
        }
        logger.warning("Cached keychain team prefix \(persisted) invalid (status \(status)); clearing cache")
        UserDefaults.standard.removeObject(forKey: cacheKey)
        lock.lock()
        cachedTeamPrefix = nil
        lock.unlock()
      }

      // SecTask APIs are unavailable on iOS; infer the Team ID prefix from the
      // default access group assigned to a throwaway probe item as fallback.
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

      let prefix = String(defaultAccessGroup[...dot])
      lock.lock()
      cachedTeamPrefix = prefix
      lock.unlock()
      UserDefaults.standard.set(prefix, forKey: cacheKey)
      return prefix + suffix
    #endif
  }
}
