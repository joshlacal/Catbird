import Foundation
import Petrel
import Testing

@testable import Catbird

// A moderation service's label settings: its own labels use its definitions and
// are saved under their exact identifiers for that service; Bluesky labels it
// lists are the global, canonical filters.

private let service = "did:plc:settings-labeler"

private func definition(
  _ identifier: String, blurs: String = "content", severity: String = "alert",
  defaultSetting: String? = nil, adultOnly: Bool? = nil,
  locales: [(String, String, String)] = []
) -> ComAtprotoLabelDefs.LabelValueDefinition {
  ComAtprotoLabelDefs.LabelValueDefinition(
    identifier: identifier, severity: severity, blurs: blurs, defaultSetting: defaultSetting, adultOnly: adultOnly,
    locales: locales.map {
      ComAtprotoLabelDefs.LabelValueDefinitionStrings(
        lang: LanguageCodeContainer(languageCode: $0.0), name: $0.1, description: $0.2)
    })
}

private func pref(_ label: String, _ visibility: String, scoped: Bool = false) throws -> ContentLabelPreference {
  ContentLabelPreference(labelerDid: scoped ? try DID(didString: service) : nil, label: label, visibility: visibility)
}

private func prefs(_ stored: [ContentLabelPreference] = [], adult: Bool = true, subscribed: Bool = true) -> ModerationPrefs {
  ModerationPrefs(adultContentEnabled: adult, contentLabelPrefs: stored, labelerDIDs: subscribed ? [service] : [])
}

private func rows(
  _ values: [String], _ definitions: [ComAtprotoLabelDefs.LabelValueDefinition], _ prefs: ModerationPrefs,
  labeler: String = service
) -> [LabelerLabelRow] {
  LabelerLabelSettings.rows(labelValues: values, definitions: definitions, labelerDID: labeler, prefs: prefs, preferredLanguages: ["en"])
}

@Suite("Labeler label settings")
struct LabelerLabelSettingsTests {
  // MARK: Service labels

  @Test("Service labels are saved verbatim for that service, without legacy aliases", arguments: [
    "nsfw", "suggestive", "spam", "x-custom",
  ])
  func scopedKeysVerbatim(identifier: String) throws {
    let row = try #require(rows([identifier], [definition(identifier)], prefs()).first)
    #expect(row.identifier == identifier)
    #expect(!row.isBuiltin)
    let did = try DID(didString: service)
    let write = LabelerLabelSettings.serviceWrite(identifier: row.identifier, preference: .hide, labelerDID: did)
    #expect(write.label == identifier)
    #expect(write.labelerDid?.didString() == service)
    #expect(write.visibility == "hide")
  }

  @Test("A saved service choice reads back verbatim and the engine applies it")
  func scopedReadBack() throws {
    let stored = [try pref("nsfw", "hide", scoped: true), try pref("porn", "ignore", scoped: true)]
    let prefs = prefs(stored)
    let row = try #require(rows(["nsfw"], [definition("nsfw", blurs: "none", severity: "alert")], prefs).first)
    #expect(row.control == .selectable(.hide, canWarn: true, source: .service))

    let interpreted = ModerationLabelDefinition.interpretAll([definition("nsfw", blurs: "none", severity: "alert")], definedBy: service)
    let label = ComAtprotoLabelDefs.Label(
      src: try DID(didString: service), uri: URI(uriString: "at://did:plc:author/app.bsky.feed.post/1"),
      val: "nsfw", cts: ATProtocolDate(date: Date()))
    var decision = ModerationDecision(did: "did:plc:author")
    decision.addLabel(label, target: .content, options: ModerationOptions(
      userDID: "did:plc:viewer", prefs: prefs, labelDefinitions: [service: interpreted]))
    #expect(decision.ui(.contentList).filter)
  }

  @Test("Service labels resolve service choice, then global choice, then the service default")
  func precedence() throws {
    let definitions = [definition("custom", defaultSetting: "hide")]
    #expect(rows(["custom"], definitions, prefs()).first?.control == .selectable(.hide, canWarn: true, source: .serviceDefault))
    let global = prefs([try pref("custom", "ignore")])
    #expect(rows(["custom"], definitions, global).first?.control == .selectable(.ignore, canWarn: true, source: .global))
    let scoped = prefs([try pref("custom", "ignore"), try pref("custom", "warn", scoped: true)])
    #expect(rows(["custom"], definitions, scoped).first?.control == .selectable(.warn, canWarn: true, source: .service))
  }

  @Test("A label with nothing to warn with offers only Show and Hide")
  func cannotWarn() throws {
    let definitions = [definition("quiet", blurs: "none", severity: "none")]
    let row = try #require(rows(["quiet"], definitions, prefs([try pref("quiet", "warn", scoped: true)])).first)
    #expect(row.control == .selectable(.ignore, canWarn: false, source: .service))
  }

  @Test("Adult-only service labels are locked as hidden while adult content is off")
  func adultOnlyLocked() throws {
    let definitions = [definition("spicy", blurs: "media", adultOnly: true), definition("plain")]
    let stored = [try pref("spicy", "ignore", scoped: true)]
    let off = rows(["spicy", "plain"], definitions, prefs(stored, adult: false))
    #expect(off.map(\.control) == [.hiddenWhileAdultContentOff, .selectable(.warn, canWarn: true, source: .serviceDefault)])
    let on = rows(["spicy"], definitions, prefs(stored, adult: true))
    #expect(on.first?.control == .selectable(.ignore, canWarn: true, source: .service))
  }

  @Test("An unsubscribed service's labels can't be configured; Bluesky moderation is always subscribed")
  func subscription() throws {
    let definitions = [definition("custom")]
    #expect(rows(["custom"], definitions, prefs(subscribed: false)).first?.control == .requiresSubscription)
    #expect(!LabelerLabelSettings.isSubscribed(service, prefs: prefs(subscribed: false)))
    #expect(LabelerLabelSettings.isSubscribed(service, prefs: prefs()))
    let bluesky = ModerationPrefs.blueskyModerationDID
    #expect(LabelerLabelSettings.isSubscribed(bluesky, prefs: prefs(subscribed: false)))
    let blueskyDefinitions = [definition("rude", blurs: "content", severity: "alert")]
    #expect(rows(["rude"], blueskyDefinitions, prefs(subscribed: false), labeler: bluesky).first?.control
      == .selectable(.warn, canWarn: true, source: .serviceDefault))
  }

  @Test("Names and descriptions come from the service's definition")
  func serviceStrings() throws {
    let definitions = [definition("custom", locales: [("fr", "Personnalisé", "Décrit"), ("en", "Custom Name", "Custom description")])]
    let row = try #require(rows(["custom"], definitions, prefs()).first)
    #expect(row.name == "Custom Name")
    #expect(row.description == "Custom description")
  }

  // MARK: Builtin labels

  @Test("Bluesky labels a service lists map to the canonical global filters")
  func builtinsMapToCanonical() throws {
    let stored = [try pref("nsfw", "warn"), try pref("gore", "ignore"), try pref("nsfw", "ignore", scoped: true)]
    let listed = rows(["porn", "gore", "graphic-media", "sexual", "nudity", "!hide", "!warn"], [], prefs(stored))
    #expect(listed.map(\.identifier) == ["porn", "graphic-media", "sexual", "nudity"])
    #expect(listed.allSatisfy { $0.isBuiltin })
    #expect(listed.map(\.control) == [
      .configuredGlobally(.warn, hasServiceOverride: false), .configuredGlobally(.ignore, hasServiceOverride: false),
      .configuredGlobally(.warn, hasServiceOverride: false), .configuredGlobally(.ignore, hasServiceOverride: false),
    ])
    #expect(listed.map(\.name) == ["Adult Content", "Graphic Media", "Sexually Suggestive", "Non-sexual Nudity"])
  }

  @Test("A service's own choice for a Bluesky label is shown, as the engine applies it")
  func builtinServiceOverride() throws {
    let stored = [try pref("nudity", "warn"), try pref("nudity", "hide", scoped: true)]
    let row = try #require(rows(["nudity"], [], prefs(stored)).first)
    #expect(row.control == .configuredGlobally(.hide, hasServiceOverride: true))

    let label = ComAtprotoLabelDefs.Label(
      src: try DID(didString: service), uri: URI(uriString: "at://did:plc:author/app.bsky.feed.post/1"),
      val: "nudity", cts: ATProtocolDate(date: Date()))
    var decision = ModerationDecision(did: "did:plc:author")
    decision.addLabel(label, target: .content, options: ModerationOptions(userDID: "did:plc:viewer", prefs: prefs(stored)))
    #expect(decision.ui(.contentList).filter)
  }

  @Test("A service can't redefine a Bluesky label")
  func builtinRedefinitionIgnored() {
    let listed = rows(["porn"], [definition("porn", blurs: "none", severity: "none", defaultSetting: "ignore")], prefs())
    #expect(listed.first?.isBuiltin == true)
    #expect(listed.first?.control == .configuredGlobally(.hide, hasServiceOverride: false))
  }

  @Test("Adult-flagged Bluesky labels are locked while adult content is off; nudity is not")
  func builtinAdultLocked() {
    let listed = rows(["porn", "sexual", "graphic-media", "nudity"], [], prefs(adult: false))
    #expect(listed.map(\.control) == [
      .hiddenWhileAdultContentOff, .hiddenWhileAdultContentOff, .hiddenWhileAdultContentOff,
      .configuredGlobally(.ignore, hasServiceOverride: false),
    ])
  }

  @Test("Unknown, invalid and duplicate values are left out, in the service's order")
  func filtering() {
    let definitions = [definition("second"), definition("first"), definition("Bad-Case")]
    let listed = rows(["first", "undefined", "second", "first", "Bad-Case", "!no-unauthenticated"], definitions, prefs())
    #expect(listed.map(\.identifier) == ["first", "second"])
  }
}
