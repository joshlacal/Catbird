import Foundation
import Testing

@testable import Catbird

// Media labels (`porn`, `sexual`, `graphic-media`, `nudity`): the upstream
// `porn` scenarios, repeated for every adult label, plus nudity (the one
// non-adult media label) and the builtin default settings.

private let blur: Set<ModerationTestFlag> = [.blur]
private let filter: Set<ModerationTestFlag> = [.filter]

private enum Where: String, CaseIterable, Sendable {
  case account = "account"
  case profile = "profile"
  case post = "post"
  case authorProfile = "author profile"
  case authorAccount = "author account"

  var subject: BehaviorSubject {
    switch self {
    case .account, .profile: .profile
    case .post, .authorProfile, .authorAccount: .post
    }
  }
}

/// Expected results for a media label, keyed by where the label sits.
private struct MediaOutcome {
  var account: ModerationExpectation
  var profile: ModerationExpectation
  var post: ModerationExpectation
  var authorProfile: ModerationExpectation
  var authorAccount: ModerationExpectation

  func expectation(_ place: Where) -> ModerationExpectation {
    switch place {
    case .account: account
    case .profile: profile
    case .post: post
    case .authorProfile: authorProfile
    case .authorAccount: authorAccount
    }
  }

  /// The label hides content (setting `hide`, or forced by disabled adult content).
  static let hide = MediaOutcome(
    account: Expect.hiddenMediaAccount,
    profile: Expect.mediaAvatarAndBanner,
    post: [.contentList: filter, .contentMedia: blur],
    authorProfile: Expect.mediaAvatarAndBanner,
    authorAccount: Expect.hiddenMediaAccount)

  /// The label warns: media blurs, nothing is removed from lists.
  static let warn = MediaOutcome(
    account: Expect.mediaAvatarAndBanner,
    profile: Expect.mediaAvatarAndBanner,
    post: [.contentMedia: blur],
    authorProfile: Expect.mediaAvatarAndBanner,
    authorAccount: Expect.mediaAvatarAndBanner)

  static let ignore = MediaOutcome(account: [:], profile: [:], post: [:], authorProfile: [:], authorAccount: [:])

  /// Adult content disabled: hides, and the blur cannot be revealed.
  static let adultDisabled = MediaOutcome(
    account: [
      .profileList: filter, .avatar: [.blur, .noOverride], .banner: [.blur, .noOverride], .contentList: filter,
    ],
    profile: Expect.lockedMediaAvatarAndBanner,
    post: [.contentList: filter, .contentMedia: [.blur, .noOverride]],
    authorProfile: Expect.lockedMediaAvatarAndBanner,
    authorAccount: [.avatar: [.blur, .noOverride], .banner: [.blur, .noOverride], .contentList: filter])
}

private func scenarios(_ value: String, _ setting: String, config: BehaviorConfig, outcome: MediaOutcome) -> [BehaviorScenario] {
  Where.allCases.map { place in
    BehaviorScenario(
      name: "\(value) on \(place.rawValue) (\(setting))", config: config, subject: place.subject,
      postLabels: place == .post ? [value] : [],
      profileLabels: place == .profile || place == .authorProfile ? [value] : [],
      accountLabels: place == .account || place == .authorAccount ? [value] : [],
      expected: outcome.expectation(place))
  }
}

private let adultLabelValues = ["porn", "sexual", "graphic-media"]

private let adultLabelScenarios: [BehaviorScenario] = adultLabelValues.flatMap { value in
  scenarios(value, "hide", config: .adultOn(value, .hide), outcome: .hide)
    + scenarios(value, "warn", config: .adultOn(value, .warn), outcome: .warn)
    + scenarios(value, "ignore", config: .adultOn(value, .ignore), outcome: .ignore)
    + scenarios(value, "adult disabled", config: .adultDisabled, outcome: .adultDisabled)
}

/// Adult content off overrides even an explicit "ignore" for adult labels.
private let adultDisabledOverrideScenarios: [BehaviorScenario] = adultLabelValues.flatMap { value in
  scenarios(value, "adult disabled, ignore set", config: BehaviorConfig(adult: false, settings: [value: .ignore]), outcome: .adultDisabled)
}

private let nudityScenarios: [BehaviorScenario] =
  scenarios("nudity", "hide", config: .setting("nudity", .hide), outcome: .hide)
  + scenarios("nudity", "warn", config: .setting("nudity", .warn), outcome: .warn)
  + scenarios("nudity", "ignore", config: .setting("nudity", .ignore), outcome: .ignore)
  + scenarios("nudity", "hide, adult disabled", config: BehaviorConfig(adult: false, settings: ["nudity": .hide]), outcome: .hide)
  + scenarios("nudity", "no setting, adult disabled", config: .adultDisabled, outcome: .ignore)

@Suite("Moderation: media labels")
struct ModerationMediaLabelTests {
  @Test("Adult media labels follow the user's setting and the adult switch", arguments: adultLabelScenarios)
  func adultLabels(_ scenario: BehaviorScenario) throws {
    try ModerationScenarioRunner.check(scenario)
  }

  @Test("Disabled adult content overrides an explicit ignore", arguments: adultDisabledOverrideScenarios)
  func adultDisabledOverridesIgnore(_ scenario: BehaviorScenario) throws {
    try ModerationScenarioRunner.check(scenario)
  }

  @Test("Nudity is not adult-gated", arguments: nudityScenarios)
  func nudity(_ scenario: BehaviorScenario) throws {
    try ModerationScenarioRunner.check(scenario)
  }

  @Test("A media label on a text-only post never blurs the post text", arguments: adultLabelValues + ["nudity"])
  func mediaLabelsNeverBlurPostText(_ value: String) throws {
    let options = ModerationFixtures.options(adult: true, settings: [value: .hide])
    let author = try ModerationFixtures.profile("alice")
    let post = try ModerationFixtures.post(author: author, labels: [try ModerationFixtures.postLabel(value, name: "alice")])
    let decision = ModerationSubjects.decidePost(post, options: options)

    #expect(!decision.ui(.contentList).blur)
    #expect(!decision.ui(.contentView).blur)
    #expect(decision.ui(.contentMedia).blur)
    #expect(decision.ui(.contentList).filter, "hide removes the post from lists")
  }

  @Test("A self-applied porn label on a profile follows the global preference (moderation.test.ts)", arguments: [
    LabelPreference.hide, .warn, .ignore,
  ])
  func selfLabelOnProfile(_ preference: LabelPreference) throws {
    // No labelers at all: the author's own label is trusted without a subscription.
    let options = ModerationOptions(
      userDID: "did:web:alice.test",
      prefs: ModerationPrefs(adultContentEnabled: true, labels: ["porn": preference], labelers: []))
    let label = try ModerationFixtures.profileLabel("porn", name: "bob", src: "did:web:bob.test")
    let decision = ModerationSubjects.decideProfileSubject(
      try ModerationFixtures.profile("bob", labels: [label]), options: options)

    let expected: ModerationExpectation = preference == .ignore ? [:] : Expect.mediaAvatarAndBanner
    expectModeration(decision, expected, "self porn on profile, \(preference.rawValue)")
    if preference == .ignore {
      #expect(decision.causes.isEmpty)
    } else {
      #expect(decision.causes.first?.source == .user)
    }
  }

  @Test("Seeded builtin defaults with adult content on")
  func builtinDefaultsAdultOn() throws {
    let prefs = ModerationPrefs(adultContentEnabled: true, contentLabelPrefs: [], labelerDIDs: [])
    let options = ModerationOptions(userDID: ModerationFixtures.selfDID, prefs: prefs)
    let src = ModerationPrefs.blueskyModerationDID
    let author = try ModerationFixtures.profile("alice")

    func decide(_ value: String) throws -> ModerationDecision {
      let label = try ModerationFixtures.postLabel(value, name: "alice", src: src)
      return ModerationSubjects.decidePost(try ModerationFixtures.post(author: author, labels: [label]), options: options)
    }

    // porn defaults to hide: removed from lists, media blurred.
    expectModeration(try decide("porn"), [.contentList: filter, .contentMedia: blur], "porn default")
    // sexual and graphic-media default to warn: media blurred only.
    expectModeration(try decide("sexual"), [.contentMedia: blur], "sexual default")
    expectModeration(try decide("graphic-media"), [.contentMedia: blur], "graphic-media default")
    // The deprecated alias is a builtin with the same defaults as graphic-media.
    expectModeration(try decide("gore"), [.contentMedia: blur], "gore default")
    // nudity defaults to ignore.
    expectModeration(try decide("nudity"), [:], "nudity default")
  }

  @Test("Seeded builtin defaults with adult content off hide every adult label and lock the blur")
  func builtinDefaultsAdultOff() throws {
    let prefs = ModerationPrefs(adultContentEnabled: false, contentLabelPrefs: [], labelerDIDs: [])
    let options = ModerationOptions(userDID: ModerationFixtures.selfDID, prefs: prefs)
    let author = try ModerationFixtures.profile("alice")
    for value in adultLabelValues {
      let label = try ModerationFixtures.postLabel(value, name: "alice", src: ModerationPrefs.blueskyModerationDID)
      let decision = ModerationSubjects.decidePost(try ModerationFixtures.post(author: author, labels: [label]), options: options)
      expectModeration(decision, [.contentList: filter, .contentMedia: [.blur, .noOverride]], "\(value) with adult off")
    }
  }

  @Test("The deprecated gore label is a builtin of its own and is read through the gore preference key")
  func goreHasItsOwnPreferenceKey() throws {
    let author = try ModerationFixtures.profile("alice")

    func decision(_ stored: [(label: String, visibility: String)], labelValue: String = "gore") throws -> ModerationDecision {
      let contentPrefs = stored.map { ContentLabelPreference(labelerDid: nil, label: $0.label, visibility: $0.visibility) }
      let prefs = ModerationPrefs(adultContentEnabled: true, contentLabelPrefs: contentPrefs, labelerDIDs: [])
      let options = ModerationOptions(userDID: ModerationFixtures.selfDID, prefs: prefs)
      let label = try ModerationFixtures.postLabel(labelValue, name: "alice", src: ModerationPrefs.blueskyModerationDID)
      return ModerationSubjects.decidePost(try ModerationFixtures.post(author: author, labels: [label]), options: options)
    }

    let unset = try decision([])
    #expect(unset.causes.first?.definition.identifier == "gore")

    // A graphic-media preference does not reach the gore value.
    expectModeration(try decision([("graphic-media", "hide")]), [.contentMedia: blur], "gore, graphic-media=hide")
    expectModeration(try decision([("graphic-media", "ignore")]), [.contentMedia: blur], "gore, graphic-media=ignore")
    // A gore preference does.
    expectModeration(try decision([("gore", "hide")]), [.contentList: filter, .contentMedia: blur], "gore, gore=hide")
    expectModeration(try decision([("gore", "ignore")]), [:], "gore, gore=ignore")
    // The legacy gore preference also sets graphic-media, as the SDK does on read.
    expectModeration(
      try decision([("gore", "hide")], labelValue: "graphic-media"), [.contentList: filter, .contentMedia: blur],
      "graphic-media, gore=hide")
  }
}
