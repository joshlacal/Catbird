import Foundation
import OSLog
import Security

/// One-time removal of on-device data written by the MLS chat stack, which Catbird Lite
/// does not ship. TestFlight builds created these files, Keychain items and defaults;
/// Lite never reads them again, so they are deleted once per install.
///
/// The inventory is deliberately exact. Everything else in the App Group, Application
/// Support (including `default.store` and `swiftdata/`), and the Keychain is untouched.
/// In particular Petrel OAuth tokens share the Keychain access group, use `blue.catbird.*`
/// accounts and carry no service attribute, so nothing here matches by account or group.
enum LegacyMLSDataPurge {
  static let completionKey = "blue.catbird.lite.mlsPurge.v1"
  static let appGroupIdentifier = "group.blue.catbird.shared"

  /// CatbirdMLSCore's storage generation suffix.
  static let storageSuffix = "clean-v2-openmls-v09-r2"

  /// Directories at the root of the App Group container.
  static let appGroupDirectoryNames: [String] = [
    "mls-state-\(storageSuffix)",
    "MLS-\(storageSuffix)",
    "epoch-checkpoints-\(storageSuffix)",
    "mls_welcome_gate-\(storageSuffix)",
    "mls-coordination-\(storageSuffix)",
    "mls-state",
    "MLS",
  ]

  /// Directories inside the app's own `Library/Caches`.
  static let cachesDirectoryNames: [String] = ["mls-images"]

  /// Generic-password services deleted by exact match.
  static let keychainServices: Set<String> = [
    "blue.catbird.mls",
    "blue.catbird.mls.signature",
    "blue.catbird.mls.groupkey",
    "blue.catbird.mls.content",
    "blue.catbird.mls.accessGroupProbe",
  ]

  /// Per-DID generic-password services: `blue.catbird.mls.hybrid.<did>.<suffix>`.
  static let hybridKeychainServicePrefix = "blue.catbird.mls.hybrid."

  /// `kSecClassKey` signature keys: `blue.catbird.mls.sig.<identity>`.
  static let signatureKeyTagPrefix = "blue.catbird.mls.sig."

  /// Case-sensitive key prefixes removed from standard and App Group defaults.
  static let userDefaultsKeyPrefixes: [String] = [
    "mls_",
    "mls.",
    "blue.catbird.mls.",
    "MLSPlaintextHeaderMigrationV1",
    "MLSRustFFIMigrationV1",
    "mlsChatNotificationsEnabled_",
  ]

  private static let logger = Logger(subsystem: "blue.catbird", category: "LegacyMLSPurge")

  // MARK: - Predicates

  static func isLegacyMLSDefaultsKey(_ key: String) -> Bool {
    userDefaultsKeyPrefixes.contains { key.hasPrefix($0) }
  }

  static func isLegacyMLSKeychainService(_ service: String) -> Bool {
    keychainServices.contains(service) || service.hasPrefix(hybridKeychainServicePrefix)
  }

  static func isLegacyMLSSignatureKeyTag(_ tag: String) -> Bool {
    tag.hasPrefix(signatureKeyTagPrefix)
  }

  // MARK: - Entry Point

  /// Runs the purge unless it already completed on this install. Synchronous and
  /// nonisolated; the app calls it from a detached utility task so launch never waits.
  static func runOnceIfNeeded() {
    let standard = UserDefaults.standard
    guard !standard.bool(forKey: completionKey) else { return }

    let removedDirectories = removeDirectories()
    let keychain = removeKeychainItems()
    var removedDefaults = removeDefaults(from: standard, domainName: Bundle.main.bundleIdentifier)
    if let groupDefaults = UserDefaults(suiteName: appGroupIdentifier) {
      removedDefaults += removeDefaults(from: groupDefaults, domainName: appGroupIdentifier)
    }

    logger.notice(
      "Legacy MLS purge: directories=\(removedDirectories) keychainItems=\(keychain.removed) keychainErrors=\(keychain.errors) defaults=\(removedDefaults)"
    )

    // A locked Keychain (e.g. background launch before first unlock) means the
    // attempt did not happen; try again next launch. Other errors are non-fatal.
    if keychain.lockedOut {
      logger.notice("Legacy MLS purge deferred: Keychain unavailable while device is locked")
      return
    }
    standard.set(true, forKey: completionKey)
  }

  // MARK: - Files

  private static func removeDirectories() -> Int {
    let fileManager = FileManager.default
    var targets: [URL] = []
    if let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
      targets += appGroupDirectoryNames.map { container.appendingPathComponent($0, isDirectory: true) }
    }
    if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
      targets += cachesDirectoryNames.map { caches.appendingPathComponent($0, isDirectory: true) }
    }

    var removed = 0
    for url in targets where fileManager.fileExists(atPath: url.path) {
      do {
        try fileManager.removeItem(at: url)
        removed += 1
      } catch {
        logger.error("Legacy MLS purge could not remove a directory: \(error.localizedDescription, privacy: .public)")
      }
    }
    return removed
  }

  // MARK: - Keychain

  private struct KeychainOutcome {
    var removed = 0
    var errors = 0
    var lockedOut = false

    mutating func record(_ status: OSStatus) {
      switch status {
      case errSecSuccess: removed += 1
      case errSecItemNotFound: break
      case errSecInteractionNotAllowed: lockedOut = true
      default: errors += 1
      }
    }
  }

  private static func removeKeychainItems() -> KeychainOutcome {
    var outcome = KeychainOutcome()

    // Exact services. No access group in the query, so every group the app is
    // entitled to is searched.
    for service in keychainServices.sorted() {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
      ]
      outcome.record(SecItemDelete(query as CFDictionary))
    }

    // Per-DID hybrid services, found by enumeration and deleted by persistent reference.
    let genericPasswords = enumerate(kSecClassGenericPassword, outcome: &outcome)
    for item in genericPasswords {
      guard let service = item[kSecAttrService as String] as? String,
            service.hasPrefix(hybridKeychainServicePrefix) else { continue }
      outcome.record(deleteItem(kSecClassGenericPassword, attributes: item))
    }

    // Signature keys stored as kSecClassKey with an application tag.
    let keys = enumerate(kSecClassKey, outcome: &outcome)
    for item in keys {
      guard let tag = applicationTag(of: item), isLegacyMLSSignatureKeyTag(tag) else { continue }
      outcome.record(deleteItem(kSecClassKey, attributes: item))
    }

    return outcome
  }

  private static func enumerate(_ itemClass: CFString, outcome: inout KeychainOutcome) -> [[String: Any]] {
    let query: [String: Any] = [
      kSecClass as String: itemClass,
      kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
      kSecReturnAttributes as String: true,
      kSecReturnPersistentRef as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else {
      outcome.record(status)
      return []
    }
    return result as? [[String: Any]] ?? []
  }

  private static func deleteItem(_ itemClass: CFString, attributes: [String: Any]) -> OSStatus {
    guard let persistentRef = attributes[kSecValuePersistentRef as String] as? Data else {
      return errSecParam
    }
    let query: [String: Any] = [
      kSecClass as String: itemClass,
      kSecValuePersistentRef as String: persistentRef,
    ]
    return SecItemDelete(query as CFDictionary)
  }

  private static func applicationTag(of attributes: [String: Any]) -> String? {
    switch attributes[kSecAttrApplicationTag as String] {
    case let data as Data: String(data: data, encoding: .utf8)
    case let string as String: string
    default: nil
    }
  }

  // MARK: - UserDefaults

  private static func removeDefaults(from defaults: UserDefaults, domainName: String?) -> Int {
    let keys: [String]
    if let domainName, let domain = defaults.persistentDomain(forName: domainName) {
      keys = Array(domain.keys)
    } else {
      keys = Array(defaults.dictionaryRepresentation().keys)
    }
    let matches = keys.filter(isLegacyMLSDefaultsKey)
    for key in matches {
      defaults.removeObject(forKey: key)
    }
    return matches.count
  }
}
