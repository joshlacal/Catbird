import Foundation
import Observation
import Petrel

// What one rendered post needs from the moderation engine, computed once per
// render from the post and the account's `ModerationPolicy`. Views read the
// flags here; they never evaluate labels themselves.

/// Identity of a cause for de-duplication across contexts.
struct ModerationCauseKey: Hashable, Sendable {
  let labelerDID: String
  let uri: String
  let value: String
  let target: LabelTarget
}

extension ModerationCause {
  var key: ModerationCauseKey {
    ModerationCauseKey(labelerDID: labelerDID, uri: label.uri.uriString(), value: label.val, target: target)
  }

  /// The cause blocks reveal because adult content is off, not because the
  /// label itself forbids override (`!hide`).
  var isAdultContentDisabled: Bool {
    noOverride && !definition.flags.contains(.noOverride)
  }

  /// Who or what is responsible for the cause hiding content, for the copy a
  /// hidden row or a locked gate shows.
  var gateReason: ModerationGateReason {
    if isAdultContentDisabled { return .adultContentOff }
    if !definition.configurable || definition.flags.contains(.noOverride) { return .moderators }
    return .userSetting
  }
}

/// Why content is hidden or locked: the account's adult-content setting (changed
/// at bsky.app), a system label or a cause the user may not override, or a
/// setting the user chose for a configurable label.
enum ModerationGateReason: Sendable, Equatable {
  case adultContentOff
  case moderators
  case userSetting
}

extension ModerationUI {
  /// Causes of two contexts combined, as the video feed does for its cover.
  func merged(with other: ModerationUI) -> ModerationUI {
    func union(_ lhs: [ModerationCause], _ rhs: [ModerationCause]) -> [ModerationCause] {
      var seen = Set<ModerationCauseKey>()
      return (lhs + rhs).filter { seen.insert($0.key).inserted }
    }
    var result = ModerationUI()
    result.noOverride = noOverride || other.noOverride
    result.filters = union(filters, other.filters)
    result.blurs = union(blurs, other.blurs)
    result.alerts = union(alerts, other.alerts)
    result.informs = union(informs, other.informs)
    return result
  }
}

/// The per-context results a post row, quote card or thread anchor renders.
struct PostModerationPresentation: Equatable, Sendable {
  /// `.contentList` for rows and quotes, `.contentView` for the thread anchor.
  let surface: ModerationContext
  let decision: ModerationDecision
  /// `ui(.contentList).filter`, unless the author is the profile being viewed.
  /// Surfaces that build lists (feeds, the video feed, notifications) drop the
  /// post; this includes a filter inherited from a quoted post.
  let isFilteredFromList: Bool
  /// A rendered row replaces the post with the hidden row. Only a filter the
  /// post carries itself counts: one inherited from a quote filters lists but
  /// renders the row normally with the quote card gated, as upstream's
  /// `PostHider` ignores downgraded filters (`getBlurrableFilter`).
  let hidesRow: Bool
  /// The surface's own UI: body blur, alerts and informs.
  let body: ModerationUI
  /// `ui(.contentMedia)`: images, galleries, video and link cards.
  let media: ModerationUI
  /// `ui(.avatar)` for the author.
  let avatar: ModerationUI
  /// Alert and inform causes not already represented by a gate or a filter.
  let chips: [ModerationCause]

  static let empty = PostModerationPresentation(
    surface: .contentList, decision: ModerationDecision(), isFilteredFromList: false, hidesRow: false,
    body: .empty, media: .empty, avatar: .empty, chips: [])

  var concealsBody: Bool { body.blur }
  var concealsMedia: Bool { media.blur }
  var concealsAvatar: Bool { avatar.blur }

  /// The filter cause the hidden row names: the first the post carries itself.
  var hiddenRowCause: ModerationCause? {
    decision.ui(.contentList).filters.first { !$0.downgraded }
  }

  /// Why the hidden row hides the post, from the cause it names.
  var hiddenRowReason: ModerationGateReason {
    hiddenRowCause?.gateReason ?? .userSetting
  }

  /// The hidden row offers Show unless the surface itself is locked, as the
  /// upstream `PostHider` reads `modui.noOverride`. A locked media cause stays
  /// locked after reveal because the media gate re-reads it.
  var hiddenRowAllowsReveal: Bool { !body.noOverride }

  /// Stable identity of the hidden row's causes, so a reveal does not survive a
  /// different decision for the same post.
  var filterIdentity: String {
    decision.ui(.contentList).filters.map { "\($0.key.labelerDID)|\($0.key.uri)|\($0.key.value)" }.joined(separator: ",")
  }

  // MARK: - Builders

  /// The presentation for a post rendered on `surface`.
  ///
  /// Record self-labels missing from `post.labels` are added to the decision as
  /// labels issued by the author on the post URI, which is what the AppView does
  /// when it hydrates a view. This covers optimistic local posts.
  static func make(
    post: AppBskyFeedDefs.PostView,
    policy: ModerationPolicy,
    surface: ModerationContext = .contentList,
    listFilterExemptDID: String? = nil
  ) -> PostModerationPresentation {
    var decision = policy.decide(post: post)
    addMissingSelfLabels(
      record: post.record, existing: post.labels, author: post.author.did, uri: post.uri,
      to: &decision, policy: policy)
    let exempt = listFilterExemptDID.map { $0 == post.author.did.didString() } ?? false
    return build(decision: decision, surface: surface, exemptFromListFilter: exempt)
  }

  /// The presentation for a quoted record. Quotes are never list-filtered on
  /// their own; the parent decision carries their causes as downgraded filters.
  static func make(quoted: AppBskyEmbedRecord.ViewRecord, policy: ModerationPolicy) -> PostModerationPresentation {
    var decision = policy.decide(quotedPost: quoted)
    addMissingSelfLabels(
      record: quoted.value, existing: quoted.labels, author: quoted.author.did, uri: quoted.uri,
      to: &decision, policy: policy)
    return build(decision: decision, surface: .contentList, exemptFromListFilter: true)
  }

  private static func build(
    decision: ModerationDecision, surface: ModerationContext, exemptFromListFilter: Bool
  ) -> PostModerationPresentation {
    let list = decision.ui(.contentList)
    let body = surface == .contentList ? list : decision.ui(surface)
    let media = decision.ui(.contentMedia)
    let hidesRow = !exemptFromListFilter && list.filters.contains { !$0.downgraded }
    var shown = Set(body.blurs.map(\.key))
    shown.formUnion(media.blurs.map(\.key))
    // The hidden row names the filter causes, so they need no chip there. Only
    // the list surface renders that row; on the thread anchor (`contentView`),
    // a quote card or the profile owner's own posts an alert or inform cause
    // that also filters lists keeps its pill, as `ThreadItemAnchor` renders
    // `PostAlerts` upstream.
    if surface == .contentList && hidesRow { shown.formUnion(list.filters.map(\.key)) }
    var seen = Set<ModerationCauseKey>()
    let chips = (body.alerts + body.informs).filter { !shown.contains($0.key) && seen.insert($0.key).inserted }
    return PostModerationPresentation(
      surface: surface, decision: decision,
      isFilteredFromList: list.filter && !exemptFromListFilter,
      hidesRow: hidesRow,
      body: body, media: media, avatar: decision.ui(.avatar), chips: chips)
  }

  // MARK: - Quoted records

  /// The post view a post quotes, with or without media alongside it. Callers
  /// that print a quote outside `RecordEmbedView` decide it with `make(quoted:)`.
  static func quotedRecord(in post: AppBskyFeedDefs.PostView) -> AppBskyEmbedRecord.ViewRecord? {
    let record: AppBskyEmbedRecord.ViewRecordUnion
    switch post.embed {
    case .appBskyEmbedRecordView(let view): record = view.record
    case .appBskyEmbedRecordWithMediaView(let view): record = view.record.record
    default: return nil
    }
    guard case .appBskyEmbedRecordViewRecord(let quoted) = record else { return nil }
    return quoted
  }

  // MARK: - Self-labels

  /// Self-label values declared in a post record.
  static func recordSelfLabelValues(_ record: ATProtocolValueContainer) -> [String] {
    guard case .knownType(let value) = record, let post = value as? AppBskyFeedPost,
      case .comAtprotoLabelDefsSelfLabels(let selfLabels)? = post.labels
    else { return [] }
    return selfLabels.values.map(\.val)
  }

  private static func addMissingSelfLabels(
    record: ATProtocolValueContainer,
    existing: [ComAtprotoLabelDefs.Label]?,
    author: DID,
    uri: ATProtocolURI,
    to decision: inout ModerationDecision,
    policy: ModerationPolicy
  ) {
    let values = recordSelfLabelValues(record)
    guard !values.isEmpty else { return }
    let authorDID = author.didString()
    let present = Set((existing ?? []).filter { $0.src.didString() == authorDID }.map(\.val))
    let missing = values.filter { !present.contains($0) }
    guard !missing.isEmpty else { return }
    let createdAt: ATProtocolDate
    if case .knownType(let value) = record, let post = value as? AppBskyFeedPost {
      createdAt = post.createdAt
    } else {
      createdAt = ATProtocolDate(date: Date())
    }
    let options = policy.options()
    let subject = URI(uriString: uri.uriString())
    for value in missing {
      decision.addLabel(
        ComAtprotoLabelDefs.Label(src: author, uri: subject, val: value, cts: createdAt),
        target: .content, options: options)
    }
  }
}

// MARK: - Reveal state

/// The reveal a gate keeps in view state. It is for one set of causes, so a
/// different set (a new label, a changed setting, another post in a reused
/// host) conceals again without an event having to fire. A set the viewer may
/// no longer override (adult content turned off after the reveal, a label that
/// became `!hide`) is concealed again as well, even though its cause keys are
/// unchanged.
struct ModerationRevealState: Equatable, Sendable {
  private var revealedCauses: [ModerationCauseKey]?

  init() {}

  func isRevealed(_ ui: ModerationUI) -> Bool {
    !ui.noOverride && revealedCauses == ui.blurs.map(\.key)
  }

  mutating func show(_ ui: ModerationUI) {
    revealedCauses = ui.blurs.map(\.key)
  }

  mutating func hide() {
    revealedCauses = nil
  }
}

/// Remembers content-warning reveals outside of any one gate view.
///
/// Feed and thread rows are SwiftUI views hosted in reused collection view
/// cells, so a gate's view state is thrown away whenever its cell is reused,
/// and a revealed post scrolled away and back came back concealed. A gate with
/// a subject (`\.moderationRevealSubject`, the post's AT URI) records Show and
/// Hide here and starts from the recorded choice, so the row lays out revealed
/// on its first pass, and the same post in another row or on another screen
/// starts revealed too. A quote card's subject is the quoted post, so showing
/// a post never opens a post it quotes. An entry is for one account, one
/// subject, one kind of gate and one set of causes, so a new cause or a cause
/// the viewer may no longer override conceals again, as
/// `ModerationRevealState` does.
@MainActor
@Observable
fileprivate final class ModerationRevealSubjectToken {
  var generation = 0
}

@MainActor
final class ModerationRevealStore {
  enum Gate: Hashable {
    case body
    case media
  }

  private struct Key: Hashable {
    let accountDID: String
    let subject: String
    let gate: Gate
    let causes: [ModerationCauseKey]
  }

  static let shared = ModerationRevealStore()

  private static let maxEntries = 5_000

  private var revealedKeys: Set<Key> = []
  private var subjectTokens: [String: ModerationRevealSubjectToken] = [:]

  /// Changes whenever the recorded reveals change. A gate restores its state
  /// from here when its row is built, so the feed's row-height cache keys
  /// heights by it: a height measured before a reveal changed never sizes a
  /// row built after it.
  private(set) var generation = 0

  private func token(for subject: String) -> ModerationRevealSubjectToken {
    if let existing = subjectTokens[subject] {
      return existing
    }
    if subjectTokens.count >= Self.maxEntries {
      for existing in subjectTokens.values {
        existing.generation &+= 1
      }
      subjectTokens.removeAll()
    }
    let created = ModerationRevealSubjectToken()
    subjectTokens[subject] = created
    return created
  }

  func isRevealed(_ ui: ModerationUI, gate: Gate, subject: String, accountDID: String) -> Bool {
    guard !ui.noOverride, let key = Self.key(ui, gate: gate, subject: subject, accountDID: accountDID) else {
      return false
    }
    _ = token(for: subject).generation
    return revealedKeys.contains(key)
  }

  func setRevealed(_ revealed: Bool, ui: ModerationUI, gate: Gate, subject: String, accountDID: String) {
    guard let key = Self.key(ui, gate: gate, subject: subject, accountDID: accountDID) else { return }
    if revealed {
      if revealedKeys.count >= Self.maxEntries {
        revealedKeys.removeAll()
        for existing in subjectTokens.values {
          existing.generation &+= 1
        }
      }
      guard revealedKeys.insert(key).inserted else { return }
    } else {
      guard revealedKeys.remove(key) != nil else { return }
    }
    generation &+= 1
    subjectTokens[subject]?.generation &+= 1
  }

  /// No key without a subject: such a gate keeps its reveal in view state only.
  private static func key(_ ui: ModerationUI, gate: Gate, subject: String, accountDID: String) -> Key? {
    guard !subject.isEmpty else { return nil }
    return Key(accountDID: accountDID, subject: subject, gate: gate, causes: ui.blurs.map(\.key))
  }
}

/// Labels on an external link card, evaluated with no self subject: only the
/// Bluesky moderation service and subscribed labelers count.
enum ExternalLinkModeration {
  static func mediaUI(labels: [ComAtprotoLabelDefs.Label]?, policy: ModerationPolicy) -> ModerationUI {
    guard let labels, !labels.isEmpty else { return .empty }
    var decision = ModerationDecision()
    let options = policy.options()
    for label in labels {
      decision.addLabel(label, target: .content, options: options)
    }
    return decision.ui(.contentMedia)
  }
}
