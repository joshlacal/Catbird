//
//  UnifiedScrollPreservationPipeline.swift
//  Catbird
//
//  Created by Claude on unified scroll position preservation
//
//  A unified pipeline that handles all scroll position preservation scenarios
//  consistently across different update paths (refresh, load more, memory warning, etc.)
//

import UIKit
import os

// Import required supporting types
import Foundation

@available(iOS 16.0, *)
final class UnifiedScrollPreservationPipeline {
    
    // MARK: - Types
    
    /// The type of update being performed
    enum UpdateType {
        case refresh(anchor: ScrollAnchor?)
        case loadMore
        case newPostsAtTop
        case memoryWarning
        case feedSwitch
        case normalUpdate
        case viewAppearance(persistedState: PersistedScrollState?)
        
        var preservationStrategy: PreservationStrategy {
            switch self {
            case .refresh(let anchor):
                return anchor != nil ? .viewportRelative : .maintainOffset
            case .loadMore:
                return .exactPosition
            case .newPostsAtTop:
                return .viewportRelative
            case .memoryWarning:
                return .maintainOffset
            case .feedSwitch:
                return .maintainOffset
            case .normalUpdate:
                return .exactPosition
            case .viewAppearance:
                return .restoreFromPersisted
            }
        }
        
        var requiresAnimation: Bool {
            switch self {
            case .feedSwitch, .viewAppearance:
                return false
            default:
                return false // No animations during position preservation
            }
        }
    }
    
    /// Strategy for preserving scroll position
    enum PreservationStrategy {
        case viewportRelative    // Maintain relative position of content in viewport
        case exactPosition       // Keep exact content offset
        case maintainOffset      // Try to maintain current offset, clamp if needed
        case restoreFromPersisted // Restore from saved state
    }
    
    /// Unified scroll anchor that works across all scenarios
    struct ScrollAnchor {
        let indexPath: IndexPath
        let postId: String?
        let contentOffset: CGPoint
        let viewportRelativeY: CGFloat  // Position relative to viewport top
        let itemFrameY: CGFloat         // Item's frame.origin.y in content coordinates
        let timestamp: Date
        
        init(from collectionView: UICollectionView) {
            guard let firstVisible = collectionView.indexPathsForVisibleItems.sorted().first,
                  let _ = collectionView.cellForItem(at: firstVisible),
                  let attributes = collectionView.layoutAttributesForItem(at: firstVisible) else {
                // Fallback anchor at current position
                self.indexPath = IndexPath(item: 0, section: 0)
                self.postId = nil
                self.contentOffset = collectionView.contentOffset
                self.viewportRelativeY = 0
                self.itemFrameY = 0
                self.timestamp = Date()
                return
            }
            
            self.indexPath = firstVisible
            self.contentOffset = collectionView.contentOffset
            
            // Calculate safe-area-relative position (consistent with persistence)
            let cellFrame = attributes.frame
            let safeAreaTop = collectionView.adjustedContentInset.top
            let currentOffset = collectionView.contentOffset.y
            
            self.itemFrameY = cellFrame.origin.y
            self.viewportRelativeY = cellFrame.origin.y - (currentOffset + safeAreaTop)
            
            self.timestamp = Date()
            self.postId = nil // Will be set by caller if needed
        }
        
        /// Create a new anchor with a specific post ID
        init(
            indexPath: IndexPath,
            postId: String?,
            contentOffset: CGPoint,
            viewportRelativeY: CGFloat,
            itemFrameY: CGFloat,
            timestamp: Date = Date()
        ) {
            self.indexPath = indexPath
            self.postId = postId
            self.contentOffset = contentOffset
            self.viewportRelativeY = viewportRelativeY
            self.itemFrameY = itemFrameY
            self.timestamp = timestamp
        }
    }
    
    /// Result of an update operation
    struct UpdateResult {
        let success: Bool
        let finalOffset: CGPoint
        let restorationAttempts: Int
        let error: Error?
    }
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "blue.catbird", category: "UnifiedScrollPipeline")
    
    // iOS 18 enhancements (optional dependencies)
    private weak var abTestingFramework: AnyObject?
    private var isProMotionDisplay: Bool {
        return UIScreen.main.maximumFramesPerSecond > 60
    }
    
    // MARK: - Enhanced Initialization
    
    init(abTestingFramework: AnyObject? = nil) {
        self.abTestingFramework = abTestingFramework
    }
    
    // MARK: - Public Methods
    
    /// Performs a unified update with appropriate scroll preservation
    @MainActor
    func performUpdate(
        type: UpdateType,
        collectionView: UICollectionView,
        dataSource: UICollectionViewDiffableDataSource<Int, String>,
        newData: [String], // Post IDs
        currentData: [String],
        getPostId: @escaping (IndexPath) -> String?
    ) async -> UpdateResult {
        
        logger.debug("🔄 UNIFIED: Starting update - type=\(String(describing: type)), strategy=\(String(describing: type.preservationStrategy))")
        
        // Step 1: Capture pre-update state
        let anchor = captureAnchor(
            type: type,
            collectionView: collectionView,
            currentData: currentData,
            getPostId: getPostId
        )
        
        // Step 2: Apply the data update
        await applyDataUpdate(
            collectionView: collectionView,
            dataSource: dataSource,
            newData: newData,
            animated: type.requiresAnimation
        )
        
        // Step 3: Wait for layout completion properly
        await waitForLayoutCompletion(collectionView: collectionView)
        
        // Step 4: Restore scroll position based on strategy
        let result = await restoreScrollPosition(
            type: type,
            anchor: anchor,
            collectionView: collectionView,
            newData: newData,
            getPostId: getPostId
        )
        
        logger.debug("✅ UNIFIED: Update complete - success=\(result.success), finalOffset=\(result.finalOffset.x),\(result.finalOffset.y)")
        
        return result
    }
    
    // MARK: - Private Methods
    
    private func captureAnchor(
        type: UpdateType,
        collectionView: UICollectionView,
        currentData: [String],
        getPostId: @escaping (IndexPath) -> String?
    ) -> ScrollAnchor? {
        
        // Special handling for different update types
        switch type {
        case .refresh(let existingAnchor):
            // Use pre-captured anchor from pull gesture if available
            if let anchor = existingAnchor {
                logger.debug("📍 Using pre-captured refresh anchor")
                return anchor
            }
        case .viewAppearance:
            // No anchor needed for persisted state restoration
            return nil
        case .memoryWarning:
            // Always capture current anchor before memory cleanup
            break
        default:
            break
        }
        
        // Capture current anchor
        let baseAnchor = ScrollAnchor(from: collectionView)
        
        // Create a new anchor with post ID if available
        let anchor: ScrollAnchor
        if baseAnchor.indexPath.item < currentData.count {
            let postId = getPostId(baseAnchor.indexPath)
            anchor = ScrollAnchor(
                indexPath: baseAnchor.indexPath,
                postId: postId,
                contentOffset: baseAnchor.contentOffset,
                viewportRelativeY: baseAnchor.viewportRelativeY,
                itemFrameY: baseAnchor.itemFrameY,
                timestamp: baseAnchor.timestamp
            )
        } else {
            anchor = baseAnchor
        }
        
        logger.debug("📍 Captured anchor - index=\(anchor.indexPath.item), postId=\(anchor.postId ?? "nil"), viewportY=\(anchor.viewportRelativeY)")
        
        return anchor
    }
    
    private func applyDataUpdate(
        collectionView: UICollectionView,
        dataSource: UICollectionViewDiffableDataSource<Int, String>,
        newData: [String],
        animated: Bool
    ) async {
        
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(newData, toSection: 0)
        
        // Apply with proper timing
        await MainActor.run { [snapshot] in
            CATransaction.begin()
            CATransaction.setDisableActions(!animated)
            
            dataSource.apply(snapshot, animatingDifferences: animated)
            
            CATransaction.commit()
        }
    }
    
    @MainActor
    private func waitForLayoutCompletion(collectionView: UICollectionView) async {
        // Use CATransaction completion block instead of sleep
        await withCheckedContinuation { continuation in
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                continuation.resume()
            }
            
            collectionView.layoutIfNeeded()
            
            CATransaction.commit()
        }
    }
    
    private func restoreScrollPosition(
        type: UpdateType,
        anchor: ScrollAnchor?,
        collectionView: UICollectionView,
        newData: [String],
        getPostId: @escaping (IndexPath) -> String?
    ) async -> UpdateResult {
        
        let strategy = type.preservationStrategy
        
        switch strategy {
        case .viewportRelative:
            return await restoreViewportRelative(
                anchor: anchor,
                collectionView: collectionView,
                newData: newData
            )
            
        case .exactPosition:
            return restoreExactPosition(
                anchor: anchor,
                collectionView: collectionView
            )
            
        case .maintainOffset:
            return maintainCurrentOffset(
                collectionView: collectionView
            )
            
        case .restoreFromPersisted:
            if case .viewAppearance(let state) = type {
                return await restoreFromPersistedState(
                    state: state,
                    collectionView: collectionView,
                    newData: newData
                )
            }
            return UpdateResult(
                success: false,
                finalOffset: collectionView.contentOffset,
                restorationAttempts: 0,
                error: nil
            )
        }
    }
    
    private func restoreViewportRelative(
        anchor: ScrollAnchor?,
        collectionView: UICollectionView,
        newData: [String]
    ) async -> UpdateResult {
        
        guard let anchor = anchor else {
            return UpdateResult(
                success: false,
                finalOffset: collectionView.contentOffset,
                restorationAttempts: 0,
                error: nil
            )
        }
        
        // Find the anchor item in new data
        let newIndex: Int
        if let postId = anchor.postId,
           let index = newData.firstIndex(of: postId) {
            newIndex = index
            logger.debug("🎯 Found anchor post by ID: \(postId) at new index \(index) (was \(anchor.indexPath.item))")
        } else if anchor.indexPath.item < newData.count {
            // Fallback to position-based (this can cause the wrong post issue)
            newIndex = anchor.indexPath.item
            logger.warning("⚠️ Fallback to position-based anchor: index \(anchor.indexPath.item) (postId was nil)")
        } else {
            // Anchor lost, maintain approximate position
            logger.warning("⚠️ Anchor lost completely, maintaining current offset")
            return maintainCurrentOffset(collectionView: collectionView)
        }
        
        let newIndexPath = IndexPath(item: newIndex, section: 0)
        
        // Get the new position of the anchor item
        guard let newAttributes = collectionView.layoutAttributesForItem(at: newIndexPath) else {
            return UpdateResult(
                success: false,
                finalOffset: collectionView.contentOffset,
                restorationAttempts: 1,
                error: nil
            )
        }
        
        // Calculate target offset to maintain safe-area-relative position
        let newAnchorY = newAttributes.frame.origin.y
        let safeAreaTop = collectionView.adjustedContentInset.top
        let targetOffsetY = newAnchorY - safeAreaTop - anchor.viewportRelativeY
        
        // Apply with pixel-perfect precision
        let displayScale = UIScreen.main.scale
        let pixelPerfectOffset = round(targetOffsetY * displayScale) / displayScale
        
        // Apply bounds checking
        let safeOffset = clampOffset(
            pixelPerfectOffset,
            collectionView: collectionView
        )
        
        // Apply the offset
        applyOffset(CGPoint(x: 0, y: safeOffset), to: collectionView)
        
        return UpdateResult(
            success: true,
            finalOffset: CGPoint(x: 0, y: safeOffset),
            restorationAttempts: 1,
            error: nil
        )
    }
    
    private func restoreExactPosition(
        anchor: ScrollAnchor?,
        collectionView: UICollectionView
    ) -> UpdateResult {
        
        guard let anchor = anchor else {
            return UpdateResult(
                success: false,
                finalOffset: collectionView.contentOffset,
                restorationAttempts: 0,
                error: nil
            )
        }
        
        // For exact position, just restore the content offset
        let safeOffset = clampOffset(anchor.contentOffset.y, collectionView: collectionView)
        applyOffset(CGPoint(x: 0, y: safeOffset), to: collectionView)
        
        return UpdateResult(
            success: true,
            finalOffset: CGPoint(x: 0, y: safeOffset),
            restorationAttempts: 1,
            error: nil
        )
    }
    
    private func maintainCurrentOffset(
        collectionView: UICollectionView
    ) -> UpdateResult {
        
        let currentOffset = collectionView.contentOffset.y
        let safeOffset = clampOffset(currentOffset, collectionView: collectionView)
        
        if abs(currentOffset - safeOffset) > 1 {
            applyOffset(CGPoint(x: 0, y: safeOffset), to: collectionView)
        }
        
        return UpdateResult(
            success: true,
            finalOffset: CGPoint(x: 0, y: safeOffset),
            restorationAttempts: 0,
            error: nil
        )
    }
    
    @MainActor
    private func restoreFromPersistedState(
        state: PersistedScrollState?,
        collectionView: UICollectionView,
        newData: [String]
    ) async -> UpdateResult {
        
        guard let state = state else {
            return UpdateResult(
                success: false,
                finalOffset: collectionView.contentOffset,
                restorationAttempts: 0,
                error: nil
            )
        }
        
        guard let index = newData.firstIndex(of: state.postID) else {
            logger.warning("⚠️ Could not find persisted post \(state.postID) - using approximate restoration")
            // Fallback to approximate position using saved content offset
            let safeOffset = clampOffset(state.contentOffset, collectionView: collectionView)
            applyOffset(CGPoint(x: 0, y: safeOffset), to: collectionView)
            
            return UpdateResult(
                success: true, // Mark as success since we did restore something reasonable
                finalOffset: CGPoint(x: 0, y: safeOffset),
                restorationAttempts: 1,
                error: nil
            )
        }
        
        let indexPath = IndexPath(item: index, section: 0)
        
        // Wait for layout if needed
        await waitForLayoutCompletion(collectionView: collectionView)
        
        guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else {
            return UpdateResult(
                success: false,
                finalOffset: collectionView.contentOffset,
                restorationAttempts: 1,
                error: nil
            )
        }
        
        // Calculate target offset relative to safe area (matching the capture logic)
        let safeAreaTop = collectionView.adjustedContentInset.top
        let targetOffset = attributes.frame.origin.y - safeAreaTop - state.offsetFromTop
        let safeOffset = clampOffset(targetOffset, collectionView: collectionView)
        
        applyOffset(CGPoint(x: 0, y: safeOffset), to: collectionView)
        
        return UpdateResult(
            success: true,
            finalOffset: CGPoint(x: 0, y: safeOffset),
            restorationAttempts: 1,
            error: nil
        )
    }
    
    private func clampOffset(_ offsetY: CGFloat, collectionView: UICollectionView) -> CGFloat {
        let contentInset = collectionView.adjustedContentInset
        let minOffset = -contentInset.top
        let maxOffset = max(minOffset, collectionView.contentSize.height - collectionView.bounds.height + contentInset.bottom)
        
        return max(minOffset, min(offsetY, maxOffset))
    }
    
    private func applyOffset(_ offset: CGPoint, to collectionView: UICollectionView) {
        // Apply multiple times if needed to overcome refresh control interference
        collectionView.setContentOffset(offset, animated: false)
        
        // Verify and reapply if needed
        DispatchQueue.main.async {
            if abs(collectionView.contentOffset.y - offset.y) > 1 {
                collectionView.setContentOffset(offset, animated: false)
            }
        }
    }
}

// MARK: - Persisted State

struct PersistedScrollState: Codable {
    let postID: String
    let offsetFromTop: CGFloat
    let contentOffset: CGFloat
}

// MARK: - UIUpdateLink Integration (iOS 18+)

@available(iOS 18.0, *)
extension UnifiedScrollPreservationPipeline {
    
    /// Enhanced UIUpdateLink frame-synchronized scroll restoration with iOS 18 optimizations
    @MainActor
    func performFrameSynchronizedRestore(
        targetOffset: CGPoint,
        collectionView: UICollectionView,
        scrollVelocity: CGFloat = 0,
        batteryLevel: Float = 1.0
    ) async -> Bool {
        
        logger.debug("🔗 Starting frame-synchronized restore with UIUpdateLink")
        
        // Use basic ProMotion-aware frame rate without external dependencies
        let optimalFrameRate = isProMotionDisplay ? 
            CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120) :
            CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        
        return await withCheckedContinuation { continuation in
            var frameCount = 0
            let maxFrames = 10 // Prevent infinite loops
            let displayScale = UIScreen.main.scale
            
            let updateLink = UIUpdateLink(view: collectionView) { [weak self] link, updateInfo in
                frameCount += 1
                
                // Check for immediate presentation opportunity
                if updateInfo.isImmediatePresentationExpected {
                    
                    // Apply pixel-perfect offset with enhanced precision
                    let pixelPerfectOffset = CGPoint(
                        x: round(targetOffset.x * displayScale) / displayScale,
                        y: round(targetOffset.y * displayScale) / displayScale
                    )
                    
                    // Track performance metrics (simplified)
                    let latency = updateInfo.modelTime - updateInfo.estimatedPresentationTime
                    self?.logger.debug("📊 Frame sync latency: \(latency * 1000)ms")
                    
                    // Perform the scroll update with frame synchronization
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    collectionView.setContentOffset(pixelPerfectOffset, animated: false)
                    
                    // Force layout if we have time before deadline
                    let timeToDeadline = updateInfo.completionDeadlineTime - updateInfo.modelTime
                    if timeToDeadline > 0.002 { // 2ms safety margin
                        collectionView.layoutIfNeeded()
                    }
                    
                    CATransaction.commit()
                    
                    // Verify precision
                    let actualOffset = collectionView.contentOffset
                    let error = abs(actualOffset.y - pixelPerfectOffset.y)
                    
                    if error < 0.5 / displayScale {
                        self?.logger.debug("✅ Frame-synchronized restore successful, error: \(error)px")
                        link.isEnabled = false
                        continuation.resume(returning: true)
                        return
                    }
                }
                
                // Check for timeout or max frames
                if frameCount >= maxFrames {
                    self?.logger.warning("⏱️ Frame-synchronized restore timed out after \(frameCount) frames")
                    link.isEnabled = false
                    continuation.resume(returning: false)
                }
            }
            
            // Configure UIUpdateLink with optimal settings
            updateLink.requiresContinuousUpdates = false
            updateLink.wantsImmediatePresentation = true
            updateLink.wantsLowLatencyEventDispatch = true
            updateLink.preferredFrameRateRange = optimalFrameRate
            updateLink.isEnabled = true
            
            // Enhanced timeout
            let timeoutDuration: TimeInterval = 0.1
            
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutDuration) {
                if updateLink.isEnabled {
                    self.logger.warning("⏰ UIUpdateLink timed out after \(timeoutDuration)s")
                    updateLink.isEnabled = false
                    continuation.resume(returning: false)
                }
            }
        }
    }
    
    /// Enhanced scroll restoration with comprehensive iOS 18 optimizations
    @MainActor
    func performEnhancedScrollRestoration(
        targetOffset: CGPoint,
        collectionView: UICollectionView,
        context: ScrollRestorationContext
    ) async -> ScrollRestorationResult {
        
        logger.info("🚀 Performing enhanced scroll restoration")
        
        let startTime = CACurrentMediaTime()
        
        // Simplified restoration strategy
        let useFrameSync = isProMotionDisplay
        
        var success = false
        var pixelError: Double = 0
        var frameRate: Double = 60
        
        if useFrameSync {
            // Use enhanced frame-synchronized restoration
            success = await performFrameSynchronizedRestore(
                targetOffset: targetOffset,
                collectionView: collectionView,
                scrollVelocity: context.scrollVelocity,
                batteryLevel: context.batteryLevel
            )
            
            frameRate = 120
            
        } else {
            // Fallback to standard restoration
            collectionView.setContentOffset(targetOffset, animated: false)
            success = true
            frameRate = 60
        }
        
        // Calculate pixel error
        let actualOffset = collectionView.contentOffset
        pixelError = abs(actualOffset.y - targetOffset.y)
        
        let duration = CACurrentMediaTime() - startTime
        
        // Track performance metrics
        logger.info("📊 Restoration complete: success=\(success), error=\(pixelError)px, duration=\(duration * 1000)ms")
        
        return ScrollRestorationResult(
            success: success,
            pixelError: pixelError,
            duration: duration,
            frameRate: frameRate,
            strategy: useFrameSync ? "frame_synchronized" : "standard"
        )
    }
}

// MARK: - Enhanced Supporting Types

struct ScrollRestorationContext {
    let scrollVelocity: CGFloat
    let batteryLevel: Float
    let thermalState: ProcessInfo.ThermalState
    let isProMotionDisplay: Bool
    let memoryPressure: Bool
    
    init() {
        self.scrollVelocity = 0
        self.batteryLevel = UIDevice.current.batteryLevel
        self.thermalState = ProcessInfo.processInfo.thermalState
        self.isProMotionDisplay = UIScreen.main.maximumFramesPerSecond > 60
        self.memoryPressure = false // Simplified
    }
}

struct ScrollRestorationResult {
    let success: Bool
    let pixelError: Double
    let duration: TimeInterval
    let frameRate: Double
    let strategy: String
    
    var isHighQuality: Bool {
        return success && pixelError < 1.0 && duration < 0.05
    }
}