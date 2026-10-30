import Foundation
import Petrel
import Testing

@testable import Catbird

// Port of `moderation-prefs.test.ts` (the parts that exercise preference
// normalization rather than the PDS) plus Catbird's canonical-key rules.

private let bluesky = ModerationPrefs.blueskyModerationDID
private let otherLabeler = "did:plc:other"

private func pref(_ label: String, _ visibility: String, labeler: String? = nil) throws -> ContentLabelPreference {
  ContentLabelPreference(labelerDid: try labeler.map { try DID(didString: $0) }, label: label, visibility: visibility)
}

private func prefs(
  _ contentLabelPrefs: [ContentLabelPreference] = [],
  labelers: [String] = [],
  adult: Bool = false
) -> ModerationPrefs {
  ModerationPrefs(adultContentEnabled: adult, contentLabelPrefs: contentLabelPrefs, labelerDIDs: labelers)
}

@Suite("Moderation: preferences")
struct ModerationPreferencesTests {
  // MARK: Visibility parsing

  @Test("Visibility strings match exactly: ignore, legacy show, warn, hide")
  func visibilityParsing() {
    #expect(LabelPreference(preferenceValue: "ignore") == .ignore)
    #expect(LabelPreference(preferenceValue: "show") == .ignore)
    #expect(LabelPreference(preferenceValue: "warn") == .warn)
    #expect(LabelPreference(preferenceValue: "hide") == .hide)
    // Case-sensitive, like the SDK: a differently cased value is not recognized.
    #expect(LabelPreference(preferenceValue: "HIDE") == nil)
    #expect(LabelPreference(preferenceValue: "Show") == nil)
    #expect(LabelPreference(preferenceValue: "") == nil)
    #expect(LabelPreference(preferenceValue: "blur") == nil)
  }

  @Test("What a decision acts on: unknown non-empty visibility is warn-like, empty is no preference")
  func storedVisibilityParsing() {
    #expect(LabelPreference(storedVisibility: "ignore") == .ignore)
    #expect(LabelPreference(storedVisibility: "show") == .ignore)
    #expect(LabelPreference(storedVisibility: "warn") == .warn)
    #expect(LabelPreference(storedVisibility: "hide") == .hide)
    // Passed through by the SDK, truthy, and neither ignore nor hide.
    #expect(LabelPreference(storedVisibility: "HIDE") == .warn)
    #expect(LabelPreference(storedVisibility: "Show") == .warn)
    #expect(LabelPreference(storedVisibility: "block") == .warn)
    #expect(LabelPreference(storedVisibility: " ") == .warn)
    // Falsy in the SDK.
    #expect(LabelPreference(storedVisibility: "") == nil)
  }

  // MARK: Defaults

  @Test("Empty preferences seed the builtin defaults and the Bluesky labeler")
  func defaults() {
    let result = prefs()
    #expect(result.labels == ["porn": .hide, "sexual": .warn, "nudity": .ignore, "graphic-media": .warn])
    #expect(result.labelers == [LabelerModerationPrefs(did: bluesky)])
    #expect(result.adultContentEnabled == false)
    #expect(ModerationPrefs.builtinDefaultLabels == result.labels)
  }

  // MARK: Legacy migration

  @Test("Legacy 'show' migrates to ignore for every builtin label")
  func legacyShowMigrates() throws {
    let result = prefs([
      try pref("porn", "show"), try pref("nudity", "show"), try pref("sexual", "show"), try pref("graphic-media", "show"),
    ])
    #expect(result.labels == ["porn": .ignore, "nudity": .ignore, "sexual": .ignore, "graphic-media": .ignore])
  }

  @Test("Old keys remap to canonical keys on read and stay under their own name, as the SDK does")
  func legacyKeysRemap() throws {
    let result = prefs([try pref("nsfw", "hide"), try pref("gore", "hide"), try pref("suggestive", "hide")])
    #expect(result.labels["porn"] == .hide)
    #expect(result.labels["graphic-media"] == .hide)
    #expect(result.labels["sexual"] == .hide)
    #expect(result.labels["nsfw"] == .hide, "the legacy name is copied, not moved")
    #expect(result.labels["gore"] == .hide)
    #expect(result.labels["suggestive"] == .hide)
  }

  @Test("Catbird's old private 'graphic' key is read as graphic-media when nothing else sets it")
  func catbirdGraphicKey() throws {
    let alone = prefs([try pref("graphic", "hide")])
    #expect(alone.labels["graphic-media"] == .hide)
    #expect(alone.labels["graphic"] == nil, "it is read as graphic-media, not kept as its own key")

    // Several entries are all read as graphic-media, in array order.
    #expect(prefs([try pref("graphic", "warn"), try pref("graphic", "hide")]).labels["graphic-media"] == .hide)
    #expect(prefs([try pref("graphic", "show")]).labels["graphic-media"] == .ignore)

    // Once a global graphic-media or gore entry exists it is an inert key, as in the SDK.
    let inert = prefs([try pref("graphic", "hide"), try pref("graphic-media", "warn")])
    #expect(inert.labels["graphic-media"] == .warn)
    #expect(inert.labels["graphic"] == .hide)
  }

  @Test("Preference keys match exactly, so a differently cased key is a different key")
  func keyCase() throws {
    let unrelated = prefs([try pref("NSFW", "warn"), try pref("Graphic-Media", "ignore"), try pref("GRAPHIC", "ignore")])
    #expect(unrelated.labels["porn"] == .hide, "NSFW is not nsfw")
    #expect(unrelated.labels["graphic-media"] == .warn, "neither Graphic-Media nor GRAPHIC reach graphic-media")
    #expect(unrelated.labels["NSFW"] == .warn, "the key is kept as sent")

    // A stray-case duplicate can never weaken the exact key.
    #expect(prefs([try pref("porn", "hide"), try pref("PORN", "ignore")]).labels["porn"] == .hide)
    #expect(prefs([try pref("PORN", "ignore"), try pref("porn", "hide")]).labels["porn"] == .hide)
  }

  @Test("Among conflicting entries for one label the later one wins, as the SDK does", arguments: [
    ("porn", "nsfw"), ("sexual", "suggestive"), ("graphic-media", "gore"),
  ])
  func lastEntryWins(canonical: String, legacy: String) throws {
    // A legacy hide after a canonical ignore must not be lost.
    #expect(prefs([try pref(canonical, "ignore"), try pref(legacy, "hide")]).labels[canonical] == .hide)
    #expect(prefs([try pref(legacy, "hide"), try pref(canonical, "ignore")]).labels[canonical] == .ignore)
    #expect(prefs([try pref(canonical, "hide"), try pref(legacy, "ignore")]).labels[canonical] == .ignore)
    #expect(prefs([try pref(legacy, "ignore"), try pref(canonical, "hide")]).labels[canonical] == .hide)
  }

  @Test("A repeated key keeps its last value")
  func repeatedKeyLastWins() throws {
    #expect(prefs([try pref("porn", "hide"), try pref("porn", "warn")]).labels["porn"] == .warn)
    #expect(prefs([try pref("porn", "warn"), try pref("porn", "hide")]).labels["porn"] == .hide)
    let mixed = prefs([try pref("nsfw", "ignore"), try pref("porn", "hide"), try pref("nsfw", "warn")])
    #expect(mixed.labels["porn"] == .warn)
  }

  @Test("A legacy alias still applies when no canonical key exists")
  func legacyAppliesAlone() throws {
    let result = prefs([try pref("nsfw", "ignore"), try pref("gore", "hide")])
    #expect(result.labels["porn"] == .ignore)
    #expect(result.labels["graphic-media"] == .hide)
  }

  @Test("The old 'graphic' key is only a fallback for graphic-media", arguments: [true, false])
  func graphicIsAFallback(graphicFirst: Bool) throws {
    func ordered(_ graphic: ContentLabelPreference, _ other: ContentLabelPreference) -> [ContentLabelPreference] {
      graphicFirst ? [graphic, other] : [other, graphic]
    }
    // An explicit graphic-media or gore entry beats it, in either order.
    #expect(prefs(ordered(try pref("graphic", "ignore"), try pref("gore", "hide"))).labels["graphic-media"] == .hide)
    #expect(prefs(ordered(try pref("graphic", "hide"), try pref("graphic-media", "warn"))).labels["graphic-media"] == .warn)
    #expect(prefs(ordered(try pref("graphic", "ignore"), try pref("graphic-media", "hide"))).labels["graphic-media"] == .hide)
    // Any global entry counts as explicit, whatever its visibility says.
    #expect(prefs(ordered(try pref("graphic", "hide"), try pref("graphic-media", "blur"))).labels["graphic-media"] == .warn)
    #expect(prefs(ordered(try pref("graphic", "hide"), try pref("graphic-media", ""))).labels["graphic-media"] == .warn)
    // A labeler-scoped entry does not.
    #expect(prefs(ordered(try pref("graphic", "hide"), try pref("graphic-media", "warn", labeler: bluesky))).labels["graphic-media"] == .hide)
    #expect(prefs(ordered(try pref("graphic", "hide"), try pref("gore", "warn", labeler: bluesky))).labels["graphic-media"] == .hide)
    // Unrelated entries do not disturb it.
    #expect(prefs(ordered(try pref("graphic", "hide"), try pref("porn", "warn"))).labels["graphic-media"] == .hide)
  }

  @Test("An unknown visibility is an explicit warn-like preference; an empty one is no preference")
  func unknownVisibility() throws {
    let result = prefs([try pref("porn", "blur"), try pref("sexual", ""), try pref("nudity", "HIDE")])
    #expect(result.labels["porn"] == .warn, "block-like strings override the hide default but are not hide")
    #expect(result.labels["sexual"] == .warn, "empty falls back to the builtin default")
    #expect(result.labels["nudity"] == .warn, "a differently cased hide is unknown")

    // Empty clears an earlier value, in either direction.
    #expect(prefs([try pref("porn", "ignore"), try pref("porn", "")]).labels["porn"] == .hide)
    #expect(prefs([try pref("porn", ""), try pref("porn", "ignore")]).labels["porn"] == .ignore)
    // A custom label's empty preference leaves no entry at all.
    #expect(prefs([try pref("spoiler", "hide"), try pref("spoiler", "")]).labels["spoiler"] == nil)
    #expect(prefs([try pref("spoiler", "nonsense")]).labels["spoiler"] == .warn)
    // The legacy copy follows the same rule.
    let legacy = prefs([try pref("nsfw", "blur")])
    #expect(legacy.labels["porn"] == .warn)
    #expect(legacy.labels["nsfw"] == .warn)
    let legacyEmpty = prefs([try pref("nsfw", "hide"), try pref("nsfw", "")])
    #expect(legacyEmpty.labels["porn"] == .hide, "back to the builtin default")
    #expect(legacyEmpty.labels["nsfw"] == nil)
  }

  @Test("Labeler-scoped unknown visibility is warn-like and an empty one falls through to the global value")
  func scopedUnknownVisibility() throws {
    let result = prefs(
      [
        try pref("porn", "block", labeler: bluesky), try pref("nudity", "hide"), try pref("nudity", "", labeler: bluesky),
        try pref("sexual", "hide", labeler: bluesky), try pref("sexual", "", labeler: bluesky),
      ])
    #expect(result.labelers.first?.labels == ["porn": .warn])
  }

  // MARK: Labelers

  @Test("Labelers start with Bluesky, keep subscription order, and are deduplicated")
  func labelerOrder() {
    #expect(prefs(labelers: []).labelers.map(\.did) == [bluesky])
    #expect(prefs(labelers: [otherLabeler]).labelers.map(\.did) == [bluesky, otherLabeler])
    #expect(prefs(labelers: [otherLabeler, bluesky, otherLabeler, "did:plc:third"]).labelers.map(\.did) == [bluesky, otherLabeler, "did:plc:third"])
  }

  @Test("Global and labeler-scoped preferences are stored separately")
  func globalAndScoped() throws {
    let result = prefs(
      [
        try pref("porn", "ignore"),
        try pref("porn", "hide", labeler: otherLabeler),
        try pref("x-custom", "warn", labeler: otherLabeler),
      ], labelers: [otherLabeler])
    #expect(result.labels["porn"] == .ignore)
    let other = result.labelers.first { $0.did == otherLabeler }
    #expect(other?.labels == ["porn": .hide, "x-custom": .warn])
    #expect(result.labelers.first { $0.did == bluesky }?.labels == [:])
    #expect(result.labels["x-custom"] == nil, "a scoped preference never becomes global")
  }

  @Test("A scoped preference for an unsubscribed labeler is dropped")
  func unsubscribedScopedDropped() throws {
    let result = prefs([try pref("porn", "ignore", labeler: otherLabeler)], labelers: [])
    #expect(result.labelers == [LabelerModerationPrefs(did: bluesky)])
    #expect(result.labels["porn"] == .hide)
  }

  @Test("Scoped preferences attach to the Bluesky labeler too")
  func scopedToBluesky() throws {
    let result = prefs([try pref("nudity", "hide", labeler: bluesky)])
    #expect(result.labelers.first?.labels == ["nudity": .hide])
  }

  @Test("Scoped keys are stored exactly as sent and never remapped", arguments: [true, false])
  func scopedKeysVerbatim(legacyFirst: Bool) throws {
    let canonical = try pref("porn", "hide", labeler: otherLabeler)
    let legacy = try pref("nsfw", "ignore", labeler: otherLabeler)
    let result = prefs(legacyFirst ? [legacy, canonical] : [canonical, legacy], labelers: [otherLabeler])
    #expect(result.labelers.last?.labels == ["porn": .hide, "nsfw": .ignore])
    #expect(result.labels["porn"] == .hide, "scoped entries never reach the global map")
    #expect(result.labels["nsfw"] == nil)

    let others = prefs(
      [
        try pref("suggestive", "hide", labeler: otherLabeler), try pref("gore", "hide", labeler: otherLabeler),
        try pref("graphic", "hide", labeler: otherLabeler), try pref("Porn", "hide", labeler: otherLabeler),
      ], labelers: [otherLabeler])
    #expect(others.labelers.last?.labels == ["suggestive": .hide, "gore": .hide, "graphic": .hide, "Porn": .hide])
    #expect(others.labels == ModerationPrefs.builtinDefaultLabels)
  }

  @Test("A scoped preference overrides the global one when the engine resolves a label")
  func scopedOverridesGlobal() throws {
    let result = prefs(
      [try pref("nudity", "ignore"), try pref("nudity", "hide", labeler: otherLabeler)],
      labelers: [otherLabeler], adult: true)
    let options = ModerationOptions(userDID: ModerationFixtures.selfDID, prefs: result)
    let author = try ModerationFixtures.profile("alice")

    func filtered(src: String) throws -> Bool {
      let label = try ModerationFixtures.postLabel("nudity", name: "alice", src: src)
      let post = try ModerationFixtures.post(author: author, labels: [label])
      return ModerationSubjects.decidePost(post, options: options).ui(.contentList).filter
    }
    #expect(try filtered(src: otherLabeler), "the scoped hide applies to that labeler's labels")
    #expect(try !filtered(src: bluesky), "the global ignore applies to everyone else")
  }

  // MARK: Labeler-defined labels that share a legacy name

  private static let labeler = ModerationFixtures.customLabelerDID

  /// A confirmed, adult-enabled policy for a user subscribed to `labeler`, which
  /// defines `identifier` as an alert that blurs content (default setting warn).
  private func policy(_ stored: [ContentLabelPreference], defining identifier: String?) -> ModerationPolicy {
    let definitions = identifier.map {
      [Self.labeler: [ComAtprotoLabelDefs.LabelValueDefinition(identifier: $0, severity: "alert", blurs: "content", defaultSetting: "warn", locales: [])]]
    }
    return ModerationPolicy(
      accountDID: ModerationFixtures.selfDID, serverAdultContentEnabled: true, contentLabelPrefs: stored,
      labelerDIDs: [Self.labeler], labelerDefinitions: definitions ?? [:], isConfirmed: true)
  }

  private func decision(_ policy: ModerationPolicy, value: String) throws -> ModerationDecision {
    let label = try ModerationFixtures.postLabel(value, name: "alice", src: Self.labeler)
    return policy.decide(post: try ModerationFixtures.post(author: try ModerationFixtures.profile("alice"), labels: [label]))
  }

  @Test("A scoped preference for a labeler's custom 'nsfw' label applies to that label")
  func scopedPreferenceReachesCustomLegacyNamedLabel() throws {
    let hidden = policy([try pref("nsfw", "hide", labeler: Self.labeler)], defining: "nsfw")
    #expect(try decision(hidden, value: "nsfw").ui(.contentList).filter, "the explicit hide is honored")

    let unset = policy([], defining: "nsfw")
    let warned = try decision(unset, value: "nsfw")
    #expect(warned.causes.count == 1 && !warned.ui(.contentList).filter, "control: without the preference the default is warn")
  }

  @Test("A scoped 'nsfw' preference never changes how the same labeler's builtin porn label is handled")
  func scopedLegacyKeyDoesNotLeakOntoBuiltins() throws {
    // Global porn is warn; a scoped nsfw=hide must not turn that labeler's porn into hide.
    let notHidden = policy([try pref("porn", "warn"), try pref("nsfw", "hide", labeler: Self.labeler)], defining: nil)
    let porn = try decision(notHidden, value: "porn")
    #expect(porn.causes.first?.setting == .warn)
    #expect(!porn.ui(.contentList).filter)

    // A scoped nsfw=ignore must not make that labeler's porn labels disappear.
    let kept = policy([try pref("nsfw", "ignore", labeler: Self.labeler)], defining: nil)
    let hiddenPorn = try decision(kept, value: "porn")
    #expect(hiddenPorn.causes.count == 1, "the labeler's builtin porn label is not ignored")
    #expect(hiddenPorn.ui(.contentList).filter)
    #expect(hiddenPorn.ui(.contentMedia).blur)

    for (legacy, builtin) in [("suggestive", "sexual"), ("gore", "graphic-media")] {
      let scopedIgnore = policy([try pref(legacy, "ignore", labeler: Self.labeler), try pref(builtin, "hide")], defining: nil)
      #expect(try decision(scopedIgnore, value: builtin).ui(.contentList).filter, "scoped \(legacy) leaves \(builtin) alone")
    }
  }

  @Test("A global legacy preference also applies to a labeler's custom label of the same name", arguments: ["nsfw", "suggestive"])
  func globalLegacyKeyReachesCustomLabel(name: String) throws {
    let hidden = policy([try pref(name, "hide")], defining: name)
    #expect(try decision(hidden, value: name).ui(.contentList).filter)
    let ignored = policy([try pref(name, "ignore")], defining: name)
    #expect(try decision(ignored, value: name).causes.isEmpty)
  }

  // MARK: Canonical identifiers and double-write aliases

  @Test("Canonical identifier mapping", arguments: [
    ("nsfw", "porn"), ("suggestive", "sexual"), ("gore", "graphic-media"), ("graphic", "graphic-media"),
    ("porn", "porn"), ("sexual", "sexual"), ("graphic-media", "graphic-media"), ("nudity", "nudity"),
    ("X-Custom", "x-custom"), ("!hide", "!hide"),
  ])
  func canonicalIdentifier(input: String, expected: String) {
    #expect(ModerationPrefs.canonicalLabelIdentifier(input) == expected)
  }

  @Test("Legacy aliases for double-writing")
  func legacyAliases() {
    #expect(ModerationPrefs.legacyAlias(forCanonical: "porn") == "nsfw")
    #expect(ModerationPrefs.legacyAlias(forCanonical: "sexual") == "suggestive")
    #expect(ModerationPrefs.legacyAlias(forCanonical: "graphic-media") == "gore")
    #expect(ModerationPrefs.legacyAlias(forCanonical: "nudity") == nil)
    #expect(ModerationPrefs.legacyAlias(forCanonical: "x-custom") == nil)
  }
}
