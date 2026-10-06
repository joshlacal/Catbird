import Foundation
import Testing
import Petrel
@testable import Catbird

@Suite("ProfileLabelPreferenceAdapterTests")
struct ProfileLabelPreferenceAdapterTests {
  @Test("Aliases match the installed runtime and unknown keys preserve spelling")
  func consumedKeyFixtures() {
    let expected = ["porn": "nsfw", "sexual": "nsfw", "NSFW": "nsfw",
      "gore": "graphic", "violence": "graphic", "graphic-media": "graphic",
      "NUDITY": "nudity", "suggestive": "suggestive", "self-harm": "self-harm",
      "Custom-Key": "Custom-Key", "!warn": "!warn"]
    for (raw, consumed) in expected {
      #expect(ProfileLabelPreferenceAdapter.consumedKey(for: raw) == consumed)
    }
  }

  @Test("Raw fallback is displayed truthfully and canonical choices take precedence")
  func selectionFixtures() throws {
    let service = try DID(didString: "did:plc:profile-service")
    let other = try DID(didString: "did:plc:other-service")
    var records: [ContentLabelPreference] = [
      .init(labelerDid: service, label: "porn", visibility: "ignore"),
      .init(labelerDid: other, label: "nsfw", visibility: "hide")]
    let raw = ProfileLabelPreferenceAdapter.selection(raw: "porn", labelerDID: service, preferences: records)
    #expect(raw.visibility == .show)
    #expect(raw.usesLegacyRawKey)
    records.append(.init(labelerDid: service, label: "nsfw", visibility: "warn"))
    let canonical = ProfileLabelPreferenceAdapter.selection(raw: "porn", labelerDID: service, preferences: records)
    let sibling = ProfileLabelPreferenceAdapter.selection(raw: "sexual", labelerDID: service, preferences: records)
    #expect(canonical.visibility == .warn && !canonical.usesLegacyRawKey)
    #expect(sibling.visibility == .warn)
    #expect(records.first?.label == "porn" && records.first?.visibility == "ignore")
  }

  @Test("Absent custom policy uses only the supplied confirmed definition default")
  func inheritedCustomChoice() throws {
    let service = try DID(didString: "did:plc:profile-service")
    let choice = ProfileLabelPreferenceAdapter.selection(raw: "Custom-Key", labelerDID: service,
                                                         preferences: [], inheritedDefault: .show)
    #expect(choice.visibility == .show)
    #expect(!choice.hasExplicitPreference)
  }
}
