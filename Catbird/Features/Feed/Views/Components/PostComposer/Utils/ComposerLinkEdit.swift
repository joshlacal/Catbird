import Foundation

enum ComposerLinkEdit {
  struct Selection: Equatable {
    let range: NSRange
    let selectedText: String
    let sourceText: String
  }

  struct Result {
    let attributedText: NSAttributedString
    let linkedRange: NSRange
    let caretRange: NSRange
    let linkFacet: RichTextFacetUtils.LinkFacet
  }

  static func selection(
    requestedRange: NSRange?,
    in attributedText: NSAttributedString
  ) -> Selection {
    let range = requestedRange.flatMap {
      validated($0, in: attributedText)
    } ?? NSRange(location: attributedText.length, length: 0)
    let selectedText = attributedText.attributedSubstring(from: range).string

    return Selection(
      range: range,
      selectedText: selectedText,
      sourceText: attributedText.string
    )
  }

  static func apply(
    url: URL,
    displayText: String?,
    selection: Selection,
    to attributedText: NSAttributedString
  ) -> Result? {
    guard selection.sourceText == attributedText.string,
          let range = validated(selection.range, in: attributedText),
          attributedText.attributedSubstring(from: range).string == selection.selectedText else {
      return nil
    }

    let updated = RichTextFacetUtils.addOrInsertLinkFacet(
      to: attributedText,
      url: url,
      range: range,
      displayText: displayText
    )
    let linkedRange: NSRange
    if range.length == 0 {
      linkedRange = NSRange(
        location: range.location,
        length: updated.length - attributedText.length
      )
    } else {
      linkedRange = range
    }
    let linkedText = updated.attributedSubstring(from: linkedRange).string
    let caretRange = NSRange(location: NSMaxRange(linkedRange), length: 0)

    return Result(
      attributedText: updated,
      linkedRange: linkedRange,
      caretRange: caretRange,
      linkFacet: RichTextFacetUtils.LinkFacet(
        range: linkedRange,
        url: url,
        displayText: linkedText
      )
    )
  }

  private static func validated(
    _ range: NSRange,
    in attributedText: NSAttributedString
  ) -> NSRange? {
    guard range.location != NSNotFound,
          range.location >= 0,
          range.length >= 0,
          range.location <= attributedText.length,
          range.length <= attributedText.length - range.location else {
      return nil
    }
    return range
  }
}
