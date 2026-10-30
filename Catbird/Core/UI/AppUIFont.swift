#if os(iOS)
import SwiftUI
import UIKit

// MARK: - App UIFont

/// UIKit fonts resolved from the app's font settings the same way `appFont` resolves SwiftUI fonts:
/// size scale, font design, monospaced digits, and Dynamic Type capped at the user's limit.
enum AppUIFont {
  @MainActor
  static func font(
    _ fontManager: FontManager, size: CGFloat, weight: UIFont.Weight,
    textStyle: UIFont.TextStyle, monospacedDigits: Bool = false
  ) -> UIFont {
    let baseSize = size * fontManager.sizeScale
    var descriptor = UIFont.systemFont(ofSize: baseSize, weight: weight).fontDescriptor
    if let designed = descriptor.withDesign(systemDesign(fontManager.fontDesign)) {
      descriptor = designed
    }
    if monospacedDigits {
      descriptor = descriptor.addingAttributes([
        .featureSettings: [[
          UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
          UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
        ]]
      ])
    }
    let font = UIFont(descriptor: descriptor, size: baseSize)
    guard fontManager.dynamicTypeEnabled else { return font }
    let metrics = UIFontMetrics(forTextStyle: textStyle)
    guard let limit = fontManager.dynamicTypeLimit else { return metrics.scaledFont(for: font) }
    let maximum = UIFont.preferredFont(
      forTextStyle: textStyle,
      compatibleWith: UITraitCollection(preferredContentSizeCategory: limit.uiContentSizeCategory)
    ).pointSize
    return metrics.scaledFont(for: font, maximumPointSize: maximum)
  }

  static func systemDesign(_ design: Font.Design) -> UIFontDescriptor.SystemDesign {
    switch design {
    case .serif: .serif
    case .rounded: .rounded
    case .monospaced: .monospaced
    default: .default
    }
  }
}
#endif
