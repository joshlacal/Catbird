import Foundation
import Petrel
import Testing

@testable import Catbird

@Suite("Age policy: moderation ceiling")
struct AgeModerationCeilingTests {
  private static let labelerA = "did:web:age-labeler-a.example"
  private static let labelerB = "did:web:age-labeler-b.example"

  // Fixture construction only; decisions and restriction copies use production code.
  private func basePolicy(serverAdult: Bool = true, confirmed: Bool = true) throws -> ModerationPolicy {
    ModerationPolicy(
      accountDID: ModerationFixtures.selfDID,
      serverAdultContentEnabled: serverAdult,
      contentLabelPrefs: [
        ContentLabelPreference(labelerDid: nil, label: "porn", visibility: "warn"),
        ContentLabelPreference(labelerDid: nil, label: "graphic-media", visibility: "hide"),
        ContentLabelPreference(labelerDid: try DID(didString: Self.labelerA), label: "spoiler", visibility: "hide"),
        ContentLabelPreference(labelerDid: try DID(didString: Self.labelerB), label: "spoiler", visibility: "ignore"),
      ],
      labelerDIDs: [Self.labelerB, Self.labelerA],
      labelerDefinitions: [
        Self.labelerA: [definition("spoiler")],
        Self.labelerB: [definition("spoiler")],
      ],
      isConfirmed: confirmed)
  }

  private func definition(_ identifier: String) -> ComAtprotoLabelDefs.LabelValueDefinition {
    .init(identifier: identifier, severity: "alert", blurs: "content", defaultSetting: "warn", locales: [])
  }

  @Test("A platform restriction never enables adult content or changes the base", arguments: [
    (true, true, true),
    (false, true, false),
    (true, false, false),
    (false, false, false),
  ])
  func restrictionCannotEnable(serverAdult: Bool, confirmed: Bool, expectedBase: Bool) throws {
    let base = try basePolicy(serverAdult: serverAdult, confirmed: confirmed)
    let before = base

    let restricted = base.restrictingMatureContent(true)

    #expect(!restricted.adultContentEnabled)
    #expect(!restricted.prefs.adultContentEnabled)
    #expect(restricted.isConfirmed == confirmed)
    #expect(restricted.restrictingMatureContent(true) == restricted)
    #expect(base == before)
    #expect(base.adultContentEnabled == expectedBase)
  }

  @Test("Removing the ceiling from the unchanged base restores only confirmed server permission", arguments: [
    (true, true, true),
    (false, true, false),
    (true, false, false),
    (false, false, false),
  ])
  func restorationUsesBase(serverAdult: Bool, confirmed: Bool, expectedAdult: Bool) throws {
    let base = try basePolicy(serverAdult: serverAdult, confirmed: confirmed)
    let restricted = base.restrictingMatureContent(true)

    let restored = base.restrictingMatureContent(false)

    #expect(restored == base)
    #expect(restored.adultContentEnabled == expectedAdult)
    #expect(restored.prefs.adultContentEnabled == expectedAdult)
    #expect(restored.isConfirmed == confirmed)
    // A clamped snapshot cannot invent the discarded server preference.
    #expect(restricted.restrictingMatureContent(false) == restricted)
    #expect(!restricted.adultContentEnabled)
  }

  @Test("Clamping preserves account identity, label choices, subscription order and custom definitions")
  func labelPolicySurvivesCeiling() throws {
    let base = try basePolicy()
    let before = base
    let restricted = base.restrictingMatureContent(true)

    #expect(base.prefs.labels["porn"] == .warn)
    #expect(base.prefs.labels["graphic-media"] == .hide)
    #expect(base.prefs.labelers.map(\.did) == [ModerationPrefs.blueskyModerationDID, Self.labelerB, Self.labelerA])
    #expect(base.prefs.labelers.first(where: { $0.did == Self.labelerA })?.labels["spoiler"] == .hide)
    #expect(base.prefs.labelers.first(where: { $0.did == Self.labelerB })?.labels["spoiler"] == .ignore)
    #expect(Set(base.labelDefinitions.keys) == [Self.labelerA, Self.labelerB])
    #expect(base.labelDefinitions[Self.labelerA]?.first?.identifier == "spoiler")
    #expect(base.labelDefinitions[Self.labelerA]?.first?.definedBy == Self.labelerA)

    #expect(restricted.accountDID == before.accountDID)
    #expect(restricted.isConfirmed == before.isConfirmed)
    #expect(restricted.prefs.labels == before.prefs.labels)
    #expect(restricted.prefs.labelers == before.prefs.labelers)
    #expect(restricted.labelDefinitions == before.labelDefinitions)
    #expect(base == before)

    let label = try ModerationFixtures.postLabel("spoiler", name: "alice", src: Self.labelerA)
    let post = try ModerationFixtures.post(author: ModerationFixtures.profile("alice"), labels: [label])
    expectModeration(base.decide(post: post), [.contentList: [.filter, .blur], .contentView: [.alert]], "base custom label")
    expectModeration(restricted.decide(post: post), [.contentList: [.filter, .blur], .contentView: [.alert]], "restricted custom label")
  }

  @Test("A porn warn preference cannot override the platform ceiling")
  func adultMediaRemainsLockedWhileRestricted() throws {
    let base = try basePolicy()
    let label = try ModerationFixtures.postLabel("porn", name: "alice", src: ModerationPrefs.blueskyModerationDID)
    let post = try ModerationFixtures.post(author: ModerationFixtures.profile("alice"), labels: [label])
    let restricted = base.restrictingMatureContent(true)

    expectModeration(base.decide(post: post), [.contentMedia: [.blur]], "base porn warn")
    expectModeration(restricted.decide(post: post), [.contentList: [.filter], .contentMedia: [.blur, .noOverride]], "restricted porn warn")
    #expect(restricted.listFilter(post: post))
    #expect(restricted.prefs.labels["porn"] == .warn)

    let restored = base.restrictingMatureContent(false)
    expectModeration(restored.decide(post: post), [.contentMedia: [.blur]], "restored porn warn")
    #expect(!restored.listFilter(post: post))
  }

  @Test("The coordinator's adult response restores only the unchanged confirmed base", arguments: [
    (true, true, true),
    (false, true, false),
    (true, false, false),
    (false, false, false),
  ])
  @MainActor
  func coordinatorAdultResultRespectsBase(serverAdult: Bool, confirmed: Bool, expectedAdult: Bool) async throws {
    let base = try basePolicy(serverAdult: serverAdult, confirmed: confirmed)
    let before = base
    let checker = AgeAccessControlledChecker()
    let access = PlatformAgeAccess(checker: checker)
    let joined = await ageAccessJoinedRefresh(access)
    await checker.waitForCalls(1)
    #expect(!base.restrictingMatureContent(access.restrictsMatureContent).adultContentEnabled)
    await checker.resolve(1, with: .init(requirement: .ageCheckRequired))
    await joined.value
    #expect(!base.restrictingMatureContent(access.restrictsMatureContent).adultContentEnabled)

    await access.request(using: { .adult }, isCurrent: { true })
    let effective = base.restrictingMatureContent(access.restrictsMatureContent)

    #expect(access.signal.ageBand == nil)
    #expect(access.allows(.generalContent))
    #expect(!access.restrictsMatureContent)
    #expect(effective == before)
    #expect(effective.adultContentEnabled == expectedAdult)
    #expect(effective.isConfirmed == confirmed)
    #expect(base == before)
  }

  @Test("An adult age decision cannot grant a server preference or session confirmation", arguments: [
    (true, true, true),
    (false, true, false),
    (true, false, false),
    (false, false, false),
  ])
  func adultDecisionDoesNotEnablePreferences(serverAdult: Bool, confirmed: Bool, expectedAdult: Bool) throws {
    let base = try basePolicy(serverAdult: serverAdult, confirmed: confirmed)
    let before = base
    let adultSignal = PlatformAgeSignal(requirement: .ageCheckRequired, ageBand: .adult)

    #expect(AgePolicy.decision(for: .platform(adultSignal), context: .ordinaryUse) == .allow)
    #expect(AgePolicy.decision(for: .platform(adultSignal), context: .matureContent) == .hideSensitiveContent)
    // This pure boundary test models removal of an extra ceiling. The coordinator's
    // consumption of the actual system result is qualified by its separate suite.
    let afterAdultDecision = base.restrictingMatureContent(false)

    #expect(afterAdultDecision == before)
    #expect(afterAdultDecision.adultContentEnabled == expectedAdult)
    #expect(afterAdultDecision.isConfirmed == confirmed)
    #expect(afterAdultDecision.prefs.labels == before.prefs.labels)
    #expect(afterAdultDecision.prefs.labelers == before.prefs.labelers)
    #expect(base == before)
  }
}
