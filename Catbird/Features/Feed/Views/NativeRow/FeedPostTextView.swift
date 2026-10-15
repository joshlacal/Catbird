#if os(iOS)
import UIKit

// MARK: - Feed Post Text View

/// Draws a post's attributed text with `UILabel` (which also renders `NSAdaptiveImageGlyph`
/// runs on iOS 18+) and resolves taps on `.feedLink` runs with a TextKit 2 layout of the same
/// text at the same width. The layout is built only when a tap needs it, never while scrolling.
///
/// The view claims a tap only when it lands on a link; every other tap reaches the row, which
/// opens the post.
final class FeedPostTextView: UIView, UIGestureRecognizerDelegate {
  private let label = UILabel()
  private lazy var linkTap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
  var onOpenLink: ((URL) -> Void)?

  var attributedText: NSAttributedString? {
    didSet {
      label.attributedText = attributedText
      setNeedsLayout()
    }
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

  override var accessibilityLabel: String? {
    get { attributedText?.string }
    set {}
  }

  // MARK: - Link Hit Testing

  /// The text stack used for one hit test. It owns all three objects because
  /// `NSTextLayoutManager` only holds its content manager weakly.
  private struct HitTestLayout {
    let content: NSTextContentStorage
    let manager: NSTextLayoutManager
    let container: NSTextContainer
  }

  private func makeHitTestLayout(for text: NSAttributedString) -> HitTestLayout {
    let content = NSTextContentStorage()
    content.attributedString = text
    let manager = NSTextLayoutManager()
    content.addTextLayoutManager(manager)
    let container = NSTextContainer(size: CGSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    manager.textContainer = container
    manager.ensureLayout(for: manager.documentRange)
    return HitTestLayout(content: content, manager: manager, container: container)
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

  /// The link under `point`, laid out exactly as the label draws it.
  func link(at point: CGPoint) -> URL? {
    guard let text = attributedText, text.length > 0, bounds.width > 0 else { return nil }
    let layout = makeHitTestLayout(for: text)
    guard let fragment = layout.manager.textLayoutFragment(for: point) else { return nil }
    let origin = fragment.layoutFragmentFrame.origin
    let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    guard let line = line(at: local, in: fragment) else { return nil }
    // `characterIndex(for:)` answers relative to the paragraph the fragment lays out, and
    // returns the first character of the next line for points past the end of this one.
    let index = line.characterIndex(for: local)
    guard NSLocationInRange(index, line.characterRange) else { return nil }
    let fragmentStart = layout.content.offset(
      from: layout.content.documentRange.location, to: fragment.rangeInElement.location)
    let character = fragmentStart + index
    guard character >= 0, character < text.length else { return nil }
    return text.attribute(.feedLink, at: character, effectiveRange: nil) as? URL
  }

  /// Opens the link under `point`, if any.
  func activateLink(at point: CGPoint) {
    guard let url = link(at: point) else { return }
    onOpenLink?(url)
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
}
#endif
