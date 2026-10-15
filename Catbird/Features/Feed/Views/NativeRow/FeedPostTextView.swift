#if os(iOS)
import Foundation
import UIKit

// MARK: - Feed Post Text View

/// Draws a post's attributed text with `UILabel` (which also renders `NSAdaptiveImageGlyph`
/// runs on iOS 18+) and resolves taps on `.feedLink` runs with a TextKit 2 layout of the same
/// text at the same width. The layout is built only when a tap needs it, never while scrolling.
///
/// The view claims a tap only when it lands on a link; every other tap reaches the row, which
/// opens the post.
///
/// For VoiceOver the view is one static-text element. It offers the row's own actions
/// (`rowAccessibilityActions`, such as "Open post"), then each link as a custom action; links are
/// also reachable through the Links rotor. Double-tapping the element taps a point that is not on
/// a link, so it opens the post like a tap on plain text. The link accessibility objects are built
/// on first use and discarded when the text changes, so configuring a cell does no accessibility
/// work.
final class FeedPostTextView: UIView, UIGestureRecognizerDelegate {
  private let label = UILabel()
  private lazy var linkTap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
  var onOpenLink: ((URL) -> Void)?
  /// Actions VoiceOver offers before the link actions, such as the row's "Open post". They are
  /// kept when the text changes.
  var rowAccessibilityActions: [UIAccessibilityCustomAction] = []

  var attributedText: NSAttributedString? {
    didSet {
      label.attributedText = attributedText
      cachedHitTestLayout = nil
      cachedLinkRuns = nil
      cachedLinkActions = nil
      cachedLinkElements = nil
      setNeedsLayout()
    }
  }

  private struct LinkRun {
    let range: NSRange
    let url: URL
    let name: String
  }

  private var cachedHitTestLayout: HitTestLayout?
  private var cachedLinkRuns: [LinkRun]?
  private var cachedLinkActions: [UIAccessibilityCustomAction]?
  private var cachedLinkElements: [LinkAccessibilityElement]?
  private lazy var linkRotor = UIAccessibilityCustomRotor(systemType: .link) { [weak self] predicate in
    self?.linkRotorItem(for: predicate)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    label.numberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    addSubview(label)
    linkTap.delegate = self
    addGestureRecognizer(linkTap)
    isAccessibilityElement = true
    accessibilityTraits = .staticText
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func layoutSubviews() {
    super.layoutSubviews()
    label.frame = bounds
  }

  // MARK: - Link Hit Testing

  /// The text stack used for one hit test. It owns all three objects because
  /// `NSTextLayoutManager` only holds its content manager weakly.
  private struct HitTestLayout {
    let width: CGFloat
    let direction: UIUserInterfaceLayoutDirection
    let text: NSAttributedString
    let content: NSTextContentStorage
    let manager: NSTextLayoutManager
    let container: NSTextContainer
  }

  /// `text` with every `.natural` paragraph alignment replaced by the side `UILabel` draws it on.
  /// `UILabel` resolves `.natural` from the interface direction, so a right-to-left paragraph in
  /// a left-to-right app is drawn left-aligned; TextKit 2 resolves it from the paragraph's own
  /// direction and would right-align it.
  private func resolvingNaturalAlignment(of text: NSAttributedString) -> NSAttributedString {
    let resolved: NSTextAlignment
    if label.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirection.rightToLeft {
      resolved = NSTextAlignment.right
    } else {
      resolved = NSTextAlignment.left
    }
    let output = NSMutableAttributedString(attributedString: text)
    let key = NSAttributedString.Key.paragraphStyle
    var location = 0
    while location < output.length {
      var run = NSRange(location: 0, length: 0)
      let existing = output.attribute(key, at: location, effectiveRange: &run) as? NSParagraphStyle
      let style = NSMutableParagraphStyle()
      if let existing {
        style.setParagraphStyle(existing)
      }
      if style.alignment == NSTextAlignment.natural {
        style.alignment = resolved
        output.addAttribute(key, value: style, range: run)
      }
      location = NSMaxRange(run)
    }
    return output
  }

  /// The layout for the current text, width and interface direction. It is built on first use
  /// (a tap, or VoiceOver asking for a link's position) and kept until one of them changes.
  private var hitTestLayout: HitTestLayout? {
    guard let text = attributedText, text.length > 0, bounds.width > 0 else { return nil }
    let direction = label.effectiveUserInterfaceLayoutDirection
    if let cachedHitTestLayout, cachedHitTestLayout.width == bounds.width, cachedHitTestLayout.direction == direction {
      return cachedHitTestLayout
    }
    let content = NSTextContentStorage()
    content.attributedString = resolvingNaturalAlignment(of: text)
    let manager = NSTextLayoutManager()
    content.addTextLayoutManager(manager)
    let container = NSTextContainer(size: CGSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    manager.textContainer = container
    manager.ensureLayout(for: manager.documentRange)
    let layout = HitTestLayout(
      width: bounds.width, direction: direction, text: text, content: content, manager: manager, container: container)
    cachedHitTestLayout = layout
    return layout
  }

  /// The line of `fragment` at `point` (fragment coordinates). A line owns the spacing below
  /// it, so a tap between two lines still resolves to the line above.
  private func line(at point: CGPoint, in fragment: NSTextLayoutFragment) -> NSTextLineFragment? {
    let lines = fragment.textLineFragments
    for (index, line) in lines.enumerated() {
      let frame = line.typographicBounds
      guard point.x >= frame.minX, point.x <= frame.maxX, point.y >= frame.minY else { continue }
      if index + 1 < lines.count {
        if point.y < lines[index + 1].typographicBounds.minY { return line }
      } else if point.y <= frame.maxY {
        return line
      }
    }
    return nil
  }

  private func link(at point: CGPoint, in layout: HitTestLayout) -> URL? {
    // The view is as tall as the text rounded up to a whole point, and glyphs such as Arabic
    // descenders reach a fraction of a point below the last line's typographic bounds.
    let usedBottom = layout.manager.usageBoundsForTextContainer.maxY
    guard point.y >= 0, point.y < ceil(usedBottom) else { return nil }
    let probe = CGPoint(x: point.x, y: min(point.y, usedBottom - 0.01))
    guard let fragment = layout.manager.textLayoutFragment(for: probe) else { return nil }
    let origin = fragment.layoutFragmentFrame.origin
    let local = CGPoint(x: probe.x - origin.x, y: probe.y - origin.y)
    guard let line = line(at: local, in: fragment) else { return nil }
    // `characterIndex(for:)` takes a point relative to the line (right-aligned and indented
    // lines do not start at x = 0), answers relative to the paragraph the fragment lays out,
    // and returns the first character of the next line for points past the end of this one.
    let lineOrigin = line.typographicBounds.origin
    let index = line.characterIndex(for: CGPoint(x: local.x - lineOrigin.x, y: local.y - lineOrigin.y))
    guard NSLocationInRange(index, line.characterRange) else { return nil }
    let fragmentStart = layout.content.offset(
      from: layout.content.documentRange.location, to: fragment.rangeInElement.location)
    let character = fragmentStart + index
    guard character >= 0, character < layout.text.length else { return nil }
    return layout.text.attribute(.feedLink, at: character, effectiveRange: nil) as? URL
  }

  /// The link under `point`, laid out the way the label draws the text.
  func link(at point: CGPoint) -> URL? {
    guard let layout = hitTestLayout else { return nil }
    return link(at: point, in: layout)
  }

  /// Opens the link under `point`, if any.
  func activateLink(at point: CGPoint) {
    guard let url = link(at: point) else { return }
    onOpenLink?(url)
  }

  /// The rectangles, in this view's coordinates, that the text of `range` occupies; one per line.
  private func rects(of range: NSRange) -> [CGRect] {
    guard let layout = hitTestLayout else { return [] }
    let documentStart = layout.content.documentRange.location
    guard let start = layout.content.location(documentStart, offsetBy: range.location),
      let end = layout.content.location(start, offsetBy: range.length),
      let textRange = NSTextRange(location: start, end: end)
    else { return [] }
    var rects: [CGRect] = []
    layout.manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
      rects.append(frame)
      return true
    }
    return rects
  }

  // MARK: - Gestures

  /// Only claim taps on a link; any other tap falls through to the row, which opens the post.
  override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
    guard recognizer === linkTap else { return super.gestureRecognizerShouldBegin(recognizer) }
    return link(at: recognizer.location(in: self)) != nil
  }

  @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
    activateLink(at: recognizer.location(in: self))
  }

  // MARK: - Accessibility

  override var accessibilityLabel: String? {
    get { attributedText?.string }
    set {}
  }

  private var linkRuns: [LinkRun] {
    if let cachedLinkRuns { return cachedLinkRuns }
    var runs: [LinkRun] = []
    if let text = attributedText {
      text.enumerateAttribute(.feedLink, in: NSRange(location: 0, length: text.length)) { value, range, _ in
        guard let url = value as? URL else { return }
        let name = text.attributedSubstring(from: range).string.trimmingCharacters(in: .whitespacesAndNewlines)
        runs.append(LinkRun(range: range, url: url, name: name.isEmpty ? url.absoluteString : name))
      }
    }
    cachedLinkRuns = runs
    return runs
  }

  /// The row's actions, then one action per link, named after the link's text.
  override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
    get {
      let actions = rowAccessibilityActions + linkActions
      return actions.isEmpty ? nil : actions
    }
    set {}
  }

  private var linkActions: [UIAccessibilityCustomAction] {
    if let cachedLinkActions { return cachedLinkActions }
    let actions = linkRuns.map { run in
      UIAccessibilityCustomAction(name: run.name) { [weak self] _ in
        guard let onOpenLink = self?.onOpenLink else { return false }
        onOpenLink(run.url)
        return true
      }
    }
    cachedLinkActions = actions
    return actions
  }

  /// The Links rotor steps through the post's links.
  override var accessibilityCustomRotors: [UIAccessibilityCustomRotor]? {
    get { linkRuns.isEmpty ? nil : [linkRotor] }
    set {}
  }

  private var linkElements: [LinkAccessibilityElement] {
    if let cachedLinkElements { return cachedLinkElements }
    let elements = linkRuns.map { LinkAccessibilityElement(textView: self, url: $0.url, range: $0.range, name: $0.name) }
    cachedLinkElements = elements
    return elements
  }

  private func linkRotorItem(for predicate: UIAccessibilityCustomRotorSearchPredicate) -> UIAccessibilityCustomRotorItemResult? {
    let elements = linkElements
    let current = elements.firstIndex { $0 === predicate.currentItem.targetElement }
    let target: Int
    switch predicate.searchDirection {
    case .next: target = current.map { $0 + 1 } ?? 0
    case .previous: target = current.map { $0 - 1 } ?? elements.count - 1
    @unknown default: return nil
    }
    guard elements.indices.contains(target) else { return nil }
    return UIAccessibilityCustomRotorItemResult(targetElement: elements[target], targetRange: nil)
  }

  fileprivate func screenFrame(ofLinkAt range: NSRange) -> CGRect {
    let rects = rects(of: range)
    guard let first = rects.first else { return .zero }
    return UIAccessibility.convertToScreenCoordinates(rects.dropFirst().reduce(first) { $0.union($1) }, in: self)
  }

  fileprivate func screenPath(ofLinkAt range: NSRange) -> UIBezierPath? {
    let path = UIBezierPath()
    for rect in rects(of: range) { path.append(UIBezierPath(rect: rect)) }
    return path.isEmpty ? nil : UIAccessibility.convertToScreenCoordinates(path, in: self)
  }

  fileprivate func openLink(_ url: URL) -> Bool {
    guard let onOpenLink else { return false }
    onOpenLink(url)
    return true
  }

  /// The point VoiceOver taps when the element is double-tapped: the point nearest the center
  /// that is not on a link, so the tap goes to the row and opens the post instead of whichever
  /// link happens to sit at the center. Text that is nothing but links has no such point and
  /// uses the center.
  var plainTextActivationPoint: CGPoint {
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    guard !linkRuns.isEmpty, let layout = hitTestLayout, link(at: center, in: layout) != nil else { return center }
    let step: CGFloat = 6
    var best: (point: CGPoint, distance: CGFloat)?
    for row in stride(from: step / 2, to: bounds.height, by: step) {
      for column in stride(from: step / 2, to: bounds.width, by: step) {
        let point = CGPoint(x: column, y: row)
        let distance = hypot(point.x - center.x, point.y - center.y)
        if distance < (best?.distance ?? .greatestFiniteMagnitude), link(at: point, in: layout) == nil {
          best = (point, distance)
        }
      }
    }
    return best?.point ?? center
  }

  override var accessibilityActivationPoint: CGPoint {
    get {
      // UIKit converts rectangles; a zero-size rectangle carries the point.
      UIAccessibility.convertToScreenCoordinates(CGRect(origin: plainTextActivationPoint, size: .zero), in: self).origin
    }
    set {}
  }
}

// MARK: - Link Accessibility Element

/// One link of a post's text as a VoiceOver rotor target. Its frame is computed from the text
/// layout when VoiceOver asks, so it is current after a width change.
private final class LinkAccessibilityElement: UIAccessibilityElement {
  private weak var textView: FeedPostTextView?
  private let url: URL
  private let range: NSRange

  init(textView: FeedPostTextView, url: URL, range: NSRange, name: String) {
    self.textView = textView
    self.url = url
    self.range = range
    super.init(accessibilityContainer: textView)
    accessibilityLabel = name
    accessibilityTraits = .link
  }

  override var accessibilityFrame: CGRect {
    get { textView?.screenFrame(ofLinkAt: range) ?? .zero }
    set {}
  }

  override var accessibilityPath: UIBezierPath? {
    get { textView?.screenPath(ofLinkAt: range) }
    set {}
  }

  override func accessibilityActivate() -> Bool {
    textView?.openLink(url) ?? false
  }
}
#endif
