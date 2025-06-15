import SwiftUI

/// A masonry layout that arranges views in columns with minimal gaps, perfect for GIFs with varying aspect ratios
struct MasonryLayout: Layout {
    let columns: Int
    let spacing: CGFloat
    
    init(columns: Int = 2, spacing: CGFloat = 8) {
        self.columns = columns
        self.spacing = spacing
    }
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout MasonryCache) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        
        let containerWidth = proposal.width ?? 400
        let columnWidth = (containerWidth - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        
        // Only calculate if cache is empty or width changed
        if cache.itemSizes.isEmpty || abs(cache.lastColumnWidth - columnWidth) > 0.1 {
            cache.setup(subviews: subviews, columnWidth: columnWidth, columns: columns, spacing: spacing)
        }
        
        let maxHeight = cache.columnHeights.max() ?? 0
        return CGSize(width: containerWidth, height: maxHeight)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout MasonryCache) {
        guard !subviews.isEmpty else { return }
        
        let columnWidth = (bounds.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        
        // Only recalculate if cache is empty or width changed
        if cache.itemSizes.isEmpty || abs(cache.lastColumnWidth - columnWidth) > 0.1 {
            cache.setup(subviews: subviews, columnWidth: columnWidth, columns: columns, spacing: spacing)
        }
        
        // Place each subview
        for (index, subview) in subviews.enumerated() {
            guard index < cache.itemSizes.count && index < cache.itemPositions.count else { continue }
            
            let targetSize = cache.itemSizes[index]
            let position = cache.itemPositions[index]
            
            let finalPosition = CGPoint(
                x: bounds.minX + position.x,
                y: bounds.minY + position.y
            )
            
            subview.place(
                at: finalPosition,
                anchor: .topLeading,
                proposal: ProposedViewSize(targetSize)
            )
        }
    }
    
    func makeCache(subviews: Subviews) -> MasonryCache {
        MasonryCache()
    }
}

/// Cache for masonry layout calculations
struct MasonryCache {
    var columnHeights: [CGFloat] = []
    var itemSizes: [CGSize] = []
    var itemPositions: [CGPoint] = []
    var lastColumnWidth: CGFloat = 0
    
    mutating func setup(subviews: Layout.Subviews, columnWidth: CGFloat, columns: Int, spacing: CGFloat) {
        // Initialize column heights
        columnHeights = Array(repeating: 0, count: columns)
        itemSizes = []
        itemPositions = []
        lastColumnWidth = columnWidth
        
        // Calculate size and position for each item
        for subview in subviews {
            // Get the ideal size for this subview with our column width constraint
            let idealSize = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            
            // The width should be our column width, height should maintain aspect ratio
            let size = CGSize(width: columnWidth, height: idealSize.height)
            itemSizes.append(size)
            
            // Find the shortest column
            let shortestColumnIndex = columnHeights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            
            // Calculate position
            let x = CGFloat(shortestColumnIndex) * (columnWidth + spacing)
            let y = columnHeights[shortestColumnIndex]
            
            itemPositions.append(CGPoint(x: x, y: y))
            
            // Update column height
            columnHeights[shortestColumnIndex] += size.height + spacing
        }
    }
}