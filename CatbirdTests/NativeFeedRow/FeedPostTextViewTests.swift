#if os(iOS)
import Testing
import UIKit
@testable import Catbird

@MainActor
@Suite("Feed post text view")
struct FeedPostTextViewTests {
  private static let font = UIFont.systemFont(ofSize: 17)

  private func attributes(lineSpacing: CGFloat = 0, kerning: CGFloat = 0) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = lineSpacing
    paragraph.lineBreakMode = .byWordWrapping
    return [.font: Self.font, .kern: kerning, .paragraphStyle: paragraph, .foregroundColor: UIColor.black]
  }

  private func width(of string: String, kerning: CGFloat = 0) -> CGFloat {
    (string as NSString).size(withAttributes: [.font: Self.font, .kern: kerning]).width
  }

  @Test("Tapping inside a link run returns its URL; outside returns nil")
  func hitTesting() {
    let text = NSMutableAttributedString(string: "see #swift today", attributes: [.font: UIFont.systemFont(ofSize: 17)])
    text.addAttribute(.feedLink, value: URL(string: "tag://swift")!, range: NSRange(location: 4, length: 6))
    let view = FeedPostTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 40))
    view.attributedText = text
    view.layoutIfNeeded()
    let prefix = ("see " as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 17)]).width
    #expect(view.link(at: CGPoint(x: prefix + 10, y: 10)) == URL(string: "tag://swift"))
    #expect(view.link(at: CGPoint(x: 2, y: 10)) == nil)
  }

  @Test("A link is hit across its whole width, including the last character's trailing half")
  func linkEdges() throws {
    let string = "see #swift today"
    let text = NSMutableAttributedString(string: string, attributes: attributes(kerning: 0.1))
    text.addAttribute(.feedLink, value: URL(string: "tag://swift")!, range: NSRange(location: 4, length: 6))
    let view = FeedPostTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 24))
    view.attributedText = text
    let start = width(of: "see ", kerning: 0.1)
    let end = width(of: "see #swift", kerning: 0.1)
    #expect(view.link(at: CGPoint(x: start + 0.5, y: 10)) == URL(string: "tag://swift"))
    #expect(view.link(at: CGPoint(x: end - 0.5, y: 10)) == URL(string: "tag://swift"))
    #expect(view.link(at: CGPoint(x: start - 0.5, y: 10)) == nil)
    #expect(view.link(at: CGPoint(x: end + 0.5, y: 10)) == nil)
  }

  @Test("Points past the text or on text without links return nil")
  func missesReturnNil() {
    let plain = NSAttributedString(string: "no links here", attributes: attributes())
    let view = FeedPostTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 24))
    #expect(view.link(at: CGPoint(x: 5, y: 5)) == nil)
    view.attributedText = plain
    #expect(view.link(at: CGPoint(x: 5, y: 5)) == nil)

    let linked = NSMutableAttributedString(string: "#tag", attributes: attributes())
    linked.addAttribute(.feedLink, value: URL(string: "tag://tag")!, range: NSRange(location: 0, length: 4))
    view.attributedText = linked
    #expect(view.link(at: CGPoint(x: 5, y: 5)) == URL(string: "tag://tag"))
    #expect(view.link(at: CGPoint(x: 5, y: 200)) == nil)
    #expect(view.link(at: CGPoint(x: 250, y: 5)) == nil)
    #expect(view.link(at: CGPoint(x: -5, y: 5)) == nil)
  }

  @Test("Opening a link reports its URL; a miss reports nothing")
  func activation() {
    let text = NSMutableAttributedString(string: "go #swift", attributes: attributes())
    text.addAttribute(.feedLink, value: URL(string: "tag://swift")!, range: NSRange(location: 3, length: 6))
    let view = FeedPostTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 24))
    view.attributedText = text
    var opened: [URL] = []
    view.onOpenLink = { opened.append($0) }
    view.activateLink(at: CGPoint(x: width(of: "go ") + 8, y: 10))
    view.activateLink(at: CGPoint(x: 2, y: 10))
    #expect(opened == [URL(string: "tag://swift")!])
  }

  @Test("The view reads as the post text to VoiceOver")
  func accessibility() {
    let view = FeedPostTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 24))
    view.attributedText = NSAttributedString(string: "Hello world", attributes: attributes())
    #expect(view.isAccessibilityElement)
    #expect(view.accessibilityLabel == "Hello world")
    #expect(view.accessibilityTraits.contains(.staticText))
  }

  /// The hit test builds its own text layout, so it must agree with what `UILabel` paints. Draw
  /// the view with link runs in red and require that every solidly red pixel is a link hit and
  /// every solidly black pixel is not, on wrapped lines with line spacing and letter spacing.
  @Test("Link hits agree with the pixels the label draws", arguments: [
    (lineSpacing: CGFloat(0), kerning: CGFloat(0)),
    (lineSpacing: CGFloat(4), kerning: CGFloat(0.1)),
    (lineSpacing: CGFloat(8), kerning: CGFloat(-0.3))
  ])
  func hitsMatchDrawing(lineSpacing: CGFloat, kerning: CGFloat) throws {
    let string = "Opening 🦋 words of a post 🏳️‍🌈 with #firstTag in them, then a long stretch of 👩🏽‍💻 plain text that has to wrap onto several lines before it reaches @someone.test and finally https://example.com/path at the end of the first paragraph.\n\nA second paragraph with #lastTag and enough more words that it wraps onto another line too"
    let text = NSMutableAttributedString(string: string, attributes: attributes(lineSpacing: lineSpacing, kerning: kerning))
    for token in ["#firstTag", "@someone.test", "https://example.com/path", "#lastTag"] {
      let range = (string as NSString).range(of: token)
      text.addAttribute(.feedLink, value: URL(string: "link://\(token.count)")!, range: range)
      text.addAttribute(.foregroundColor, value: UIColor.red, range: range)
    }
    let textWidth: CGFloat = 280
    let height = FeedRowLayoutEngine.textHeight(text, width: textWidth)
    let view = FeedPostTextView(frame: CGRect(x: 0, y: 0, width: textWidth, height: height))
    view.backgroundColor = .white
    view.attributedText = text
    view.layoutIfNeeded()

    let scale: CGFloat = 2
    let pixels = try RenderedPixels(of: view, scale: scale)
    var redPixels = 0
    var blackPixels = 0
    var misses: [String] = []
    // Every hit test builds a text layout, so check a deterministic sample of the pixels.
    let sampleStride = 5
    for row in 0..<pixels.height {
      for column in 0..<pixels.width {
        let color = pixels.color(column: column, row: row)
        guard color.isSolidRed || color.isSolidBlack else { continue }
        if color.isSolidRed { redPixels += 1 } else { blackPixels += 1 }
        guard (color.isSolidRed ? redPixels : blackPixels) % sampleStride == 0 else { continue }
        let point = CGPoint(x: (CGFloat(column) + 0.5) / scale, y: (CGFloat(row) + 0.5) / scale)
        let hit = view.link(at: point)
        if color.isSolidRed, hit == nil { misses.append("red pixel is not a link at \(point)") }
        if color.isSolidBlack, hit != nil { misses.append("black pixel is a link at \(point)") }
      }
    }
    #expect(redPixels > 500 && blackPixels > 2000, "the text was not drawn")
    #expect(misses.isEmpty, "\(misses.count) disagreements, first: \(misses.prefix(3))")
  }

  @Test("Links on later paragraphs are found")
  func multipleParagraphs() {
    let string = "first line\nsecond #tag line\n\nlast"
    let text = NSMutableAttributedString(string: string, attributes: attributes(lineSpacing: 4))
    let range = (string as NSString).range(of: "#tag")
    text.addAttribute(.feedLink, value: URL(string: "tag://tag")!, range: range)
    let view = FeedPostTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
    view.attributedText = text
    let lineAdvance = Self.font.lineHeight + 4
    let linkX = width(of: "second ") + 6
    #expect(view.link(at: CGPoint(x: linkX, y: lineAdvance + 8)) == URL(string: "tag://tag"))
    #expect(view.link(at: CGPoint(x: linkX, y: 8)) == nil)
    #expect(view.link(at: CGPoint(x: linkX, y: lineAdvance * 3 + 8)) == nil)
  }
}
#endif
