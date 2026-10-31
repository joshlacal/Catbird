#if os(iOS)
import Foundation
import Petrel
import Testing
import UIKit
@testable import Catbird

@MainActor
@Suite("Feed row layout engine")
struct FeedRowLayoutEngineTests {
  private func input(
    text: String, width: CGFloat = 390, displayName: String = "Alice Rivera", maxContentWidth: CGFloat? = nil,
    displayScale: CGFloat = 1, fontManager: FontManager = FontManager()
  ) throws -> FeedRowLayoutInput {
    let typography = FeedRowTypography.resolved(
      fontManager: fontManager, boldText: false, contentSize: UIApplication.shared.preferredContentSizeCategory)
    let post = AppBskyFeedPost(
      text: text, entities: nil, facets: nil, reply: nil, embed: nil, langs: nil, labels: nil,
      tags: nil, createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 0)))
    return FeedRowLayoutInput(
      postID: "p", width: width, typography: typography, displayName: displayName,
      handle: "@alice.test", timeText: "3m", verificationSymbol: nil,
      text: FeedPostTextBuilder.build(post: post, typography: typography, linkStyle: .color,
        textColor: .label, linkColor: .systemBlue),
      contentSignature: try FeedRowTestPosts.signature(), maxContentWidth: maxContentWidth,
      displayScale: displayScale)
  }

  @Test("Measured text height is what a UILabel needs to draw it", arguments: [
    "short", String(repeating: "wrapping words across several lines ", count: 12), "emoji 🦋🏳️‍🌈👩🏽‍💻 mixed",
  ])
  func textHeightMatchesLabel(text: String) throws {
    let input = try input(text: text)
    let layout = FeedRowLayoutEngine.layout(input)
    let label = UILabel()
    label.numberOfLines = 0
    label.attributedText = input.text
    let fitted = label.sizeThatFits(CGSize(width: layout.textFrame.width, height: .greatestFiniteMagnitude))
    // Never shorter than the label needs, and less than a point taller (the text is rounded up
    // to a whole pixel of the input's display scale).
    #expect(layout.textFrame.height >= fitted.height - 0.001)
    #expect(layout.textFrame.height - fitted.height < 1)
  }

  @Test("Height is the sum of the stacked frames")
  func heightAddsUp() throws {
    let layout = FeedRowLayoutEngine.layout(try input(text: "hello"))
    #expect(layout.height >= layout.dividerFrame.maxY)
    #expect(layout.height - layout.dividerFrame.maxY < 1)
    #expect(layout.actionBarFrame.minY >= layout.textFrame.maxY)
    #expect(layout.textFrame.minY >= max(layout.nameFrame.maxY, layout.timeFrame.maxY))
  }

  @Test("A long display name hides the handle instead of overlapping the time")
  func handleHidesWhenNoRoom() throws {
    var long = try input(text: "x", width: 320)
    long = FeedRowLayoutInput(
      postID: long.postID, width: long.width, typography: long.typography,
      displayName: String(repeating: "Very Long Name ", count: 6), handle: long.handle,
      timeText: long.timeText, verificationSymbol: nil, text: long.text, contentSignature: long.contentSignature)
    let layout = FeedRowLayoutEngine.layout(long)
    #expect(layout.handleFrame == nil)
    #expect(layout.nameFrame.maxX <= layout.timeFrame.minX)
    #expect(layout.timeFrame.maxX <= layout.optionsButtonFrame.minX)
  }

  @Test("Layout is deterministic and thread-safe")
  func deterministicOffMain() async throws {
    let value = try input(text: "same text every time")
    let main = FeedRowLayoutEngine.layout(value)
    let background = await Task.detached { FeedRowLayoutEngine.layout(value) }.value
    #expect(main == background)
  }

  // MARK: - Parity with the SwiftUI row

  /// Top of the content column: the row's top padding plus the column's own top padding.
  private static let contentTop = FeedRowMetrics.rowTop + FeedRowMetrics.contentTop

  @Test("The header is as tall as the options button and the text starts below it")
  func headerFitsOptionsButton() throws {
    let input = try input(text: "hello")
    let layout = FeedRowLayoutEngine.layout(input)
    let glyph = input.typography.optionsGlyphSize
    let options = layout.optionsButtonFrame
    #expect(options.minY == Self.contentTop)
    #expect(options.height == glyph.height + FeedRowMetrics.optionsGlyphPadding * 2)
    #expect(options.width == glyph.width + FeedRowMetrics.optionsGlyphPadding * 2)
    let headerHeight = max(options.height, input.typography.name.lineHeight, input.typography.metadata.lineHeight)
    #expect(abs(layout.textFrame.minY - (Self.contentTop + headerHeight + FeedRowMetrics.textTop)) < 0.001)
    #expect(options.maxY <= layout.textFrame.minY)
  }

  @Test("The options glyph sits inside the header's trailing padding")
  func optionsInsideHeaderPadding() throws {
    let layout = FeedRowLayoutEngine.layout(try input(text: "hello"))
    #expect(layout.optionsButtonFrame.maxX == layout.actionBarFrame.maxX - FeedRowMetrics.headerHorizontal)
  }

  @Test("The avatar is centered in its column")
  func avatarCenteredInColumn() throws {
    let layout = FeedRowLayoutEngine.layout(try input(text: "hello"))
    let m = FeedRowMetrics.self
    #expect(layout.avatarFrame.minX == m.rowHorizontal + m.avatarColumnInset + (m.avatarColumnWidth - m.avatarSize) / 2)
    #expect(layout.avatarFrame.minY == m.rowTop + m.avatarColumnInset)
  }

  @Test("A post without text keeps the record padding and column spacing on both sides")
  func emptyTextIsSymmetric() throws {
    let empty = FeedRowLayoutEngine.layout(try input(text: ""))
    let filled = FeedRowLayoutEngine.layout(try input(text: "hello"))
    #expect(empty.textFrame.height == 0)
    let inset = FeedRowMetrics.textHorizontal
    #expect(empty.textFrame.minY == filled.textFrame.minY - inset)
    #expect(empty.actionBarFrame.minY - empty.textFrame.maxY == FeedRowMetrics.textBottom - inset)
    #expect(empty.textFrame.minY - filled.optionsButtonFrame.maxY == empty.actionBarFrame.minY - empty.textFrame.maxY)
  }

  @Test("Without a display name the handle starts the line")
  func blankNameHandleHasNoGap() throws {
    let layout = FeedRowLayoutEngine.layout(try input(text: "hello", displayName: ""))
    let handle = try #require(layout.handleFrame)
    #expect(layout.nameFrame.width == 0)
    #expect(handle.minX == layout.nameFrame.minX)
  }

  @Test("The text is as tall as its lines, rounded up to a whole pixel", arguments: [CGFloat(1), 2, 3])
  func textHeightRoundsToPixels(scale: CGFloat) throws {
    let input = try input(text: String(repeating: "pixel rounding ", count: 9), displayScale: scale)
    let layout = FeedRowLayoutEngine.layout(input)
    let exact = FeedRowLayoutEngine.textHeight(input.text, width: layout.textFrame.width)
    let pixels = layout.textFrame.height * scale
    #expect(abs(pixels - pixels.rounded()) < 0.001)
    #expect(layout.textFrame.height >= exact)
    #expect(layout.textFrame.height - exact < 1 / scale)
    #expect(layout.actionBarFrame.minY == layout.textFrame.maxY + FeedRowMetrics.textBottom)
    let rowPixels = layout.height * scale
    #expect(abs(rowPixels - rowPixels.rounded()) < 0.001)
    #expect(layout.height >= layout.dividerFrame.maxY)
  }

  @Test("The divider is drawn as SwiftUI draws a half-point line, rounded out to whole pixels",
    arguments: [(CGFloat(3), CGFloat(2)), (2, 1)])
  func dividerCoversWholePixels(scale: CGFloat, pixels: CGFloat) throws {
    let layout = FeedRowLayoutEngine.layout(try input(text: "hello", displayScale: scale))
    let divider = layout.dividerFrame
    #expect(abs(divider.height * scale - pixels) < 0.001)
    let top = divider.minY * scale
    #expect(abs(top - top.rounded()) < 0.001)
    // The row is laid out with the nominal half point, as the hosted row is; the drawn line fits in it.
    #expect(divider.maxY <= layout.height + 0.001)
    #expect(divider.width == layout.width)
  }

  /// Header heights whose row bottoms fall a third, three quarters, a fifth and four fifths of a
  /// pixel off the grid at the given scale (the header grows with the options glyph's height).
  @Test("The divider's edges round to the nearest pixel like SwiftUI's when the row bottom is off the grid",
    arguments: [(CGFloat(3), CGFloat(6.1)), (3, 6.25), (2, 6.1), (2, 6.4)])
  func dividerEdgesRoundLikeSwiftUI(scale: CGFloat, glyphHeight: CGFloat) throws {
    let base = try input(text: "hello", displayScale: scale)
    let t = base.typography
    let typography = FeedRowTypography(
      body: t.body, name: t.name, metadata: t.metadata, bodyLineSpacing: t.bodyLineSpacing, kerning: t.kerning,
      optionsGlyphSize: CGSize(width: t.optionsGlyphSize.width, height: glyphHeight),
      separatorLineHeight: t.separatorLineHeight, generationKey: t.generationKey &+ 1)
    let input = FeedRowLayoutInput(
      postID: base.postID, width: base.width, typography: typography, displayName: base.displayName,
      handle: base.handle, timeText: base.timeText, verificationSymbol: nil, text: base.text,
      contentSignature: base.contentSignature, displayScale: scale)
    let layout = FeedRowLayoutEngine.layout(input)
    let rowBottom = layout.actionBarFrame.maxY + FeedRowMetrics.actionBarBottom
    let pixels = rowBottom * scale
    #expect(abs(pixels - pixels.rounded()) > 0.1, "the case must be off the pixel grid")

    // SwiftUI rounds each edge of the half-point rectangle to the nearest pixel.
    func nearestPixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
    #expect(abs(layout.dividerFrame.minY - nearestPixel(rowBottom)) < 0.001)
    #expect(abs(layout.dividerFrame.maxY - nearestPixel(rowBottom + FeedRowMetrics.dividerHeight)) < 0.001)
    // Row height (and so every row top) is unchanged: the nominal half point, rounded up.
    #expect(abs(layout.height - ((rowBottom + FeedRowMetrics.dividerHeight) * scale - 0.0001).rounded(.up) / scale) < 0.001)
    #expect(layout.dividerFrame.maxY <= layout.height + 0.001)
  }

  /// The SwiftUI header's texts are top-aligned, each as tall as its line rounded up to a whole
  /// pixel. From Extra Extra Extra Large up the tallest is the "·" separator, which is drawn in the
  /// system body style and outgrows both the app's fonts and the options button.
  @Test("At large text sizes the header is as tall as the separator's line, rounded up to a whole pixel",
    arguments: [UIContentSizeCategory.extraExtraExtraLarge, .accessibilityLarge])
  func headerFitsSeparatorLine(contentSize: UIContentSizeCategory) throws {
    let scale: CGFloat = 3
    let base = try NativeFeedRowTestFactory.layoutInput(text: "hello", contentSize: contentSize)
    let t = base.typography
    let input = FeedRowLayoutInput(
      postID: base.postID, width: base.width, typography: t, displayName: base.displayName,
      handle: base.handle, timeText: base.timeText, verificationSymbol: nil, text: base.text,
      contentSignature: base.contentSignature, displayScale: scale)
    let layout = FeedRowLayoutEngine.layout(input)
    let separator = t.separatorLineHeight
    #expect(separator > layout.optionsButtonFrame.height)
    #expect(separator > max(t.name.lineHeight, t.metadata.lineHeight))
    let header = (separator * scale).rounded(.up) / scale
    #expect(abs(layout.textFrame.minY - (Self.contentTop + header + FeedRowMetrics.textTop)) < 0.001)
  }

  @Test("A header line taller than the options button is rounded up to a whole pixel", arguments: [CGFloat(3), 2])
  func headerLineRoundsUpToPixel(scale: CGFloat) throws {
    let base = try input(text: "hello", displayScale: scale)
    let t = base.typography
    let name = UIFont.systemFont(ofSize: 30, weight: UIFont.Weight.semibold)
    let typography = FeedRowTypography(
      body: t.body, name: name, metadata: t.metadata, bodyLineSpacing: t.bodyLineSpacing, kerning: t.kerning,
      optionsGlyphSize: t.optionsGlyphSize, separatorLineHeight: t.separatorLineHeight,
      generationKey: t.generationKey &+ 2)
    let input = FeedRowLayoutInput(
      postID: base.postID, width: base.width, typography: typography, displayName: base.displayName,
      handle: base.handle, timeText: base.timeText, verificationSymbol: nil, text: base.text,
      contentSignature: base.contentSignature, displayScale: scale)
    let layout = FeedRowLayoutEngine.layout(input)
    let line = name.lineHeight
    #expect(line > layout.optionsButtonFrame.height)
    #expect(abs(line * scale - (line * scale).rounded()) > 0.1, "the line must be off the pixel grid")
    let header = (line * scale).rounded(.up) / scale
    #expect(abs(layout.textFrame.minY - (Self.contentTop + header + FeedRowMetrics.textTop)) < 0.001)
    // The name keeps its own line height; only the header's extent is rounded.
    #expect(abs(layout.nameFrame.height - line) < 0.001)
  }

  @Test("A maximum content width centers the row's content and keeps a full-width divider")
  func maximumContentWidthCenters() throws {
    let full = FeedRowLayoutEngine.layout(try input(text: "hello", width: 600))
    let wide = FeedRowLayoutEngine.layout(try input(text: "hello", width: 1000, maxContentWidth: 600))
    #expect(wide.width == 1000)
    #expect(wide.height == full.height)
    #expect(wide.avatarFrame == full.avatarFrame.offsetBy(dx: 200, dy: 0))
    #expect(wide.textFrame == full.textFrame.offsetBy(dx: 200, dy: 0))
    #expect(wide.actionBarFrame == full.actionBarFrame.offsetBy(dx: 200, dy: 0))
    #expect(wide.optionsButtonFrame == full.optionsButtonFrame.offsetBy(dx: 200, dy: 0))
    #expect(wide.dividerFrame.minX == 0)
    #expect(wide.dividerFrame.width == 1000)
  }
}
#endif
