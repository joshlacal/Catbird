import Foundation
import Petrel
import Security

/// Minimal generic-password Keychain seam for `CircleKeyStore`.
///
/// Production uses `SystemCircleKeychain`; tests use an in-memory fake. The
/// protocol is deliberately tiny so the backend can later move into the Rust
/// core's SQLCipher database (spec §12, "Option C") behind the same
/// `CircleKeyStore` interface.
protocol CircleKeychain: Sendable {
  func read(service: String, account: String) throws -> Data?
  /// Creates or replaces the item. `accessibility` is a `kSecAttrAccessible*` value.
  func write(service: String, account: String, data: Data, accessibility: String) throws
  func delete(service: String, account: String) throws
  /// Every account name stored under `service`.
  func accounts(service: String) throws -> [String]
}

enum CircleKeychainError: Error, Equatable {
  case status(OSStatus)
}

/// `CircleKeychain` over the Security framework, through Petrel's
/// `KeychainSecItem` (the single funnel every Catbird keychain access uses).
/// Items live in the app's default access group and never sync to iCloud.
struct SystemCircleKeychain: CircleKeychain {
  /// I6: always the data-protection keychain. On macOS the default is the
  /// legacy file keychain, which ignores `kSecAttrAccessible`; on iOS the
  /// flag is a no-op, so it is set unconditionally.
  static func baseQuery(service: String, account: String?) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
      kSecUseDataProtectionKeychain as String: true
    ]
    if let account { query[kSecAttrAccount as String] = account }
    return query
  }

  func read(service: String, account: String) throws -> Data? {
    var query = Self.baseQuery(service: service, account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = KeychainSecItem.copyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess: return result as? Data
    case errSecItemNotFound: return nil
    default: throw CircleKeychainError.status(status)
    }
  }

  func write(service: String, account: String, data: Data, accessibility: String) throws {
    let query = Self.baseQuery(service: service, account: account)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: accessibility
    ]
    let updateStatus = KeychainSecItem.update(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else { throw CircleKeychainError.status(updateStatus) }
    let addQuery = query.merging(attributes) { _, new in new }
    let addStatus = KeychainSecItem.add(addQuery as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw CircleKeychainError.status(addStatus) }
  }

  func delete(service: String, account: String) throws {
    let status = KeychainSecItem.delete(Self.baseQuery(service: service, account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CircleKeychainError.status(status)
    }
  }

  func accounts(service: String) throws -> [String] {
    var query = Self.baseQuery(service: service, account: nil)
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    var result: CFTypeRef?
    let status = KeychainSecItem.copyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      let items = (result as? [[String: Any]]) ?? []
      return items.compactMap { $0[kSecAttrAccount as String] as? String }
    case errSecItemNotFound:
      return []
    default:
      throw CircleKeychainError.status(status)
    }
  }
}

/// Per-account cache of opened Circle key versions and the owner's pending
/// re-wrap list (spec §6 rules 8 and 11, I8).
///
/// Backed by the Keychain: one generic-password item per Space, service
/// `blue.catbird.circles.keys`, account `<accountDID>|<spaceURI>`, accessible
/// after first unlock on this device only, never synced. The item holds a JSON
/// blob `{ "versions": { "<n>": { key, createdAt, reason, senderEpochHead?,
/// recordCID? } }, "pending": { "<did>": "<reason>" }, "lastRewrapAt"?, "members": { "<did>": joinedAtVersion },
/// "migration"?: { eligible: [did], step } }`. The pending list is roster-sensitive,
/// so it lives in the same encrypted item, never in a cache database.
///
/// Reads return raw key `Data` only; nothing here logs or describes key material.
actor CircleKeyStore {
  static let keychainService = "blue.catbird.circles.keys"
  static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

  private let accountDID: String
  private let keychain: any CircleKeychain

  init(accountDID: String, keychain: any CircleKeychain) {
    self.accountDID = accountDID
    self.keychain = keychain
  }

  // MARK: Key versions

  func store(spaceURI: String, keyVersion: UInt64, circleKey: Data, createdAt: Date, reason: String) async throws {
    try mutate(spaceURI) { blob in
      let previous = blob.versions[String(keyVersion)]
      // Replacing the key invalidates the CID of the record it came from.
      let sameKey = previous?.key == circleKey.base64EncodedString()
      blob.versions[String(keyVersion)] = Blob.Version(
        key: circleKey.base64EncodedString(),
        createdAt: Self.formatDate(createdAt),
        reason: reason,
        senderEpochHead: previous?.senderEpochHead,
        recordCID: sameKey ? previous?.recordCID : nil
      )
    }
  }

  func key(spaceURI: String, keyVersion: UInt64) async throws -> Data? {
    try load(spaceURI).versions[String(keyVersion)].flatMap { Data(base64Encoded: $0.key) }
  }

  func versionMeta(spaceURI: String, keyVersion: UInt64) async throws -> (createdAt: Date, reason: String)? {
    guard let entry = try load(spaceURI).versions[String(keyVersion)],
          let date = Self.parseDate(entry.createdAt)
    else { return nil }
    return (createdAt: date, reason: entry.reason)
  }

  func latestVersion(spaceURI: String) async throws -> UInt64? {
    try await allVersions(spaceURI: spaceURI).last
  }

  func allVersions(spaceURI: String) async throws -> [UInt64] {
    try load(spaceURI).versions.keys.compactMap(UInt64.init).sorted()
  }

  /// The owner epoch head embedded in the key record this device last wrote or
  /// opened for `keyVersion` (non-secret; used by `reconcileEpochs`).
  func setSenderEpochHead(spaceURI: String, keyVersion: UInt64, head: Data) async throws {
    try mutate(spaceURI) { blob in
      blob.versions[String(keyVersion)]?.senderEpochHead = head.base64EncodedString()
    }
  }

  func senderEpochHead(spaceURI: String, keyVersion: UInt64) async throws -> Data? {
    try load(spaceURI).versions[String(keyVersion)]?.senderEpochHead.flatMap { Data(base64Encoded: $0) }
  }

  /// CID of the key record this device last wrote, read back or adopted for
  /// `keyVersion` (non-secret; `refreshKeys` re-adopts on a mismatch).
  func setRecordCID(spaceURI: String, keyVersion: UInt64, cid: String) async throws {
    try mutate(spaceURI) { blob in
      blob.versions[String(keyVersion)]?.recordCID = cid
    }
  }

  func recordCID(spaceURI: String, keyVersion: UInt64) async throws -> String? {
    try load(spaceURI).versions[String(keyVersion)]?.recordCID
  }

  /// When the current version was last wrapped to the roster (weekly re-wrap, §6 rule 6).
  func setLastRewrapAt(spaceURI: String, date: Date) async throws {
    try mutate(spaceURI) { $0.lastRewrapAt = Self.formatDate(date) }
  }

  func lastRewrapAt(spaceURI: String) async throws -> Date? {
    try load(spaceURI).lastRewrapAt.flatMap(Self.parseDate)
  }

  // MARK: Per-member history policy

  /// The first key version `did` may receive (§7 per member): the rotated
  /// version for a history-hidden add, 0 (every version) otherwise. 0 removes
  /// the entry; members without an entry count as 0.
  func setJoinedAtVersion(spaceURI: String, did: String, version: UInt64) async throws {
    try mutate(spaceURI) { blob in
      if version == 0 {
        blob.members.removeValue(forKey: did)
      } else {
        blob.members[did] = version
      }
    }
  }

  func joinedAtVersion(spaceURI: String, did: String) async throws -> UInt64 {
    try load(spaceURI).members[did] ?? 0
  }

  func joinedAtVersions(spaceURI: String) async throws -> [String: UInt64] {
    try load(spaceURI).members
  }

  // MARK: Pending re-wraps

  func setPendingRewrap(spaceURI: String, did: String, reason: String) async throws {
    try mutate(spaceURI) { $0.pending[did] = reason }
  }

  func clearPendingRewrap(spaceURI: String, did: String) async throws {
    try mutate(spaceURI) { $0.pending.removeValue(forKey: did) }
  }

  func pendingRewraps(spaceURI: String) async throws -> [(did: String, reason: String)] {
    try load(spaceURI).pending.sorted { $0.key < $1.key }.map { (did: $0.key, reason: $0.value) }
  }

  // MARK: Upgrade plan (D17)

  /// The members `v1` of an upgraded Space is (or will be) wrapped to, and the
  /// next unfinished step (2 key, 3 grants, 4 `migratedTo`). A resumed upgrade
  /// grants only these DIDs, never a freshly computed set.
  func setMigrationPlan(spaceURI: String, eligible: [String], step: Int) async throws {
    try mutate(spaceURI) { $0.migration = Blob.Migration(eligible: eligible, step: step) }
  }

  func migrationPlan(spaceURI: String) async throws -> (eligible: [String], step: Int)? {
    try load(spaceURI).migration.map { (eligible: $0.eligible, step: $0.step) }
  }

  func clearMigrationPlan(spaceURI: String) async throws {
    try mutate(spaceURI) { $0.migration = nil }
  }

  // MARK: Wipe

  /// Returns `true` when at least one Circle key record is stored for `accountDID`.
  nonisolated static func hasStoredKeys(
    accountDID: String,
    keychain: any CircleKeychain = SystemCircleKeychain()
  ) -> Bool {
    let trimmed = accountDID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    let lowerPrefix = trimmed.lowercased() + "|"
    guard let accounts = try? keychain.accounts(service: keychainService) else {
      return false
    }
    return accounts.contains { $0.lowercased().hasPrefix(lowerPrefix) }
  }

  /// Deletes every Circle key item belonging to `accountDID` (sign-out, I8).
  /// A DID never contains `|`, so the account prefix is unambiguous.
  static func wipe(accountDID: String, keychain: any CircleKeychain) throws {
    let prefix = accountDID + "|"
    for account in try keychain.accounts(service: keychainService) where account.hasPrefix(prefix) {
      try keychain.delete(service: keychainService, account: account)
    }
  }

  // MARK: Storage

  private struct Blob: Codable {
    struct Version: Codable {
      var key: String
      var createdAt: String
      var reason: String
      var senderEpochHead: String?
      var recordCID: String?
    }

    struct Migration: Codable {
      var eligible: [String]
      var step: Int
    }

    var versions: [String: Version] = [:]
    var pending: [String: String] = [:]
    var lastRewrapAt: String?
    var members: [String: UInt64] = [:]
    var migration: Migration?

    init() {}

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      versions = try container.decodeIfPresent([String: Version].self, forKey: .versions) ?? [:]
      pending = try container.decodeIfPresent([String: String].self, forKey: .pending) ?? [:]
      lastRewrapAt = try container.decodeIfPresent(String.self, forKey: .lastRewrapAt)
      members = try container.decodeIfPresent([String: UInt64].self, forKey: .members) ?? [:]
      migration = try container.decodeIfPresent(Migration.self, forKey: .migration)
    }
  }

  private func account(_ spaceURI: String) -> String { "\(accountDID)|\(spaceURI)" }

  private func load(_ spaceURI: String) throws -> Blob {
    guard let data = try keychain.read(service: Self.keychainService, account: account(spaceURI)) else {
      return Blob()
    }
    return try JSONDecoder().decode(Blob.self, from: data)
  }

  private func mutate(_ spaceURI: String, _ change: (inout Blob) -> Void) throws {
    var blob = try load(spaceURI)
    change(&blob)
    if blob.versions.isEmpty && blob.pending.isEmpty && blob.members.isEmpty && blob.lastRewrapAt == nil
      && blob.migration == nil {
      try keychain.delete(service: Self.keychainService, account: account(spaceURI))
      return
    }
    let data = try JSONEncoder().encode(blob)
    try keychain.write(
      service: Self.keychainService, account: account(spaceURI), data: data, accessibility: Self.accessibility
    )
  }

  private static func formatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }

  private static func formatDate(_ date: Date) -> String {
    formatter().string(from: date)
  }

  private static func parseDate(_ string: String) -> Date? {
    formatter().date(from: string)
  }
}
