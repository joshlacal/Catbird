//
//  BatchUpdateCoordinator.swift
//  Catbird
//
//  Created by Claude on iOS 18 UIUpdateLink optimization
//
//  Coordinates batch updates with display refresh cycle for smooth animations
//

import UIKit
import os

@available(iOS 16.0, *)
final class BatchUpdateCoordinator {
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "blue.catbird", category: "BatchUpdateCoordinator")
    private var lastStableFrameTime: CFTimeInterval = 0
    private let stabilityRequiredDuration: CFTimeInterval = 0.033 // ~2 frames at 60fps
    
    // MARK: - Public Methods
    
    /// Determines if the collection view is ready for batch updates
    /// - Parameter collectionView: The collection view to check
    /// - Returns: True if conditions are optimal for batch updates
    func isReadyForBatchUpdate(_ collectionView: UICollectionView) -> Bool {
        let currentTime = CACurrentMediaTime()
        
        // Check if user is actively interacting
        let isUserInteracting = collectionView.isTracking || 
                               collectionView.isDragging || 
                               collectionView.isDecelerating
        
        if isUserInteracting {
            // Reset stability timer during user interaction
            lastStableFrameTime = currentTime
            return false
        }
        
        // Check if any animations are running
        if hasOngoingAnimations(in: collectionView) {
            lastStableFrameTime = currentTime
            return false
        }
        
        // Check if we've been stable long enough
        let stableDuration = currentTime - lastStableFrameTime
        if stableDuration < stabilityRequiredDuration {
            return false
        }
        
        logger.debug("Collection view ready for batch update after \(stableDuration)s stability")
        return true
    }
    
    /// Resets the stability timer (call when starting new operations)
    func resetStabilityTimer() {
        lastStableFrameTime = CACurrentMediaTime()
    }
    
    // MARK: - Private Methods
    
    private func hasOngoingAnimations(in collectionView: UICollectionView) -> Bool {
        // Check collection view layer animations
        if let layer = collectionView.layer.presentation() {
            // If presentation layer differs from model layer, animation is active
            let modelBounds = collectionView.layer.bounds
            let presentationBounds = layer.bounds
            
            if !modelBounds.equalTo(presentationBounds) {
                return true
            }
        }
        
        // Check visible cells for animations
        for cell in collectionView.visibleCells {
            if let cellLayer = cell.layer.presentation() {
                let modelFrame = cell.layer.frame
                let presentationFrame = cellLayer.frame
                
                if !modelFrame.equalTo(presentationFrame) {
                    return true
                }
            }
        }
        
        return false
    }
}

// MARK: - Performance Configuration

@available(iOS 16.0, *)
extension BatchUpdateCoordinator {
    
    /// Configuration for different update scenarios
    enum UpdateScenario {
        case refresh          // Pull-to-refresh with new content
        case loadMore        // Infinite scroll loading
        case liveUpdate      // Real-time content changes
        case userAction      // User-initiated changes
        
        var stabilityDuration: CFTimeInterval {
            switch self {
            case .refresh:
                return 0.050 // ~3 frames - allow for refresh animation
            case .loadMore:
                return 0.016 // ~1 frame - immediate for smooth scrolling
            case .liveUpdate:
                return 0.033 // ~2 frames - balance responsiveness with stability
            case .userAction:
                return 0.016 // ~1 frame - immediate feedback
            }
        }
    }
    
    /// Checks readiness for specific update scenario
    func isReady(for scenario: UpdateScenario, collectionView: UICollectionView) -> Bool {
        let previousDuration = stabilityRequiredDuration
        defer {
            // Note: In production code, you'd want to make stabilityRequiredDuration mutable
            // or create separate coordinators for different scenarios
        }
        
        // For now, use the scenario-specific duration for the check
        let currentTime = CACurrentMediaTime()
        let isUserInteracting = collectionView.isTracking || 
                               collectionView.isDragging || 
                               collectionView.isDecelerating
        
        if isUserInteracting && scenario != .userAction {
            return false
        }
        
        if hasOngoingAnimations(in: collectionView) {
            return false
        }
        
        let stableDuration = currentTime - lastStableFrameTime
        return stableDuration >= scenario.stabilityDuration
    }
}