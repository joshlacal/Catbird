#if os(iOS)
import UIKit

// MARK: - Colors

/// Colors of the trending interstitial, as dynamic `UIColor`s.
@MainActor
enum TrendingInterstitialColors {
  /// `Color.secondary.opacity(0.08)`: topic card fill.
  static let cardFill = secondary(opacity: 0.08)
  /// `Color.secondary.opacity(0.12)`: loading and fallback video thumbnails.
  static let placeholderFill = secondary(opacity: 0.12)

  private static func secondary(opacity: CGFloat) -> UIColor {
    UIColor { traits in
      let base = UIColor.secondaryLabel.resolvedColor(with: traits)
      return base.withAlphaComponent(base.cgColor.alpha * opacity)
    }
  }

  /// `Color.dynamicBackground(themeManager, currentScheme:)`: pure black or dim gray in dark mode
  /// per the theme, the system background otherwise.
  static func background(darkThemeMode: ThemeManager.DarkThemeMode) -> UIColor {
    UIColor { traits in
      guard traits.userInterfaceStyle == .dark else { return .systemBackground.resolvedColor(with: traits) }
      switch darkThemeMode {
      case .black: return UIColor(red: 0, green: 0, blue: 0, alpha: 1)
      case .dim: return UIColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1)
      }
    }
  }
}

// MARK: - Symbols

/// SF Symbol images are resolved once per configuration; the first lookup of a symbol is costly.
@MainActor
enum TrendingSymbolCache {
  private struct Key: Hashable {
    let name: String
    let pointSize: CGFloat
    let font: UIFont?
    let weight: UIImage.SymbolWeight
    let scale: UIImage.SymbolScale
    let textStyle: UIFont.TextStyle?
    let tint: TrendingTopicCategoryStyle.Tint?
  }

  private static var images: [Key: UIImage] = [:]

  /// `TrendingTopicCategoryMark`: hierarchical rendering in the category tint.
  static func categoryMark(_ name: String, pointSize: CGFloat, tint: TrendingTopicCategoryStyle.Tint) -> UIImage? {
    image(Key(name: name, pointSize: pointSize, font: nil, weight: .semibold, scale: .default, textStyle: nil, tint: tint)) {
      UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        .applying(UIImage.SymbolConfiguration(hierarchicalColor: tint.uiColor))
    }
  }

  /// A template symbol sized to `font`.
  static func symbol(_ name: String, font: UIFont, scale: UIImage.SymbolScale = .default) -> UIImage? {
    image(Key(name: name, pointSize: font.pointSize, font: font, weight: .regular, scale: scale, textStyle: nil, tint: nil)) {
      UIImage.SymbolConfiguration(font: font, scale: scale)
    }?.withRenderingMode(.alwaysTemplate)
  }

  /// A template symbol in a system text style (`.font(.title2)`, `.font(.caption.weight(.semibold))`).
  static func symbol(_ name: String, textStyle: UIFont.TextStyle, weight: UIImage.SymbolWeight = .regular) -> UIImage? {
    image(Key(name: name, pointSize: 0, font: nil, weight: weight, scale: .default, textStyle: textStyle, tint: nil)) {
      UIImage.SymbolConfiguration(textStyle: textStyle).applying(UIImage.SymbolConfiguration(weight: weight))
    }?.withRenderingMode(.alwaysTemplate)
  }

  /// Every symbol the cell shows, resolved ahead of its first appearance.
  static func prepare(typography t: TrendingInterstitialTypography, categories: [(String, TrendingTopicCategoryStyle.Tint)]) {
    for (name, tint) in categories {
      _ = categoryMark(name, pointSize: t.markIconPointSize, tint: tint)
    }
    _ = symbol("ellipsis", font: t.optionsGlyph)
    _ = symbol("play.rectangle", textStyle: .title2)
    _ = symbol("eye.slash.fill", textStyle: .title2)
    _ = symbol("play.fill", textStyle: .caption1, weight: .semibold)
    _ = symbol("person.crop.circle.fill")
    _ = symbol("eye.slash.fill")
  }

  /// A template symbol at its default configuration, scaled by its image view.
  static func symbol(_ name: String) -> UIImage? {
    image(Key(name: name, pointSize: 0, font: nil, weight: .regular, scale: .default, textStyle: nil, tint: nil)) {
      UIImage.SymbolConfiguration.unspecified
    }?.withRenderingMode(.alwaysTemplate)
  }

  private static func image(_ key: Key, configuration: () -> UIImage.SymbolConfiguration) -> UIImage? {
    if let cached = images[key] { return cached }
    guard let image = UIImage(systemName: key.name, withConfiguration: configuration()) else { return nil }
    images[key] = image
    return image
  }
}
#endif
