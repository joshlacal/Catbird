import UIKit
import os

// MARK: - Simplified Profile Layout
@available(iOS 18.0, *)
final class SimplifiedProfileLayout: UICollectionViewCompositionalLayout {
  private let layoutLogger = Logger(subsystem: "blue.catbird", category: "SimplifiedProfileLayout")
  
  // Track only critical changes that require layout invalidation
  private var lastContentSize: CGSize = .zero
  private var isInvalidating: Bool = false
  
  override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
    guard let collectionView = collectionView else { return false }
    
    // Prevent recursive invalidation
    guard !isInvalidating else { 
      return false 
    }
    
    let currentBounds = collectionView.bounds
    
    // Only invalidate for significant size changes (orientation, window resize)
    // NOT for scroll position changes
    let sizeChanged = abs(currentBounds.width - newBounds.width) > 1.0 ||
                     abs(currentBounds.height - newBounds.height) > 1.0
    
    if sizeChanged {
      layoutLogger.debug("Layout invalidated for size change: \(NSCoder.string(for: currentBounds.size)) -> \(NSCoder.string(for: newBounds.size))")
    }
    
    // Never invalidate for scroll position changes - this is the key to smooth performance
    // The header view will handle all stretch animations internally
    return sizeChanged
  }
  
  override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
    // Guard against recursive invalidation
    guard !isInvalidating else {
      layoutLogger.debug("Prevented recursive invalidation")
      return
    }
    
    isInvalidating = true
    defer { isInvalidating = false }
    
    if context.invalidateEverything || context.invalidateDataSourceCounts {
      layoutLogger.debug("Layout completely invalidated")
    } else {
      layoutLogger.debug("Layout partially invalidated")
    }
    
    super.invalidateLayout(with: context)
  }
  
  override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
    // Get the standard attributes without any scroll-based modifications
    guard let layoutAttributes = super.layoutAttributesForElements(in: rect) else {
      return nil
    }
    
    // Return attributes as-is - no frame manipulation here
    // The header view will handle all dynamic positioning internally
    return layoutAttributes
  }
  
  override func layoutAttributesForSupplementaryView(ofKind elementKind: String, at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
    guard let attributes = super.layoutAttributesForSupplementaryView(ofKind: elementKind, at: indexPath) else {
      return nil
    }
    
    // For the banner header (section 0), ensure proper z-index but don't modify frame
    if elementKind == UICollectionView.elementKindSectionHeader && indexPath.section == 0 {
      attributes.zIndex = 0 // Base level - let header manage internal layering
    }
    
    return attributes
  }
}