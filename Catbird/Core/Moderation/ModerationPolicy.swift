import Foundation
import Petrel

// An immutable, Sendable snapshot of everything the moderation engine needs
// for one signed-in account. The app builds a new policy whenever preferences,
// subscribed labelers or labeler definitions change, and hands it to views and
// services; the policy itself never mutates.

struct ModerationPolicy: Sendable, Equatable {
  /// DID of the signed-in account, or `nil` when no account is active.
  let accountDID: String?
  /// Preferences with the EFFECTIVE adult-content value already applied.
  let prefs: ModerationPrefs
  /// Interpreted custom definitions of subscribed labelers, keyed by labeler DID.
  let labelDefinitions: [String: [ModerationLabelDefinition]]
  /// Whether this session has confirmed preferences with the server.
  let isConfirmed: Bool

  /// Build a policy from stored server state.
  ///
  /// Adult content is effective only when the server preference is on and this
  /// session has confirmed preferences. Only subscribed labelers' definitions
  /// are kept.
  init(
    accountDID: String?,
    serverAdultContentEnabled: Bool,
    contentLabelPrefs: [ContentLabelPreference],
    labelerDIDs: [String],
    labelerDefinitions: [String: [ComAtprotoLabelDefs.LabelValueDefinition]],
    isConfirmed: Bool
  ) {
    let prefs = ModerationPrefs(
      adultContentEnabled: serverAdultContentEnabled && isConfirmed,
      contentLabelPrefs: contentLabelPrefs,
      labelerDIDs: labelerDIDs)

    let subscribed = Set(prefs.labelers.map(\.did))
    var interpreted: [String: [ModerationLabelDefinition]] = [:]
    for (did, definitions) in labelerDefinitions where subscribed.contains(did) {
      let valid = ModerationLabelDefinition.interpretAll(definitions, definedBy: did)
      if !valid.isEmpty { interpreted[did] = valid }
    }

    self.init(accountDID: accountDID, prefs: prefs, labelDefinitions: interpreted, isConfirmed: isConfirmed)
  }

  /// Direct construction from already-normalized values.
  init(
    accountDID: String?,
    prefs: ModerationPrefs,
    labelDefinitions: [String: [ModerationLabelDefinition]] = [:],
    isConfirmed: Bool
  ) {
    self.accountDID = accountDID
    self.prefs = prefs
    self.labelDefinitions = labelDefinitions
    self.isConfirmed = isConfirmed
  }

  /// The policy used before preferences are known: no account, adult content
  /// off, builtin defaults, the Bluesky moderation service only.
  static let failClosed = ModerationPolicy(
    accountDID: nil,
    serverAdultContentEnabled: false,
    contentLabelPrefs: [],
    labelerDIDs: [],
    labelerDefinitions: [:],
    isConfirmed: false)

  /// The effective adult-content setting.
  var adultContentEnabled: Bool { prefs.adultContentEnabled }

  func options(now: Date = Date()) -> ModerationOptions {
    ModerationOptions(userDID: accountDID, prefs: prefs, labelDefinitions: labelDefinitions, now: now)
  }

  /// Adds only a platform restriction. Call on the unchanged confirmed base policy,
  /// so removing the extra ceiling can never invent a preference or lose its value.
  func restrictingMatureContent(_ restricted: Bool) -> ModerationPolicy {
    guard restricted, prefs.adultContentEnabled else { return self }
    var effective = prefs
    effective.adultContentEnabled = false
    return ModerationPolicy(
      accountDID: accountDID, prefs: effective,
      labelDefinitions: labelDefinitions, isConfirmed: isConfirmed)
  }

  // MARK: - Decisions

  func decide(post: AppBskyFeedDefs.PostView) -> ModerationDecision {
    ModerationSubjects.decidePost(post, options: options())
  }

  func decide(quotedPost: AppBskyEmbedRecord.ViewRecord) -> ModerationDecision {
    ModerationSubjects.decideQuotedPost(quotedPost, options: options())
  }

  /// Account-level labels only.
  func decide(account: some ModerationAccountSubject) -> ModerationDecision {
    ModerationSubjects.decideAccount(account, options: options())
  }

  /// Account and profile labels merged, as `moderateProfile` does upstream.
  func decide(profile: some ModerationAccountSubject) -> ModerationDecision {
    ModerationSubjects.decideProfileSubject(profile, options: options())
  }

  // MARK: - Conveniences

  /// Whether feed rows should drop this post (`contentList` filter).
  func listFilter(post: AppBskyFeedDefs.PostView) -> Bool {
    decide(post: post).ui(.contentList).filter
  }

  /// The definition behind a label, for display. Resolves builtins first, then
  /// the issuing labeler's own definitions.
  func definition(for label: ComAtprotoLabelDefs.Label) -> ModerationLabelDefinition? {
    ModerationLabelDefinition.resolve(
      labelValue: label.val, labelerDID: label.src.didString(), custom: labelDefinitions)
  }
}
