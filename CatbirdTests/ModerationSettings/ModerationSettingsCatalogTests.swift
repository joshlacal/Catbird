import Foundation
import Testing

@testable import Catbird

// Settings search finds each moderation control under the name and control id
// the Moderation screen shows.

@Suite("Moderation settings catalog")
struct ModerationSettingsCatalogTests {
  private func entry(_ control: String) -> SettingsSearchEntry? {
    SettingsCatalog.entries.first { $0.target == SettingsTarget(screen: .moderation, control: SettingsControlID(rawValue: control)) }
  }

  @Test("Every content filter row has a search entry with its on-screen name and control id")
  func filterEntriesMatchRows() throws {
    let prefs = ModerationPrefs(adultContentEnabled: true, contentLabelPrefs: [], labelerDIDs: [])
    for row in ContentFilterSettings.rows(for: prefs) {
      let match = try #require(entry(row.controlID.rawValue), "missing entry for \(row.identifier)")
      #expect(match.title == row.name)
    }
  }

  @Test("The adult content toggle is indexed under its on-screen name")
  func adultToggle() throws {
    #expect(try #require(entry("moderation.adultContent")).title == "Enable Adult Content")
  }

  @Test("Catbird's former private control ids are gone", arguments: ["moderation.nsfw", "moderation.suggestive", "moderation.graphic"])
  func legacyIDsRemoved(control: String) {
    #expect(entry(control) == nil)
    #expect(SettingsRoute(rawValue: "moderation/\(control)") == nil)
  }

  @Test("Filter control ids resolve as Settings routes", arguments: ContentFilterSettings.builtinIdentifiers)
  func routesResolve(identifier: String) {
    let control = ContentFilterSettings.controlID(for: identifier)
    #expect(SettingsRoute(rawValue: "moderation/\(control.rawValue)")?.target == SettingsTarget(screen: .moderation, control: control))
  }

  @Test("Search finds filters by Bluesky and legacy terms", arguments: [
    ("gore", "Graphic Media"), ("violence", "Graphic Media"), ("suggestive", "Sexually Suggestive"),
    ("NSFW", "Adult Content"), ("nudity", "Non-sexual Nudity"),
  ])
  func search(query: String, title: String) {
    #expect(SettingsCatalog.search(query).contains { $0.title == title && $0.target.screen == .moderation })
  }
}
