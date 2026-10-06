import Foundation
import NaturalLanguage

/// Only changes that can alter visible posts require a feed refresh.
struct ReadingLanguageFilterSignature: Equatable, Sendable {
  let hidesOtherLanguages: Bool
  let preferredBaseCodes: [String]

  init(hideOtherLanguages: Bool, preferredLanguages: [String]) {
    let codes = Set(preferredLanguages.compactMap(ReadingLanguagePolicy.supportedBaseCode)).sorted()
    hidesOtherLanguages = hideOtherLanguages && !codes.isEmpty
    preferredBaseCodes = hidesOtherLanguages ? codes : []
  }
}

/// Reading-language filtering compares supported base codes and retains undecidable posts.
enum ReadingLanguagePolicy {
  private static let supportedCodes = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier))

  static func supportedBaseCode(_ raw: String) -> String? {
    let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").first.map(String.init) ?? ""
    guard supportedCodes.contains(code), !["und", "mul", "zxx", "mis"].contains(code) else { return nil }
    return code
  }

  static func allows(declaredLanguages: [String], preferredLanguages: [String], detectedLanguage: String?) -> Bool {
    let preferred = Set(preferredLanguages.compactMap(supportedBaseCode))
    guard !preferred.isEmpty else { return true }
    if !declaredLanguages.isEmpty {
      let declared = declaredLanguages.compactMap(supportedBaseCode)
      // An unknown declaration cannot establish that every language is unwanted.
      guard declared.count == declaredLanguages.count else { return true }
      return declared.contains(where: preferred.contains)
    }
    guard let detectedLanguage, let detected = supportedBaseCode(detectedLanguage) else { return true }
    return preferred.contains(detected)
  }

  static func allows(declaredLanguages: [String], preferredLanguages: [String], text: String) -> Bool {
    var detected: String?
    if declaredLanguages.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      // A recognizer belongs to this call; feed and search filtering share no mutable detector.
      let recognizer = NLLanguageRecognizer()
      recognizer.processString(text)
      if let language = recognizer.dominantLanguage,
         let confidence = recognizer.languageHypotheses(withMaximum: 3)[language], confidence >= 0.5 {
        detected = language.rawValue
      }
    }
    return allows(declaredLanguages: declaredLanguages, preferredLanguages: preferredLanguages, detectedLanguage: detected)
  }
}
