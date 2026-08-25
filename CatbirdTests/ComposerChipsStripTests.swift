import Foundation
import Petrel
import PetrelCatbird
import Testing
@testable import Catbird
@Suite("Composer chips strip visibility")
struct ComposerChipsStripTests {
  @Test func hiddenWhenNothingIsSet() {
    #expect(!ComposerChipsStrip.isVisible(
      tagCount: 0, explicitLanguageCount: 0, labelCount: 0,
      threadgateIsCustom: false, hasLanguageSuggestion: false))
  }

  @Test func visibleWhenAnyValueIsSet() {
    #expect(ComposerChipsStrip.isVisible(
      tagCount: 1, explicitLanguageCount: 0, labelCount: 0,
      threadgateIsCustom: false, hasLanguageSuggestion: false))
    #expect(ComposerChipsStrip.isVisible(
      tagCount: 0, explicitLanguageCount: 1, labelCount: 0,
      threadgateIsCustom: false, hasLanguageSuggestion: false))
    #expect(ComposerChipsStrip.isVisible(
      tagCount: 0, explicitLanguageCount: 0, labelCount: 2,
      threadgateIsCustom: false, hasLanguageSuggestion: false))
    #expect(ComposerChipsStrip.isVisible(
      tagCount: 0, explicitLanguageCount: 0, labelCount: 0,
      threadgateIsCustom: true, hasLanguageSuggestion: false))
    #expect(ComposerChipsStrip.isVisible(
      tagCount: 0, explicitLanguageCount: 0, labelCount: 0,
      threadgateIsCustom: false, hasLanguageSuggestion: true))
  }

  @Test func threadgateSummaryText() {
    var settings = ThreadgateSettings()
    #expect(ComposerChipsStrip.threadgateSummary(settings) == "Anyone")

    settings.allowEverybody = false
    settings.allowNobody = true
    #expect(ComposerChipsStrip.threadgateSummary(settings) == "Nobody")

    settings.allowNobody = false
    settings.allowFollowing = true
    settings.allowFollowers = true
    #expect(ComposerChipsStrip.threadgateSummary(settings) == "Following, Followers")

    settings.allowFollowing = false
    settings.allowFollowers = false
    #expect(ComposerChipsStrip.threadgateSummary(settings) == "Custom")
  }

  @Test func circleAudiencePickerExcludesNonActiveCircles() {
    let active = CircleTestFixtures.family
    let expired = BlueCatbirdCircleDefs.CircleSummary(
      uri: try! SpaceRef(uriString: "at://did:plc:alice/space/blue.catbird.circle/expired"),
      name: "Expired Circle",
      owner: CircleTestFixtures.alice,
      accessState: .value_expired,
      muted: nil
    )
    let removed = BlueCatbirdCircleDefs.CircleSummary(
      uri: try! SpaceRef(uriString: "at://did:plc:alice/space/blue.catbird.circle/removed"),
      name: "Removed Circle",
      owner: CircleTestFixtures.alice,
      accessState: .value_removed,
      muted: nil
    )
    let all = [active, expired, removed]
    let filtered = all.filter { $0.accessState == .value_active }
    #expect(filtered.count == 1)
    #expect(filtered.first?.name == "Family")
  }
}
