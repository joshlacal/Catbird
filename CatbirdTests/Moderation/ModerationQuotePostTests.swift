import Foundation
import Petrel
import Testing

@testable import Catbird

// Port of the label parts of `moderation-quoteposts.test.ts`. Labels on a
// quoted post (or its author) are downgraded on the parent: they can still
// filter it out of lists, but they never blur, alert or inform on the parent.

struct QuoteLabelScenario: Sendable, CustomTestStringConvertible {
  let blurs: String
  let severity: String
  let target: CustomLabelTarget

  var testDescription: String { "quoted label blurs=\(blurs), severity=\(severity), target=\(target.rawValue)" }

  /// Every combination expects only filters, never blurs, alerts or informs.
  var expected: ModerationExpectation {
    switch target {
    case .account: [.profileList: [.filter], .contentList: [.filter]]
    case .profile: [:]
    case .post: [.contentList: [.filter]]
    }
  }
}

private let quoteScenarios: [QuoteLabelScenario] = ["content", "media", "none"].flatMap { blurs in
  ["alert", "inform", "none"].flatMap { severity in
    CustomLabelTarget.allCases.map { QuoteLabelScenario(blurs: blurs, severity: severity, target: $0) }
  }
}

@Suite("Moderation: quote posts")
struct ModerationQuotePostTests {
  private let src = ModerationFixtures.customLabelerDID

  private func parentPost(
    quotedLabels: [ComAtprotoLabelDefs.Label]? = nil,
    quotedAuthorLabels: [ComAtprotoLabelDefs.Label]? = nil,
    parentLabels: [ComAtprotoLabelDefs.Label]? = nil,
    style: ModerationFixtures.QuoteStyle = .plain
  ) throws -> AppBskyFeedDefs.PostView {
    let quoted = try ModerationFixtures.quotedRecord(
      author: try ModerationFixtures.profile("carla", labels: quotedAuthorLabels), labels: quotedLabels)
    return try ModerationFixtures.post(
      author: try ModerationFixtures.profile("bob"), labels: parentLabels, quote: quoted, style: style)
  }

  @Test("Custom labels on a quoted post only ever filter the parent", arguments: quoteScenarios)
  func customLabelOnQuote(_ scenario: QuoteLabelScenario) throws {
    let options = ModerationFixtures.customOptions(blurs: scenario.blurs, severity: scenario.severity)
    let post: AppBskyFeedDefs.PostView
    switch scenario.target {
    case .post:
      post = try parentPost(quotedLabels: [try ModerationFixtures.postLabel("custom", name: "carla", src: src)])
    case .profile:
      post = try parentPost(quotedAuthorLabels: [try ModerationFixtures.profileLabel("custom", name: "carla", src: src)])
    case .account:
      post = try parentPost(quotedAuthorLabels: [try ModerationFixtures.accountLabel("custom", name: "carla", src: src)])
    }
    expectModeration(ModerationSubjects.decidePost(post, options: options), scenario.expected, scenario.testDescription)
  }

  @Test("A !hide on the quoted post filters the parent but cannot blur or lock it")
  func hideOnQuoteDoesNotBlurParent() throws {
    let label = try ModerationFixtures.postLabel("!hide", name: "carla")
    let decision = ModerationSubjects.decidePost(try parentPost(quotedLabels: [label]), options: ModerationFixtures.options())
    expectModeration(decision, [.contentList: [.filter]], "quoted !hide")
    #expect(decision.causes.count == 1)
    #expect(decision.causes.allSatisfy { $0.downgraded })
  }

  @Test("A porn label on a quoted post removes the parent from lists but never blurs parent media")
  func pornOnQuote() throws {
    let label = try ModerationFixtures.postLabel("porn", name: "carla")
    let options = ModerationFixtures.options(adult: true, settings: ["porn": .hide])
    let decision = ModerationSubjects.decidePost(try parentPost(quotedLabels: [label]), options: options)
    expectModeration(decision, [.contentList: [.filter]], "quoted porn")
  }

  @Test("The parent's own labels are not downgraded")
  func parentLabelsStayActive() throws {
    let parentLabel = try ModerationFixtures.postLabel("!warn", name: "bob")
    let quotedLabel = try ModerationFixtures.postLabel("!hide", name: "carla")
    let decision = ModerationSubjects.decidePost(
      try parentPost(quotedLabels: [quotedLabel], parentLabels: [parentLabel]), options: ModerationFixtures.options())
    expectModeration(decision, [.contentList: [.filter, .blur], .contentView: [.blur]], "parent !warn + quoted !hide")
  }

  @Test("Quote-with-media embeds are treated like plain quotes")
  func quoteWithMedia() throws {
    let label = try ModerationFixtures.postLabel("!hide", name: "carla")
    let decision = ModerationSubjects.decidePost(
      try parentPost(quotedLabels: [label], style: .withMedia), options: ModerationFixtures.options())
    expectModeration(decision, [.contentList: [.filter]], "quote with media")
  }

  @Test("A blocked quote contributes no label causes")
  func blockedQuote() throws {
    let label = try ModerationFixtures.postLabel("!hide", name: "carla")
    let decision = ModerationSubjects.decidePost(
      try parentPost(quotedLabels: [label], style: .blocked), options: ModerationFixtures.options())
    #expect(decision.isEmpty)
    expectModeration(decision, [:], "blocked quote")
  }

  @Test("The quoted post's author labels are evaluated with the quoted author as the subject")
  func quotedAuthorSelfLabel() throws {
    // carla labels her own account `porn`; self-labels are honored, and adult content is on.
    let selfLabel = try ModerationFixtures.accountLabel("porn", name: "carla", src: "did:web:carla.test")
    let options = ModerationFixtures.options(adult: true, settings: ["porn": .hide])
    let decision = ModerationSubjects.decidePost(try parentPost(quotedAuthorLabels: [selfLabel]), options: options)
    let cause = try #require(decision.causes.first)
    #expect(cause.source == .user)
    #expect(cause.downgraded)
    #expect(decision.did == "did:web:bob.test", "the parent's author is the decision subject")
  }
}
