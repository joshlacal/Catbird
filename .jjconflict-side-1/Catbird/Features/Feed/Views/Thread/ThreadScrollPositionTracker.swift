//
//  ThreadScrollPositionTracker.swift
//  Catbird
//
//  Simplified implementation for clean reverse infinite scroll pattern
//

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import OSLog

#if os(iOS)
/// Minimal scroll position tracker for thread view's reverse infinite scroll.
/// Used only for basic scroll position capture when needed.
@available(iOS 16.0, *)
final class ThreadScrollPositionTracker {
  private let logger = Logger(
    subsystem: "blue.catbird", category: "ThreadScrollPositionTracker")

  // MARK: - Types
  
  /// Thread section mapping for scroll position tracking
  enum ThreadSection: Int {
    case loadMoreParents = 0
    case parentPosts = 1
    case mainPost = 2
    case replies = 3
    case bottomSpacer = 4
  }
  
  /// Simplified scroll anchor for thread positioning
  struct ScrollAnchor {
    let indexPath: IndexPath
    let mainPostFrameY: CGFloat
    let contentOffset: CGPoint
    let timestamp: TimeInterval
    let isMainPostAnchor: Bool
    
    init(indexPath: IndexPath, mainPostFrameY: CGFloat, contentOffset: CGPoint, isMainPostAnchor: Bool = false) {
      self.indexPath = indexPath
      self.mainPostFrameY = mainPostFrameY
      self.contentOffset = contentOffset
      self.timestamp = CACurrentMediaTime()
      self.isMainPostAnchor = isMainPostAnchor
    }
  }

  // MARK: - Simple Position Capture
  
  /// Captures current scroll position - simplified for clean implementation
  func captureCurrentOffset(collectionView: UICollectionView) -> CGFloat {
    return collectionView.contentOffset.y
  }
  
  /// Captures scroll anchor for position restoration
  func captureScrollAnchor(collectionView: UICollectionView) -> ScrollAnchor? {
    let visibleIndexPaths = collectionView.indexPathsForVisibleItems.sorted()
    guard let firstVisible = visibleIndexPaths.first else { return nil }
    
    // Try to get main post frame if visible
    let mainPostIndexPath = IndexPath(item: 0, section: ThreadSection.mainPost.rawValue)
    let mainPostFrameY = collectionView.layoutAttributesForItem(at: mainPostIndexPath)?.frame.origin.y ?? 0
    
    let isMainPostAnchor = firstVisible.section == ThreadSection.mainPost.rawValue
    
    return ScrollAnchor(
      indexPath: firstVisible,
      mainPostFrameY: mainPostFrameY,
      contentOffset: collectionView.contentOffset,
      isMainPostAnchor: isMainPostAnchor
    )
  }
  
  /// Restores scroll position using anchor
  func restoreScrollPosition(collectionView: UICollectionView, to anchor: ScrollAnchor) {
    // Simple restoration - adjust based on main post position change
    let currentMainPostIndexPath = IndexPath(item: 0, section: ThreadSection.mainPost.rawValue)
    let currentMainPostFrameY = collectionView.layoutAttributesForItem(at: currentMainPostIndexPath)?.frame.origin.y ?? 0
    
    let frameDelta = currentMainPostFrameY - anchor.mainPostFrameY
    let targetOffset = CGPoint(x: 0, y: anchor.contentOffset.y + frameDelta)
    
    // Clamp to valid bounds
    let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)
    let clampedOffset = CGPoint(x: 0, y: max(0, min(targetOffset.y, maxOffset)))
    
    collectionView.setContentOffset(clampedOffset, animated: false)
    
    logger.debug("Restored position using anchor, delta: \(frameDelta)pt")
  }
  
  /// Restores scroll position with height adjustment - used for reverse scroll
  func restoreWithHeightAdjustment(
    collectionView: UICollectionView, 
    previousOffset: CGFloat, 
    heightDelta: CGFloat
  ) {
    let newOffset = previousOffset + heightDelta
    let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)
    let clampedOffset = max(0, min(newOffset, maxOffset))
    
    collectionView.setContentOffset(CGPoint(x: 0, y: clampedOffset), animated: false)
    
    logger.debug("Restored position with height adjustment: \(heightDelta)pt, offset: \(clampedOffset)")
  }
}

#else
/// macOS stub implementation
@available(macOS 13.0, *)
final class ThreadScrollPositionTracker {
  private let logger = Logger(
    subsystem: "blue.catbird", category: "ThreadScrollPositionTracker")
  
  func captureCurrentOffset(collectionView: Any) -> CGFloat {
    logger.debug("ThreadScrollPositionTracker called on macOS (stub)")
    return 0
  }
  
  func restoreWithHeightAdjustment(collectionView: Any, previousOffset: CGFloat, heightDelta: CGFloat) {
    logger.debug("ThreadScrollPositionTracker restoreWithHeightAdjustment called on macOS (stub)")
  }
}
#endif