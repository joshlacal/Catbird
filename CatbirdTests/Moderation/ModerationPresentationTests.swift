import Foundation
import Petrel
import Testing

@testable import Catbird

// Display strings and cause titles.

private func custom(
  _ identifier: String = "spoiler",
  locales: [(String, String, String)] = [],
  blurs: String = "content",
  severity: String = "alert"
) throws -> ModerationLabelDefinition {
  let strings = locales.map {
    ComAtprotoLabelDefs.LabelValueDefinitionStrings(lang: LanguageCodeContainer(languageCode: $0.0), name: $0.1, description: $0.2)
  }
  return try #require(
    ModerationLabelDefinition.interpret(
      .init(identifier: identifier, severity: severity, blurs: blurs, defaultSetting: "warn", locales: strings),
      definedBy: ModerationFixtures.customLabelerDID))
}

@Suite("Moderation: presentation")
struct ModerationPresentationTests {
  // MARK: Builtin strings

  @Test("Builtin names and descriptions match social-app's global label strings", arguments: [
    ("porn", "Adult Content", "Explicit sexual images."),
    ("sexual", "Sexually Suggestive", "Does not include nudity."),
    ("nudity", "Non-sexual Nudity", "E.g. artistic nudes."),
    ("graphic-media", "Graphic Media", "Explicit or potentially disturbing media."),
    ("!hide", "Content Blocked", "This content has been hidden by the moderators."),
    ("!warn", "Content Warning", "This content has received a general warning from moderators."),
    ("!no-unauthenticated", "Sign-in Required", "This user has requested that their content only be shown to signed-in users."),
  ])
  func builtinStrings(identifier: String, name: String, description: String) throws {
    let definition = try #require(ModerationLabelDefinition.builtins[identifier])
    let strings = ModerationPresentation.strings(for: definition, preferredLanguages: ["fr-FR"])
    #expect(strings.name == name)
    #expect(strings.description == description)
    #expect(ModerationPresentation.name(for: definition) == name)
    #expect(ModerationPresentation.description(for: definition) == description)
  }

  @Test("Every builtin has display strings")
  func allBuiltinsCovered() {
    for definition in ModerationLabelDefinition.builtins.values {
      let strings = ModerationPresentation.strings(for: definition, preferredLanguages: ["en"])
      #expect(strings.name != definition.identifier, "\(definition.identifier) fell back to its identifier")
    }
  }

  // MARK: Custom strings

  @Test("Custom definitions use the first device language that matches a published locale")
  func localeMatching() throws {
    let definition = try custom(locales: [("en", "Spoiler", "Plot details."), ("fr", "Divulgâcheur", "Détails de l'intrigue."), ("pt-BR", "Spoiler BR", "Detalhes.")])
    #expect(ModerationPresentation.name(for: definition, preferredLanguages: ["fr-CA", "en-US"]) == "Divulgâcheur")
    #expect(ModerationPresentation.name(for: definition, preferredLanguages: ["pt-BR"]) == "Spoiler BR")
    #expect(ModerationPresentation.name(for: definition, preferredLanguages: ["en-GB"]) == "Spoiler")
    #expect(ModerationPresentation.description(for: definition, preferredLanguages: ["FR"]) == "Détails de l'intrigue.")
    // A regional locale only matches that region, not other regions or the bare language.
    #expect(ModerationPresentation.name(for: definition, preferredLanguages: ["pt-PT"]) == "Spoiler", "no match falls back to the first locale")
  }

  @Test("Underscore tags match, device order decides first, and published order breaks ties within a language")
  func localeMatchingOrder() throws {
    let definition = try custom(locales: [("pt-BR", "Spoiler BR", "Detalhes."), ("en", "Spoiler", "Plot details.")])
    #expect(ModerationPresentation.name(for: definition, preferredLanguages: ["pt_BR"]) == "Spoiler BR")
    #expect(ModerationPresentation.name(for: definition, preferredLanguages: ["ja", "en_US", "pt-BR"]) == "Spoiler", "en-US precedes pt-BR on the device")
    #expect(ModerationPresentation.name(for: definition, preferredLanguages: []) == "Spoiler BR", "no device language falls back to the first locale")

    let overlapping = try custom(locales: [("en", "First", "One."), ("en-US", "Second", "Two.")])
    #expect(ModerationPresentation.name(for: overlapping, preferredLanguages: ["en-US"]) == "First")
    #expect(ModerationPresentation.name(for: overlapping, preferredLanguages: ["en-GB"]) == "First")

    let wildcard = try custom(locales: [("de", "Spoiler DE", "Handlung."), ("*", "Spoiler any", "Any.")])
    #expect(ModerationPresentation.name(for: wildcard, preferredLanguages: ["ja"]) == "Spoiler any")
  }

  @Test("Custom definitions fall back to the first locale, then to the identifier")
  func customFallbacks() throws {
    let withLocales = try custom(locales: [("de", "Spoiler DE", "Handlung.")])
    #expect(ModerationPresentation.name(for: withLocales, preferredLanguages: ["ja"]) == "Spoiler DE")

    let bare = try custom("no-strings")
    let strings = ModerationPresentation.strings(for: bare, preferredLanguages: ["en-US"])
    #expect(strings.name == "no-strings")
    #expect(strings.description == "Labeled \"no-strings\"")
    #expect(strings.lang == "en-US")
  }

  // MARK: Titles

  private func decision(_ labels: [(String, String)], adult: Bool = true, settings: [String: LabelPreference] = [:]) throws -> ModerationDecision {
    let src = ModerationFixtures.customLabelerDID
    let spoiler = try custom(locales: [("en", "Spoiler", "Plot details.")])
    let options = ModerationFixtures.options(
      adult: adult, settings: settings,
      labelers: [LabelerModerationPrefs(did: ModerationFixtures.labelerDID), LabelerModerationPrefs(did: src, labels: ["spoiler": .warn])],
      definitions: [src: [spoiler]])
    let list = try labels.map { try ModerationFixtures.postLabel($0.0, name: "alice", src: $0.1) }
    return ModerationSubjects.decidePost(try ModerationFixtures.post(author: try ModerationFixtures.profile("alice"), labels: list), options: options)
  }

  @Test("The title names the highest-priority blur cause")
  func titleFromBlur() throws {
    let labeler = ModerationFixtures.labelerDID
    // !hide (priority 1) beats a spoiler warning (priority 7) in the list context.
    let mixed = try decision([("spoiler", ModerationFixtures.customLabelerDID), ("!hide", labeler)])
    #expect(ModerationPresentation.title(for: mixed.ui(.contentList)) == "Content Blocked")

    let spoilerOnly = try decision([("spoiler", ModerationFixtures.customLabelerDID)])
    #expect(ModerationPresentation.title(for: spoilerOnly.ui(.contentList), preferredLanguages: ["en"]) == "Spoiler")
  }

  @Test("Media blurs title the cause; sexual is presented as Adult Content, as in social-app")
  func mediaTitles() throws {
    let labeler = ModerationFixtures.labelerDID
    #expect(ModerationPresentation.title(for: try decision([("porn", labeler)]).ui(.contentMedia)) == "Adult Content")
    #expect(ModerationPresentation.title(for: try decision([("sexual", labeler)]).ui(.contentMedia)) == "Adult Content")
    #expect(ModerationPresentation.title(for: try decision([("graphic-media", labeler)]).ui(.contentMedia)) == "Graphic Media")
    #expect(ModerationPresentation.title(for: try decision([("nudity", labeler)], settings: ["nudity": .warn]).ui(.contentMedia)) == "Non-sexual Nudity")
  }

  @Test("With no blur the title uses the highest-priority alert")
  func titleFromAlert() throws {
    let src = ModerationFixtures.customLabelerDID
    let alertOnly = try custom("heads-up", blurs: "none", severity: "alert")
    let options = ModerationFixtures.options(
      labelers: [LabelerModerationPrefs(did: src, labels: ["heads-up": .warn])], definitions: [src: [alertOnly]])
    let label = try ModerationFixtures.postLabel("heads-up", name: "alice", src: src)
    let post = try ModerationFixtures.post(author: try ModerationFixtures.profile("alice"), labels: [label])
    let ui = ModerationSubjects.decidePost(post, options: options).ui(.contentView)
    #expect(ui.alert && !ui.blur)
    #expect(ModerationPresentation.title(for: ui) == "heads-up")
  }

  @Test("With nothing to name, the title is a generic content warning")
  func genericFallback() {
    #expect(ModerationPresentation.title(for: .empty) == "Content Warning")
    #expect(ModerationPresentation.fallbackTitle == "Content Warning")
  }
}
