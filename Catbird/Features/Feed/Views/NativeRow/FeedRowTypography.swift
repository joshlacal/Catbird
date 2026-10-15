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
      generationKey: key)
    cache = resolved
    return resolved
  }

  @MainActor private static var cache: FeedRowTypography?
}
#endif
