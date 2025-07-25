import UIKit
import os

// MARK: - Fixed Stretchy Layout
@available(iOS 18.0, *)
final class FixedStretchyLayout: UICollectionViewCompositionalLayout {
  private let layoutLogger = Logger(subsystem: "blue.catbird", category: "FixedStretchyLayout")
  
  private var lastScrollOffset: CGFloat = 0
  private let scrollThreshold: CGFloat = 1.0 // Only invalidate if scroll change is significant
  
  override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
    guard let collectionView = collectionView,
          let layoutAttributes = super.layoutAttributesForElements(in: rect) else {
      return nil
    }
    
    let contentOffsetY = collectionView.contentOffset.y
    let adjustedContentInset = collectionView.adjustedContentInset.top
    
    for attributes in layoutAttributes {
      // Only modify the first section header (banner)
      if attributes.representedElementKind == UICollectionView.elementKindSectionHeader &&
         attributes.indexPath.section == 0 {
        
        updateHeaderAttributes(attributes, 
                             contentOffsetY: contentOffsetY, 
                             adjustedContentInset: adjustedContentInset)
        
        // Notify header view of stretch amount
        notifyHeaderViewOfStretch(at: attributes.indexPath, 
                                contentOffsetY: contentOffsetY, 
                                adjustedContentInset: adjustedContentInset)
      } else {
        // Lower z-index for all content below header
        if attributes.indexPath.section == 1 {
          // Profile info section should be above banner but avatar should be on top
          attributes.zIndex = 100
        } else {
          // Other sections get lower z-index
          attributes.zIndex = attributes.indexPath.section * 100 + attributes.indexPath.item
        }
      }
    }
    
    return layoutAttributes
  }
  
  private func updateHeaderAttributes(_ attributes: UICollectionViewLayoutAttributes,
                                    contentOffsetY: CGFloat,
                                    adjustedContentInset: CGFloat) {
    // When pulling down (overscroll)
    let overscrollOffset = contentOffsetY + adjustedContentInset
    
    if overscrollOffset < 0 {
      let stretchAmount = abs(overscrollOffset)
      
      var frame = attributes.frame
      
      // Safe stretch calculation with bounds checking
      let originalHeight = attributes.frame.height
      let maxStretch = originalHeight * 2.0 // Limit stretch to 2x original height
      let clampedStretch = min(stretchAmount, maxStretch)
      
      // Ensure frame dimensions are always valid
      frame.size.height = max(originalHeight, originalHeight + clampedStretch)
      frame.size.width = max(1.0, frame.size.width) // Ensure positive width
      frame.origin.y = min(contentOffsetY, frame.origin.y) // Prevent invalid Y position
      
      // Validate frame before applying
      if frame.size.height > 0 && frame.size.width > 0 && 
         !frame.size.height.isInfinite && !frame.size.width.isInfinite &&
         !frame.size.height.isNaN && !frame.size.width.isNaN {
        attributes.frame = frame
      }
      
      attributes.zIndex = 50 // Much lower z-index so avatar can appear on top
      
      if stretchAmount > 10 {
        layoutLogger.debug("Header stretching: offset=\(contentOffsetY, privacy: .public), stretch=\(clampedStretch, privacy: .public)")
      }
    } else {
      // Normal state - much lower z-index so avatar can appear on top
      attributes.zIndex = 50
    }
  }
  
  private func notifyHeaderViewOfStretch(at indexPath: IndexPath,
                                       contentOffsetY: CGFloat,
                                       adjustedContentInset: CGFloat) {
    guard let collectionView = collectionView,
          let headerView = collectionView.supplementaryView(
            forElementKind: UICollectionView.elementKindSectionHeader,
            at: indexPath
          ) as? FixedProfileHeaderView else {
      return
    }
    
    let overscrollOffset = contentOffsetY + adjustedContentInset
    
    if overscrollOffset < 0 {
      let stretchAmount = abs(overscrollOffset)
      Task { @MainActor in
        headerView.updateForStretch(stretchAmount: stretchAmount)
      }
    } else {
      Task { @MainActor in
        headerView.resetStretch()
      }
    }
  }
  
  override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
    guard let collectionView = collectionView else { return false }
    
    let currentOffset = collectionView.contentOffset.y
    let newOffset = newBounds.origin.y
    let sizeChanged = abs(collectionView.bounds.height - newBounds.height) > 0.1 ||
                     abs(collectionView.bounds.width - newBounds.width) > 0.1
    
    // Only invalidate for significant scroll changes or size changes
    let shouldInvalidate = abs(currentOffset - newOffset) > scrollThreshold || sizeChanged
    
    if shouldInvalidate {
      lastScrollOffset = newOffset
    }
    
    return shouldInvalidate
  }
  
  override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
    if context.invalidateEverything || context.invalidateDataSourceCounts {
      layoutLogger.debug("Layout invalidated completely")
    }
    super.invalidateLayout(with: context)
  }
}
