import Foundation
import Petrel
import Testing

@testable import Catbird

// Shared fixtures for the moderation engine suites. They mirror
// `atproto/packages/api/src/mocker.ts` and `tests/util/moderation-behavior.ts`.

// MARK: - Expected result vocabulary

/// The flags `toBeModerationResult` checks upstream.
enum ModerationTestFlag: String, Sendable, Hashable {
  case filter
  case blur
  case alert
  case inform
  case noOverride
}

/// Expected flags per context. A missing context must be a complete no-op.
typealias ModerationExpectation = [ModerationContext: Set<ModerationTestFlag>]

extension ModerationUI {
  var testFlags: Set<ModerationTestFlag> {
    var flags: Set<ModerationTestFlag> = []
    if filter { flags.insert(.filter) }
    if blur { flags.insert(.blur) }
    if alert { flags.insert(.alert) }
    if inform { flags.insert(.inform) }
    if noOverride { flags.insert(.noOverride) }
    return flags
  }
}

/// Assert that `decision` produces exactly `expected` in every listed context
/// (and a no-op in every other checked context).
func expectModeration(
  _ decision: ModerationDecision,
  _ expected: ModerationExpectation,
  contexts: [ModerationContext] = ModerationContext.allCases,
  _ name: String,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  for context in contexts {
    let actual = decision.ui(context).testFlags
    let wanted = expected[context] ?? []
    #expect(actual == wanted, "\(name) [\(context.rawValue)]: expected \(wanted.map(\.rawValue).sorted()), got \(actual.map(\.rawValue).sorted())", sourceLocation: sourceLocation)
  }
}

// MARK: - Builders

enum ModerationFixtures {
  static let labelerDID = "did:plc:fake-labeler"
  static let selfDID = "did:web:self.test"
  static let customLabelerDID = "did:web:labeler.test"

  static func did(_ string: String) throws -> DID { try DID(didString: string) }

  static func label(
    _ value: String,
    uri: String,
    src: String = labelerDID,
    neg: Bool? = nil,
    exp: Date? = nil
  ) throws -> ComAtprotoLabelDefs.Label {
    ComAtprotoLabelDefs.Label(
      src: try did(src), uri: URI(uriString: uri), val: value, neg: neg,
      cts: ATProtocolDate(date: Date()), exp: exp.map { ATProtocolDate(date: $0) })
  }

  /// A label on the account itself (`uri` is the DID).
  static func accountLabel(_ value: String, name: String, src: String = labelerDID, neg: Bool? = nil, exp: Date? = nil) throws -> ComAtprotoLabelDefs.Label {
    try label(value, uri: "did:web:\(name).test", src: src, neg: neg, exp: exp)
  }

  /// A label on the profile record (`app.bsky.actor.profile/self`).
  static func profileLabel(_ value: String, name: String, src: String = labelerDID) throws -> ComAtprotoLabelDefs.Label {
    try label(value, uri: "at://did:web:\(name).test/app.bsky.actor.profile/self", src: src)
  }

  /// A label on a post by `name`.
  static func postLabel(_ value: String, name: String, src: String = labelerDID, neg: Bool? = nil, exp: Date? = nil) throws -> ComAtprotoLabelDefs.Label {
    try label(value, uri: "at://did:web:\(name).test/app.bsky.feed.post/fake", src: src, neg: neg, exp: exp)
  }

  static func profile(_ name: String, labels: [ComAtprotoLabelDefs.Label]? = nil) throws -> AppBskyActorDefs.ProfileViewBasic {
    AppBskyActorDefs.ProfileViewBasic(
      did: try did("did:web:\(name).test"), handle: try Handle(handleString: "\(name).test"),
      displayName: name.capitalized, labels: labels)
  }

  private static func postRecord() -> ATProtocolValueContainer {
    .knownType(
      AppBskyFeedPost(
        text: "Post text", entities: nil, facets: nil, reply: nil, embed: nil, langs: nil,
        labels: nil, tags: nil, createdAt: ATProtocolDate(date: Date())))
  }

  static func quotedRecord(
    author: AppBskyActorDefs.ProfileViewBasic,
    labels: [ComAtprotoLabelDefs.Label]? = nil
  ) throws -> AppBskyEmbedRecord.ViewRecord {
    AppBskyEmbedRecord.ViewRecord(
      uri: try ATProtocolURI(uriString: "at://\(author.did)/app.bsky.feed.post/quoted"),
      cid: CID.fromDAGCBOR(Data("quoted".utf8)), author: author, value: postRecord(),
      labels: labels, indexedAt: ATProtocolDate(date: Date()))
  }

  enum QuoteStyle: Sendable {
    case plain
    case withMedia
    case blocked
  }

  static func post(
    author: AppBskyActorDefs.ProfileViewBasic,
    labels: [ComAtprotoLabelDefs.Label]? = nil,
    quote: AppBskyEmbedRecord.ViewRecord? = nil,
    style: QuoteStyle = .plain
  ) throws -> AppBskyFeedDefs.PostView {
    var embed: AppBskyFeedDefs.PostViewEmbedUnion?
    if let quote {
      let record: AppBskyEmbedRecord.ViewRecordUnion
      if style == .blocked {
        record = .appBskyEmbedRecordViewBlocked(
          AppBskyEmbedRecord.ViewBlocked(
            uri: quote.uri, blocked: true, author: AppBskyFeedDefs.BlockedAuthor(did: quote.author.did)))
      } else {
        record = .appBskyEmbedRecordViewRecord(quote)
      }
      let view = AppBskyEmbedRecord.View(record: record)
      if style == .withMedia {
        embed = .appBskyEmbedRecordWithMediaView(
          AppBskyEmbedRecordWithMedia.View(record: view, media: .appBskyEmbedImagesView(AppBskyEmbedImages.View(images: []))))
      } else {
        embed = .appBskyEmbedRecordView(view)
      }
    }
    return AppBskyFeedDefs.PostView(
      uri: try ATProtocolURI(uriString: "at://\(author.did)/app.bsky.feed.post/fake"),
      cid: CID.fromDAGCBOR(Data("post".utf8)), author: author, record: postRecord(), embed: embed,
      indexedAt: ATProtocolDate(date: Date()), labels: labels)
  }

  // MARK: Options

  /// Options the way `ModerationBehaviorSuiteRunner.moderationOpts` builds them.
  static func options(
    authed: Bool = true,
    adult: Bool = false,
    settings: [String: LabelPreference] = [:],
    labelers: [LabelerModerationPrefs] = [LabelerModerationPrefs(did: labelerDID)],
    definitions: [String: [ModerationLabelDefinition]] = [:],
    now: Date = Date()
  ) -> ModerationOptions {
    ModerationOptions(
      userDID: authed ? selfDID : "",
      prefs: ModerationPrefs(adultContentEnabled: adult, labels: settings, labelers: labelers),
      labelDefinitions: definitions, now: now)
  }

  static func customDefinition(
    _ identifier: String = "custom",
    blurs: String,
    severity: String,
    defaultSetting: String? = "warn",
    adultOnly: Bool? = nil,
    definedBy: String = customLabelerDID
  ) -> ModerationLabelDefinition? {
    ModerationLabelDefinition.interpret(
      ComAtprotoLabelDefs.LabelValueDefinition(
        identifier: identifier, severity: severity, blurs: blurs, defaultSetting: defaultSetting,
        adultOnly: adultOnly, locales: []),
      definedBy: definedBy)
  }

  /// Options for a labeler that defines `custom` and has the user set to `hide`.
  static func customOptions(blurs: String, severity: String) -> ModerationOptions {
    ModerationOptions(
      userDID: "did:web:alice.test",
      prefs: ModerationPrefs(
        adultContentEnabled: true, labels: [:],
        labelers: [LabelerModerationPrefs(did: customLabelerDID, labels: ["custom": .hide])]),
      labelDefinitions: [
        customLabelerDID: [customDefinition(blurs: blurs, severity: severity)].compactMap { $0 }
      ])
  }
}
