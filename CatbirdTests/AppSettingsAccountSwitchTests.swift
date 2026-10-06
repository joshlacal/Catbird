import Foundation
import SwiftData
import Testing
@testable import Catbird

@Suite("App settings account switch barrier", .serialized)
@MainActor
struct AppSettingsAccountSwitchTests {
  @Test("Suspension rejects every ordinary ingress and retains a failed final save")
  func closedIngressAndFailedSave() async throws {
    let fixture = try LocalSettingsSwitchFixture()
    defer { fixture.cleanUp() }
    await fixture.settle()
    let globalTheme = fixture.defaults.string(forKey: "theme")
    var effects = 0
    fixture.settings.theme = "dark"
    fixture.settings.afterPendingSave { effects += 1 }
    let staleSave = try #require(fixture.scheduled.last)
    #expect(fixture.settings.suspendLocalChanges(for: fixture.did))
    #expect(!fixture.settings.canEditPersistedSettings)
    fixture.settings.theme = "blocked"
    fixture.settings.retryPersistence()
    fixture.settings.afterPendingSave { effects += 100 }
    #expect(!fixture.settings.persistPendingChanges(for: fixture.did))
    #expect(await fixture.settings.resolvePendingChanges(for: fixture.did, decision: .discard) == .unavailable)
    staleSave()
    #expect(fixture.saveCount == 0)
    fixture.failSave = true
    #expect(!fixture.settings.flushPendingChangesForAccountSwitch(for: fixture.did))
    #expect(fixture.settings.accountSwitchFlushFailure == .saveFailed)
    await fixture.settle()
    #expect(fixture.settings.hasPendingChanges)
    #expect(fixture.settings.pendingChangesDescription.contains("Theme: Dark"))
    #expect(fixture.defaults.string(forKey: "theme") == globalTheme)
    #expect(fixture.notifications.isEmpty && effects == 0)
    fixture.isActive = false
    #expect(!fixture.settings.resumeLocalChanges(for: fixture.did))
    fixture.isActive = true
    #expect(fixture.settings.resumeLocalChanges(for: fixture.did))
    fixture.failSave = false
    #expect(await fixture.settings.resolvePendingChanges(for: fixture.did, decision: .save) == .resolved)
    await fixture.settle()
    #expect(try fixture.storedTheme() == "dark")
    #expect(effects == 1)
  }

  @Test("Closed flush saves the row but refuses retirement until its follow-up effect finishes")
  func closedFlushDefersPublication() async throws {
    let fixture = try LocalSettingsSwitchFixture()
    defer { fixture.cleanUp() }
    await fixture.settle()
    let globalTheme = fixture.defaults.string(forKey: "theme")
    var effects = 0
    fixture.settings.theme = "dark"
    fixture.settings.afterPendingSave { effects += 1 }
    #expect(fixture.settings.suspendLocalChanges(for: fixture.did))
    #expect(!fixture.settings.flushPendingChangesForAccountSwitch(for: fixture.did))
    #expect(fixture.settings.accountSwitchFlushFailure == .unfinishedChanges)
    await fixture.settle()
    #expect(try fixture.storedTheme() == "dark")
    #expect(fixture.defaults.string(forKey: AppSettingsModel.scopedKey("theme", accountDID: fixture.did)) == "dark")
    #expect(fixture.defaults.string(forKey: "theme") == globalTheme)
    #expect(fixture.notifications.isEmpty && effects == 0)
    #expect(fixture.settings.hasPendingChanges)
    #expect(fixture.settings.resumeLocalChanges(for: fixture.did))
    await fixture.settle()
    #expect(fixture.defaults.string(forKey: "theme") == "dark")
    #expect(effects == 1 && !fixture.settings.hasPendingChanges)
  }

  @Test("An unavailable store with no local draft does not block account switching")
  func unavailableWithoutDraft() async throws {
    let fixture = try LocalSettingsSwitchFixture(failInitialFetch: true)
    defer { fixture.cleanUp() }
    #expect(fixture.settings.persistenceState == .unavailable)
    #expect(fixture.settings.suspendLocalChanges(for: fixture.did))
    #expect(fixture.settings.flushPendingChangesForAccountSwitch(for: fixture.did))
    #expect(fixture.settings.accountSwitchFlushFailure == nil)
    #expect(!fixture.settings.flushPendingChangesForAccountSwitch(for: "did:plc:another"))
    #expect(fixture.saveCount == 0)
  }

  @Test("An admitted but unstarted effect survives cancellation and starts once after resume")
  func unstartedEffectSurvivesSuspension() async throws {
    let fixture = try LocalSettingsSwitchFixture()
    defer { fixture.cleanUp() }
    await fixture.settle()
    var admitted: [@MainActor () async -> Void] = []
    fixture.settings.persistence.startEffect = { admitted.append($0); return true }
    var effects = 0
    fixture.settings.theme = "dark"
    fixture.settings.afterPendingSave { effects += 1 }
    #expect(fixture.settings.persistPendingChanges(for: fixture.did))
    await fixture.settle()
    #expect(admitted.count == 1 && fixture.settings.hasPendingChanges)
    #expect(fixture.settings.suspendLocalChanges(for: fixture.did))
    await admitted[0]()
    #expect(effects == 0 && fixture.settings.hasPendingChanges)
    #expect(!fixture.settings.flushPendingChangesForAccountSwitch(for: fixture.did))
    #expect(fixture.settings.accountSwitchFlushFailure == .unfinishedChanges)
    #expect(fixture.settings.resumeLocalChanges(for: fixture.did))
    await fixture.settle()
    #expect(admitted.count == 2)
    await admitted[1]()
    #expect(effects == 1 && !fixture.settings.hasPendingChanges)
  }

  @Test("An already started effect remains in the real account service drain")
  func startedEffectIsDrained() async throws {
    let fixture = try LocalSettingsSwitchFixture()
    defer { fixture.cleanUp() }
    await fixture.settle()
    var continuation: CheckedContinuation<Void, Never>?
    var completed = false
    fixture.settings.theme = "dark"
    fixture.settings.afterPendingSave {
      await withCheckedContinuation { continuation = $0 }
      completed = true
    }
    #expect(fixture.settings.persistPendingChanges(for: fixture.did))
    await fixture.settle()
    #expect(continuation != nil)
    #expect(fixture.settings.suspendLocalChanges(for: fixture.did))
    #expect(!fixture.settings.flushPendingChangesForAccountSwitch(for: fixture.did))
    #expect(fixture.settings.accountSwitchFlushFailure == .unfinishedChanges)
    fixture.work.suspend()
    var drained = false
    let drain = Task { @MainActor in
      try await fixture.work.drain(timeout: .seconds(1))
      drained = true
    }
    await fixture.settle()
    #expect(!drained && !completed)
    continuation?.resume()
    try await drain.value
    #expect(drained && completed)
    #expect(fixture.settings.flushPendingChangesForAccountSwitch(for: fixture.did))
  }

  @Test("Successful retirement cannot lose the retained Show All language-filter action")
  func retirementWaitsForLanguageCompatibilityAction() async throws {
    let fixture = try LocalSettingsSwitchFixture()
    defer { fixture.cleanUp() }
    await fixture.settle()
    var legacyLanguageFilterEnabled = true
    var retired = false
    fixture.settings.hideNonPreferredLanguages = false
    fixture.settings.afterPendingSave(key: "language-filter", description: "Show posts in all reading languages") {
      legacyLanguageFilterEnabled = false
    }
    #expect(fixture.settings.suspendLocalChanges(for: fixture.did))
    fixture.work.suspend()
    try await fixture.work.drain(timeout: .seconds(1))
    if fixture.settings.flushPendingChangesForAccountSwitch(for: fixture.did) { retired = true }
    #expect(!retired)
    #expect(fixture.settings.accountSwitchFlushFailure == .unfinishedChanges)
    #expect(legacyLanguageFilterEnabled && fixture.settings.hasPendingChanges)
    #expect(fixture.settings.pendingChangesDescription.contains("Show posts in all reading languages"))
    let saved = try ModelContext(fixture.container).fetch(FetchDescriptor<AppSettingsModel>()).first
    #expect(saved?.hideNonPreferredLanguages == false)
    fixture.work.resume()
    #expect(fixture.settings.resumeLocalChanges(for: fixture.did))
    await fixture.settle()
    #expect(!legacyLanguageFilterEnabled && !fixture.settings.hasPendingChanges)
    #expect(fixture.settings.suspendLocalChanges(for: fixture.did))
    fixture.work.suspend()
    try await fixture.work.drain(timeout: .seconds(1))
    if fixture.settings.flushPendingChangesForAccountSwitch(for: fixture.did) { retired = true }
    #expect(retired && fixture.settings.accountSwitchFlushFailure == nil)
  }
}

@MainActor
private final class LocalSettingsSwitchFixture {
  let settings = AppSettings()
  let work = AccountServiceWork()
  let container: ModelContainer
  let context: ModelContext
  let did = "did:plc:offline-settings-switch"
  let suiteName = "blue.catbird.fixture.switch.\(UUID().uuidString)"
  let defaults: UserDefaults
  var failSave = false
  var failFetch = false
  var isActive = true
  var saveCount = 0
  var scheduled: [() -> Void] = []
  var notifications: [String] = []
  private var observer: NSObjectProtocol?
  private let previousHaptics = PlatformHaptics.isEnabled

  init(failInitialFetch: Bool = false) throws {
    defaults = UserDefaults(suiteName: suiteName)!
    container = try ModelContainer(for: AppSettingsModel.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    context = ModelContext(container)
    context.autosaveEnabled = false
    let row = AppSettingsModel(accountDID: did)
    row.theme = "light"
    context.insert(row)
    try context.save()
    failFetch = failInitialFetch
    settings.persistence = .init(
      fetch: { [weak self] context, did in
        guard let self, !self.failFetch else { throw CocoaError(.persistentStoreOperation) }
        let id = AppSettingsModel.settingsId(for: did)
        return try context.fetch(FetchDescriptor<AppSettingsModel>(predicate: #Predicate { $0.id == id })).first
      }, save: { [weak self] context in
        guard let self else { throw CocoaError(.persistentStoreOperation) }
        self.saveCount += 1
        if self.failSave { throw CocoaError(.persistentStoreOperation) }
        try context.save()
      }, isActiveAccount: { [weak self] did, owner in
        guard let self else { return false }
        return self.isActive && self.did == did && self.settings === owner
      }, scheduleSave: { [weak self] in self?.scheduled.append($0); return nil },
      standardDefaults: defaults, sharedDefaults: defaults,
      startEffect: { [weak self] in self?.work.start(operation: $0) != nil }
    )
    observer = NotificationCenter.default.addObserver(forName: NSNotification.Name("AppSettingsChanged"), object: settings, queue: .main) { [weak self] notification in
      let did = notification.userInfo?["accountDID"] as? String
      MainActor.assumeIsolated { if let did { self?.notifications.append(did) } }
    }
    settings.initialize(with: context, accountDID: did)
  }

  func settle() async { for _ in 0..<16 { await Task.yield() } }

  func storedTheme() throws -> String? {
    try ModelContext(container).fetch(FetchDescriptor<AppSettingsModel>()).first?.theme
  }

  func cleanUp() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    defaults.removePersistentDomain(forName: suiteName)
    PlatformHaptics.isEnabled = previousHaptics
  }
}
