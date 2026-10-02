#if targetEnvironment(macCatalyst)
import UIKit

/// UISegmentedControl subclass that draws badge circles on specific segments.
/// Used in the Mac Catalyst NSToolbar for notification and message count badges.
final class BadgedSegmentedControl: UISegmentedControl {
  /// Badge counts keyed by segment index. Zero or nil means no badge.
  private var badges: [Int: Int] = [:]

  func setBadge(_ count: Int, forSegment segment: Int) {
    let oldCount = badges[segment] ?? 0
    guard oldCount != count else { return }
    badges[segment] = count > 0 ? count : nil
    updateAccessibilityLabel(forSegment: segment)
    setNeedsDisplay()
  }

  private func updateAccessibilityLabel(forSegment segment: Int) {
    guard segment < numberOfSegments else { return }
    let baseTitle = titleForSegment(at: segment) ?? ""
    if let count = badges[segment] {
      if let segmentView = subviews[safe: segment] {
        segmentView.accessibilityLabel = "\(baseTitle), \(count) unread"
      }
    } else {
      if let segmentView = subviews[safe: segment] {
        segmentView.accessibilityLabel = baseTitle
      }
    }
  }

  override func draw(_ rect: CGRect) {
    super.draw(rect)
    guard !badges.isEmpty else { return }
    for (segment, count) in badges {
      guard segment < numberOfSegments, count > 0 else { continue }
      drawBadge(count: count, forSegment: segment, in: rect)
    }
  }

  private func drawBadge(count: Int, forSegment segment: Int, in rect: CGRect) {
    let segmentWidth = rect.width / CGFloat(numberOfSegments)
    let segmentX = segmentWidth * CGFloat(segment)
    let badgeSize: CGFloat = count > 9 ? 18 : 16
    let badgeX = segmentX + segmentWidth - badgeSize / 2 - 4
    let badgeY: CGFloat = 2
    let badgeRect = CGRect(x: badgeX, y: badgeY, width: badgeSize, height: badgeSize)
    let path = UIBezierPath(ovalIn: badgeRect)
    UIColor.systemRed.setFill()
    path.fill()
    let text = count > 99 ? "99+" : "\(count)"
    let attrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: count > 99 ? 8 : 10, weight: UIFont.Weight.bold),
      .foregroundColor: UIColor.white
    ]
    let textSize = (text as NSString).size(withAttributes: attrs)
    let textRect = CGRect(
      x: badgeRect.midX - textSize.width / 2,
      y: badgeRect.midY - textSize.height / 2,
      width: textSize.width,
      height: textSize.height
    )
    (text as NSString).draw(in: textRect, withAttributes: attrs)
  }
}

private extension Collection {
  subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
#endif
