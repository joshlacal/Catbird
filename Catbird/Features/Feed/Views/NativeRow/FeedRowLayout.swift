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
  /// The name the header shows; empty when the author's display name is blank, in which case
  /// the handle starts the line with no gap before it (`PostHeaderView`).
  let displayName: String
  let handle: String            // "@handle"
  let timeText: String          // shortTimeAgoString(from:)
  let verificationSymbol: String?   // VerificationBadgeKind.symbolName
  let text: NSAttributedString
  let contentSignature: FeedPostContentSignature
  /// The widest the row's content may be, centered in `width`
  /// (`FeedRowMetrics.maxRegularWidthContent` in a regular horizontal size class); `nil` for no limit.
  let maxContentWidth: CGFloat?
  /// Pixels per point of the screen the row is drawn on. The text's height is rounded up to a
  /// whole pixel, as SwiftUI and `UILabel` size text; `1` rounds to whole points.
  let displayScale: CGFloat

  init(
    postID: String, width: CGFloat, typography: FeedRowTypography, displayName: String, handle: String,
    timeText: String, verificationSymbol: String?, text: NSAttributedString,
    contentSignature: FeedPostContentSignature, maxContentWidth: CGFloat? = nil, displayScale: CGFloat = 1
  ) {
    self.postID = postID
    self.width = width
    self.typography = typography
    self.displayName = displayName
    self.handle = handle
    self.timeText = timeText
    self.verificationSymbol = verificationSymbol
    self.text = text
    self.contentSignature = contentSignature
    self.maxContentWidth = maxContentWidth
    self.displayScale = max(displayScale, 1)
  }
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
  /// The text's exact typographic height. Uses NSString drawing measurement, which is thread-safe
  /// and matches how `UILabel` lays out the same attributed string. The layout rounds it up to a
  /// whole pixel of the input's display scale, as `UILabel` and SwiftUI's `Text` report it.
  static func textHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
    guard text.length > 0, width > 0 else { return 0 }
    let rect = text.boundingRect(
      with: CGSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    return rect.height
  }

  /// `value` rounded to the nearest whole pixel; a value halfway between two pixels rounds up when
  /// `tiesUp`, down otherwise.
  private static func nearestPixel(_ value: CGFloat, scale: CGFloat, tiesUp: Bool) -> CGFloat {
    let pixels = value * scale
    let rounded = tiesUp ? (pixels + 0.5 + 0.0001).rounded(.down) : (pixels - 0.5 - 0.0001).rounded(.up)
    return rounded / scale
  }

  /// `value` rounded up to a whole pixel; the tolerance keeps a value already on a pixel boundary.
  private static func pixelCeil(_ value: CGFloat, scale: CGFloat) -> CGFloat {
    ceil(value * scale - 0.0001) / scale
  }

  private static func singleLineWidth(_ string: String, font: UIFont, kerning: CGFloat) -> CGFloat {
    ceil((string as NSString).size(withAttributes: [.font: font, .kern: kerning]).width)
  }

  static func layout(_ input: FeedRowLayoutInput) -> FeedRowLayout {
    let m = FeedRowMetrics.self
    let t = input.typography
    let rowWidth = input.width
    // The lane the row's content occupies: the full width, or at most `maxContentWidth` centered
    // in it. Only the divider spans the whole row.
    let laneWidth = min(rowWidth, input.maxContentWidth ?? rowWidth)
    let laneX = (rowWidth - laneWidth) / 2
    // The avatar is centered in its column, which sits inside the column's padding.
    let avatarX = laneX + m.rowHorizontal + m.avatarColumnInset + (m.avatarColumnWidth - m.avatarSize) / 2
    let avatarFrame = CGRect(x: avatarX, y: m.rowTop + m.avatarColumnInset, width: m.avatarSize, height: m.avatarSize)
    let contentX = laneX + m.rowHorizontal + m.avatarColumnInset * 2 + m.avatarColumnWidth + m.columnSpacing
    let contentWidth = max(0, laneX + laneWidth - m.rowHorizontal - contentX)
    let contentTop = m.rowTop + m.contentTop

    // Header line: name [badge] [handle] · time ............ [options]
    // The line and the options button (the ellipsis glyph and its padding) are top-aligned inside
    // the header's horizontal padding; the header is as tall as the taller of the two.
    let headerX = contentX + m.headerHorizontal
    let optionsWidth = t.optionsGlyphSize.width + m.optionsGlyphPadding * 2
    let optionsHeight = t.optionsGlyphSize.height + m.optionsGlyphPadding * 2
    let optionsFrame = CGRect(
      x: contentX + contentWidth - m.headerHorizontal - optionsWidth, y: contentTop,
      width: optionsWidth, height: optionsHeight)
    // The header's labels are as tall as its tallest line. The SwiftUI header top-aligns its
    // texts, each as tall as its line rounded up to a whole pixel, the "·" separator (in the
    // system body style) among them; the header is as tall as the tallest text or the options
    // button. At "Tight" every line has the constant line height.
    let lineHeight = max(
      t.nameLine?.height(lines: 1) ?? t.name.lineHeight, t.metadataLine?.height(lines: 1) ?? t.metadata.lineHeight)
    let headerLineHeight = pixelCeil(max(lineHeight, t.separatorLineHeight), scale: input.displayScale)
    let headerHeight = max(headerLineHeight, optionsHeight)
    let timeWidth = singleLineWidth("·  " + input.timeText, font: t.metadata, kerning: 0)
    // `PostHeaderView` spaces the time from the name and handle by its stack spacing, and the
    // header's `Spacer` keeps at least that much room before the options button. Both are part of
    // what the name and handle cannot use, so the time never reaches the options button.
    let timeGap = m.headerSpacing
    let available = max(0, optionsFrame.minX - m.headerSpacing - headerX - timeWidth - timeGap)
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
    // Without a display name the handle starts the line, with no gap before it.
    let handleGap = input.displayName.isEmpty ? 0 : m.headerSpacing
    let handleRoom = available - (cursor - headerX) - handleGap
    var handleFrame: CGRect?
    if handleRoom >= min(handleIdeal, m.minimumTruncatedHandleWidth) {
      let handle = CGRect(x: cursor + handleGap, y: contentTop, width: min(handleIdeal, handleRoom), height: lineHeight)
      handleFrame = handle
      cursor = handle.maxX
    }
    let timeFrame = CGRect(x: cursor + timeGap, y: contentTop, width: timeWidth, height: lineHeight)

    let textWidth = max(0, contentWidth - m.textHorizontal * 2)
    let textHeight = pixelCeil(textHeight(input.text, width: textWidth), scale: input.displayScale)
    // A post without text has no text view: its padding is absent above and below the empty frame,
    // while the record text's own padding and the column spacing remain, as in the SwiftUI row.
    let missingTextInset = input.text.length > 0 ? 0 : m.textHorizontal
    let textFrame = CGRect(
      x: contentX + m.textHorizontal, y: contentTop + headerHeight + m.textTop - missingTextInset,
      width: textWidth, height: textHeight)
    let actionTop = textFrame.maxY + m.textBottom - missingTextInset
    let actionBarFrame = CGRect(x: contentX, y: actionTop, width: contentWidth, height: m.actionBarHeight)
    let contentBottom = actionBarFrame.maxY + m.actionBarBottom
    let rowBottom = max(contentBottom, avatarFrame.maxY + m.avatarColumnInset)
    // The hosted row's divider is a half-point `Rectangle`; SwiftUI rounds each of its edges to the
    // nearest pixel, a tie rounding outwards (the top up the screen, the bottom down). On the pixel
    // grid that covers two pixels at 3x and one at 2x; off the grid it can cover one pixel at 3x.
    // The row is still as tall as the nominal half point, rounded up to a whole pixel as a
    // self-sizing SwiftUI row reports it.
    let scale = input.displayScale
    let height = pixelCeil(rowBottom + m.dividerHeight, scale: scale)
    let dividerTop = nearestPixel(rowBottom, scale: scale, tiesUp: false)
    let dividerBottom = min(
      height,
      max(dividerTop + 1 / scale, nearestPixel(rowBottom + m.dividerHeight, scale: scale, tiesUp: true)))
    let dividerFrame = CGRect(x: 0, y: dividerTop, width: rowWidth, height: dividerBottom - dividerTop)
    return FeedRowLayout(
      width: rowWidth, height: height,
      avatarFrame: avatarFrame, nameFrame: nameFrame,
      badgeFrame: badgeFrame, handleFrame: handleFrame, timeFrame: timeFrame,
      optionsButtonFrame: optionsFrame, textFrame: textFrame, actionBarFrame: actionBarFrame,
      dividerFrame: dividerFrame)
  }
}
#endif
