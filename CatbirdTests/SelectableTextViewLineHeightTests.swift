#if os(iOS)
import Testing
import UIKit
@testable import Catbird

/// The thread's main post draws in a `UITextView`. At Tight its lines have a constant line height,
/// shorter than the font's, and the text view must still hold the first line's accents and emoji
/// and the last line's descenders inside its bounds.
@MainActor
@Suite("Selectable text view line height")
struct SelectableTextViewLineHeightTests {
  private static func tightText() -> (NSAttributedString, AppLineHeightPlacement) {
    let font = UIFont.systemFont(ofSize: 17)
    let placement = AppLineHeightPlacement.resolve(font: font, factor: FontManager.tightLineHeightFactor)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    placement.apply(to: paragraph)
    let text = NSAttributedString(string: "ÁÉ 👩🏽‍💻 Ångström first line\nsecond line\nlast gjpqy", attributes: [
      .font: font, .paragraphStyle: paragraph, .foregroundColor: UIColor.black,
    ])
    return (text, placement)
  }

  /// A text view set up as `SelectableTextView.makeUIView` sets it up.
  private static func textView() -> SelectableSelfSizingTextView {
    let textView = SelectableSelfSizingTextView()
    textView.isEditable = false
    textView.isScrollEnabled = false
    textView.backgroundColor = .clear
    textView.textContainer.lineFragmentPadding = 0
    textView.textContainerInset = .zero
    return textView
  }

  @Test("The text is inset by the glyph offset, so it draws where SwiftUI's Text does")
  func insetFollowsPlacement() {
    let (text, placement) = Self.tightText()
    let textView = Self.textView()
    SelectableTextView.show(text, linePlacement: placement, in: textView)
    #expect(textView.textContainerInset == UIEdgeInsets(top: placement.glyphOffset, left: 0, bottom: 0, right: 0))
    SelectableTextView.show(text, linePlacement: nil, in: textView)
    #expect(textView.textContainerInset == .zero)
  }

  /// `UITextView` draws its lines where TextKit lays them out, inset by `textContainerInset`, and
  /// clips at its bounds: the first baseline must sit where SwiftUI's `Text` draws it, one point
  /// size down, with the font's ascent inside the view.
  @Test("The first line sits where SwiftUI's Text draws it, its ascenders inside the view")
  func firstLineIsInsideTheView() throws {
    let (text, placement) = Self.tightText()
    let font = UIFont.systemFont(ofSize: 17)
    let textView = Self.textView()
    SelectableTextView.show(text, linePlacement: placement, in: textView)
    let height = textView.sizeThatFits(CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)).height
    textView.frame = CGRect(x: 0, y: 0, width: 300, height: height)
    textView.layoutIfNeeded()

    let manager = try #require(textView.textLayoutManager)
    manager.ensureLayout(for: manager.documentRange)
    let fragment = try #require(manager.textLayoutFragment(for: manager.documentRange.location))
    let line = try #require(fragment.textLineFragments.first)
    let baseline = textView.textContainerInset.top + fragment.layoutFragmentFrame.minY
      + line.typographicBounds.minY + line.glyphOrigin.y
    #expect(abs(baseline - font.pointSize) < 0.01, "baseline \(baseline)")
    #expect(baseline - font.ascender >= 0, "ascender top \(baseline - font.ascender)")
    // Every line fits the measured height.
    let bottom = textView.textContainerInset.top + manager.usageBoundsForTextContainer.maxY
    #expect(bottom <= height, "text bottom \(bottom) height \(height)")
    #expect(abs(manager.usageBoundsForTextContainer.height - placement.height(lines: 3)) < 0.01)
  }

  /// The text view sized as the thread sizes it and clipped to its bounds, drawn inside a white
  /// container with `margin` around it, so any ink outside the view is missing from the drawing.
  /// (A text view that does not scroll draws past its bounds on iOS 27; a container or a later
  /// system may clip it.) `linePlacement` nil leaves the text at the top of the view, with no inset.
  private static func drawn(
    _ text: NSAttributedString, linePlacement: AppLineHeightPlacement?, width: CGFloat, margin: CGFloat, scale: CGFloat
  ) throws -> Drawing {
    let textView = Self.textView()
    SelectableTextView.show(text, linePlacement: linePlacement, in: textView)
    let height = textView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
    let container = UIView(frame: CGRect(x: 0, y: 0, width: width + 2 * margin, height: height + 2 * margin))
    textView.frame = CGRect(x: margin, y: margin, width: width, height: height)
    textView.clipsToBounds = true
    container.addSubview(textView)
    container.layoutIfNeeded()
    return (try RenderedPixels(of: container, scale: scale), textView)
  }

  /// A text view's drawing and the text view.
  private typealias Drawing = (pixels: RenderedPixels, textView: SelectableSelfSizingTextView)

  /// `text` drawn where `textView` lays it out, with nothing to clip it.
  private static func reference(_ text: NSAttributedString, in drawn: Drawing, margin: CGFloat) throws -> RenderedPixels {
    let scale = drawn.pixels.scale
    let size = CGSize(width: CGFloat(drawn.pixels.width) / scale, height: CGFloat(drawn.pixels.height) / scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = true
    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: size))
      text.draw(
        with: CGRect(x: margin, y: margin + drawn.textView.textContainerInset.top, width: drawn.textView.bounds.width,
          height: CGFloat.greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }
    return try RenderedPixels(image: try #require(image.cgImage), scale: scale)
  }

  /// With its top inset at the glyph offset, the text view holds all of its ink: the first line's
  /// accents, emoji and fallback-font (Thai) ascent, and the last line's descenders, emoji and
  /// stacked marks are drawn whole even when the view clips to its bounds, the same ink as the
  /// text drawn where nothing clips it. Without the inset the same drawing loses the first line's
  /// accents, which shows the drawing does clip.
  @Test("Accents, emoji and descenders on the first and last lines are inside the view",
    .enabled(if: FontManager.supportsLineHeight))
  func tightTextIsNotClipped() throws {
    let font = UIFont.systemFont(ofSize: 17)
    let placement = AppLineHeightPlacement.resolve(font: font, factor: FontManager.tightLineHeightFactor)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    placement.apply(to: paragraph)
    let text = NSAttributedString(
      string: "ÁÉ 👩🏽‍💻 Ångström ไทย first\nsecond line\nlast gjpqy 👩🏽‍💻 ỹ̃", attributes: [
        .font: font, .paragraphStyle: paragraph, .foregroundColor: UIColor.black,
      ])
    let width: CGFloat = 300
    let margin: CGFloat = 12
    let drawn = try Self.drawn(text, linePlacement: placement, width: width, margin: margin, scale: 3)
    let expected = try Self.reference(text, in: drawn, margin: margin)
    let drawnBands = drawn.pixels.inkRows()
    let expectedBands = expected.inkRows()
    try #require(expected.darkPixelCount() > 1000, "the reference text was not drawn")
    #expect(drawnBands.count == expectedBands.count, "drawn \(drawnBands) expected \(expectedBands)")
    let top = (try #require(drawnBands.first).lowerBound, try #require(expectedBands.first).lowerBound)
    let bottom = (try #require(drawnBands.last).upperBound, try #require(expectedBands.last).upperBound)
    #expect(abs(top.0 - top.1) <= 1 && abs(bottom.0 - bottom.1) <= 1, "drawn \(drawnBands) expected \(expectedBands)")
    let difference = abs(drawn.pixels.darkPixelCount() - expected.darkPixelCount())
    #expect(CGFloat(difference) <= CGFloat(expected.darkPixelCount()) * 0.01,
      "drawn \(drawn.pixels.darkPixelCount()) expected \(expected.darkPixelCount())")

    let uninset = try Self.drawn(text, linePlacement: nil, width: width, margin: margin, scale: 3)
    let uninsetTop = try #require(uninset.pixels.inkRows().first).lowerBound
    let uninsetExpectedTop = try #require(Self.reference(text, in: uninset, margin: margin).inkRows().first).lowerBound
    #expect(uninsetTop > uninsetExpectedTop + 1,
      "without the inset the first line should be clipped: drawn from row \(uninsetTop), its ink from \(uninsetExpectedTop)")
  }
}
#endif
