//
//  ThreadScrollPositionTracker.swift
//  Catbird
//
//  Created by Claude on 8/1/25.
//

import UIKit
import OSLog

/// Specialized scroll position tracker for thread view's unique multi-section reverse infinite scroll pattern.
/// Maintains visual position relative to the main post when parent posts are loaded above existing content.
@available(iOS 16.0, *)
final class ThreadScrollPositionTracker {
  private let logger = Logger(
    subsystem: "blue.catbird", category: "ThreadScrollPositionTracker")

  // MARK: - Thread Section Constants
  enum ThreadSection: Int, CaseIterable {
    case loadMoreParents = 0
    case parentPosts = 1
    case mainPost = 2
    case replies = 3
    case bottomSpacer = 4
  }

  // MARK: - Scroll Anchor
  struct ScrollAnchor {
    let indexPath: IndexPath
    let offsetY: CGFloat        // Current scroll position when captured
    let itemFrameY: CGFloat     // Where the item was positioned in content
    let timestamp: Date         // For staleness detection
    let postId: String?         // The actual post ID (captured before refresh)
    let mainPostFrameY: CGFloat // Where the main post was positioned (critical for threads)
    let sectionType: ThreadSection // Which section this anchor belongs to
    
    var isMainPostAnchor: Bool {
      return sectionType == .mainPost
    }
  }

  private var lastAnchor: ScrollAnchor?
  private(set) var isTracking = true

  // MARK: - Anchor Capture

  /// Captures scroll anchor with thread-specific logic, prioritizing main post stability
  func captureScrollAnchor(collectionView: UICollectionView) -> ScrollAnchor? {
    guard isTracking else { return nil }

    let currentOffset = collectionView.contentOffset.y
    
    // For threads, we ALWAYS want to anchor relative to the main post if possible
    if let mainPostAnchor = captureMainPostAnchor(collectionView: collectionView, currentOffset: currentOffset) {
      lastAnchor = mainPostAnchor
      logger.debug("✅ Captured main post anchor: offset=\(currentOffset), mainPostY=\(mainPostAnchor.mainPostFrameY)")
      return mainPostAnchor
    }
    
    // Fallback to parent posts section if main post not visible
    if let parentAnchor = captureParentPostAnchor(collectionView: collectionView, currentOffset: currentOffset) {
      lastAnchor = parentAnchor
      logger.debug("📍 Captured parent post anchor: section=\(parentAnchor.indexPath.section), item=\(parentAnchor.indexPath.item)")
      return parentAnchor
    }
    
    // Final fallback to any visible item with main post reference
    if let genericAnchor = captureGenericAnchor(collectionView: collectionView, currentOffset: currentOffset) {
      lastAnchor = genericAnchor
      logger.debug("🔄 Captured generic anchor: section=\(genericAnchor.indexPath.section), item=\(genericAnchor.indexPath.item)")
      return genericAnchor
    }

    logger.warning("❌ Failed to capture any scroll anchor")
    return nil
  }

  // MARK: - Anchor Capture Strategies

  private func captureMainPostAnchor(collectionView: UICollectionView, currentOffset: CGFloat) -> ScrollAnchor? {
    let mainPostIndexPath = IndexPath(item: 0, section: ThreadSection.mainPost.rawValue)
    
    guard collectionView.numberOfSections > ThreadSection.mainPost.rawValue,
          collectionView.numberOfItems(inSection: ThreadSection.mainPost.rawValue) > 0,
          let mainPostAttributes = collectionView.layoutAttributesForItem(at: mainPostIndexPath) else {
      return nil
    }

    // Check if main post is sufficiently visible (at least 10% visible)
    let visibleBounds = collectionView.bounds
    let mainPostFrame = mainPostAttributes.frame
    let visibleArea = mainPostFrame.intersection(visibleBounds)
    let visibilityRatio = visibleArea.height / mainPostFrame.height
    
    guard visibilityRatio >= 0.1 else { return nil }

    return ScrollAnchor(
      indexPath: mainPostIndexPath,
      offsetY: currentOffset,
      itemFrameY: mainPostFrame.origin.y,
      timestamp: Date(),
      postId: "main-post", // Special identifier for main post
      mainPostFrameY: mainPostFrame.origin.y,
      sectionType: .mainPost
    )
  }

  private func captureParentPostAnchor(collectionView: UICollectionView, currentOffset: CGFloat) -> ScrollAnchor? {
    guard collectionView.numberOfSections > ThreadSection.parentPosts.rawValue else { return nil }
    
    let parentSection = ThreadSection.parentPosts.rawValue
    let parentItemCount = collectionView.numberOfItems(inSection: parentSection)
    guard parentItemCount > 0 else { return nil }

    // Find the most visible parent post
    let visibleBounds = collectionView.bounds
    var bestAnchor: ScrollAnchor?
    var bestVisibilityRatio: CGFloat = 0

    for item in 0..<parentItemCount {
      let indexPath = IndexPath(item: item, section: parentSection)
      guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { continue }

      let itemFrame = attributes.frame
      let visibleArea = itemFrame.intersection(visibleBounds)
      let visibilityRatio = visibleArea.height / itemFrame.height

      if visibilityRatio > bestVisibilityRatio && visibilityRatio >= 0.3 {
        let mainPostFrameY = getMainPostFrameY(collectionView: collectionView) ?? itemFrame.origin.y
        
        bestAnchor = ScrollAnchor(
          indexPath: indexPath,
          offsetY: currentOffset,
          itemFrameY: itemFrame.origin.y,
          timestamp: Date(),
          postId: "parent-\(item)", // Parent post identifier
          mainPostFrameY: mainPostFrameY,
          sectionType: .parentPosts
        )
        bestVisibilityRatio = visibilityRatio
      }
    }

    return bestAnchor
  }

  private func captureGenericAnchor(collectionView: UICollectionView, currentOffset: CGFloat) -> ScrollAnchor? {
    let visibleIndexPaths = collectionView.indexPathsForVisibleItems.sorted()
    let visibleBounds = collectionView.bounds

    for indexPath in visibleIndexPaths {
      // Skip spacer and load more sections
      guard indexPath.section != ThreadSection.bottomSpacer.rawValue &&
            indexPath.section != ThreadSection.loadMoreParents.rawValue,
            let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { continue }

      let itemFrame = attributes.frame
      let visibleArea = itemFrame.intersection(visibleBounds)
      let visibilityRatio = visibleArea.height / itemFrame.height

      if visibilityRatio >= 0.2 {
        let sectionType = ThreadSection(rawValue: indexPath.section) ?? .replies
        let mainPostFrameY = getMainPostFrameY(collectionView: collectionView) ?? itemFrame.origin.y
        
        return ScrollAnchor(
          indexPath: indexPath,
          offsetY: currentOffset,
          itemFrameY: itemFrame.origin.y,
          timestamp: Date(),
          postId: "generic-\(indexPath.section)-\(indexPath.item)",
          mainPostFrameY: mainPostFrameY,
          sectionType: sectionType
        )
      }
    }

    return nil
  }

  // MARK: - Position Restoration

  /// Restores scroll position with thread-specific logic maintaining main post visual stability
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

    // Force layout to ensure all positions are calculated
    let layoutStartTime = Date()
    collectionView.layoutIfNeeded()
    
    let layoutDuration = Date().timeIntervalSince(layoutStartTime)
    if layoutDuration > FeedConstants.layoutTimeout {
      logger.warning("Layout took too long (\(layoutDuration)s) - may be unstable")
    }

    // Use thread-specific restoration strategy
    if anchor.isMainPostAnchor {
      restoreMainPostPosition(collectionView: collectionView, anchor: anchor)
    } else {
      restoreViewportRelativePosition(collectionView: collectionView, anchor: anchor)
    }
  }

  private func restoreMainPostPosition(collectionView: UICollectionView, anchor: ScrollAnchor) {
    let mainPostIndexPath = IndexPath(item: 0, section: ThreadSection.mainPost.rawValue)
    
    guard collectionView.numberOfSections > ThreadSection.mainPost.rawValue,
          collectionView.numberOfItems(inSection: ThreadSection.mainPost.rawValue) > 0,
          let currentMainPostAttributes = collectionView.layoutAttributesForItem(at: mainPostIndexPath) else {
      logger.warning("Main post not found - attempting fallback")
      restoreScrollPositionFallback(collectionView: collectionView, anchor: anchor)
      return
    }

    // Calculate how much the main post moved
    let currentMainPostY = currentMainPostAttributes.frame.origin.y
    let originalMainPostY = anchor.mainPostFrameY
    let mainPostDelta = currentMainPostY - originalMainPostY

    // Restore to maintain the same visual position of the main post
    let newOffsetY = anchor.offsetY + mainPostDelta
    
    // Apply bounds checking
    let contentHeight = collectionView.contentSize.height
    let viewHeight = collectionView.bounds.height
    let maxContentOffset = max(0, contentHeight - viewHeight)
    let correctedOffset = max(0, min(newOffsetY, maxContentOffset))

    collectionView.setContentOffset(CGPoint(x: 0, y: correctedOffset), animated: false)

    logger.debug("✅ Restored main post position: mainPost moved by \(mainPostDelta)pt, new offset=\(correctedOffset)")
  }

  private func restoreViewportRelativePosition(collectionView: UICollectionView, anchor: ScrollAnchor) {
    // For non-main-post anchors, try to maintain viewport-relative position
    // but prioritize keeping the main post stable if possible
    
    let currentMainPostY = getMainPostFrameY(collectionView: collectionView) ?? anchor.mainPostFrameY
    let mainPostDelta = currentMainPostY - anchor.mainPostFrameY
    
    // If main post moved significantly, use main post delta
    if abs(mainPostDelta) > 50 {
      let newOffsetY = anchor.offsetY + mainPostDelta
      let contentHeight = collectionView.contentSize.height
      let viewHeight = collectionView.bounds.height
      let maxContentOffset = max(0, contentHeight - viewHeight)
      let correctedOffset = max(0, min(newOffsetY, maxContentOffset))
      
      collectionView.setContentOffset(CGPoint(x: 0, y: correctedOffset), animated: false)
      logger.debug("✅ Restored using main post delta: \(mainPostDelta)pt, offset=\(correctedOffset)")
      return
    }
    
    // Otherwise, try to restore the original anchor item position
    guard anchor.indexPath.section < collectionView.numberOfSections,
          anchor.indexPath.item < collectionView.numberOfItems(inSection: anchor.indexPath.section),
          let currentAttributes = collectionView.layoutAttributesForItem(at: anchor.indexPath) else {
      logger.warning("Original anchor item not found - using main post position")
      restoreMainPostPosition(collectionView: collectionView, anchor: anchor)
      return
    }

    let currentItemY = currentAttributes.frame.origin.y
    let originalItemY = anchor.itemFrameY
    let itemDelta = currentItemY - originalItemY

    let newOffsetY = anchor.offsetY + itemDelta
    let contentHeight = collectionView.contentSize.height
    let viewHeight = collectionView.bounds.height
    let maxContentOffset = max(0, contentHeight - viewHeight)
    let correctedOffset = max(0, min(newOffsetY, maxContentOffset))

    collectionView.setContentOffset(CGPoint(x: 0, y: correctedOffset), animated: false)
    
    logger.debug("✅ Restored viewport-relative position: item moved by \(itemDelta)pt, offset=\(correctedOffset)")
  }

  // MARK: - Helper Methods

  private func getMainPostFrameY(collectionView: UICollectionView) -> CGFloat? {
    guard collectionView.numberOfSections > ThreadSection.mainPost.rawValue,
          collectionView.numberOfItems(inSection: ThreadSection.mainPost.rawValue) > 0 else {
      return nil
    }
    
    let mainPostIndexPath = IndexPath(item: 0, section: ThreadSection.mainPost.rawValue)
    return collectionView.layoutAttributesForItem(at: mainPostIndexPath)?.frame.origin.y
  }

  private func validateCollectionViewState(_ collectionView: UICollectionView) -> Bool {
    let bounds = collectionView.bounds
    guard bounds.width > 0 && bounds.height > 0 else {
      logger.debug("Invalid bounds: \(bounds.debugDescription)")
      return false
    }
    
    let contentSize = collectionView.contentSize
    guard contentSize.height >= 0 && contentSize.width >= 0 else {
      logger.debug("Invalid content size: \(contentSize.debugDescription)")
      return false
    }
    
    guard collectionView.numberOfSections > 0 else {
      logger.debug("No sections in collection view")
      return false
    }
    
    return true
  }

  // MARK: - Fallback Restoration

  private func restoreScrollPositionFallback(collectionView: UICollectionView, anchor: ScrollAnchor) {
    logger.info("🛡️ Starting thread scroll position fallback restoration")
    
    // Strategy 1: Try to keep main post in similar viewport position
    if let mainPostY = getMainPostFrameY(collectionView: collectionView) {
      // Calculate where the main post should be based on the original anchor
      let viewportHeight = collectionView.bounds.height
      let targetMainPostVisibleY = viewportHeight * 0.3 // Show main post at 30% down the viewport
      let targetOffset = max(0, mainPostY - targetMainPostVisibleY)
      
      let contentHeight = collectionView.contentSize.height
      let maxOffset = max(0, contentHeight - viewportHeight)
      let clampedOffset = min(targetOffset, maxOffset)
      
      collectionView.setContentOffset(CGPoint(x: 0, y: clampedOffset), animated: false)
      logger.info("🛡️ Fallback: positioned main post at \(targetMainPostVisibleY)pt from top")
      return
    }
    
    // Strategy 2: Use relative positioning within the section that had the anchor
    let anchorSection = anchor.indexPath.section
    let totalItemsInSection = collectionView.numberOfItems(inSection: anchorSection)
    
    if totalItemsInSection > 0 {
      let relativePosition = min(Double(anchor.indexPath.item) / Double(totalItemsInSection), 1.0)
      let targetItem = Int(relativePosition * Double(totalItemsInSection))
      let fallbackIndexPath = IndexPath(item: min(targetItem, totalItemsInSection - 1), section: anchorSection)
      
      if let fallbackAttributes = collectionView.layoutAttributesForItem(at: fallbackIndexPath) {
        let targetOffset = max(0, fallbackAttributes.frame.origin.y - 100) // Show item 100pt from top
        let contentHeight = collectionView.contentSize.height
        let viewHeight = collectionView.bounds.height
        let maxOffset = max(0, contentHeight - viewHeight)
        let clampedOffset = min(targetOffset, maxOffset)
        
        collectionView.setContentOffset(CGPoint(x: 0, y: clampedOffset), animated: false)
        logger.info("🛡️ Fallback: restored to relative position in section \(anchorSection)")
        return
      }
    }
    
    // Strategy 3: Position at a reasonable default for threads (show some parents + main post)
    let contentHeight = collectionView.contentSize.height
    let viewHeight = collectionView.bounds.height
    
    if contentHeight > viewHeight {
      let defaultOffset = min(contentHeight * 0.2, 200) // 20% down or 200pt, whichever is smaller
      collectionView.setContentOffset(CGPoint(x: 0, y: defaultOffset), animated: false)
      logger.info("🛡️ Fallback: positioned at default thread position")
    } else {
      collectionView.setContentOffset(.zero, animated: false)
      logger.info("🛡️ Fallback: positioned at top (content shorter than view)")
    }
  }

  // MARK: - Tracking Control

  func pauseTracking() {
    isTracking = false
  }

  func resumeTracking() {
    isTracking = true
  }
}