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
}
