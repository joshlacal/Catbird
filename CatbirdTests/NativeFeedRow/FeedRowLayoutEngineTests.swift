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
    let typography = FeedRowTypography.resolved(fontManager: fontManager, boldText: false)
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
