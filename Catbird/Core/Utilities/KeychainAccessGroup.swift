import Foundation
import OSLog
import Security

/// Resolves the fully-qualified shared keychain access group (`{TeamID}.{suffix}`)
/// used by the app and its extensions.
enum KeychainAccessGroup {
  private static let logger = Logger(subsystem: "blue.catbird", category: "KeychainAccessGroup")

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
      // SecTask APIs are unavailable on iOS; infer the Team ID prefix from the
      // default access group assigned to a throwaway probe item.
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

      return String(defaultAccessGroup[...dot]) + suffix
    #endif
  }
}
