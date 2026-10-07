import Foundation

// Display strings for label definitions. The builtin English strings match
// social-app's `src/lib/moderation/useGlobalLabelStrings.ts`; custom labels
// use the strings the labeler published, picked by the device's languages.

enum ModerationPresentation {
  /// Shown when a moderated surface has no more specific cause to name.
  static let fallbackTitle = "Content Warning"

  private static let builtinStrings: [String: LabelDisplayStrings] = {
    func entry(_ identifier: String, _ name: String, _ description: String) -> (String, LabelDisplayStrings) {
      (identifier, LabelDisplayStrings(lang: "en", name: name, description: description))
    }
    return Dictionary(uniqueKeysWithValues: [
      entry("!hide", "Content Blocked", "This content has been hidden by the moderators."),
      entry("!warn", "Content Warning", "This content has received a general warning from moderators."),
      entry(
        "!no-unauthenticated", "Sign-in Required",
        "This user has requested that their content only be shown to signed-in users."),
      entry("porn", "Adult Content", "Explicit sexual images."),
      entry("sexual", "Sexually Suggestive", "Does not include nudity."),
      entry("nudity", "Non-sexual Nudity", "E.g. artistic nudes."),
      entry("graphic-media", "Graphic Media", "Explicit or potentially disturbing media."),
      entry("gore", "Graphic Media", "Explicit or potentially disturbing media."),
    ])
  }()

  // MARK: - Strings

  /// Name and description for a definition.
  ///
  /// Builtins use the table above. Custom definitions use the first locale that
  /// matches one of the device's languages (BCP 47 basic filtering: a
  /// definition language matches a device language that equals it or extends
  /// it), then the first published locale, then the bare identifier.
  ///
  /// `preferredLanguages` defaults to `Locale.preferredLanguages`, read only
  /// when a custom definition needs it.
  static func strings(
    for definition: ModerationLabelDefinition,
    preferredLanguages: [String]? = nil
  ) -> LabelDisplayStrings {
    if definition.definedBy == nil, let builtin = builtinStrings[definition.identifier] {
      return builtin
    }
    let languages = preferredLanguages ?? Locale.preferredLanguages
    if definition.definedBy != nil,
      let match = localizedStrings(in: definition.locales, preferredLanguages: languages)
    {
      return match
    }
    let identifier: String = definition.identifier
    let language: String = languages.first ?? "en"
    return LabelDisplayStrings(lang: language, name: identifier, description: "Labeled \"\(identifier)\"")
  }

  /// The first published locale matching a device language, in device order,
  /// else the first published locale. Each language tag is lowercased once.
  private static func localizedStrings(
    in locales: [LabelDisplayStrings],
    preferredLanguages: [String]
  ) -> LabelDisplayStrings? {
    guard !locales.isEmpty else { return nil }
    let ranges = locales.map { $0.lang.lowercased() }
    for language in preferredLanguages {
      let tag = language.lowercased().replacingOccurrences(of: "_", with: "-")
      if let index = ranges.firstIndex(where: { languageRange($0, matches: tag) }) {
        return locales[index]
      }
    }
    return locales.first
  }

  static func name(for definition: ModerationLabelDefinition, preferredLanguages: [String]? = nil) -> String {
    strings(for: definition, preferredLanguages: preferredLanguages).name
  }

  static func description(for definition: ModerationLabelDefinition, preferredLanguages: [String]? = nil) -> String {
    strings(for: definition, preferredLanguages: preferredLanguages).description
  }

  // MARK: - Titles

  /// The name of the cause for a pill or a cover. As in social-app's cause
  /// description, `sexual` is presented as "Adult Content" here even though the
  /// label settings list says "Sexually Suggestive".
  static func title(for cause: ModerationCause, preferredLanguages: [String]? = nil) -> String {
    if cause.definition.definedBy == nil,
      cause.definition.identifier == "porn" || cause.definition.identifier == "sexual"
    {
      return "Adult Content"
    }
    return name(for: cause.definition, preferredLanguages: preferredLanguages)
  }

  /// The title for a moderated surface: the highest-priority blur cause, else
  /// the highest-priority alert cause, else a generic warning.
  static func title(for ui: ModerationUI, preferredLanguages: [String]? = nil) -> String {
    if let cause = ui.blurs.min(by: { $0.priority < $1.priority }) ?? ui.alerts.min(by: { $0.priority < $1.priority }) {
      return title(for: cause, preferredLanguages: preferredLanguages)
    }
    return fallbackTitle
  }

  // MARK: - Language matching

  /// BCP 47 basic filtering. `range` is a definition language and `tag` a device
  /// language, both already lowercased with `-` separators.
  private static func languageRange(_ range: String, matches tag: String) -> Bool {
    if range == "*" || tag == range { return true }
    return tag.hasPrefix(range) && tag.dropFirst(range.count).first == "-"
  }
}
