import CatbirdBrand
import Foundation
import SwiftUI
import Testing
#if os(iOS)
import UIKit
#endif
@testable import Catbird

@Suite("Brand token parity and WCAG contrast")
@MainActor
struct BrandTokenParityTests {
  private struct AppearanceMode: Sendable {
    let name: String
    let colorScheme: ColorScheme
    let darkThemeMode: ThemeManager.DarkThemeMode
  }

  private static let modes: [AppearanceMode] = [
    AppearanceMode(name: "light", colorScheme: .light, darkThemeMode: .dim),
    AppearanceMode(name: "dim", colorScheme: .dark, darkThemeMode: .dim),
    AppearanceMode(name: "trueBlack", colorScheme: .dark, darkThemeMode: .black)
  ]

  // MARK: - Brand.color Surface Parity

  @Test("Dim surfaces and text match Brand.color.dim exactly")
  func dimSurfacesMatchBrand() {
    let dim = Brand.color.dim
    let resolved = CatbirdThemeColors.resolve(
      colorScheme: .dark,
      darkThemeMode: .dim,
      accent: .catbird,
      isHighContrast: false
    )

    #expect(resolved.isDim)
    #expect(!resolved.isTrueBlack)
    #expect(resolved.surfaceSRGB(.canvas).hexString == dim.background.uppercased())
    #expect(resolved.surfaceSRGB(.grouped).hexString == dim.background.uppercased())
    #expect(resolved.surfaceSRGB(.card).hexString == dim.surface.uppercased())
    #expect(resolved.surfaceSRGB(.elevated).hexString == dim.surfaceContainer.uppercased())
    #expect(resolved.textSRGB(.primary).hexString == dim.onSurface.uppercased())
    #expect(resolved.textSRGB(.secondary).hexString == dim.onSurfaceVariant.uppercased())

    #if os(iOS)
    let manager = ThemeManager(fontManager: FontManager())
    manager.darkThemeMode = .dim
    let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
    #expect(Self.resolvedHex(.dynamicBackground(manager, currentScheme: .dark), traits: darkTraits) == dim.background.uppercased())
    #expect(Self.resolvedHex(.dynamicGroupedBackground(manager, currentScheme: .dark), traits: darkTraits) == dim.background.uppercased())
    #expect(Self.resolvedHex(.elevatedBackground(manager, elevation: .low, currentScheme: .dark), traits: darkTraits) == dim.surface.uppercased())
    #expect(Self.resolvedHex(.dynamicGroupedRowBackground(manager, currentScheme: .dark), traits: darkTraits) == dim.surface.uppercased())
    #expect(Self.resolvedHex(.dynamicSecondaryBackground(manager, currentScheme: .dark), traits: darkTraits) == dim.surfaceContainer.uppercased())
    #expect(Self.resolvedHex(.dynamicTertiaryBackground(manager, currentScheme: .dark), traits: darkTraits) == dim.surfaceContainerHigh.uppercased())
    #expect(Self.resolvedHex(manager.dimBackgroundColor, traits: darkTraits) == dim.background.uppercased())
    #endif
  }

  @Test("True Black surfaces and text match Brand.color.trueBlack exactly")
  func trueBlackSurfacesMatchBrand() {
    let black = Brand.color.trueBlack
    let resolved = CatbirdThemeColors.resolve(
      colorScheme: .dark,
      darkThemeMode: .black,
      accent: .catbird,
      isHighContrast: false
    )

    #expect(resolved.isTrueBlack)
    #expect(!resolved.isDim)
    #expect(resolved.surfaceSRGB(.canvas).hexString == black.background.uppercased())
    #expect(resolved.surfaceSRGB(.grouped).hexString == black.background.uppercased())
    #expect(resolved.surfaceSRGB(.card).hexString == black.surface.uppercased())
    #expect(resolved.surfaceSRGB(.elevated).hexString == black.surfaceContainer.uppercased())
    #expect(resolved.textSRGB(.primary).hexString == black.onSurface.uppercased())
    #expect(resolved.textSRGB(.secondary).hexString == black.onSurfaceVariant.uppercased())
    #expect(resolved.shadowColor() == .clear)

    #if os(iOS)
    let manager = ThemeManager(fontManager: FontManager())
    manager.darkThemeMode = .black
    let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
    #expect(Self.resolvedHex(.dynamicBackground(manager, currentScheme: .dark), traits: darkTraits) == black.background.uppercased())
    #expect(Self.resolvedHex(.dynamicGroupedBackground(manager, currentScheme: .dark), traits: darkTraits) == black.background.uppercased())
    #expect(Self.resolvedHex(.elevatedBackground(manager, elevation: .low, currentScheme: .dark), traits: darkTraits) == black.surface.uppercased())
    #expect(Self.resolvedHex(.dynamicGroupedRowBackground(manager, currentScheme: .dark), traits: darkTraits) == black.surface.uppercased())
    #expect(Self.resolvedHex(.dynamicSecondaryBackground(manager, currentScheme: .dark), traits: darkTraits) == black.surfaceContainer.uppercased())
    #expect(Self.resolvedHex(.dynamicTertiaryBackground(manager, currentScheme: .dark), traits: darkTraits) == black.surfaceContainerHigh.uppercased())
    #endif
  }

  @Test("Semantic colors match Brand.color.semantic")
  func semanticColorsMatchBrand() {
    let semantic = Brand.color.semantic
    for mode in Self.modes {
      let theme = CatbirdThemeColors.resolve(
        colorScheme: mode.colorScheme,
        darkThemeMode: mode.darkThemeMode,
        accent: .catbird
      )
      #expect(theme.semanticSRGB(.success).hexString == semantic.success.uppercased())
      #expect(theme.semanticSRGB(.warning).hexString == semantic.warning.uppercased())
      #expect(theme.semanticSRGB(.danger).hexString == semantic.danger.uppercased())
      #expect(theme.semanticSRGB(.encryptionShield).hexString == semantic.encryptionShield.uppercased())
    }
  }

  // MARK: - Dark-Mode Accent Resolution

  @Test("Dark mode resolves accentDark from Brand.color for all 7 palettes")
  func darkModeResolvesAccentDark() {
    let manager = ThemeManager(fontManager: FontManager())
    for accent in AccentColorOption.allCases {
      manager.currentAccentColor = accent
      let expectedDarkHex = accent.brandPalette.accentDark.uppercased()
      let resolvedDim = CatbirdThemeColors.resolve(
        themeManager: manager,
        colorScheme: .dark
      )
      #expect(
        resolvedDim.accentChromeSRGB.hexString == expectedDarkHex,
        "\(accent.rawValue): dark chrome must match Brand.color.accentDark (\(expectedDarkHex)), got \(resolvedDim.accentChromeSRGB.hexString)"
      )
      #expect(
        accent.chromeSRGB(for: .dark).hexString == expectedDarkHex,
        "\(accent.rawValue): AccentColorOption.chromeSRGB(for: .dark) must resolve accentDark"
      )
      #if os(iOS)
      let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
      let dynamicDark = accent.dynamicUIColor.resolvedColor(with: darkTraits)
      #expect(
        Self.hexString(from: dynamicDark) == expectedDarkHex,
        "\(accent.rawValue): dynamicUIColor in dark traits must resolve \(expectedDarkHex)"
      )
      #endif
    }
  }

  // MARK: - Full 7 Palettes × 3 Modes WCAG AA Contrast Matrix

  @Test("All 7 accent palettes × 3 modes pass WCAG AA contrast invariants")
  func allPalettesAndModesMeetWCAG() {
    for mode in Self.modes {
      for accent in AccentColorOption.allCases {
        assertWCAGInvariants(accent: accent, mode: mode)
      }
    }
  }

  private func assertWCAGInvariants(accent: AccentColorOption, mode: AppearanceMode) {
    let theme = CatbirdThemeColors.resolve(
      colorScheme: mode.colorScheme,
      darkThemeMode: mode.darkThemeMode,
      accent: accent,
      isHighContrast: false
    )
    let canvas = theme.surfaceSRGB(.canvas)
    let card = theme.surfaceSRGB(.card)
    let label = "\(accent.rawValue)/\(mode.name)"

    assertContrast(theme.accentTextSRGB, on: canvas, minimum: 4.5, context: "\(label) accentText/canvas")
    assertContrast(theme.accentTextSRGB, on: card, minimum: 4.5, context: "\(label) accentText/card")
    assertContrast(theme.accentChromeSRGB, on: canvas, minimum: 3.0, context: "\(label) accentChrome/canvas")
    assertContrast(theme.accentChromeSRGB, on: card, minimum: 3.0, context: "\(label) accentChrome/card")
    assertContrast(theme.onAccentSRGB, on: theme.accentChromeSRGB, minimum: 4.5, context: "\(label) onAccent/accentChrome")
    assertContrast(theme.textSRGB(.primary), on: canvas, minimum: 4.5, context: "\(label) primaryText/canvas")
    assertContrast(theme.textSRGB(.primary), on: card, minimum: 4.5, context: "\(label) primaryText/card")
    assertContrast(theme.textSRGB(.secondary), on: canvas, minimum: 4.5, context: "\(label) secondaryText/canvas")
    assertContrast(theme.textSRGB(.secondary), on: card, minimum: 4.5, context: "\(label) secondaryText/card")
  }

  private func assertContrast(
    _ foreground: CatbirdSRGBColor,
    on background: CatbirdSRGBColor,
    minimum: Double,
    context: String
  ) {
    let ratio = Self.wcagContrastRatio(foreground, background)
    #expect(
      ratio >= minimum,
      "\(context): \(foreground.hexString) on \(background.hexString) = \(String(format: "%.2f", ratio)):1 (< \(minimum))"
    )
  }

  // MARK: - Independent WCAG 2.1 Calculator

  private static func wcagRelativeLuminance(_ color: CatbirdSRGBColor) -> Double {
    func channel(_ value: Double) -> Double {
      value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
  }

  private static func wcagContrastRatio(_ first: CatbirdSRGBColor, _ second: CatbirdSRGBColor) -> Double {
    let lighter = max(wcagRelativeLuminance(first), wcagRelativeLuminance(second))
    let darker = min(wcagRelativeLuminance(first), wcagRelativeLuminance(second))
    return (lighter + 0.05) / (darker + 0.05)
  }

  #if os(iOS)
  private static func resolvedHex(_ color: Color, traits: UITraitCollection) -> String {
    let resolved = UIColor(color).resolvedColor(with: traits)
    return hexString(from: resolved)
  }

  private static func hexString(from uiColor: UIColor) -> String {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    let redByte = Int((Double(red) * 255.0).rounded())
    let greenByte = Int((Double(green) * 255.0).rounded())
    let blueByte = Int((Double(blue) * 255.0).rounded())
    return String(format: "#%02X%02X%02X", redByte, greenByte, blueByte)
  }
  #endif
}
