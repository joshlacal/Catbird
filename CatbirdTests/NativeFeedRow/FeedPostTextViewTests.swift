#if os(iOS)
import Testing
import UIKit
@testable import Catbird

@MainActor
@Suite("Feed post text view")
struct FeedPostTextViewTests {
  private static let font = UIFont.systemFont(ofSize: 17)

  /// The constant line height "Tight" gives this font.
  private static let tightPlacement = AppLineHeightPlacement.resolve(font: font, factor: FontManager.tightLineHeightFactor)

  private func attributes(
    lineSpacing: CGFloat = 0, kerning: CGFloat = 0, placement: AppLineHeightPlacement? = nil
  ) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = lineSpacing
    placement?.apply(to: paragraph)
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

  private static let mixedDirectionTokens = [
    "#firstTag", "@someone.test", "https://example.com/path", "#lastTag", "#עברית", "@alice.test", "#תגית", "#عربي",
    "@bob.test", "#وسم"
  ]

  /// English wrapped text with emoji, then Hebrew and Arabic paragraphs whose last lines are short.
  private static let mixedDirectionString =
    "Opening 🦋 words of a post 🏳️‍🌈 with #firstTag in them, then a long stretch of 👩🏽‍💻 plain text that has to wrap onto several lines before it reaches @someone.test and finally https://example.com/path at the end of the first paragraph.\n\nA second paragraph with #lastTag and enough more words that it wraps onto another line too\n\nשלום עולם #עברית וגם @alice.test ועוד מילים רבות כדי לעטוף שורה ועוד #תגית בסוף\n\nمرحبا بالعالم #عربي و @bob.test وكلمات أخرى كثيرة لكي تلتف على السطر #وسم هنا"

  /// The hit test builds its own text layout, so it must agree with what `UILabel` paints. Draw
  /// the view with link runs in red and require that every solidly red pixel is a link hit and
  /// every solidly black pixel is not.
  private func expectHitsMatchDrawing(
    lineSpacing: CGFloat, kerning: CGFloat, tight: Bool = false, direction: UISemanticContentAttribute
  ) throws {
    let string = Self.mixedDirectionString
    let placement = tight ? Self.tightPlacement : nil
    let text = NSMutableAttributedString(
      string: string, attributes: attributes(lineSpacing: lineSpacing, kerning: kerning, placement: placement))
    for token in Self.mixedDirectionTokens {
      let range = (string as NSString).range(of: token)
      try #require(range.location != NSNotFound, "missing \(token)")
      text.addAttribute(.feedLink, value: URL(string: "link://\(range.location)")!, range: range)
      text.addAttribute(.foregroundColor, value: UIColor.red, range: range)
    }
    let textWidth: CGFloat = 280
    let height = FeedRowLayoutEngine.textHeight(text, width: textWidth)
    let view = FeedPostTextView(frame: CGRect(x: 0, y: 0, width: textWidth, height: height))
    view.semanticContentAttribute = direction
    view.backgroundColor = .white
    view.attributedText = text
    view.linePlacement = placement
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
    #expect(redPixels > 800 && blackPixels > 3000, "the text was not drawn")
    #expect(misses.isEmpty, "\(misses.count) disagreements, first: \(misses.prefix(3))")
  }

  @Test("Link hits agree with the pixels the label draws, in left-to-right and right-to-left paragraphs", arguments: [
    (lineSpacing: CGFloat(0), kerning: CGFloat(0), tight: false),
    (lineSpacing: CGFloat(4), kerning: CGFloat(0.1), tight: false),
    (lineSpacing: CGFloat(8), kerning: CGFloat(-0.3), tight: false),
    (lineSpacing: CGFloat(0), kerning: CGFloat(0.1), tight: true)
  ])
  func hitsMatchDrawing(lineSpacing: CGFloat, kerning: CGFloat, tight: Bool) throws {
    try expectHitsMatchDrawing(lineSpacing: lineSpacing, kerning: kerning, tight: tight, direction: .forceLeftToRight)
  }

  @Test("Link hits agree with the pixels the label draws in a right-to-left interface", arguments: [
    (lineSpacing: CGFloat(0), kerning: CGFloat(0), tight: false),
    (lineSpacing: CGFloat(4), kerning: CGFloat(0.1), tight: false),
    (lineSpacing: CGFloat(0), kerning: CGFloat(0.1), tight: true)
  ])
  func hitsMatchDrawingInRightToLeftInterface(lineSpacing: CGFloat, kerning: CGFloat, tight: Bool) throws {
    try expectHitsMatchDrawing(lineSpacing: lineSpacing, kerning: kerning, tight: tight, direction: .forceRightToLeft)
  }

  @Test("At Tight the label draws the lines lower by the glyph offset, and link frames follow")
  func tightLabelAndLinkFramesFollowPlacement() throws {
    let string = "see #swift today"
    let text = NSMutableAttributedString(string: string, attributes: attributes(placement: Self.tightPlacement))
    text.addAttribute(.feedLink, value: URL(string: "tag://swift")!, range: NSRange(location: 4, length: 6))
    let height = ceil(Self.tightPlacement.height(lines: 1) * 3) / 3
    let plain = FeedPostTextView(frame: CGRect(x: 0, y: 0, width: 300, height: height))
    plain.attributedText = text
    let tight = FeedPostTextView(frame: CGRect(x: 0, y: 0, width: 300, height: height))
    tight.attributedText = text
    tight.linePlacement = Self.tightPlacement
    // UIAccessibility converts a view's geometry to screen coordinates. On iOS 26 it returns
    // an empty frame for unattached views, so both drawings need a real window for this check.
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 300, height: 100)
    let controller = UIViewController()
    window.rootViewController = controller
    controller.view.addSubview(plain)
    controller.view.addSubview(tight)
    window.isHidden = false
    defer { window.isHidden = true; window.rootViewController = nil }
    window.layoutIfNeeded()
    let x = width(of: "see ") + 10
    // A point just below the TextKit line is on the link only once the label moves down.
    let lowered = CGPoint(x: x, y: Self.tightPlacement.lineHeight + Self.tightPlacement.glyphOffset / 2)
    #expect(plain.link(at: lowered) == nil)
    #expect(tight.link(at: lowered) == URL(string: "tag://swift"))
    // The band the label leaves above the first line belongs to that line.
    #expect(tight.link(at: CGPoint(x: x, y: Self.tightPlacement.glyphOffset / 2)) == URL(string: "tag://swift"))
    #expect(tight.link(at: CGPoint(x: x, y: -1)) == nil)

    // The link's VoiceOver frame moves with the drawn text.
    func linkFrame(_ view: FeedPostTextView) throws -> CGRect {
      let rotor = try #require(view.accessibilityCustomRotors?.first)
      let predicate = UIAccessibilityCustomRotorSearchPredicate()
      predicate.currentItem = UIAccessibilityCustomRotorItemResult(targetElement: view, targetRange: nil)
      predicate.searchDirection = .next
      let element = try #require(rotor.itemSearchBlock(predicate)?.targetElement as? UIAccessibilityElement)
      return element.accessibilityFrame
    }
    let shift = try linkFrame(tight).minY - linkFrame(plain).minY
    #expect(abs(shift - Self.tightPlacement.glyphOffset) < 0.01, "shift \(shift)")
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

@MainActor
@Suite("Feed post text view accessibility")
struct FeedPostTextViewAccessibilityTests {
  private static let font = UIFont.systemFont(ofSize: 17)

  /// "Read #swift and @alice.test or https://example.com/x today" with its three links.
  private func linkedText(_ string: String = "Read #swift and @alice.test or https://example.com/x today") -> NSAttributedString {
    let text = NSMutableAttributedString(string: string, attributes: [.font: Self.font, .foregroundColor: UIColor.black])
    for token in ["#swift", "@alice.test", "https://example.com/x"] {
      let range = (string as NSString).range(of: token)
      guard range.location != NSNotFound else { continue }
      text.addAttribute(.feedLink, value: URL(string: "link://\(token.count)")!, range: range)
    }
    return text
  }

  private func makeView(_ text: NSAttributedString?, width: CGFloat = 300) -> FeedPostTextView {
    let view = FeedPostTextView(frame: CGRect(x: 0, y: 0, width: width, height: 120))
    view.attributedText = text
    return view
  }

  @Test("Each link is a custom action named after its text, in reading order")
  func customActionNames() {
    let view = makeView(linkedText())
    let actions = view.accessibilityCustomActions ?? []
    #expect(actions.map(\.name) == ["#swift", "@alice.test", "https://example.com/x"])
  }

  @Test("Invoking an action opens that link")
  func customActionOpensLink() {
    let view = makeView(linkedText())
    var opened: [URL] = []
    view.onOpenLink = { opened.append($0) }
    let actions = view.accessibilityCustomActions ?? []
    #expect(actions.count == 3)
    #expect(actions[1].actionHandler?(actions[1]) == true)
    #expect(actions[0].actionHandler?(actions[0]) == true)
    #expect(opened == [URL(string: "link://11")!, URL(string: "link://6")!])
  }

  @Test("An action does nothing and reports it when no handler is set")
  func customActionWithoutHandler() {
    let view = makeView(linkedText())
    let action = view.accessibilityCustomActions?.first
    #expect(action?.actionHandler?(action!) == false)
  }

  @Test("Actions are rebuilt when the text changes and cleared when it has no links")
  func actionsRebuilt() {
    let view = makeView(linkedText())
    #expect(view.accessibilityCustomActions?.count == 3)
    let replacement = NSMutableAttributedString(string: "Only #tag here", attributes: [.font: Self.font])
    replacement.addAttribute(.feedLink, value: URL(string: "tag://tag")!, range: NSRange(location: 5, length: 4))
    view.attributedText = replacement
    #expect(view.accessibilityCustomActions?.map(\.name) == ["#tag"])
    view.attributedText = NSAttributedString(string: "No links", attributes: [.font: Self.font])
    #expect(view.accessibilityCustomActions == nil)
    view.attributedText = linkedText()
    #expect(view.accessibilityCustomActions?.count == 3)
    view.attributedText = nil
    #expect(view.accessibilityCustomActions == nil)
    #expect(view.accessibilityCustomRotors == nil)
  }

  @Test("Row actions come before the link actions and are kept when the text changes")
  func rowActionsFirst() {
    let view = makeView(linkedText())
    let openPost = UIAccessibilityCustomAction(name: "Open post") { _ in true }
    view.rowAccessibilityActions = [openPost]
    #expect(view.accessibilityCustomActions?.map(\.name) == ["Open post", "#swift", "@alice.test", "https://example.com/x"])
    view.attributedText = NSAttributedString(string: "No links", attributes: [.font: Self.font])
    #expect(view.accessibilityCustomActions?.map(\.name) == ["Open post"])
    view.attributedText = nil
    #expect(view.accessibilityCustomActions?.first === openPost)
  }

  @Test("A link that spans formatting changes is one action")
  func linkAcrossAttributeRuns() {
    let text = NSMutableAttributedString(string: "see #swiftui now", attributes: [.font: Self.font])
    let url = URL(string: "tag://swiftui")!
    text.addAttribute(.feedLink, value: url, range: NSRange(location: 4, length: 8))
    text.addAttribute(.foregroundColor, value: UIColor.blue, range: NSRange(location: 4, length: 3))
    text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 7, length: 5))
    let view = makeView(text)
    #expect(view.accessibilityCustomActions?.map(\.name) == ["#swiftui"])
  }

  @Test("The Links rotor steps through the links in both directions")
  func linkRotor() throws {
    let view = makeView(linkedText())
    var opened: [URL] = []
    view.onOpenLink = { opened.append($0) }
    let rotor = try #require(view.accessibilityCustomRotors?.first)
    #expect(rotor.systemRotorType == .link)

    func result(from current: NSObjectProtocol, _ direction: UIAccessibilityCustomRotor.Direction) -> UIAccessibilityCustomRotorItemResult? {
      let predicate = UIAccessibilityCustomRotorSearchPredicate()
      predicate.currentItem = UIAccessibilityCustomRotorItemResult(targetElement: current, targetRange: nil)
      predicate.searchDirection = direction
      return rotor.itemSearchBlock(predicate)
    }

    let first = try #require(result(from: view, .next))
    let firstElement = try #require(first.targetElement as? UIAccessibilityElement)
    #expect(firstElement.accessibilityLabel == "#swift")
    #expect(firstElement.accessibilityTraits.contains(.link))
    #expect(firstElement.accessibilityContainer as? FeedPostTextView === view)

    let second = try #require(result(from: firstElement, .next))
    let secondElement = try #require(second.targetElement as? UIAccessibilityElement)
    #expect(secondElement.accessibilityLabel == "@alice.test")
    let third = try #require(result(from: secondElement, .next))
    let thirdElement = try #require(third.targetElement as? UIAccessibilityElement)
    #expect(thirdElement.accessibilityLabel == "https://example.com/x")
    #expect(result(from: thirdElement, .next) == nil)

    let back = try #require(result(from: thirdElement, .previous))
    #expect((back.targetElement as? UIAccessibilityElement)?.accessibilityLabel == "@alice.test")
    #expect(result(from: firstElement, .previous) == nil)
    let last = try #require(result(from: view, .previous))
    #expect((last.targetElement as? UIAccessibilityElement)?.accessibilityLabel == "https://example.com/x")

    #expect(secondElement.accessibilityActivate())
    #expect(opened == [URL(string: "link://11")!])
  }

  @Test("A rotor target's frame covers its link's text")
  func linkElementFrame() throws {
    let view = makeView(linkedText())
    let rotor = try #require(view.accessibilityCustomRotors?.first)
    let predicate = UIAccessibilityCustomRotorSearchPredicate()
    predicate.currentItem = UIAccessibilityCustomRotorItemResult(targetElement: view, targetRange: nil)
    predicate.searchDirection = .next
    let element = try #require(rotor.itemSearchBlock(predicate)?.targetElement as? UIAccessibilityElement)

    let prefix = ("Read " as NSString).size(withAttributes: [.font: Self.font]).width
    let linkWidth = ("#swift" as NSString).size(withAttributes: [.font: Self.font]).width
    let expected = UIAccessibility.convertToScreenCoordinates(
      CGRect(x: prefix, y: 0, width: linkWidth, height: Self.font.lineHeight), in: view)
    #expect(abs(element.accessibilityFrame.minX - expected.minX) < 1)
    #expect(abs(element.accessibilityFrame.width - expected.width) < 1)
    #expect(abs(element.accessibilityFrame.height - expected.height) < 2)
    #expect(element.accessibilityPath != nil)
  }

  /// One line of plain words after a hashtag that covers the middle of the view.
  private func hashtagThenPlainText() -> FeedPostTextView {
    let string = "#aVeryLongHashtagThatFillsTheMiddleOfTheLine and then some plain words"
    let text = NSMutableAttributedString(string: string, attributes: [.font: Self.font])
    text.addAttribute(
      .feedLink, value: URL(string: "tag://long")!, range: (string as NSString).range(of: "#aVeryLongHashtagThatFillsTheMiddleOfTheLine"))
    let view = makeView(text, width: 400)
    view.frame.size.height = 24
    return view
  }

  @Test("Double-tapping the element taps a point that is not on a link")
  func activationPointAvoidsLinks() {
    let view = hashtagThenPlainText()
    #expect(view.link(at: CGPoint(x: view.bounds.midX, y: view.bounds.midY)) != nil)

    let point = view.plainTextActivationPoint
    #expect(view.bounds.contains(point))
    #expect(view.link(at: point) == nil)
    let expected = UIAccessibility.convertToScreenCoordinates(CGRect(origin: point, size: .zero), in: view).origin
    #expect(view.accessibilityActivationPoint == expected)
  }

  @Test("Without links the activation point is the center")
  func activationPointWithoutLinks() {
    let view = makeView(NSAttributedString(string: "Just plain words", attributes: [.font: Self.font]))
    #expect(view.plainTextActivationPoint == CGPoint(x: view.bounds.midX, y: view.bounds.midY))
  }

  @Test("A center that is not on a link stays the activation point")
  func activationPointKeepsPlainCenter() {
    let string = "#a then a long run of plain words in the middle of the line"
    let text = NSMutableAttributedString(string: string, attributes: [.font: Self.font])
    text.addAttribute(.feedLink, value: URL(string: "tag://a")!, range: NSRange(location: 0, length: 2))
    let view = makeView(text, width: 400)
    view.frame.size.height = 24
    #expect(view.link(at: CGPoint(x: view.bounds.midX, y: view.bounds.midY)) == nil)
    #expect(view.plainTextActivationPoint == CGPoint(x: view.bounds.midX, y: view.bounds.midY))
  }

  @Test("Text that is only links still has an activation point inside the view")
  func activationPointAllLinks() {
    let string = "#onlyALink"
    let text = NSMutableAttributedString(string: string, attributes: [.font: Self.font])
    text.addAttribute(.feedLink, value: URL(string: "tag://only")!, range: NSRange(location: 0, length: 10))
    let view = makeView(text, width: 100)
    view.frame.size.height = 20
    #expect(view.bounds.contains(view.plainTextActivationPoint))
  }
}
#endif
