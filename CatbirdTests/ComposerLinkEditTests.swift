import Foundation
import Testing
@testable import Catbird

@Suite("Composer link edit safety")
struct ComposerLinkEditTests {
  @Test func freshCaretInsertionCreatesVisibleLinkedText() {
    let text = NSAttributedString(string: "Hello ")
    let selection = ComposerLinkEdit.selection(
      requestedRange: NSRange(location: text.length, length: 0),
      in: text
    )

    let result = ComposerLinkEdit.apply(
      url: URL(string: "https://example.com")!,
      displayText: "Example",
      selection: selection,
      to: text
    )

    #expect(result?.attributedText.string == "Hello Example")
    #expect(result?.linkedRange == NSRange(location: 6, length: 7))
    #expect(result?.caretRange == NSRange(location: 13, length: 0))
    #expect(result?.attributedText.attribute(
      .link,
      at: 6,
      effectiveRange: nil
    ) as? URL == URL(string: "https://example.com"))
  }

  @Test func staleSelectionIsRejected() {
    let original = NSAttributedString(string: "selected text")
    let selection = ComposerLinkEdit.selection(
      requestedRange: NSRange(location: 0, length: original.length),
      in: original
    )

    let changed = NSAttributedString(string: "different text")
    let result = ComposerLinkEdit.apply(
      url: URL(string: "https://example.com")!,
      displayText: nil,
      selection: selection,
      to: changed
    )

    #expect(result == nil)
  }

  @Test func outOfBoundsSelectionIsRejectedInsteadOfClamped() {
    let text = NSAttributedString(string: "short")
    let selection = ComposerLinkEdit.Selection(
      range: NSRange(location: 20, length: 3),
      selectedText: "old",
      sourceText: text.string
    )

    let result = ComposerLinkEdit.apply(
      url: URL(string: "https://example.com")!,
      displayText: nil,
      selection: selection,
      to: text
    )

    #expect(result == nil)
  }

  @Test func invalidPresentationRangeFallsBackToSafeCaret() {
    let text = NSAttributedString(string: "Hello")

    let selection = ComposerLinkEdit.selection(
      requestedRange: NSRange(location: 99, length: 1),
      in: text
    )

    #expect(selection.range == NSRange(location: text.length, length: 0))
    #expect(selection.selectedText.isEmpty)
  }
}
