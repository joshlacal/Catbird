#if os(iOS)
  import Testing
  import UIKit
  @testable import Catbird

  /// `NSAdaptiveImageGlyph` (inline Bluemoji) only renders under TextKit 2.
  /// Touching `UITextView.layoutManager` (or `textContainer.layoutManager`)
  /// silently downgrades the view to TextKit 1 compatibility mode, after which
  /// `textLayoutManager` becomes nil and adaptive image glyphs draw as nothing.
  @Suite("SelectableTextView TextKit 2")
  @MainActor
  struct SelectableTextViewTextKitTests {

    @Test("measurement path keeps TextKit 2 active")
    func measurementKeepsTextKit2() {
      let view = SelectableSelfSizingTextView()
      view.supportsAdaptiveImageGlyph = true
      view.attributedText = NSAttributedString(string: "test test :test1: yay")
      view.frame = CGRect(x: 0, y: 0, width: 320, height: 100)

      // Exercise every sizing entry point the SwiftUI wrapper uses.
      _ = view.sizeThatFits(CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
      _ = view.intrinsicContentSize
      view.layoutIfNeeded()

      #expect(view.textLayoutManager != nil,
              "sizing forced a TextKit 1 fallback — adaptive image glyphs will not render")
    }
  }
#endif
