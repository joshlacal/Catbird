//
//  BackwardsInfiniteScrollLayout.swift
//  Catbird
//
//  Created by Josh LaCalamito on 3/17/25.
//


import UIKit

class BackwardsInfiniteScrollLayout: UICollectionViewLayout {
    private var contentBounds = CGRect.zero
    private var cachedAttributes = [UICollectionViewLayoutAttributes]()
    private var previousContentHeight: CGFloat = 0 // Track previous content height
    
    // Configuration
    var sectionInsets = UIEdgeInsets(top: 5, left: 0, bottom: 5, right: 0)
    var estimatedItemHeights: [IndexPath: CGFloat] = [:]
    var actualItemHeights: [IndexPath: CGFloat] = [:]  // Track actual measured heights
    var preloadingThreshold: CGFloat = 300
    var cellSpacing: CGFloat = 10  // Add explicit spacing between cells
    var hasAddedContentAtTop: Bool = false  // Track if content was added at top
    
    // Delegate to notify when approaching top
    weak var loadingDelegate: BackwardsInfiniteScrollLayoutDelegate?
    
    override func prepare() {
        super.prepare()
        
        guard let collectionView = collectionView else { return }
        
        // Save previous content height before recalculating
        previousContentHeight = contentBounds.height
        
        // Reset cached information
        cachedAttributes.removeAll()
        contentBounds = CGRect(origin: .zero, size: .zero)
        
        // Process all items
        let sections = collectionView.numberOfSections
        var yOffset = sectionInsets.top
        
        for section in 0..<sections {
            let items = collectionView.numberOfItems(inSection: section)
            
            for item in 0..<items {
                let indexPath = IndexPath(item: item, section: section)
                let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
                
                // Get height for this item, prioritizing actual measured heights
                let height = actualItemHeights[indexPath] ?? 
                             estimatedItemHeights[indexPath] ?? 200
                
                // Set frame with explicit spacing
                let frame = CGRect(
                    x: sectionInsets.left,
                    y: yOffset,
                    width: collectionView.bounds.width - sectionInsets.left - sectionInsets.right,
                    height: height
                )
                
                attributes.frame = frame
                cachedAttributes.append(attributes)
                
                // Update y offset with explicit spacing
                yOffset += height + cellSpacing
                contentBounds = contentBounds.union(frame)
            }
            
            // Add section spacing
            yOffset += sectionInsets.bottom
        }
        
        // Check if we need to load more content at the top
        if let delegate = loadingDelegate, 
           collectionView.contentOffset.y < preloadingThreshold,
           collectionView.contentOffset.y > 0,
           !cachedAttributes.isEmpty {
            
            delegate.layoutIsApproachingTop(self)
        }
    }
    
    override var collectionViewContentSize: CGSize {
        return CGSize(width: contentBounds.width, height: contentBounds.height + sectionInsets.bottom)
    }
    
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        return cachedAttributes.filter { $0.frame.intersects(rect) }
    }
    
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        return cachedAttributes.first { $0.indexPath == indexPath }
    }
    
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        // Only invalidate if width changes, not on scroll
        return collectionView?.bounds.width != newBounds.width
    }
    
    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint, 
                                     withScrollingVelocity velocity: CGPoint) -> CGPoint {
        guard previousContentHeight > 0 else {
            return proposedContentOffset
        }
        
        let heightDifference = collectionViewContentSize.height - previousContentHeight
        
        if heightDifference > 0 && hasAddedContentAtTop {
            // Content was added at top - adjust offset
            hasAddedContentAtTop = false
            return CGPoint(x: proposedContentOffset.x, y: proposedContentOffset.y + heightDifference)
        }
        
        return proposedContentOffset
    }
    
    // Track actual heights after cell measurement
    func updateActualHeight(for indexPath: IndexPath, height: CGFloat) {
        actualItemHeights[indexPath] = height
        // Don't invalidate immediately - this would cause jumps
    }
    
    // Batch update heights and invalidate once
    func applyMeasuredHeights() {
        invalidateLayout()
    }
    
    // Mark that content was added at the top for position preservation
    func markContentAddedAtTop() {
        hasAddedContentAtTop = true
    }

    // Update estimated height for a specific item
    func updateEstimatedHeight(for indexPath: IndexPath, height: CGFloat) {
        estimatedItemHeights[indexPath] = height
    }
}

// Protocol for notifying about approaching top
protocol BackwardsInfiniteScrollLayoutDelegate: AnyObject {
    func layoutIsApproachingTop(_ layout: BackwardsInfiniteScrollLayout)
}
