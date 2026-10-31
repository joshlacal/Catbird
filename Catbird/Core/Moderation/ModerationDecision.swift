import Foundation
import Petrel

// Swift port of `moderation/decision.ts` and `moderation/ui.ts` from
// `@atproto/api`, restricted to LABEL causes. Blocks, mutes, muted words and
// hidden posts are handled by other code paths and are not represented here.

// MARK: - Options

/// Everything a decision needs besides the subject itself.
struct ModerationOptions: Sendable {
  /// DID of the signed-in account, or `nil` (or empty) when logged out.
  var userDID: String?
  var prefs: ModerationPrefs
  /// Interpreted custom definitions, keyed by the DID of the labeler that declared them.
  var labelDefinitions: [String: [ModerationLabelDefinition]]
  /// The reference time for label expiry.
  var now: Date

  init(
    userDID: String?,
    prefs: ModerationPrefs,
    labelDefinitions: [String: [ModerationLabelDefinition]] = [:],
    now: Date = Date()
  ) {
    self.userDID = userDID
    self.prefs = prefs
    self.labelDefinitions = labelDefinitions
    self.now = now
  }

  var isAuthenticated: Bool {
    userDID.map { !$0.isEmpty } ?? false
  }
}

// MARK: - Cause

enum ModerationCauseSource: Sendable, Equatable {
  /// The subject labeled itself.
  case user
  case labeler(did: String)
}

/// One label that applies to a subject, with the preference and behavior that
/// were in force when it was evaluated.
struct ModerationCause: Sendable, Equatable {
  let label: ComAtprotoLabelDefs.Label
  /// The DID that issued the label, kept as a string so repeated comparisons
  /// do not rebuild it from `label.src`.
  let labelerDID: String
  let definition: ModerationLabelDefinition
  let target: LabelTarget
  let setting: LabelPreference
  let behavior: ModerationBehavior
  /// The user may not reveal what this cause blurs.
  let noOverride: Bool
  /// Lower is more important: 1 system or forced, 2 hide, 5 and 7 and 8 by severity.
  let priority: Int
  let source: ModerationCauseSource
  /// Set on causes inherited from a quoted post: they may filter, but never
  /// blur, alert or inform on the parent.
  var downgraded: Bool = false
}

// MARK: - UI result

/// What a decision means for one `ModerationContext`.
struct ModerationUI: Sendable, Equatable {
  var noOverride = false
  var filters: [ModerationCause] = []
  var blurs: [ModerationCause] = []
  var alerts: [ModerationCause] = []
  var informs: [ModerationCause] = []

  static let empty = ModerationUI()

  var filter: Bool { !filters.isEmpty }
  var blur: Bool { !blurs.isEmpty }
  var alert: Bool { !alerts.isEmpty }
  var inform: Bool { !informs.isEmpty }
}

// MARK: - Decision

/// The set of label causes affecting one subject, and the rules to turn them
/// into per-context UI.
struct ModerationDecision: Sendable, Equatable {
  var did: String
  var isMe: Bool
  var causes: [ModerationCause]

  init(did: String = "", isMe: Bool = false, causes: [ModerationCause] = []) {
    self.did = did
    self.isMe = isMe
    self.causes = causes
  }

  /// Combine decisions. The first non-nil decision supplies `did` and `isMe`.
  static func merge(_ decisions: [ModerationDecision?]) -> ModerationDecision {
    let present = decisions.compactMap { $0 }
    guard let first = present.first else { return ModerationDecision() }
    if present.count == 1 { return first }
    return ModerationDecision(did: first.did, isMe: first.isMe, causes: present.flatMap(\.causes))
  }

  /// A copy with every cause downgraded (used for quoted posts).
  func downgraded() -> ModerationDecision {
    var copy = self
    for index in copy.causes.indices {
      copy.causes[index].downgraded = true
    }
    return copy
  }

  var isEmpty: Bool { causes.isEmpty }

  // MARK: ui(context:)

  /// Port of the label branch of `ModerationDecision.ui()` upstream.
  func ui(_ context: ModerationContext) -> ModerationUI {
    guard !causes.isEmpty else { return .empty }
    var result = ModerationUI()

    for cause in causes {
      switch (context, cause.target) {
      case (.profileList, .account):
        if cause.setting == .hide && !isMe { result.filters.append(cause) }
      case (.contentList, .account), (.contentList, .content):
        if cause.setting == .hide && !isMe { result.filters.append(cause) }
      default:
        break
      }

      guard !cause.downgraded, let action = cause.behavior[context] else { continue }
      switch action {
      case .blur:
        result.blurs.append(cause)
        if cause.noOverride && !isMe { result.noOverride = true }
      case .alert:
        result.alerts.append(cause)
      case .inform:
        result.informs.append(cause)
      }
    }

    result.filters = Self.stableSortedByPriority(result.filters)
    result.blurs = Self.stableSortedByPriority(result.blurs)
    return result
  }

  private static func stableSortedByPriority(_ causes: [ModerationCause]) -> [ModerationCause] {
    guard causes.count > 1 else { return causes }
    return causes.enumerated()
      .sorted { lhs, rhs in
        lhs.element.priority != rhs.element.priority
          ? lhs.element.priority < rhs.element.priority
          : lhs.offset < rhs.offset
      }
      .map(\.element)
  }

  // MARK: addLabel

  private enum BehaviorSeverity {
    case high
    case medium
    case low
  }

  private static func severity(of behavior: ModerationBehavior?) -> BehaviorSeverity {
    guard let behavior else { return .low }
    if behavior[.profileView] == .blur || behavior[.contentView] == .blur { return .high }
    if behavior[.contentList] == .blur || behavior[.contentMedia] == .blur { return .medium }
    return .low
  }

  /// Port of `ModerationDecision.addLabel` upstream.
  ///
  /// Catbird additions: negated and expired labels are skipped, and an exact
  /// duplicate (same issuer, subject URI, value and target) adds no cause.
  mutating func addLabel(_ label: ComAtprotoLabelDefs.Label, target: LabelTarget, options: ModerationOptions) {
    // Inactive labels carry no moderation meaning.
    if label.neg == true { return }
    if let expiry = label.exp, expiry.date <= options.now { return }

    let labelerDID = label.src.didString()

    // Look up the definition; ignore labels we don't understand.
    guard
      let definition = ModerationLabelDefinition.resolve(
        labelValue: label.val, labelerDID: labelerDID, custom: options.labelDefinitions)
    else { return }

    // Only the subject itself and the user's configured labelers are trusted.
    let isSelf = labelerDID == did
    let labelerPrefs = isSelf ? nil : options.prefs.labelers.first { $0.did == labelerDID }
    if !isSelf && labelerPrefs == nil { return }
    if isSelf && definition.flags.contains(.noSelf) { return }

    // The same labeler repeating the same label on the same subject adds
    // nothing. A different subject URI is a different label. The URI string is
    // built only for a candidate that already matches on the cheaper fields.
    if causes.contains(where: {
      $0.target == target && $0.label.val == label.val && $0.labelerDID == labelerDID
        && $0.label.uri.uriString() == label.uri.uriString()
    }) {
      return
    }

    let adultBlocked = definition.flags.contains(.adult) && !options.prefs.adultContentEnabled

    // Establish the preference for interpretation.
    var setting = definition.defaultSetting
    if !definition.configurable {
      setting = definition.defaultSetting
    } else if adultBlocked {
      setting = .hide
    } else if let scoped = labelerPrefs?.labels[definition.identifier] {
      setting = scoped
    } else if let global = options.prefs.labels[definition.identifier] {
      setting = global
    }

    // Ignore labels the user asked to ignore.
    if setting == .ignore { return }

    // Ignore sign-in-only labels once the user is signed in.
    if definition.flags.contains(.unauthed) && options.isAuthenticated { return }

    let behavior = definition.behaviors[target]
    let priority: Int
    if definition.flags.contains(.noOverride) || adultBlocked {
      priority = 1
    } else if setting == .hide {
      priority = 2
    } else {
      switch Self.severity(of: behavior) {
      case .high: priority = 5
      case .medium: priority = 7
      case .low: priority = 8
      }
    }

    causes.append(
      ModerationCause(
        label: label,
        labelerDID: labelerDID,
        definition: definition,
        target: target,
        setting: setting,
        behavior: behavior ?? .noop,
        noOverride: definition.flags.contains(.noOverride) || adultBlocked,
        priority: priority,
        source: isSelf ? .user : .labeler(did: labelerDID)))
  }
}
