//
//  ScrollPositionTracker.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/4/25.
//

import UIKit
import OSLog


@available(iOS 18.0, *)
final class ScrollPositionTracker {
  private let logger = Logger(
    subsystem: "blue.catbird", category: "ScrollPositionTracker")

  struct ScrollAnchor {
    let indexPath: IndexPath
    let offsetY: CGFloat
    let itemFrameY: CGFloat
    let timestamp: Date
  }

  private var lastAnchor: ScrollAnchor?
  private(set) var isTracking = true

  func captureScrollAnchor(collectionView: UICollectionView) -> ScrollAnchor? {
    guard isTracking else { return nil }

    // Find the first visible post that's at least 30% visible
    let visibleIndexPaths = collectionView.indexPathsForVisibleItems.sorted()
    let visibleBounds = collectionView.bounds

    for indexPath in visibleIndexPaths {
      // Only consider post items
      if indexPath.section == FeedViewController.Section.posts.rawValue,
        let attributes = collectionView.layoutAttributesForItem(at: indexPath)
      {

        // Check if the item is sufficiently visible (at least 30% showing)
        let itemFrame = attributes.frame
        let visibleArea = itemFrame.intersection(visibleBounds)
        let visibilityRatio = visibleArea.height / itemFrame.height

        if visibilityRatio >= 0.3 {
          let anchor = ScrollAnchor(
            indexPath: indexPath,
            offsetY: collectionView.contentOffset.y,
            itemFrameY: itemFrame.origin.y,
            timestamp: Date()
          )

          lastAnchor = anchor
          logger.debug(
            "Captured scroll anchor: item[\(indexPath.section), \(indexPath.item)] at y=\(itemFrame.origin.y), offset=\(collectionView.contentOffset.y), visibility=\(visibilityRatio)"
          )
          return anchor
        }
      }
    }

    return nil
  }

  func restoreScrollPosition(collectionView: UICollectionView, to anchor: ScrollAnchor) {
    guard isTracking else { return }

    // Force layout to ensure all positions are calculated
    collectionView.layoutIfNeeded()

    // Get current position of anchor item
    guard let currentAttributes = collectionView.layoutAttributesForItem(at: anchor.indexPath)
    else {
      logger.warning("Could not restore scroll position - anchor item not found")
      return
    }

    // Calculate how much content was added/removed above the anchor
    let currentItemY = currentAttributes.frame.origin.y
    let originalItemY = anchor.itemFrameY
    let heightDelta = currentItemY - originalItemY

    // Apply corrected offset
    let newOffsetY = anchor.offsetY + heightDelta
    let correctedOffset = max(0, newOffsetY)  // Don't scroll above content

    collectionView.setContentOffset(CGPoint(x: 0, y: correctedOffset), animated: false)

    logger.debug(
      "Restored scroll position: anchor moved from y=\(originalItemY) to y=\(currentItemY), delta=\(heightDelta), new offset=\(correctedOffset)"
    )
  }

  func pauseTracking() {
    isTracking = false
  }

  func resumeTracking() {
    isTracking = true
  }
}
