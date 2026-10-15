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
  let kerning: CGFloat
  /// The size of the options ellipsis glyph. The SwiftUI row draws it as an `Image` in the
  /// environment's font, the system body style, so its size follows Dynamic Type but not the
  /// app's own font settings.
  let optionsGlyphSize: CGSize
  /// Changes whenever any input above changes; part of every layout cache key.
  let generationKey: Int

  @MainActor
  static func resolved(fontManager: FontManager, boldText: Bool) -> FeedRowTypography {
    let contentSize = UIApplication.shared.preferredContentSizeCategory
    var hasher = Hasher()
    hasher.combine(ObjectIdentifier(fontManager))
    hasher.combine(fontManager.generation)
    hasher.combine(boldText)
    hasher.combine(contentSize.rawValue)
    let key = hasher.finalize()
    if let cached = cache, cached.generationKey == key { return cached }

    let body = AppUIFont.font(
      fontManager, size: Typography.Size.body, weight: boldText ? .semibold : .regular, textStyle: .body)
    let resolved = FeedRowTypography(
      body: body,
      name: AppUIFont.font(
        fontManager, size: Typography.Size.headline, weight: boldText ? .bold : .semibold, textStyle: .headline),
      metadata: AppUIFont.font(
        fontManager, size: Typography.Size.body, weight: boldText ? .semibold : .regular, textStyle: .body),
      bodyLineSpacing: fontManager.getLineSpacing(for: body.pointSize),
      kerning: fontManager.letterSpacingValue,
      optionsGlyphSize: optionsGlyphSize(contentSize: contentSize),
      generationKey: key)
    cache = resolved
    return resolved
  }

  /// The options glyph's symbol configuration: the system body style at `contentSize`.
  static func optionsGlyphConfiguration(contentSize: UIContentSizeCategory) -> UIImage.SymbolConfiguration {
    UIImage.SymbolConfiguration(
      font: UIFont.preferredFont(
        forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: contentSize)))
  }

  /// The size of the ellipsis glyph drawn with `optionsGlyphConfiguration(contentSize:)`.
  static func optionsGlyphSize(contentSize: UIContentSizeCategory) -> CGSize {
    UIImage(systemName: "ellipsis", withConfiguration: optionsGlyphConfiguration(contentSize: contentSize))?.size
      ?? .zero
  }

  @MainActor private static var cache: FeedRowTypography?
}
#endif
