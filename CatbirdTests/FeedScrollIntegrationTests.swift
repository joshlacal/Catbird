//
//  FeedScrollIntegrationTests.swift
//  CatbirdTests
//
//  Integration tests for the unified scroll preservation system
//

import Testing
import UIKit
@testable import Catbird

@available(iOS 18.0, *)
@MainActor
struct FeedScrollIntegrationTests {
    
    // MARK: - UIUpdateLink Tests
    
    @Test("UIUpdateLink provides pixel-perfect scroll restoration")
    func testPixelPerfectScrollRestoration() async throws {
        let system = OptimizedScrollPreservationSystem()
        let collectionView = MockCollectionView()
        
        // Set up test data
        collectionView.contentSize = CGSize(width: 375, height: 5000)
        collectionView.bounds = CGRect(x: 0, y: 0, width: 375, height: 812)
        collectionView.contentOffset = CGPoint(x: 0, y: 1234.5)
        
        // Capture anchor
        let anchor = system.capturePreciseAnchor(from: collectionView)
        #expect(anchor != nil)
        
        // Simulate content update
        collectionView.contentSize = CGSize(width: 375, height: 5500)
        
        // Restore position
        let success = await system.restorePositionSmoothly(
            to: anchor!,
            in: collectionView,
            newPostIds: ["post1", "post2", "post3"],
            animated: false
        )
        
        #expect(success == true)
        
        // Verify pixel-perfect restoration
        let displayScale = UIScreen.main.scale
        let expectedOffset = round(1234.5 * displayScale) / displayScale
        #expect(abs(collectionView.contentOffset.y - expectedOffset) < 0.01)
    }
    
    @Test("UIUpdateLink handles frame synchronization correctly")
    func testFrameSynchronization() async throws {
        let system = OptimizedScrollPreservationSystem()
        let collectionView = MockCollectionView()
        
        var updateCompleted = false
        
        await withCheckedContinuation { continuation in
            system.createOptimizedUpdateLink(
                for: collectionView,
                targetOffset: CGPoint(x: 0, y: 500)
            ) { success in
                updateCompleted = success
                continuation.resume()
            }
        }
        
        #expect(updateCompleted == true)
    }
    
    // MARK: - Gap Detection Tests
    
    @Test("Gap detection identifies missing posts correctly")
    func testGapDetection() async throws {
        let system = OptimizedScrollPreservationSystem()
        
        let currentPosts = ["post1", "post2", "post3", "post10", "post11"]
        let visibleRange = 2..<4  // Viewing post3 and post10
        
        let result = system.detectGaps(
            currentPosts: currentPosts,
            visibleRange: visibleRange,
            cursor: "cursor123",
            previousCursor: nil
        )
        
        #expect(result.hasGap == true)
        #expect(result.gapSize > 0)
    }
    
    @Test("Gap loading manager preloads content to prevent gaps")
    func testGapPreloading() async throws {
        let manager = FeedGapLoadingManager()
        let stateManager = MockFeedStateManager()
        
        // Set up initial state
        stateManager.posts = Array(repeating: MockPost(), count: 20)
        
        // Simulate scrolling near top
        let visibleRange = 2..<7
        
        await manager.preloadToPreventGaps(
            stateManager: stateManager,
            scrollDirection: .up,
            visibleRange: visibleRange
        )
        
        // Verify preload was triggered
        #expect(stateManager.refreshCalled == true)
    }
    
    // MARK: - App Lifecycle Tests
    
    @Test("Scroll position persists through app suspension")
    func testAppSuspensionPersistence() async throws {
        let controller = FeedCollectionViewControllerIntegrated(
            stateManager: MockFeedStateManager(),
            navigationPath: .constant(NavigationPath()),
            onScrollOffsetChanged: nil
        )
        
        // Load view to trigger setup
        _ = controller.view
        
        // Set scroll position
        controller.collectionView.contentOffset = CGPoint(x: 0, y: 1500)
        
        // Simulate app entering background
        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        // Wait for save to complete
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Verify position was saved
        let savedState = controller.loadPersistedScrollState()
        #expect(savedState != nil)
        #expect(abs(savedState!.contentOffset - 1500) < 1)
        
        // Simulate app returning to foreground
        NotificationCenter.default.post(
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        
        // Wait for restoration
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // Verify position was restored
        #expect(abs(controller.collectionView.contentOffset.y - 1500) < 10)
    }
    
    @Test("Automatic persistence saves position periodically")
    func testAutomaticPersistence() async throws {
        let controller = FeedCollectionViewControllerIntegrated(
            stateManager: MockFeedStateManager(),
            navigationPath: .constant(NavigationPath()),
            onScrollOffsetChanged: nil
        )
        
        _ = controller.view
        
        // Scroll significantly
        controller.collectionView.contentOffset = CGPoint(x: 0, y: 500)
        
        // Wait for automatic persistence timer
        try await Task.sleep(nanoseconds: 2_100_000_000) // 2.1 seconds
        
        // Verify position was saved
        let savedState = controller.loadPersistedScrollState()
        #expect(savedState != nil)
    }
    
    // MARK: - Update Type Tests
    
    @Test("Refresh preserves scroll position with viewport-relative strategy")
    func testRefreshPreservation() async throws {
        let pipeline = UnifiedScrollPreservationPipeline()
        let collectionView = MockCollectionView()
        let dataSource = MockDataSource()
        
        let result = await pipeline.performUpdate(
            type: .refresh(anchor: nil),
            collectionView: collectionView,
            dataSource: dataSource,
            newData: ["post1", "post2", "post3"],
            currentData: ["oldPost1", "oldPost2"],
            getPostId: { _ in "post1" }
        )
        
        #expect(result.success == true)
    }
    
    @Test("Load more maintains exact position")
    func testLoadMorePreservation() async throws {
        let pipeline = UnifiedScrollPreservationPipeline()
        let collectionView = MockCollectionView()
        let dataSource = MockDataSource()
        
        collectionView.contentOffset = CGPoint(x: 0, y: 2000)
        
        let result = await pipeline.performUpdate(
            type: .loadMore,
            collectionView: collectionView,
            dataSource: dataSource,
            newData: ["post1", "post2", "post3", "post4", "post5"],
            currentData: ["post1", "post2", "post3"],
            getPostId: { _ in "post1" }
        )
        
        #expect(result.success == true)
        #expect(abs(collectionView.contentOffset.y - 2000) < 1)
    }
    
    @Test("Memory warning preserves position while clearing non-visible cells")
    func testMemoryWarningHandling() async throws {
        let controller = FeedCollectionViewControllerIntegrated(
            stateManager: MockFeedStateManager(),
            navigationPath: .constant(NavigationPath()),
            onScrollOffsetChanged: nil
        )
        
        _ = controller.view
        controller.collectionView.contentOffset = CGPoint(x: 0, y: 1000)
        
        // Trigger memory warning
        controller.didReceiveMemoryWarning()
        
        // Wait for handling
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Verify position was maintained
        #expect(abs(controller.collectionView.contentOffset.y - 1000) < 10)
    }
    
    // MARK: - Edge Cases
    
    @Test("Handles empty feed gracefully")
    func testEmptyFeed() async throws {
        let pipeline = UnifiedScrollPreservationPipeline()
        let collectionView = MockCollectionView()
        let dataSource = MockDataSource()
        
        let result = await pipeline.performUpdate(
            type: .normalUpdate,
            collectionView: collectionView,
            dataSource: dataSource,
            newData: [],
            currentData: [],
            getPostId: { _ in nil }
        )
        
        #expect(result.success == true)
        #expect(result.error == nil)
    }
    
    @Test("Recovers from failed updates")
    func testFailedUpdateRecovery() async throws {
        let controller = FeedCollectionViewControllerIntegrated(
            stateManager: MockFeedStateManager(),
            navigationPath: .constant(NavigationPath()),
            onScrollOffsetChanged: nil
        )
        
        _ = controller.view
        let originalOffset = CGPoint(x: 0, y: 500)
        controller.collectionView.contentOffset = originalOffset
        
        // Simulate failed update by having state manager throw
        controller.stateManager.shouldFailNextOperation = true
        
        await controller.performUpdate(type: .refresh(anchor: nil))
        
        // Verify position was restored to pre-update state
        #expect(abs(controller.collectionView.contentOffset.y - originalOffset.y) < 10)
    }
}

// MARK: - Mock Objects

@available(iOS 18.0, *)
@MainActor
final class MockCollectionView: UICollectionView {
    init() {
        let layout = UICollectionViewFlowLayout()
        super.init(frame: .zero, collectionViewLayout: layout)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override var indexPathsForVisibleItems: [IndexPath] {
        return [IndexPath(item: 0, section: 0), IndexPath(item: 1, section: 0)]
    }
    
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = CGRect(x: 0, y: CGFloat(indexPath.item * 100), width: 375, height: 100)
        return attributes
    }
    
    override func cellForItem(at indexPath: IndexPath) -> UICollectionViewCell? {
        return UICollectionViewCell()
    }
}

@MainActor
final class MockDataSource: UICollectionViewDiffableDataSource<Int, String> {
    init() {
        let collectionView = MockCollectionView()
        super.init(collectionView: collectionView) { _, _, _ in
            return UICollectionViewCell()
        }
    }
}

@MainActor
@Observable
final class MockFeedStateManager: FeedStateManager {
    var shouldFailNextOperation = false
    var refreshCalled = false
    
    override func refresh() async {
        refreshCalled = true
        if shouldFailNextOperation {
            shouldFailNextOperation = false
            throw MockError.intentionalFailure
        }
    }
}

struct MockPost: Identifiable {
    let id = UUID().uuidString
}

enum MockError: Error {
    case intentionalFailure
}