//
//  LanguageHelpers.swift
//  Catbird
//
//  Created by Josh LaCalamito on 12/18/23.
//

import Foundation
import Petrel

func getAvailableLanguages() -> [LanguageCodeContainer] {
  // Define a curated list of common language tags following BCP 47
  let commonLanguageTags = [
    // Common language codes (ISO 639-1)
    "ar", "de", "en", "es", "fr", "hi", "id", "it", "ja", "ko",
    "nl", "pl", "pt", "ru", "th", "tr", "uk", "vi", "zh",

    // Common regional variants
    "en-US", "en-GB", "es-ES", "es-MX", "pt-BR", "pt-PT",
    "zh-CN", "zh-TW", "fr-FR", "fr-CA", "de-DE", "de-AT", "de-CH"
  ]

  // Create a dictionary to track unique languages with their full tags
  var uniqueLanguages: [String: LanguageCodeContainer] = [:]
  
  // Process each tag and keep only one entry per base language
  for tag in commonLanguageTags {
    let container = LanguageCodeContainer(languageCode: tag)
    let baseLanguageCode = container.lang.languageCode?.identifier ?? container.lang.minimalIdentifier
    
    // Either add this as a new language or replace if it's a regional variant
    // Prefer tags with regions (longer tags)
    if uniqueLanguages[baseLanguageCode] == nil || tag.count > uniqueLanguages[baseLanguageCode]!.lang.minimalIdentifier.count {
      uniqueLanguages[baseLanguageCode] = container
    }
  }
  
  // Sort the unique languages by their localized names
  return uniqueLanguages.values.sorted(by: { (a: LanguageCodeContainer, b: LanguageCodeContainer) -> Bool in
    let aName = Locale.current.localizedString(forLanguageCode: a.lang.languageCode?.identifier ?? "") ?? a.lang.minimalIdentifier
    let bName = Locale.current.localizedString(forLanguageCode: b.lang.languageCode?.identifier ?? "") ?? b.lang.minimalIdentifier
    return aName < bName
  })
}

// Helper function to get a properly formatted display name including region
func getDisplayName(for locale: Locale) -> String {
  let languageName = Locale.current.localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? "") ?? locale.identifier
  
  // If there's a region code, add it to the display name
  if let regionCode = locale.region?.identifier {
    let regionName = Locale.current.localizedString(forRegionCode: regionCode) ?? regionCode
    return "\(languageName) (\(regionName))"
  }
  
  return languageName
}

extension Sequence where Element: Hashable {
  func uniqued() -> [Element] {
    var set = Set<Element>()
    return filter { set.insert($0).inserted }
  }
}