import Foundation
import Petrel
import Testing

@testable import Catbird

// Catbird-specific engine rules: which label sources are trusted, which labels
// are inactive, how labeler definitions are validated, and how causes rank.

private let bluesky = ModerationPrefs.blueskyModerationDID

@Suite("Moderation: engine")
struct ModerationEngineTests {
  private let author = "alice"

  private func causes(
    _ labels: [ComAtprotoLabelDefs.Label],
    options: ModerationOptions,
    on authorName: String = "alice"
  ) throws -> [ModerationCause] {
    let post = try ModerationFixtures.post(author: try ModerationFixtures.profile(authorName), labels: labels)
    return ModerationSubjects.decidePost(post, options: options).causes
  }

  // MARK: Trusted sources

  @Test("A label from an unsubscribed labeler is ignored")
  func unsubscribedLabelerIgnored() throws {
    let label = try ModerationFixtures.postLabel("!hide", name: author, src: "did:plc:stranger")
    let options = ModerationFixtures.options()
    #expect(try causes([label], options: options).isEmpty)
    // The same label from a subscribed labeler applies, so the control is meaningful.
    let trusted = try ModerationFixtures.postLabel("!hide", name: author, src: ModerationFixtures.labelerDID)
    #expect(try causes([trusted], options: options).count == 1)
  }

  @Test("The Bluesky moderation service is always trusted, even with no subscriptions")
  func blueskyAlwaysTrusted() throws {
    let prefs = ModerationPrefs(adultContentEnabled: true, contentLabelPrefs: [], labelerDIDs: [])
    let options = ModerationOptions(userDID: ModerationFixtures.selfDID, prefs: prefs)
    let label = try ModerationFixtures.postLabel("!warn", name: author, src: bluesky)
    let found = try causes([label], options: options)
    #expect(found.count == 1)
    #expect(found.first?.source == .labeler(did: bluesky))
  }

  @Test("A self-label is trusted without a subscription and is attributed to the user")
  func selfLabelTrusted() throws {
    let options = ModerationFixtures.options(adult: true, labelers: [])
    let label = try ModerationFixtures.postLabel("porn", name: author, src: "did:web:alice.test")
    let found = try causes([label], options: options)
    #expect(found.first?.source == .user)
  }

  @Test("Self-labels cannot use system or labeler-defined values", arguments: ["!hide", "!warn"])
  func selfLabelsRejectNoSelf(value: String) throws {
    let options = ModerationFixtures.options()
    let label = try ModerationFixtures.postLabel(value, name: author, src: "did:web:alice.test")
    #expect(try causes([label], options: options).isEmpty)
  }

  @Test("A labeler-defined label is noSelf, so an author cannot self-apply it")
  func customLabelNoSelf() throws {
    let src = ModerationFixtures.customLabelerDID
    let definition = try #require(ModerationFixtures.customDefinition(blurs: "content", severity: "alert"))
    let options = ModerationFixtures.options(labelers: [LabelerModerationPrefs(did: src)], definitions: [src: [definition]])
    let selfApplied = try ModerationFixtures.postLabel("custom", name: author, src: "did:web:alice.test")
    #expect(try causes([selfApplied], options: options).isEmpty)
  }

  // MARK: Inactive labels

  @Test("Negated labels are ignored")
  func negatedIgnored() throws {
    let label = try ModerationFixtures.postLabel("!hide", name: author, neg: true)
    #expect(try causes([label], options: ModerationFixtures.options()).isEmpty)
  }

  @Test("Expired labels are ignored; unexpired and unbounded labels apply")
  func expiry() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let options = ModerationFixtures.options(now: now)
    let expired = try ModerationFixtures.postLabel("!hide", name: author, exp: now.addingTimeInterval(-60))
    let boundary = try ModerationFixtures.postLabel("!hide", name: author, exp: now)
    let future = try ModerationFixtures.postLabel("!hide", name: author, exp: now.addingTimeInterval(60))
    let unbounded = try ModerationFixtures.postLabel("!hide", name: author)

    #expect(try causes([expired], options: options).isEmpty)
    #expect(try causes([boundary], options: options).isEmpty, "a label expiring exactly now is expired")
    #expect(try causes([future], options: options).count == 1)
    #expect(try causes([unbounded], options: options).count == 1)
  }

  @Test("An explicit false neg is an ordinary label")
  func negFalseApplies() throws {
    let label = try ModerationFixtures.postLabel("!hide", name: author, neg: false)
    #expect(try causes([label], options: ModerationFixtures.options()).count == 1)
  }

  @Test("Labels the engine does not understand are ignored")
  func unknownLabelIgnored() throws {
    let label = try ModerationFixtures.postLabel("some-unknown-value", name: author)
    #expect(try causes([label], options: ModerationFixtures.options()).isEmpty)
  }

  // MARK: Duplicates

  @Test("The same labeler repeating a label for the same target adds one cause")
  func duplicatesCollapse() throws {
    let label = try ModerationFixtures.postLabel("!warn", name: author)
    let found = try causes([label, label], options: ModerationFixtures.options())
    #expect(found.count == 1)
  }

  @Test("Only an exact duplicate collapses: the same labeler and value on another subject URI is a separate cause")
  func differentSubjectsKeepBothCauses() throws {
    let options = ModerationFixtures.options(adult: true)
    let src = ModerationFixtures.labelerDID
    let first = try ModerationFixtures.label("porn", uri: "at://did:web:alice.test/app.bsky.feed.post/p1", src: src)
    let other = try ModerationFixtures.label("porn", uri: "at://did:web:alice.test/app.bsky.feed.post/p1-other", src: src)

    let post = try ModerationFixtures.post(author: try ModerationFixtures.profile(author), labels: [first, other])
    let decision = ModerationSubjects.decidePost(post, options: options)
    #expect(decision.causes.count == 2)
    #expect(decision.ui(.contentList).filters.count == 2)

    // Control: repeating the identical label (same URI) still adds nothing.
    #expect(try causes([first, other, first, other], options: options).count == 2)
  }

  @Test("!no-unauthenticated on both the account and the profile record yields two account causes and one profile cause")
  func noUnauthenticatedOnAccountAndProfileRecord() throws {
    let account = try ModerationFixtures.accountLabel("!no-unauthenticated", name: "bob")
    let profileRecord = try ModerationFixtures.profileLabel("!no-unauthenticated", name: "bob")
    let loggedOut = ModerationFixtures.options(authed: false)

    let decision = ModerationSubjects.decideProfileSubject(
      try ModerationFixtures.profile("bob", labels: [account, profileRecord]), options: loggedOut)
    #expect(decision.causes.filter { $0.target == .account }.count == 2, "both URIs are labels on the account")
    #expect(decision.causes.filter { $0.target == .profile }.count == 1)

    // Control: the account label repeated verbatim still collapses.
    let repeated = ModerationSubjects.decideAccount(
      try ModerationFixtures.profile("bob", labels: [account, account]), options: loggedOut)
    #expect(repeated.causes.count == 1)
  }

  @Test("Different labelers or different values are separate causes")
  func distinctCausesKept() throws {
    let other = "did:plc:other-labeler"
    let options = ModerationFixtures.options(labelers: [
      LabelerModerationPrefs(did: ModerationFixtures.labelerDID), LabelerModerationPrefs(did: other),
    ])
    let labels = [
      try ModerationFixtures.postLabel("!warn", name: author),
      try ModerationFixtures.postLabel("!warn", name: author, src: other),
      try ModerationFixtures.postLabel("!hide", name: author),
    ]
    #expect(try causes(labels, options: options).count == 3)
  }

  // MARK: Definition hardening

  @Test("A labeler can never define a builtin, an alias, or a system label", arguments: [
    "porn", "sexual", "nudity", "graphic-media", "gore", "!hide", "!warn", "!no-unauthenticated", "!anything",
  ])
  func reservedIdentifiersRejected(identifier: String) {
    let definition = ComAtprotoLabelDefs.LabelValueDefinition(
      identifier: identifier, severity: "alert", blurs: "none", defaultSetting: "ignore", locales: [])
    #expect(ModerationLabelDefinition.interpret(definition, definedBy: ModerationFixtures.customLabelerDID) == nil)
    #expect(ModerationLabelDefinition.interpretAll([definition], definedBy: ModerationFixtures.customLabelerDID).isEmpty)
  }

  @Test("Identifiers must match ^[a-z-]+$ and fit the lexicon length", arguments: [
    ("", false), ("custom", true), ("x-custom", true), ("-", true), ("Custom", false), ("custom1", false),
    ("custom_value", false), ("custom value", false), ("café", false), (String(repeating: "a", count: 100), true),
    (String(repeating: "a", count: 101), false),
  ])
  func identifierSyntax(identifier: String, valid: Bool) {
    let definition = ComAtprotoLabelDefs.LabelValueDefinition(
      identifier: identifier, severity: "inform", blurs: "none", locales: [])
    #expect((ModerationLabelDefinition.interpret(definition, definedBy: "did:plc:x") != nil) == valid)
    #expect(ModerationLabelDefinition.isValidCustomIdentifier(identifier) == valid)
  }

  @Test("interpretAll drops only the rejected definitions and keeps order")
  func interpretAllFilters() {
    func def(_ identifier: String) -> ComAtprotoLabelDefs.LabelValueDefinition {
      .init(identifier: identifier, severity: "inform", blurs: "none", locales: [])
    }
    let result = ModerationLabelDefinition.interpretAll(
      [def("first"), def("porn"), def("!hide"), def("second"), def("Bad")], definedBy: "did:plc:x")
    #expect(result.map(\.identifier) == ["first", "second"])
    #expect(result.allSatisfy { $0.definedBy == "did:plc:x" && $0.configurable })
  }

  @Test("A definition smuggled in under a builtin name never shadows the builtin")
  func smuggledDefinitionIgnored() throws {
    let src = ModerationFixtures.customLabelerDID
    // Bypass `interpret` to build what it refuses to build.
    let forged = ModerationLabelDefinition(
      identifier: "porn", configurable: true, defaultSetting: .ignore, flags: [], blurs: .none,
      severity: .none, behaviors: [:], definedBy: src, locales: [])
    let options = ModerationFixtures.options(
      adult: true, settings: ["porn": .hide], labelers: [LabelerModerationPrefs(did: src)], definitions: [src: [forged]])
    let label = try ModerationFixtures.postLabel("porn", name: author, src: src)
    let found = try causes([label], options: options)
    let cause = try #require(found.first)
    #expect(cause.definition.definedBy == nil, "the builtin definition is used")
    #expect(cause.behavior[.contentMedia] == .blur)
  }

  @Test("A definition is only used for labels from the labeler that declared it")
  func definitionScopedToLabeler() throws {
    let declaring = "did:web:declaring.test"
    let other = "did:web:other.test"
    let definition = try #require(ModerationFixtures.customDefinition(blurs: "content", severity: "alert", definedBy: declaring))
    let options = ModerationFixtures.options(
      labelers: [LabelerModerationPrefs(did: declaring), LabelerModerationPrefs(did: other)],
      definitions: [declaring: [definition]])

    let fromDeclaring = try ModerationFixtures.postLabel("custom", name: author, src: declaring)
    let fromOther = try ModerationFixtures.postLabel("custom", name: author, src: other)
    #expect(try causes([fromDeclaring], options: options).count == 1)
    #expect(try causes([fromOther], options: options).isEmpty)

    // A definition filed under the wrong labeler key is rejected too.
    let misfiled = ModerationFixtures.options(
      labelers: [LabelerModerationPrefs(did: other)], definitions: [other: [definition]])
    #expect(try causes([fromOther], options: misfiled).isEmpty)
  }

  @Test("Interpretation copies localized strings")
  func interpretationLocales() throws {
    let strings = ComAtprotoLabelDefs.LabelValueDefinitionStrings(
      lang: LanguageCodeContainer(languageCode: "en-GB"), name: "Spoilers", description: "Plot details.")
    let definition = try #require(
      ModerationLabelDefinition.interpret(
        .init(identifier: "spoiler", severity: "inform", blurs: "content", locales: [strings]), definedBy: "did:plc:x"))
    #expect(definition.locales == [LabelDisplayStrings(lang: "en-GB", name: "Spoilers", description: "Plot details.")])
    #expect(definition.blurs == .content)
    #expect(definition.severity == .inform)
  }

  // MARK: Priority and ranking

  @Test("Priorities: system or forced 1, hide 2, then 5 / 7 / 8 by how strongly the label blurs")
  func priorities() throws {
    let src = ModerationFixtures.customLabelerDID
    // `adultOnly` makes a content label blur the thread view, the high-severity case.
    let alertContent = try #require(
      ModerationFixtures.customDefinition("view", blurs: "content", severity: "alert", adultOnly: true))
    let mediaOnly = try #require(ModerationFixtures.customDefinition("media", blurs: "media", severity: "none"))
    let alertOnly = try #require(ModerationFixtures.customDefinition("alert", blurs: "none", severity: "alert"))
    let options = ModerationFixtures.options(
      adult: true,
      settings: ["porn": .warn],
      labelers: [
        LabelerModerationPrefs(did: ModerationFixtures.labelerDID),
        LabelerModerationPrefs(did: src, labels: ["view": .warn, "media": .warn, "alert": .warn]),
      ],
      definitions: [src: [alertContent, mediaOnly, alertOnly]])

    func priority(_ value: String, from source: String) throws -> Int? {
      let label = try ModerationFixtures.postLabel(value, name: author, src: source)
      return try causes([label], options: options).first?.priority
    }
    #expect(try priority("!hide", from: ModerationFixtures.labelerDID) == 1)
    #expect(try priority("!warn", from: ModerationFixtures.labelerDID) == 5, "!warn blurs the thread view: high severity")
    #expect(try priority("porn", from: ModerationFixtures.labelerDID) == 7, "media blur is medium severity")
    #expect(try priority("view", from: src) == 5)
    #expect(try priority("media", from: src) == 7)
    #expect(try priority("alert", from: src) == 8)

    // `hide` outranks the severity tiers; forced adult-off hide is priority 1.
    let hiding = ModerationFixtures.options(adult: true, settings: ["porn": .hide])
    let hidePorn = try ModerationFixtures.postLabel("porn", name: author)
    #expect(try causes([hidePorn], options: hiding).first?.priority == 2)
    let adultOff = ModerationFixtures.options(adult: false)
    #expect(try causes([hidePorn], options: adultOff).first?.priority == 1)
    #expect(try causes([hidePorn], options: adultOff).first?.noOverride == true)
  }

  @Test("Filters and blurs are sorted by priority, keeping insertion order for ties")
  func uiSortedByPriority() throws {
    let other = "did:plc:other-labeler"
    let options = ModerationFixtures.options(
      adult: true, settings: ["nudity": .hide, "porn": .warn],
      labelers: [LabelerModerationPrefs(did: ModerationFixtures.labelerDID), LabelerModerationPrefs(did: other)])
    let labels = [
      try ModerationFixtures.postLabel("porn", name: author),  // warn: priority 7
      try ModerationFixtures.postLabel("nudity", name: author),  // hide: priority 2
      try ModerationFixtures.postLabel("nudity", name: author, src: other),  // hide: priority 2, later
      try ModerationFixtures.postLabel("!hide", name: author),  // priority 1
    ]
    let post = try ModerationFixtures.post(author: try ModerationFixtures.profile(author), labels: labels)
    let ui = ModerationSubjects.decidePost(post, options: options).ui(.contentMedia)
    #expect(ui.blurs.map(\.priority) == [2, 2, 7])
    #expect(ui.blurs.map(\.label.val) == ["nudity", "nudity", "porn"])
    #expect(ui.blurs.map(\.labelerDID) == [ModerationFixtures.labelerDID, other, ModerationFixtures.labelerDID])
    let list = ModerationSubjects.decidePost(post, options: options).ui(.contentList)
    #expect(list.filters.map(\.priority) == [1, 2, 2])
  }

  // MARK: Decision plumbing

  @Test("merge takes did and isMe from the first non-nil decision and joins causes")
  func mergeSemantics() throws {
    let options = ModerationFixtures.options()
    let label = try ModerationFixtures.postLabel("!warn", name: author)
    var first = ModerationDecision(did: "did:web:alice.test", isMe: false)
    first.addLabel(label, target: .content, options: options)
    let second = ModerationDecision(did: "did:web:self.test", isMe: true, causes: first.causes)

    let merged = ModerationDecision.merge([nil, first, nil, second])
    #expect(merged.did == "did:web:alice.test")
    #expect(merged.isMe == false)
    #expect(merged.causes.count == 2)
    #expect(ModerationDecision.merge([]).isEmpty)
    #expect(ModerationDecision.merge([nil, nil]).did == "")
  }

  @Test("downgraded() marks every cause and leaves the original untouched")
  func downgradeCopies() throws {
    let label = try ModerationFixtures.postLabel("!hide", name: author)
    var decision = ModerationDecision(did: "did:web:alice.test")
    decision.addLabel(label, target: .content, options: ModerationFixtures.options())
    let downgraded = decision.downgraded()
    #expect(downgraded.causes.allSatisfy { $0.downgraded })
    #expect(decision.causes.allSatisfy { !$0.downgraded })
    #expect(downgraded.ui(.contentList).filter)
    #expect(!downgraded.ui(.contentList).blur)
  }

  @Test("A decision with no causes is a complete no-op in every context")
  func emptyDecision() {
    let decision = ModerationDecision(did: "did:web:alice.test")
    for context in ModerationContext.allCases {
      #expect(decision.ui(context) == .empty)
    }
  }

  @Test("A post with no labels anywhere returns an empty decision that still names its author")
  func fastPath() throws {
    let options = ModerationFixtures.options()
    let plain = try ModerationFixtures.post(author: try ModerationFixtures.profile("self"))
    let decision = ModerationSubjects.decidePost(plain, options: options)
    #expect(decision.isEmpty)
    #expect(decision.did == ModerationFixtures.selfDID)
    #expect(decision.isMe)

    let quoted = try ModerationFixtures.quotedRecord(author: try ModerationFixtures.profile("carla"))
    let withQuote = try ModerationFixtures.post(author: try ModerationFixtures.profile("bob"), quote: quoted)
    #expect(ModerationSubjects.decidePost(withQuote, options: options).isEmpty)
  }

  @Test("Own content: a hide setting does not filter the author's own post")
  func ownContentNotFiltered() throws {
    let options = ModerationFixtures.options(adult: true, settings: ["porn": .hide])
    let label = try ModerationFixtures.postLabel("porn", name: "self")
    let post = try ModerationFixtures.post(author: try ModerationFixtures.profile("self"), labels: [label])
    let decision = ModerationSubjects.decidePost(post, options: options)
    #expect(decision.isMe)
    #expect(!decision.ui(.contentList).filter)
    #expect(decision.ui(.contentMedia).blur, "the author still sees their media behind a blur")
  }
}
