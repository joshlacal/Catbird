#if os(iOS)
import QuartzCore
import UIKit

/// Drives a single-frame, top-anchored self-sizing pass for a hosted post cell
/// when in-row UI state changes (content-warning Show/Hide, hidden-post reveal,
/// muted preview/quote reveal, translation toggle, link warning, or block card).
///
/// Without an explicit non-animated pass, `_UIHostingContentView` flushes its
/// dirty SwiftUI state during CoreAnimation's pre-commit observer while
/// `UIView.areAnimationsEnabled` is `true`, causing `UICollectionView` to latch
/// its self-sizing spring (`0.3s`) and anchor scroll offset to the wrong item
/// whenever the cell's top edge is partially scrolled beneath the navigation bar.
@MainActor
enum CollectionViewCellResizeAnchor {
  /// True while a synchronous top-anchored cell resize is adjusting layout and
  /// `contentOffset`, allowing scroll delegates to ignore transient offset steps.
  private(set) static var isPerformingResize = false

  private static let disabledLayerActions: [String: CAAction] = [
    "bounds": NSNull(),
    "position": NSNull(),
    "frame": NSNull(),
    "contents": NSNull(),
    "onOrderIn": NSNull(),
    "onOrderOut": NSNull()
  ]

  /// Suppresses implicit CoreAnimation geometry actions on a cell and its content view.
  static func disableImplicitLayerAnimations(on cell: UICollectionViewCell) {
    cell.layer.actions = disabledLayerActions
    cell.contentView.layer.actions = disabledLayerActions
  }

  /// Flushes the cell's hosted SwiftUI layout, invalidates and resolves its
  /// collection-view item height in one non-animated pass, and restores
  /// `contentOffset.y` so the cell's top edge remains at the exact same
  /// viewport coordinate (`0.0 pt` jump) unless clamped at the scroll bounds.
  static func performTopAnchoredResize(
    in collectionView: UICollectionView?,
    for cell: UICollectionViewCell?,
    prepare: (() -> Void)? = nil
  ) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

    UIView.performWithoutAnimation {
      prepare?()

      guard let collectionView,
            let cell,
            cell.window != nil,
            collectionView.window != nil,
            let indexPath = collectionView.indexPath(for: cell)
      else {
        return
      }

      let oldOffset = collectionView.contentOffset
      let anchorViewportY = cell.frame.minY - oldOffset.y

      let wasPerformingResize = isPerformingResize
      isPerformingResize = true
      defer { isPerformingResize = wasPerformingResize }

      invalidateHostedIntrinsicSize(of: cell)
      let didInvalidateLayout = invalidateCellHeight(in: collectionView, for: cell, at: indexPath)
      if didInvalidateLayout {
        collectionView.layoutIfNeeded()
        restoreTopAnchor(
          in: collectionView,
          for: cell,
          at: indexPath,
          oldOffsetX: oldOffset.x,
          anchorViewportY: anchorViewportY
        )
      }

      // Settle the cell and hosted view at their final bounds inside the same
      // non-animated transaction so pre-commit has zero dirty layout left.
      cell.layoutIfNeeded()
      cell.contentView.layoutIfNeeded()

      if didInvalidateLayout && collectionView.layer.needsLayout() {
        collectionView.layoutIfNeeded()
        restoreTopAnchor(
          in: collectionView,
          for: cell,
          at: indexPath,
          oldOffsetX: oldOffset.x,
          anchorViewportY: anchorViewportY
        )
      }
    }
  }

  private static func invalidateHostedIntrinsicSize(of cell: UICollectionViewCell) {
    // UIHostingConfiguration installs _UIHostingContentView as cell.contentView itself.
    // Flushing layout on cell.contentView evaluates any pending SwiftUI state mutation
    // before preferredLayoutAttributesFitting queries the updated height.
    cell.contentView.setNeedsLayout()
    cell.contentView.layoutIfNeeded()
    cell.contentView.invalidateIntrinsicContentSize()
    cell.invalidateIntrinsicContentSize()
  }

  @discardableResult
  private static func invalidateCellHeight(
    in collectionView: UICollectionView,
    for cell: UICollectionViewCell,
    at indexPath: IndexPath
  ) -> Bool {
    let layout = collectionView.collectionViewLayout
    if let original = layout.layoutAttributesForItem(at: indexPath),
       let seed = original.copy() as? UICollectionViewLayoutAttributes {
      seed.size.height = 44
      let preferred = cell.preferredLayoutAttributesFitting(seed)
      guard abs(preferred.size.height - original.size.height) > 0.5 else {
        return false
      }
      if layout.shouldInvalidateLayout(
        forPreferredLayoutAttributes: preferred,
        withOriginalAttributes: original
      ) {
        let context = layout.invalidationContext(
          forPreferredLayoutAttributes: preferred,
          withOriginalAttributes: original
        )
        layout.invalidateLayout(with: context)
        return true
      }
      return false
    }

    let fallback = UICollectionViewLayoutInvalidationContext()
    fallback.invalidateItems(at: [indexPath])
    layout.invalidateLayout(with: fallback)
    return true
  }

  private static func restoreTopAnchor(
    in collectionView: UICollectionView,
    for cell: UICollectionViewCell,
    at indexPath: IndexPath,
    oldOffsetX: CGFloat,
    anchorViewportY: CGFloat
  ) {
    let updatedFrame = collectionView.layoutAttributesForItem(at: indexPath)?.frame ?? cell.frame
    let inset = collectionView.adjustedContentInset
    let minOffsetY = -inset.top
    let maxOffsetY = max(
      minOffsetY,
      collectionView.contentSize.height - collectionView.bounds.height + inset.bottom
    )
    let desiredOffsetY = min(maxOffsetY, max(minOffsetY, updatedFrame.minY - anchorViewportY))
    if abs(collectionView.contentOffset.y - desiredOffsetY) > 0.001 {
      collectionView.contentOffset = CGPoint(x: oldOffsetX, y: desiredOffsetY)
      collectionView.layoutIfNeeded()
    }
  }
}
#endif
