import Foundation
import Petrel
import Testing

@testable import Catbird

// Table-driven scenario support, a port of `ModerationBehaviorSuiteRunner`
// (atproto/packages/api/tests/util/moderation-behavior.ts) restricted to
// label causes.

/// A named user configuration (`SuiteConfigurations` upstream).
struct BehaviorConfig: Sendable {
  var authed = true
  var adult = false
  var settings: [String: LabelPreference] = [:]

  static let none = BehaviorConfig()
  static let adultDisabled = BehaviorConfig(adult: false)
  static let loggedOut = BehaviorConfig(authed: false)

  static func adultOn(_ value: String, _ preference: LabelPreference) -> BehaviorConfig {
    BehaviorConfig(adult: true, settings: [value: preference])
  }

  static func setting(_ value: String, _ preference: LabelPreference) -> BehaviorConfig {
    BehaviorConfig(settings: [value: preference])
  }
}

enum BehaviorSubject: Sendable {
  case post
  case profile
}

/// One row of an upstream `SCENARIOS` table.
struct BehaviorScenario: Sendable, CustomTestStringConvertible {
  var name: String
  var config: BehaviorConfig = .none
  var subject: BehaviorSubject
  var author = "alice"
  /// Labels on the post, the author's profile record, and the author's account.
  var postLabels: [String] = []
  var profileLabels: [String] = []
  var accountLabels: [String] = []
  var expected: ModerationExpectation

  var testDescription: String { name }

  /// Upstream only checks profile contexts for profile subjects.
  var contexts: [ModerationContext] {
    switch subject {
    case .profile: ModerationContext.allCases
    case .post: ModerationContext.allCases.filter { $0 != .profileList && $0 != .profileView }
    }
  }
}

enum ModerationScenarioRunner {
  static func decision(for scenario: BehaviorScenario) throws -> ModerationDecision {
    let options = ModerationFixtures.options(
      authed: scenario.config.authed, adult: scenario.config.adult, settings: scenario.config.settings)

    var authorLabels: [ComAtprotoLabelDefs.Label] = []
    for value in scenario.accountLabels {
      authorLabels.append(try ModerationFixtures.accountLabel(value, name: scenario.author))
    }
    for value in scenario.profileLabels {
      authorLabels.append(try ModerationFixtures.profileLabel(value, name: scenario.author))
    }
    let author = try ModerationFixtures.profile(scenario.author, labels: authorLabels)

    switch scenario.subject {
    case .profile:
      return ModerationSubjects.decideProfileSubject(author, options: options)
    case .post:
      let labels = try scenario.postLabels.map {
        try ModerationFixtures.postLabel($0, name: scenario.author)
      }
      return ModerationSubjects.decidePost(try ModerationFixtures.post(author: author, labels: labels), options: options)
    }
  }

  static func check(_ scenario: BehaviorScenario) throws {
    let result = try decision(for: scenario)
    expectModeration(result, scenario.expected, contexts: scenario.contexts, scenario.name)
  }
}

// MARK: - Shorthand for expectation tables

private let blurOnly: Set<ModerationTestFlag> = [.blur]
private let lockedBlur: Set<ModerationTestFlag> = [.blur, .noOverride]
private let filteredLockedBlur: Set<ModerationTestFlag> = [.filter, .blur, .noOverride]

/// Expectation tables that repeat across scenarios.
enum Expect {
  /// `!hide` / `!no-unauthenticated` on the account.
  static let lockedAccount: ModerationExpectation = [
    .profileList: filteredLockedBlur, .profileView: lockedBlur, .avatar: lockedBlur,
    .banner: lockedBlur, .displayName: lockedBlur, .contentList: filteredLockedBlur,
    .contentView: lockedBlur,
  ]

  /// `!hide` / `!no-unauthenticated` on the profile record.
  static let lockedProfile: ModerationExpectation = [
    .avatar: lockedBlur, .banner: lockedBlur, .displayName: lockedBlur,
  ]

  /// `!hide` / `!no-unauthenticated` on a post.
  static let lockedPost: ModerationExpectation = [
    .contentList: filteredLockedBlur, .contentView: lockedBlur,
  ]

  /// `!hide` / `!no-unauthenticated` on a post author's account.
  static let lockedAuthorAccount: ModerationExpectation = [
    .avatar: lockedBlur, .banner: lockedBlur, .displayName: lockedBlur,
    .contentList: filteredLockedBlur, .contentView: lockedBlur,
  ]

  /// A media label that hides, on the account.
  static let hiddenMediaAccount: ModerationExpectation = [
    .profileList: [.filter], .avatar: blurOnly, .banner: blurOnly, .contentList: [.filter],
  ]

  static let mediaAvatarAndBanner: ModerationExpectation = [.avatar: blurOnly, .banner: blurOnly]

  static let lockedMediaAvatarAndBanner: ModerationExpectation = [.avatar: lockedBlur, .banner: lockedBlur]
}
