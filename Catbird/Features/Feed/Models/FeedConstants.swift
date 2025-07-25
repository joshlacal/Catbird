//
//  FeedConstants.swift
//  Catbird
//
//  Created by Claude on 7/13/25.
//

import Foundation
import CoreGraphics

/// Centralized constants for feed system configuration and performance tuning
struct FeedConstants {
    
    // MARK: - Scroll & Pagination
    
    /// Number of screen heights before the bottom to trigger infinite scroll loading
    static let infiniteScrollTriggerThreshold: CGFloat = 0.8
    
    /// Minimum number of posts remaining to trigger load more operation
    static let loadMorePostThreshold: Int = 10
    
    /// Minimum percentage visibility required for scroll anchor capture
    static let scrollAnchorVisibilityThreshold: CGFloat = 0.3
    
    /// Navigation cooldown period in seconds to prevent false infinite scroll triggers
    static let navigationCooldownDuration: TimeInterval = 0.5
    
    // MARK: - Performance & Debouncing
    
    /// Debounce interval for rapid data updates to prevent UI flickering
    static let updateDebounceInterval: TimeInterval = 0.05
    
    /// Debounce delay for filter operations in milliseconds
    static let filterDebounceDelay: UInt64 = 300_000_000 // 300ms
    
    /// Debounce delay for load more triggers in milliseconds  
    static let loadMoreDebounceDelay: UInt64 = 10_000_000 // 10ms
    
    /// Debounce delay for LoadMoreTrigger component in milliseconds
    static let triggerDebounceDelay: UInt64 = 200_000_000 // 200ms
    
    /// Brief delay to prevent UI flickering on fast filter operations
    static let filterLoadingDelay: UInt64 = 150_000_000 // 150ms
    
    /// Interval for saving scroll position (throttled to avoid excessive saves)
    static let scrollPositionSaveInterval: TimeInterval = 2.0
    
    // MARK: - UI Spacing & Layout
    
    /// Base spacing unit used throughout feed components (multiple of 3pt)
    static let baseSpacingUnit: CGFloat = 3
    
    /// Standard padding for feed components
    static let standardPadding: CGFloat = baseSpacingUnit * 5 // 15pt
    
    /// Compact padding for tight layouts
    static let compactPadding: CGFloat = baseSpacingUnit * 3 // 9pt
    
    /// Large padding for section separations
    static let largePadding: CGFloat = baseSpacingUnit * 8 // 24pt
    
    // MARK: - Feed Refresh & Caching
    
    /// Minimum interval between automatic feed refreshes (in seconds)
    static let minimumRefreshInterval: TimeInterval = 300 // 5 minutes
    
    /// Interval for checking new posts availability
    static let newPostsCheckInterval: TimeInterval = 60 // 1 minute
    
    /// Duration to keep continuity banners visible (in seconds)
    static let continuityBannerDuration: TimeInterval = 3.0
    
    /// Minimum interval between continuity banner displays
    static let continuityBannerCooldown: TimeInterval = 5.0
    
    // MARK: - Content Detection
    
    /// Time gap threshold for detecting content gaps (in seconds)
    static let contentGapThreshold: TimeInterval = 3600 // 1 hour
    
    /// Maximum recent posts to check for gap detection
    static let gapDetectionRecentPostLimit: Int = 10
    
    /// Threshold for significant new content in non-chronological feeds
    static let significantContentThreshold: Int = 3
    
    /// Minimum percentage of feed change to trigger background refresh
    static let backgroundRefreshThreshold: Double = 0.1 // 10%
    
    // MARK: - Theme & Visual
    
    /// Default corner radius for feed UI elements
    static let defaultCornerRadius: CGFloat = 8
    
    /// Small corner radius for compact elements
    static let smallCornerRadius: CGFloat = 4
    
    /// Large corner radius for prominent elements
    static let largeCornerRadius: CGFloat = 12
    
    /// Shadow radius for feed cards and banners
    static let shadowRadius: CGFloat = 4
    
    /// Shadow opacity for subtle depth effects
    static let shadowOpacity: Double = 0.1
    
    // MARK: - Animation & Transitions
    
    /// Standard animation duration for feed transitions
    static let standardAnimationDuration: TimeInterval = 0.3
    
    /// Quick animation duration for immediate feedback
    static let quickAnimationDuration: TimeInterval = 0.15
    
    /// Slow animation duration for prominent transitions
    static let slowAnimationDuration: TimeInterval = 0.5
    
    // MARK: - Error Handling
    
    /// Delay before retrying failed operations
    static let retryDelay: TimeInterval = 1.0
    
    /// Maximum number of automatic retry attempts
    static let maxRetryAttempts: Int = 3
    
    /// Timeout for loading operations in seconds
    static let loadingTimeout: TimeInterval = 30.0
    
    // MARK: - Scroll Position Restoration
    
    /// Maximum time to spend on scroll position restoration attempts
    static let scrollRestorationTimeout: TimeInterval = 2.0
    
    /// Maximum number of scroll restoration retry attempts
    static let maxScrollRestorationAttempts: Int = 3
    
    /// Maximum age of scroll anchor before considering it stale (in seconds)
    static let maxScrollAnchorAge: TimeInterval = 30.0
    
    /// Maximum time for layout operations during scroll restoration
    static let layoutTimeout: TimeInterval = 1.0
    
    /// Threshold for detecting failed scroll restoration (offset difference in points)
    static let scrollRestorationVerificationThreshold: CGFloat = 1.0
    
    /// Default fallback scroll position as percentage of content height
    static let fallbackScrollPositionPercent: CGFloat = 0.1 // 10% from top
    
    /// Maximum fallback scroll offset in points
    static let maxFallbackScrollOffset: CGFloat = 200
}

// MARK: - Convenience Extensions

extension FeedConstants {
    
    /// Returns spacing value for the given multiplier of base unit
    static func spacing(_ multiplier: CGFloat) -> CGFloat {
        return baseSpacingUnit * multiplier
    }
    
    /// Returns nanoseconds for the given milliseconds
    static func nanoseconds(from milliseconds: UInt64) -> UInt64 {
        return milliseconds * 1_000_000
    }
    
    /// Returns TimeInterval for the given milliseconds
    static func timeInterval(from milliseconds: UInt64) -> TimeInterval {
        return TimeInterval(milliseconds) / 1000.0
    }
}