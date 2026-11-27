//
//  CatbirdCatalogLaunchConfig.swift
//  Catbird
//
//  DEBUG-only launch-argument and `blue.catbird://catalog?...` URL route parser
//  powering `-CatbirdCatalog`, Tier-1 snapshot tests, and Tier-2 catalog UITests.
//

#if DEBUG
import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct CatbirdCatalogLaunchConfig: Equatable, Sendable {
  var surface: CatbirdCatalogSurface
  var sweepAll: Bool
  var profile: CatbirdTrapProfile
  var theme: String
  var darkThemeMode: String
  var accentColor: String
  var fontStyle: String
  var fontSize: String
  var lineSpacing: String
  var dynamicType: DynamicTypeSize
  var boldText: Bool
  var reduceTransparency: Bool
  var reduceMotion: Bool
  var increaseContrast: Bool
  var layoutDirection: LayoutDirection
  var inspectorEnabled: Bool
  var disableAnimations: Bool
  var hideChrome: Bool

  init(
    surface: CatbirdCatalogSurface = .kit,
    sweepAll: Bool = false,
    profile: CatbirdTrapProfile = .baselineLight,
    inspectorEnabled: Bool = false,
    disableAnimations: Bool = true,
    hideChrome: Bool = false
  ) {
    self.surface = surface
    self.sweepAll = sweepAll
    self.profile = profile
    self.theme = profile.theme
    self.darkThemeMode = profile.darkThemeMode
    self.accentColor = profile.accentColor
    self.fontStyle = profile.fontStyle
    self.fontSize = profile.fontSize
    self.lineSpacing = profile.lineSpacing
    self.dynamicType = profile.dynamicTypeSize
    self.boldText = profile.boldText
    self.reduceTransparency = profile.reduceTransparency
    self.reduceMotion = profile.reduceMotion
    self.increaseContrast = profile.increaseContrast
    self.layoutDirection = profile.layoutDirection
    self.inspectorEnabled = inspectorEnabled
    self.disableAnimations = disableAnimations
    self.hideChrome = hideChrome
  }

  /// True when `-CatbirdCatalog` (or `--catbird-catalog`) is present in launch arguments.
  static var isRequested: Bool {
    isRequested(in: ProcessInfo.processInfo.arguments)
  }

  static func isRequested(in arguments: [String]) -> Bool {
    if arguments.contains("-CatbirdCatalog") || arguments.contains("--catbird-catalog") {
      return true
    }
    if arguments.contains(where: { $0.hasPrefix("-CatbirdCatalog=") || $0.hasPrefix("--catbird-catalog=") }) {
      return true
    }
    if let raw = UserDefaults.standard.string(forKey: "CatbirdCatalog"), !raw.isEmpty {
      return true
    }
    return false
  }

  var preferredColorScheme: ColorScheme? {
    switch theme.lowercased() {
    case "light": return .light
    case "dark", "dim", "black": return .dark
    default: return nil
    }
  }

  #if os(iOS)
  private static let contentSizeMap: [DynamicTypeSize: UIContentSizeCategory] = [
    .xSmall: .extraSmall,
    .small: .small,
    .medium: .medium,
    .large: .large,
    .xLarge: .extraLarge,
    .xxLarge: .extraExtraLarge,
    .xxxLarge: .extraExtraExtraLarge,
    .accessibility1: .accessibilityMedium,
    .accessibility2: .accessibilityLarge,
    .accessibility3: .accessibilityExtraLarge,
    .accessibility4: .accessibilityExtraExtraLarge,
    .accessibility5: .accessibilityExtraExtraExtraLarge
  ]

  var uiContentSizeCategory: UIContentSizeCategory {
    Self.contentSizeMap[dynamicType] ?? .large
  }
  #endif

  /// Returns a copy with all theme/font/a11y fields reset to the supplied trap profile.
  func applying(profile newProfile: CatbirdTrapProfile) -> CatbirdCatalogLaunchConfig {
    CatbirdCatalogLaunchConfig(
      surface: surface,
      sweepAll: sweepAll,
      profile: newProfile,
      inspectorEnabled: inspectorEnabled,
      disableAnimations: disableAnimations,
      hideChrome: hideChrome
    )
  }

  /// Applies route query overrides from `blue.catbird://catalog?surface=<raw>&profile=<raw>&inspector=<0|1>`.
  func applying(catalogURL url: URL) -> CatbirdCatalogLaunchConfig? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }
    let scheme = (components.scheme ?? "").lowercased()
    let host = (components.host ?? "").lowercased()
    guard (scheme == "blue.catbird" || scheme == "catbird") && host == "catalog" else {
      return nil
    }

    let lookup = Dictionary(
      (components.queryItems ?? []).compactMap { item -> (String, String)? in
        guard let value = item.value else { return nil }
        return (item.name.lowercased(), value)
      },
      uniquingKeysWith: { _, latest in latest }
    )

    var updated = self
    if let profileRaw = lookup["profile"], let parsedProfile = CatbirdTrapProfile(rawValue: profileRaw.lowercased()) {
      updated = updated.applying(profile: parsedProfile)
    }
    updated.applySurfaceValue(lookup["surface"])
    updated.applyVisualOverrides { key in lookup[key] }
    updated.applyFlagOverrides { key in lookup[key] }
    return updated
  }

  /// Parses launch arguments into a `CatbirdCatalogLaunchConfig`.
  static func fromProcessArguments(
    _ arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> CatbirdCatalogLaunchConfig {
    let profile = argumentValue(names: ["-CatbirdProfile", "--catbird-profile"], in: arguments)
      .flatMap { CatbirdTrapProfile(rawValue: $0.lowercased()) } ?? .baselineLight

    var config = CatbirdCatalogLaunchConfig(profile: profile)
    let rawSurface = argumentValue(names: ["-CatbirdCatalog", "--catbird-catalog"], in: arguments)
      ?? UserDefaults.standard.string(forKey: "CatbirdCatalog")
      ?? "kit"
    config.applySurfaceValue(rawSurface)

    let argTable: [String: [String]] = [
      "theme": ["-CatbirdTheme", "--catbird-theme"],
      "accent": ["-CatbirdAccent", "--catbird-accent"],
      "font": ["-CatbirdFont", "--catbird-font"],
      "fontsize": ["-CatbirdFontSize", "--catbird-font-size"],
      "linespacing": ["-CatbirdLineSpacing", "--catbird-line-spacing"],
      "dt": ["-CatbirdDT", "--catbird-dt"],
      "reducetransparency": ["-CatbirdReduceTransparency", "--catbird-reduce-transparency"],
      "reducemotion": ["-CatbirdReduceMotion", "--catbird-reduce-motion"],
      "highcontrast": ["-CatbirdHighContrast", "--catbird-high-contrast"],
      "inspector": ["-CatbirdInspector", "--catbird-inspector"],
      "clean": ["-CatbirdCatalogClean", "--catbird-catalog-clean"],
      "animations": ["-CatbirdAnimations", "--catbird-animations"]
    ]
    let resolver: (String) -> String? = { key in
      guard let names = argTable[key] else { return nil }
      return argumentValue(names: names, in: arguments)
    }

    config.applyVisualOverrides(using: resolver)
    config.applyFlagOverrides(using: resolver)
    return config
  }
}

// MARK: - Config Parsing Helpers

private extension CatbirdCatalogLaunchConfig {
  static let dynamicTypeLookup: [String: DynamicTypeSize] = [
    "XS": .xSmall,
    "S": .small,
    "M": .medium,
    "L": .large,
    "LARGE": .large,
    "XL": .xLarge,
    "XXL": .xxLarge,
    "XXXL": .xxxLarge,
    "AX1": .accessibility1,
    "AX2": .accessibility2,
    "AX3": .accessibility3,
    "AX4": .accessibility4,
    "AX5": .accessibility5
  ]

  mutating func applySurfaceValue(_ raw: String?) {
    guard let raw else { return }
    if raw.lowercased() == "all" {
      sweepAll = true
      surface = .kit
    } else if let parsed = CatbirdCatalogSurface.parse(raw) {
      surface = parsed
    }
  }

  mutating func applyVisualOverrides(using lookup: (String) -> String?) {
    if let themeRaw = lookup("theme") { applyThemeKeyword(themeRaw) }
    if let accentRaw = lookup("accent") { accentColor = Self.normalizeAccent(accentRaw) }
    if let fontRaw = lookup("font") { fontStyle = fontRaw.lowercased() }
    if let sizeRaw = lookup("fontsize") { fontSize = sizeRaw }
    if let spacingRaw = lookup("linespacing") { lineSpacing = spacingRaw.lowercased() }
    if let dynamicTypeRaw = lookup("dt") ?? lookup("dynamictype") {
      let normalized = dynamicTypeRaw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      if let parsedSize = Self.dynamicTypeLookup[normalized] {
        dynamicType = parsedSize
      }
    }
  }

  mutating func applyFlagOverrides(using lookup: (String) -> String?) {
    if let parsed = lookup("reducetransparency").flatMap(Self.parseBool) { reduceTransparency = parsed }
    if let parsed = lookup("reducemotion").flatMap(Self.parseBool) { reduceMotion = parsed }
    if let parsed = lookup("highcontrast").flatMap(Self.parseBool) { increaseContrast = parsed }
    if let parsed = lookup("inspector").flatMap(Self.parseBool) { inspectorEnabled = parsed }
    if let parsed = (lookup("clean") ?? lookup("hidechrome")).flatMap(Self.parseBool) { hideChrome = parsed }
    if let parsed = lookup("animations").flatMap(Self.parseBool) { disableAnimations = !parsed }
  }

  mutating func applyThemeKeyword(_ raw: String) {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "light":
      theme = "light"
    case "dim":
      theme = "dark"
      darkThemeMode = "dim"
    case "black", "true-black", "trueblack":
      theme = "dark"
      darkThemeMode = "black"
    case "dark":
      theme = "dark"
    case "system":
      theme = "system"
    default:
      break
    }
  }

  static func normalizeAccent(_ raw: String) -> String {
    let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if lower == "catbird" { return AccentColorOption.catbird.rawValue }
    return AccentColorOption(rawValue: lower)?.rawValue ?? AccentColorOption.catbird.rawValue
  }

  static func parseBool(_ raw: String) -> Bool? {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on": return true
    case "0", "false", "no", "off": return false
    default: return nil
    }
  }

  static func argumentValue(names: [String], in arguments: [String]) -> String? {
    for name in names {
      let prefix = "\(name)="
      if let prefixed = arguments.first(where: { $0.hasPrefix(prefix) }) {
        return String(prefixed.dropFirst(prefix.count))
      }
      if let index = arguments.firstIndex(of: name), index + 1 < arguments.count {
        let candidate = arguments[index + 1]
        if !candidate.hasPrefix("-") {
          return candidate
        }
      }
    }
    return nil
  }
}
#endif
