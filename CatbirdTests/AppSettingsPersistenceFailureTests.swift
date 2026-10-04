import Foundation
import SwiftData
import Testing
@testable import Catbird

@Suite("App settings persistence failures", .serialized)
@MainActor
struct AppSettingsPersistenceFailureTests {
  @Test("A failed fetch disables edits and Retry loads confirmed settings")
  func failedFetchRecoversOnRetry() async throws {
    let fixture = try SettingsPersistenceFixture()
    defer { fixture.restoreDefaults() }
    try fixture.seed { $0.theme = "dark" }
    fixture.installBackupSentinels()
    let backups = fixture.backupValues()
    fixture.failFetch = true

    fixture.initialize()
    fixture.settings.theme = "blocked-theme"
    await fixture.drainPublications()

    #expect(fixture.settings.persistenceState == .unavailable)
    #expect(!fixture.settings.canEditPersistedSettings)
    #expect(fixture.scheduledActions.isEmpty)
    #expect(fixture.notifications.isEmpty)
    #expect(fixture.backupValues() == backups)

    fixture.failFetch = false
    fixture.settings.retryPersistence()
    await fixture.drainPublications()

    #expect(fixture.settings.persistenceState == .ready)
    #expect(fixture.settings.canEditPersistedSettings)
    #expect(fixture.settings.theme == "dark")
    #expect(fixture.notifications == [fixture.didA])
    #expect(fixture.saveCount == 0)
    #expect(UserDefaults.standard.string(forKey: "theme") == "dark")
    #expect(AppSettingsModel.sharedDefaults().string(forKey: "theme") == "dark")
  }

  @Test("A failed save retains its attempt without backup, notification, or runtime effects")
  func failedSaveRetainsAttemptForRetry() async throws {
    let fixture = try SettingsPersistenceFixture()
    defer { fixture.restoreDefaults() }
    try fixture.seed { $0.theme = "light" }
    fixture.initialize()
    await fixture.drainPublications()
    let backups = fixture.backupValues()
    var effects = 0

    fixture.settings.theme = "dark"
    fixture.settings.disableHaptics = true
    fixture.settings.afterPendingSave(key: "appearance") { effects += 1 }
    fixture.failSave = true
    fixture.fireLatestSave()
    await fixture.drainPublications()

    #expect(fixture.settings.persistenceState == .saveFailed)
    #expect(!fixture.settings.canEditPersistedSettings)
    #expect(fixture.settings.theme == "light")
    #expect(!fixture.settings.disableHaptics)
    #expect(try fixture.storedRow()?.theme == "light")
    #expect(fixture.settings.pendingChangesDescription.contains("Theme: Dark"))
    #expect(fixture.settings.pendingChangesDescription.contains("Disable Haptics: On"))
    #expect(fixture.backupValues() == backups)
    #expect(fixture.notifications.isEmpty)
    #expect(effects == 0)
    #expect(PlatformHaptics.isEnabled)

    let retainedDescription = fixture.settings.pendingChangesDescription
    let scheduledCount = fixture.scheduledActions.count
    fixture.settings.theme = "blocked-theme"
    fixture.settings.disableHaptics = false
    fixture.settings.setExternalMediaConsent(.hide, for: .youtube)
    #expect(fixture.settings.pendingChangesDescription == retainedDescription)
    #expect(fixture.scheduledActions.count == scheduledCount)

    fixture.failSave = false
    fixture.settings.retryPersistence()
    fixture.settings.retryPersistence()
    await fixture.drainPublications()

    #expect(fixture.settings.persistenceState == .ready)
    #expect(fixture.settings.theme == "dark")
    #expect(fixture.settings.disableHaptics)
    #expect(try fixture.storedRow()?.theme == "dark")
    #expect(try fixture.storedRow()?.disableHaptics == true)
    #expect(fixture.notifications == [fixture.didA])
    #expect(fixture.saveCount == 2)
    #expect(effects == 1)
    #expect(!PlatformHaptics.isEnabled)
    #expect(UserDefaults.standard.string(forKey: "theme") == "dark")
  }

  @Test("Same-account initialization retains a failed or debounced attempt and its original baseline",
        arguments: [false, true])
  func sameAccountReinitializationPreservesAttempt(failFirst: Bool) async throws {
    let fixture = try SettingsPersistenceFixture()
    defer { fixture.restoreDefaults() }
    try fixture.seed { $0.theme = "light" }
    fixture.initialize()
    await fixture.drainPublications()
    fixture.settings.theme = "dark"
    var effects = 0
    fixture.settings.afterPendingSave { effects += 1 }
    if failFirst {
      fixture.failSave = true
      fixture.fireLatestSave()
      fixture.failSave = false
    }
    let retainedDescription = fixture.settings.pendingChangesDescription
    try fixture.updateStoredRow {
      $0.theme = "imported-theme"
      $0.fontSize = "imported-font-size"
    }

    fixture.initialize()
    await fixture.drainPublications()

    #expect(fixture.settings.persistenceState == .saveFailed)
    #expect(fixture.settings.theme == "imported-theme")
    #expect(fixture.settings.fontSize == "imported-font-size")
    #expect(fixture.settings.pendingChangesDescription == retainedDescription)
    #expect(fixture.notifications.isEmpty)
    #expect(effects == 0)

    fixture.settings.retryPersistence()
    await fixture.drainPublications()

    #expect(fixture.settings.theme == "dark")
    #expect(fixture.settings.fontSize == "imported-font-size")
    #expect(try fixture.storedRow()?.fontSize == "imported-font-size")
    #expect(fixture.notifications == [fixture.didA])
    #expect(effects == 1)
  }

  @Test("A failed refetch preserves confirmed getters and the retained attempt across load Retry")
  func failedRefetchRetainsConfirmedSnapshotAndAttempt() async throws {
    let fixture = try SettingsPersistenceFixture()
    defer { fixture.restoreDefaults() }
    try fixture.seed { $0.theme = "light" }
    fixture.initialize()
    await fixture.drainPublications()
    fixture.settings.theme = "dark"
    var effects = 0
    fixture.settings.afterPendingSave { effects += 1 }
    fixture.failSave = true
    fixture.fireLatestSave()
    let retainedDescription = fixture.settings.pendingChangesDescription
    fixture.failFetch = true

    fixture.initialize()
    await fixture.drainPublications()

    #expect(fixture.settings.persistenceState == .unavailable)
    #expect(fixture.settings.theme == "light")
    #expect(fixture.settings.pendingChangesDescription == retainedDescription)
    #expect(fixture.notifications.isEmpty)

    try fixture.updateStoredRow { $0.fontStyle = "serif" }
    fixture.failFetch = false
    fixture.failSave = false
    fixture.settings.retryPersistence()
    await fixture.drainPublications()
    #expect(fixture.settings.persistenceState == .saveFailed)
    #expect(fixture.settings.theme == "light")
    #expect(fixture.settings.fontStyle == "serif")
    #expect(fixture.settings.pendingChangesDescription == retainedDescription)
    #expect(fixture.notifications == [fixture.didA])
    #expect(effects == 0)

    fixture.settings.retryPersistence()
    await fixture.drainPublications()
    #expect(fixture.settings.persistenceState == .ready)
    #expect(fixture.settings.theme == "dark")
    #expect(fixture.settings.fontStyle == "serif")
    #expect(fixture.notifications == [fixture.didA, fixture.didA])
    #expect(effects == 1)
  }

  @Test("Account switches reject stale scheduled saves and queued publication effects")
  func accountSwitchRejectsStaleWork() async throws {
    let fixture = try SettingsPersistenceFixture()
    defer { fixture.restoreDefaults() }
    try fixture.seed { $0.theme = "light" }
    try fixture.seed(accountDID: fixture.didB) { $0.theme = "account-b-theme" }
    fixture.initialize()
    await fixture.drainPublications()
    var effects = 0
    fixture.settings.theme = "discarded-a-theme"
    fixture.settings.afterPendingSave { effects += 1 }
    let staleSave = try #require(fixture.scheduledActions.last)

    fixture.initialize(accountDID: fixture.didB)
    staleSave()
    await fixture.drainPublications()

    #expect(fixture.settings.theme == "account-b-theme")
    #expect(try fixture.storedRow()?.theme == "light")
    #expect(fixture.saveCount == 0)
    #expect(fixture.notifications.isEmpty)
    #expect(effects == 0)

    fixture.initialize()
    await fixture.drainPublications()
    #expect(fixture.settings.persistenceState == .saveFailed)
    #expect(fixture.settings.pendingChangesDescription.contains("discarded-a-theme"))
    #expect(await fixture.settings.resolvePendingChanges(for: fixture.didA, decision: .discard) == .resolved)
    fixture.settings.theme = "saved-a-theme"
    fixture.settings.disableHaptics = true
    fixture.settings.afterPendingSave { effects += 1 }
    #expect(fixture.settings.persistPendingChanges())
    fixture.initialize(accountDID: fixture.didB)
    await fixture.drainPublications()

    #expect(try fixture.storedRow()?.theme == "saved-a-theme")
    #expect(fixture.settings.theme == "account-b-theme")
    #expect(UserDefaults.standard.string(forKey: "theme") == "account-b-theme")
    #expect(AppSettingsModel.sharedDefaults().string(forKey: "theme") == "account-b-theme")
    #expect(PlatformHaptics.isEnabled)
    #expect(fixture.notifications.isEmpty)
    #expect(effects == 0)

    fixture.initialize()
    await fixture.drainPublications()
    #expect(effects == 1)
    var retryEffects = 0
    fixture.settings.theme = "retry-a-theme"
    fixture.settings.afterPendingSave { retryEffects += 1 }
    fixture.failSave = true
    fixture.fireLatestSave()
    #expect(fixture.settings.persistenceState == .saveFailed)
    fixture.failSave = false
    fixture.onFetch = { did in
      guard did == fixture.didA else { return }
      fixture.onFetch = nil
      fixture.initialize(accountDID: fixture.didB)
    }

    fixture.settings.retryPersistence()
    await fixture.drainPublications()

    #expect(fixture.settings.persistenceState == .ready)
    #expect(fixture.settings.theme == "account-b-theme")
    #expect(try fixture.storedRow()?.theme == "saved-a-theme")
    #expect(fixture.notifications.isEmpty)
    #expect(effects == 1)
    #expect(retryEffects == 0)
  }

  @Test("Inactive account and superseded same-DID owners cannot publish global effects",
        arguments: [false, true])
  func inactiveOwnerDoesNotPublishGlobalEffects(sameDID: Bool) async throws {
    let fixture = try SettingsPersistenceFixture()
    defer { fixture.restoreDefaults() }
    try fixture.seed { $0.theme = "light" }
    fixture.initialize()
    await fixture.drainPublications()
    let globalBackups = fixture.globalBackupValues()
    let replacementOwner = AppSettings()
    if sameDID {
      fixture.activeOwner = replacementOwner
    } else {
      fixture.activeDID = fixture.didB
    }
    var effects = 0
    fixture.settings.theme = "dark"
    fixture.settings.disableHaptics = true
    fixture.settings.afterPendingSave { effects += 1 }

    #expect(fixture.settings.persistPendingChanges())
    await fixture.drainPublications()

    #expect(fixture.settings.persistenceState == .ready)
    #expect(try fixture.storedRow()?.theme == "dark")
    #expect(fixture.notifications == [fixture.didA])
    #expect(fixture.globalBackupValues() == globalBackups)
    #expect(UserDefaults.standard.string(forKey: AppSettingsModel.scopedKey("theme", accountDID: fixture.didA)) == "dark")
    #expect(PlatformHaptics.isEnabled)
    #expect(effects == 0)
    withExtendedLifetime(replacementOwner) {}
  }

  @Test("Consecutive saves coalesce effects and publish only the latest confirmed snapshot")
  func latestConfirmedSnapshotCoalescesEffects() async throws {
    let fixture = try SettingsPersistenceFixture()
    defer { fixture.restoreDefaults() }
    try fixture.seed()
    fixture.initialize()
    await fixture.drainPublications()
    var effects: [String] = []
    fixture.settings.afterPendingSave(key: "no-edit") { effects.append("no-edit") }
    fixture.settings.theme = "light"
    fixture.settings.afterPendingSave(key: "appearance") { effects.append("superseded") }
    fixture.settings.afterPendingSave(key: "media") { effects.append("media") }
    #expect(fixture.settings.persistPendingChanges())

    fixture.settings.theme = "dark"
    fixture.settings.afterPendingSave(key: "appearance") { effects.append("latest") }
    #expect(fixture.settings.persistPendingChanges())
    await fixture.drainPublications()

    #expect(fixture.notifications == [fixture.didA])
    #expect(effects.sorted() == ["latest", "media"])
    #expect(UserDefaults.standard.string(forKey: "theme") == "dark")
    fixture.settings.retryPersistence()
    await fixture.drainPublications()
    #expect(fixture.notifications == [fixture.didA])
    #expect(effects.count == 2)
  }

  @Test("Settings saves and failures leave unrelated pending shared-context edits untouched",
        arguments: [false, true])
  func unrelatedSharedContextEditsRemainPending(failFirst: Bool) async throws {
    let fixture = try SettingsPersistenceFixture()
    defer { fixture.restoreDefaults() }
    try fixture.seed()
    try fixture.seed(accountDID: fixture.didB) { $0.fontStyle = "saved-other-font" }
    fixture.initialize()
    await fixture.drainPublications()
    let other = try #require(try SettingsPersistenceFixture.fetchRow(in: fixture.context, accountDID: fixture.didB))
    other.fontStyle = "unsaved-other-font"
    let inserted = AppSettingsModel(accountDID: fixture.didC)
    inserted.theme = "unsaved-new-row"
    fixture.context.insert(inserted)
    fixture.settings.theme = "dark"
    fixture.failSave = failFirst

    #expect(fixture.settings.persistPendingChanges() == !failFirst)
    await fixture.drainPublications()
    #expect(other.fontStyle == "unsaved-other-font")
    #expect(fixture.context.hasChanges)
    #expect(try fixture.storedRow(accountDID: fixture.didB)?.fontStyle == "saved-other-font")
    #expect(try fixture.storedRow(accountDID: fixture.didC) == nil)
    #expect(try SettingsPersistenceFixture.fetchRow(in: fixture.context, accountDID: fixture.didC)?.theme == "unsaved-new-row")

    if failFirst {
      fixture.failSave = false
      fixture.settings.retryPersistence()
      await fixture.drainPublications()
    }
    #expect(try fixture.storedRow()?.theme == "dark")
    #expect(other.fontStyle == "unsaved-other-font")
    #expect(fixture.context.hasChanges)
    #expect(try fixture.storedRow(accountDID: fixture.didB)?.fontStyle == "saved-other-font")
    #expect(try fixture.storedRow(accountDID: fixture.didC) == nil)
  }

  @Test("Saving a draft preserves concurrent unrelated fields and another provider's consent")
  func concurrentChangesMergeWithoutOverwritingUneditedValues() async throws {
    let fixture = try SettingsPersistenceFixture()
    defer { fixture.restoreDefaults() }
    try fixture.seed { $0.theme = "light" }
    fixture.initialize()
    await fixture.drainPublications()
    fixture.settings.theme = "dark"
    fixture.settings.setExternalMediaConsent(.allow, for: .youtube)
    try fixture.updateStoredRow {
      $0.fontStyle = "custom-imported-font"
      $0.setConsent(.hide, for: .spotify)
      $0.externalMediaConsents["future-provider"] = "future-consent"
    }

    #expect(fixture.settings.persistPendingChanges())
    await fixture.drainPublications()

    let stored = try #require(try fixture.storedRow())
    #expect(stored.theme == "dark")
    #expect(stored.fontStyle == "custom-imported-font")
    #expect(stored.consent(for: .youtube) == .allow)
    #expect(stored.consent(for: .spotify) == .hide)
    #expect(stored.externalMediaConsents["future-provider"] == "future-consent")
    #expect(fixture.settings.fontStyle == "custom-imported-font")
    #expect(fixture.settings.externalMediaConsent(for: .spotify) == .hide)
  }

  @Test("Failed first-row creation does not publish or replace widget backups")
  func failedNewRowCreationDoesNotPublishBackups() async throws {
    let fixture = try SettingsPersistenceFixture()
    defer { fixture.restoreDefaults() }
    fixture.installBackupSentinels()
    let backups = fixture.backupValues()
    fixture.failSave = true

    fixture.initialize()
    await fixture.drainPublications()

    #expect(fixture.settings.persistenceState == .unavailable)
    #expect(try fixture.storedRow() == nil)
    #expect(fixture.backupValues() == backups)
    #expect(fixture.notifications.isEmpty)

    fixture.failSave = false
    fixture.settings.retryPersistence()
    await fixture.drainPublications()

    #expect(fixture.settings.persistenceState == .ready)
    #expect(try fixture.storedRow()?.theme == "global-before")
    #expect(AppSettingsModel.sharedDefaults().string(forKey: "theme") == "global-before")
    #expect(fixture.notifications == [fixture.didA])
  }

  @Test("Failed legacy migration preserves the legacy row and commits all values on Retry")
  func failedLegacyMigrationDoesNotLoseSourceRow() async throws {
    let fixture = try SettingsPersistenceFixture()
    defer { fixture.restoreDefaults() }
    let legacy = SettingsPersistenceValues.sample(accountDID: fixture.didA, revision: 1)
    legacy.id = AppSettingsModel.legacySharedId
    fixture.context.insert(legacy)
    try fixture.context.save()
    let expected = SettingsPersistenceValues.values(of: legacy)
    fixture.installBackupSentinels()
    let backups = fixture.backupValues()
    fixture.failSave = true

    fixture.initialize()
    await fixture.drainPublications()

    #expect(fixture.settings.persistenceState == .unavailable)
    #expect(try fixture.storedRow() == nil)
    let retained = try #require(try fixture.storedLegacyRow())
    #expect(SettingsPersistenceValues.values(of: retained) == expected)
    #expect(fixture.backupValues() == backups)
    #expect(fixture.notifications.isEmpty)

    fixture.failSave = false
    fixture.settings.retryPersistence()
    await fixture.drainPublications()

    let migrated = try #require(try fixture.storedRow())
    #expect(SettingsPersistenceValues.values(of: migrated) == expected)
    #expect(SettingsPersistenceValues.values(of: fixture.settings) == expected)
    #expect(try fixture.storedLegacyRow() == nil)
    #expect(fixture.notifications == [fixture.didA])
  }

  @Test("All 42 settings survive detached snapshots, failure rollback, and retained-attempt Retry")
  func allValuesSurviveSnapshotRollbackAndRetry() async throws {
    let fixture = try SettingsPersistenceFixture()
    defer { fixture.restoreDefaults() }
    let baseline = SettingsPersistenceValues.sample(accountDID: fixture.didA, revision: 1)
    baseline.externalMediaConsents["future-provider"] = "future-consent"
    fixture.context.insert(baseline)
    try fixture.context.save()
    let original = SettingsPersistenceValues.values(of: baseline)
    let attempt = SettingsPersistenceValues.sample(accountDID: fixture.didA, revision: 2)
    let expected = SettingsPersistenceValues.values(of: attempt)
    fixture.initialize()
    await fixture.drainPublications()

    #expect(original.count == 42)
    #expect(expected.count == 42)
    #expect(SettingsPersistenceValues.values(of: fixture.settings) == original)
    SettingsPersistenceValues.apply(attempt, to: fixture.settings)
    #expect(SettingsPersistenceValues.values(of: fixture.settings) == expected)
    #expect(fixture.settings.persistenceState == .saving)
    fixture.failSave = true
    fixture.fireLatestSave()
    await fixture.drainPublications()

    #expect(SettingsPersistenceValues.values(of: fixture.settings) == original)
    let storedAfterFailure = try #require(try fixture.storedRow())
    #expect(SettingsPersistenceValues.values(of: storedAfterFailure) == original)
    #expect(fixture.settings.pendingChangesDescription.contains("custom-theme-2"))
    #expect(fixture.settings.pendingChangesDescription.contains("custom-letterSpacing-2"))
    #expect(fixture.settings.pendingChangesDescription.contains("Sensitive Content Scanning:"))
    #expect(fixture.settings.pendingChangesDescription.contains(ExternalMediaProvider.youtube.displayName))

    fixture.failSave = false
    fixture.settings.retryPersistence()
    await fixture.drainPublications()

    let stored = try #require(try fixture.storedRow())
    #expect(SettingsPersistenceValues.values(of: fixture.settings) == expected)
    #expect(SettingsPersistenceValues.values(of: stored) == expected)
    #expect(stored.externalMediaConsents["future-provider"] == "future-consent")
    #expect(fixture.notifications == [fixture.didA])
  }
  @Test("Departure resolution is bound to the originating account and retains failed drafts")
  func pendingDepartureResolution() async throws {
    let fixture = try SettingsPersistenceFixture()
    defer { fixture.restoreDefaults() }
    try fixture.seed { $0.theme = "light" }
    try fixture.seed(accountDID: fixture.didB) { $0.theme = "dark" }
    fixture.initialize()
    await fixture.drainPublications()
    fixture.settings.theme = "account-a-attempt"
    let staleSave = try #require(fixture.scheduledActions.last)
    #expect(fixture.settings.pendingChangesSummary?.accountDID == fixture.didA)
    fixture.failSave = true
    #expect(await fixture.settings.resolvePendingChanges(for: fixture.didA, decision: .save) == .saveFailed)
    #expect(fixture.settings.theme == "light")
    #expect(fixture.settings.hasPendingChanges)
    fixture.failSave = false
    fixture.initialize(accountDID: fixture.didB)
    staleSave()
    #expect(await fixture.settings.resolvePendingChanges(for: fixture.didA, decision: .discard) == .accountChanged)
    #expect(fixture.settings.theme == "dark")
    fixture.initialize()
    #expect(fixture.settings.persistenceState == .saveFailed)
    #expect(fixture.settings.pendingChangesDescription.contains("account-a-attempt"))
    #expect(await fixture.settings.resolvePendingChanges(for: fixture.didA, decision: .save) == .resolved)
    #expect(try fixture.storedRow()?.theme == "account-a-attempt")
    #expect(!fixture.settings.hasPendingChanges)
  }

  @Test("Discard fences scheduled saves and effects without changing confirmed backups")
  func explicitDiscardFencesWork() async throws {
    let fixture = try SettingsPersistenceFixture()
    defer { fixture.restoreDefaults() }
    try fixture.seed { $0.theme = "light" }
    fixture.initialize()
    await fixture.drainPublications()
    let backups = fixture.globalBackupValues()
    var effects = 0
    fixture.settings.theme = "dark"
    fixture.settings.afterPendingSave { effects += 1 }
    let scheduledSave = try #require(fixture.scheduledActions.last)
    #expect(await fixture.settings.resolvePendingChanges(for: fixture.didA, decision: .discard) == .resolved)
    scheduledSave()
    await fixture.drainPublications()
    #expect(fixture.settings.theme == "light")
    #expect(try fixture.storedRow()?.theme == "light")
    #expect(fixture.settings.persistenceState == .ready)
    #expect(!fixture.settings.hasPendingChanges)
    #expect(fixture.globalBackupValues() == backups)
    #expect(fixture.notifications.isEmpty)
    #expect(effects == 0)
    #expect(fixture.saveCount == 0)
  }

  @Test("External media consent commits atomically and retains unknown providers")
  func atomicExternalMediaConsent() async throws {
    let fixture = try SettingsPersistenceFixture()
    defer { fixture.restoreDefaults() }
    try fixture.seed { row in
      row.externalMediaConsents = ["future-provider": "future-choice"]
      row.setConsent(.hide, for: .youtube)
    }
    fixture.initialize()
    await fixture.drainPublications()
    fixture.failSave = true
    #expect(!fixture.settings.applyExternalMediaConsent(.allow, providers: [.youtube, .spotify]))
    #expect(fixture.settings.externalMediaConsent(for: .youtube) == .hide)
    #expect(fixture.settings.externalMediaConsent(for: .spotify) == .undecided)
    #expect(try fixture.storedRow()?.externalMediaConsents["future-provider"] == "future-choice")
    #expect(fixture.settings.hasPendingChanges)
    fixture.failSave = false
    #expect(await fixture.settings.resolvePendingChanges(for: fixture.didA, decision: .save) == .resolved)
    #expect(fixture.settings.externalMediaConsent(for: .youtube) == .allow)
    #expect(fixture.settings.externalMediaConsent(for: .spotify) == .allow)
    #expect(try fixture.storedRow()?.externalMediaConsents["future-provider"] == "future-choice")
  }

  @Test("A pending compatibility effect remains reviewable even when its stored value is unchanged")
  func pendingCompatibilityEffectDescription() async throws {
    let fixture = try SettingsPersistenceFixture()
    defer { fixture.restoreDefaults() }
    try fixture.seed()
    fixture.initialize()
    await fixture.drainPublications()
    var effects = 0
    fixture.settings.hideNonPreferredLanguages = false
    fixture.settings.afterPendingSave(key: "language-filter", description: "Show posts in all reading languages") { effects += 1 }
    fixture.failSave = true
    fixture.fireLatestSave()
    #expect(fixture.settings.pendingChangesDescription.contains("Show posts in all reading languages"))
    #expect(effects == 0)
    fixture.failSave = false
    #expect(await fixture.settings.resolvePendingChanges(for: fixture.didA, decision: .save) == .resolved)
    await fixture.drainPublications()
    #expect(effects == 1)
    #expect(!fixture.settings.hasPendingChanges)
  }

  @Test("Explicit discard can release an account draft after its saved row fails to reload")
  func discardAfterAccountReloadFailure() async throws {
    let fixture = try SettingsPersistenceFixture()
    defer { fixture.restoreDefaults() }
    try fixture.seed { $0.theme = "light" }
    try fixture.seed(accountDID: fixture.didB)
    fixture.initialize()
    fixture.settings.theme = "pending-a"
    fixture.initialize(accountDID: fixture.didB)
    fixture.failFetch = true
    fixture.initialize()
    #expect(fixture.settings.persistenceState == .unavailable)
    #expect(fixture.settings.hasPendingChanges)
    #expect(await fixture.settings.resolvePendingChanges(for: fixture.didA, decision: .discard) == .resolved)
    #expect(!fixture.settings.hasPendingChanges)
    #expect(fixture.settings.persistenceState == .unavailable)
    #expect(!fixture.settings.canEditPersistedSettings)
    fixture.failFetch = false
    #expect(try fixture.storedRow()?.theme == "light")
  }

  @Test("An inactive settings owner cannot allow an external player")
  func inactiveExternalConsentOwnerIsRejected() async throws {
    let fixture = try SettingsPersistenceFixture()
    defer { fixture.restoreDefaults() }
    try fixture.seed()
    fixture.initialize()
    await fixture.drainPublications()
    fixture.activeDID = fixture.didB
    #expect(!fixture.settings.applyExternalMediaConsent(.allow, providers: [.youtube]))
    #expect(fixture.settings.externalMediaConsent(for: .youtube) == .undecided)
    #expect(!fixture.settings.hasPendingChanges)
    #expect(fixture.saveCount == 0)
  }

  @Test("Opening settings preserves every legacy cap and the explicit full system range",
        arguments: AppTextSizeLimit.options.map(\.value))
  func textSizeLimitIsNeverMigrated(value: String) async throws {
    let fixture = try SettingsPersistenceFixture()
    defer { fixture.restoreDefaults() }
    try fixture.seed { $0.maxDynamicTypeSize = value }
    fixture.initialize()
    #expect(fixture.settings.maxDynamicTypeSize == value)
    #expect(try fixture.storedRow()?.maxDynamicTypeSize == value)
    #expect(fixture.saveCount == 0)
    #expect(AppSettingsModel().maxDynamicTypeSize == "accessibility1")
  }

  @Test("System accessibility augments runtime behavior without changing stored choices")
  func systemAccessibilityDoesNotSavePreferences() async throws {
    let fixture = try SettingsPersistenceFixture()
    defer { fixture.restoreDefaults() }
    try fixture.seed()
    fixture.initialize()
    await fixture.drainPublications()
    fixture.settings.refreshSystemAccessibility(.init(reduceMotion: true, prefersCrossfade: true, increaseContrast: true, boldText: true))
    #expect(fixture.settings.effectiveReduceMotion)
    #expect(fixture.settings.effectivePrefersCrossfade)
    #expect(fixture.settings.effectiveIncreaseContrast)
    #expect(fixture.settings.effectiveBoldText)
    #expect(!fixture.settings.reduceMotion)
    #expect(!fixture.settings.increaseContrast)
    #expect(!fixture.settings.boldText)
    #expect(!fixture.settings.hasPendingChanges)
    #expect(fixture.saveCount == 0)
  }

}

@MainActor
private final class SettingsPersistenceFixture {
  let container: ModelContainer
  let context: ModelContext
  let settings = AppSettings()
  let effectWork = AccountServiceWork()
  let didA = "did:plc:settings-a-\(UUID().uuidString)"
  let didB = "did:plc:settings-b-\(UUID().uuidString)"
  let didC = "did:plc:settings-c-\(UUID().uuidString)"
  var failFetch = false
  var failSave = false
  var saveCount = 0
  var onFetch: ((String) -> Void)?
  var scheduledActions: [() -> Void] = []
  var activeDID: String?
  weak var activeOwner: AppSettings?
  private let notificationRecords = SettingsPersistenceNotificationRecords()
  private var notificationObserver: NSObjectProtocol?
  private var savedDefaults: [(UserDefaults, String, Any?)] = []
  private let savedHaptics = PlatformHaptics.isEnabled

  init() throws {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    self.container = try ModelContainer(for: AppSettingsModel.self, configurations: configuration)
    self.context = ModelContext(self.container)
    self.context.autosaveEnabled = false
    self.activeDID = self.didA
    self.activeOwner = self.settings
    let baseKeys = Self.backupKeys
    let accountKeys: [String] = [self.didA, self.didB, self.didC].flatMap { (did: String) -> [String] in
      baseKeys.map { AppSettingsModel.scopedKey($0, accountDID: did) }
    }
    for key in baseKeys + accountKeys + ["lastActiveSettingsAccountDID"] {
      self.savedDefaults.append((.standard, key, UserDefaults.standard.object(forKey: key)))
    }
    let group = AppSettingsModel.sharedDefaults()
    for key in ["theme", "darkThemeMode"] {
      self.savedDefaults.append((group, key, group.object(forKey: key)))
    }
    let notificationRecords = self.notificationRecords
    self.notificationObserver = NotificationCenter.default.addObserver(
      forName: NSNotification.Name("AppSettingsChanged"), object: self.settings, queue: nil
    ) { notification in
      if let did = notification.userInfo?["accountDID"] as? String {
        notificationRecords.append(did)
      }
    }
    self.settings.persistence = .init(
      fetch: { [weak self] context, did in
        guard let self, !self.failFetch else { throw SettingsPersistenceFixtureError.fetch }
        let row = try Self.fetchRow(in: context, accountDID: did)
        self.onFetch?(did)
        return row
      },
      save: { [weak self] context in
        guard let self else { throw SettingsPersistenceFixtureError.save }
        self.saveCount += 1
        if self.failSave { throw SettingsPersistenceFixtureError.save }
        try context.save()
      },
      isActiveAccount: { [weak self] did, owner in
        guard let self else { return false }
        return self.activeDID == did && self.activeOwner === owner
      },
      scheduleSave: { [weak self] action in
        self?.scheduledActions.append(action)
        return nil
      },
      startEffect: { [weak self] operation in
        self?.effectWork.start(operation: operation) != nil
      }
    )
  }

  var notifications: [String] { self.notificationRecords.snapshot() }

  static var backupKeys: [String] {
    ["theme", "darkThemeMode", "accentColor", "fontStyle", "fontSize", "lineSpacing",
     "letterSpacing", "dynamicTypeEnabled", "maxDynamicTypeSize", "useWebViewEmbeds"]
      + ExternalMediaProvider.allCases.map { "externalMediaConsent.\($0.rawValue)" }
  }

  func restoreDefaults() {
    if let notificationObserver { NotificationCenter.default.removeObserver(notificationObserver) }
    self.notificationObserver = nil
    for (defaults, key, value) in self.savedDefaults {
      if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
    PlatformHaptics.isEnabled = self.savedHaptics
  }

  func initialize(accountDID: String? = nil) {
    let did = accountDID ?? self.didA
    self.activeDID = did
    self.activeOwner = self.settings
    self.settings.initialize(with: self.context, accountDID: did)
  }

  func seed(accountDID: String? = nil, configure: (AppSettingsModel) -> Void = { _ in }) throws {
    let row = AppSettingsModel(accountDID: accountDID ?? self.didA)
    configure(row)
    self.context.insert(row)
    try self.context.save()
  }

  static func fetchRow(in context: ModelContext, accountDID: String) throws -> AppSettingsModel? {
    let id = AppSettingsModel.settingsId(for: accountDID)
    return try context.fetch(FetchDescriptor<AppSettingsModel>(predicate: #Predicate { $0.id == id })).first
  }

  func storedRow(accountDID: String? = nil) throws -> AppSettingsModel? {
    try Self.fetchRow(in: ModelContext(self.container), accountDID: accountDID ?? self.didA)
  }

  func storedLegacyRow() throws -> AppSettingsModel? {
    let id = AppSettingsModel.legacySharedId
    let context = ModelContext(self.container)
    return try context.fetch(FetchDescriptor<AppSettingsModel>(predicate: #Predicate { $0.id == id })).first
  }

  func updateStoredRow(_ update: (AppSettingsModel) -> Void) throws {
    let context = ModelContext(self.container)
    context.autosaveEnabled = false
    let row = try #require(try Self.fetchRow(in: context, accountDID: self.didA))
    update(row)
    try context.save()
  }

  func fireLatestSave() {
    guard let action = self.scheduledActions.last else {
      Issue.record("Expected a scheduled settings save")
      return
    }
    action()
  }

  func drainPublications() async {
    for _ in 0..<12 { await Task.yield() }
  }

  func installBackupSentinels() {
    UserDefaults.standard.set("global-before", forKey: "theme")
    UserDefaults.standard.set("global-dark-before", forKey: "darkThemeMode")
    UserDefaults.standard.set("other-account-before", forKey: "lastActiveSettingsAccountDID")
    AppSettingsModel.sharedDefaults().set("widget-before", forKey: "theme")
    AppSettingsModel.sharedDefaults().set("widget-dark-before", forKey: "darkThemeMode")
  }

  func backupValues() -> [String: String] {
    var result = self.globalBackupValues()
    for did in [self.didA, self.didB, self.didC] {
      for key in Self.backupKeys {
        let scoped = AppSettingsModel.scopedKey(key, accountDID: did)
        result[scoped] = String(describing: UserDefaults.standard.object(forKey: scoped))
      }
    }
    return result
  }

  func globalBackupValues() -> [String: String] {
    var result: [String: String] = [:]
    for key in Self.backupKeys + ["lastActiveSettingsAccountDID"] {
      result["standard.\(key)"] = String(describing: UserDefaults.standard.object(forKey: key))
    }
    for key in ["theme", "darkThemeMode"] {
      result["group.\(key)"] = String(describing: AppSettingsModel.sharedDefaults().object(forKey: key))
    }
    return result
  }
}

private enum SettingsPersistenceFixtureError: Error {
  case fetch
  case save
}

private final class SettingsPersistenceNotificationRecords: @unchecked Sendable {
  private let lock = NSLock()
  private var accounts: [String] = []

  func append(_ accountDID: String) {
    self.lock.lock()
    defer { self.lock.unlock() }
    self.accounts.append(accountDID)
  }

  func snapshot() -> [String] {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.accounts
  }
}

@MainActor
private enum SettingsPersistenceValues {
  private static let stringFields: [(String, ReferenceWritableKeyPath<AppSettingsModel, String>, ReferenceWritableKeyPath<AppSettings, String>)] = [
    ("theme", \.theme, \.theme),
    ("darkThemeMode", \.darkThemeMode, \.darkThemeMode),
    ("accentColor", \.accentColor, \.accentColor),
    ("fontStyle", \.fontStyle, \.fontStyle),
    ("fontSize", \.fontSize, \.fontSize),
    ("lineSpacing", \.lineSpacing, \.lineSpacing),
    ("letterSpacing", \.letterSpacing, \.letterSpacing),
    ("maxDynamicTypeSize", \.maxDynamicTypeSize, \.maxDynamicTypeSize),
    ("linkStyle", \.linkStyle, \.linkStyle),
    ("threadSortOrder", \.threadSortOrder, \.threadSortOrder),
    ("appLanguage", \.appLanguage, \.appLanguage),
    ("primaryLanguage", \.primaryLanguage, \.primaryLanguage)
  ]
  private static let boolFields: [(String, ReferenceWritableKeyPath<AppSettingsModel, Bool>, ReferenceWritableKeyPath<AppSettings, Bool>)] = [
    ("dynamicTypeEnabled", \.dynamicTypeEnabled, \.dynamicTypeEnabled),
    ("requireAltText", \.requireAltText, \.requireAltText),
    ("largerAltTextBadges", \.largerAltTextBadges, \.largerAltTextBadges),
    ("disableHaptics", \.disableHaptics, \.disableHaptics),
    ("reduceMotion", \.reduceMotion, \.reduceMotion),
    ("prefersCrossfade", \.prefersCrossfade, \.prefersCrossfade),
    ("increaseContrast", \.increaseContrast, \.increaseContrast),
    ("boldText", \.boldText, \.boldText),
    ("showReadingTimeEstimates", \.showReadingTimeEstimates, \.showReadingTimeEstimates),
    ("highlightLinks", \.highlightLinks, \.highlightLinks),
    ("confirmBeforeActions", \.confirmBeforeActions, \.confirmBeforeActions),
    ("shakeToUndo", \.shakeToUndo, \.shakeToUndo),
    ("enableViaAttribution", \.enableViaAttribution, \.enableViaAttribution),
    ("sensitiveContentScanningEnabled", \.sensitiveContentScanningEnabled, \.sensitiveContentScanningEnabled),
    ("autoplayVideos", \.autoplayVideos, \.autoplayVideos),
    ("useInAppBrowser", \.useInAppBrowser, \.useInAppBrowser),
    ("showTrendingTopics", \.showTrendingTopics, \.showTrendingTopics),
    ("showTrendingVideos", \.showTrendingVideos, \.showTrendingVideos),
    ("prioritizeFollowedUsers", \.prioritizeFollowedUsers, \.prioritizeFollowedUsers),
    ("threadedReplies", \.threadedReplies, \.threadedReplies),
    ("showHiddenPosts", \.showHiddenPosts, \.showHiddenPosts),
    ("showSavedFeedSamples", \.showSavedFeedSamples, \.showSavedFeedSamples),
    ("useWebViewEmbeds", \.useWebViewEmbeds, \.useWebViewEmbeds),
    ("hideNonPreferredLanguages", \.hideNonPreferredLanguages, \.hideNonPreferredLanguages),
    ("showLanguageIndicators", \.showLanguageIndicators, \.showLanguageIndicators),
    ("loggedOutVisibility", \.loggedOutVisibility, \.loggedOutVisibility)
  ]
  private static let doubleFields: [(String, ReferenceWritableKeyPath<AppSettingsModel, Double>, ReferenceWritableKeyPath<AppSettings, Double>)] = [
    ("displayScale", \.displayScale, \.displayScale),
    ("longPressDuration", \.longPressDuration, \.longPressDuration)
  ]

  static func sample(accountDID: String, revision: Int) -> AppSettingsModel {
    let model = AppSettingsModel(accountDID: accountDID)
    for (name, path, _) in self.stringFields { model[keyPath: path] = "custom-\(name)-\(revision)" }
    for (index, field) in self.boolFields.enumerated() {
      model[keyPath: field.1] = (index + revision).isMultiple(of: 2)
    }
    model.displayScale = revision == 1 ? 0.85 : 1.25
    model.longPressDuration = revision == 1 ? 0.35 : 0.75
    model.contentLanguages = revision == 1 ? ["fr-CA", "ja"] : ["es-MX", "uk", "ko"]
    let consents: [ExternalMediaConsent] = [.undecided, .allow, .hide]
    for (index, provider) in ExternalMediaProvider.allCases.enumerated() {
      model.setConsent(consents[(index + revision) % consents.count], for: provider)
    }
    return model
  }

  static func apply(_ model: AppSettingsModel, to settings: AppSettings) {
    for (_, source, target) in self.stringFields { settings[keyPath: target] = model[keyPath: source] }
    for (_, source, target) in self.boolFields { settings[keyPath: target] = model[keyPath: source] }
    for (_, source, target) in self.doubleFields { settings[keyPath: target] = model[keyPath: source] }
    settings.contentLanguages = model.contentLanguages
    for provider in ExternalMediaProvider.allCases {
      settings.setExternalMediaConsent(model.consent(for: provider), for: provider)
    }
  }

  static func values(of model: AppSettingsModel) -> [String: String] {
    var result: [String: String] = [:]
    for (name, path, _) in self.stringFields { result[name] = model[keyPath: path] }
    for (name, path, _) in self.boolFields { result[name] = String(model[keyPath: path]) }
    for (name, path, _) in self.doubleFields { result[name] = String(model[keyPath: path]) }
    result["contentLanguages"] = model.contentLanguages.joined(separator: "|")
    result["externalMediaConsents"] = ExternalMediaProvider.allCases.map {
      "\($0.rawValue):\(model.consent(for: $0).rawValue)"
    }.joined(separator: "|")
    return result
  }

  static func values(of settings: AppSettings) -> [String: String] {
    var result: [String: String] = [:]
    for (name, _, path) in self.stringFields { result[name] = settings[keyPath: path] }
    for (name, _, path) in self.boolFields { result[name] = String(settings[keyPath: path]) }
    for (name, _, path) in self.doubleFields { result[name] = String(settings[keyPath: path]) }
    result["contentLanguages"] = settings.contentLanguages.joined(separator: "|")
    result["externalMediaConsents"] = ExternalMediaProvider.allCases.map {
      "\($0.rawValue):\(settings.externalMediaConsent(for: $0).rawValue)"
    }.joined(separator: "|")
    return result
  }
}
