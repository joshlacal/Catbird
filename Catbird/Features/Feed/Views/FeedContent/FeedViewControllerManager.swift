////
////  FeedViewControllerManager.swift
////  Catbird
////
////  Created by Claude on 7/19/25.
////
////  Manages persistent feed view controllers for smooth navigation and scroll preservation
////
//
//import SwiftUI
//import UIKit
//import Petrel
//import os
//
///// Manages persistent feed view controllers to prevent recreation and maintain scroll position
//@available(iOS 16.0, *)
//@MainActor
//final class FeedViewControllerManager: ObservableObject {
//    
//    // MARK: - Singleton
//    
//    static let shared = FeedViewControllerManager()
//    
//    // MARK: - Properties
//    
//    /// Cache of view controllers by feed identifier
//    private var controllerCache: [String: WeakControllerRef] = [:]
//    
//    /// Maximum number of cached controllers to prevent memory bloat
//    private let maxCachedControllers = 5
//    
//    /// Logger for debugging
//    private let logger = Logger(subsystem: "blue.catbird", category: "FeedViewControllerManager")
//    
//    // MARK: - Types
//    
//    /// Weak reference wrapper for view controllers
//    private class WeakControllerRef {
//        weak var controller: FeedCollectionViewController?
//        let lastAccessed: Date
//        
//        init(controller: FeedCollectionViewController) {
//            self.controller = controller
//            self.lastAccessed = Date()
//        }
//        
//        var isValid: Bool {
//            return controller != nil
//        }
//    }
//    
//    // MARK: - Initialization
//    
//    private init() {
//        // Set up memory warning observer
//        NotificationCenter.default.addObserver(
//            self,
//            selector: #selector(handleMemoryWarning),
//            name: UIApplication.didReceiveMemoryWarningNotification,
//            object: nil
//        )
//        
//        // Clean up on app background
//        NotificationCenter.default.addObserver(
//            self,
//            selector: #selector(handleAppBackground),
//            name: UIApplication.didEnterBackgroundNotification,
//            object: nil
//        )
//    }
//    
//    deinit {
//        NotificationCenter.default.removeObserver(self)
//    }
//    
//    // MARK: - Public Methods
//    
//    /// Gets or creates a persistent view controller for the given feed
//    func getController(
//        for fetchType: FetchType,
//        appState: AppState,
//        navigationPath: Binding<NavigationPath>,
//        onScrollOffsetChanged: ((CGFloat) -> Void)? = nil
//    ) -> FeedCollectionViewController {
//        
//        let identifier = fetchType.identifier
//        
//        // Check if we have a cached controller
//        if let cachedRef = controllerCache[identifier],
//           let existingController = cachedRef.controller {
//            
//            logger.debug("Reusing existing controller for feed: \(identifier)")
//            
//            // Update the controller's fetch type if needed
//            existingController.updateFetchType(fetchType, preserveScroll: true)
//            
//            // Update navigation path binding
//            existingController.updateNavigationPath(navigationPath)
//            
//            // Update scroll callback
//            existingController.updateScrollCallback(onScrollOffsetChanged)
//            
//            return existingController
//        }
//        
//        // Create new controller
//        logger.debug("Creating new controller for feed: \(identifier)")
//        
//        // Create FeedManager and FeedModel for the state manager
//        let feedManager = FeedManager(
//            client: appState.atProtoClient,
//            fetchType: fetchType
//        )
//        
//        let feedModel = FeedModel(
//            feedManager: feedManager,
//            appState: appState
//        )
//        
//        let stateManager = FeedStateManager(
//            appState: appState,
//            feedModel: feedModel,
//            feedType: fetchType
//        )
//        
//        let controller = FeedCollectionViewController(
//            stateManager: stateManager,
//            navigationPath: navigationPath,
//            onScrollOffsetChanged: onScrollOffsetChanged
//        )
//        
//        // Set stable restoration identifier (no UUID!)
//        controller.restorationIdentifier = "FeedCollectionViewController_\(identifier.hash)"
//        
//        // Cache the controller
//        cacheController(controller, for: identifier)
//        
//        // Load initial data for the new controller
//        Task { @MainActor in
//            await stateManager.loadInitialData()
//        }
//        
//        return controller
//    }
//    
//    /// Updates the fetch type for an existing controller
//    func updateFetchType(
//        _ fetchType: FetchType,
//        for controller: FeedCollectionViewController,
//        preserveScroll: Bool = true
//    ) {
//        let identifier = fetchType.identifier
//        
//        logger.debug("Updating fetch type to \(identifier), preserveScroll: \(preserveScroll)")
//        
//        controller.updateFetchType(fetchType, preserveScroll: preserveScroll)
//        
//        // Update cache key if identifier changed
//        updateCacheKey(for: controller, newIdentifier: identifier)
//    }
//    
//    /// Removes a controller from cache
//    func removeController(for identifier: String) {
//        controllerCache.removeValue(forKey: identifier)
//        logger.debug("Removed controller for feed: \(identifier)")
//    }
//    
//    /// Clears all cached controllers
//    func clearCache() {
//        controllerCache.removeAll()
//        logger.debug("Cleared all cached controllers")
//    }
//    
//    // MARK: - Private Methods
//    
//    private func cacheController(_ controller: FeedCollectionViewController, for identifier: String) {
//        // Clean up expired references
//        cleanupExpiredReferences()
//        
//        // Enforce cache size limit
//        if controllerCache.count >= maxCachedControllers {
//            evictOldestController()
//        }
//        
//        controllerCache[identifier] = WeakControllerRef(controller: controller)
//        logger.debug("Cached controller for feed: \(identifier) (cache size: \(self.controllerCache.count))")
//    }
//    
//    private func updateCacheKey(for controller: FeedCollectionViewController, newIdentifier: String) {
//        // Find current cache entry
//        for (key, ref) in controllerCache {
//            if ref.controller === controller {
//                controllerCache.removeValue(forKey: key)
//                controllerCache[newIdentifier] = ref
//                break
//            }
//        }
//    }
//    
//    private func cleanupExpiredReferences() {
//        controllerCache = controllerCache.compactMapValues { ref in
//            ref.isValid ? ref : nil
//        }
//    }
//    
//    private func evictOldestController() {
//        guard let oldestKey = controllerCache.min(by: { $0.value.lastAccessed < $1.value.lastAccessed })?.key else {
//            return
//        }
//        
//        controllerCache.removeValue(forKey: oldestKey)
//        logger.debug("Evicted oldest controller: \(oldestKey)")
//    }
//    
//    // MARK: - Notification Handlers
//    
//    @objc private func handleMemoryWarning() {
//        logger.warning("Memory warning received, clearing controller cache")
//        
//        // Keep only the most recently accessed controllers
//        let sortedControllers = controllerCache.sorted { $0.value.lastAccessed > $1.value.lastAccessed }
//        controllerCache.removeAll()
//        
//        // Keep top 2 most recent during memory pressure
//        for (key, ref) in sortedControllers.prefix(2) {
//            if ref.isValid {
//                controllerCache[key] = ref
//            }
//        }
//    }
//    
//    @objc private func handleAppBackground() {
//        logger.debug("App backgrounded, cleaning up expired references")
//        cleanupExpiredReferences()
//    }
//}
//
//// MARK: - FeedCollectionViewController Extensions
//
//@available(iOS 16.0, *)
//extension FeedCollectionViewController {
//    
//    /// Updates the fetch type while preserving scroll position
//    func updateFetchType(_ fetchType: FetchType, preserveScroll: Bool) {
//        let currentScrollPosition = preserveScroll ? captureCurrentScrollPosition() : nil
//        
//        // Update state manager asynchronously
//        Task { @MainActor in
//            await stateManager.updateFetchType(fetchType)
//            
//            // Restore scroll position if requested
//            if preserveScroll, let position = currentScrollPosition {
//                // Wait for data to load
//                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
//                await restoreScrollPosition(position)
//            }
//        }
//    }
//    
//    /// Updates the navigation path binding
//    func updateNavigationPath(_ navigationPath: Binding<NavigationPath>) {
//        // Store the new navigation path - implementation depends on how it's used
//        // This might require refactoring the controller to accept updated bindings
//    }
//    
//    /// Updates the scroll callback
//    func updateScrollCallback(_ callback: ((CGFloat) -> Void)?) {
//        // Update the scroll callback - implementation depends on current structure
//        // This might require making the callback a mutable property
//    }
//    
//    /// Captures current scroll position for preservation
//    private func captureCurrentScrollPosition() -> ScrollPositionTracker.ScrollAnchor? {
//        return scrollTracker.captureScrollAnchor(collectionView: collectionView)
//    }
//    
//    /// Restores a previously captured scroll position
//    private func restoreScrollPosition(_ anchor: ScrollPositionTracker.ScrollAnchor) async {
//        scrollTracker.restoreScrollPosition(collectionView: collectionView, to: anchor)
//    }
//}
