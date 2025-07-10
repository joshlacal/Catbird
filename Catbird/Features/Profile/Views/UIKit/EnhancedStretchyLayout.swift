import UIKit
import os

@available(iOS 18.0, *)
final class EnhancedStretchyLayout: UICollectionViewCompositionalLayout {
//  private let logger = Logger(subsystem: "blue.catbird", category: "EnhancedStretchyLayout")
  
  private var lastStretchAmount: CGFloat = 0
  private let maxStretchLimit: CGFloat = 300
  private let dampingThreshold: CGFloat = 100
  
  override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
    guard let collectionView = collectionView,
          let layoutAttributes = super.layoutAttributesForElements(in: rect) else {
      return nil
    }
    
    let contentOffsetY = collectionView.contentOffset.y
    let adjustedContentInset = collectionView.adjustedContentInset.top
    let safeAreaTop = collectionView.safeAreaInsets.top
    
    for attributes in layoutAttributes {
      if attributes.representedElementKind == UICollectionView.elementKindSectionHeader &&
         attributes.indexPath.section == 0 {
        
        updateHeaderAttributes(attributes, contentOffsetY: contentOffsetY, 
                             adjustedContentInset: adjustedContentInset, 
                             safeAreaTop: safeAreaTop)
        
        notifyHeaderViewOfStretch(at: attributes.indexPath)
      } else {
        attributes.zIndex = attributes.indexPath.row
      }
    }
    
    return layoutAttributes
  }
  
  private func updateHeaderAttributes(_ attributes: UICollectionViewLayoutAttributes, 
                                    contentOffsetY: CGFloat, 
                                    adjustedContentInset: CGFloat, 
                                    safeAreaTop: CGFloat) {
    attributes.zIndex = 1000
    
    let overscrollOffset = contentOffsetY + adjustedContentInset
    
    if overscrollOffset < 0 {
      let rawStretchAmount = abs(overscrollOffset)
      let dampedStretchAmount = calculateDampedStretch(rawStretchAmount)
      
      var frame = attributes.frame
      frame.size.height = attributes.frame.height + dampedStretchAmount
      frame.origin.y = contentOffsetY
      attributes.frame = frame
      
      lastStretchAmount = dampedStretchAmount
      
      if dampedStretchAmount > 5 {
        logger.debug("Stretching: raw=\(rawStretchAmount, privacy: .public), damped=\(dampedStretchAmount, privacy: .public)")
      }
    } else {
      lastStretchAmount = 0
    }
  }
  
  private func calculateDampedStretch(_ rawAmount: CGFloat) -> CGFloat {
    guard rawAmount > 0 else { return 0 }
    
    if rawAmount <= dampingThreshold {
      return rawAmount
    }
    
    let excessAmount = rawAmount - dampingThreshold
    let dampingFactor: CGFloat = 0.3
    let dampedExcess = excessAmount * dampingFactor
    let totalDamped = dampingThreshold + dampedExcess
    
    return min(totalDamped, maxStretchLimit)
  }
  
  private func notifyHeaderViewOfStretch(at indexPath: IndexPath) {
    guard let collectionView = collectionView,
          let headerView = collectionView.supplementaryView(
            forElementKind: UICollectionView.elementKindSectionHeader,
            at: indexPath
          ) as? EnhancedProfileHeaderView else {
      return
    }
    
    Task { @MainActor in
      headerView.updateForStretch(stretchAmount: lastStretchAmount)
    }
  }
  
  override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
    guard let collectionView = collectionView else { return false }
    
    let currentOffset = collectionView.contentOffset.y
    let newOffset = newBounds.origin.y
    let sizeDifference = abs(collectionView.bounds.width - newBounds.width) > 1.0
    
    return currentOffset != newOffset || sizeDifference
  }
  
  override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
    if context.invalidateEverything || context.invalidateDataSourceCounts {
      lastStretchAmount = 0
    }
    super.invalidateLayout(with: context)
  }
}
