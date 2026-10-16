#if os(iOS)
import UIKit

// MARK: - Feed Row Typography

/// Fonts and text metrics for a native feed row, resolved once per font-settings change.
/// `@unchecked Sendable`: `UIFont` is immutable and thread-safe; layouts are computed off the main actor.
struct FeedRowTypography: Equatable, @unchecked Sendable {
  let body: UIFont
  let name: UIFont
  let metadata: UIFont
  let bodyLineSpacing: CGFloat
  /// Where the body, name and metadata (handle and time) lines draw at "Tight", which the hosted
  /// row's `appFont` draws at a constant line height; nil at Normal and Relaxed.
  let bodyLine: AppLineHeightPlacement?
  let nameLine: AppLineHeightPlacement?
  let metadataLine: AppLineHeightPlacement?
  let kerning: CGFloat
  /// The size of the options ellipsis glyph. The SwiftUI row draws it as an `Image` in the
  /// environment's font, the system body style, so its size follows Dynamic Type but not the
  /// app's own font settings.
  let optionsGlyphSize: CGSize
  /// The line height of the header's "·" separator. The SwiftUI header draws it as a `Text` in the
  /// environment's font, the system body style, so it follows Dynamic Type but not the app's font
  /// settings, and from Extra Extra Extra Large up it is the header's tallest line. At "Tight" it
  /// takes the constant line height like the time beside it (`appLineSpacing()`).
  let separatorLineHeight: CGFloat
  /// Changes whenever any input above changes; part of every layout cache key.
  let generationKey: Int

  /// `contentSize` is the feed's trait collection's, which `FontManager` caps at the app's Dynamic
  /// Type limit: the hosted row's environment font, and with it the options glyph and the "·"
  /// separator, follows it rather than the system setting.
  @MainActor
  static func resolved(fontManager: FontManager, boldText: Bool, contentSize: UIContentSizeCategory) -> FeedRowTypography {
    // The settings themselves, not only the manager's identity and generation: a manager
    // allocated where a released one lived starts at the same generation, and must not be served
    // the released manager's fonts (for example after an account switch). The design is hashed as
    // its UIKit value; describing the SwiftUI `Font.Design` as a string goes through runtime
    // reflection.
    var hasher = Hasher()
    hasher.combine(ObjectIdentifier(fontManager))
    hasher.combine(fontManager.generation)
    hasher.combine(fontManager.sizeScale)
    hasher.combine(AppUIFont.systemDesign(fontManager.fontDesign).rawValue)
    hasher.combine(fontManager.dynamicTypeEnabled)
    hasher.combine(fontManager.dynamicTypeLimit?.uiContentSizeCategory.rawValue)
    hasher.combine(fontManager.lineSpacingMultiplier)
    hasher.combine(fontManager.lineHeightFactor)
    hasher.combine(fontManager.letterSpacingValue)
    hasher.combine(boldText)
    hasher.combine(contentSize.rawValue)
    let key = hasher.finalize()
    if let cached = cache, cached.generationKey == key { return cached }

    let body = AppUIFont.font(
      fontManager, size: Typography.Size.body, weight: boldText ? .semibold : .regular, textStyle: .body)
    let name = AppUIFont.font(
      fontManager, size: Typography.Size.headline, weight: boldText ? .bold : .semibold, textStyle: .headline)
    let metadata = AppUIFont.font(
      fontManager, size: Typography.Size.body, weight: boldText ? .semibold : .regular, textStyle: .body)
    let lineHeightFactor = fontManager.lineHeightFactor
    let resolved = FeedRowTypography(
      body: body,
      name: name,
      metadata: metadata,
      bodyLineSpacing: bodyLineSpacing(fontManager: fontManager),
      bodyLine: lineHeightFactor.map { .resolve(font: body, factor: $0) },
      nameLine: lineHeightFactor.map { .resolve(font: name, factor: $0) },
      metadataLine: lineHeightFactor.map { .resolve(font: metadata, factor: $0) },
      kerning: fontManager.letterSpacingValue,
      optionsGlyphSize: optionsGlyphSize(contentSize: contentSize),
      separatorLineHeight: separatorLineHeight(contentSize: contentSize, lineHeightFactor: lineHeightFactor),
      generationKey: key)
    cache = resolved
    return resolved
  }

  /// The line spacing the hosted row's `Text` gets from `AppFontModifier`: the spacing of the app's
  /// body size scaled by the line-spacing multiplier, the same at every Dynamic Type size. "Tight"
  /// adds none; it tightens the lines with `bodyLine`.
  @MainActor
  static func bodyLineSpacing(fontManager: FontManager) -> CGFloat {
    fontManager.roleLineSpacing
  }

  /// The environment's font in the SwiftUI row: the system body style at `contentSize`.
  static func environmentFont(contentSize: UIContentSizeCategory) -> UIFont {
    UIFont.preferredFont(
      forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: contentSize))
  }

  /// The options glyph's symbol configuration: the system body style at `contentSize`.
  static func optionsGlyphConfiguration(contentSize: UIContentSizeCategory) -> UIImage.SymbolConfiguration {
    UIImage.SymbolConfiguration(font: environmentFont(contentSize: contentSize))
  }

  /// The line height of the header's "·" separator, drawn in the system body style at `contentSize`:
  /// the font's own, or at "Tight" (`lineHeightFactor`) the constant line height.
  static func separatorLineHeight(contentSize: UIContentSizeCategory, lineHeightFactor: CGFloat? = nil) -> CGFloat {
    let font = environmentFont(contentSize: contentSize)
    return lineHeightFactor.map { AppLineHeightPlacement.resolve(font: font, factor: $0).height(lines: 1) }
      ?? font.lineHeight
  }

  /// The size of the ellipsis glyph drawn with `optionsGlyphConfiguration(contentSize:)`.
  static func optionsGlyphSize(contentSize: UIContentSizeCategory) -> CGSize {
    UIImage(systemName: "ellipsis", withConfiguration: optionsGlyphConfiguration(contentSize: contentSize))?.size
      ?? .zero
  }

  @MainActor private static var cache: FeedRowTypography?
}
#endif
