#if os(iOS)
import UIKit

// MARK: - Layout Types

/// Everything the layout engine needs to place one row.
/// `@unchecked Sendable`: `NSAttributedString` and `UIFont` are immutable once built, and the
/// attributed text is never mutated after it reaches the engine, so the value can cross to the
/// background layout queue.
struct FeedRowLayoutInput: @unchecked Sendable {
  let postID: String
  let width: CGFloat
  let typography: FeedRowTypography
  let displayName: String
  let handle: String            // "@handle"
  let timeText: String          // shortTimeAgoString(from:)
  let verificationSymbol: String?   // VerificationBadgeKind.symbolName
  let text: NSAttributedString
  let contentSignature: FeedPostContentSignature
}

struct FeedRowLayout: Equatable, Sendable {
  let width: CGFloat
  let height: CGFloat
  let avatarFrame: CGRect
  let nameFrame: CGRect
  let badgeFrame: CGRect?
  let handleFrame: CGRect?      // nil when the handle does not fit (HandleFitLayout rule)
  let timeFrame: CGRect         // includes the leading "· "
  let optionsButtonFrame: CGRect
  let textFrame: CGRect         // .zero height when the post has no text
  let actionBarFrame: CGRect
  let dividerFrame: CGRect
}

// MARK: - Feed Row Layout Engine

enum FeedRowLayoutEngine {
  /// Uses NSString drawing measurement, which is thread-safe and matches how `UILabel` lays out
  /// the same attributed string.
  static func textHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
    guard text.length > 0, width > 0 else { return 0 }
    let rect = text.boundingRect(
      with: CGSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    return ceil(rect.height)
  }

  private static func singleLineWidth(_ string: String, font: UIFont, kerning: CGFloat) -> CGFloat {
    ceil((string as NSString).size(withAttributes: [.font: font, .kern: kerning]).width)
  }

  static func layout(_ input: FeedRowLayoutInput) -> FeedRowLayout {
    let m = FeedRowMetrics.self
    let t = input.typography
    let rowWidth = input.width
    let avatarX = m.rowHorizontal + m.avatarColumnInset
    let avatarFrame = CGRect(x: avatarX, y: m.rowTop + m.avatarColumnInset, width: m.avatarSize, height: m.avatarSize)
    let contentX = m.rowHorizontal + m.avatarColumnInset * 2 + m.avatarColumnWidth + m.columnSpacing
    let contentWidth = max(0, rowWidth - contentX - m.rowHorizontal)
    let contentTop = m.rowTop + m.contentTop

    // Header line: name [badge] [handle] · time ............ [options]
    let headerX = contentX + m.headerHorizontal
    let optionsFrame = CGRect(
      x: contentX + contentWidth - m.optionsButtonSide, y: contentTop - (m.optionsButtonSide - t.name.lineHeight) / 2,
      width: m.optionsButtonSide, height: m.optionsButtonSide)
    let lineHeight = ceil(max(t.name.lineHeight, t.metadata.lineHeight))
    let timeWidth = singleLineWidth("·  " + input.timeText, font: t.metadata, kerning: 0)
    // The gap before the time is part of what the name and handle cannot use, so the time never
    // reaches the options button.
    let timeGap = m.headerSpacing / 2
    let available = max(0, optionsFrame.minX - headerX - timeWidth - timeGap)
    let badgeSide = input.verificationSymbol == nil ? 0 : ceil(t.metadata.pointSize * 0.85)
    let badgeSpace = badgeSide > 0 ? badgeSide + 4 : 0
    let nameWidth = min(singleLineWidth(input.displayName, font: t.name, kerning: 0), max(0, available - badgeSpace))
    let nameFrame = CGRect(x: headerX, y: contentTop, width: nameWidth, height: lineHeight)
    var cursor = nameFrame.maxX
    var badgeFrame: CGRect?
    if badgeSide > 0 {
      let badge = CGRect(x: cursor + 4, y: contentTop + (lineHeight - badgeSide) / 2, width: badgeSide, height: badgeSide)
      badgeFrame = badge
      cursor = badge.maxX
    }
    // HandleFitLayout rule: full width if it fits, truncated if ≥ minimum, else hidden.
    let handleIdeal = singleLineWidth(input.handle, font: t.metadata, kerning: t.kerning)
    let handleRoom = available - (cursor - headerX) - m.headerSpacing
    var handleFrame: CGRect?
    if handleRoom >= min(handleIdeal, m.minimumTruncatedHandleWidth) {
      let handle = CGRect(x: cursor + m.headerSpacing, y: contentTop, width: min(handleIdeal, handleRoom), height: lineHeight)
      handleFrame = handle
      cursor = handle.maxX
    }
    let timeFrame = CGRect(x: cursor + timeGap, y: contentTop, width: timeWidth, height: lineHeight)

    let textWidth = max(0, contentWidth - m.textHorizontal * 2)
    let textHeight = textHeight(input.text, width: textWidth)
    let textFrame = CGRect(
      x: contentX + m.textHorizontal, y: nameFrame.maxY + m.textTop, width: textWidth, height: textHeight)
    let actionTop = textFrame.maxY + (textHeight > 0 ? m.textBottom : 0)
    let actionBarFrame = CGRect(x: contentX, y: actionTop, width: contentWidth, height: m.actionBarHeight)
    let contentBottom = actionBarFrame.maxY + m.actionBarBottom
    let rowBottom = max(contentBottom, avatarFrame.maxY + m.avatarColumnInset)
    let dividerFrame = CGRect(x: 0, y: rowBottom, width: rowWidth, height: m.dividerHeight)
    return FeedRowLayout(
      width: rowWidth, height: dividerFrame.maxY, avatarFrame: avatarFrame, nameFrame: nameFrame,
      badgeFrame: badgeFrame, handleFrame: handleFrame, timeFrame: timeFrame,
      optionsButtonFrame: optionsFrame, textFrame: textFrame, actionBarFrame: actionBarFrame,
      dividerFrame: dividerFrame)
  }
}
#endif
