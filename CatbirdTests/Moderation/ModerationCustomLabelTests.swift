import Foundation
import Petrel
import Testing

@testable import Catbird

// Port of `moderation-custom-labels.test.ts`: a labeler-defined label
// ("custom", user setting `hide`) across every blurs x severity combination,
// attached to a post, a profile record, and an account.

enum CustomLabelTarget: String, Sendable, CaseIterable {
  case post
  case profile
  case account
}

struct CustomLabelScenario: Sendable, CustomTestStringConvertible {
  let blurs: String
  let severity: String
  let target: CustomLabelTarget
  let expected: ModerationExpectation

  var testDescription: String { "blurs=\(blurs), severity=\(severity), target=\(target.rawValue)" }
}

private struct CustomRow {
  let blurs: String
  let severity: String
  let account: ModerationExpectation
  let profile: ModerationExpectation
  let post: ModerationExpectation
}

private let alert: Set<ModerationTestFlag> = [.alert]
private let inform: Set<ModerationTestFlag> = [.inform]
private let filter: Set<ModerationTestFlag> = [.filter]
private let blur: Set<ModerationTestFlag> = [.blur]
private let filterBlur: Set<ModerationTestFlag> = [.filter, .blur]
private let filterAlert: Set<ModerationTestFlag> = [.filter, .alert]
private let filterInform: Set<ModerationTestFlag> = [.filter, .inform]

private let customRows: [CustomRow] = [
  CustomRow(
    blurs: "content", severity: "alert",
    account: [.profileList: filterAlert, .profileView: alert, .contentList: filterBlur, .contentView: alert],
    profile: [.profileList: alert, .profileView: alert],
    post: [.contentList: filterBlur, .contentView: alert]),
  CustomRow(
    blurs: "content", severity: "inform",
    account: [.profileList: filterInform, .profileView: inform, .contentList: filterBlur, .contentView: inform],
    profile: [.profileList: inform, .profileView: inform],
    post: [.contentList: filterBlur, .contentView: inform]),
  CustomRow(
    blurs: "content", severity: "none",
    account: [.profileList: filter, .contentList: filterBlur],
    profile: [:],
    post: [.contentList: filterBlur]),
  CustomRow(
    blurs: "media", severity: "alert",
    account: [.profileList: filterAlert, .profileView: alert, .avatar: blur, .banner: blur, .contentList: filter],
    profile: [.profileList: alert, .profileView: alert, .avatar: blur, .banner: blur],
    post: [.contentList: filter, .contentMedia: blur]),
  CustomRow(
    blurs: "media", severity: "inform",
    account: [.profileList: filterInform, .profileView: inform, .avatar: blur, .banner: blur, .contentList: filter],
    profile: [.profileList: inform, .profileView: inform, .avatar: blur, .banner: blur],
    post: [.contentList: filter, .contentMedia: blur]),
  CustomRow(
    blurs: "media", severity: "none",
    account: [.profileList: filter, .avatar: blur, .banner: blur, .contentList: filter],
    profile: [.avatar: blur, .banner: blur],
    post: [.contentList: filter, .contentMedia: blur]),
  CustomRow(
    blurs: "none", severity: "alert",
    account: [.profileList: filterAlert, .profileView: alert, .contentList: filterAlert, .contentView: alert],
    profile: [.profileList: alert, .profileView: alert],
    post: [.contentList: filterAlert, .contentView: alert]),
  CustomRow(
    blurs: "none", severity: "inform",
    account: [.profileList: filterInform, .profileView: inform, .contentList: filterInform, .contentView: inform],
    profile: [.profileList: inform, .profileView: inform],
    post: [.contentList: filterInform, .contentView: inform]),
  CustomRow(
    blurs: "none", severity: "none",
    account: [.profileList: filter, .contentList: filter],
    profile: [:],
    post: [.contentList: filter]),
]

private let customScenarios: [CustomLabelScenario] = customRows.flatMap { row in
  [
    CustomLabelScenario(blurs: row.blurs, severity: row.severity, target: .post, expected: row.post),
    CustomLabelScenario(blurs: row.blurs, severity: row.severity, target: .profile, expected: row.profile),
    CustomLabelScenario(blurs: row.blurs, severity: row.severity, target: .account, expected: row.account),
  ]
}

/// One row of the upstream "Custom labels can set the default setting" test.
struct DefaultSettingScenario: Sendable, CustomTestStringConvertible {
  let value: String
  let expected: ModerationExpectation

  var testDescription: String { value }
}

private let defaultSettingScenarios: [DefaultSettingScenario] = [
  DefaultSettingScenario(value: "default-hide", expected: [.contentList: filterBlur, .contentView: inform]),
  DefaultSettingScenario(value: "default-warn", expected: [.contentList: blur, .contentView: inform]),
  DefaultSettingScenario(value: "default-ignore", expected: [:]),
]

/// An adult-only definition whose declared behavior blurs nothing (or is unknown).
struct AdultOnlyScenario: Sendable, CustomTestStringConvertible {
  let blurs: String
  let severity: String
  let adultOff: ModerationExpectation

  var testDescription: String { "blurs=\(blurs), severity=\(severity)" }
}

private let adultOnlyScenarios: [AdultOnlyScenario] = [
  AdultOnlyScenario(blurs: "none", severity: "none", adultOff: [.contentList: filter]),
  AdultOnlyScenario(blurs: "none", severity: "alert", adultOff: [.contentList: filterAlert, .contentView: alert]),
  AdultOnlyScenario(blurs: "sparkle", severity: "alert", adultOff: [.contentList: filter]),
]

@Suite("Moderation: custom labels")
struct ModerationCustomLabelTests {
  @Test("Labeler-defined label behaviors", arguments: customScenarios)
  func customLabel(_ scenario: CustomLabelScenario) throws {
    let src = ModerationFixtures.customLabelerDID
    let options = ModerationFixtures.customOptions(blurs: scenario.blurs, severity: scenario.severity)

    let decision: ModerationDecision
    switch scenario.target {
    case .post:
      let label = try ModerationFixtures.postLabel("custom", name: "bob", src: src)
      decision = ModerationSubjects.decidePost(
        try ModerationFixtures.post(author: try ModerationFixtures.profile("bob"), labels: [label]), options: options)
    case .profile:
      let label = try ModerationFixtures.profileLabel("custom", name: "bob", src: src)
      decision = ModerationSubjects.decideProfileSubject(try ModerationFixtures.profile("bob", labels: [label]), options: options)
    case .account:
      let label = try ModerationFixtures.accountLabel("custom", name: "bob", src: src)
      decision = ModerationSubjects.decideProfileSubject(try ModerationFixtures.profile("bob", labels: [label]), options: options)
    }
    expectModeration(decision, scenario.expected, scenario.testDescription)
  }

  @Test("adultOnly custom labels blur content in the thread view and lock while adult content is off")
  func adultOnlyContentLabel() throws {
    let definition = try #require(
      ModerationFixtures.customDefinition(blurs: "content", severity: "none", adultOnly: true))
    #expect(definition.flags == [.noSelf, .adult])
    #expect(definition.behaviors[.content]?[.contentView] == .blur)

    let src = ModerationFixtures.customLabelerDID
    let label = try ModerationFixtures.postLabel("custom", name: "bob", src: src)
    let post = try ModerationFixtures.post(author: try ModerationFixtures.profile("bob"), labels: [label])
    let labelers = [LabelerModerationPrefs(did: src, labels: ["custom": .warn])]

    // Adult content on: the user's "warn" applies and can be revealed.
    let on = ModerationFixtures.options(adult: true, labelers: labelers, definitions: [src: [definition]])
    let warned = ModerationSubjects.decidePost(post, options: on)
    expectModeration(warned, [.contentList: blur, .contentView: blur], "adultOnly with adult on")

    // Adult content off: forced hide, and the blur has no reveal.
    let off = ModerationFixtures.options(adult: false, labelers: labelers, definitions: [src: [definition]])
    let hidden = ModerationSubjects.decidePost(post, options: off)
    expectModeration(
      hidden, [.contentList: [.filter, .blur, .noOverride], .contentView: [.blur, .noOverride]], "adultOnly with adult off")
  }

  @Test("defaultSetting applies when the user set nothing; only explicit hide or ignore override warn")
  func definitionDefaultSetting() throws {
    func setting(_ raw: String?) throws -> LabelPreference {
      try #require(ModerationFixtures.customDefinition(blurs: "content", severity: "alert", defaultSetting: raw)).defaultSetting
    }
    #expect(try setting("hide") == .hide)
    #expect(try setting("ignore") == .ignore)
    #expect(try setting("warn") == .warn)
    #expect(try setting(nil) == .warn)
    #expect(try setting("show") == .warn)
    #expect(try setting("anything") == .warn)

    // With no stored preference the definition default decides.
    let src = ModerationFixtures.customLabelerDID
    let definition = try #require(ModerationFixtures.customDefinition(blurs: "content", severity: "alert", defaultSetting: "hide"))
    let options = ModerationFixtures.options(
      labelers: [LabelerModerationPrefs(did: src)], definitions: [src: [definition]])
    let label = try ModerationFixtures.postLabel("custom", name: "bob", src: src)
    let post = try ModerationFixtures.post(author: try ModerationFixtures.profile("bob"), labels: [label])
    #expect(ModerationSubjects.decidePost(post, options: options).ui(.contentList).filter)
  }

  @Test("Custom labels can set the default setting (moderation.test.ts)", arguments: defaultSettingScenarios)
  func definitionDefaultSettingThroughUI(_ scenario: DefaultSettingScenario) throws {
    let src = ModerationFixtures.customLabelerDID
    let definitions = try [("default-hide", "hide"), ("default-warn", "warn"), ("default-ignore", "ignore")].map {
      try #require(
        ModerationFixtures.customDefinition($0.0, blurs: "content", severity: "inform", defaultSetting: $0.1))
    }
    let options = ModerationFixtures.options(
      adult: true, labelers: [LabelerModerationPrefs(did: src)], definitions: [src: definitions])

    let label = try ModerationFixtures.postLabel(scenario.value, name: "bob", src: src)
    let post = try ModerationFixtures.post(author: try ModerationFixtures.profile("bob"), labels: [label])
    expectModeration(ModerationSubjects.decidePost(post, options: options), scenario.expected, scenario.value)
  }

  @Test("Labels with an invalid value name are ignored, even if a definition for them was smuggled in")
  func invalidLabelValueNames() throws {
    let src = ModerationFixtures.customLabelerDID
    func forged(_ identifier: String) -> ModerationLabelDefinition {
      // `interpret` refuses these identifiers, so build what it would not.
      ModerationLabelDefinition(
        identifier: identifier, configurable: true, defaultSetting: .warn, flags: [.noSelf], blurs: .content,
        severity: .inform, behaviors: [.content: [.contentList: .blur, .contentView: .inform]], definedBy: src,
        locales: [])
    }
    let options = ModerationFixtures.options(
      adult: true,
      labelers: [LabelerModerationPrefs(did: src, labels: ["BadLabel": .hide, "bad/label": .hide, "good-label": .hide])],
      definitions: [src: [forged("BadLabel"), forged("bad/label"), forged("good-label")]])

    let invalid = try ["BadLabel", "bad/label"].map { try ModerationFixtures.postLabel($0, name: "bob", src: src) }
    let post = try ModerationFixtures.post(author: try ModerationFixtures.profile("bob"), labels: invalid)
    let decision = ModerationSubjects.decidePost(post, options: options)
    #expect(decision.causes.isEmpty)
    expectModeration(decision, [:], "invalid label value names")

    // Control: the same definition under a valid name does apply, so the name is the reason.
    let valid = try ModerationFixtures.postLabel("good-label", name: "bob", src: src)
    let validPost = try ModerationFixtures.post(author: try ModerationFixtures.profile("bob"), labels: [valid])
    expectModeration(
      ModerationSubjects.decidePost(validPost, options: options), [.contentList: filterBlur, .contentView: inform],
      "valid label value name")
  }

  @Test(
    "Parity with the SDK: an adult-only definition that declares no blur is removed from lists while adult content is off, and adds no cover",
    arguments: adultOnlyScenarios)
  func adultOnlyDefinitionWithoutBlur(_ scenario: AdultOnlyScenario) throws {
    let src = ModerationFixtures.customLabelerDID
    let definition = try #require(
      ModerationFixtures.customDefinition(blurs: scenario.blurs, severity: scenario.severity, adultOnly: true))
    #expect(definition.flags.contains(.adult))
    let labelers = [LabelerModerationPrefs(did: src, labels: ["custom": .warn])]
    let label = try ModerationFixtures.postLabel("custom", name: "bob", src: src)
    let post = try ModerationFixtures.post(author: try ModerationFixtures.profile("bob"), labels: [label])

    let off = ModerationFixtures.options(adult: false, labelers: labelers, definitions: [src: [definition]])
    let hidden = ModerationSubjects.decidePost(post, options: off)
    #expect(hidden.causes.first?.setting == .hide, "adult content off forces hide")
    #expect(hidden.causes.first?.noOverride == true)
    expectModeration(hidden, scenario.adultOff, "adult-only, adult content off, \(scenario.testDescription)")

    // With adult content on the user's warn applies and nothing is filtered.
    let on = ModerationFixtures.options(adult: true, labelers: labelers, definitions: [src: [definition]])
    #expect(!ModerationSubjects.decidePost(post, options: on).ui(.contentList).filter)
  }
}
