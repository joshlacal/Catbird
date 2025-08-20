//
//  OptimizedScrollPreservationSystem.swift
//  Catbird
//
//  Optimized scroll preservation using iOS 18 UIUpdateLink for pixel-perfect, frame-synchronized updates
//

#if os(iOS)
import UIKit
import os

@available(iOS 18.0, *)
@MainActor
final class OptimizedScrollPreservationSystem {
    
    // MARK: - Types
    
    /// Precise scroll anchor with sub-pixel accuracy
    struct PreciseScrollAnchor {
        let indexPath: IndexPath
        let postId: String
        let contentOffset: CGPoint
        let viewportRelativeY: CGFloat
        let itemFrameY: CGFloat
        let itemHeight: CGFloat
        let visibleHeightInViewport: CGFloat
        let timestamp: TimeInterval
        let displayScale: CGFloat
        
        /// Pixel-aligned values
        var pixelAlignedOffset: CGPoint {
            CGPoint(
                x: round(contentOffset.x * displayScale) / displayScale,
                y: round(contentOffset.y * displayScale) / displayScale
            )
        }
        
        var pixelAlignedViewportY: CGFloat {
            round(viewportRelativeY * displayScale) / displayScale
        }
    }
    
    /// Gap detection result for feed loading
    struct GapDetectionResult {
        let hasGap: Bool
        let gapSize: Int  // Number of missing posts
        let anchorPostId: String
        let newestVisiblePostId: String
        let expectedNextCursor: String?
    }
    
    /// Frame-synchronized update context
    struct UpdateContext {
        let updateLink: UIUpdateLink
        let updateInfo: UIUpdateInfo? // Optional since UIUpdateInfo is provided by callback
        let targetOffset: CGPoint
        let startTime: TimeInterval
        let maxDuration: TimeInterval
        let completionHandler: ((Bool) -> Void)?
    }
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "blue.catbird", category: "OptimizedScrollPreservation")
    private var activeUpdateLink: UIUpdateLink?
    private var activeUpdateContext: UpdateContext?
    private let displayScale = PlatformScreenInfo.scale
    private let frameRateManager = AdaptiveFrameRateManager()
    private let telemetryActor = ScrollPerformanceTelemetryActor()
    
    // A/B Testing integration for scroll preservation strategies
    private weak var abTestingFramework: ABTestingFramework?
    
    // ProMotion display detection
    private let isProMotionDisplay: Bool
    
    // MARK: - Initialization
    
    init(abTestingFramework: ABTestingFramework? = nil) {
        self.abTestingFramework = abTestingFramework
        
        // Detect ProMotion display capability
        self.isProMotionDisplay = PlatformScreenInfo.isProMotionDisplay
        
        logger.info("📱 Initialized with ProMotion: \(self.isProMotionDisplay), max FPS: \(PlatformScreenInfo.maximumFramesPerSecond)")
    }
    
    // MARK: - UIUpdateLink Management
    
    /// Creates an optimized UIUpdateLink for scroll position updates
    func createOptimizedUpdateLink(
        for collectionView: UICollectionView,
        targetOffset: CGPoint,
        completion: @escaping (Bool) -> Void
    ) {
        // Clean up any existing link
        activeUpdateLink?.isEnabled = false
        activeUpdateLink = nil
        
        // Create new update link with optimal configuration
        let updateLink = UIUpdateLink(view: collectionView) { [weak self, weak collectionView] link, updateInfo in
            guard let self = self,
                  let collectionView = collectionView else {
                link.isEnabled = false
                completion(false)
                return
            }
            
            Task {
                await self.handleUpdateLinkFrame(
                    link: link,
                    info: updateInfo,
                    collectionView: collectionView,
                    targetOffset: targetOffset,
                    completion: completion
                )
            }
        }
        
        // Configure for optimal scroll restoration with adaptive frame rates
        updateLink.requiresContinuousUpdates = false
        updateLink.wantsLowLatencyEventDispatch = true
        updateLink.wantsImmediatePresentation = true
        
        // iOS 18: Adaptive frame rate based on display capabilities and scroll context
        let adaptiveFrameRate = frameRateManager.getOptimalFrameRate(
            for: .scrollRestoration,
            isProMotionDisplay: isProMotionDisplay,
            batteryLevel: PlatformDeviceInfo.batteryLevel
        )
        updateLink.preferredFrameRateRange = adaptiveFrameRate
        
        // Track A/B test variant for scroll preservation strategy
        let scrollStrategy = abTestingFramework?.getVariant(for: "scroll_position_preservation_v2") ?? .control
        logger.debug("🧪 Using scroll preservation strategy: \(scrollStrategy.rawValue)")
        
        // Store context - UIUpdateInfo will be provided by the update link callback
        activeUpdateContext = UpdateContext(
            updateLink: updateLink,
            updateInfo: nil, // Will be set in the callback
            targetOffset: targetOffset,
            startTime: CACurrentMediaTime(),
            maxDuration: 0.5, // 500ms max
            completionHandler: completion
        )
        
        // Enable the link
        updateLink.isEnabled = true
        activeUpdateLink = updateLink
        
        logger.debug("🎯 Created optimized UIUpdateLink for offset: \(targetOffset.x),\(targetOffset.y)")
    }
    
    /// Handles a frame update from UIUpdateLink
    private func handleUpdateLinkFrame(
        link: UIUpdateLink,
        info: UIUpdateInfo,
        collectionView: UICollectionView,
        targetOffset: CGPoint,
        completion: @escaping (Bool) -> Void
    ) async {
        let currentTime = CACurrentMediaTime()
        let context = activeUpdateContext
        
        // Check timeout
        if let context = context,
           currentTime - context.startTime > context.maxDuration {
            logger.warning("⏱️ UIUpdateLink timed out after \(context.maxDuration)s")
            link.isEnabled = false
            completion(false)
            return
        }
        
        // Check for immediate presentation opportunity
        if info.isImmediatePresentationExpected {
            logger.debug("✨ Immediate presentation available at \(info.estimatedPresentationTime)")
            
            // Start performance measurement for A/B testing
            let performanceMeasurement = abTestingFramework?.startPerformanceMeasurement(for: "scroll_position_preservation_v2")
            
            // Apply pixel-perfect offset with sub-pixel accuracy
            let pixelPerfectOffset = CGPoint(
                x: round(targetOffset.x * displayScale) / displayScale,
                y: round(targetOffset.y * displayScale) / displayScale
            )
            
            // Perform the scroll update with frame synchronization
            let success = await performFrameSynchronizedScroll(
                collectionView: collectionView,
                targetOffset: pixelPerfectOffset,
                updateInfo: info
            )
            
            if success {
                // Verify the scroll was applied with enhanced precision
                let actualOffset = collectionView.contentOffset
                let error = abs(actualOffset.y - pixelPerfectOffset.y)
                let pixelThreshold = 0.25 / displayScale // Quarter pixel accuracy
                
                if error < pixelThreshold {
                    logger.debug("✅ Sub-pixel perfect scroll achieved with error: \(error)")
                    performanceMeasurement?.complete(operation: "pixel_perfect_scroll_restoration")
                    
                    // Track success metrics
                    await telemetryActor.recordScrollRestoration(
                        success: true,
                        error: error,
                        frameRate: Double(PlatformScreenInfo.maximumFramesPerSecond),
                        duration: currentTime - (context?.startTime ?? currentTime)
                    )
                    
                    link.isEnabled = false
                    completion(true)
                    return
                } else {
                    logger.debug("⚠️ Scroll applied but not sub-pixel perfect, error: \(error), retrying...")
                }
            }
        }
        
        // Check if we're in low-latency phase
        if info.isPerformingLowLatencyPhases {
            logger.debug("⚡ Low-latency phase active")
            // Prepare for next frame but don't apply yet
        }
    }
    
    /// Performs frame-synchronized scroll with sub-pixel precision and ProMotion optimization
    private func performFrameSynchronizedScroll(
        collectionView: UICollectionView,
        targetOffset: CGPoint,
        updateInfo: UIUpdateInfo
    ) async -> Bool {
        // Calculate timing for optimal presentation with iOS 18 precision
        let completionDeadline = updateInfo.completionDeadlineTime
        let presentationTime = updateInfo.estimatedPresentationTime
        let currentTime = updateInfo.modelTime
        
        // We have a window to complete the update
        let timeRemaining = completionDeadline - currentTime
        
        guard timeRemaining > 0 else {
            logger.warning("⏰ Not enough time for update, deadline passed")
            return false
        }
        
        // Enhanced frame synchronization for ProMotion displays
        return await withCheckedContinuation { continuation in
            // Use CADisplayLink for frame-perfect timing on ProMotion displays
            if isProMotionDisplay {
                performProMotionOptimizedScroll(
                    collectionView: collectionView,
                    targetOffset: targetOffset,
                    presentationTime: presentationTime
                ) { success in
                    continuation.resume(returning: success)
                }
            } else {
                // Standard 60Hz optimization
                performStandardFrameScroll(
                    collectionView: collectionView,
                    targetOffset: targetOffset,
                    updateInfo: updateInfo
                )
                continuation.resume(returning: true)
            }
        }
    }
    
    /// ProMotion-optimized scroll for 120Hz displays
    private func performProMotionOptimizedScroll(
        collectionView: UICollectionView,
        targetOffset: CGPoint,
        presentationTime: TimeInterval,
        completion: @escaping (Bool) -> Void
    ) {
        // Create high-precision display link for 120Hz timing
        let displayLink = CADisplayLink(target: self, selector: #selector(proMotionScrollFrame(_:)))
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: 80,
            maximum: 120,
            preferred: 120
        )
        
        // Store context for the display link callback
        proMotionScrollContext = ProMotionScrollContext(
            collectionView: collectionView,
            targetOffset: targetOffset,
            presentationTime: presentationTime,
            completion: completion,
            displayLink: displayLink
        )
        
        displayLink.add(to: .main, forMode: .common)
    }
    
    private var proMotionScrollContext: ProMotionScrollContext?
    
    @objc private func proMotionScrollFrame(_ displayLink: CADisplayLink) {
        guard let context = proMotionScrollContext else {
            displayLink.invalidate()
            return
        }
        
        // Check if we're at the optimal presentation time
        let currentTime = CACurrentMediaTime()
        if currentTime >= context.presentationTime - 0.001 { // 1ms tolerance
            // Apply the scroll at the perfect moment
            performInstantaneousScroll(
                collectionView: context.collectionView,
                targetOffset: context.targetOffset
            )
            
            displayLink.invalidate()
            context.completion(true)
            proMotionScrollContext = nil
        }
    }
    
    /// Standard 60Hz frame-synchronized scroll
    private func performStandardFrameScroll(
        collectionView: UICollectionView,
        targetOffset: CGPoint,
        updateInfo: UIUpdateInfo
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak collectionView] in
            if let collectionView = collectionView {
                let finalOffset = collectionView.contentOffset
                self?.logger.debug("📍 Standard frame scroll complete: \(finalOffset.x),\(finalOffset.y)")
            }
        }
        
        performInstantaneousScroll(collectionView: collectionView, targetOffset: targetOffset)
        
        // Force immediate layout for iOS 18 UIUpdateLink coordination
        if updateInfo.isImmediatePresentationExpected {
            collectionView.layoutIfNeeded()
        }
        
        CATransaction.commit()
    }
    
    /// Instantaneous scroll application with sub-pixel precision
    private func performInstantaneousScroll(
        collectionView: UICollectionView,
        targetOffset: CGPoint
    ) {
        // Apply with enhanced precision for iOS 18
        collectionView.setContentOffset(targetOffset, animated: false)
        
        // Immediate verification and correction for sub-pixel accuracy
        let actualOffset = collectionView.contentOffset
        let yError = abs(actualOffset.y - targetOffset.y)
        
        if yError > 0.1 / displayScale {
            // Apply correction if needed
            collectionView.setContentOffset(targetOffset, animated: false)
            logger.debug("🔧 Applied scroll correction, original error: \(yError)")
        }
    }
    
    private struct ProMotionScrollContext {
        let collectionView: UICollectionView
        let targetOffset: CGPoint
        let presentationTime: TimeInterval
        let completion: (Bool) -> Void
        let displayLink: CADisplayLink
    }
    
    // MARK: - Precise Anchor Capture
    
    /// Captures a precise scroll anchor with sub-pixel accuracy
    func capturePreciseAnchor(
        from collectionView: UICollectionView,
        preferredIndexPath: IndexPath? = nil
    ) -> PreciseScrollAnchor? {
        let visibleIndexPaths = collectionView.indexPathsForVisibleItems.sorted()
        
        guard !visibleIndexPaths.isEmpty else {
            logger.debug("No visible items for anchor capture")
            return nil
        }
        
        // Determine which item to use as anchor
        let anchorIndexPath: IndexPath
        
        if let preferred = preferredIndexPath,
           visibleIndexPaths.contains(preferred) {
            anchorIndexPath = preferred
        } else {
            // Find the item closest to viewport center
            let viewportCenterY = collectionView.contentOffset.y + collectionView.bounds.height / 2
            
            var closestIndexPath = visibleIndexPaths[0]
            var closestDistance = CGFloat.greatestFiniteMagnitude
            
            for indexPath in visibleIndexPaths {
                guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { continue }
                
                let itemCenterY = attributes.frame.midY
                let distance = abs(itemCenterY - viewportCenterY)
                
                if distance < closestDistance {
                    closestDistance = distance
                    closestIndexPath = indexPath
                }
            }
            
            anchorIndexPath = closestIndexPath
        }
        
        // Get precise measurements
        guard let attributes = collectionView.layoutAttributesForItem(at: anchorIndexPath),
              let cell = collectionView.cellForItem(at: anchorIndexPath) else {
            return nil
        }
        
        let contentOffset = collectionView.contentOffset
        let itemFrame = attributes.frame
        let visibleRect = CGRect(origin: contentOffset, size: collectionView.bounds.size)
        let visibleItemRect = itemFrame.intersection(visibleRect)
        
        return PreciseScrollAnchor(
            indexPath: anchorIndexPath,
            postId: "", // Will be set by caller
            contentOffset: contentOffset,
            viewportRelativeY: itemFrame.origin.y - contentOffset.y,
            itemFrameY: itemFrame.origin.y,
            itemHeight: itemFrame.height,
            visibleHeightInViewport: visibleItemRect.height,
            timestamp: CACurrentMediaTime(),
            displayScale: displayScale
        )
    }
    
    // MARK: - Gap Detection
    
    /// Detects gaps in the feed that need to be filled
    func detectGaps(
        currentPosts: [String], // Post IDs
        visibleRange: Range<Int>,
        cursor: String?,
        previousCursor: String?
    ) -> GapDetectionResult {
        guard !currentPosts.isEmpty,
              visibleRange.lowerBound >= 0,
              visibleRange.upperBound <= currentPosts.count else {
            return GapDetectionResult(
                hasGap: false,
                gapSize: 0,
                anchorPostId: "",
                newestVisiblePostId: "",
                expectedNextCursor: nil
            )
        }
        
        // Check if there's a potential gap
        let firstVisibleIndex = visibleRange.lowerBound
        let lastVisibleIndex = max(visibleRange.lowerBound, visibleRange.upperBound - 1)
        
        // If user is viewing posts near the top but we have a cursor,
        // there might be newer posts we haven't loaded
        let hasGap = firstVisibleIndex < 10 && cursor != nil && cursor != previousCursor
        
        // Estimate gap size based on typical feed behavior
        let estimatedGapSize = hasGap ? 20 : 0 // Typical page size
        
        return GapDetectionResult(
            hasGap: hasGap,
            gapSize: estimatedGapSize,
            anchorPostId: currentPosts[firstVisibleIndex],
            newestVisiblePostId: currentPosts[lastVisibleIndex],
            expectedNextCursor: cursor
        )
    }
    
    // MARK: - Smooth Restoration
    
    /// Calculates the target offset for position restoration without applying it
    func calculateTargetOffset(
        for anchor: PreciseScrollAnchor,
        newPostIds: [String],
        in collectionView: UICollectionView
    ) -> CGPoint? {
        // Find the anchor post in new data
        guard let newIndex = newPostIds.firstIndex(of: anchor.postId) else {
            logger.warning("Anchor post \(anchor.postId) not found in new data for calculation")
            return nil
        }
        
        let newIndexPath = IndexPath(item: newIndex, section: 0)
        
        // Get layout attributes for the new position
        guard let newAttributes = collectionView.layoutAttributesForItem(at: newIndexPath) else {
            logger.warning("Could not get attributes for anchor at \(newIndexPath) for calculation")
            return nil
        }
        
        // Calculate the target offset to maintain the same viewport-relative position
        // The key insight: we want the anchor post to appear at the same position in the viewport
        // as it was when the anchor was captured
        let newItemY = newAttributes.frame.origin.y
        let contentInset = collectionView.adjustedContentInset
        
        // The target offset should position the anchor post so that its relative position 
        // in the viewport matches what it was when the anchor was captured
        let targetOffsetY = newItemY - anchor.viewportRelativeY
        
        // Apply pixel alignment
        let pixelPerfectOffset = CGPoint(
            x: 0,
            y: round(targetOffsetY * displayScale) / displayScale
        )
        
        // Check bounds - ensure we don't scroll beyond valid content area
        let contentHeight = collectionView.contentSize.height
        let viewportHeight = collectionView.bounds.height
        let minOffset = -contentInset.top
        let maxOffset = max(minOffset, contentHeight - viewportHeight + contentInset.bottom)
        
        let safeOffset = CGPoint(
            x: 0,
            y: max(minOffset, min(pixelPerfectOffset.y, maxOffset))
        )
        
        logger.debug("📐 Calculated target offset: \(safeOffset.y) for anchor post \(anchor.postId) (was at index \(anchor.indexPath.item), now at \(newIndex))")
        return safeOffset
    }
    
    /// Restores scroll position with smooth animation if needed
    func restorePositionSmoothly(
        to anchor: PreciseScrollAnchor,
        in collectionView: UICollectionView,
        newPostIds: [String],
        animated: Bool = false
    ) async -> Bool {
        // Find the anchor post in new data
        guard let newIndex = newPostIds.firstIndex(of: anchor.postId) else {
            logger.warning("Anchor post \(anchor.postId) not found in new data")
            return false
        }
        
        let newIndexPath = IndexPath(item: newIndex, section: 0)
        
        // Wait for layout if needed
        await waitForLayout(collectionView)
        
        // Get new position of anchor item
        guard let newAttributes = collectionView.layoutAttributesForItem(at: newIndexPath) else {
            logger.warning("Could not get attributes for anchor at \(newIndexPath)")
            return false
        }
        
        // Calculate pixel-perfect target offset
        let newItemY = newAttributes.frame.origin.y
        let targetOffsetY = newItemY - anchor.viewportRelativeY
        
        // Apply pixel alignment
        let pixelPerfectOffset = CGPoint(
            x: 0,
            y: round(targetOffsetY * displayScale) / displayScale
        )
        
        // Check bounds
        let contentHeight = collectionView.contentSize.height
        let viewportHeight = collectionView.bounds.height
        let maxOffset = max(0, contentHeight - viewportHeight)
        let safeOffset = CGPoint(
            x: 0,
            y: max(0, min(pixelPerfectOffset.y, maxOffset))
        )
        
        if animated && abs(collectionView.contentOffset.y - safeOffset.y) > 100 {
            // Use smooth animation for large jumps
            await animateScroll(to: safeOffset, in: collectionView)
        } else {
            // Use frame-synchronized update for precise positioning with A/B testing
            let scrollStrategy = abTestingFramework?.getVariant(for: "scroll_position_preservation_v2") ?? .control
            
            if scrollStrategy == .treatment {
                // Enhanced restoration with full iOS 18 features
                await withCheckedContinuation { continuation in
                    createOptimizedUpdateLink(
                        for: collectionView,
                        targetOffset: safeOffset
                    ) { success in
                        continuation.resume(returning: success)
                    }
                }
            } else {
                // Control: Standard restoration method
                collectionView.setContentOffset(safeOffset, animated: false)
            }
        }
        
        return true
    }
    
    /// Animates scroll with spring physics
    private func animateScroll(to offset: CGPoint, in collectionView: UICollectionView) async {
        await withCheckedContinuation { continuation in
            UIView.animate(
                withDuration: 0.35,
                delay: 0,
                usingSpringWithDamping: 0.85,
                initialSpringVelocity: 0,
                options: [.curveEaseInOut, .allowUserInteraction]
            ) {
                collectionView.setContentOffset(offset, animated: false)
            } completion: { _ in
                continuation.resume()
            }
        }
    }
    
    /// Waits for collection view layout to complete
    private func waitForLayout(_ collectionView: UICollectionView) async {
        await withCheckedContinuation { continuation in
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                continuation.resume()
            }
            collectionView.layoutIfNeeded()
            CATransaction.commit()
        }
    }
    
    // MARK: - Cleanup
    
    /// Cleans up active update links
    func cleanup() {
        activeUpdateLink?.isEnabled = false
        activeUpdateLink = nil
        activeUpdateContext = nil
    }
    
    deinit {
        activeUpdateLink?.isEnabled = false
        activeUpdateLink = nil
        activeUpdateContext = nil
        proMotionScrollContext?.displayLink.invalidate()
        proMotionScrollContext = nil
    }
}

// MARK: - Feed Gap Loading Manager

@available(iOS 18.0, *)
@MainActor
final class FeedGapLoadingManager {
    
    // MARK: - Types
    
    struct GapLoadingStrategy {
        let maxGapSize: Int
        let loadBatchSize: Int
        let preserveAnchor: Bool
        let useBackgroundLoading: Bool
    }
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "blue.catbird", category: "FeedGapLoading")
    private var activeGapLoadTask: Task<Void, Never>?
    
    // MARK: - Gap Detection and Loading
    
    /// Detects and loads gaps in the feed
    func detectAndLoadGaps(
        stateManager: FeedStateManager,
        visibleIndexPaths: [IndexPath],
        strategy: GapLoadingStrategy = .default
    ) async {
        // Cancel any existing gap load
        activeGapLoadTask?.cancel()
        
        guard !visibleIndexPaths.isEmpty,
              let firstIndexPath = visibleIndexPaths.first,
              let lastIndexPath = visibleIndexPaths.last,
              firstIndexPath.item >= 0,
              lastIndexPath.item >= 0,
              firstIndexPath.item <= lastIndexPath.item else { 
            logger.debug("Invalid or empty visible index paths")
            return 
        }
        
        let currentPostIds = stateManager.posts.map { $0.id }
        
        // Ensure range bounds are valid
        guard firstIndexPath.item < currentPostIds.count,
              lastIndexPath.item < currentPostIds.count else {
            logger.debug("Visible index paths exceed current posts count")
            return
        }
        
        let visibleRange = firstIndexPath.item..<(lastIndexPath.item + 1)
        
        // Simple gap detection without creating a new scroll system instance
        // Check if there's a potential gap near the top
        let firstVisibleIndex = visibleRange.lowerBound
        let hasGap = firstVisibleIndex < 10 && !stateManager.isLoading && !stateManager.hasReachedEnd
        
        guard hasGap else {
            logger.debug("No gaps detected in visible range")
            return
        }
        
        logger.info("🔍 Gap detected near top - loading newer content")
        
        // Load missing content
        activeGapLoadTask = Task { [weak stateManager] in
            guard let stateManager = stateManager else { return }
            
            if strategy.useBackgroundLoading {
                // Load in background without disrupting UI
                await stateManager.backgroundRefresh()
            } else {
                // Standard refresh that may show loading state
                await stateManager.refresh()
            }
            
            logger.debug("✅ Gap loading completed")
        }
        
        await activeGapLoadTask?.value
    }
    
    /// Preemptively loads content to prevent gaps
    func preloadToPreventGaps(
        stateManager: FeedStateManager,
        scrollDirection: ScrollDirection,
        visibleRange: Range<Int>
    ) async {
        let totalPosts = stateManager.posts.count
        
        // Determine preload threshold based on scroll direction
        let shouldPreload: Bool
        
        switch scrollDirection {
        case .up:
            // Preload when approaching top
            shouldPreload = visibleRange.lowerBound < 5 && !stateManager.isLoading
        case .down:
            // Preload when approaching bottom (standard infinite scroll)
            shouldPreload = visibleRange.upperBound > totalPosts - 10 && !stateManager.hasReachedEnd
        case .none:
            shouldPreload = false
        }
        
        if shouldPreload {
            logger.debug("📥 Preloading content for scroll direction: \(String(describing: scrollDirection))")
            
            if scrollDirection == .up {
                // Load newer posts
                await stateManager.refresh()
            } else {
                // Load older posts
                await stateManager.loadMore()
            }
        }
    }
    
    enum ScrollDirection {
        case up, down, none
    }
}

// MARK: - Extensions

extension FeedGapLoadingManager.GapLoadingStrategy {
    static let `default` = FeedGapLoadingManager.GapLoadingStrategy(
        maxGapSize: 50,
        loadBatchSize: 20,
        preserveAnchor: true,
        useBackgroundLoading: true
    )
    
    static let aggressive = FeedGapLoadingManager.GapLoadingStrategy(
        maxGapSize: 100,
        loadBatchSize: 50,
        preserveAnchor: true,
        useBackgroundLoading: false
    )
}

#else

// MARK: - macOS Stub

@available(macOS 15.0, *)
@MainActor
final class OptimizedScrollPreservationSystem {
    
    init() {
        // No-op on macOS
    }
    
    func preserveScrollPosition() {
        // No-op on macOS
    }
    
    func restoreScrollPosition() {
        // No-op on macOS
    }
}

#endif
