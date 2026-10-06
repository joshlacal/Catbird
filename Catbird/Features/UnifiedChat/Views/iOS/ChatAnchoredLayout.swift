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
        estimatedItemSize = CGSize(width: width, height: Self.defaultEstimatedHeight)
        measuredHeights.removeAll()
      }
    }
    super.prepare()
  }

  static let defaultEstimatedHeight: CGFloat = 80

  /// Stable identity for the item at an index path (message ID). When set, each
  /// item's last fitted height becomes its estimate, so a full re-layout (any
  /// snapshot apply) does not reset off-screen rows to the flat default and
  /// shrink the scrollable range.
  var measuredItemKey: ((IndexPath) -> AnyHashable?)?
  private var measuredHeights: [AnyHashable: CGFloat] = [:]

  func estimatedSize(at indexPath: IndexPath) -> CGSize {
    let height = measuredItemKey?(indexPath).flatMap { measuredHeights[$0] } ?? Self.defaultEstimatedHeight
    return CGSize(width: estimatedItemSize.width, height: height)
  }

  override func shouldInvalidateLayout(
    forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
    withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
  ) -> Bool {
    if preferredAttributes.representedElementCategory == .cell,
      abs(preferredAttributes.size.width - estimatedItemSize.width) < 0.5,
      let key = measuredItemKey?(preferredAttributes.indexPath) {
      measuredHeights[key] = preferredAttributes.size.height
    }
    return abs(preferredAttributes.size.height - originalAttributes.size.height) > 0.5
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
  // The outer viewport owns keyboard and safe-area space. Applying the window's
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
    // SwiftUI excludes navigation and keyboard. The measured footer is our sole inset.
    contentInsetAdjustmentBehavior = .never
    bounces = true
    alwaysBounceVertical = true
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

  // Layout attribute queries can re-prepare the layout and change contentSize
  // outside layoutSubviews. Schedule a pass so bottom follow still evaluates.
  override var contentSize: CGSize {
    didSet { if contentSize != oldValue { setNeedsLayout() } }
  }

  private var settledBottomOffsetY: CGFloat?
  private var settledContentSize = CGSize.zero
  private var settledViewportSize = CGSize.zero
  private var settledInsets = UIEdgeInsets.zero
  private var isRestoringBottom = false
  private var viewportReadingAnchor: (cell: UICollectionViewCell, index: IndexPath, y: CGFloat)?

  override var bounds: CGRect {
    willSet {
      guard newValue.size != bounds.size, bounds.height > 0 else { return }
      // Capture against the old viewport before UIKit reacts to a keyboard or
      // growing composer. Keeping a reader's origin and bottom intent are distinct.
      let bottom = max(-adjustedContentInset.top,
        contentSize.height - bounds.height + adjustedContentInset.bottom)
      pendingInsetBottomFollow = pendingInsetBottomFollow || abs(contentOffset.y - bottom) <= 24
      if viewportReadingAnchor == nil {
        let visibleTop = contentOffset.y + adjustedContentInset.top
        if let cell = visibleCells.filter({ $0.frame.maxY > visibleTop })
          .min(by: { $0.frame.minY < $1.frame.minY }), let index = indexPath(for: cell) {
          viewportReadingAnchor = (cell, index, cell.frame.minY - contentOffset.y)
        }
      }
    }
  }

  override func layoutSubviews() {
    guard !isRestoringBottom else {
      super.layoutSubviews()
      return
    }
    let layout = collectionViewLayout as? ChatAnchoredLayout
    let isInteracting = isTracking || isDragging || isDecelerating
    let wasOverscrolling = contentOffset.y < -adjustedContentInset.top - 0.5
      || settledBottomOffsetY.map { contentOffset.y > $0 + 0.5 } == true
    let mayFollow = layout?.preservesSelfSizingAnchor == true
      && !isInteracting && !wasOverscrolling && !UIAccessibility.isVoiceOverRunning
    let wasAtBottom = settledBottomOffsetY.map { abs(contentOffset.y - $0) <= 24 } ?? false

    let visibleTop = contentOffset.y + adjustedContentInset.top
    let readerCell = viewportReadingAnchor?.cell ?? visibleCells.filter { $0.frame.maxY > visibleTop }
      .min { $0.frame.minY < $1.frame.minY }
    let readerIndex = viewportReadingAnchor?.index ?? readerCell.flatMap { indexPath(for: $0) }
    let readerY = viewportReadingAnchor?.y ?? readerCell.map { $0.frame.minY - contentOffset.y }
    layout?.managesReadingAnchor = layout?.preservesSelfSizingAnchor == true
    super.layoutSubviews()
    layout?.managesReadingAnchor = false
    let geometryChanged = contentSize != settledContentSize || bounds.size != settledViewportSize
      || adjustedContentInset != settledInsets
    // A resting reader within a few points of the recorded bottom stays pinned
    // even without a geometry change; otherwise the reading-anchor branch below
    // can carry a bottom reader away when cells above re-measure.
    let currentBottom = max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
    let driftedFromBottom = settledBottomOffsetY.map { abs(contentOffset.y - $0) <= 4 } == true
      && abs(contentOffset.y - currentBottom) > 0.5
    if mayFollow && (geometryChanged || driftedFromBottom) && (wasAtBottom || pendingInsetBottomFollow) {
      isRestoringBottom = true
      layout?.managesReadingAnchor = true
      // Moving to the bottom can materialize or re-measure cells, changing the
      // content height in the same pass. Check convergence after each layout,
      // not before it, so the last pass cannot leave an unpinned gap.
      for _ in 0..<4 {
        let bottom = max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
        if abs(contentOffset.y - bottom) <= 0.5 { break }
        contentOffset.y = bottom
        super.layoutSubviews()
      }
      layout?.managesReadingAnchor = false
      isRestoringBottom = false
      // The last pass may still have changed the content height. Pin to the
      // bottom recorded below so the next pass sees a reader at the bottom.
      let bottom = max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
      if abs(contentOffset.y - bottom) > 0.5 { contentOffset.y = bottom }
    } else if layout?.preservesSelfSizingAnchor == true,
      let readerCell, let readerIndex, let readerY,
      indexPath(for: readerCell) == readerIndex {
      let bottom = max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
      if let target = ChatScrollGeometry.readingOffset(
        target: readerCell.frame.minY - readerY, current: contentOffset.y,
        bottom: bottom, top: -adjustedContentInset.top, isInteracting: isInteracting
      ) {
        isRestoringBottom = true
        contentOffset.y = target
        isRestoringBottom = false
      }
    }
    pendingInsetBottomFollow = false
    viewportReadingAnchor = nil
    settledBottomOffsetY = max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
    settledContentSize = contentSize
    settledViewportSize = bounds.size
    settledInsets = adjustedContentInset
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
    let bottom = max(
      -collectionView.adjustedContentInset.top,
      collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom
    )
    if let offset = ChatScrollGeometry.readingOffset(
      target: target, current: collectionView.contentOffset.y,
      bottom: bottom, top: -collectionView.adjustedContentInset.top,
      isInteracting: collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
    ) {
      collectionView.contentOffset.y = offset
    }
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
