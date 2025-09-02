//
//  ScrollPositionTracker.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/4/25.
//

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import OSLog

#if os(iOS)
@available(iOS 16.0, *)
final class ScrollPositionTracker {
  private let logger = Logger(
    subsystem: "blue.catbird", category: "ScrollPositionTracker")

  struct ScrollAnchor {
    let indexPath: IndexPath
    let offsetY: CGFloat
    let itemFrameY: CGFloat
    let timestamp: Date
    let postId: String?
  }

  private var lastAnchor: ScrollAnchor?
  private(set) var isTracking = true

  func captureScrollAnchor(collectionView: UICollectionView) -> ScrollAnchor? {
    guard isTracking else { return nil }

    // Get current offset - can be negative during pull-to-refresh
    let currentOffset = collectionView.contentOffset.y
    
    // Special handling for pull-to-refresh (negative offset)
    if currentOffset < 0 {
      // User is pulling to refresh - capture the first item if available
      let firstIndexPath = IndexPath(item: 0, section: 0)
      if collectionView.numberOfItems(inSection: 0) > 0,
         let attributes = collectionView.layoutAttributesForItem(at: firstIndexPath) {
        
        let anchor = ScrollAnchor(
          indexPath: firstIndexPath,
          offsetY: currentOffset, // Preserve negative offset
          itemFrameY: attributes.frame.origin.y,
          timestamp: Date(),
          postId: nil
        )
        
        lastAnchor = anchor
        logger.debug(
          "Captured pull-to-refresh anchor: item[0, 0] at y=\(attributes.frame.origin.y), offset=\(currentOffset) (negative indicates pull)"
        )
        return anchor
      }
    }

    // Find the first visible post that's at least 30% visible
    let visibleIndexPaths = collectionView.indexPathsForVisibleItems.sorted()
    let visibleBounds = collectionView.bounds

    for indexPath in visibleIndexPaths {
      // For single-section layout, check main section
      if indexPath.section == 0,
        let attributes = collectionView.layoutAttributesForItem(at: indexPath)
      {

        // Check if the item is sufficiently visible
        let itemFrame = attributes.frame
        let visibleArea = itemFrame.intersection(visibleBounds)
        let visibilityRatio = visibleArea.height / itemFrame.height

        if visibilityRatio >= FeedConstants.scrollAnchorVisibilityThreshold {
          let anchor = ScrollAnchor(
            indexPath: indexPath,
            offsetY: currentOffset,
            itemFrameY: itemFrame.origin.y,
            timestamp: Date(),
            postId: nil
          )

          lastAnchor = anchor
          logger.debug(
            "Captured scroll anchor: item[\(indexPath.section), \(indexPath.item)] at y=\(itemFrame.origin.y), offset=\(currentOffset), visibility=\(visibilityRatio)"
          )
          return anchor
        }
      }
    }

    return nil
  }

  func restoreScrollPosition(collectionView: UICollectionView, to anchor: ScrollAnchor) {
    guard isTracking else { 
      logger.debug("Scroll tracking disabled - skipping restoration")
      return 
    }

    // Validate anchor age
    let anchorAge = Date().timeIntervalSince(anchor.timestamp)
    guard anchorAge < FeedConstants.maxScrollAnchorAge else {
      logger.warning("Anchor too old (\(anchorAge)s) - attempting fallback restoration")
      restoreScrollPositionFallback(collectionView: collectionView, anchor: anchor)
      return
    }

    // Validate collection view state
    guard validateCollectionViewState(collectionView) else {
      logger.warning("Invalid collection view state - attempting fallback restoration")
      restoreScrollPositionFallback(collectionView: collectionView, anchor: anchor)
      return
    }

    // Force layout to ensure all positions are calculated with timeout
    let layoutStartTime = Date()
    collectionView.layoutIfNeeded()
    
    // Check layout didn't take too long
    let layoutDuration = Date().timeIntervalSince(layoutStartTime)
    if layoutDuration > FeedConstants.layoutTimeout {
      logger.warning("Layout took too long (\(layoutDuration)s) - may be unstable")
    }

    // Validate anchor index path is still valid
    guard anchor.indexPath.section < collectionView.numberOfSections,
          anchor.indexPath.item < collectionView.numberOfItems(inSection: anchor.indexPath.section) else {
      logger.warning("Anchor index path out of bounds - attempting fallback")
      restoreScrollPositionFallback(collectionView: collectionView, anchor: anchor)
      return
    }

    // Get current position of anchor item
    guard let currentAttributes = collectionView.layoutAttributesForItem(at: anchor.indexPath)
    else {
      logger.warning("Could not restore scroll position - anchor item not found at exact path, attempting fallback")
      restoreScrollPositionFallback(collectionView: collectionView, anchor: anchor)
      return
    }

    // Validate the layout attributes are reasonable
    guard currentAttributes.frame.height > 0 && currentAttributes.frame.width > 0 else {
      logger.warning("Invalid layout attributes for anchor item - attempting fallback")
      restoreScrollPositionFallback(collectionView: collectionView, anchor: anchor)
      return
    }

    // Calculate how much content was added/removed above the anchor
    let currentItemY = currentAttributes.frame.origin.y
    let originalItemY = anchor.itemFrameY
    let heightDelta = currentItemY - originalItemY

    // Enhanced bounds checking
    let contentHeight = collectionView.contentSize.height
    let viewHeight = collectionView.bounds.height
    
    guard contentHeight > 0 && viewHeight > 0 else {
      logger.warning("Invalid dimensions - content: \(contentHeight), view: \(viewHeight)")
      restoreScrollPositionFallback(collectionView: collectionView, anchor: anchor)
      return
    }

    // Apply corrected offset with enhanced bounds checking
    let newOffsetY = anchor.offsetY + heightDelta
    let minContentOffset = -collectionView.adjustedContentInset.top
    let maxContentOffset = max(
      minContentOffset,
      contentHeight + collectionView.adjustedContentInset.bottom - viewHeight
    )
    let correctedOffset = min(max(newOffsetY, minContentOffset), maxContentOffset)
    
    // Validate the calculated offset is reasonable
    guard correctedOffset >= minContentOffset && correctedOffset <= maxContentOffset else {
      logger.warning("Calculated offset out of bounds: \(correctedOffset), max: \(maxContentOffset)")
      restoreScrollPositionFallback(collectionView: collectionView, anchor: anchor)
      return
    }

    // Apply the scroll position
    let targetX = -collectionView.adjustedContentInset.left
    collectionView.setContentOffset(CGPoint(x: targetX, y: correctedOffset), animated: false)

    // Verify the restoration was successful
    let actualOffset = collectionView.contentOffset.y
    let offsetDifference = abs(actualOffset - correctedOffset)
    
    if offsetDifference > FeedConstants.scrollRestorationVerificationThreshold {
      logger.warning("Scroll restoration may have failed - expected: \(correctedOffset), actual: \(actualOffset)")
    }

    logger.debug(
      "✅ Restored scroll position: anchor moved from y=\(originalItemY) to y=\(currentItemY), delta=\(heightDelta), new offset=\(correctedOffset)"
    )
  }
  
  /// Validates collection view state before attempting restoration
  private func validateCollectionViewState(_ collectionView: UICollectionView) -> Bool {
    // Check basic dimensions
    let bounds = collectionView.bounds
    guard bounds.width > 0 && bounds.height > 0 else {
        logger.debug("Invalid bounds: \(bounds.debugDescription)")
      return false
    }
    
    // Check content size
    let contentSize = collectionView.contentSize
    guard contentSize.height >= 0 && contentSize.width >= 0 else {
        logger.debug("Invalid content size: \(contentSize.debugDescription)")
      return false
    }
    
    // Check sections and items
    guard collectionView.numberOfSections > 0 else {
      logger.debug("No sections in collection view")
      return false
    }
    
    return true
  }

  private func restoreScrollPositionFallback(collectionView: UICollectionView, anchor: ScrollAnchor) {
    logger.info("🛡️ Starting scroll position fallback restoration")
    
    // Strategy 1: Try to restore to the same relative position as before
    let totalItems = collectionView.numberOfItems(inSection: anchor.indexPath.section)
    
    if totalItems > 0 {
      let relativePosition = min(Double(anchor.indexPath.item) / Double(totalItems), 1.0)
      let targetItem = Int(relativePosition * Double(totalItems))
      let fallbackIndexPath = IndexPath(item: min(targetItem, totalItems - 1), section: anchor.indexPath.section)
      
      if let fallbackAttributes = collectionView.layoutAttributesForItem(at: fallbackIndexPath) {
        // Enhanced fallback positioning with bounds checking
        let contentHeight = collectionView.contentSize.height
        let viewHeight = collectionView.bounds.height
        let minOffsetY = -collectionView.adjustedContentInset.top
        let maxOffsetY = max(
          minOffsetY,
          contentHeight + collectionView.adjustedContentInset.bottom - viewHeight
        )
        
        // Position the fallback item similarly to where the anchor was
        let baseOffset = fallbackAttributes.frame.origin.y - anchor.offsetY + anchor.itemFrameY
        let fallbackOffset = min(max(baseOffset, minOffsetY), maxOffsetY)
        
        // Validate offset is reasonable
        if fallbackOffset >= minOffsetY && fallbackOffset <= maxOffsetY {
          let targetX = -collectionView.adjustedContentInset.left
          collectionView.setContentOffset(CGPoint(x: targetX, y: fallbackOffset), animated: false)
          
          logger.info(
            "🛡️ Fallback successful: restored to relative position \(relativePosition) at item \(targetItem), offset \(fallbackOffset)"
          )
          return
        }
      }
    }
    
    // Strategy 2: If relative position failed, try to scroll to a safe middle position
    let contentHeight = collectionView.contentSize.height
    let viewHeight = collectionView.bounds.height
    let minOffsetY = -collectionView.adjustedContentInset.top
    
    if contentHeight > viewHeight {
      let availableScroll = contentHeight + collectionView.adjustedContentInset.bottom - viewHeight - minOffsetY
      let middleOffset = minOffsetY + min(availableScroll * 0.3, contentHeight * FeedConstants.fallbackScrollPositionPercent)
      let targetX = -collectionView.adjustedContentInset.left
      collectionView.setContentOffset(CGPoint(x: targetX, y: middleOffset), animated: false)
      
      logger.info("🛡️ Fallback: restored to middle position with offset \(middleOffset)")
    } else {
      // Strategy 3: Content is shorter than view, just go to top
      let targetX = -collectionView.adjustedContentInset.left
      let targetY = -collectionView.adjustedContentInset.top
      collectionView.setContentOffset(CGPoint(x: targetX, y: targetY), animated: false)
      logger.info("🛡️ Fallback: restored to top (content shorter than view)")
    }
  }

  func pauseTracking() {
    isTracking = false
  }

  func resumeTracking() {
    isTracking = true
  }
}
#else
/// macOS stub implementation - Scroll position tracking not available on macOS
@available(macOS 13.0, *)
final class ScrollPositionTracker {
  private let logger = Logger(
    subsystem: "blue.catbird", category: "ScrollPositionTracker")

  struct ScrollAnchor {
    let indexPath: IndexPath
    let offsetY: CGFloat
    let itemFrameY: CGFloat
    let timestamp: Date
    let postId: String?
  }

  private(set) var isTracking = true

  func captureScrollAnchor(collectionView: Any) -> ScrollAnchor? {
    logger.debug("ScrollPositionTracker captureScrollAnchor called on macOS (stub implementation)")
    return nil
  }

  func restoreScrollPosition(collectionView: Any, to anchor: ScrollAnchor) {
    logger.debug("ScrollPositionTracker restoreScrollPosition called on macOS (stub implementation)")
  }

  func pauseTracking() {
    isTracking = false
  }

  func resumeTracking() {
    isTracking = true
  }
}
#endif
