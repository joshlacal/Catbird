import Foundation
import Testing

@testable import Catbird

// Port of the imperative-label scenarios of `moderation-behaviors.test.ts`:
// `!hide`, `!warn`, `!no-unauthenticated`, own-content behavior and the
// label-only merge cases.

private let blur: Set<ModerationTestFlag> = [.blur]

private let warnAccount: ModerationExpectation = [
  .profileList: blur, .profileView: blur, .avatar: blur, .banner: blur,
  .contentList: blur, .contentView: blur,
]
private let warnProfile: ModerationExpectation = [.avatar: blur, .banner: blur, .displayName: blur]
private let warnPost: ModerationExpectation = [.contentList: blur, .contentView: blur]
private let warnAuthorAccount: ModerationExpectation = [
  .avatar: blur, .banner: blur, .contentList: blur, .contentView: blur,
]

private func scenario(
  _ name: String,
  _ subject: BehaviorSubject,
  config: BehaviorConfig = .none,
  author: String = "alice",
  account: [String] = [],
  profile: [String] = [],
  post: [String] = [],
  expect expected: ModerationExpectation
) -> BehaviorScenario {
  BehaviorScenario(
    name: name, config: config, subject: subject, author: author, postLabels: post,
    profileLabels: profile, accountLabels: account, expected: expected)
}

private let imperativeScenarios: [BehaviorScenario] = [
  scenario("!hide on account", .profile, account: ["!hide"], expect: Expect.lockedAccount),
  scenario("!hide on profile", .profile, profile: ["!hide"], expect: Expect.lockedProfile),
  scenario("!hide on post", .post, post: ["!hide"], expect: Expect.lockedPost),
  scenario("!hide on author profile", .post, profile: ["!hide"], expect: Expect.lockedProfile),
  scenario("!hide on author account", .post, account: ["!hide"], expect: Expect.lockedAuthorAccount),

  scenario("!warn on account", .profile, account: ["!warn"], expect: warnAccount),
  scenario("!warn on profile", .profile, profile: ["!warn"], expect: warnProfile),
  scenario("!warn on post", .post, post: ["!warn"], expect: warnPost),
  scenario("!warn on author profile", .post, profile: ["!warn"], expect: warnProfile),
  scenario("!warn on author account", .post, account: ["!warn"], expect: warnAuthorAccount),
]

private let loggedOutScenarios: [BehaviorScenario] = [
  scenario("!no-unauthenticated on account, logged out", .profile, config: .loggedOut, account: ["!no-unauthenticated"], expect: Expect.lockedAccount),
  // The profile-record label counts as an account label too, so it also filters.
  scenario("!no-unauthenticated on profile, logged out", .profile, config: .loggedOut, profile: ["!no-unauthenticated"], expect: Expect.lockedAccount),
  scenario("!no-unauthenticated on post, logged out", .post, config: .loggedOut, post: ["!no-unauthenticated"], expect: Expect.lockedPost),
  scenario("!no-unauthenticated on author profile, logged out", .post, config: .loggedOut, profile: ["!no-unauthenticated"], expect: Expect.lockedAuthorAccount),
  scenario("!no-unauthenticated on author account, logged out", .post, config: .loggedOut, account: ["!no-unauthenticated"], expect: Expect.lockedAuthorAccount),
]

private let loggedInScenarios: [BehaviorScenario] = [
  scenario("!no-unauthenticated on account, logged in", .profile, account: ["!no-unauthenticated"], expect: [:]),
  scenario("!no-unauthenticated on profile, logged in", .profile, profile: ["!no-unauthenticated"], expect: [:]),
  scenario("!no-unauthenticated on post, logged in", .post, post: ["!no-unauthenticated"], expect: [:]),
  scenario("!no-unauthenticated on author profile, logged in", .post, profile: ["!no-unauthenticated"], expect: [:]),
  scenario("!no-unauthenticated on author account, logged in", .post, account: ["!no-unauthenticated"], expect: [:]),
]

/// The signed-in user's own content (`self`): nothing filters, nothing locks.
private let ownContentScenarios: [BehaviorScenario] = [
  scenario("self profile: !hide on account", .profile, author: "self", account: ["!hide"], expect: [
    .avatar: blur, .banner: blur, .displayName: blur, .profileList: blur, .profileView: blur,
    .contentList: blur, .contentView: blur,
  ]),
  scenario("self profile: !hide on profile", .profile, author: "self", profile: ["!hide"], expect: [
    .avatar: blur, .banner: blur, .displayName: blur,
  ]),
  scenario("self post: !hide on post", .post, author: "self", post: ["!hide"], expect: [
    .contentView: blur, .contentList: blur,
  ]),
  scenario("self post: !hide on author profile", .post, author: "self", profile: ["!hide"], expect: [
    .avatar: blur, .banner: blur, .displayName: blur,
  ]),
  scenario("self post: !hide on author account", .post, author: "self", account: ["!hide"], expect: [
    .avatar: blur, .banner: blur, .displayName: blur, .contentList: blur, .contentView: blur,
  ]),
  scenario("self post: !warn on post", .post, author: "self", post: ["!warn"], expect: warnPost),
  scenario("self post: !warn on author profile", .post, author: "self", profile: ["!warn"], expect: warnProfile),
  scenario("self post: !warn on author account", .post, author: "self", account: ["!warn"], expect: warnAuthorAccount),
]

private let porn: ModerationExpectation = [
  .profileList: [.filter], .avatar: blur, .banner: blur, .contentList: [.filter],
]

/// Label-only merge cases: the strongest cause decides, per context.
private let mergingScenarios: [BehaviorScenario] = [
  scenario("!hide and porn on account (hide)", .profile, config: .adultOn("porn", .hide), account: ["!hide", "porn"], expect: Expect.lockedAccount),
  scenario("!warn and porn on account (hide)", .profile, config: .adultOn("porn", .hide), account: ["!warn", "porn"], expect: [
    .profileList: [.filter, .blur], .profileView: blur, .avatar: blur, .banner: blur,
    .contentList: [.filter, .blur], .contentView: blur,
  ]),
  scenario("!hide on account, !warn on profile", .profile, account: ["!hide"], profile: ["!warn"], expect: Expect.lockedAccount),
  scenario("!warn on account, !hide on profile", .profile, account: ["!warn"], profile: ["!hide"], expect: [
    .profileList: blur, .profileView: blur, .avatar: [.blur, .noOverride], .banner: [.blur, .noOverride],
    .displayName: [.blur, .noOverride], .contentList: blur, .contentView: blur,
  ]),
  scenario("!hide and porn on post (hide)", .post, config: .adultOn("porn", .hide), post: ["!hide", "porn"], expect: [
    .contentList: [.filter, .blur, .noOverride], .contentView: [.blur, .noOverride], .contentMedia: blur,
  ]),
  scenario("!warn and porn on post (hide)", .post, config: .adultOn("porn", .hide), post: ["!warn", "porn"], expect: [
    .contentList: [.filter, .blur], .contentView: blur, .contentMedia: blur,
  ]),
]

@Suite("Moderation: imperative labels")
struct ModerationImperativeLabelTests {
  @Test("!hide and !warn", arguments: imperativeScenarios)
  func hideAndWarn(_ scenario: BehaviorScenario) throws {
    try ModerationScenarioRunner.check(scenario)
  }

  @Test("!no-unauthenticated when logged out", arguments: loggedOutScenarios)
  func noUnauthenticatedLoggedOut(_ scenario: BehaviorScenario) throws {
    try ModerationScenarioRunner.check(scenario)
  }

  @Test("!no-unauthenticated when logged in is a no-op", arguments: loggedInScenarios)
  func noUnauthenticatedLoggedIn(_ scenario: BehaviorScenario) throws {
    try ModerationScenarioRunner.check(scenario)
  }

  @Test("Own content never filters and never locks", arguments: ownContentScenarios)
  func ownContent(_ scenario: BehaviorScenario) throws {
    try ModerationScenarioRunner.check(scenario)
  }

  @Test("Merging labels on one subject", arguments: mergingScenarios)
  func merging(_ scenario: BehaviorScenario) throws {
    try ModerationScenarioRunner.check(scenario)
  }

  @Test("A nil or empty user DID counts as logged out; any other DID counts as signed in")
  func missingUserDIDIsLoggedOut() throws {
    let author = try ModerationFixtures.profile("alice", labels: [try ModerationFixtures.accountLabel("!no-unauthenticated", name: "alice")])
    let prefs = ModerationPrefs(adultContentEnabled: false, labels: [:], labelers: [LabelerModerationPrefs(did: ModerationFixtures.labelerDID)])
    for userDID in [nil, ""] as [String?] {
      let options = ModerationOptions(userDID: userDID, prefs: prefs)
      #expect(!options.isAuthenticated)
      #expect(ModerationSubjects.decideProfileSubject(author, options: options).ui(.profileList).filter)
    }
    let signedIn = ModerationFixtures.options()
    #expect(signedIn.isAuthenticated)
    #expect(!ModerationSubjects.decideProfileSubject(author, options: signedIn).ui(.profileList).filter)
  }
}
