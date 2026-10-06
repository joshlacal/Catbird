import Foundation
import SwiftData
import Testing
@testable import Catbird

@Suite("Settings language scope", .serialized)
@MainActor
struct SettingsLanguageScopeTests {
  @Test("An unsupported interface selection remains intact until an explicit device choice")
  func interfaceSelectionIsDeviceScoped() {
    let suiteName = "blue.catbird.fixture.language.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("future-locale", forKey: "appLanguage")
    var applications: [String] = []
    let preferences = InterfaceLanguagePreferences(defaults: defaults, apply: { applications.append($0) })
    let oldAccount = AppSettingsModel(accountDID: "did:plc:fixture-language-a")
    oldAccount.appLanguage = "legacy-account-locale"
    oldAccount.primaryLanguage = "es"
    oldAccount.contentLanguages = ["es", "pt-BR"]
    #expect(preferences.selectedLanguage == "future-locale")
    #expect(applications.isEmpty)
    #expect(oldAccount.appLanguage == "legacy-account-locale")
    preferences.select("system")
    #expect(preferences.selectedLanguage == "system")
    #expect(applications == ["system"])
    #expect(oldAccount.appLanguage == "legacy-account-locale")
    #expect(oldAccount.primaryLanguage == "es")
    #expect(oldAccount.contentLanguages == ["es", "pt-BR"])
  }

  @Test("Failed local reading publication preserves other fields, backups and device language")
  func failedReadingPublicationPreservesState() async throws {
    let suiteName = "blue.catbird.fixture.reading.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let did = "did:plc:fixture-reading-a"
    defaults.set("future-locale", forKey: "appLanguage")
    let contentKey = AppSettingsModel.scopedKey("contentLanguages", accountDID: did)
    defaults.set(["en"], forKey: contentKey)
    let container = try ModelContainer(for: Preferences.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    let row = Preferences(accountDID: did)
    row.interests = ["art"]
    container.mainContext.insert(row)
    try container.mainContext.save()
    let manager = PreferencesManager(modelContext: container.mainContext)
    manager.configure(accountDID: did)
    manager.readingLanguageDefaults = defaults
    manager.readingLanguagePersistence.save = { _ in throw CocoaError(.persistentStoreOperation) }
    await #expect(throws: CocoaError.self) {
      try await manager.updateReadingLanguagePreferences(primaryLanguage: "es", contentLanguages: ["es"], expectedAccountDID: did)
    }
    let failed = try ModelContext(container).fetch(FetchDescriptor<Preferences>()).first!
    #expect(failed.primaryLanguage == "en")
    #expect(failed.interests == ["art"])
    #expect(defaults.stringArray(forKey: contentKey) == ["en"])
    #expect(defaults.string(forKey: "appLanguage") == "future-locale")
    manager.readingLanguagePersistence = .live
    try await manager.updateReadingLanguagePreferences(primaryLanguage: "es", contentLanguages: ["es", "pt-BR"], expectedAccountDID: did)
    let confirmed = try ModelContext(container).fetch(FetchDescriptor<Preferences>()).first!
    #expect(confirmed.primaryLanguage == "es")
    #expect(confirmed.contentLanguages == ["es", "pt-BR"])
    #expect(confirmed.interests == ["art"])
    #expect(defaults.stringArray(forKey: contentKey) == ["es", "pt-BR"])
    #expect(defaults.string(forKey: "appLanguage") == "future-locale")
    manager.configure(accountDID: "did:plc:fixture-reading-b")
    await #expect(throws: PreferencesManagerError.self) {
      try await manager.updateReadingLanguagePreferences(primaryLanguage: "fr", contentLanguages: ["fr"], expectedAccountDID: did)
    }
    #expect(defaults.stringArray(forKey: contentKey) == ["es", "pt-BR"])
  }

  @Test("Interface choices come from shipped localizations rather than reading-language options")
  func interfaceTranslationCoverage() {
    let offered = InterfaceLanguagePreferences.availableLanguages()
    let declared = Set(Bundle.main.localizations + [Bundle.main.developmentLocalization].compactMap { $0 })
    #expect(offered.allSatisfy { declared.contains($0) && $0 != "Base" })
    #expect(offered.count == Set(offered).count)
  }
}
