#if os(iOS)
import Testing
import UIKit
@testable import Catbird

/// The thread's main post draws in a `UITextView`, which clips what it draws. At Tight its lines
/// have a constant line height, shorter than the font's, and the text view must still show the
/// first line's accents and emoji whole.
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
}
#endif
