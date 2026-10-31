import Foundation
import Petrel
import Testing

@testable import Catbird

// The Moderation screen's builtin content filters: displayed values come from
// the engine's `ModerationPrefs` normalization, and a global choice writes the
// canonical key plus its legacy alias in one update, as `@bsky/sdk` does.

private func global(_ label: String, _ visibility: String) -> ContentLabelPreference {
  ContentLabelPreference(labelerDid: nil, label: label, visibility: visibility)
}

private func prefs(_ stored: [ContentLabelPreference], adult: Bool = true, labelers: [String] = []) -> ModerationPrefs {
  ModerationPrefs(adultContentEnabled: adult, contentLabelPrefs: stored, labelerDIDs: labelers)
}

/// The displayed control for each builtin filter, keyed by identifier.
private func displayed(_ prefs: ModerationPrefs) -> [String: ContentFilterRow.Control] {
  Dictionary(uniqueKeysWithValues: ContentFilterSettings.rows(for: prefs).map { ($0.identifier, $0.control) })
}

@Suite("Content filter settings")
struct ContentFilterSettingsTests {
  // MARK: Rows

  @Test("Rows use Bluesky's keys, order, names and descriptions")
  func rowIdentity() throws {
    let rows = ContentFilterSettings.rows(for: prefs([]))
    #expect(rows.map(\.identifier) == ["porn", "sexual", "graphic-media", "nudity"])
    #expect(rows.map(\.name) == ["Adult Content", "Sexually Suggestive", "Graphic Media", "Non-sexual Nudity"])
    for row in rows {
      let definition = try #require(ModerationLabelDefinition.builtin(forLabelValue: row.identifier))
      #expect(row.description == ModerationPresentation.description(for: definition))
      #expect(row.controlID.rawValue == "moderation.\(row.identifier)")
    }
  }

  @Test("Unset filters show the builtin defaults")
  func defaults() {
    #expect(displayed(prefs([])) == [
      "porn": .selectable(.hide), "sexual": .selectable(.warn),
      "graphic-media": .selectable(.warn), "nudity": .selectable(.ignore),
    ])
  }

  @Test("Stored gore=hide with graphic-media=hide shows Hide, not Warn")
  func beforeScreenshotBug() {
    let shown = displayed(prefs([global("gore", "hide"), global("graphic-media", "hide")]))
    #expect(shown["graphic-media"] == .selectable(.hide))
  }

  @Test("Legacy keys are read as their canonical filters")
  func legacyKeys() {
    let shown = displayed(prefs([global("nsfw", "ignore"), global("suggestive", "hide"), global("gore", "hide")]))
    #expect(shown["porn"] == .selectable(.ignore))
    #expect(shown["sexual"] == .selectable(.hide))
    #expect(shown["graphic-media"] == .selectable(.hide))
  }

  @Test("Conflicting legacy and canonical entries resolve in array order, last wins", arguments: [
    (["porn": "hide"], ["nsfw": "ignore"], "porn", LabelPreference.ignore),
    (["nsfw": "ignore"], ["porn": "hide"], "porn", .hide),
    (["sexual": "ignore"], ["suggestive": "hide"], "sexual", .hide),
    (["suggestive": "hide"], ["sexual": "warn"], "sexual", .warn),
    (["graphic-media": "ignore"], ["gore": "hide"], "graphic-media", .hide),
    (["gore": "hide"], ["graphic-media": "ignore"], "graphic-media", .ignore),
  ])
  func conflictingOrder(first: [String: String], second: [String: String], identifier: String, expected: LabelPreference) {
    let stored = [first, second].flatMap { $0.map { global($0.key, $0.value) } }
    #expect(displayed(prefs(stored))[identifier] == .selectable(expected))
  }

  @Test("A stored show reads as Show", arguments: ["porn", "nsfw", "sexual", "graphic-media", "gore", "nudity"])
  func showIsIgnore(key: String) {
    let identifier = ModerationPrefs.canonicalLabelIdentifier(key)
    #expect(displayed(prefs([global(key, "show")]))[identifier] == .selectable(.ignore))
  }

  @Test("Catbird's former graphic key is only a fallback for Graphic Media")
  func graphicFallback() {
    #expect(displayed(prefs([global("graphic", "hide")]))["graphic-media"] == .selectable(.hide))
    #expect(displayed(prefs([global("graphic", "hide"), global("graphic-media", "ignore")]))["graphic-media"] == .selectable(.ignore))
    #expect(displayed(prefs([global("graphic-media", "ignore"), global("graphic", "hide")]))["graphic-media"] == .selectable(.ignore))
    #expect(displayed(prefs([global("gore", "ignore"), global("graphic", "hide")]))["graphic-media"] == .selectable(.ignore))
  }

  @Test("A service's own preference never changes a global filter")
  func scopedEntriesIgnored() throws {
    let service = "did:plc:settings-service"
    let stored = [ContentLabelPreference(labelerDid: try DID(didString: service), label: "porn", visibility: "ignore")]
    #expect(displayed(prefs(stored, labelers: [service]))["porn"] == .selectable(.hide))
  }

  @Test("The screen shows what the account's moderation policy applies")
  func matchesPolicy() {
    let stored = [global("porn", "hide"), global("nsfw", "warn"), global("graphic", "ignore"), global("nudity", "show")]
    let policy = ModerationPolicy(
      accountDID: "did:plc:settings-viewer", serverAdultContentEnabled: true, contentLabelPrefs: stored,
      labelerDIDs: [], labelerDefinitions: [:], isConfirmed: true)
    #expect(displayed(policy.prefs) == [
      "porn": .selectable(.warn), "sexual": .selectable(.warn),
      "graphic-media": .selectable(.ignore), "nudity": .selectable(.ignore),
    ])
  }

  // MARK: Adult content off

  @Test("Adult-only filters are locked as hidden while adult content is off")
  func adultFiltersLocked() {
    let stored = [global("porn", "ignore"), global("sexual", "ignore"), global("graphic-media", "ignore")]
    let shown = displayed(prefs(stored, adult: false))
    #expect(shown["porn"] == .hiddenWhileAdultContentOff)
    #expect(shown["sexual"] == .hiddenWhileAdultContentOff)
    #expect(shown["graphic-media"] == .hiddenWhileAdultContentOff)
  }

  @Test("Non-sexual nudity stays editable while adult content is off", arguments: [
    ([] as [String], LabelPreference.ignore), (["warn"], .warn), (["hide"], .hide), (["show"], .ignore),
  ])
  func nudityEditable(stored: [String], expected: LabelPreference) {
    let shown = displayed(prefs(stored.map { global("nudity", $0) }, adult: false))
    #expect(shown["nudity"] == .selectable(expected))
  }

  @Test("An unconfirmed policy locks the adult filters")
  func unconfirmedPolicyLocks() {
    let policy = ModerationPolicy(
      accountDID: "did:plc:settings-viewer", serverAdultContentEnabled: true, contentLabelPrefs: [],
      labelerDIDs: [], labelerDefinitions: [:], isConfirmed: false)
    #expect(displayed(policy.prefs)["porn"] == .hiddenWhileAdultContentOff)
    #expect(displayed(policy.prefs)["nudity"] == .selectable(.ignore))
  }

  // MARK: Writes

  @Test("A global choice writes the canonical key and its legacy alias together", arguments: [
    ("porn", ["porn", "nsfw"]), ("sexual", ["sexual", "suggestive"]),
    ("graphic-media", ["graphic-media", "gore"]), ("nudity", ["nudity"]),
  ])
  func doubleWrite(identifier: String, keys: [String]) {
    for preference in LabelPreference.allCases {
      let writes = ContentFilterSettings.globalWrites(identifier: identifier, preference: preference)
      #expect(writes.map(\.label) == keys)
      #expect(writes.allSatisfy { $0.labelerDid == nil && $0.visibility == preference.rawValue })
    }
  }

  @Test("After a saved choice the screen shows that choice, whatever legacy entries were stored", arguments: [
    ([("porn", "hide"), ("nsfw", "ignore")], "porn"),
    ([("suggestive", "hide"), ("sexual", "ignore")], "sexual"),
    ([("gore", "hide"), ("graphic-media", "hide")], "graphic-media"),
    ([("graphic", "hide")], "graphic-media"),
    ([("nudity", "show")], "nudity"),
  ])
  func writeThenRead(stored: [(String, String)], identifier: String) {
    let existing = stored.map { global($0.0, $0.1) }
    for preference in LabelPreference.allCases {
      let writes = ContentFilterSettings.globalWrites(identifier: identifier, preference: preference)
      let merged = Preferences.mergingContentLabelPreferences(writes, into: existing)
      #expect(displayed(prefs(merged))[identifier] == .selectable(preference))
    }
  }

  @Test("A pending choice applies only to its own filter")
  func pendingChoice() {
    let pending = PendingLabelChoice(identifier: "porn", preference: .warn)
    #expect(pending.preference(for: "porn") == .warn)
    #expect(pending.preference(for: "nsfw") == nil)
    #expect(LabelPreference.allCases.map(\.settingsOptionTitle) == ["Show", "Warn", "Hide"])
  }
}
