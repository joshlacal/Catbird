#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import Catbird

/// The DM composer's minimum editor height must hold one body line as TextKit lays it
/// out. A shorter minimum lets TextEditor settle a point below its content on some
/// launches, which clips the line and shifts the transcript's footer inset.
@Suite("Chat composer editor metrics")
@MainActor
struct ChatComposerEditorMetricsTests {
  @Test("The minimum editor height fits one laid-out body line",
    arguments: [DynamicTypeSize.large, .xLarge, .xxxLarge, .accessibility1, .accessibility3, .accessibility5])
  func minimumFitsOneLine(size: DynamicTypeSize) {
    let minimum = ChatComposerEditorMetrics.minimumHeight(for: size)
    for text in ["", "Message"] {
      let laidOut = singleLineHeight(text: text, size: size)
      #expect(minimum >= laidOut, "\(size) \"\(text)\": minimum \(minimum) < laid out \(laidOut)")
      #expect(minimum - laidOut < 1 || minimum == 36, "\(size) \"\(text)\": minimum \(minimum) adds space beyond \(laidOut)")
    }
  }

  private func singleLineHeight(text: String, size: DynamicTypeSize) -> CGFloat {
    let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
    let textView = UITextView()
    textView.font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
    let inset = ChatComposerEditorMetrics.textInset
    textView.textContainerInset = UIEdgeInsets(top: inset, left: 0, bottom: inset, right: 0)
    textView.text = text
    return textView.sizeThatFits(CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)).height
  }
}
#endif
