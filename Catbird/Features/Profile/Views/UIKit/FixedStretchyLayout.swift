import UIKit
import os

// MARK: - Fixed Stretchy Layout
@available(iOS 18.0, *)
final class FixedStretchyLayout: UICollectionViewCompositionalLayout {
  private let layoutLogger = Logger(subsystem: "blue.catbird", category: "FixedStretchyLayout")
  
  private var lastScrollOffset: CGFloat = 0
  private let scrollThreshold: CGFloat = 5.0 // Balanced threshold for responsive stretching
  private var isInvalidating: Bool = false // Guard against recursive invalidation
  private var lastInvalidationTime: CFTimeInterval = 0
  private var lastStretchAmount: CGFloat = 0 // Track stretch to reduce redundant updates
  
  override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
    guard let collectionView = collectionView,
          let layoutAttributes = super.layoutAttributesForElements(in: rect) else {
      return nil
    }
    
    let contentOffsetY = collectionView.contentOffset.y
    let adjustedContentInset = collectionView.adjustedContentInset.top
    let overscrollOffset = contentOffsetY + adjustedContentInset
    
    // Only process if we're actually overscrolling or have a header
    let isOverscrolling = overscrollOffset < 0
    
    for attributes in layoutAttributes {
      // Only modify the first section header (banner)
      if attributes.representedElementKind == UICollectionView.elementKindSectionHeader &&
         attributes.indexPath.section == 0 {
        
        updateHeaderAttributes(attributes, 
                             contentOffsetY: contentOffsetY, 
                             adjustedContentInset: adjustedContentInset)
        
        // Only notify if stretch amount changed significantly
        let currentStretch = isOverscrolling ? abs(overscrollOffset) : 0
        if abs(currentStretch - lastStretchAmount) > 1.0 {
          notifyHeaderViewOfStretch(at: attributes.indexPath, 
                                  contentOffsetY: contentOffsetY, 
                                  adjustedContentInset: adjustedContentInset)
          lastStretchAmount = currentStretch
        }
      } else {
        // Simplified Z-index to prevent overlapping issues
        attributes.zIndex = 1
      }
    }
    
    return layoutAttributes
  }
  
  private func updateHeaderAttributes(_ attributes: UICollectionViewLayoutAttributes,
                                    contentOffsetY: CGFloat,
                                    adjustedContentInset: CGFloat) {
    // Calculate overscroll amount
    let overscrollOffset = contentOffsetY + adjustedContentInset
    
    if overscrollOffset < 0 {
      // Pulling down - stretch the header
      let stretchAmount = abs(overscrollOffset)
      
      var frame = attributes.frame
      
      // Elastic stretch effect:
      // Pin header to top and expand height
      frame.origin.y = contentOffsetY // Pin to current scroll position
      
      // Expand height to create stretchy effect
      let originalHeight = attributes.frame.height
      frame.size.height = originalHeight + stretchAmount
      
      // Validate frame before applying
      if frame.size.height > 0 && frame.size.width > 0 && 
         !frame.size.height.isInfinite && !frame.size.width.isInfinite &&
         !frame.size.height.isNaN && !frame.size.width.isNaN {
        attributes.frame = frame
      }
      
      attributes.zIndex = 0 // At base level, let header view handle internal z-ordering
      
    } else {
      // Normal scrolling - no parallax to keep it simple and performant
      // Header stays at its original position
      attributes.zIndex = 0
    }
  }
  
  private func notifyHeaderViewOfStretch(at indexPath: IndexPath,
                                       contentOffsetY: CGFloat,
                                       adjustedContentInset: CGFloat) {
    guard let collectionView = collectionView else { return }
    
    // Get the header view
    let headerView = collectionView.supplementaryView(
      forElementKind: UICollectionView.elementKindSectionHeader,
      at: indexPath
    )
    
    // Calculate overscroll amount
    let overscrollOffset = contentOffsetY + adjustedContentInset
    
    if let enhancedHeader = headerView as? EnhancedProfileHeaderView {
      // Direct call without Task for immediate response
      if overscrollOffset < 0 {
        let stretchAmount = abs(overscrollOffset)
        enhancedHeader.updateForStretch(stretchAmount: stretchAmount)
      } else {
        enhancedHeader.resetStretch()
      }
    } else if let fixedHeader = headerView as? FixedProfileHeaderView {
      // Support for the alternative header view
      if overscrollOffset < 0 {
        let stretchAmount = abs(overscrollOffset)
        fixedHeader.updateForStretch(stretchAmount: stretchAmount)
      } else {
        fixedHeader.resetStretch()
      }
    }
  }
  
  override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
    guard let collectionView = collectionView else { return false }
    
    // Prevent recursive invalidation
    guard !isInvalidating else { 
      return false 
    }
    
    // Throttle invalidations for performance
    let currentTime = CFAbsoluteTimeGetCurrent()
    guard currentTime - lastInvalidationTime > 0.016 else { // 60 FPS max for smoother feel
      return false
    }
    
    let currentOffset = collectionView.contentOffset.y
    let newOffset = newBounds.origin.y
    
    // Check for significant size changes (orientation, etc)
    let sizeChanged = abs(collectionView.bounds.height - newBounds.height) > 1.0 ||
                     abs(collectionView.bounds.width - newBounds.width) > 1.0
    
    // Only invalidate for overscroll (when we need to stretch the header)
    let adjustedTop = collectionView.adjustedContentInset.top
    let isOverscrolling = newOffset < -adjustedTop
    
    // Invalidate only when necessary
    let shouldInvalidate = sizeChanged || isOverscrolling
    
    if shouldInvalidate {
      lastScrollOffset = newOffset
      lastInvalidationTime = currentTime
    }
    
    return shouldInvalidate
  }
  
  override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
    // Guard against recursive invalidation
    guard !isInvalidating else {
      layoutLogger.debug("Skipping recursive invalidation")
      return
    }
    
    isInvalidating = true
    defer { isInvalidating = false }
    
    if context.invalidateEverything || context.invalidateDataSourceCounts {
      layoutLogger.debug("Layout invalidated completely")
    }
    
    super.invalidateLayout(with: context)
  }
}
