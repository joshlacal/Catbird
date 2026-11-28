import CatbirdBrand
import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import os

// MARK: - sRGB Token Math (WCAG 2.1)

/// Exact sRGB color representation matching `docs/brand/contrast-audit.md` and `Brand.color` hex tokens.
struct CatbirdSRGBColor: Sendable, Equatable, Hashable {
  let red: Double
  let green: Double
  let blue: Double

  init(red: Double, green: Double, blue: Double) {
    self.red = min(max(red, 0), 1)
    self.green = min(max(green, 0), 1)
    self.blue = min(max(blue, 0), 1)
  }

  init?(hex: String) {
    let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return nil }
    self.red = Double((value >> 16) & 0xFF) / 255.0
    self.green = Double((value >> 8) & 0xFF) / 255.0
    self.blue = Double(value & 0xFF) / 255.0
  }

  var hexString: String {
    let redByte = Int((red * 255.0).rounded())
    let greenByte = Int((green * 255.0).rounded())
    let blueByte = Int((blue * 255.0).rounded())
    return String(format: "#%02X%02X%02X", redByte, greenByte, blueByte)
  }

  var swiftUIColor: Color {
    Color(.sRGB, red: red, green: green, blue: blue, opacity: 1.0)
  }

  /// WCAG 2.1 relative luminance in sRGB.
  var relativeLuminance: Double {
    func linearize(_ channel: Double) -> Double {
      channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
  }

  /// WCAG 2.1 contrast ratio against `other` (1.0 ... 21.0).
  func contrastRatio(with other: CatbirdSRGBColor) -> Double {
    let lighter = max(relativeLuminance, other.relativeLuminance)
    let darker = min(relativeLuminance, other.relativeLuminance)
    return (lighter + 0.05) / (darker + 0.05)
  }

  /// Darken along the exact same HSL hue/saturation until `contrastRatio(with: background) >= minimumRatio`.
  func darkenedToContrast(
    against background: CatbirdSRGBColor,
    minimumRatio: Double
  ) -> CatbirdSRGBColor {
    if contrastRatio(with: background) >= minimumRatio {
      return self
    }
    let hsl = toHSL()
    var low = 0.0
    var high = hsl.lightness
    for _ in 0..<40 {
      let mid = (low + high) * 0.5
      let candidate = Self.fromHSL(HSL(hue: hsl.hue, saturation: hsl.saturation, lightness: mid))
      if candidate.contrastRatio(with: background) >= minimumRatio {
        low = mid
      } else {
        high = mid
      }
    }
    return Self.fromHSL(HSL(hue: hsl.hue, saturation: hsl.saturation, lightness: low))
  }

  /// Highest-contrast accessible foreground (`#FFFFFF` vs `#0B0D12`) on `background`.
  /// Prefers `#FFFFFF` whenever white already clears WCAG AA-normal (>= 4.5:1).
  static func onAccent(for background: CatbirdSRGBColor) -> CatbirdSRGBColor {
    let whiteRatio = pureWhite.contrastRatio(with: background)
    let inkRatio = darkInk.contrastRatio(with: background)
    if whiteRatio >= 4.5 || whiteRatio >= inkRatio {
      return pureWhite
    }
    return darkInk
  }

  private struct HSL {
    let hue: Double
    let saturation: Double
    let lightness: Double
  }

  private func toHSL() -> HSL {
    let maxChannel = max(red, green, blue)
    let minChannel = min(red, green, blue)
    let delta = maxChannel - minChannel
    let lightness = (maxChannel + minChannel) * 0.5
    guard delta > 1e-9 else { return HSL(hue: 0, saturation: 0, lightness: lightness) }
    let saturation = lightness > 0.5
      ? delta / (2.0 - maxChannel - minChannel)
      : delta / (maxChannel + minChannel)
    let hue: Double
    if maxChannel == red {
      hue = ((green - blue) / delta + (green < blue ? 6.0 : 0.0)) / 6.0
    } else if maxChannel == green {
      hue = ((blue - red) / delta + 2.0) / 6.0
    } else {
      hue = ((red - green) / delta + 4.0) / 6.0
    }
    return HSL(hue: hue, saturation: saturation, lightness: lightness)
  }

  private static func fromHSL(_ hsl: HSL) -> CatbirdSRGBColor {
    guard hsl.saturation > 1e-9 else {
      return CatbirdSRGBColor(red: hsl.lightness, green: hsl.lightness, blue: hsl.lightness)
    }
    let upper = hsl.lightness < 0.5
      ? hsl.lightness * (1.0 + hsl.saturation)
      : hsl.lightness + hsl.saturation - hsl.lightness * hsl.saturation
    let lower = 2.0 * hsl.lightness - upper
    func hueToChannel(_ rawTurn: Double) -> Double {
      var turn = rawTurn
      if turn < 0 { turn += 1 }
      if turn > 1 { turn -= 1 }
      if turn < 1.0 / 6.0 { return lower + (upper - lower) * 6.0 * turn }
      if turn < 0.5 { return upper }
      if turn < 2.0 / 3.0 { return lower + (upper - lower) * (2.0 / 3.0 - turn) * 6.0 }
      return lower
    }
    return CatbirdSRGBColor(
      red: hueToChannel(hsl.hue + 1.0 / 3.0),
      green: hueToChannel(hsl.hue),
      blue: hueToChannel(hsl.hue - 1.0 / 3.0)
    )
  }

  // MARK: - Canonical Token Constants (Brand.color + Color.pkl 0.2.0 Parity)

  static let pureWhite = CatbirdSRGBColor(red: 1.0, green: 1.0, blue: 1.0)
  static let darkInk = CatbirdSRGBColor(hex: "#0B0D12")!

  static let catbirdFallbackAccent = CatbirdSRGBColor(hex: "#5192FF")!
  static let catbirdFallbackTextAccent = CatbirdSRGBColor(hex: "#005EFF")!

  // Light surfaces & text (`Color.pkl` 0.2.0 parity)
  static let lightCanvas = CatbirdSRGBColor(hex: "#FFFFFF")!
  static let lightCard = CatbirdSRGBColor(hex: "#F2F2F7")!
  static let lightElevated = CatbirdSRGBColor(hex: "#FFFFFF")!
  static let lightGrouped = CatbirdSRGBColor(hex: "#F2F2F7")!
  static let lightOnSurface = CatbirdSRGBColor(hex: "#111318")!
  static let lightOnSurfaceVariant = CatbirdSRGBColor(hex: "#5C5F66")!
  static let lightOnSurfaceVariantHighContrast = CatbirdSRGBColor(hex: "#3C3E44")!
  static let lightTertiaryText = CatbirdSRGBColor(hex: "#767980")!
  static let lightDisabledText = CatbirdSRGBColor(hex: "#9B9EA6")!
  static let lightBorderSubtle = CatbirdSRGBColor(hex: "#D1D1D6")!
  static let lightBorderProminent = CatbirdSRGBColor(hex: "#76767B")!

  // Dim surfaces & text (`Brand.color.dim`)
  static let dimBackground = CatbirdSRGBColor(hex: Brand.color.dim.background) ?? CatbirdSRGBColor(hex: "#111318")!
  static let dimSurface = CatbirdSRGBColor(hex: Brand.color.dim.surface) ?? CatbirdSRGBColor(hex: "#1D1F26")!
  static let dimSurfaceContainer = CatbirdSRGBColor(hex: Brand.color.dim.surfaceContainer) ?? CatbirdSRGBColor(hex: "#23252D")!
  static let dimSurfaceContainerHigh = CatbirdSRGBColor(hex: Brand.color.dim.surfaceContainerHigh) ?? CatbirdSRGBColor(hex: "#2A2D36")!
  static let dimOnSurface = CatbirdSRGBColor(hex: Brand.color.dim.onSurface) ?? CatbirdSRGBColor(hex: "#E6E6EC")!
  static let dimOnSurfaceVariant = CatbirdSRGBColor(hex: Brand.color.dim.onSurfaceVariant) ?? CatbirdSRGBColor(hex: "#A8A8B0")!
  static let dimOnSurfaceVariantHighContrast = CatbirdSRGBColor(hex: "#C8C8D0")!
  static let dimTertiaryText = CatbirdSRGBColor(hex: "#7E808A")!
  static let dimDisabledText = CatbirdSRGBColor(hex: "#5A5C66")!
  static let dimBorderSubtle = CatbirdSRGBColor(hex: "#323540")!
  static let dimBorderProminent = CatbirdSRGBColor(hex: "#6E7280")!

  // True Black surfaces & text (`Brand.color.trueBlack`)
  static let trueBlackBackground = CatbirdSRGBColor(hex: Brand.color.trueBlack.background) ?? CatbirdSRGBColor(hex: "#000000")!
  static let trueBlackSurface = CatbirdSRGBColor(hex: Brand.color.trueBlack.surface) ?? CatbirdSRGBColor(hex: "#0A0A0A")!
  static let trueBlackSurfaceContainer = CatbirdSRGBColor(hex: Brand.color.trueBlack.surfaceContainer) ?? CatbirdSRGBColor(hex: "#121212")!
  static let trueBlackSurfaceContainerHigh = CatbirdSRGBColor(hex: Brand.color.trueBlack.surfaceContainerHigh) ?? CatbirdSRGBColor(hex: "#1A1A1A")!
  static let trueBlackOnSurface = CatbirdSRGBColor(hex: Brand.color.trueBlack.onSurface) ?? CatbirdSRGBColor(hex: "#F5F5F7")!
  static let trueBlackOnSurfaceVariant = CatbirdSRGBColor(hex: Brand.color.trueBlack.onSurfaceVariant) ?? CatbirdSRGBColor(hex: "#8E8E93")!
  static let trueBlackOnSurfaceVariantHighContrast = CatbirdSRGBColor(hex: "#B8B8BE")!
  static let trueBlackTertiaryText = CatbirdSRGBColor(hex: "#68686E")!
  static let trueBlackDisabledText = CatbirdSRGBColor(hex: "#48484D")!
  static let trueBlackBorderSubtle = CatbirdSRGBColor(hex: "#262629")!
  static let trueBlackBorderProminent = CatbirdSRGBColor(hex: "#636366")!

  // Semantic colors (`Brand.color.semantic`)
  static let semanticSuccess = CatbirdSRGBColor(hex: Brand.color.semantic.success) ?? CatbirdSRGBColor(hex: "#34C759")!
  static let semanticWarning = CatbirdSRGBColor(hex: Brand.color.semantic.warning) ?? CatbirdSRGBColor(hex: "#FF9F0A")!
  static let semanticDanger = CatbirdSRGBColor(hex: Brand.color.semantic.danger) ?? CatbirdSRGBColor(hex: "#FF3B30")!
  static let semanticEncryptionShield = CatbirdSRGBColor(hex: Brand.color.semantic.encryptionShield) ?? CatbirdSRGBColor(hex: "#34C759")!
}

// MARK: - Unified CatbirdTheme Contract

enum CatbirdSurface: CaseIterable, Sendable, Hashable {
  case canvas
  case card
  case elevated
  case grouped
}

enum CatbirdTextRoleColor: CaseIterable, Sendable, Hashable {
  case primary
  case secondary
  case tertiary
  case disabled
}

enum CatbirdBorderRole: CaseIterable, Sendable, Hashable {
  case subtle
  case prominent
}

enum CatbirdSemanticTone: CaseIterable, Sendable, Hashable {
  case info
  case accent
  case success
  case warning
  case danger
  case neutral
  case encryptionShield
}

/// Snapshot of resolved semantic colors for the active appearance, dark-mode style,
/// accent palette, and contrast setting. Injected via `@Environment(\.catbirdTheme)`.
struct CatbirdThemeColors: Sendable, Equatable {
  let colorScheme: ColorScheme
  let darkThemeMode: ThemeManager.DarkThemeMode
  let accentOption: AccentColorOption
  let isHighContrast: Bool

  var isDark: Bool { colorScheme == .dark }
  var isTrueBlack: Bool { colorScheme == .dark && darkThemeMode == .black }
  var isDim: Bool { colorScheme == .dark && darkThemeMode == .dim }

  // MARK: - Accent Tokens

  var accentChromeSRGB: CatbirdSRGBColor {
    accentOption.chromeSRGB(for: colorScheme)
  }

  var accentTextSRGB: CatbirdSRGBColor {
    accentOption.textAccentSRGB(for: colorScheme)
  }

  var onAccentSRGB: CatbirdSRGBColor {
    accentOption.onAccentSRGB(for: colorScheme)
  }

  var accentChrome: Color { accentChromeSRGB.swiftUIColor }
  var accentText: Color { accentTextSRGB.swiftUIColor }
  var onAccent: Color { onAccentSRGB.swiftUIColor }

  // MARK: - Surface Tokens

  func surfaceSRGB(_ surface: CatbirdSurface) -> CatbirdSRGBColor {
    switch (colorScheme, darkThemeMode, surface) {
    case (.dark, .black, .canvas), (.dark, .black, .grouped):
      return .trueBlackBackground
    case (.dark, .black, .card):
      return .trueBlackSurface
    case (.dark, .black, .elevated):
      return .trueBlackSurfaceContainer

    case (.dark, .dim, .canvas), (.dark, .dim, .grouped):
      return .dimBackground
    case (.dark, .dim, .card):
      return .dimSurface
    case (.dark, .dim, .elevated):
      return .dimSurfaceContainer

    case (_, _, .canvas):
      return .lightCanvas
    case (_, _, .card):
      return .lightCard
    case (_, _, .elevated):
      return .lightElevated
    case (_, _, .grouped):
      return .lightGrouped
    }
  }

  func surface(_ surface: CatbirdSurface) -> Color {
    surfaceSRGB(surface).swiftUIColor
  }

  // MARK: - Text Tokens

  func textSRGB(_ role: CatbirdTextRoleColor) -> CatbirdSRGBColor {
    if isTrueBlack {
      return trueBlackTextSRGB(role)
    }
    if isDark {
      return dimTextSRGB(role)
    }
    return lightTextSRGB(role)
  }

  private func trueBlackTextSRGB(_ role: CatbirdTextRoleColor) -> CatbirdSRGBColor {
    switch role {
    case .primary: return isHighContrast ? .pureWhite : .trueBlackOnSurface
    case .secondary: return isHighContrast ? .trueBlackOnSurfaceVariantHighContrast : .trueBlackOnSurfaceVariant
    case .tertiary: return isHighContrast ? .trueBlackOnSurfaceVariant : .trueBlackTertiaryText
    case .disabled: return isHighContrast ? .trueBlackTertiaryText : .trueBlackDisabledText
    }
  }

  private func dimTextSRGB(_ role: CatbirdTextRoleColor) -> CatbirdSRGBColor {
    switch role {
    case .primary: return isHighContrast ? .pureWhite : .dimOnSurface
    case .secondary: return isHighContrast ? .dimOnSurfaceVariantHighContrast : .dimOnSurfaceVariant
    case .tertiary: return isHighContrast ? .dimOnSurfaceVariant : .dimTertiaryText
    case .disabled: return isHighContrast ? .dimTertiaryText : .dimDisabledText
    }
  }

  private func lightTextSRGB(_ role: CatbirdTextRoleColor) -> CatbirdSRGBColor {
    switch role {
    case .primary: return isHighContrast ? CatbirdSRGBColor(red: 0, green: 0, blue: 0) : .lightOnSurface
    case .secondary: return isHighContrast ? .lightOnSurfaceVariantHighContrast : .lightOnSurfaceVariant
    case .tertiary: return isHighContrast ? .lightOnSurfaceVariant : .lightTertiaryText
    case .disabled: return isHighContrast ? .lightTertiaryText : .lightDisabledText
    }
  }

  func text(_ role: CatbirdTextRoleColor) -> Color {
    textSRGB(role).swiftUIColor
  }

  // MARK: - Border Tokens

  func borderSRGB(_ role: CatbirdBorderRole) -> CatbirdSRGBColor {
    let effectiveRole: CatbirdBorderRole = isHighContrast ? .prominent : role
    switch (colorScheme, darkThemeMode, effectiveRole) {
    case (.dark, .black, .subtle):
      return .trueBlackBorderSubtle
    case (.dark, .black, .prominent):
      return .trueBlackBorderProminent
    case (.dark, .dim, .subtle):
      return .dimBorderSubtle
    case (.dark, .dim, .prominent):
      return .dimBorderProminent
    case (_, _, .subtle):
      return .lightBorderSubtle
    case (_, _, .prominent):
      return .lightBorderProminent
    }
  }

  func border(_ role: CatbirdBorderRole) -> Color {
    borderSRGB(role).swiftUIColor
  }

  // MARK: - Semantic Tokens

  func semanticSRGB(_ tone: CatbirdSemanticTone) -> CatbirdSRGBColor {
    switch tone {
    case .info, .accent:
      return accentChromeSRGB
    case .success:
      return .semanticSuccess
    case .warning:
      return .semanticWarning
    case .danger:
      return .semanticDanger
    case .neutral:
      return textSRGB(.secondary)
    case .encryptionShield:
      return .semanticEncryptionShield
    }
  }

  func semantic(_ tone: CatbirdSemanticTone) -> Color {
    semanticSRGB(tone).swiftUIColor
  }

  // MARK: - Shadow Token

  /// Theme-aware elevation shadow color (clear on OLED True Black where drop shadows disappear).
  func shadowColor() -> Color {
    if isTrueBlack {
      return .clear
    }
    if isDark {
      return Color.black.opacity(0.45)
    }
    return Color.black.opacity(0.14)
  }

  // MARK: - Resolvers

  static func resolve(
    themeManager: ThemeManager?,
    colorScheme: ColorScheme,
    contrast: ColorSchemeContrast = .standard
  ) -> CatbirdThemeColors {
    let effectiveScheme = themeManager?.effectiveColorScheme(for: colorScheme) ?? colorScheme
    let darkMode = themeManager?.darkThemeMode ?? .dim
    let accent = themeManager?.currentAccentColor ?? .catbird
    return CatbirdThemeColors(
      colorScheme: effectiveScheme,
      darkThemeMode: darkMode,
      accentOption: accent,
      isHighContrast: contrast == .increased
    )
  }

  static func resolve(
    colorScheme: ColorScheme,
    darkThemeMode: ThemeManager.DarkThemeMode = .dim,
    accent: AccentColorOption = .catbird,
    isHighContrast: Bool = false
  ) -> CatbirdThemeColors {
    CatbirdThemeColors(
      colorScheme: colorScheme,
      darkThemeMode: darkThemeMode,
      accentOption: accent,
      isHighContrast: isHighContrast
    )
  }
}

private struct CatbirdThemeKey: EnvironmentKey {
  static let defaultValue = CatbirdThemeColors.resolve(
    colorScheme: .light,
    darkThemeMode: .dim,
    accent: .catbird,
    isHighContrast: false
  )
}

extension EnvironmentValues {
  var catbirdTheme: CatbirdThemeColors {
    get { self[CatbirdThemeKey.self] }
    set { self[CatbirdThemeKey.self] = newValue }
  }
}

// MARK: - Theme Color System (Legacy Bridges Backed by Brand.color)

/// Text style variations for different hierarchy levels
enum TextStyle {
    case primary
    case secondary
    case tertiary
    case disabled
}

/// Color elevation levels for creating depth hierarchy
enum ColorElevation: Int {
    case base = 0
    case low = 1
    case medium = 2
    case high = 3
    case modal = 4
    case popover = 5
}

// MARK: - Color Extensions

extension Color {
    
    // MARK: - Dynamic Background Colors
    
    /// Primary background color that adapts to theme (`Brand.color.dim.background` / `Brand.color.trueBlack.background`).
    static func dynamicBackground(_ themeManager: ThemeManager, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeManager.effectiveColorScheme(for: currentScheme)
        
        switch (colorScheme, themeManager.darkThemeMode) {
        case (.dark, .black):
            return CatbirdSRGBColor.trueBlackBackground.swiftUIColor
        case (.dark, .dim):
            return CatbirdSRGBColor.dimBackground.swiftUIColor
        default:
            #if os(iOS)
            return Color(.systemBackground)
            #elseif os(macOS)
            return Color(.windowBackgroundColor)
            #endif
        }
    }
    
    /// Secondary background color that adapts to theme (`Brand.color.dim.surfaceContainer` / `Brand.color.trueBlack.surfaceContainer`).
    static func dynamicSecondaryBackground(_ themeManager: ThemeManager, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeManager.effectiveColorScheme(for: currentScheme)
        
        switch (colorScheme, themeManager.darkThemeMode) {
        case (.dark, .black):
            return CatbirdSRGBColor.trueBlackSurfaceContainer.swiftUIColor
        case (.dark, .dim):
            return CatbirdSRGBColor.dimSurfaceContainer.swiftUIColor
        default:
            return Color(platformColor: PlatformColor.platformSecondarySystemBackground)
        }
    }
    
    /// Tertiary background color that adapts to theme (`Brand.color.dim.surfaceContainerHigh` / `Brand.color.trueBlack.surfaceContainerHigh`).
    static func dynamicTertiaryBackground(_ themeManager: ThemeManager, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeManager.effectiveColorScheme(for: currentScheme)
        
        switch (colorScheme, themeManager.darkThemeMode) {
        case (.dark, .black):
            return CatbirdSRGBColor.trueBlackSurfaceContainerHigh.swiftUIColor
        case (.dark, .dim):
            return CatbirdSRGBColor.dimSurfaceContainerHigh.swiftUIColor
        default:
            return Color(platformColor: PlatformColor.platformTertiarySystemBackground)
        }
    }
    
    /// Grouped background color for list backgrounds
    static func dynamicGroupedBackground(_ themeManager: ThemeManager, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeManager.effectiveColorScheme(for: currentScheme)
        
        switch (colorScheme, themeManager.darkThemeMode) {
        case (.dark, .black):
            return CatbirdSRGBColor.trueBlackBackground.swiftUIColor
        case (.dark, .dim):
            return CatbirdSRGBColor.dimBackground.swiftUIColor
        default:
            #if os(iOS)
            return Color(.systemGroupedBackground)
            #elseif os(macOS)
            return Color(.windowBackgroundColor)
            #endif
        }
    }
    
    /// Row background for a grouped list (a `Form`) drawn over `dynamicGroupedBackground`: the
    /// system's grouped row color in light mode, and a raised card above the Dim or Black background.
    static func dynamicGroupedRowBackground(_ themeManager: ThemeManager, currentScheme: ColorScheme) -> Color {
        guard themeManager.effectiveColorScheme(for: currentScheme) == .dark else {
            return Color(platformColor: PlatformColor.platformSecondarySystemGroupedBackground)
        }
        return elevatedBackground(themeManager, elevation: .low, currentScheme: currentScheme)
    }
    
    // MARK: - Elevated Backgrounds (with hierarchy)
    
    /// Elevated background with proper hierarchy for depth (`Brand.color.dim` / `Brand.color.trueBlack`).
    static func elevatedBackground(_ themeManager: ThemeManager, elevation: ColorElevation = .low, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeManager.effectiveColorScheme(for: currentScheme)
        guard colorScheme == .dark else {
            return lightElevatedBackground(elevation)
        }
        return darkElevatedBackground(elevation, isTrueBlack: themeManager.darkThemeMode == .black)
    }

    private static func lightElevatedBackground(_ elevation: ColorElevation) -> Color {
        switch elevation {
        case .base:
            return systemBackground
        case .low, .medium:
            return secondarySystemBackground
        case .high, .modal, .popover:
            return tertiarySystemBackground
        }
    }

    private static func darkElevatedBackground(_ elevation: ColorElevation, isTrueBlack: Bool) -> Color {
        switch (isTrueBlack, elevation) {
        case (true, .base): return CatbirdSRGBColor.trueBlackBackground.swiftUIColor
        case (true, .low): return CatbirdSRGBColor.trueBlackSurface.swiftUIColor
        case (true, .medium): return CatbirdSRGBColor.trueBlackSurfaceContainer.swiftUIColor
        case (true, .high), (true, .modal), (true, .popover): return CatbirdSRGBColor.trueBlackSurfaceContainerHigh.swiftUIColor
        case (false, .base): return CatbirdSRGBColor.dimBackground.swiftUIColor
        case (false, .low): return CatbirdSRGBColor.dimSurface.swiftUIColor
        case (false, .medium): return CatbirdSRGBColor.dimSurfaceContainer.swiftUIColor
        case (false, .high), (false, .modal), (false, .popover): return CatbirdSRGBColor.dimSurfaceContainerHigh.swiftUIColor
        }
    }
    
    // MARK: - Text Colors
    
    /// Dynamic text color with proper contrast for readability
    static func dynamicText(_ themeManager: ThemeManager, style: TextStyle = .primary, currentScheme: ColorScheme, increaseContrast: Bool = false) -> Color {
        let theme = CatbirdThemeColors.resolve(
            themeManager: themeManager,
            colorScheme: currentScheme,
            contrast: increaseContrast ? .increased : .standard
        )
        let role: CatbirdTextRoleColor = {
            switch style {
            case .primary: return .primary
            case .secondary: return .secondary
            case .tertiary: return .tertiary
            case .disabled: return .disabled
            }
        }()
        return theme.text(role)
    }
    
    // MARK: - Separator Colors
    
    /// Dynamic separator color
    static func dynamicSeparator(_ themeManager: ThemeManager, currentScheme: ColorScheme, increaseContrast: Bool = false) -> Color {
        let theme = CatbirdThemeColors.resolve(
            themeManager: themeManager,
            colorScheme: currentScheme,
            contrast: increaseContrast ? .increased : .standard
        )
        return theme.border(increaseContrast ? .prominent : .subtle)
    }
    
    // MARK: - Border Colors
    
    /// Dynamic border color for cards and containers
    static func dynamicBorder(_ themeManager: ThemeManager, isProminent: Bool = false, currentScheme: ColorScheme, increaseContrast: Bool = false) -> Color {
        let theme = CatbirdThemeColors.resolve(
            themeManager: themeManager,
            colorScheme: currentScheme,
            contrast: increaseContrast ? .increased : .standard
        )
        return theme.border(isProminent || increaseContrast ? .prominent : .subtle)
    }
    
    // MARK: - Special Purpose Colors
    
    /// Glass overlay color for blur effects
    static func glassOverlay(_ themeManager: ThemeManager, intensity: GlassIntensity = .medium, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeManager.effectiveColorScheme(for: currentScheme)
        
        if colorScheme == .dark && themeManager.darkThemeMode == .black {
            // No glass effect in true black mode
            return Color.clear
        }
        
        switch intensity {
        case .subtle:
            return Color.white.opacity(0.05)
        case .medium:
            return Color.white.opacity(0.08)
        case .strong:
            return Color.white.opacity(0.12)
        }
    }
    
    /// Shadow color that adapts to theme
    static func dynamicShadow(_ themeManager: ThemeManager, currentScheme: ColorScheme) -> Color {
        CatbirdThemeColors.resolve(themeManager: themeManager, colorScheme: currentScheme).shadowColor()
    }
    
    // MARK: - Cross-Platform System Colors

    static var systemBackground: Color { Color(platformColor: PlatformColor.platformSystemBackground) }
    static var secondarySystemBackground: Color { Color(platformColor: PlatformColor.platformSecondarySystemBackground) }
    static var tertiarySystemBackground: Color { Color(platformColor: PlatformColor.platformTertiarySystemBackground) }
    static var systemGroupedBackground: Color { Color(platformColor: PlatformColor.platformSystemGroupedBackground) }
    static var label: Color { Color(platformColor: PlatformColor.platformLabel) }
    static var secondaryLabel: Color { Color(platformColor: PlatformColor.platformSecondaryLabel) }
    static var tertiaryLabel: Color { Color(platformColor: PlatformColor.platformTertiaryLabel) }
    static var quaternaryLabel: Color { Color(platformColor: PlatformColor.platformQuaternaryLabel) }
    static var systemFill: Color { Color(platformColor: PlatformColor.platformSystemFill) }
    static var quaternarySystemFill: Color { Color(platformColor: PlatformColor.platformQuaternarySystemFill) }
    static var systemBlue: Color { Color(platformColor: PlatformColor.platformSystemBlue) }
    static var systemRed: Color { Color(platformColor: PlatformColor.platformSystemRed) }
    static var systemGreen: Color { Color(platformColor: PlatformColor.platformSystemGreen) }
    static var systemOrange: Color { Color(platformColor: PlatformColor.platformSystemOrange) }
    static var systemYellow: Color { Color(platformColor: PlatformColor.platformSystemYellow) }
    static var systemPink: Color { Color(platformColor: PlatformColor.platformSystemPink) }
    static var systemPurple: Color { Color(platformColor: PlatformColor.platformSystemPurple) }
    static var systemTeal: Color { Color(platformColor: PlatformColor.platformSystemTeal) }
    static var systemIndigo: Color { Color(platformColor: PlatformColor.platformSystemIndigo) }
    static var systemBrown: Color { Color(platformColor: PlatformColor.platformSystemBrown) }
    static var systemGray: Color { Color(platformColor: PlatformColor.platformSystemGray) }
    static var systemGray2: Color { Color(platformColor: PlatformColor.platformSystemGray2) }
    static var systemGray3: Color { Color(platformColor: PlatformColor.platformSystemGray3) }
    static var systemGray4: Color { Color(platformColor: PlatformColor.platformSystemGray4) }
    static var systemGray5: Color { Color(platformColor: PlatformColor.platformSystemGray5) }
    static var systemGray6: Color { Color(platformColor: PlatformColor.platformSystemGray6) }
    static var separator: Color { Color(platformColor: PlatformColor.platformSeparator) }
    static var opaqueSeparator: Color { Color(platformColor: PlatformColor.platformOpaqueSeparator) }
}

// MARK: - Theme Color Cache

/// Performance optimization: Cache calculated colors with lock-based thread safety
/// Uses OSAllocatedUnfairLock for minimal blocking (nanoseconds) - much faster than DispatchQueue.sync
class ThemeColorCache {
    static let shared = ThemeColorCache()

    private var cache: [String: Color] = [:]
    private let lock = OSAllocatedUnfairLock()

    func color(for key: String, generator: () -> Color) -> Color {
        let cached: Color? = lock.withLock { cache[key] }
        if let cached = cached {
            return cached
        }

        let color = generator()
        lock.withLock { cache[key] = color }
        return color
    }

    func invalidate() {
        lock.withLock { cache.removeAll() }
    }

    /// Selectively invalidate cache entries for a specific theme
    func invalidateTheme(_ theme: String) {
        lock.withLock {
            cache = cache.filter { !$0.key.hasPrefix(theme) && !$0.key.hasPrefix("dynamic") }
        }
    }
}

// MARK: - Accessibility Color Extensions

extension Color {
    /// Adaptive background color that respects contrast settings
    static func adaptiveBackground(appState: AppState?, defaultColor: Color) -> Color {
        let increaseContrast = appState?.appSettings.effectiveIncreaseContrast ?? false
        return increaseContrast ? defaultColor.opacity(0.95) : defaultColor
    }
    
    /// Adaptive foreground color that respects contrast settings
    static func adaptiveForeground(appState: AppState?, defaultColor: Color) -> Color {
        let increaseContrast = appState?.appSettings.effectiveIncreaseContrast ?? false
        return increaseContrast ? .primary : defaultColor
    }
    
    /// Adaptive border color that respects contrast settings
    static func adaptiveBorder(appState: AppState?) -> Color {
        let increaseContrast = appState?.appSettings.effectiveIncreaseContrast ?? false
        return increaseContrast ? .primary.opacity(0.3) : .gray.opacity(0.2)
    }
    
    /// Adaptive text color that respects contrast settings
    static func adaptiveText(appState: AppState?, themeManager: ThemeManager, style: TextStyle = .primary, currentScheme: ColorScheme) -> Color {
        let increaseContrast = appState?.appSettings.effectiveIncreaseContrast ?? false
        return dynamicText(themeManager, style: style, currentScheme: currentScheme, increaseContrast: increaseContrast)
    }

    /// Adaptive text color variant that accepts AppSettings directly
    static func adaptiveText(appSettings: AppSettings?, themeManager: ThemeManager, style: TextStyle = .primary, currentScheme: ColorScheme) -> Color {
        let increaseContrast = appSettings?.effectiveIncreaseContrast ?? false
        return dynamicText(themeManager, style: style, currentScheme: currentScheme, increaseContrast: increaseContrast)
    }
    
    /// Adaptive border color that respects theme and contrast settings
    static func adaptiveBorder(appState: AppState?, themeManager: ThemeManager, isProminent: Bool = false, currentScheme: ColorScheme) -> Color {
        let increaseContrast = appState?.appSettings.effectiveIncreaseContrast ?? false
        return dynamicBorder(themeManager, isProminent: isProminent, currentScheme: currentScheme, increaseContrast: increaseContrast)
    }
    
    /// Adaptive separator color that respects contrast settings
    static func adaptiveSeparator(appState: AppState?, themeManager: ThemeManager, currentScheme: ColorScheme) -> Color {
        let increaseContrast = appState?.appSettings.effectiveIncreaseContrast ?? false
        return dynamicSeparator(themeManager, currentScheme: currentScheme, increaseContrast: increaseContrast)
    }
}

// MARK: - UIColor / NSColor Extensions

#if os(iOS)
extension UIColor {
    
    /// Convert our theme system colors to UIColor for UIKit components
    static func themed(_ color: (ThemeManager) -> Color, with themeManager: ThemeManager) -> UIColor {
        return UIColor(color(themeManager))
    }
    
    /// Helper to create dynamic colors that respond to theme changes
    static func dynamicThemed(
        light: @escaping () -> UIColor,
        dark: @escaping (ThemeManager.DarkThemeMode) -> UIColor
    ) -> UIColor {
        return UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return dark(.dim)
            } else {
                return light()
            }
        }
    }
}
#elseif os(macOS)
extension NSColor {
    
    /// Convert our theme system colors to NSColor for macOS components
    static func themed(_ color: (ThemeManager) -> Color, with themeManager: ThemeManager) -> NSColor {
        return NSColor(color(themeManager))
    }
    
    /// Helper to create dynamic colors that respond to theme changes
    static func dynamicThemed(
        light: @escaping () -> NSColor,
        dark: @escaping (ThemeManager.DarkThemeMode) -> NSColor
    ) -> NSColor {
        return NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return dark(.dim)
            } else {
                return light()
            }
        }
    }
}
#endif
