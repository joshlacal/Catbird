#if os(iOS)
import UIKit

// MARK: - Trending Interstitial Typography

/// Fonts and scaled metrics of the trending interstitial, resolved the way the SwiftUI
/// presentation resolves them (`appFont`, `scaledCustomFont`, `@ScaledMetric`), once per change
/// of font settings, bold text or content size category.
/// `@unchecked Sendable`: `UIFont` and `UIImage` are immutable and thread-safe.
struct TrendingInterstitialTypography: Equatable, @unchecked Sendable {
  /// "Trending on Bluesky" / "Trending Videos": `scaledCustomFont(size: 17, weight: .bold, width: 120, relativeTo: .headline)`.
  let sectionHeading: UIFont
  /// Topic title: `scaledCustomFont(size: 18, weight: .bold, width: 120, relativeTo: .title3)`.
  let topicTitle: UIFont
  /// Category name: `appFont(AppTextRole.caption)`.
  let categoryName: UIFont
  /// Topic description and the empty-videos message: `appFont(AppTextRole.subheadline)`.
  let subheadline: UIFont
  /// Post count: `appFont(AppTextRole.caption)`.
  let caption: UIFont
  /// "Open The Vids": `appFont(size: 15, weight: .medium, relativeTo: .subheadline)`.
  let videosButton: UIFont
  /// Video author: `appFont(size: 12, weight: .medium, relativeTo: .caption)`.
  let videoAuthor: UIFont
  /// Options ellipsis glyph: `appFont(AppTextRole.subheadline)`.
  let optionsGlyph: UIFont

  /// `lineSpacing` the SwiftUI modifiers apply: role fonts and `appFont(Font)` use the body size,
  /// `appFont(size:)` uses its own size.
  let roleLineSpacing: CGFloat
  let videosButtonLineSpacing: CGFloat
  let videoAuthorLineSpacing: CGFloat
  let kerning: CGFloat

  /// `TrendingTopicCategoryMark(diameter: 28)`: `@ScaledMetric(relativeTo: .title3)`.
  let markDiameter: CGFloat
  let markIconPointSize: CGFloat
  /// `TrendingVideosSection.authorHeight` and `authorAvatarSize`.
  let videoAuthorHeight: CGFloat
  let videoAuthorAvatarSize: CGFloat
  /// The small `chevron.right` beside "Open The Vids" (`imageScale(.small)` in its font).
  let disclosureGlyph: UIImage?
  var disclosureGlyphSize: CGSize { disclosureGlyph?.size ?? .zero }
  /// `dynamicTypeSize.isAccessibilitySize`.
  let isAccessibilitySize: Bool
  /// Text frames round to device pixels at this scale.
  let displayScale: CGFloat

  /// Changes whenever any input above changes; part of every layout cache key.
  let generationKey: Int

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.generationKey == rhs.generationKey }

  @MainActor
  static func resolved(fontManager: FontManager, traits: UITraitCollection) -> TrendingInterstitialTypography {
    let category = traits.preferredContentSizeCategory
    let boldText = traits.legibilityWeight == .bold || fontManager.effectiveBoldText
    var hasher = Hasher()
    hasher.combine(ObjectIdentifier(fontManager))
    hasher.combine(fontManager.generation)
    hasher.combine(boldText)
    hasher.combine(category.rawValue)
    hasher.combine(traits.displayScale)
    let key = hasher.finalize()
    if let cached = cache, cached.generationKey == key { return cached }

    func role(_ size: CGFloat, _ weight: UIFont.Weight, _ style: UIFont.TextStyle) -> UIFont {
      AppUIFont.font(fontManager, size: size, weight: bolder(weight, boldText), textStyle: style)
    }
    func wide(_ size: CGFloat, _ style: UIFont.TextStyle) -> UIFont {
      // `FontManager.resolvedFont` for width != 100: the size preference applies, Dynamic Type
      // applies only while enabled, and neither the font design nor bold text changes the face.
      UIFont.variableSystemFont(
        size: size * fontManager.sizeScale, weightValue: 700, width: 120,
        scaledFor: fontManager.dynamicTypeEnabled ? style : nil)
    }

    let metrics = { (style: UIFont.TextStyle, value: CGFloat) in
      UIFontMetrics(forTextStyle: style).scaledValue(for: value, compatibleWith: traits)
    }
    let diameter = metrics(.title3, 28)
    let authorLine = (fontManager.dynamicTypeEnabled ? metrics(.caption1, 18) : 18) * fontManager.sizeScale
    let authorLineSpacing = fontManager.getLineSpacing(for: Typography.Size.caption)
    let bodyLineSpacing = fontManager.getLineSpacing(for: Typography.Size.body)
    let videosButton = role(Typography.Size.subheadline, .medium, .subheadline)
    let disclosure = UIImage(systemName: "chevron.right",
      withConfiguration: UIImage.SymbolConfiguration(font: videosButton, scale: .small))

    let resolved = TrendingInterstitialTypography(
      sectionHeading: wide(17, .headline),
      topicTitle: wide(18, .title3),
      categoryName: role(Typography.Size.caption, .medium, .caption1),
      subheadline: role(Typography.Size.subheadline, .medium, .subheadline),
      caption: role(Typography.Size.caption, .medium, .caption1),
      videosButton: videosButton,
      videoAuthor: role(Typography.Size.caption, .medium, .caption1),
      optionsGlyph: role(Typography.Size.subheadline, .medium, .subheadline),
      roleLineSpacing: bodyLineSpacing * fontManager.lineSpacingMultiplier,
      videosButtonLineSpacing: fontManager.getLineSpacing(for: Typography.Size.subheadline),
      videoAuthorLineSpacing: authorLineSpacing,
      kerning: fontManager.letterSpacingValue,
      markDiameter: min(diameter, 60),
      markIconPointSize: min(metrics(.title3, 14), min(diameter, 60) * 0.5),
      videoAuthorHeight: max(36, authorLine * 2 + max(0, authorLineSpacing)),
      videoAuthorAvatarSize: min(24, max(16, authorLine)),
      disclosureGlyph: disclosure,
      isAccessibilitySize: category.isAccessibilityCategory,
      displayScale: max(1, traits.displayScale),
      generationKey: key)
    cache = resolved
    return resolved
  }

  /// `AppFontModifier.adjustFontWeight`: bold text moves every weight one step heavier.
  private static func bolder(_ weight: UIFont.Weight, _ boldText: Bool) -> UIFont.Weight {
    guard boldText else { return weight }
    switch weight {
    case .ultraLight: return .light
    case .thin: return .regular
    case .light: return .medium
    case .regular, .medium: return .semibold
    case .semibold: return .bold
    case .bold: return .heavy
    case .heavy: return .black
    default: return .semibold
    }
  }

  @MainActor private static var cache: TrendingInterstitialTypography?
}
#endif
