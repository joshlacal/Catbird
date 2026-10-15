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
    text: String, width: CGFloat = 390, fontManager: FontManager = FontManager()
  ) throws -> FeedRowLayoutInput {
    let typography = FeedRowTypography.resolved(fontManager: fontManager, boldText: false)
    let post = AppBskyFeedPost(
      text: text, entities: nil, facets: nil, reply: nil, embed: nil, langs: nil, labels: nil,
      tags: nil, createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 0)))
    return FeedRowLayoutInput(
      postID: "p", width: width, typography: typography, displayName: "Alice Rivera",
      handle: "@alice.test", timeText: "3m", verificationSymbol: nil,
      text: FeedPostTextBuilder.build(post: post, typography: typography, linkStyle: .color,
        textColor: .label, linkColor: .systemBlue),
      contentSignature: try FeedRowTestPosts.signature())
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
    #expect(abs(ceil(fitted.height) - layout.textFrame.height) <= 0.5)
  }

  @Test("Height is the sum of the stacked frames")
  func heightAddsUp() throws {
    let layout = FeedRowLayoutEngine.layout(try input(text: "hello"))
    #expect(layout.height == layout.dividerFrame.maxY)
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
}
#endif
