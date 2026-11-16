//
//  ExperimentalSettings.swift
//  Catbird
//
//  Per-account encrypted chat preferences and the AppView draft sync opt-in.
//

import CatbirdMLSCore
import OSLog
import SwiftUI
import os

/// Per-account encrypted chat (MLS) preferences and the AppView draft sync opt-in.
///
/// Encrypted chat is on for every account. It runs once the account has seen the one-time
/// introduction, because the first device enrollment publishes device key records to the
/// user's repository. The user can turn it off per account; only that choice is stored, in
/// the App Group so the Notification Service Extension honours it too.
@Observable
final class ExperimentalSettings {
  static let shared: ExperimentalSettings = {
    let settings = ExperimentalSettings(
      appGroupDefaults: UserDefaults(suiteName: MLSAccountPreferenceKeys.appGroupSuiteName) ?? .standard,
      standardDefaults: .standard
    )
    settings.migrateLegacyMLSOptInIfNeeded()
    return settings
  }()

  @ObservationIgnored private let logger = Logger(subsystem: "blue.catbird", category: "ExperimentalSettings")
  @ObservationIgnored private let appGroupDefaults: UserDefaults
  @ObservationIgnored private let standardDefaults: UserDefaults
  @ObservationIgnored private let hashAccountDID: @Sendable (String) -> String?
  @ObservationIgnored private let accountHashCache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

  // MARK: - Storage keys

  /// Pre-225 per-account opt-in (standard defaults). Read only by the one-time migration.
  static let legacyMLSOptInKeyPrefix = "blue.catbird.mls.optedIn."

  /// Pre-225 per-account warning acknowledgement (standard defaults). Still honoured as a
  /// seen introduction so accounts that already enrolled are not asked again.
  static let legacyMLSWarningAcknowledgedKeyPrefix = "blue.catbird.mls.warningAcknowledged."

  /// Marks that the one-time migration of the pre-225 opt-in values has run (standard defaults).
  static let legacyMLSOptInMigrationKey = "blue.catbird.mls.optInMigration.v225"

  /// Values earlier builds cached from the gateway client configuration. Nothing reads them.
  static let retiredRuntimeConfigurationKeys = ["mls_public_beta_enabled", "circles_public_beta_enabled"]

  /// Storage key for AppView draft sync opt-in
  private static let draftSyncEnabledKey = "blue.catbird.draftSync.enabled"

  init(
    appGroupDefaults: UserDefaults,
    standardDefaults: UserDefaults,
    hashAccountDID: @escaping @Sendable (String) -> String? = { try? MLSAppGroupStorage.accountDidHash(for: $0) }
  ) {
    self.appGroupDefaults = appGroupDefaults
    self.standardDefaults = standardDefaults
    self.hashAccountDID = hashAccountDID
  }

  // MARK: - Draft Sync (AppView-stored drafts)

  /// Whether composer drafts are synced to the Bluesky AppView (app.bsky.draft.*).
  /// Defaults to OFF as a current-main safety gate; an explicit opt-in is
  /// required even though the translation and synchronization path exists.
  var draftSyncEnabled: Bool {
    get { standardDefaults.bool(forKey: Self.draftSyncEnabledKey) }
    set {
      standardDefaults.set(newValue, forKey: Self.draftSyncEnabledKey)
      logger.info("Draft sync \(newValue ? "enabled" : "disabled")")
    }
  }

  // MARK: - Per-account encrypted chat

  /// The account's DID hash, or `nil` for an empty or malformed DID.
  func accountHash(for accountDID: String) -> String? {
    let trimmed = accountDID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let cached = accountHashCache.withLock({ $0[trimmed] }) {
      return cached
    }
    guard let hash = hashAccountDID(trimmed) else { return nil }
    accountHashCache.withLock { $0[trimmed] = hash }
    return hash
  }

  /// Whether encrypted chat is on for the account: `true` unless the user turned it off.
  func isMLSChatEnabled(for accountDID: String) -> Bool {
    guard let hash = accountHash(for: accountDID) else { return false }
    return !appGroupDefaults.bool(forKey: MLSAccountPreferenceKeys.userDisabled(accountHash: hash))
  }

  /// Whether the user turned encrypted chat off for the account.
  func isMLSUserDisabled(for accountDID: String) -> Bool {
    guard let hash = accountHash(for: accountDID) else { return false }
    return appGroupDefaults.bool(forKey: MLSAccountPreferenceKeys.userDisabled(accountHash: hash))
  }

  /// Whether the account has seen the encrypted chat introduction (or made its own choice).
  func hasSeenMLSIntro(for accountDID: String) -> Bool {
    guard let hash = accountHash(for: accountDID) else { return false }
    if appGroupDefaults.bool(forKey: MLSAccountPreferenceKeys.introAcknowledged(accountHash: hash)) {
      return true
    }
    return standardDefaults.bool(forKey: Self.legacyMLSWarningAcknowledgedKeyPrefix + accountDID)
  }

  /// Whether MLS storage, enrollment and network work may run for the account.
  func isMLSRuntimeAllowed(for accountDID: String) -> Bool {
    isMLSChatEnabled(for: accountDID) && hasSeenMLSIntro(for: accountDID)
  }

  /// Whether the one-time encrypted chat introduction should be shown for the account.
  func shouldPresentMLSIntro(for accountDID: String) -> Bool {
    guard accountHash(for: accountDID) != nil else { return false }
    return isMLSChatEnabled(for: accountDID) && !hasSeenMLSIntro(for: accountDID)
  }

  /// The user continued past the introduction or turned encrypted chat on.
  func enableMLSChat(for accountDID: String) {
    guard let hash = accountHash(for: accountDID) else { return }
    appGroupDefaults.set(true, forKey: MLSAccountPreferenceKeys.introAcknowledged(accountHash: hash))
    appGroupDefaults.removeObject(forKey: MLSAccountPreferenceKeys.userDisabled(accountHash: hash))
    logger.info("Encrypted chat turned on for account: \(accountDID.prefix(20))...")
  }

  /// The user turned encrypted chat off, or chose "Not now" on the introduction.
  /// Only a user choice may call this; enrollment or eligibility failures never do.
  func disableMLSChat(for accountDID: String) {
    guard let hash = accountHash(for: accountDID) else { return }
    appGroupDefaults.set(true, forKey: MLSAccountPreferenceKeys.introAcknowledged(accountHash: hash))
    appGroupDefaults.set(true, forKey: MLSAccountPreferenceKeys.userDisabled(accountHash: hash))
    logger.info("Encrypted chat turned off for account: \(accountDID.prefix(20))...")
  }

  /// Records a successful device enrollment for the account.
  func recordMLSEnrollment(for accountDID: String, at date: Date = Date()) {
    guard let hash = accountHash(for: accountDID) else { return }
    let key = MLSAccountPreferenceKeys.enrolledAt(accountHash: hash)
    guard appGroupDefaults.object(forKey: key) == nil else { return }
    appGroupDefaults.set(date.timeIntervalSince1970, forKey: key)
  }

  /// Whether this device ever enrolled the account for encrypted chat.
  func hasRecordedMLSEnrollment(for accountDID: String) -> Bool {
    guard let hash = accountHash(for: accountDID) else { return false }
    return appGroupDefaults.object(forKey: MLSAccountPreferenceKeys.enrolledAt(accountHash: hash)) != nil
  }

  /// Removes every encrypted chat preference for the account.
  func resetMLSSettings(for accountDID: String) {
    standardDefaults.removeObject(forKey: Self.legacyMLSOptInKeyPrefix + accountDID)
    standardDefaults.removeObject(forKey: Self.legacyMLSWarningAcknowledgedKeyPrefix + accountDID)
    if let hash = accountHash(for: accountDID) {
      appGroupDefaults.removeObject(forKey: MLSAccountPreferenceKeys.userDisabled(accountHash: hash))
      appGroupDefaults.removeObject(forKey: MLSAccountPreferenceKeys.introAcknowledged(accountHash: hash))
      appGroupDefaults.removeObject(forKey: MLSAccountPreferenceKeys.enrolledAt(accountHash: hash))
    }
    logger.info("Encrypted chat settings reset for account: \(accountDID.prefix(20))...")
  }

  // MARK: - One-time migration

  /// Runs once per install. Earlier builds stored an opt-in that defaulted to off and was also
  /// written as `false` after enrollment or eligibility failures, so a stored `false` does not
  /// show what the user chose. Those values are dropped and the account sees the introduction
  /// again; a stored `true` keeps its acknowledgement. Cached gateway configuration values are
  /// removed as well.
  func migrateLegacyMLSOptInIfNeeded() {
    guard !standardDefaults.bool(forKey: Self.legacyMLSOptInMigrationKey) else { return }

    let prefix = Self.legacyMLSOptInKeyPrefix
    let legacyKeys = standardDefaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
    for key in legacyKeys {
      let accountDID = String(key.dropFirst(prefix.count))
      if !standardDefaults.bool(forKey: key) {
        standardDefaults.removeObject(forKey: Self.legacyMLSWarningAcknowledgedKeyPrefix + accountDID)
      }
      standardDefaults.removeObject(forKey: key)
    }

    for key in Self.retiredRuntimeConfigurationKeys {
      appGroupDefaults.removeObject(forKey: key)
      standardDefaults.removeObject(forKey: key)
    }

    standardDefaults.set(true, forKey: Self.legacyMLSOptInMigrationKey)
    logger.info("Migrated \(legacyKeys.count) legacy encrypted chat opt-in value(s)")
  }
}
