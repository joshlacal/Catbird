//
//  UIKitStateObserver.swift
//  Catbird
//
//  Proper @Observable state integration for UIKit components
//

import Foundation
import SwiftUI
import Observation

@MainActor
final class UIKitStateObserver<T: Observable> {
    
    private let observedObject: T
    private let onChange: @MainActor (T) -> Void
    private nonisolated(unsafe) var observationTask: Task<Void, Never>?
    
    init(observing object: T, onChange: @escaping @MainActor (T) -> Void) {
        self.observedObject = object
        self.onChange = onChange
        startObserving()
    }
    
    func startObserving() {
        observationTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            // Use proper @Observable observation - we need to actually read properties to observe them
            withObservationTracking {
                // For FeedStateManager, we need to observe all relevant properties
                if let stateManager = self.observedObject as? FeedStateManager {
                    _ = stateManager.posts
                    _ = stateManager.loadingState
                    _ = stateManager.hasReachedEnd
                    _ = stateManager.isEmpty
                } else if let themeManager = self.observedObject as? ThemeManager {
                    // For ThemeManager, observe theme-related properties
                    _ = themeManager.colorSchemeOverride
                    _ = themeManager.darkThemeMode
                } else if let feedback = self.observedObject as? FeedFeedbackManager {
                    // Explicitly observe feed feedback toggles and feed identity
                    _ = feedback.isEnabled
                    _ = feedback.currentFeedType?.identifier
                } else {
                    // For other observable objects, read a known-changing property by re-evaluating the object
                    _ = self.observedObject
                }
            } onChange: {
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.onChange(self.observedObject)
                    // Continue observing
                    self.startObserving()
                }
            }
        }
    }
    
    nonisolated func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }
    
    deinit {
        stopObserving()
    }
}

// MARK: - FeedStateManager Integration

extension UIKitStateObserver where T == FeedStateManager {
    
    /// Create an observer specifically for FeedStateManager that watches relevant properties
    static func observeFeedStateManager(
        _ stateManager: FeedStateManager,
        onPostsChanged: @escaping @MainActor ([CachedFeedViewPost]) -> Void,
        onLoadingStateChanged: @escaping @MainActor (FeedStateManager.LoadingState) -> Void,
        onScrollAnchorChanged: @escaping @MainActor (FeedStateManager.ScrollAnchor?) -> Void
    ) -> UIKitStateObserver<FeedStateManager> {
        
        var previousPosts: [CachedFeedViewPost] = stateManager.posts
        var previousLoadingState: FeedStateManager.LoadingState = stateManager.loadingState
        var previousScrollAnchor = stateManager.getScrollAnchor()
        
        return UIKitStateObserver(observing: stateManager) { manager in
            // Check what specifically changed and call appropriate handlers
            let currentPosts = manager.posts
            let currentLoadingState = manager.loadingState
            let currentScrollAnchor = manager.getScrollAnchor()
            
            // Posts changed
            if previousPosts != currentPosts {
                onPostsChanged(currentPosts)
                previousPosts = currentPosts
            }
            
            // Loading state changed
            if previousLoadingState != currentLoadingState {
                onLoadingStateChanged(currentLoadingState)
                previousLoadingState = currentLoadingState
            }
            
            // Scroll anchor changed
            if previousScrollAnchor?.postID != currentScrollAnchor?.postID ||
               previousScrollAnchor?.offsetFromTop != currentScrollAnchor?.offsetFromTop {
                onScrollAnchorChanged(currentScrollAnchor)
                previousScrollAnchor = currentScrollAnchor
            }
        }
    }
}

// MARK: - Collection Equality for CachedFeedViewPost

extension Array where Element == CachedFeedViewPost {
    static func != (lhs: [CachedFeedViewPost], rhs: [CachedFeedViewPost]) -> Bool {
        return !(lhs == rhs)
    }
    
    static func == (lhs: [CachedFeedViewPost], rhs: [CachedFeedViewPost]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (index, lhsPost) in lhs.enumerated() {
            let rhsPost = rhs[index]
            // Compare only the essential post data, not cache timestamps
            // This prevents infinite refresh loops caused by timestamp changes
            if lhsPost.id != rhsPost.id {
                return false
            }
        }
        return true
    }
}
