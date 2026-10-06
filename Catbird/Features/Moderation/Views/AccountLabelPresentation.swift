import Foundation
import Petrel

/// Display metadata from the issuing labeler's published label definitions.
struct AccountLabelPresentation {
  enum Severity { case information, warning, unspecified }
  let name: String
  let description: String?
  let issuer: String
  let severity: Severity

  init(
    label: ComAtprotoLabelDefs.Label,
    labeler: AppBskyLabelerDefs.LabelerViewDetailed?,
    preferredLanguages: [String] = Locale.preferredLanguages
  ) {
    let definition = label.val.hasPrefix("!") ? nil : labeler?.policies.labelValueDefinitions?.first { $0.identifier == label.val }
    let strings = definition.flatMap { Self.localizedStrings($0.locales, preferredLanguages: preferredLanguages) }
    name = strings?.name ?? Self.builtInName(label.val)
    description = strings?.description
    if let creator = labeler?.creator {
      issuer = creator.displayName.flatMap { $0.isEmpty ? nil : $0 }.map { "\($0) (@\(creator.handle))" }
        ?? "@\(creator.handle)"
    } else {
      issuer = label.src.didString()
    }
    switch definition?.severity {
    case "inform": severity = .information
    case "alert": severity = .warning
    default: severity = .unspecified
    }
  }

  static func localizedStrings(
    _ locales: [ComAtprotoLabelDefs.LabelValueDefinitionStrings], preferredLanguages: [String]
  ) -> ComAtprotoLabelDefs.LabelValueDefinitionStrings? {
    for preference in preferredLanguages {
      let tag = preference.replacingOccurrences(of: "_", with: "-").lowercased()
      if let exact = locales.first(where: { $0.lang.languageTag.lowercased() == tag }) { return exact }
      let language = tag.split(separator: "-").first
      if let sameLanguage = locales.first(where: { $0.lang.languageTag.lowercased().split(separator: "-").first == language }) {
        return sameLanguage
      }
    }
    return locales.first(where: { $0.lang.languageTag.lowercased() == "en" }) ?? locales.first
  }

  static func accountLabels(
    _ labels: [ComAtprotoLabelDefs.Label], subjectDID: String, subscribedIssuers: Set<String>
  ) -> [ComAtprotoLabelDefs.Label] {
    var seen = Set<String>()
    return labels.filter {
      ReportingService.isLabelActive($0)
        && ($0.uri.uriString() == subjectDID || $0.uri.uriString() == "at://\(subjectDID)/app.bsky.actor.profile/self")
        && ($0.src.didString() == subjectDID || subscribedIssuers.contains($0.src.didString()))
        && seen.insert($0.id).inserted
    }
  }

  private static func builtInName(_ value: String) -> String {
    switch value {
    case "porn": String(localized: "Adult Content")
    case "sexual": String(localized: "Sexually Suggestive")
    case "nudity": String(localized: "Non-Sexual Nudity")
    case "graphic-media": String(localized: "Graphic Media")
    case "!hide": String(localized: "Hidden by Moderation Service")
    case "!warn": String(localized: "Moderation Warning")
    case "!no-unauthenticated": String(localized: "Sign-In Required")
    case "bot": String(localized: "Automated Account")
    default: value
    }
  }
}
