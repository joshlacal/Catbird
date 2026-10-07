import Foundation
import Petrel

// Swift port of `moderation/subjects/*.ts` from `@atproto/api` (account,
// profile, post), label causes only. Feed generators and lists are not moderated
// by any launch surface and have no decider here.

// MARK: - Account subjects

/// A profile view that carries an account DID and account/profile labels.
protocol ModerationAccountSubject: Sendable {
  var moderationDID: String { get }
  var moderationLabels: [ComAtprotoLabelDefs.Label]? { get }
}

extension AppBskyActorDefs.ProfileViewBasic: ModerationAccountSubject {
  var moderationDID: String { did.didString() }
  var moderationLabels: [ComAtprotoLabelDefs.Label]? { labels }
}

extension AppBskyActorDefs.ProfileView: ModerationAccountSubject {
  var moderationDID: String { did.didString() }
  var moderationLabels: [ComAtprotoLabelDefs.Label]? { labels }
}

extension AppBskyActorDefs.ProfileViewDetailed: ModerationAccountSubject {
  var moderationDID: String { did.didString() }
  var moderationLabels: [ComAtprotoLabelDefs.Label]? { labels }
}

extension ChatBskyActorDefs.ProfileViewBasic: ModerationAccountSubject {
  var moderationDID: String { did.didString() }
  var moderationLabels: [ComAtprotoLabelDefs.Label]? { labels }
}

// MARK: - Subject deciders

enum ModerationSubjects {
  /// Labels whose subject is the profile record rather than the account.
  static let profileRecordURISuffix = "/app.bsky.actor.profile/self"

  /// The one profile-record label that is treated as an account label.
  static let noUnauthenticatedValue = "!no-unauthenticated"

  // MARK: Post

  /// Post labels, then the quoted post (downgraded), then the author's account
  /// and profile labels.
  static func decidePost(_ post: AppBskyFeedDefs.PostView, options: ModerationOptions) -> ModerationDecision {
    let authorDID = post.author.moderationDID
    var subject = ModerationDecision(did: authorDID, isMe: isMe(authorDID, options))

    let quoted = embeddedViewRecord(post.embed)
    // Fast path: no labels anywhere means nothing to evaluate or merge.
    if !hasLabels(post.labels), !hasLabels(post.author.labels),
      quoted.map({ !hasLabels($0.labels) && !hasLabels($0.author.labels) }) ?? true
    {
      return subject
    }

    addLabels(post.labels, target: .content, to: &subject, options: options)
    return .merge([
      subject,
      decideEmbed(post.embed, options: options)?.downgraded(),
      decideAccount(labels: post.author.labels, did: authorDID, options: options),
      decideProfile(labels: post.author.labels, did: authorDID, options: options),
    ])
  }

  /// A quoted post's own labels plus its author's account and profile labels.
  static func decideQuotedPost(_ quoted: AppBskyEmbedRecord.ViewRecord, options: ModerationOptions) -> ModerationDecision {
    let authorDID = quoted.author.moderationDID
    var subject = ModerationDecision(did: authorDID, isMe: isMe(authorDID, options))
    if !hasLabels(quoted.labels), !hasLabels(quoted.author.labels) { return subject }

    addLabels(quoted.labels, target: .content, to: &subject, options: options)
    return .merge([
      subject,
      decideAccount(labels: quoted.author.labels, did: authorDID, options: options),
      decideProfile(labels: quoted.author.labels, did: authorDID, options: options),
    ])
  }

  // MARK: Account and profile

  /// Labels on the account (the DID). Labels on the profile record are excluded
  /// except `!no-unauthenticated`, which applies to the whole account.
  static func decideAccount(_ subject: some ModerationAccountSubject, options: ModerationOptions) -> ModerationDecision {
    decideAccount(labels: subject.moderationLabels, did: subject.moderationDID, options: options)
  }

  /// Labels on the profile record only.
  static func decideProfile(_ subject: some ModerationAccountSubject, options: ModerationOptions) -> ModerationDecision {
    decideProfile(labels: subject.moderationLabels, did: subject.moderationDID, options: options)
  }

  private static func decideAccount(
    labels: [ComAtprotoLabelDefs.Label]?,
    did accountDID: String,
    options: ModerationOptions
  ) -> ModerationDecision {
    var decision = ModerationDecision(did: accountDID, isMe: isMe(accountDID, options))
    guard let labels, !labels.isEmpty else { return decision }
    for label in filterAccountLabels(labels) {
      decision.addLabel(label, target: .account, options: options)
    }
    return decision
  }

  private static func decideProfile(
    labels: [ComAtprotoLabelDefs.Label]?,
    did accountDID: String,
    options: ModerationOptions
  ) -> ModerationDecision {
    var decision = ModerationDecision(did: accountDID, isMe: isMe(accountDID, options))
    guard let labels, !labels.isEmpty else { return decision }
    for label in filterProfileLabels(labels) {
      decision.addLabel(label, target: .profile, options: options)
    }
    return decision
  }

  /// `moderateProfile` upstream: account decision merged with profile decision.
  static func decideProfileSubject(_ subject: some ModerationAccountSubject, options: ModerationOptions) -> ModerationDecision {
    let accountDID = subject.moderationDID
    let labels = subject.moderationLabels
    return .merge([
      decideAccount(labels: labels, did: accountDID, options: options),
      decideProfile(labels: labels, did: accountDID, options: options),
    ])
  }

  static func filterAccountLabels(_ labels: [ComAtprotoLabelDefs.Label]?) -> [ComAtprotoLabelDefs.Label] {
    guard let labels else { return [] }
    var kept: [ComAtprotoLabelDefs.Label] = []
    for label in labels {
      let isNoUnauthenticated: Bool = label.val == noUnauthenticatedValue
      if isNoUnauthenticated || !isProfileRecordLabel(label) { kept.append(label) }
    }
    return kept
  }

  static func filterProfileLabels(_ labels: [ComAtprotoLabelDefs.Label]?) -> [ComAtprotoLabelDefs.Label] {
    guard let labels else { return [] }
    return labels.filter { isProfileRecordLabel($0) }
  }

  // MARK: Embeds

  /// The record behind a quote embed (plain or with media), if it is a post.
  private static func embeddedViewRecord(_ embed: AppBskyFeedDefs.PostViewEmbedUnion?) -> AppBskyEmbedRecord.ViewRecord? {
    switch embed {
    case .appBskyEmbedRecordView(let view):
      if case .appBskyEmbedRecordViewRecord(let record) = view.record { return record }
    case .appBskyEmbedRecordWithMediaView(let view):
      if case .appBskyEmbedRecordViewRecord(let record) = view.record.record { return record }
    default:
      break
    }
    return nil
  }

  /// Port of `decideEmbed` (subjects/post.ts). Blocked quotes produce no label causes.
  private static func decideEmbed(_ embed: AppBskyFeedDefs.PostViewEmbedUnion?, options: ModerationOptions) -> ModerationDecision? {
    let record: AppBskyEmbedRecord.ViewRecordUnion
    switch embed {
    case .appBskyEmbedRecordView(let view): record = view.record
    case .appBskyEmbedRecordWithMediaView(let view): record = view.record.record
    default: return nil
    }

    switch record {
    case .appBskyEmbedRecordViewRecord(let quoted):
      return decideQuotedPost(quoted, options: options)
    case .appBskyEmbedRecordViewBlocked(let blocked):
      let blockedDID = blocked.author.did.didString()
      return ModerationDecision(did: blockedDID, isMe: isMe(blockedDID, options))
    default:
      return nil
    }
  }

  // MARK: Helpers

  private static func isMe(_ did: String, _ options: ModerationOptions) -> Bool {
    !did.isEmpty && options.userDID == did
  }

  private static func hasLabels(_ labels: [ComAtprotoLabelDefs.Label]?) -> Bool {
    labels?.isEmpty == false
  }

  private static func isProfileRecordLabel(_ label: ComAtprotoLabelDefs.Label) -> Bool {
    label.uri.uriString().hasSuffix(profileRecordURISuffix)
  }

  private static func addLabels(
    _ labels: [ComAtprotoLabelDefs.Label]?,
    target: LabelTarget,
    to decision: inout ModerationDecision,
    options: ModerationOptions
  ) {
    guard let labels else { return }
    for label in labels {
      decision.addLabel(label, target: target, options: options)
    }
  }
}
