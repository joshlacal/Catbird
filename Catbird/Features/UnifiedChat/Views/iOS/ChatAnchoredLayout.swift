#if os(iOS)
import UIKit
import SwiftUI

/// Compensates in the same layout transaction as a hosting cell's intrinsic-size
/// change, including embeds that resolve without a message snapshot update.
final class ChatAnchoredLayout: UICollectionViewFlowLayout {
  override init() {
    super.init()
    scrollDirection = .vertical
    minimumLineSpacing = 4
    minimumInteritemSpacing = 0
    sectionInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func prepare() {
    if let collectionView {
      let width = collectionView.bounds.width - collectionView.adjustedContentInset.left
        - collectionView.adjustedContentInset.right
      if width > 0, abs(estimatedItemSize.width - width) > 0.5 {
        estimatedItemSize = CGSize(width: width, height: 80)
      }
    }
    super.prepare()
  }

  override func shouldInvalidateLayout(
    forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
    withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
  ) -> Bool {
    abs(preferredAttributes.size.height - originalAttributes.size.height) > 0.5
      || abs(preferredAttributes.size.width - originalAttributes.size.width) > 0.5
  }

  var preservesSelfSizingAnchor = true
  fileprivate var managesReadingAnchor = false

  override func invalidationContext(
    forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
    withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
  ) -> UICollectionViewLayoutInvalidationContext {
    let context = super.invalidationContext(
      forPreferredLayoutAttributes: preferredAttributes,
      withOriginalAttributes: originalAttributes
    )
    if managesReadingAnchor { context.contentOffsetAdjustment.y = 0; return context }
    guard preservesSelfSizingAnchor, let collectionView,
      originalAttributes.representedElementCategory == .cell,
      abs(preferredAttributes.size.width - originalAttributes.size.width) < 0.5
    else { return context }

    let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
    let anchor = collectionView.indexPathsForVisibleItems.filter { indexPath in
      guard let attributes = layoutAttributesForItem(at: indexPath) else { return false }
      return attributes.frame.maxY > visibleTop
    }.min()
    // Replace UIKit's suggested vertical adjustment so compensation is applied
    // exactly once; preserve any horizontal adjustment from the superclass.
    context.contentOffsetAdjustment.y = ChatScrollGeometry.resizeAdjustment(
      oldHeight: originalAttributes.size.height,
      newHeight: preferredAttributes.size.height,
      resizedItem: originalAttributes.indexPath.item,
      anchorItem: anchor?.item,
      contentHeight: collectionViewContentSize.height,
      offsetY: collectionView.contentOffset.y,
      viewportHeight: collectionView.bounds.height,
      topInset: collectionView.adjustedContentInset.top,
      bottomInset: collectionView.adjustedContentInset.bottom,
      // Bottom following belongs to the collection layout boundary, not this callback.
      isInteracting: true
    )
    return context
  }
}
/// A transcript always has one full-width cell per row. Flow layout must not
/// adopt a hosting view's narrower intrinsic width and then rewrap its text.
final class ChatTranscriptCell: UICollectionViewCell {
  // The collection owns keyboard and safe-area insets. Applying the window's
  // safe area again inside each hosting cell changes its fitted height on scroll.
  override var safeAreaInsets: UIEdgeInsets { .zero }

  #if DEBUG
  private(set) var lastPreferredSize: CGSize?
  #endif
  override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
    let attributes = super.preferredLayoutAttributesFitting(layoutAttributes).copy() as! UICollectionViewLayoutAttributes
    let size = contentView.systemLayoutSizeFitting(
      CGSize(width: layoutAttributes.size.width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )
    attributes.size = CGSize(width: layoutAttributes.size.width, height: ceil(size.height))
    #if DEBUG
    lastPreferredSize = attributes.size
    #endif
    return attributes
  }
}

/// Bottom intent must be captured against the previous completed layout. During
/// preferred-size invalidation, UIKit may already expose the new content height.
final class ChatTranscriptCollectionView: UICollectionView {
  override init(frame: CGRect, collectionViewLayout layout: UICollectionViewLayout) {
    super.init(frame: frame, collectionViewLayout: layout)
    selfSizingInvalidation = .enabledIncludingConstraints
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var insetChangeWasAtBottom = false
  private var pendingInsetBottomFollow = false

  override var contentInset: UIEdgeInsets {
    willSet {
      let bottom = max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
      insetChangeWasAtBottom = abs(contentOffset.y - bottom) <= 24
    }
    didSet {
      pendingInsetBottomFollow = pendingInsetBottomFollow || insetChangeWasAtBottom
      setNeedsLayout()
    }
  }

  private var settledBottomOffsetY: CGFloat?
  private var isRestoringBottom = false

  override func layoutSubviews() {
    guard !isRestoringBottom else {
      super.layoutSubviews()
      return
    }
    let layout = collectionViewLayout as? ChatAnchoredLayout
    let mayFollow = layout?.preservesSelfSizingAnchor == true
      && !isTracking && !isDragging && !isDecelerating
    let wasAtBottom = settledBottomOffsetY.map { abs(contentOffset.y - $0) <= 24 } ?? false

    let visibleTop = contentOffset.y + adjustedContentInset.top
    let readerCell = visibleCells.filter { $0.frame.maxY > visibleTop }
      .min { $0.frame.minY < $1.frame.minY }
    let readerIndex = readerCell.flatMap { indexPath(for: $0) }
    let readerY = readerCell.map { $0.frame.minY - contentOffset.y }
    layout?.managesReadingAnchor = layout?.preservesSelfSizingAnchor == true
    super.layoutSubviews()
    layout?.managesReadingAnchor = false
    if mayFollow && (wasAtBottom || pendingInsetBottomFollow) {
      isRestoringBottom = true
      // Moving to the bottom can materialize another estimated cell. Settle its
      // measurement before recording the next baseline, without an animation.
      for _ in 0..<2 {
        let bottom = max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
        if abs(contentOffset.y - bottom) > 0.5 { contentOffset.y = bottom }
        super.layoutSubviews()
      }
      isRestoringBottom = false
    } else if layout?.preservesSelfSizingAnchor == true,
      let readerCell, let readerIndex, let readerY,
      indexPath(for: readerCell) == readerIndex {
      let bottom = max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
      let target = min(bottom, max(-adjustedContentInset.top, readerCell.frame.minY - readerY))
      if abs(target - contentOffset.y) > 0.5 {
        isRestoringBottom = true
        contentOffset.y = target
        isRestoringBottom = false
      }
    }
    pendingInsetBottomFollow = false
    settledBottomOffsetY = max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
  }
}

/// Shared by the controller and hosting-cell fixtures so snapshot restoration
/// and late intrinsic-size compensation are exercised together.
@MainActor
struct ChatVisibleItemAnchor<Item: Hashable> {
  let item: Item
  let viewportY: CGFloat

  static func capture(
    in collectionView: UICollectionView,
    itemAt: (IndexPath) -> Item?,
    include: (Item) -> Bool
  ) -> Self? {
    let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
    for indexPath in collectionView.indexPathsForVisibleItems.sorted() {
      guard let item = itemAt(indexPath), include(item),
        let attributes = collectionView.layoutAttributesForItem(at: indexPath),
        attributes.frame.maxY > visibleTop else { continue }
      return Self(item: item, viewportY: attributes.frame.minY - collectionView.contentOffset.y)
    }
    return nil
  }

  func restore(in collectionView: UICollectionView, indexPathFor: (Item) -> IndexPath?) {
    guard let indexPath = indexPathFor(item),
      let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return }
    let target = attributes.frame.minY - viewportY
    guard abs(target - collectionView.contentOffset.y) > 0.5 else { return }
    let bottom = max(
      -collectionView.adjustedContentInset.top,
      collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom
    )
    collectionView.contentOffset.y = min(bottom, max(-collectionView.adjustedContentInset.top, target))
  }
}
#endif

#if os(iOS)
/// Notify UIKit after SwiftUI resolves new intrinsic content, including shrink.
/// The weak cell reference avoids retaining a reusable cell through its content.
struct ChatTranscriptContent<Content: View>: View {
  private weak var cell: ChatTranscriptCell?
  private let content: Content

  init(cell: ChatTranscriptCell, @ViewBuilder content: () -> Content) {
    self.cell = cell
    self.content = content()
  }

  var body: some View {
    content
      .fixedSize(horizontal: false, vertical: true)
      .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak cell] _ in
        cell?.invalidateIntrinsicContentSize()
      }
  }
}
#endif
