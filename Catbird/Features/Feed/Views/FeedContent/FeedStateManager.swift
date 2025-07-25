//
//  FeedStateManager.swift
//  Catbird
//
//  Created by Claude on 7/18/25.
//
//  @Observable state manager that coordinates feed data and persistent ViewModels
//

import Foundation
import SwiftUI
import Petrel
import os

@MainActor @Observable
final class FeedStateManager: StateInvalidationSubscriber {
    // MARK: - Types
    
    enum LoadingState: Equatable {
        case idle
        case loading
        case refreshing
        case loadingMore
        case error(Error)
        
        static func == (lhs: LoadingState, rhs: LoadingState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading), (.refreshing, .refreshing), (.loadingMore, .loadingMore):
                return true
            case (.error, .error):
                return true // Compare error messages if needed
            default:
                return false
            }
        }
    }
    
    struct ScrollAnchor {
        let postID: String
        let offsetFromTop: CGFloat
        let timestamp: Date
        
        var isStale: Bool {
            let maxAge: TimeInterval = FeedConstants.maxScrollAnchorAge
            return Date().timeIntervalSince(timestamp) > maxAge
        }
    }
    
    // MARK: - Published Properties
    
    /// Current posts in the feed
    private(set) var posts: [CachedFeedViewPost] = []
    
    /// Current loading state
    private(set) var loadingState: LoadingState = .idle
    
    /// Whether we've reached the end of the feed
    var hasReachedEnd = false
    
    /// Error message for display
    private(set) var errorMessage: String?
    
    /// Whether the feed is empty (no posts and not loading)
    var isEmpty: Bool {
        self.posts.isEmpty && !isLoading
    }
    
    /// Whether any loading operation is in progress
    var isLoading: Bool {
        switch loadingState {
        case .loading, .refreshing, .loadingMore:
            return true
        case .idle, .error:
            return false
        }
    }
    
    /// Current feed type being managed
    var currentFeedType: FetchType {
        return feedType
    }
    
    // MARK: - Private Properties
    
    /// Cached ViewModels keyed by post ID
    private var viewModelCache: [String: FeedPostViewModel] = [:]
    
    /// Dependencies
    private let appState: AppState
    private let feedModel: FeedModel
    private var feedType: FetchType
    
    /// Scroll position tracking
    private var scrollAnchor: ScrollAnchor?
    
    /// Debouncing and coordination
    private var refreshTask: Task<Void, Error>?
    private var loadMoreTask: Task<Void, Error>?
    private var updateTask: Task<Void, Error>?
    
    /// App lifecycle tracking
    private var isAppInBackground = false
    private var backgroundNotificationObserver: NSObjectProtocol?
    private var foregroundNotificationObserver: NSObjectProtocol?
    
    // MARK: - Logging
    
    private let logger = Logger(subsystem: "blue.catbird", category: "FeedStateManager")
    
    // MARK: - Initialization
    
    init(appState: AppState, feedModel: FeedModel, feedType: FetchType) {
        self.appState = appState
        self.feedModel = feedModel
        self.feedType = feedType
        
        // Initialize with current feed data
        self.posts = feedModel.posts
        
        // Set up observers for feed model changes
        setupObservers()
        
        // Subscribe to state invalidation events
        appState.stateInvalidationBus.subscribe(self)
        
        // Setup app lifecycle observers
        setupAppLifecycleObservers()
        
        logger.debug("FeedStateManager initialized for feed type: \(feedType.identifier)")
    }
    
    // MARK: - Setup
    
    private func setupObservers() {
        // Note: With @Observable, we don't need explicit observers
        // The SwiftUI view will automatically observe changes
    }
    
    /// Setup app lifecycle observers to handle background/foreground transitions
    private func setupAppLifecycleObservers() {
        backgroundNotificationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppDidEnterBackground()
            }
        }
        
        foregroundNotificationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppWillEnterForeground()
            }
        }
    }
    
    /// Handle app entering background - cancel ongoing tasks to prevent crashes
    private func handleAppDidEnterBackground() {
        isAppInBackground = true
        
        // Cancel all ongoing tasks when app goes to background
        refreshTask?.cancel()
        loadMoreTask?.cancel()
        updateTask?.cancel()
        
        logger.debug("App entered background - cancelled all tasks")
    }
    
    /// Handle app entering foreground - resume normal operation
    private func handleAppWillEnterForeground() {
        isAppInBackground = false
        logger.debug("App entering foreground")
    }
    
    // MARK: - ViewModel Management
    
    /// Gets or creates a ViewModel for a post, preserving existing UI state
    func viewModel(for post: CachedFeedViewPost) -> FeedPostViewModel {
        if let existing = viewModelCache[post.id] {
            // Update the post data while preserving UI state
            existing.updatePost(post)
            return existing
        }
        
        // Create new ViewModel
        let viewModel = FeedPostViewModel(post: post, appState: appState)
        viewModelCache[post.id] = viewModel
        
        logger.debug("Created new FeedPostViewModel for post: \(post.id)")
        return viewModel
    }
    
    /// Clears ViewModels for posts that are no longer in the feed
    private func cleanupViewModels() {
        let currentPostIDs = Set(posts.map { $0.id })
        let cachedPostIDs = Set(viewModelCache.keys)
        
        // Remove ViewModels for posts no longer in the feed
        let toRemove = cachedPostIDs.subtracting(currentPostIDs)
        for postID in toRemove {
            viewModelCache.removeValue(forKey: postID)
        }
        
        // Clear cached properties for memory management
        for viewModel in viewModelCache.values {
            viewModel.clearCache()
        }
        
        if !toRemove.isEmpty {
            logger.debug("Cleaned up \(toRemove.count) ViewModels")
        }
    }
    
    // MARK: - Data Loading
    
    /// Performs initial load of the feed
    @MainActor
    func loadInitialData() async {
        guard case .idle = loadingState else { return }
        
        loadingState = .loading
        errorMessage = nil
        hasReachedEnd = false  // Reset when loading fresh data
        
        await feedModel.loadFeed(fetch: feedType, forceRefresh: true)
        await updatePostsFromModel()
        
        // Check if feed has more data after initial load
        if !feedModel.hasMore {
            hasReachedEnd = true
            logger.debug("Initial load indicates no more data available")
        }
        
        loadingState = .idle
        logger.debug("Initial data loaded successfully - posts: \(self.posts.count), hasMore: \(self.feedModel.hasMore)")
    }
    
    /// Refreshes the feed data
    @MainActor
    func refresh() async {
        // Don't start new tasks if app is in background
        guard !isAppInBackground else {
            logger.debug("Skipping refresh - app is in background")
            return
        }
        
        // Cancel any existing refresh task
        refreshTask?.cancel()
        
        refreshTask = Task {
            guard !Task.isCancelled && !isAppInBackground else { return }
            
            loadingState = .refreshing
            errorMessage = nil
            hasReachedEnd = false
            
            // Capture scroll anchor before refresh
            captureScrollAnchor()
            
            await feedModel.loadFeed(fetch: feedType, forceRefresh: true)
            
            guard !Task.isCancelled && !isAppInBackground else { return }
            
            await updatePostsFromModel()
            loadingState = .idle
            
            logger.debug("Feed refreshed successfully")
        }
        
        try? await refreshTask?.value
    }
    
    /// Loads more posts for infinite scroll
    @MainActor
    func loadMore() async {
        // More specific check - only prevent if already loading more
        guard loadingState != .loadingMore,
              !hasReachedEnd,
              !isAppInBackground else {
            logger.debug("loadMore skipped - state: \(String(describing: self.loadingState)), hasReachedEnd: \(self.hasReachedEnd)")
            return
        }
        
        // Cancel any existing load more task
        loadMoreTask?.cancel()
        
        loadMoreTask = Task {
            guard !Task.isCancelled && !isAppInBackground else { return }
            
            loadingState = .loadingMore
            
            let previousCount = posts.count
            
            do {
                await feedModel.loadMore()
                
                guard !Task.isCancelled && !isAppInBackground else { 
                    loadingState = .idle
                    return 
                }
                
                await updatePostsFromModel()
                
                // Check if we've reached the end
                // Only set hasReachedEnd if feedModel says there's no more data
                if !feedModel.hasMore {
                    hasReachedEnd = true
                    logger.debug("Reached end of feed - no more cursor")
                } else if posts.count == previousCount {
                    // Posts were filtered out, but there might be more
                    logger.debug("No new posts after filtering, but more data available")
                }
                
                logger.debug("Loaded more posts successfully - total posts: \(self.posts.count)")
            } catch {
                logger.error("Error in loadMore: \(error)")
            }
            
            // Always reset state to idle
            loadingState = .idle
        }
        
        try? await loadMoreTask?.value
    }
    
    /// Retries the last failed operation
    @MainActor
    func retry() async {
        switch loadingState {
        case .error:
            if posts.isEmpty {
                await loadInitialData()
            } else {
                await refresh()
            }
        default:
            break
        }
    }
    
    // MARK: - Data Updates
    
    /// Updates posts from the feed model with debouncing
    @MainActor
    private func updatePostsFromModel() async {
        // Cancel any existing update task
        updateTask?.cancel()
        
        updateTask = Task {
            // Debounce rapid updates
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            
            guard !Task.isCancelled else { return }
            
            let newPosts = feedModel.posts
            let oldPosts = posts
            
            // Only update if posts actually changed
            guard newPosts != oldPosts else { 
                logger.debug("updatePostsFromModel: No change in posts (count: \(newPosts.count))")
                return 
            }
            
            posts = newPosts
            
            // Clean up ViewModels for posts no longer in the feed
            cleanupViewModels()
            
            logger.debug("Updated posts from model: \(oldPosts.count) -> \(self.posts.count) posts")
        }
        
        try? await updateTask?.value
    }
    
    // MARK: - Scroll Position Management
    
    /// Captures the current scroll position for restoration
    func captureScrollAnchor() {
        // This will be called by the UIKit controller when needed
        // We store the anchor for later restoration
    }
    
    /// Sets a scroll anchor for position restoration
    func setScrollAnchor(_ anchor: ScrollAnchor) {
        scrollAnchor = anchor
        logger.debug("Set scroll anchor for post: \(anchor.postID)")
    }
    
    /// Gets the current scroll anchor if not stale
    func getScrollAnchor() -> ScrollAnchor? {
        guard let anchor = scrollAnchor,
              !anchor.isStale else {
            scrollAnchor = nil
            return nil
        }
        return anchor
    }
    
    /// Clears the scroll anchor
    func clearScrollAnchor() {
        scrollAnchor = nil
    }
    
    // MARK: - Utility Methods
    
    /// Gets a post by ID
    func post(withID postID: String) -> CachedFeedViewPost? {
        posts.first { $0.id == postID }
    }
    
    /// Gets the index of a post by ID
    func index(of postID: String) -> Int? {
        posts.firstIndex { $0.id == postID }
    }
    
    /// Checks if a post exists in the current feed
    func contains(postID: String) -> Bool {
        posts.contains { $0.id == postID }
    }
    
    // MARK: - Cleanup
    
    /// Clears all cached data and cancels ongoing tasks
    func cleanup() {
        // Mark as background to prevent new tasks
        isAppInBackground = true
        
        // Cancel all tasks
        refreshTask?.cancel()
        loadMoreTask?.cancel()
        updateTask?.cancel()
        
        // Clear references
        refreshTask = nil
        loadMoreTask = nil
        updateTask = nil
        
        viewModelCache.removeAll()
        scrollAnchor = nil
        
        // Remove notification observers
        if let backgroundObserver = backgroundNotificationObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
            backgroundNotificationObserver = nil
        }
        if let foregroundObserver = foregroundNotificationObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
            foregroundNotificationObserver = nil
        }
        
        // Unsubscribe from state invalidation events
        appState.stateInvalidationBus.unsubscribe(self)
        
        logger.debug("FeedStateManager cleaned up")
    }
    
    deinit {
        // Note: Cannot access @MainActor properties from deinit
        // Cleanup will be handled by the cleanup() method called from the parent view
        // Tasks will be cancelled automatically when the object is deallocated
        logger.debug("FeedStateManager deallocated")
    }
    
    // MARK: - Feed Type Updates
    
    /// Updates the fetch type while preserving scroll position
    @MainActor
    func updateFetchType(_ newFetchType: FetchType, preserveScrollPosition: Bool = true) async {
        guard newFetchType.identifier != self.feedType.identifier else {
            logger.debug("Feed type unchanged, no update needed")
            return
        }
        
        logger.debug("Updating feed type from \(self.feedType.identifier) to \(newFetchType.identifier)")
        
        // Save current scroll position if requested
        let savedScrollAnchor = preserveScrollPosition ? scrollAnchor : nil
        
        // Cancel any ongoing operations
        refreshTask?.cancel()
        loadMoreTask?.cancel()
        updateTask?.cancel()
        
        // Update the feed type
        self.feedType = newFetchType
        
        // Update the feed model's fetch type via its manager
        feedModel.feedManager.updateFetchType(newFetchType)
        
        // Clear current state
        loadingState = .idle
        hasReachedEnd = false
        errorMessage = nil
        
        // Keep existing ViewModels if they're for the same posts
        // This prevents UI state loss when switching between feeds with overlapping content
        
        // Load new feed data
        await loadInitialData()
        
        // Restore scroll position if we had one and the posts support it
        if preserveScrollPosition, 
           let anchor = savedScrollAnchor,
           !anchor.isStale,
           let matchingPostIndex = posts.firstIndex(where: { $0.id == anchor.postID }) {
            
            // Create updated scroll anchor for the matching post
            self.scrollAnchor = ScrollAnchor(
                postID: anchor.postID,
                offsetFromTop: anchor.offsetFromTop,
                timestamp: Date()
            )
            
            logger.debug("Restored scroll position to post \(anchor.postID) at index \(matchingPostIndex)")
        } else {
            // Clear scroll anchor if we can't restore position
            self.scrollAnchor = nil
            if preserveScrollPosition {
                logger.debug("Could not restore scroll position - anchor post not found or stale")
            }
        }
    }
}

// MARK: - Error Handling

extension FeedStateManager {
    /// User-friendly error message
    var displayErrorMessage: String {
        switch loadingState {
        case .error(let error):
            return error.localizedDescription
        default:
            return errorMessage ?? "Unknown error"
        }
    }
    
    /// Whether there's an error that can be retried
    var canRetry: Bool {
        switch loadingState {
        case .error:
            return true
        default:
            return false
        }
    }
}

// MARK: - StateInvalidationSubscriber

extension FeedStateManager {
    /// Handle state invalidation events
    func handleStateInvalidation(_ event: StateInvalidationEvent) async {
        switch event {
        case .feedUpdated(let fetchType):
            // Refresh if this is the same feed type we're managing
            if fetchType.identifier == self.feedType.identifier {
                logger.debug("Received feed update for \(fetchType.identifier), refreshing")
                await refresh()
            }
            
        case .feedListChanged:
            // When feed list changes, we might need to refresh to get updated feed data
            logger.debug("Feed list changed, refreshing current feed")
            await refresh()
            
        case .accountSwitched:
            // When account switches, clear everything and reload
            logger.debug("Account switched, clearing and reloading feed")
            posts.removeAll()
            viewModelCache.removeAll()
            hasReachedEnd = false
            await loadInitialData()
            
        case .authenticationCompleted:
            // When authentication completes, load initial data if we don't have any
            if posts.isEmpty {
                logger.debug("Authentication completed, loading initial feed data")
                await loadInitialData()
            }
            
        case .postCreated, .replyCreated:
            // Refresh to show new posts
            logger.debug("New post created, refreshing to show it")
            await refresh()
            
        default:
            // Other events don't require action for feed state
            break
        }
    }
    
    /// Check if this feed state manager is interested in specific events
    nonisolated func isInterestedIn(_ event: StateInvalidationEvent) -> Bool {
        switch event {
        case .feedUpdated, .feedListChanged, .accountSwitched, .authenticationCompleted, .postCreated, .replyCreated:
            return true
        default:
            return false
        }
    }
}

// MARK: - Preview Support

extension FeedStateManager {
    /// Creates a preview instance for SwiftUI previews
    static func preview(posts: [CachedFeedViewPost] = []) -> FeedStateManager {
        // This would need to be implemented with mock dependencies
        // For now, we'll use the actual dependencies
        fatalError("Preview not implemented - use actual dependencies")
    }
}
