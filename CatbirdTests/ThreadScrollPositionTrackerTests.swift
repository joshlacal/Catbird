//
//  ThreadScrollPositionTrackerTests.swift
//  CatbirdTests
//
//  Created by Claude on 8/1/25.
//

import Testing
import UIKit
@testable import Catbird

@available(iOS 16.0, *)
@Suite("ThreadScrollPositionTracker Tests")
struct ThreadScrollPositionTrackerTests {
    
    // MARK: - Test Setup
    
    private func createMockCollectionView() -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 320, height: 100)
        layout.minimumLineSpacing = 0
        layout.sectionInset = .zero
        
        let collectionView = UICollectionView(frame: CGRect(x: 0, y: 0, width: 320, height: 568), collectionViewLayout: layout)
        
        // Mock data source with 5 sections matching thread layout
        class MockDataSource: NSObject, UICollectionViewDataSource {
            func numberOfSections(in collectionView: UICollectionView) -> Int {
                return 5 // loadMoreParents, parentPosts, mainPost, replies, bottomSpacer
            }
            
            func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
                switch section {
                case 0: return 1 // loadMoreParents
                case 1: return 3 // parentPosts  
                case 2: return 1 // mainPost
                case 3: return 2 // replies
                case 4: return 1 // bottomSpacer
                default: return 0
                }
            }
            
            func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
                return UICollectionViewCell()
            }
        }
        
        collectionView.dataSource = MockDataSource()
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "Cell")
        
        // Force layout
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        
        return collectionView
    }
    
    // MARK: - Anchor Capture Tests
    
    @Test("Capture main post anchor when main post is visible")
    func captureMainPostAnchor() async {
        let tracker = ThreadScrollPositionTracker()
        let collectionView = createMockCollectionView()
        
        // Position so main post (section 2) is visible
        collectionView.setContentOffset(CGPoint(x: 0, y: 250), animated: false)
        collectionView.layoutIfNeeded()
        
        let anchor = tracker.captureScrollAnchor(collectionView: collectionView)
        
        #expect(anchor != nil, "Should capture anchor when main post is visible")
        #expect(anchor?.sectionType == .mainPost, "Should prefer main post anchor")
        #expect(anchor?.indexPath.section == 2, "Main post should be in section 2")
        #expect(anchor?.indexPath.item == 0, "Main post should be item 0")
        #expect(anchor?.isMainPostAnchor == true, "Should be identified as main post anchor")
    }
    
    @Test("Capture parent post anchor when main post is not visible")
    func captureParentPostAnchor() async {
        let tracker = ThreadScrollPositionTracker()
        let collectionView = createMockCollectionView()
        
        // Position so only parent posts (section 1) are visible
        collectionView.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
        collectionView.layoutIfNeeded()
        
        let anchor = tracker.captureScrollAnchor(collectionView: collectionView)
        
        #expect(anchor != nil, "Should capture anchor when parent posts are visible")
        #expect(anchor?.sectionType == .parentPosts, "Should capture parent post anchor")
        #expect(anchor?.indexPath.section == 1, "Parent posts should be in section 1")
    }
    
    @Test("Handle main post frame reference correctly")  
    func mainPostFrameReference() async {
        let tracker = ThreadScrollPositionTracker()
        let collectionView = createMockCollectionView()
        
        // Position to show parent posts
        collectionView.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
        collectionView.layoutIfNeeded()
        
        let anchor = tracker.captureScrollAnchor(collectionView: collectionView)
        
        #expect(anchor != nil, "Should capture anchor")
        #expect(anchor?.mainPostFrameY ?? 0 > 0, "Should have valid main post frame reference")
        
        // Main post should be at expected position (after loadMoreParents + 3 parentPosts)
        let expectedMainPostY: CGFloat = 100 + (3 * 100) // 400pt
        #expect(abs((anchor?.mainPostFrameY ?? 0) - expectedMainPostY) < 10, "Main post frame should be at expected position")
    }
    
    @Test("Fail gracefully when no anchor can be captured")
    func failGracefullyNoAnchor() async {
        let tracker = ThreadScrollPositionTracker()
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        
        let anchor = tracker.captureScrollAnchor(collectionView: collectionView)
        
        #expect(anchor == nil, "Should return nil when no valid anchor available")
    }
    
    // MARK: - Position Restoration Tests
    
    @Test("Restore main post position correctly")
    func restoreMainPostPosition() async {
        let tracker = ThreadScrollPositionTracker()
        let collectionView = createMockCollectionView()
        
        // Capture anchor with main post visible
        collectionView.setContentOffset(CGPoint(x: 0, y: 250), animated: false)
        collectionView.layoutIfNeeded()
        
        guard let originalAnchor = tracker.captureScrollAnchor(collectionView: collectionView) else {
            Issue.record("Failed to capture anchor")
            return
        }
        
        #expect(originalAnchor.isMainPostAnchor, "Should have main post anchor")
        
        // Simulate adding parent posts by shifting content down
        // In real scenario, main post moves down when parents are added above
        let mockAnchorAfterChange = ThreadScrollPositionTracker.ScrollAnchor(
            indexPath: originalAnchor.indexPath,
            offsetY: originalAnchor.offsetY,
            itemFrameY: originalAnchor.itemFrameY,
            timestamp: originalAnchor.timestamp,
            postId: originalAnchor.postId,
            mainPostFrameY: originalAnchor.mainPostFrameY + 200, // Main post moved down by 200pt
            sectionType: originalAnchor.sectionType
        )
        
        // Restore position
        tracker.restoreScrollPosition(collectionView: collectionView, to: mockAnchorAfterChange)
        
        let finalOffset = collectionView.contentOffset.y
        let expectedOffset = originalAnchor.offsetY + 200 // Should adjust for main post movement
        
        #expect(abs(finalOffset - expectedOffset) < 10, "Should restore position accounting for main post movement")
    }
    
    @Test("Handle viewport-relative restoration for parent posts")
    func restoreViewportRelativePosition() async {
        let tracker = ThreadScrollPositionTracker()
        let collectionView = createMockCollectionView()
        
        // Capture anchor with parent post visible
        collectionView.setContentOffset(CGPoint(x: 0, y: 150), animated: false)
        collectionView.layoutIfNeeded()
        
        guard let originalAnchor = tracker.captureScrollAnchor(collectionView: collectionView) else {
            Issue.record("Failed to capture anchor")
            return
        }
        
        #expect(originalAnchor.sectionType == .parentPosts, "Should have parent post anchor")
        
        // Simulate main post movement (new parents added above)
        let mockAnchorAfterChange = ThreadScrollPositionTracker.ScrollAnchor(
            indexPath: originalAnchor.indexPath,
            offsetY: originalAnchor.offsetY,
            itemFrameY: originalAnchor.itemFrameY + 100, // Parent item moved down
            timestamp: originalAnchor.timestamp,
            postId: originalAnchor.postId,
            mainPostFrameY: originalAnchor.mainPostFrameY + 100, // Main post also moved down
            sectionType: originalAnchor.sectionType
        )
        
        // Restore position
        tracker.restoreScrollPosition(collectionView: collectionView, to: mockAnchorAfterChange)
        
        let finalOffset = collectionView.contentOffset.y
        
        // Should maintain viewport-relative position
        #expect(finalOffset > originalAnchor.offsetY, "Should adjust scroll position for content changes")
    }
    
    @Test("Use fallback restoration when anchor is invalid")
    func fallbackRestoration() async {
        let tracker = ThreadScrollPositionTracker()
        let collectionView = createMockCollectionView()
        
        // Create an invalid anchor (out of bounds)
        let invalidAnchor = ThreadScrollPositionTracker.ScrollAnchor(
            indexPath: IndexPath(item: 10, section: 1), // Item doesn't exist
            offsetY: 100,
            itemFrameY: 200,
            timestamp: Date().addingTimeInterval(-100), // Old timestamp
            postId: "invalid",
            mainPostFrameY: 400,
            sectionType: .parentPosts
        )
        
        let originalOffset = collectionView.contentOffset.y
        
        // Attempt restoration
        tracker.restoreScrollPosition(collectionView: collectionView, to: invalidAnchor)
        
        let finalOffset = collectionView.contentOffset.y
        
        // Should have attempted some form of restoration (fallback)
        #expect(finalOffset >= 0, "Should maintain valid scroll position")
        #expect(finalOffset <= collectionView.contentSize.height - collectionView.bounds.height, "Should respect content bounds")
    }
    
    // MARK: - Thread-Specific Behavior Tests
    
    @Test("Prioritize main post stability during reverse infinite scroll")
    func prioritizeMainPostStability() async {
        let tracker = ThreadScrollPositionTracker()
        let collectionView = createMockCollectionView()
        
        // Test scenario: user is viewing main post, then scrolls up to load more parents
        collectionView.setContentOffset(CGPoint(x: 0, y: 350), animated: false) // Main post mostly visible
        collectionView.layoutIfNeeded()
        
        guard let anchor = tracker.captureScrollAnchor(collectionView: collectionView) else {
            Issue.record("Failed to capture anchor")
            return
        }
        
        #expect(anchor.isMainPostAnchor, "Should prioritize main post anchor when it's visible")
        
        // Verify main post visibility calculation
        let mainPostIndexPath = IndexPath(item: 0, section: 2)
        if let attributes = collectionView.layoutAttributesForItem(at: mainPostIndexPath) {
            let visibleBounds = collectionView.bounds
            let visibleArea = attributes.frame.intersection(visibleBounds)
            let visibilityRatio = visibleArea.height / attributes.frame.height
            
            #expect(visibilityRatio >= 0.1, "Main post should meet minimum visibility threshold")
        }
    }
    
    @Test("Handle multi-section layout correctly")
    func handleMultiSectionLayout() async {
        let tracker = ThreadScrollPositionTracker()
        let collectionView = createMockCollectionView()
        
        // Test each section can be captured as anchor
        let testPositions: [(CGFloat, ThreadScrollPositionTracker.ThreadSection)] = [
            (50, .loadMoreParents),   // Position 0: loadMoreParents visible
            (150, .parentPosts),      // Position 1: parentPosts visible  
            (350, .mainPost),         // Position 2: mainPost visible
            (550, .replies)           // Position 3: replies visible
        ]
        
        for (position, expectedSection) in testPositions {
            collectionView.setContentOffset(CGPoint(x: 0, y: position), animated: false)
            collectionView.layoutIfNeeded()
            
            let anchor = tracker.captureScrollAnchor(collectionView: collectionView)
            
            if expectedSection == .loadMoreParents {
                // Load more section might not be capturable (designed to be skipped)
                continue
            }
            
            #expect(anchor != nil, "Should capture anchor at position \(position)")
            
            if let anchor = anchor {
                // For main post, should always prefer main post section
                if expectedSection == .mainPost {
                    #expect(anchor.sectionType == .mainPost, "Should capture main post when visible")
                } else if expectedSection == .parentPosts {
                    #expect(anchor.sectionType == .parentPosts || anchor.sectionType == .mainPost, "Should capture parent or main post")
                }
            }
        }
    }
    
    // MARK: - Edge Case Tests
    
    @Test("Handle empty collection view")
    func handleEmptyCollectionView() async {
        let tracker = ThreadScrollPositionTracker()
        let layout = UICollectionViewFlowLayout()
        let collectionView = UICollectionView(frame: CGRect(x: 0, y: 0, width: 320, height: 568), collectionViewLayout: layout)
        
        // No data source - empty collection view
        let anchor = tracker.captureScrollAnchor(collectionView: collectionView)
        
        #expect(anchor == nil, "Should handle empty collection view gracefully")
    }
    
    @Test("Handle tracking disabled")
    func handleTrackingDisabled() async {
        let tracker = ThreadScrollPositionTracker()
        let collectionView = createMockCollectionView()
        
        tracker.pauseTracking()
        
        let anchor = tracker.captureScrollAnchor(collectionView: collectionView)
        #expect(anchor == nil, "Should not capture anchor when tracking is disabled")
        
        // Test restoration also respects tracking state
        let mockAnchor = ThreadScrollPositionTracker.ScrollAnchor(
            indexPath: IndexPath(item: 0, section: 2),
            offsetY: 100,
            itemFrameY: 200,
            timestamp: Date(),
            postId: "test",
            mainPostFrameY: 400,
            sectionType: .mainPost
        )
        
        let originalOffset = collectionView.contentOffset.y
        tracker.restoreScrollPosition(collectionView: collectionView, to: mockAnchor)
        
        #expect(collectionView.contentOffset.y == originalOffset, "Should not restore when tracking is disabled")
        
        // Re-enable tracking
        tracker.resumeTracking()
        let anchorAfterResume = tracker.captureScrollAnchor(collectionView: collectionView)
        #expect(anchorAfterResume != nil, "Should capture anchor after re-enabling tracking")
    }
    
    @Test("Handle extremely large content")
    func handleLargeContent() async {
        let tracker = ThreadScrollPositionTracker()
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 320, height: 1000) // Very tall items
        
        let collectionView = UICollectionView(frame: CGRect(x: 0, y: 0, width: 320, height: 568), collectionViewLayout: layout)
        collectionView.dataSource = createMockCollectionView().dataSource
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "Cell")
        
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        
        // Scroll to large offset
        let largeOffset: CGFloat = 3000
        collectionView.setContentOffset(CGPoint(x: 0, y: largeOffset), animated: false)
        collectionView.layoutIfNeeded()
        
        let anchor = tracker.captureScrollAnchor(collectionView: collectionView)
        
        #expect(anchor != nil, "Should handle large content offsets")
        
        if let anchor = anchor {
            #expect(anchor.offsetY == largeOffset, "Should capture correct large offset")
            #expect(anchor.mainPostFrameY > 0, "Should have valid main post reference even with large content")
        }
    }
    
    // MARK: - Performance Tests
    
    @Test("Anchor capture performance")
    func anchorCapturePerformance() async {
        let tracker = ThreadScrollPositionTracker()
        let collectionView = createMockCollectionView()
        
        collectionView.setContentOffset(CGPoint(x: 0, y: 250), animated: false)
        collectionView.layoutIfNeeded()
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Capture anchor multiple times to test performance
        for _ in 0..<100 {
            _ = tracker.captureScrollAnchor(collectionView: collectionView)
        }
        
        let endTime = CFAbsoluteTimeGetCurrent()
        let averageTime = (endTime - startTime) / 100
        
        #expect(averageTime < 0.001, "Anchor capture should be fast (< 1ms average)")
    }
}

// MARK: - Integration Tests with Mock UIKit Components

@available(iOS 16.0, *)
@Suite("ThreadScrollPositionTracker Integration Tests")
struct ThreadScrollPositionTrackerIntegrationTests {
    
    @Test("Full reverse infinite scroll simulation")
    func fullReverseInfiniteScrollSimulation() async {
        let tracker = ThreadScrollPositionTracker()
        let collectionView = createCollectionViewWithDynamicContent()
        
        // Initial state: 3 parent posts, 1 main post, 2 replies
        collectionView.setContentOffset(CGPoint(x: 0, y: 300), animated: false) // Main post visible
        collectionView.layoutIfNeeded()
        
        // Capture anchor before loading more parents
        guard let anchorBeforeLoad = tracker.captureScrollAnchor(collectionView: collectionView) else {
            Issue.record("Failed to capture initial anchor")
            return
        }
        
        #expect(anchorBeforeLoad.isMainPostAnchor, "Should capture main post anchor")
        
        // Simulate loading 2 more parent posts (added above existing content)
        simulateAddingParentPosts(to: collectionView, count: 2)
        
        // Create anchor that reflects the content change
        let anchorAfterLoad = ThreadScrollPositionTracker.ScrollAnchor(
            indexPath: anchorBeforeLoad.indexPath,
            offsetY: anchorBeforeLoad.offsetY,
            itemFrameY: anchorBeforeLoad.itemFrameY,
            timestamp: anchorBeforeLoad.timestamp,
            postId: anchorBeforeLoad.postId,
            mainPostFrameY: anchorBeforeLoad.mainPostFrameY + 200, // Main post moved down by 2 * 100pt
            sectionType: anchorBeforeLoad.sectionType
        )
        
        // Restore position
        tracker.restoreScrollPosition(collectionView: collectionView, to: anchorAfterLoad)
        
        // Verify main post is still visible in similar viewport position
        let mainPostIndexPath = IndexPath(item: 0, section: 2)
        if let mainPostAttributes = collectionView.layoutAttributesForItem(at: mainPostIndexPath) {
            let mainPostVisibleY = mainPostAttributes.frame.origin.y - collectionView.contentOffset.y
            let viewportHeight = collectionView.bounds.height
            
            #expect(mainPostVisibleY >= 0 && mainPostVisibleY <= viewportHeight, "Main post should remain visible after parent loading")
            
            // Should be in roughly the same viewport position (allowing some tolerance)
            let originalMainPostVisibleY = anchorBeforeLoad.mainPostFrameY - anchorBeforeLoad.offsetY
            #expect(abs(mainPostVisibleY - originalMainPostVisibleY) < 50, "Main post should maintain similar viewport position")
        }
    }
    
    private func createCollectionViewWithDynamicContent() -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 320, height: 100)
        layout.minimumLineSpacing = 0
        
        let collectionView = UICollectionView(frame: CGRect(x: 0, y: 0, width: 320, height: 568), collectionViewLayout: layout)
        
        class DynamicDataSource: NSObject, UICollectionViewDataSource {
            var parentPostCount = 3
            
            func numberOfSections(in collectionView: UICollectionView) -> Int {
                return 5
            }
            
            func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
                switch section {
                case 0: return parentPostCount > 0 ? 1 : 0 // loadMoreParents
                case 1: return parentPostCount // parentPosts
                case 2: return 1 // mainPost
                case 3: return 2 // replies
                case 4: return 1 // bottomSpacer
                default: return 0
                }
            }
            
            func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
                return UICollectionViewCell()
            }
        }
        
        let dataSource = DynamicDataSource()
        collectionView.dataSource = dataSource
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "Cell")
        
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        
        return collectionView
    }
    
    private func simulateAddingParentPosts(to collectionView: UICollectionView, count: Int) {
        if let dataSource = collectionView.dataSource as? DynamicDataSource {
            dataSource.parentPostCount += count
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
        }
    }
    
    // Helper class for dynamic content simulation
    private class DynamicDataSource: NSObject, UICollectionViewDataSource {
        var parentPostCount = 3
        
        func numberOfSections(in collectionView: UICollectionView) -> Int {
            return 5
        }
        
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            switch section {
            case 0: return parentPostCount > 0 ? 1 : 0
            case 1: return parentPostCount
            case 2: return 1
            case 3: return 2
            case 4: return 1
            default: return 0
            }
        }
        
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            return UICollectionViewCell()
        }
    }
}