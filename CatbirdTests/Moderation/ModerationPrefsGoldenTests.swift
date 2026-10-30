import Foundation
import Petrel
import Testing

@testable import Catbird

// Cross-checks preference normalization against what the real `@bsky/sdk`
// `getPreferences` produced for the same stored preferences
// (`tools/moderation-reference/golden.json`, embedded as `ModerationReferenceGolden`).
//
// Every preference case is compared. The SDK keeps a stored visibility as a
// string, and `decision.ts` reads it by truthiness, so the comparison reads the
// golden strings the way the engine acts on them (`GoldenVisibility.effective`):
//
// - `ignore`, `warn`, `hide` and `show` (as `ignore`) are themselves.
// - Any other non-empty string, `block` and `HIDE` included, is an explicit
//   preference that behaves like `warn`.
// - The empty string is no preference. In the global map the SDK falls back to
//   the label definition's default, which for a seeded builtin is the seeded value
//   and for any other key is "absent"; in a labeler's map it falls through to the
//   global value, so the key is absent.
//
// The one intentional deviation is Catbird's former private `graphic` key, held
// to the case's `catbird.expected` (the real SDK on the stored preferences with
// `graphic` read as `graphic-media`).

private func expectedGlobal(_ stored: [String: String]) -> [String: LabelPreference] {
  var result: [String: LabelPreference] = [:]
  for (key, value) in stored {
    if let effective = GoldenVisibility.effective(value) {
      result[key] = LabelPreference(rawValue: effective)
    } else if let seeded = ModerationPrefs.builtinDefaultLabels[key] {
      result[key] = seeded
    }
  }
  return result
}

private func expectedScoped(_ stored: [String: String]) -> [String: LabelPreference] {
  stored.compactMapValues { GoldenVisibility.effective($0).flatMap { LabelPreference(rawValue: $0) } }
}

@Suite("Moderation: preferences against the SDK golden")
struct ModerationPrefsGoldenTests {
  @Test("The golden preference cases are loaded and cover every family")
  func goldenIsLoaded() throws {
    let golden = try ModerationGolden.shared()
    #expect(golden.prefCases.count >= 60)
    let families = Set(golden.prefCases.map { String($0.id.split(separator: "/").first ?? "") })
    for family in ["empty", "adult", "legacy-alone", "canonical-alone", "legacy+canonical", "canonical+legacy", "duplicates",
      "all-legacy-and-canonical", "unknown-visibility", "custom-label", "private-key", "labelers"]
    {
      #expect(families.contains(family), "family \(family)")
    }
    #expect(golden.prefCases.contains { $0.id.hasPrefix("labelers/scoped-legacy-nsfw-not-remapped") })
    #expect(golden.prefCases.filter { $0.catbird != nil }.allSatisfy { $0.id.hasPrefix("private-key/") })
    #expect(golden.prefCases.contains { $0.catbird != nil }, "the private-key deviation is exercised")
  }

  @Test("Normalized preferences equal the SDK's getPreferences output, or the private-key deviation", arguments: ModerationGolden.prefCaseIDs)
  func matchesSDK(id: String) throws {
    let golden = try #require(try ModerationGolden.shared().prefCaseByID[id])
    let expected = golden.effectiveExpected

    let stored = try golden.raw.map {
      ContentLabelPreference(
        labelerDid: try $0.labelerDid.map { try DID(didString: $0) }, label: $0.label, visibility: $0.visibility)
    }
    let prefs = ModerationPrefs(
      adultContentEnabled: golden.adultContentEnabled ?? false, contentLabelPrefs: stored, labelerDIDs: golden.labelers)

    #expect(prefs.adultContentEnabled == expected.adultContentEnabled, "\(id): adultContentEnabled")
    #expect(prefs.labels == expectedGlobal(expected.labels), "\(id): global labels")
    #expect(
      prefs.labelers == expected.labelers.map { LabelerModerationPrefs(did: $0.did, labels: expectedScoped($0.labels)) },
      "\(id): labelers")
  }

  @Test("Only the private-key family differs from the SDK, and only where the fallback applies")
  func deviationIsConfinedToPrivateKeyFallback() throws {
    for golden in try ModerationGolden.shared().prefCases {
      guard let deviation = golden.catbird else { continue }
      let hasGlobalGraphicMedia = golden.raw.contains {
        $0.labelerDid == nil && ($0.label == "graphic-media" || $0.label == "gore")
      }
      #expect(!hasGlobalGraphicMedia, "\(golden.id): the fallback never applies next to a graphic-media or gore entry")
      #expect(golden.raw.contains { $0.labelerDid == nil && $0.label == "graphic" }, "\(golden.id): a global graphic entry")
      // The deviation changes graphic-media and nothing else but the inert key.
      var sdkLabels = golden.normalized.labels
      sdkLabels["graphic"] = nil
      var catbirdLabels = deviation.expected.labels
      catbirdLabels["graphic-media"] = nil
      sdkLabels["graphic-media"] = nil
      #expect(sdkLabels == catbirdLabels, "\(golden.id): only graphic-media differs")
      #expect(deviation.expected.labelers.map(\.did) == golden.normalized.labelers.map(\.did))
    }
  }
}
