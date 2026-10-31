import Foundation
import Petrel
import Testing

@testable import Catbird

// ModerationPolicy: effective adult content, fail-closed defaults, labeler
// definition filtering, and the convenience queries other code calls.

private let bluesky = ModerationPrefs.blueskyModerationDID
private let labelerA = "did:plc:labeler-a"
private let labelerB = "did:plc:labeler-b"

private func policy(
  account: String? = ModerationFixtures.selfDID,
  serverAdult: Bool = true,
  prefs: [ContentLabelPreference] = [],
  labelers: [String] = [],
  definitions: [String: [ComAtprotoLabelDefs.LabelValueDefinition]] = [:],
  confirmed: Bool = true
) -> ModerationPolicy {
  ModerationPolicy(
    accountDID: account, serverAdultContentEnabled: serverAdult, contentLabelPrefs: prefs,
    labelerDIDs: labelers, labelerDefinitions: definitions, isConfirmed: confirmed)
}

private func definition(_ identifier: String, blurs: String = "content", severity: String = "alert") -> ComAtprotoLabelDefs.LabelValueDefinition {
  .init(identifier: identifier, severity: severity, blurs: blurs, defaultSetting: "warn", locales: [])
}

@Suite("Moderation: policy")
struct ModerationPolicyTests {
  // MARK: Effective adult content

  @Test("Adult content is effective only when the server value is on and this session confirmed it", arguments: [
    (true, true, true),
    (false, true, false),
    (true, false, false),
    (false, false, false),
  ])
  func effectiveAdult(server: Bool, confirmed: Bool, expected: Bool) {
    let result = policy(serverAdult: server, confirmed: confirmed)
    #expect(result.adultContentEnabled == expected)
    #expect(result.prefs.adultContentEnabled == expected)
    #expect(result.isConfirmed == confirmed)
  }

  @Test("Unconfirmed or adult-off sessions hide adult media and lock the blur")
  func unconfirmedHidesAdultMedia() throws {
    let author = try ModerationFixtures.profile("alice")
    let label = try ModerationFixtures.postLabel("porn", name: "alice", src: bluesky)
    let post = try ModerationFixtures.post(author: author, labels: [label])

    for blocked in [policy(confirmed: false), policy(serverAdult: false)] {
      let decision = blocked.decide(post: post)
      expectModeration(decision, [.contentList: [.filter], .contentMedia: [.blur, .noOverride]], "adult blocked")
      #expect(blocked.listFilter(post: post))
    }

    // Adult content effective and the user choosing "warn": media blurs, nothing is removed.
    let allowed = policy(prefs: [ContentLabelPreference(labelerDid: nil, label: "porn", visibility: "warn")])
    expectModeration(allowed.decide(post: post), [.contentMedia: [.blur]], "adult allowed, warn")
    #expect(!allowed.listFilter(post: post))
  }

  // MARK: Fail closed

  @Test("The fail-closed policy has no account, adult off, builtin defaults, Bluesky only")
  func failClosed() {
    let closed = ModerationPolicy.failClosed
    #expect(closed.accountDID == nil)
    #expect(!closed.adultContentEnabled)
    #expect(!closed.isConfirmed)
    #expect(closed.prefs.labels == ModerationPrefs.builtinDefaultLabels)
    #expect(closed.prefs.labelers.map(\.did) == [bluesky])
    #expect(closed.labelDefinitions.isEmpty)
    #expect(!closed.options().isAuthenticated)
  }

  @Test("Fail-closed still honors Bluesky system labels and treats the viewer as logged out")
  func failClosedSystemLabels() throws {
    let author = try ModerationFixtures.profile("alice")
    let noAuth = try ModerationFixtures.accountLabel("!no-unauthenticated", name: "alice", src: bluesky)
    let hide = try ModerationFixtures.postLabel("!hide", name: "alice", src: bluesky)

    let decision = ModerationPolicy.failClosed.decide(
      post: try ModerationFixtures.post(author: try ModerationFixtures.profile("alice", labels: [noAuth]), labels: [hide]))
    #expect(decision.ui(.contentList).filter)
    #expect(decision.ui(.contentList).noOverride)
    #expect(ModerationPolicy.failClosed.decide(profile: author).isEmpty)
  }

  // MARK: Definitions

  @Test("Only subscribed labelers' definitions are kept, and rejected definitions are dropped")
  func definitionsFiltered() {
    let result = policy(
      labelers: [labelerA],
      definitions: [
        labelerA: [definition("spoiler"), definition("porn"), definition("!hide")],
        labelerB: [definition("other")],
        bluesky: [definition("bsky-custom")],
        "did:plc:nobody": [definition("ghost")],
      ])
    #expect(Set(result.labelDefinitions.keys) == [labelerA, bluesky])
    #expect(result.labelDefinitions[labelerA]?.map(\.identifier) == ["spoiler"])
    #expect(result.labelDefinitions[labelerA]?.first?.definedBy == labelerA)
    #expect(result.labelDefinitions[bluesky]?.map(\.identifier) == ["bsky-custom"])
  }

  @Test("A labeler whose only definitions are rejected has no entry")
  func allRejectedNoEntry() {
    let result = policy(labelers: [labelerA], definitions: [labelerA: [definition("porn")]])
    #expect(result.labelDefinitions.isEmpty)
  }

  @Test("definition(for:) resolves builtins and the issuing labeler's own definitions only")
  func definitionLookup() throws {
    let result = policy(labelers: [labelerA, labelerB], definitions: [labelerA: [definition("spoiler")]])
    let builtin = try ModerationFixtures.postLabel("porn", name: "alice", src: labelerB)
    let custom = try ModerationFixtures.postLabel("spoiler", name: "alice", src: labelerA)
    let wrongIssuer = try ModerationFixtures.postLabel("spoiler", name: "alice", src: labelerB)
    let unknown = try ModerationFixtures.postLabel("mystery", name: "alice", src: labelerA)

    #expect(result.definition(for: builtin)?.identifier == "porn")
    #expect(result.definition(for: builtin)?.definedBy == nil)
    #expect(result.definition(for: custom)?.definedBy == labelerA)
    #expect(result.definition(for: wrongIssuer) == nil)
    #expect(result.definition(for: unknown) == nil)
  }

  @Test("A subscribed labeler's custom label moderates through the policy")
  func customLabelThroughPolicy() throws {
    let result = policy(
      prefs: [ContentLabelPreference(labelerDid: try DID(didString: labelerA), label: "spoiler", visibility: "hide")],
      labelers: [labelerA], definitions: [labelerA: [definition("spoiler")]])
    let label = try ModerationFixtures.postLabel("spoiler", name: "alice", src: labelerA)
    let post = try ModerationFixtures.post(author: try ModerationFixtures.profile("alice"), labels: [label])
    expectModeration(result.decide(post: post), [.contentList: [.filter, .blur], .contentView: [.alert]], "custom spoiler")
  }

  // MARK: Options and equality

  @Test("options(now:) carries the account, prefs, definitions and time")
  func optionsSnapshot() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let result = policy(labelers: [labelerA], definitions: [labelerA: [definition("spoiler")]])
    let options = result.options(now: now)
    #expect(options.userDID == ModerationFixtures.selfDID)
    #expect(options.prefs == result.prefs)
    #expect(options.labelDefinitions == result.labelDefinitions)
    #expect(options.now == now)
    #expect(options.isAuthenticated)
  }

  @Test("Policies compare by value")
  func equality() {
    #expect(policy() == policy())
    #expect(policy() != policy(serverAdult: false))
    #expect(policy() != policy(labelers: [labelerA]))
    #expect(policy() != policy(account: "did:plc:someone-else"))
  }
}
