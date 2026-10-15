import Foundation
import Petrel
import SwiftData
import Testing
@testable import Catbird

@Suite("Settings runtime propagation", .serialized)
@MainActor
struct AppStateAccentChangeTests {
  /// Settings reach the theme and fonts only through the active account's state: the
  /// `AppSettingsChanged` observer ignores any other, so an outgoing account cannot restyle the app.
  /// Each case makes its state the active one, as the app does, and restores the previous lifecycle.
  private func activate(_ state: AppState) -> () -> Void {
    let previous = AppStateManager.shared.lifecycle
    AppStateManager.shared.setLifecycleForTesting(.authenticated(state))
    return { AppStateManager.shared.setLifecycleForTesting(previous) }
  }

  @Test("Consecutive accent-only changes reach the active theme")
  func consecutiveAccentChangesApply() async throws {
    let accountDID = "did:plc:accentsettingstest"
    let container = try ModelContainer(
      for: AppSettingsModel.self, Preferences.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    )
    let model = AppSettingsModel(accountDID: accountDID)
    container.mainContext.insert(model)
    try container.mainContext.save()
    let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:1")!)
    let state = AppState(userDID: accountDID, client: client)
    let restoreLifecycle = activate(state)
    defer { restoreLifecycle() }
    defer { state.cleanup() }
    state.initializePreferencesManager(with: container.mainContext)
    let originalTheme = state.appSettings.theme
    let originalFont = state.appSettings.fontStyle

    // The first change establishes the hash; a second accent-only edit must not be dropped.
    for accent in [AccentColorOption.twilight, .lavender] {
      state.appSettings.accentColor = accent.rawValue
      for _ in 0..<150 {
        if state.themeManager.currentAccentColor == accent { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      #expect(state.themeManager.currentAccentColor == accent)
      let persisted = try ModelContext(container).fetch(FetchDescriptor<AppSettingsModel>())
      #expect(persisted.first(where: { $0.id == model.id })?.accentColor == accent.rawValue)
    }
    #expect(state.appSettings.theme == originalTheme)
    #expect(state.appSettings.fontStyle == originalFont)
  }

  @Test("Retrying a failed settings load updates the active font manager")
  func retryLoadAppliesRecoveredTypography() async throws {
    let accountDID = "did:plc:settingsfontrecovery"
    let container = try ModelContainer(
      for: AppSettingsModel.self, Preferences.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    )
    let model = AppSettingsModel(accountDID: accountDID)
    container.mainContext.insert(model)
    try container.mainContext.save()
    let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:1")!)
    let state = AppState(userDID: accountDID, client: client)
    let restoreLifecycle = activate(state)
    defer { restoreLifecycle() }
    defer { state.cleanup() }
    let live = AppSettings.Persistence.live
    var failFetch = true
    state.appSettings.persistence = .init(
      fetch: { context, did in
        if failFetch {
          failFetch = false
          throw CocoaError(.persistentStoreOperation)
        }
        return try live.fetch(context, did)
      },
      save: live.save
    )
    state.initializePreferencesManager(with: container.mainContext)
    #expect(state.appSettings.persistenceState == .unavailable)
    // Choose a saved value different from the fallback that is actually active.
    let recoveredStyle = state.fontManager.fontStyle == "serif" ? "monospaced" : "serif"
    model.fontStyle = recoveredStyle
    try container.mainContext.save()

    state.appSettings.retryPersistence()
    #expect(state.appSettings.persistenceState == .ready)
    for _ in 0..<150 {
      if state.fontManager.fontStyle == recoveredStyle { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(state.fontManager.fontStyle == recoveredStyle)
  }

  @Test("A saved accent change on an account that is not the active one leaves the theme alone")
  func inactiveAccountChangeLeavesTheme() async throws {
    let accountDID = "did:plc:inactiveaccentsettings"
    let container = try ModelContainer(
      for: AppSettingsModel.self, Preferences.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    )
    let model = AppSettingsModel(accountDID: accountDID)
    container.mainContext.insert(model)
    try container.mainContext.save()
    let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:1")!)
    let state = AppState(userDID: accountDID, client: client)
    defer { state.cleanup() }
    state.initializePreferencesManager(with: container.mainContext)
    let before = state.themeManager.currentAccentColor
    let accent: AccentColorOption = before == .twilight ? .lavender : .twilight

    state.appSettings.accentColor = accent.rawValue
    var saved = false
    for _ in 0..<150 where !saved {
      try await Task.sleep(for: .milliseconds(20))
      saved = try ModelContext(container).fetch(FetchDescriptor<AppSettingsModel>())
        .first(where: { $0.id == model.id })?.accentColor == accent.rawValue
    }
    #expect(saved, "The change must be saved, so only the theme hand-off is under test")
    // Longer than the settings observer's debounce.
    try await Task.sleep(for: .milliseconds(500))
    #expect(state.themeManager.currentAccentColor == before)
  }
}
