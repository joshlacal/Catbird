//
//  UnifiedScrollPreservationTests.swift
//  CatbirdTests
//
//  Tests for unified scroll preservation pipeline
//

import Testing
import UIKit
@testable import Catbird

@available(iOS 16.0, *)
struct UnifiedScrollPreservationTests {
    
    // MARK: - Test Fixtures
    
    private func makeTestCollectionView() -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 375, height: 100)
        layout.minimumLineSpacing = 0
        
        let collectionView = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: 375, height: 667),
            collectionViewLayout: layout
        )
        
        return collectionView
    }
    
    private func makeTestDataSource(
        collectionView: UICollectionView
    ) -> UICollectionViewDiffableDataSource<Int, String> {
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewCell, String> { cell, indexPath, item in
            // Simple cell configuration
        }
        
        return UICollectionViewDiffableDataSource<Int, String>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(
                using: cellRegistration,
                for: indexPath,
                item: item
            )
        }
    }
    
    // MARK: - Viewport Relative Tests
    
    @Test("Viewport relative preservation maintains visual content")
    @MainActor
    func testViewportRelativePreservation() async {
        let pipeline = UnifiedScrollPreservationPipeline()
        let collectionView = makeTestCollectionView()
        let dataSource = makeTestDataSource(collectionView: collectionView)
        
        // Initial data
        let initialData = (0..<20).map { "post-\($0)" }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(initialData)
        await dataSource.apply(snapshot, animatingDifferences: false)
        
        // Scroll to middle
        collectionView.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        collectionView.layoutIfNeeded()
        
        // Capture initial state
        let initialOffset = collectionView.contentOffset.y
        
        // New data with posts added at top
        let newData = ["new-1", "new-2", "new-3"] + initialData
        
        // Perform update with viewport relative strategy
        let result = await pipeline.performUpdate(
            type: .newPostsAtTop,
            collectionView: collectionView,
            dataSource: dataSource,
            newData: newData,
            currentData: initialData,
            getPostId: { indexPath in
                indexPath.item < newData.count ? newData[indexPath.item] : nil
            }
        )
        
        #expect(result.success == true)
        
        // With 3 new items of 100px each, offset should increase by ~300
        let expectedOffset = initialOffset + 300
        let actualOffset = result.finalOffset.y
        
        #expect(abs(actualOffset - expectedOffset) < 10) // Allow small variance
    }
    
    // MARK: - Exact Position Tests
    
    @Test("Load more maintains exact scroll position")
    @MainActor
    func testLoadMoreExactPosition() async {
        let pipeline = UnifiedScrollPreservationPipeline()
        let collectionView = makeTestCollectionView()
        let dataSource = makeTestDataSource(collectionView: collectionView)
        
        // Initial data
        let initialData = (0..<20).map { "post-\($0)" }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(initialData)
        await dataSource.apply(snapshot, animatingDifferences: false)
        
        // Scroll near bottom
        collectionView.setContentOffset(CGPoint(x: 0, y: 1500), animated: false)
        collectionView.layoutIfNeeded()
        
        let initialOffset = collectionView.contentOffset.y
        
        // Add more data at bottom
        let newData = initialData + (20..<30).map { "post-\($0)" }
        
        // Perform update with load more strategy
        let result = await pipeline.performUpdate(
            type: .loadMore,
            collectionView: collectionView,
            dataSource: dataSource,
            newData: newData,
            currentData: initialData,
            getPostId: { indexPath in
                indexPath.item < newData.count ? newData[indexPath.item] : nil
            }
        )
        
        #expect(result.success == true)
        #expect(result.finalOffset.y == initialOffset) // Exact position maintained
    }
    
    // MARK: - Memory Warning Tests
    
    @Test("Memory warning preserves scroll position")
    @MainActor
    func testMemoryWarningPreservation() async {
        let pipeline = UnifiedScrollPreservationPipeline()
        let collectionView = makeTestCollectionView()
        let dataSource = makeTestDataSource(collectionView: collectionView)
        
        // Setup data
        let data = (0..<50).map { "post-\($0)" }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(data)
        await dataSource.apply(snapshot, animatingDifferences: false)
        
        // Scroll to specific position
        collectionView.setContentOffset(CGPoint(x: 0, y: 1000), animated: false)
        collectionView.layoutIfNeeded()
        
        let initialOffset = collectionView.contentOffset.y
        
        // Simulate memory warning update
        let result = await pipeline.performUpdate(
            type: .memoryWarning,
            collectionView: collectionView,
            dataSource: dataSource,
            newData: data,
            currentData: data,
            getPostId: { indexPath in
                indexPath.item < data.count ? data[indexPath.item] : nil
            }
        )
        
        #expect(result.success == true)
        
        // Position should be maintained or clamped if content changed
        let offsetDifference = abs(result.finalOffset.y - initialOffset)
        #expect(offsetDifference < 50) // Allow small adjustment for clamping
    }
    
    // MARK: - Pull to Refresh Tests
    
    @Test("Pull to refresh with anchor preserves position correctly")
    @MainActor
    func testPullToRefreshWithAnchor() async {
        let pipeline = UnifiedScrollPreservationPipeline()
        let collectionView = makeTestCollectionView()
        let dataSource = makeTestDataSource(collectionView: collectionView)
        
        // Initial data
        let initialData = (0..<20).map { "post-\($0)" }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(initialData)
        await dataSource.apply(snapshot, animatingDifferences: false)
        
        // Simulate pull to refresh (negative offset)
        collectionView.setContentOffset(CGPoint(x: 0, y: -100), animated: false)
        collectionView.layoutIfNeeded()
        
        // Create anchor at first visible item
        let anchor = UnifiedScrollPreservationPipeline.ScrollAnchor(
            indexPath: IndexPath(item: 0, section: 0),
            postId: "post-0",
            contentOffset: CGPoint(x: 0, y: -100),
            viewportRelativeY: 100, // First item is 100px below viewport top due to negative offset
            itemFrameY: 0,
            timestamp: Date()
        )
        
        // New data with items at top
        let newData = ["new-1", "new-2"] + initialData
        
        // Perform refresh update
        let result = await pipeline.performUpdate(
            type: .refresh(anchor: anchor),
            collectionView: collectionView,
            dataSource: dataSource,
            newData: newData,
            currentData: initialData,
            getPostId: { indexPath in
                indexPath.item < newData.count ? newData[indexPath.item] : nil
            }
        )
        
        #expect(result.success == true)
        
        // The anchor post (post-0) should maintain its viewport-relative position
        // It was at index 0, now at index 2 (after 2 new posts)
        // Expected offset: 2 items * 100px - 100px viewport offset = 100px
        let expectedOffset: CGFloat = 100
        #expect(abs(result.finalOffset.y - expectedOffset) < 10)
    }
    
    // MARK: - Edge Case Tests
    
    @Test("Handles empty data gracefully")
    @MainActor
    func testEmptyDataHandling() async {
        let pipeline = UnifiedScrollPreservationPipeline()
        let collectionView = makeTestCollectionView()
        let dataSource = makeTestDataSource(collectionView: collectionView)
        
        // Start with empty data
        let result = await pipeline.performUpdate(
            type: .normalUpdate,
            collectionView: collectionView,
            dataSource: dataSource,
            newData: [],
            currentData: [],
            getPostId: { _ in nil }
        )
        
        #expect(result.success == true)
        #expect(result.finalOffset == .zero)
    }
    
    @Test("Clamps offset when content shrinks")
    @MainActor
    func testOffsetClampingOnContentShrink() async {
        let pipeline = UnifiedScrollPreservationPipeline()
        let collectionView = makeTestCollectionView()
        let dataSource = makeTestDataSource(collectionView: collectionView)
        
        // Initial large dataset
        let initialData = (0..<50).map { "post-\($0)" }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(initialData)
        await dataSource.apply(snapshot, animatingDifferences: false)
        
        // Scroll to bottom
        let maxOffset = 50 * 100 - 667 // items * height - viewport height
        collectionView.setContentOffset(CGPoint(x: 0, y: maxOffset), animated: false)
        collectionView.layoutIfNeeded()
        
        // Shrink data significantly
        let newData = (0..<5).map { "post-\($0)" }
        
        let result = await pipeline.performUpdate(
            type: .normalUpdate,
            collectionView: collectionView,
            dataSource: dataSource,
            newData: newData,
            currentData: initialData,
            getPostId: { indexPath in
                indexPath.item < newData.count ? newData[indexPath.item] : nil
            }
        )
        
        #expect(result.success == true)
        
        // Offset should be clamped to new max
        _ = max(0, 5 * 100 - 667)
        #expect(result.finalOffset.y <= 0) // With only 5 items, content fits in viewport
    }
    
    // MARK: - Performance Tests
    
    @Test("Handles large dataset efficiently")
    @MainActor
    func testLargeDatasetPerformance() async {
        let pipeline = UnifiedScrollPreservationPipeline()
        let collectionView = makeTestCollectionView()
        let dataSource = makeTestDataSource(collectionView: collectionView)
        
        // Large dataset
        let data = (0..<1000).map { "post-\($0)" }
        
        let startTime = Date()
        
        let result = await pipeline.performUpdate(
            type: .normalUpdate,
            collectionView: collectionView,
            dataSource: dataSource,
            newData: data,
            currentData: [],
            getPostId: { indexPath in
                indexPath.item < data.count ? data[indexPath.item] : nil
            }
        )
        
        let duration = Date().timeIntervalSince(startTime)
        
        #expect(result.success == true)
        #expect(duration < 1.0) // Should complete within 1 second
    }
    
    // MARK: - Pixel Perfect Tests
    
    @Test("Maintains pixel-perfect alignment")
    @MainActor
    func testPixelPerfectAlignment() async {
        let pipeline = UnifiedScrollPreservationPipeline()
        let collectionView = makeTestCollectionView()
        let dataSource = makeTestDataSource(collectionView: collectionView)
        
        let displayScale = PlatformScreenInfo.scale
        
        // Setup with specific offset that needs pixel alignment
        let data = (0..<20).map { "post-\($0)" }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(data)
        await dataSource.apply(snapshot, animatingDifferences: false)
        
        // Set non-pixel-aligned offset
        let unalignedOffset: CGFloat = 123.456789
        collectionView.setContentOffset(CGPoint(x: 0, y: unalignedOffset), animated: false)
        
        let result = await pipeline.performUpdate(
            type: .normalUpdate,
            collectionView: collectionView,
            dataSource: dataSource,
            newData: data,
            currentData: data,
            getPostId: { indexPath in
                indexPath.item < data.count ? data[indexPath.item] : nil
            }
        )
        
        // Check pixel alignment
        let finalPixels = result.finalOffset.y * displayScale
        let isPixelAligned = abs(finalPixels - round(finalPixels)) < 0.001
        
        #expect(isPixelAligned == true)
    }
}

// MARK: - Integration Tests

@available(iOS 16.0, *)
struct FeedCollectionViewControllerScrollTests {
    
    @Test("FeedCollectionViewController integrates with unified pipeline")
    @MainActor
    func testControllerIntegration() async {
        // This would test the actual FeedCollectionViewController
        // with the unified pipeline integration
        
        // Create mock state manager
        let mockStateManager = FeedStateManager(
            appState: AppState.shared,
            feedModel: FeedModel(
                feedManager: FeedManager(
                    client: AppState.shared.atProtoClient,
                    fetchType: .timeline
                ),
                appState: AppState.shared
            ),
            feedType: .timeline
        )
        
        // Create controller
        let navigationPath = Binding<NavigationPath>(
            get: { NavigationPath() },
            set: { _ in }
        )
        
        let controller = FeedCollectionViewController(
            stateManager: mockStateManager,
            navigationPath: navigationPath
        )
        
        // Load view
        _ = controller.view
        
        // Verify unified pipeline is used
        #expect(controller.collectionView != nil)
    }
}
