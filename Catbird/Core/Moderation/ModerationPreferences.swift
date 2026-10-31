import Foundation
import Petrel

// Preference model for the moderation engine, plus the legacy-key
// normalization that `@atproto/api` does in `agent.ts`
// (`adjustLegacyContentLabelPref`, `remapLegacyLabels`, `DEFAULT_LABEL_SETTINGS`).

// MARK: - Label preference

/// How a user wants a label handled.
enum LabelPreference: String, Sendable, Equatable, CaseIterable {
  case ignore
  case warn
  case hide

  /// Parse a visibility string that Catbird or the Bluesky app wrote. Matches
  /// exactly and case-sensitively, like the SDK: `ignore`, `warn`, `hide`, and the
  /// legacy `show` (treated as `ignore`). Anything else, `HIDE` and `Show`
  /// included, returns `nil`.
  ///
  /// This is for settings UI that must know whether a stored string is one the
  /// app wrote. Moderation decisions use `init?(storedVisibility:)`.
  init?(preferenceValue: String) {
    switch preferenceValue {
    case "ignore", "show": self = .ignore
    case "warn": self = .warn
    case "hide": self = .hide
    default: return nil
    }
  }

  /// The preference a decision acts on for a stored visibility string,
  /// reproducing `getPreferences` and `decision.ts` in `@atproto/api`.
  ///
  /// `getPreferences` rewrites only exactly `show` to `ignore` and passes every
  /// other string through. `addLabel` then reads a preference by truthiness: the
  /// empty string counts as no preference, and any other value that is not
  /// `ignore` or `hide` overrides the default yet is neither, so it behaves like
  /// `warn` (a media blur or alert, never a list filter). That makes an unknown
  /// non-empty string (`block`, `HIDE`) an explicit, warn-like preference.
  /// Returns `nil` only for the empty string.
  init?(storedVisibility: String) {
    guard !storedVisibility.isEmpty else { return nil }
    self = Self(preferenceValue: storedVisibility) ?? .warn
  }
}

// MARK: - Labeler-scoped preferences

/// Preferences a user set for one specific labeler. They take precedence over
/// the global preference for the same label.
struct LabelerModerationPrefs: Sendable, Equatable {
  var did: String
  var labels: [String: LabelPreference]

  init(did: String, labels: [String: LabelPreference] = [:]) {
    self.did = did
    self.labels = labels
  }
}

// MARK: - Moderation prefs

/// The preference snapshot the engine reads. Global label keys are the
/// canonical ids (`porn`, `sexual`, `graphic-media`, `nudity`), plus the stored
/// legacy names and custom labeler values exactly as the server sent them.
struct ModerationPrefs: Sendable, Equatable {
  /// DID of the Bluesky moderation service (`moderation.bsky.app`). It is a
  /// trusted label source for every user without subscribing.
  static let blueskyModerationDID = "did:plc:ar7c4by46qjdydhdevvrndac"

  /// Whether adult content may be shown. Callers pass the effective value.
  var adultContentEnabled: Bool
  /// Global label preferences. The engine reads a label's own identifier.
  var labels: [String: LabelPreference]
  /// Trusted third-party label sources, in subscription order.
  var labelers: [LabelerModerationPrefs]

  /// `DEFAULT_LABEL_SETTINGS` upstream: the default setting of every
  /// configurable builtin label except the deprecated aliases (`gore`), which the
  /// SDK does not seed.
  static let builtinDefaultLabels: [String: LabelPreference] = {
    var defaults: [String: LabelPreference] = [:]
    for definition in ModerationLabelDefinition.builtins.values
    where definition.configurable && !ModerationLabelDefinition.deprecatedAliasIdentifiers.contains(definition.identifier) {
      defaults[definition.identifier] = definition.defaultSetting
    }
    return defaults
  }()

  /// Direct construction, used by tests and by callers that already hold
  /// normalized values. Does not seed defaults or add the Bluesky labeler.
  init(
    adultContentEnabled: Bool,
    labels: [String: LabelPreference],
    labelers: [LabelerModerationPrefs]
  ) {
    self.adultContentEnabled = adultContentEnabled
    self.labels = labels
    self.labelers = labelers
  }

  /// Build prefs from stored server preferences, the way `@bsky/sdk`'s
  /// `getPreferences` does.
  ///
  /// - Global entries (`labelerDid == nil`) override the seeded builtin defaults.
  ///   Entries are applied in array order, so the last entry for a label wins.
  /// - A global legacy key (`nsfw`, `suggestive`, `gore`) sets its canonical id
  ///   (`porn`, `sexual`, `graphic-media`) AND stays in `labels` under its own
  ///   name. `gore` is also a label value of its own, read through that key. A
  ///   labeler's custom label may share a legacy name, and the SDK resolves it
  ///   through the same global map.
  /// - Catbird's former private key `graphic` is read as `graphic-media`, but only
  ///   when no global `graphic-media` or `gore` entry exists (whatever its
  ///   visibility). When one exists, `graphic` is an inert key, as in the SDK.
  /// - Labeler-scoped entries are stored verbatim under the key the server sent
  ///   (the SDK never remaps them) on that labeler if subscribed, else dropped.
  /// - Keys and visibility strings match exactly and are case-sensitive, as in
  ///   the SDK. See `LabelPreference.init?(storedVisibility:)` for how an unknown
  ///   or empty visibility reads.
  /// - An empty visibility is no preference: it clears an earlier value for the
  ///   key, so the labeler-scoped lookup falls through to the global one and the
  ///   global one falls through to the definition's default.
  /// - `labelers` always begins with the Bluesky moderation service, followed by
  ///   the subscribed labelers in order, deduplicated.
  init(
    adultContentEnabled: Bool,
    contentLabelPrefs: [ContentLabelPreference],
    labelerDIDs: [String]
  ) {
    var labelers = [LabelerModerationPrefs(did: Self.blueskyModerationDID)]
    var seen: Set<String> = [Self.blueskyModerationDID]
    for did in labelerDIDs where seen.insert(did).inserted {
      labelers.append(LabelerModerationPrefs(did: did))
    }
    let labelerIndex = Dictionary(uniqueKeysWithValues: labelers.enumerated().map { ($1.did, $0) })

    var labels = Self.builtinDefaultLabels
    let hasGlobalGraphicMedia = contentLabelPrefs.contains {
      $0.labelerDid == nil && ($0.label == "graphic-media" || $0.label == "gore")
    }

    for pref in contentLabelPrefs {
      let preference = LabelPreference(storedVisibility: pref.visibility)

      if let labelerDid = pref.labelerDid {
        if let index = labelerIndex[labelerDid.didString()] {
          labelers[index].labels[pref.label] = preference
        }
        continue
      }

      var key = pref.label
      if key == Self.catbirdGraphicKey, !hasGlobalGraphicMedia {
        key = "graphic-media"
      }

      // No preference means the definition's default, which for a seeded
      // builtin is the seeded value.
      labels[key] = preference ?? Self.builtinDefaultLabels[key]
      if let canonical = Self.sdkLegacyToCanonical[key] {
        labels[canonical] = preference ?? Self.builtinDefaultLabels[canonical]
      }
    }

    self.init(adultContentEnabled: adultContentEnabled, labels: labels, labelers: labelers)
  }

  // MARK: - Legacy key mapping

  /// Catbird's former private key for the graphic media preference.
  static let catbirdGraphicKey = "graphic"

  /// Legacy keys the SDK remaps on read (`remapLegacyLabels`).
  private static let sdkLegacyToCanonical: [String: String] = [
    "nsfw": "porn",
    "suggestive": "sexual",
    "gore": "graphic-media",
  ]

  private static let canonicalToLegacy: [String: String] = [
    "porn": "nsfw",
    "sexual": "suggestive",
    "graphic-media": "gore",
  ]

  /// Map a label identifier a caller holds (a UI value, a label `val`) to the
  /// canonical id used for writes: `nsfw` to `porn`, `suggestive` to `sexual`,
  /// `gore` and Catbird's old `graphic` to `graphic-media`. Everything else is
  /// returned lowercased.
  ///
  /// Reading stored preferences does not use this: `init(adultContentEnabled:
  /// contentLabelPrefs:labelerDIDs:)` matches keys exactly, like the SDK.
  static func canonicalLabelIdentifier(_ identifier: String) -> String {
    let lowered = identifier.lowercased()
    if lowered == catbirdGraphicKey { return "graphic-media" }
    return sdkLegacyToCanonical[lowered] ?? lowered
  }

  /// The Bluesky legacy key that must be written alongside a canonical global
  /// preference (`porn` to `nsfw`, `sexual` to `suggestive`, `graphic-media`
  /// to `gore`), as social-app does. `nil` when there is none.
  static func legacyAlias(forCanonical identifier: String) -> String? {
    canonicalToLegacy[identifier]
  }
}
