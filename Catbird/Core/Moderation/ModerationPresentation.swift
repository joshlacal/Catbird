import Foundation

// Display strings for label definitions. The builtin English strings match
// social-app's `src/lib/moderation/useGlobalLabelStrings.ts`; custom labels
// use the strings the labeler published, picked by the device's languages.

enum ModerationPresentation {
  /// Shown when a moderated surface has no more specific cause to name.
  static var fallbackTitle: String {
    String(localized: "Content Warning", comment: "Generic moderation banner title when content has a warning.")
  }

  private static var builtinStrings: [String: LabelDisplayStrings] {
    func entry(_ identifier: String, _ name: String, _ description: String) -> (String, LabelDisplayStrings) {
      let lang = Bundle.main.preferredLocalizations.first ?? "en"
      return (identifier, LabelDisplayStrings(lang: lang, name: name, description: description))
    }
    return Dictionary(uniqueKeysWithValues: [
      entry(
        "!hide",
        String(localized: "Content Blocked", comment: "Moderation label title when moderators have blocked content."),
        String(localized: "This content has been hidden by the moderators.", comment: "Moderation label description when content was hidden by moderators.")
      ),
      entry(
        "!warn",
        String(localized: "Content Warning", comment: "Generic moderation label title when moderators issued a warning."),
        String(localized: "This content has received a general warning from moderators.", comment: "Moderation label description for a general moderator warning.")
      ),
      entry(
        "!no-unauthenticated",
        String(localized: "Sign-in Required", comment: "Moderation label title when content requires signing in to view."),
        String(localized: "This user has requested that their content only be shown to signed-in users.", comment: "Moderation label description when an author restricts content to signed-in viewers.")
      ),
      entry(
        "porn",
        String(localized: "Adult Content", comment: "Moderation label title for explicit adult content."),
        String(localized: "Explicit sexual images.", comment: "Moderation label description for explicit sexual images.")
      ),
      entry(
        "sexual",
        String(localized: "Sexually Suggestive", comment: "Moderation label title for sexually suggestive content."),
        String(localized: "Does not include nudity.", comment: "Moderation label description for sexually suggestive content without nudity.")
      ),
      entry(
        "nudity",
        String(localized: "Non-sexual Nudity", comment: "Moderation label title for non-sexual nudity."),
        String(localized: "E.g. artistic nudes.", comment: "Moderation label description for non-sexual nudity.")
      ),
      entry(
        "graphic-media",
        String(localized: "Graphic Media", comment: "Moderation label title for graphic or disturbing media."),
        String(localized: "Explicit or potentially disturbing media.", comment: "Moderation label description for graphic media.")
      ),
      entry(
        "gore",
        String(localized: "Graphic Media", comment: "Moderation label title for graphic or disturbing media."),
        String(localized: "Explicit or potentially disturbing media.", comment: "Moderation label description for graphic media.")
      ),
    ])
  }

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
    return LabelDisplayStrings(
      lang: language,
      name: identifier,
      description: String(
        localized: "Labeled “\(identifier)”",
        comment: "Fallback description for a custom moderation label — variable is the raw label identifier."
      )
    )
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
      return String(localized: "Adult Content", comment: "Moderation cover title for adult or sexually suggestive content.")
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
