//
//  PostListPinnedHeaderLayout.swift
//  Catbird
//
//  The list layout behind PostListCollectionController, and the scroll rule for a
//  list whose section header pins under the navigation bar (the profile tab picker).
//

import CoreGraphics

/// Where a post list with a pinned header lands when it switches to another scroll
/// position key, as a profile does when it switches tabs. Offsets are normalized: 0 is
/// the top of the content.
enum PostListPinnedScrollRestoration {
  /// How far short of the pin offset a list still counts as pinned, so rounding in
  /// the content offset doesn't drop a pinned header back into the content.
  static let pinTolerance: CGFloat = 0.5

  /// - Parameters:
  ///   - saved: the offset the target key last had, if it was shown before.
  ///   - current: the list's offset now, before the switch.
  ///   - pinOffset: the offset at which the pinned header reaches the bar, or nil for a
  ///     list without a pinned header.
  static func offset(saved: CGFloat?, current: CGFloat, pinOffset: CGFloat?) -> CGFloat {
    // No pinned header: each key keeps its own place, as before.
    guard let pinOffset else { return saved ?? 0 }
    // The header is still in view: leave it exactly where it is.
    guard current >= pinOffset - pinTolerance else { return max(0, current) }
    // Pinned: stay pinned, and go back to the target's own place if it was further down.
    return max(saved ?? 0, pinOffset)
  }
}

#if os(iOS)
import UIKit

/// A compositional list layout that pins one section's boundary header under the top
/// bars, including in a list that draws under a transparent navigation bar.
///
/// `UICollectionViewCompositionalLayout` pins headers to the top of the content-inset
/// rect. A list that extends under the top bar cancels its top inset
/// (`PostListCollectionController.applyContentInsetBehavior()`), so that rect starts at
/// the top of the screen and the header would pin behind the status and navigation
/// bars. This layout moves the pin line down to the bottom of the bars, and keeps the
/// content tall enough for the header to reach it whatever the section under it holds.
/// With no pinned section it returns exactly what the compositional layout computes.
final class PostListPinnedHeaderLayout: UICollectionViewCompositionalLayout {
  /// The section whose header pins, or nil for a list without one.
  var pinnedSection: Int?
  /// The height the content above the pinned header was last laid out at.
  private var heightAbovePinnedHeader: CGFloat?

  /// How far below the top of the bounds the header pins: the bottom of the top bars.
  var pinInset: CGFloat {
    guard let collectionView else { return 0 }
    return max(collectionView.adjustedContentInset.top, collectionView.safeAreaInsets.top)
  }

  /// The content y of the pinned header while it is not pinned: the end of the sections above.
  var pinnedHeaderRestingY: CGFloat? {
    guard let pinnedSection, let collectionView,
          pinnedSection < collectionView.numberOfSections else { return nil }
    for section in stride(from: pinnedSection - 1, through: 0, by: -1) {
      let count = collectionView.numberOfItems(inSection: section)
      guard count > 0 else { continue }
      if let frame = super.layoutAttributesForItem(at: IndexPath(item: count - 1, section: section))?.frame {
        return frame.maxY
      }
    }
    return 0
  }

  /// The normalized offset (content offset plus top inset) at which the header pins.
  var pinOffset: CGFloat? {
    guard let collectionView, let restingY = pinnedHeaderRestingY else { return nil }
    return max(0, restingY - pinInset + collectionView.adjustedContentInset.top)
  }

  /// The section above the pinned header, holding the one item over it (the profile
  /// information). A list section would estimate that item at 44 pt each time a resize (a
  /// rotation) lays it out again: until the item is in view and measured, the content above
  /// the header collapses, and over a short tab the offset is clamped to the top. This one
  /// starts from the height the item last had.
  func sectionAbovePinnedHeader() -> NSCollectionLayoutSection {
    let size = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1), heightDimension: .estimated(heightAbovePinnedHeader ?? 44)
    )
    return NSCollectionLayoutSection(group: .vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)]))
  }

  override func prepare() {
    super.prepare()
    if let restingY = pinnedHeaderRestingY, restingY > 0 { heightAbovePinnedHeader = restingY }
  }

  override var collectionViewContentSize: CGSize {
    var size = super.collectionViewContentSize
    guard let collectionView, let restingY = pinnedHeaderRestingY else { return size }
    // Enough room below the header to scroll it up to the pin line, so a short tab,
    // or a switch to one while pinned, still lets the header pin.
    let minimum = restingY - pinInset + collectionView.bounds.height
      - collectionView.adjustedContentInset.bottom
    size.height = max(size.height, minimum)
    return size
  }

  override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
    let attributes = super.layoutAttributesForElements(in: rect)
    guard let pinnedSection, let collectionView, pinnedSection < collectionView.numberOfSections else {
      return attributes
    }
    var pinned = attributes?.map(pinningUnderBars) ?? []
    // The compositional layout keeps a pinned header inside its section, so while the
    // content is shorter than the offset (a switch to a short tab, before its offset is
    // restored) it leaves the header out, and the collection view would drop the view
    // with the picker's state. A pinned header is always where it pins.
    let kind = UICollectionView.elementKindSectionHeader
    let isPinnedHeader = { (item: UICollectionViewLayoutAttributes) in
      item.representedElementKind == kind && item.indexPath.section == pinnedSection
    }
    if !pinned.contains(where: isPinnedHeader),
       let header = layoutAttributesForSupplementaryView(ofKind: kind, at: IndexPath(item: 0, section: pinnedSection)),
       header.frame.intersects(rect) {
      pinned.append(header)
    }
    return pinned
  }

  override func layoutAttributesForSupplementaryView(
    ofKind elementKind: String, at indexPath: IndexPath
  ) -> UICollectionViewLayoutAttributes? {
    let attributes = super.layoutAttributesForSupplementaryView(ofKind: elementKind, at: indexPath)
    guard pinnedSection != nil else { return attributes }
    return attributes.map(pinningUnderBars)
  }

  /// Lowers the pinned header from the compositional layout's pin line to the bars'.
  /// The compositional layout places it at max(resting y, its own pin line), which is
  /// never below the bars' line, so taking the larger of the two moves only a pinned header.
  private func pinningUnderBars(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
    guard attributes.representedElementCategory == .supplementaryView,
          attributes.representedElementKind == UICollectionView.elementKindSectionHeader,
          attributes.indexPath.section == pinnedSection, let collectionView else { return attributes }
    let pinLine = collectionView.contentOffset.y + pinInset
    guard attributes.frame.minY < pinLine,
          let pinned = attributes.copy() as? UICollectionViewLayoutAttributes else { return attributes }
    pinned.frame.origin.y = pinLine
    return pinned
  }
}

/// A collection view that says when it has finished a layout pass, so its controller can
/// keep a pinned header pinned when a pass moves the pin line.
final class LayoutReportingCollectionView: UICollectionView {
  var didLayoutSubviews: (() -> Void)?

  override func layoutSubviews() {
    super.layoutSubviews()
    didLayoutSubviews?()
  }
}
#endif
