import Foundation
import Petrel

// Settings-facing view of the moderation engine. Every value the moderation
// settings show comes from `ModerationPrefs`, the same normalization the engine
// applies to the account's confirmed preferences, and every write uses the keys
// the engine reads. The rules follow social-app at commit 5b88335:
// `src/screens/Moderation/index.tsx`, `src/components/moderation/LabelPreference.tsx`
// and `setContentLabelPref` in `@bsky/sdk` (`dist/actions/preferences.js`).

// MARK: - Preference titles

extension LabelPreference {
  /// The segmented-control title Bluesky uses for this preference.
  var settingsOptionTitle: String {
    switch self {
    case .ignore: "Show"
    case .warn: "Warn"
    case .hide: "Hide"
    }
  }
}

// MARK: - Global content filters

/// One builtin content filter on the Moderation screen.
struct ContentFilterRow: Identifiable, Equatable {
  enum Control: Equatable {
    /// The user picks a preference. The value is the one the engine applies.
    case selectable(LabelPreference)
    /// The label is adult-only and adult content is off, so the engine hides it
    /// whatever is stored.
    case hiddenWhileAdultContentOff
  }

  /// The canonical preference key (`porn`, `sexual`, `graphic-media`, `nudity`).
  let identifier: String
  let name: String
  let description: String
  let control: Control

  var id: String { identifier }
  var controlID: SettingsControlID { ContentFilterSettings.controlID(for: identifier) }
}

enum ContentFilterSettings {
  /// The builtin labels the Moderation screen configures, in Bluesky's order.
  static let builtinIdentifiers = ["porn", "sexual", "graphic-media", "nudity"]

  /// The Settings search and focus anchor for a builtin filter.
  static func controlID(for identifier: String) -> SettingsControlID {
    SettingsControlID(rawValue: "moderation.\(identifier)")
  }

  /// The rows for `prefs`, which must come from
  /// `ModerationPrefs(adultContentEnabled:contentLabelPrefs:labelerDIDs:)` so the
  /// builtin defaults, the legacy remap and `show` are applied exactly as the
  /// engine applies them.
  static func rows(for prefs: ModerationPrefs) -> [ContentFilterRow] {
    builtinIdentifiers.compactMap { identifier in
      guard let definition = ModerationLabelDefinition.builtin(forLabelValue: identifier) else { return nil }
      let control: ContentFilterRow.Control =
        definition.flags.contains(.adult) && !prefs.adultContentEnabled
        ? .hiddenWhileAdultContentOff
        : .selectable(prefs.labels[identifier] ?? definition.defaultSetting)
      return ContentFilterRow(
        identifier: identifier,
        name: ModerationPresentation.name(for: definition),
        description: ModerationPresentation.description(for: definition),
        control: control)
    }
  }

  /// The preferences one global choice saves, sent in a single update: the
  /// canonical key, then its legacy alias (`porn`/`nsfw`, `sexual`/`suggestive`,
  /// `graphic-media`/`gore`), as `setContentLabelPref` does.
  static func globalWrites(identifier: String, preference: LabelPreference) -> [ContentLabelPreference] {
    var writes = [ContentLabelPreference(labelerDid: nil, label: identifier, visibility: preference.rawValue)]
    if let alias = ModerationPrefs.legacyAlias(forCanonical: identifier) {
      writes.append(ContentLabelPreference(labelerDid: nil, label: alias, visibility: preference.rawValue))
    }
    return writes
  }
}

// MARK: - Content preview

/// What the engine does with a post that carries one builtin label from the
/// Bluesky moderation service, under the given preferences.
enum ContentFilterPreview {
  enum Outcome: Equatable {
    case shown
    case mediaBlurred(canReveal: Bool)
    case removedFromFeeds(canRevealMedia: Bool)

    var summary: String {
      switch self {
      case .shown:
        "Shown without a warning."
      case .mediaBlurred(true):
        "Post text is shown. Images and video are blurred until you choose to show them."
      case .mediaBlurred(false):
        "Post text is shown. Images and video stay blurred."
      case .removedFromFeeds(true):
        "Removed from feeds. If you open the post, its images and video are blurred until you choose to show them."
      case .removedFromFeeds(false):
        "Removed from feeds. If you open the post, its images and video stay blurred."
      }
    }

    var systemImage: String {
      switch self {
      case .shown: "eye"
      case .mediaBlurred: "eye.trianglebadge.exclamationmark"
      case .removedFromFeeds: "eye.slash"
      }
    }
  }

  private static let sampleAuthorDID = "did:plc:catbird-settings-preview"
  private static let samplePostURI = "at://did:plc:catbird-settings-preview/app.bsky.feed.post/preview"

  /// The engine's decision for a sample post labeled `identifier`.
  static func outcome(for identifier: String, prefs: ModerationPrefs, now: Date = Date()) -> Outcome? {
    guard let source = try? DID(didString: ModerationPrefs.blueskyModerationDID) else { return nil }
    let label = ComAtprotoLabelDefs.Label(
      src: source, uri: URI(uriString: samplePostURI), val: identifier, cts: ATProtocolDate(date: now))
    var decision = ModerationDecision(did: sampleAuthorDID)
    decision.addLabel(label, target: .content, options: ModerationOptions(userDID: nil, prefs: prefs, now: now))
    let media = decision.ui(.contentMedia)
    if decision.ui(.contentList).filter { return .removedFromFeeds(canRevealMedia: !media.noOverride) }
    if media.blur { return .mediaBlurred(canReveal: !media.noOverride) }
    return .shown
  }
}

// MARK: - Labeler label settings

/// One label a moderation service publishes, as its settings show it.
struct LabelerLabelRow: Identifiable, Equatable {
  /// Where the value the engine applies for a service label comes from.
  enum Source: Equatable {
    /// A choice saved for this service.
    case service
    /// A global choice for the same label identifier.
    case global
    /// The service's default for the label.
    case serviceDefault
  }

  enum Control: Equatable {
    /// A label the service defines. Choices are saved for this service under
    /// `identifier`, exactly as the service spells it.
    case selectable(LabelPreference, canWarn: Bool, source: Source)
    /// A Bluesky label. It is configured on the Moderation screen under the
    /// canonical `identifier`. The value is the one the engine applies to this
    /// service's labels, which includes a choice saved for this service alone
    /// (`hasServiceOverride`); the user can only remove that choice here.
    case configuredGlobally(LabelPreference, hasServiceOverride: Bool)
    /// The label is adult-only and adult content is off, so the engine hides it.
    case hiddenWhileAdultContentOff
    /// The service is not subscribed, so the engine ignores its labels.
    case requiresSubscription
  }

  /// The preference key the engine reads for this label.
  let identifier: String
  let name: String
  let description: String
  let isBuiltin: Bool
  let control: Control

  var id: String { identifier }
}

enum LabelerLabelSettings {
  /// Whether the engine trusts labels from `labelerDID`. The Bluesky moderation
  /// service is always trusted.
  static func isSubscribed(_ labelerDID: String, prefs: ModerationPrefs) -> Bool {
    prefs.labelers.contains { $0.did == labelerDID }
  }

  /// The configurable labels a service publishes, in its order, without
  /// duplicates. Unknown values and system (`!`) labels are left out, as in
  /// social-app's labeler Labels tab.
  static func rows(
    labelValues: [String],
    definitions: [ComAtprotoLabelDefs.LabelValueDefinition],
    labelerDID: String,
    prefs: ModerationPrefs,
    preferredLanguages: [String]? = nil
  ) -> [LabelerLabelRow] {
    let custom = ModerationLabelDefinition.interpretAll(definitions, definedBy: labelerDID)
    let labelerPrefs = prefs.labelers.first { $0.did == labelerDID }
    var seen: Set<String> = []
    var rows: [LabelerLabelRow] = []
    for value in labelValues {
      guard let definition = definition(for: value, custom: custom), definition.configurable,
            seen.insert(definition.identifier).inserted else { continue }
      rows.append(LabelerLabelRow(
        identifier: definition.identifier,
        name: ModerationPresentation.name(for: definition, preferredLanguages: preferredLanguages),
        description: ModerationPresentation.description(for: definition, preferredLanguages: preferredLanguages),
        isBuiltin: definition.definedBy == nil,
        control: control(for: definition, labelerPrefs: labelerPrefs, prefs: prefs)))
    }
    return rows
  }

  /// The one preference a service-scoped choice saves. The key is never
  /// remapped and no legacy alias is written, as in `setContentLabelPref`.
  static func serviceWrite(identifier: String, preference: LabelPreference, labelerDID: DID) -> ContentLabelPreference {
    ContentLabelPreference(labelerDid: labelerDID, label: identifier, visibility: preference.rawValue)
  }

  /// `lookupLabelValueDefinition` in social-app: the service's own definition,
  /// else the builtin. Catbird refuses service definitions for builtin and `!`
  /// identifiers, and shows the deprecated `gore` as `graphic-media`.
  private static func definition(for value: String, custom: [ModerationLabelDefinition]) -> ModerationLabelDefinition? {
    if !value.hasPrefix("!"), let own = custom.first(where: { $0.identifier == value }) { return own }
    guard ModerationLabelDefinition.builtin(forLabelValue: value) != nil else { return nil }
    return ModerationLabelDefinition.builtin(forLabelValue: ModerationPrefs.canonicalLabelIdentifier(value))
  }

  /// The engine's precedence for one label: adult gate, then the service's
  /// choice, then the global choice, then the definition's default.
  private static func control(
    for definition: ModerationLabelDefinition,
    labelerPrefs: LabelerModerationPrefs?,
    prefs: ModerationPrefs
  ) -> LabelerLabelRow.Control {
    let identifier = definition.identifier
    if definition.flags.contains(.adult) && !prefs.adultContentEnabled { return .hiddenWhileAdultContentOff }
    if definition.definedBy == nil {
      let scoped = labelerPrefs?.labels[identifier]
      return .configuredGlobally(
        scoped ?? prefs.labels[identifier] ?? definition.defaultSetting, hasServiceOverride: scoped != nil)
    }
    guard let labelerPrefs else { return .requiresSubscription }

    let stored: LabelPreference
    let source: LabelerLabelRow.Source
    if let scoped = labelerPrefs.labels[identifier] {
      (stored, source) = (scoped, .service)
    } else if let global = prefs.labels[identifier] {
      (stored, source) = (global, .global)
    } else {
      (stored, source) = (definition.defaultSetting, .serviceDefault)
    }
    // A label with no blur and no severity has nothing to warn with, so `warn` acts as `ignore`.
    let canWarn = !(definition.blurs == LabelBlurs.none && definition.severity == LabelSeverity.none)
    return .selectable(!canWarn && stored == .warn ? .ignore : stored, canWarn: canWarn, source: source)
  }
}
