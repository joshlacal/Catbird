import Foundation
import Petrel

// Swift port of the label-definition half of `@atproto/api` moderation:
// `moderation/types.ts` (behaviors, flags), `moderation/util.ts`
// (`interpretLabelValueDefinition`), and the builtin table generated from
// `definitions/labels.json`.
//
// Everything in this file is pure, synchronous value-type code.

// MARK: - Contexts and behaviors

/// A place in the UI where a moderation decision is rendered. Mirrors the keys
/// of `ModerationBehavior` in `@atproto/api`.
enum ModerationContext: String, CaseIterable, Sendable {
  case profileList
  case profileView
  case avatar
  case banner
  case displayName
  case contentList
  case contentView
  case contentMedia
}

/// What a label does in a given context.
enum ModerationBehaviorAction: String, Sendable {
  case blur
  case alert
  case inform
}

/// A context-to-action lookup. Absent contexts mean "no effect".
struct ModerationBehavior: Sendable, Equatable, ExpressibleByDictionaryLiteral {
  private let actions: [ModerationContext: ModerationBehaviorAction]

  /// The behavior that does nothing anywhere (`NOOP_BEHAVIOR` upstream).
  static let noop = ModerationBehavior()

  init(_ actions: [ModerationContext: ModerationBehaviorAction] = [:]) {
    self.actions = actions
  }

  init(dictionaryLiteral elements: (ModerationContext, ModerationBehaviorAction)...) {
    self.actions = Dictionary(elements, uniquingKeysWith: { _, latest in latest })
  }

  subscript(context: ModerationContext) -> ModerationBehaviorAction? {
    actions[context]
  }

  var isEmpty: Bool { actions.isEmpty }
}

// MARK: - Definition vocabulary

/// What a label is attached to. `account` labels target the DID, `profile`
/// labels target the `app.bsky.actor.profile/self` record, `content` labels
/// target posts, feeds, lists and similar records.
enum LabelTarget: String, CaseIterable, Sendable, Hashable {
  case account
  case profile
  case content
}

enum LabelFlag: String, Sendable, Hashable {
  case noOverride = "no-override"
  case adult
  case unauthed
  case noSelf = "no-self"
}

enum LabelBlurs: String, Sendable, Hashable {
  case content
  case media
  case none
}

enum LabelSeverity: String, Sendable, Hashable {
  case inform
  case alert
  case none
}

/// Human readable strings for one language, from a labeler's definition.
struct LabelDisplayStrings: Sendable, Equatable, Hashable {
  let lang: String
  let name: String
  let description: String
}

// MARK: - Definition

/// A fully interpreted label definition, either builtin (`definedBy == nil`)
/// or declared by a labeler.
struct ModerationLabelDefinition: Sendable, Equatable {
  let identifier: String
  let configurable: Bool
  let defaultSetting: LabelPreference
  let flags: Set<LabelFlag>
  let blurs: LabelBlurs
  let severity: LabelSeverity
  let behaviors: [LabelTarget: ModerationBehavior]
  /// DID of the labeler that declared this definition; `nil` for builtins.
  let definedBy: String?
  let locales: [LabelDisplayStrings]
}

// MARK: - Builtin table

extension ModerationLabelDefinition {
  /// Transcription of `atproto/packages/api/definitions/labels.json`, keyed by
  /// identifier. A deprecated alias in that file (`gore`, an alias of
  /// `graphic-media`) is a builtin of its own in the SDK's generated table: it is
  /// looked up by its own identifier and read through its own preference key, so
  /// it appears here as a separate entry (see `deprecatedAliasIdentifiers`).
  static let builtins: [String: ModerationLabelDefinition] = {
    let all = [
      hideLabel, warnLabel, noUnauthenticatedLabel, pornLabel, sexualLabel, nudityLabel, graphicMediaLabel, goreLabel,
    ]
    return Dictionary(uniqueKeysWithValues: all.map { ($0.identifier, $0) })
  }()

  /// Builtins that exist only as deprecated aliases of another builtin. They are
  /// complete definitions, but the SDK does not seed a preference for them
  /// (`DEFAULT_LABEL_SETTINGS` lists the four canonical labels), so they use
  /// their definition's default until a `gore` preference is stored.
  static let deprecatedAliasIdentifiers: Set<String> = ["gore"]

  /// Behavior matrix shared by `!hide` and `!no-unauthenticated`.
  private static let imperativeBehaviors: [LabelTarget: ModerationBehavior] = [
    .account: [
      .profileList: .blur, .profileView: .blur, .avatar: .blur, .banner: .blur,
      .displayName: .blur, .contentList: .blur, .contentView: .blur,
    ],
    .profile: [.avatar: .blur, .banner: .blur, .displayName: .blur],
    .content: [.contentList: .blur, .contentView: .blur],
  ]

  /// Behavior matrix shared by every media label (`porn`, `sexual`, `nudity`,
  /// `graphic-media`).
  private static let mediaBehaviors: [LabelTarget: ModerationBehavior] = [
    .account: [.avatar: .blur, .banner: .blur],
    .profile: [.avatar: .blur, .banner: .blur],
    .content: [.contentMedia: .blur],
  ]

  private static let hideLabel = ModerationLabelDefinition(
    identifier: "!hide", configurable: false, defaultSetting: .hide,
    flags: [.noOverride, .noSelf], blurs: .content, severity: .alert,
    behaviors: imperativeBehaviors, definedBy: nil, locales: [])

  private static let warnLabel = ModerationLabelDefinition(
    identifier: "!warn", configurable: false, defaultSetting: .warn,
    flags: [.noSelf], blurs: .content, severity: .none,
    behaviors: [
      .account: [
        .profileList: .blur, .profileView: .blur, .avatar: .blur, .banner: .blur,
        .contentList: .blur, .contentView: .blur,
      ],
      .profile: [.avatar: .blur, .banner: .blur, .displayName: .blur],
      .content: [.contentList: .blur, .contentView: .blur],
    ], definedBy: nil, locales: [])

  private static let noUnauthenticatedLabel = ModerationLabelDefinition(
    identifier: "!no-unauthenticated", configurable: false, defaultSetting: .hide,
    flags: [.noOverride, .unauthed], blurs: .content, severity: .none,
    behaviors: imperativeBehaviors, definedBy: nil, locales: [])

  private static let pornLabel = ModerationLabelDefinition(
    identifier: "porn", configurable: true, defaultSetting: .hide,
    flags: [.adult], blurs: .media, severity: .none,
    behaviors: mediaBehaviors, definedBy: nil, locales: [])

  private static let sexualLabel = ModerationLabelDefinition(
    identifier: "sexual", configurable: true, defaultSetting: .warn,
    flags: [.adult], blurs: .media, severity: .none,
    behaviors: mediaBehaviors, definedBy: nil, locales: [])

  private static let nudityLabel = ModerationLabelDefinition(
    identifier: "nudity", configurable: true, defaultSetting: .ignore,
    flags: [], blurs: .media, severity: .none,
    behaviors: mediaBehaviors, definedBy: nil, locales: [])

  private static let graphicMediaLabel = graphicMedia(identifier: "graphic-media")

  /// Deprecated alias of `graphic-media`: the same definition under its own
  /// identifier, so its preference key is `gore`, not `graphic-media`.
  private static let goreLabel = graphicMedia(identifier: "gore")

  private static func graphicMedia(identifier: String) -> ModerationLabelDefinition {
    ModerationLabelDefinition(
      identifier: identifier, configurable: true, defaultSetting: .warn,
      flags: [.adult], blurs: .media, severity: .none,
      behaviors: mediaBehaviors, definedBy: nil, locales: [])
  }

  /// The builtin definition for a label value, if it is one.
  static func builtin(forLabelValue value: String) -> ModerationLabelDefinition? {
    builtins[value]
  }
}

// MARK: - Identifier rules and lookup

extension ModerationLabelDefinition {
  /// Longest identifier the lexicon allows for a labeler-defined value.
  static let maxCustomIdentifierLength = 100

  /// `CUSTOM_LABEL_VALUE_RE` upstream (`^[a-z-]+$`), plus the lexicon length cap.
  static func isValidCustomIdentifier(_ identifier: String) -> Bool {
    guard !identifier.isEmpty, identifier.utf8.count <= maxCustomIdentifierLength else { return false }
    return identifier.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D }
  }

  /// Identifiers a labeler may never define: every builtin (the deprecated
  /// `gore` included) and every system label (leading `!`).
  static func isReservedIdentifier(_ identifier: String) -> Bool {
    identifier.hasPrefix("!") || builtins[identifier] != nil
  }

  /// Find the definition for a label value emitted by `labelerDID`.
  ///
  /// Builtin values always resolve to the builtin table, so a definition
  /// smuggled into `custom` can never shadow them. Other values resolve only
  /// to a definition that this exact labeler declared.
  static func resolve(
    labelValue: String,
    labelerDID: String,
    custom: [String: [ModerationLabelDefinition]]
  ) -> ModerationLabelDefinition? {
    if let builtin = builtin(forLabelValue: labelValue) { return builtin }
    guard isValidCustomIdentifier(labelValue), let definitions = custom[labelerDID] else { return nil }
    return definitions.first { $0.identifier == labelValue && $0.definedBy == labelerDID }
  }
}

// MARK: - Labeler definition interpretation

extension ModerationLabelDefinition {
  /// Port of `interpretLabelValueDefinition` (util.ts), hardened: returns
  /// `nil` for identifiers that are reserved (builtin or `!`-prefixed)
  /// or that do not match `^[a-z-]+$`. Upstream interprets those anyway and
  /// relies on lookup order; Catbird refuses to represent them at all.
  static func interpret(
    _ def: ComAtprotoLabelDefs.LabelValueDefinition,
    definedBy labelerDID: String
  ) -> ModerationLabelDefinition? {
    guard isValidCustomIdentifier(def.identifier), !isReservedIdentifier(def.identifier) else {
      return nil
    }

    let severity = LabelSeverity(rawValue: def.severity) ?? .none
    let alertOrInform: ModerationBehaviorAction? =
      severity == .alert ? .alert : (severity == .inform ? .inform : nil)
    let adultOnly = def.adultOnly == true

    var account: [ModerationContext: ModerationBehaviorAction] = [:]
    var profile: [ModerationContext: ModerationBehaviorAction] = [:]
    var content: [ModerationContext: ModerationBehaviorAction] = [:]

    // Unknown `blurs` values produce no behaviors at all, as upstream does.
    let knownBlurs = LabelBlurs(rawValue: def.blurs)
    switch knownBlurs {
    case .content:
      account[.profileList] = alertOrInform
      account[.profileView] = alertOrInform
      account[.contentList] = .blur
      account[.contentView] = adultOnly ? .blur : alertOrInform
      profile[.profileList] = alertOrInform
      profile[.profileView] = alertOrInform
      content[.contentList] = .blur
      content[.contentView] = adultOnly ? .blur : alertOrInform
    case .media:
      account[.profileList] = alertOrInform
      account[.profileView] = alertOrInform
      account[.avatar] = .blur
      account[.banner] = .blur
      profile[.profileList] = alertOrInform
      profile[.profileView] = alertOrInform
      profile[.avatar] = .blur
      profile[.banner] = .blur
      content[.contentMedia] = .blur
    case .some(.none):
      account[.profileList] = alertOrInform
      account[.profileView] = alertOrInform
      account[.contentList] = alertOrInform
      account[.contentView] = alertOrInform
      profile[.profileList] = alertOrInform
      profile[.profileView] = alertOrInform
      content[.contentList] = alertOrInform
      content[.contentView] = alertOrInform
    case nil:
      break
    }

    // Only an explicit "hide" or "ignore" overrides the "warn" default.
    let defaultSetting: LabelPreference
    switch def.defaultSetting {
    case "hide": defaultSetting = .hide
    case "ignore": defaultSetting = .ignore
    default: defaultSetting = .warn
    }

    var flags: Set<LabelFlag> = [.noSelf]
    if adultOnly { flags.insert(.adult) }

    return ModerationLabelDefinition(
      identifier: def.identifier,
      configurable: true,
      defaultSetting: defaultSetting,
      flags: flags,
      blurs: knownBlurs ?? LabelBlurs.none,
      severity: severity,
      behaviors: [
        .account: ModerationBehavior(account),
        .profile: ModerationBehavior(profile),
        .content: ModerationBehavior(content),
      ],
      definedBy: labelerDID,
      locales: def.locales.map {
        LabelDisplayStrings(lang: $0.lang.languageTag, name: $0.name, description: $0.description)
      })
  }

  /// Interpret every definition a labeler published, dropping the rejected ones.
  static func interpretAll(
    _ defs: [ComAtprotoLabelDefs.LabelValueDefinition],
    definedBy labelerDID: String
  ) -> [ModerationLabelDefinition] {
    defs.compactMap { interpret($0, definedBy: labelerDID) }
  }
}
