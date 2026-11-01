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

// MARK: - App Line Height

/// Where UIKit draws text that has a constant line height, so it lands where SwiftUI's `Text`
/// draws it under `View.lineHeight(.multiple(factor:))` (`AppLineHeightModifier`).
///
/// Both renderers put consecutive baselines `lineHeight` apart and make `n` lines `n × lineHeight`
/// tall (SwiftUI rounds the total up to a whole pixel, as it does every text height). They differ
/// in where the first baseline sits: SwiftUI puts it one point size below the top of the text,
/// whatever the font's ascent and the line height; TextKit (`UILabel`, `boundingRect`,
/// `UITextView`) puts it one descent above the bottom of the first line. `glyphOffset` is how far
/// UIKit's text moves down to draw where SwiftUI does. Ink outside the lines (accents above the
/// first, descenders below the last) is drawn in both: `UILabel` draws past its bounds.
///
/// The text is assumed to have no line spacing, as "Tight" adds none.
struct AppLineHeightPlacement: Equatable, Sendable {
  /// The distance between two baselines.
  let lineHeight: CGFloat
  let glyphOffset: CGFloat

  static func resolve(font: UIFont, factor: CGFloat) -> AppLineHeightPlacement {
    placement(lineHeight: factor * font.pointSize, font: font)
  }

  /// `font.descender` is negative: TextKit's first baseline is `lineHeight + descender` down.
  private static func placement(lineHeight: CGFloat, font: UIFont) -> AppLineHeightPlacement {
    AppLineHeightPlacement(lineHeight: lineHeight, glyphOffset: font.pointSize - (lineHeight + font.descender))
  }

  /// The height of `lines` lines with no line spacing.
  func height(lines: Int) -> CGFloat {
    CGFloat(lines) * lineHeight
  }

  /// Gives every line of `paragraph` this line height.
  func apply(to paragraph: NSMutableParagraphStyle) {
    paragraph.minimumLineHeight = lineHeight
    paragraph.maximumLineHeight = lineHeight
  }

  /// The frame of a `UILabel` that draws the lines a SwiftUI `Text` at `textFrame` draws: lower by
  /// `glyphOffset`, and higher by half of what `textFrame` adds to its whole lines. `Text` draws
  /// from the top of a frame rounded up to whole pixels, where `UILabel` centers its text.
  func labelFrame(textFrame: CGRect) -> CGRect {
    let lines = (textFrame.height / lineHeight + 0.001).rounded(.down)
    let excess = max(0, textFrame.height - lines * lineHeight)
    return textFrame.offsetBy(dx: 0, dy: glyphOffset - excess / 2)
  }
}

extension AppLineHeightPlacement {
  /// The placement `text` was built with: the constant line height of its first paragraph and
  /// the font it starts with. Nil when its lines take their fonts' own heights.
  init?(of text: NSAttributedString?) {
    guard let text, text.length > 0,
      let paragraph = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
      paragraph.maximumLineHeight > 0, paragraph.minimumLineHeight == paragraph.maximumLineHeight,
      let font = text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
    else { return nil }
    self = Self.placement(lineHeight: paragraph.maximumLineHeight, font: font)
  }
}
#endif
