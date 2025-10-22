//
//  FeedStateManager.swift
//  Catbird
//
//  Created by Claude on 7/18/25.
//
//  @Observable state manager that coordinates feed data and persistent ViewModels
//

import Foundation
import Observation
import SwiftUI
import Petrel
import os
#if os(iOS)
import UIKit
#endif

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
    
    /// New posts tracking for indicator
    private(set) var newPostsCount: Int = 0
    private(set) var newPostsAuthorAvatars: [String] = []
    private(set) var hasNewPosts: Bool = false
    private var newPostsDetectedTime: Date? = nil
    
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
    let appState: AppState
    private let feedModel: FeedModel
    private var feedType: FetchType
    
    /// Scroll position tracking
    private var scrollAnchor: ScrollAnchor?
    
    /// Debouncing and coordination
    private var refreshTask: Task<Void, Error>?
    private var loadMoreTask: Task<Void, Error>?
    private var updateTask: Task<Void, Error>?
    
    /// Automatic refresh coordination
    private var autoRefreshTask: Task<Void, Never>?
    
    /// App lifecycle tracking
    private var isAppInBackground = false
    private var backgroundNotificationObserver: NSObjectProtocol?
    private var foregroundNotificationObserver: NSObjectProtocol?
    
    /// User action tracking to prevent unwanted automatic refreshes
    private var lastUserAction: Date = Date.distantPast
    private var isUserInitiatedAction = false
    private let userActionCooldownInterval: TimeInterval = 2.0 // 2 seconds
    
    /// New posts tracking
    private var postsBeforeRefresh: [CachedFeedViewPost] = []
    private var isTrackingNewPosts = false // Prevent multiple tracking calls
    /// Callback for scrolling to top
    var scrollToTopCallback: (() -> Void)?
    
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
        
        // Start automatic refresh monitoring
        startAutomaticRefreshMonitoring()
        
        logger.debug("FeedStateManager initialized for feed type: \(feedType.identifier)")
    }


    // MARK: - Setup
    
    private func setupObservers() {
        // Observe filter changes and reapply immediately
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("FeedFiltersChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.reapplyFilters()
            }
        }
    }
    
    /// Setup app lifecycle observers (legacy support - main lifecycle now handled via SwiftUI scene phase)
    private func setupAppLifecycleObservers() {
        // Keep app lifecycle observers for compatibility but rely primarily on scene phase coordination
        #if os(iOS)
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
        #elseif os(macOS)
        backgroundNotificationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppDidEnterBackground()
            }
        }
        
        foregroundNotificationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppWillEnterForeground()
            }
        }
        #endif
    }
    
    /// Handle app entering background - cancel ongoing tasks to prevent crashes
    private func handleAppDidEnterBackground() {
        isAppInBackground = true
        
        // Cancel all ongoing tasks when app goes to background
        refreshTask?.cancel()
        loadMoreTask?.cancel()
        updateTask?.cancel()
        autoRefreshTask?.cancel()
        
        logger.debug("App entered background - cancelled all tasks")
    }
    
    /// Handle app entering foreground - resume normal operation
    private func handleAppWillEnterForeground() {
        isAppInBackground = false
        logger.debug("App entering foreground")
        
        // Restart automatic refresh monitoring
        startAutomaticRefreshMonitoring()
        
        // Don't automatically refresh when returning from navigation
        // Only refresh if user hasn't taken any action recently
        let timeSinceLastUserAction = Date().timeIntervalSince(lastUserAction)
        if timeSinceLastUserAction > 30.0 { // 30 seconds
            logger.debug("App returned to foreground after long time since user action, allowing potential refresh")
        } else {
            logger.debug("App returned to foreground recently after user action, skipping automatic refresh")
        }
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

        // Only load if posts are empty or this is a user-initiated action
        guard posts.isEmpty || isUserInitiatedAction else {
            logger.debug("Skipping initial load - posts exist and not user-initiated")
            return
        }

        markUserAction()

        loadingState = .loading
        errorMessage = nil
        hasReachedEnd = false  // Reset when loading fresh data

        await feedModel.loadFeed(fetch: feedType, forceRefresh: true)

        // Check if feed load encountered an error
        if let error = feedModel.error {
            logger.error("Initial load failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            loadingState = .error(error)
            return
        }

        await updatePostsFromModel()

        // Check if feed has more data after initial load
        if !feedModel.hasMore {
            hasReachedEnd = true
            logger.debug("Initial load indicates no more data available")
        }

        loadingState = .idle
        logger.debug("Initial data loaded successfully - posts: \(self.posts.count), hasMore: \(self.feedModel.hasMore)")
    }
    
    /// Load initial data with system flag - bypasses user-initiated check for post-authentication loading
    func loadInitialDataWithSystemFlag() async {
        guard case .idle = loadingState else { return }

        logger.debug("Loading initial data with system flag - post-authentication")

        loadingState = .loading
        errorMessage = nil
        hasReachedEnd = false  // Reset when loading fresh data

        // For system-initiated loads (like post-auth), always force refresh even if posts exist
        await feedModel.loadFeed(fetch: feedType, forceRefresh: true)

        // Check if feed load encountered an error
        if let error = feedModel.error {
            logger.error("System initial load failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            loadingState = .error(error)
            return
        }

        await updatePostsFromModel()

        // Check if feed has more data after initial load
        if !feedModel.hasMore {
            hasReachedEnd = true
            logger.debug("Initial load indicates no more data available")
        }

        loadingState = .idle
        logger.debug("System-initiated initial data loaded successfully - posts: \(self.posts.count), hasMore: \(self.feedModel.hasMore)")
    }
    
    /// Refreshes the feed data (user-initiated via pull-to-refresh or button)
    /// This bypasses background checks since user interaction proves app is active
    @MainActor
    func refreshUserInitiated() async {
        logger.debug("🔄 User-initiated refresh - forcing foreground state")
        
        // User interaction means we're definitely in foreground, reset the flag
        isAppInBackground = false
        
        // Delegate to standard refresh
        await refresh()
    }
    
    /// Refreshes the feed data (user-initiated)
    @MainActor
    func refresh() async {
        // Don't start new tasks if app is in background
        guard !isAppInBackground else {
            logger.debug("Skipping refresh - app is in background")
            return
        }

        // Validate account state before attempting refresh
        guard let client = appState.atProtoClient else {
            logger.error("❌ Cannot refresh: No ATProto client available")
            errorMessage = "Authentication required. Please restart the app."
            loadingState = .error(NSError(domain: "FeedStateManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No client available"]))
            return
        }

        // Check if account is available (with retry for transient state issues)
        var accountAvailable = false
        for attempt in 1...3 {
            let validSession = await client.hasValidSession()
            if validSession {
                if let handle = try? await client.getHandle() {
                    logger.debug("✅ Account validation passed: \(validSession) \(handle)") }
                accountAvailable = true
                break
            } else {
                logger.warning("⚠️ Account not available on attempt \(attempt)/3, waiting 100ms...")
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }

        guard accountAvailable else {
            logger.error("❌ Cannot refresh: Account manager state is inconsistent after 3 attempts")
            errorMessage = "Account session lost. Please try again or restart the app."
            loadingState = .error(NSError(domain: "FeedStateManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Account unavailable"]))
            return
        }

        // Mark this as a user-initiated action
        markUserAction()

        // Store posts before refresh to track new posts
        postsBeforeRefresh = posts
        isTrackingNewPosts = false // Reset tracking flag for new refresh
        logger.debug("🔍 NEW_POSTS_DEBUG: Stored \(self.postsBeforeRefresh.count) posts before refresh for comparison")
        logger.debug("🔍 NEW_POSTS_DEBUG: First 3 post IDs before refresh: \(self.postsBeforeRefresh.prefix(3).map { $0.id })")

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

            // Check if feed load encountered an error
            if let error = feedModel.error {
                logger.error("Feed refresh failed: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
                loadingState = .error(error)
                return
            }

            await updatePostsFromModel()

            // Track new posts after refresh
            await trackNewPostsAfterRefresh()

            // Debug: Print current indicator state after tracking
            logger.debug("🔍 POST_TRACKING_FINAL: After trackNewPosts - hasNewPosts=\(self.hasNewPosts), count=\(self.newPostsCount), avatars=\(self.newPostsAuthorAvatars.count)")

            loadingState = .idle

            logger.debug("Feed refreshed successfully")
        }

        try? await refreshTask?.value
    }
    
    /// Loads more posts for infinite scroll (user-initiated)
    @MainActor
    func loadMore() async {
        // More specific check - only prevent if already loading more
        guard loadingState != .loadingMore,
              !hasReachedEnd,
              !isAppInBackground else {
            logger.debug("loadMore skipped - state: \(String(describing: self.loadingState)), hasReachedEnd: \(self.hasReachedEnd)")
            return
        }
        
        // Mark this as a user-initiated action
        markUserAction()
        
        // Cancel any existing load more task
        loadMoreTask?.cancel()
        
        loadMoreTask = Task {
            guard !Task.isCancelled && !isAppInBackground else { return }
            
            loadingState = .loadingMore
            
            let previousCount = posts.count
            
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
    
    /// Re-applies current filter settings to existing posts
    /// This allows filters to take effect immediately without needing to refresh from server
    @MainActor
    func reapplyFilters() async {
        logger.debug("Reapplying filters to \(self.feedModel.posts.count) posts")
        
        // Trigger FeedModel to re-process its posts with current filter settings
        let filteredPosts = feedModel.applyFilters(withSettings: appState.feedFilterSettings)
        
        // Update our display
        posts = filteredPosts
        
        // Clean up ViewModels for posts no longer visible
        cleanupViewModels()
        
        logger.debug("Filter reapplication complete - now showing \(self.posts.count) posts")
    }
    
    // MARK: - Scroll Position Management
    
    /// Captures the current scroll position for restoration
    func captureScrollAnchor() {
        // This will be called by the UIKit controller when needed
        // We store the anchor for later restoration
    }
    
    /// Captures scroll position from UICollectionView (called by controller)
    #if os(iOS)
    func captureScrollAnchor(from collectionView: UICollectionView) {
        guard !posts.isEmpty else { return }
        
        let visibleIndexPaths = collectionView.indexPathsForVisibleItems.sorted()
        guard let firstVisibleIndexPath = visibleIndexPaths.first,
              firstVisibleIndexPath.item < posts.count else { return }
        
        let post = posts[firstVisibleIndexPath.item]
        
        // Calculate offset from the top of the visible cell
        let cellFrame = collectionView.cellForItem(at: firstVisibleIndexPath)?.frame ?? .zero
        let contentOffsetY = collectionView.contentOffset.y
        let offsetFromTop = contentOffsetY - cellFrame.minY
        
        scrollAnchor = ScrollAnchor(
            postID: post.id,
            offsetFromTop: offsetFromTop,
            timestamp: Date()
        )
        
        logger.debug("📍 Captured scroll anchor for post: \(post.id), offset: \(offsetFromTop)")
    }
    #endif
    
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
    
    // MARK: - Data Restoration
    
    /// Restores persisted posts without triggering network requests
    @MainActor
    func restorePersistedPosts(_ posts: [CachedFeedViewPost]) async {
        guard self.posts.isEmpty else {
            logger.debug("Posts already loaded, skipping restoration")
            return
        }
        
        // Filter out posts that can't be decoded (malformed cached data)
        var validPosts: [CachedFeedViewPost] = []
        var invalidPostIds: [String] = []
        
        for post in posts {
            if (try? post.feedViewPost) != nil {
                validPosts.append(post)
            } else {
                invalidPostIds.append(post.id)
                logger.warning("Cached post \(post.id) cannot be decoded - will be removed from cache")
            }
        }
        
        // If we found invalid posts, remove them from the cache
        if !invalidPostIds.isEmpty {
            logger.info("Removing \(invalidPostIds.count) invalid cached posts")
            Task.detached { [invalidPostIds] in
                await PersistentFeedStateManager.shared.removeInvalidPosts(withIds: invalidPostIds)
            }
        }
        
        self.posts = validPosts
        self.loadingState = .idle
        self.hasReachedEnd = false
        
        // Update feed model's posts to match
        await feedModel.restorePersistedPosts(validPosts)
        
        logger.debug("Restored \(validPosts.count) persisted posts (\(invalidPostIds.count) invalid posts filtered out)")
    }
    
    // MARK: - iOS 18+ Smart Refresh Methods
    
    /// Smart refresh that preserves scroll position and UI state
    @MainActor
    func smartRefresh() async {
        // Don't start new tasks if app is in background
        guard !isAppInBackground else {
            logger.debug("Skipping smart refresh - app is in background")
            return
        }
        
        // Cancel any existing tasks
        refreshTask?.cancel()
        
        refreshTask = Task {
            guard !Task.isCancelled && !isAppInBackground else { return }

            // Capture current scroll position before refresh
            captureScrollAnchor()

            // Use background refresh strategy to preserve UI continuity
            loadingState = .refreshing
            errorMessage = nil
            hasReachedEnd = false

            logger.debug("Starting smart refresh for feed: \(self.feedType.identifier)")

            // Load fresh data using the feed model
            await feedModel.loadFeed(fetch: feedType, forceRefresh: true, strategy: .backgroundRefresh)

            guard !Task.isCancelled && !isAppInBackground else {
                loadingState = .idle
                return
            }

            // Check if feed load encountered an error
            if let error = feedModel.error {
                logger.error("Smart refresh failed: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
                loadingState = .error(error)
                return
            }

            // Update posts from the model
            await updatePostsFromModel()

            // Reset pagination state if needed
            if !feedModel.hasMore {
                hasReachedEnd = true
            }

            logger.debug("Smart refresh completed successfully for feed: \(self.feedType.identifier)")

            if !Task.isCancelled {
                loadingState = .idle
            }
        }
        
        try? await refreshTask?.value
    }
    
    /// Background refresh that doesn't disrupt the current UI state
    @MainActor
    func backgroundRefresh() async {
        // Don't start if already refreshing or app is in background
        guard !isAppInBackground, 
              loadingState != .refreshing,
              loadingState != .loading else {
            logger.debug("Skipping background refresh - conditions not met")
            return
        }
        
        logger.debug("Starting background refresh for feed: \(self.feedType.identifier)")
        
        // Don't change UI loading state for background refresh
        let originalLoadingState = loadingState
        
        // Use the feed model's background refresh capability
        await feedModel.loadFeed(fetch: feedType, forceRefresh: false, strategy: .backgroundRefresh)
        
        // Only update if we're not cancelled and app is still active
        guard !isAppInBackground else { return }
        
        // Update posts from the model (this will only update if there are significant changes)
        await updatePostsFromModel()
        
        logger.debug("Background refresh completed for feed: \(self.feedType.identifier)")
        
        // Restore original loading state if it wasn't changed by user action
        if loadingState == originalLoadingState {
            loadingState = .idle
        }
    }
    
    // MARK: - New Posts Tracking
    
    /// Tracks new posts that were added after a refresh
    @MainActor
    private func trackNewPostsAfterRefresh() async {
        logger.debug("🔍 NEW_POSTS_DEBUG: trackNewPostsAfterRefresh called - postsBeforeRefresh.count=\(self.postsBeforeRefresh.count), currentPosts.count=\(self.posts.count), isTrackingNewPosts=\(self.isTrackingNewPosts)")
        
        // Don't show new posts indicator for non-chronological feeds
        guard currentFeedType.isChronological else {
            logger.debug("🔍 NEW_POSTS_DEBUG: Non-chronological feed - skipping new posts tracking")
            clearNewPostsIndicator()
            postsBeforeRefresh.removeAll()
            return
        }
        
        // Prevent multiple calls during the same refresh cycle
        guard !isTrackingNewPosts else {
            logger.debug("🔍 NEW_POSTS_DEBUG: Already tracking new posts - skipping duplicate call")
            return
        }
        
        guard !postsBeforeRefresh.isEmpty else {
            // First load, no previous posts to compare
            logger.debug("🔍 NEW_POSTS_DEBUG: No previous posts to compare - this is first load")
            return
        }
        
        isTrackingNewPosts = true
        
        // FIXED: Instead of comparing IDs, compare timestamps to find genuinely newer posts
        // Get the timestamp of the most recent post before refresh
        // Note: indexedAt is never nil - it's an ATProtocolDate, not optional
        let mostRecentTimestampBefore: Date = (try? postsBeforeRefresh.first?.feedViewPost)?.post.indexedAt.date ?? Date.distantPast
        
        // If we couldn't find any timestamps, fallback to ID comparison
        if mostRecentTimestampBefore == Date.distantPast {
            logger.debug("🔍 NEW_POSTS_DEBUG: No valid timestamps in previous posts, using ID comparison fallback")
            let oldPostIds = Set(postsBeforeRefresh.map { $0.id })
            let topPosts = Array(posts.prefix(20))
            let newPosts = topPosts.filter { !oldPostIds.contains($0.id) }
            
            if !newPosts.isEmpty && newPosts.count < 10 {
                newPostsCount = newPosts.count
                hasNewPosts = true
                newPostsDetectedTime = Date()
                
                // Extract author avatars for the indicator
                var authorAvatars: [String] = []
                var seenAuthors: Set<String> = []
                for post in newPosts.prefix(10) {
                    guard let feedPost = try? post.feedViewPost else { continue }
                    let authorDid = feedPost.post.author.did.didString()
                    if !seenAuthors.contains(authorDid) {
                        seenAuthors.insert(authorDid)
                        if let avatarURL = feedPost.post.author.avatar?.uriString() {
                            authorAvatars.append(avatarURL)
                        }
                        if authorAvatars.count >= 3 { break }
                    }
                }
                newPostsAuthorAvatars = authorAvatars
                
                logger.debug("🔍 NEW_POSTS_DEBUG: (Fallback) Found \(newPosts.count) new posts by ID comparison with \(authorAvatars.count) avatars")
            } else {
                clearNewPostsIndicator()
            }
            postsBeforeRefresh.removeAll()
            isTrackingNewPosts = false
            return
        }
        
        logger.debug("🔍 NEW_POSTS_DEBUG: Most recent post before refresh was at: \(mostRecentTimestampBefore)")
        
        // Find posts that are newer than the most recent one before refresh
        // Also check that they're at the beginning of the feed (first 20 posts)
        let topPosts = Array(posts.prefix(20))
        let newPosts = topPosts.filter { post in
            guard let feedPost = try? post.feedViewPost else { return false }
            return feedPost.post.indexedAt.date > mostRecentTimestampBefore
        }
        
        logger.debug("🔍 NEW_POSTS_DEBUG: Found \(newPosts.count) posts newer than \(mostRecentTimestampBefore)")
        logger.debug("🔍 NEW_POSTS_DEBUG: Current feed has \(self.posts.count) total posts")
        
        if !newPosts.isEmpty {
            logger.debug("🔍 NEW_POSTS_DEBUG: New posts timestamps: \(newPosts.prefix(3).compactMap { try? $0.feedViewPost.post.indexedAt })")
        }
        
        // Only show indicator if:
        // 1. There are new posts
        // 2. They're at the top of the feed (not buried)
        // 3. There's a reasonable number (not the entire feed)
        if !newPosts.isEmpty && newPosts.count < 15 {
            newPostsCount = newPosts.count
            hasNewPosts = true
            newPostsDetectedTime = Date()
            
            logger.debug("🔍 NEW_POSTS_DEBUG: Setting hasNewPosts=true with newPostsCount=\(self.newPostsCount)")
            
            // Extract author avatars from new posts (up to 3 unique avatars)
            var authorAvatars: [String] = []
            var seenAuthors: Set<String> = []
            
            for post in newPosts.prefix(10) { // Check first 10 new posts
                guard let feedPost = try? post.feedViewPost else { continue }
                let authorDid = feedPost.post.author.did.didString()
                if !seenAuthors.contains(authorDid) {
                    seenAuthors.insert(authorDid)
                    if let avatarURL = feedPost.post.author.avatar?.uriString() {
                        authorAvatars.append(avatarURL)
                    }
                    if authorAvatars.count >= 3 {
                        break
                    }
                }
            }
            
            newPostsAuthorAvatars = authorAvatars
            
            logger.debug("✅ NEW_POSTS_DEBUG: Successfully tracked \(self.newPostsCount) new posts with \(authorAvatars.count) unique author avatars - hasNewPosts=\(self.hasNewPosts)")
        } else {
            // No new posts or too many (entire feed changed)
            if newPosts.count >= 15 {
                logger.debug("🔍 NEW_POSTS_DEBUG: Too many new posts (\(newPosts.count)) - likely entire feed changed, not showing indicator")
            } else {
                logger.debug("🔍 NEW_POSTS_DEBUG: No new posts found - clearing indicator")
            }
            clearNewPostsIndicator()
        }
        
        // Clear the before-refresh snapshot and reset tracking flag
        postsBeforeRefresh.removeAll()
        isTrackingNewPosts = false
    }
    
    /// Clears the new posts indicator
    @MainActor
    func clearNewPostsIndicator() {
        logger.debug("🔍 NEW_POSTS_DEBUG: clearNewPostsIndicator called - was hasNewPosts=\(self.hasNewPosts)")
        hasNewPosts = false
        newPostsCount = 0
        newPostsAuthorAvatars.removeAll()
        newPostsDetectedTime = nil
    }
    
    /// Checks if the new posts indicator should be dismissed based on scroll position
    @MainActor
    func shouldDismissNewPostsIndicator(for scrollOffset: CGFloat) -> Bool {
        // Don't dismiss immediately after detecting new posts (give it 2 seconds to show)
        if let detectedTime = newPostsDetectedTime {
            let timeSinceDetection = Date().timeIntervalSince(detectedTime)
            if timeSinceDetection < 2.0 {
                return false
            }
        }
        
        // Only dismiss when scrolled to very top
        return hasNewPosts && scrollOffset <= -50 // More negative = higher up (past the top)
    }
    
    /// Scrolls to top and clears new posts indicator
    @MainActor
    func scrollToTopAndClearNewPosts() {
        clearNewPostsIndicator()
        scrollToTopCallback?()
    }
    
    /// DEBUG: Manually trigger new posts indicator for testing
    @MainActor
    public func debugTriggerNewPostsIndicator(count: Int = 3) {
        logger.debug("🐛 DEBUG: Manually triggering new posts indicator with count=\(count)")
        hasNewPosts = true
        newPostsCount = count
        
        // Use real avatars from current posts if available
        var avatars: [String] = []
        var seenAuthors: Set<String> = []
        for post in posts.prefix(5) {
            guard let feedPost = try? post.feedViewPost else { continue }
            let authorDid = feedPost.post.author.did.didString()
            if !seenAuthors.contains(authorDid) {
                seenAuthors.insert(authorDid)
                if let avatarURL = feedPost.post.author.avatar?.uriString() {
                    avatars.append(avatarURL)
                }
                if avatars.count >= 3 { break }
            }
        }
        
        // Fallback to example avatars if no real ones available
        if avatars.isEmpty {
            avatars = ["https://example.com/avatar1.jpg", "https://example.com/avatar2.jpg"]
        }
        
        newPostsAuthorAvatars = avatars
        logger.debug("🐛 DEBUG: Set hasNewPosts=\(self.hasNewPosts), newPostsCount=\(self.newPostsCount), avatars=\(self.newPostsAuthorAvatars.count)")
        
        // @Observable automatically tracks state changes, no manual notification needed
    }
    
    /// DEBUG: Get current new posts state for debugging
    @MainActor
    func debugGetNewPostsState() -> (hasNewPosts: Bool, count: Int, avatars: Int) {
        return (hasNewPosts: self.hasNewPosts, count: self.newPostsCount, avatars: self.newPostsAuthorAvatars.count)
    }
    
    /// DEBUG: Force refresh and track what happens with real API data
    @MainActor
    func debugForceRefreshAndTrack() async {
        logger.debug("🐛 DEBUG: Force refreshing to test real new posts tracking")
        await refresh()
    }
    
    // MARK: - Scene Phase Coordination (iOS 18+)
    
    /// Handle scene phase transitions coordinated by FeedStateStore
    @MainActor
    func handleScenePhaseTransition(_ phase: ScenePhase) async {
        logger.debug("🎭 Scene phase transition: \(String(describing: phase))")
        
        switch phase {
        case .background:
            await handleScenePhaseBackground()
        case .active:
            await handleScenePhaseActive()
        case .inactive:
            await handleScenePhaseInactive()
        @unknown default:
            logger.debug("⚠️ Unknown scene phase: \(String(describing: phase))")
        }
    }
    
    /// Handle background scene phase - preserve state without disruption
    @MainActor
    private func handleScenePhaseBackground() async {
        logger.debug("📱 Scene entering background - preserving state")
        isAppInBackground = true
        
        // Cancel ongoing operations to prevent crashes
        refreshTask?.cancel()
        loadMoreTask?.cancel()
        updateTask?.cancel()
        autoRefreshTask?.cancel()
        
        // Capture current scroll anchor for restoration
        captureScrollAnchor()
        
        logger.debug("✅ Background state preserved")
    }
    
    /// Handle active scene phase - restore state intelligently
    @MainActor  
    private func handleScenePhaseActive() async {
        logger.debug("📱 Scene becoming active - restoring state")
        isAppInBackground = false
        
        // Restart automatic refresh monitoring
        startAutomaticRefreshMonitoring()
        
        // State restoration is handled by the store's intelligent refresh logic
        // Individual state managers don't need to refresh automatically
        logger.debug("✅ Active state restored (refresh controlled by FeedStateStore)")
    }
    
    /// Handle inactive scene phase - prepare for potential backgrounding
    @MainActor
    private func handleScenePhaseInactive() async {
        logger.debug("📱 Scene becoming inactive - preparing for backgrounding")
        
        // Capture current scroll position proactively
        captureScrollAnchor()
        
        // Don't cancel tasks here as inactive might be temporary (Control Center, etc.)
        logger.debug("✅ Inactive state prepared")
    }
    
    /// Restore UI state without triggering network refresh
    @MainActor
    func restoreUIStateWithoutRefresh() async {
        logger.debug("🔄 Restoring UI state without refresh")
        
        // Ensure we're not in a loading state
        if loadingState == .loading || loadingState == .refreshing {
            loadingState = .idle
        }
        
        // Don't trigger network operations - just ensure UI is consistent
        logger.debug("✅ UI state restored without refresh")
    }
    
    /// Get associated UIKit controller for restoration coordination
    func getAssociatedUIKitController() -> FeedCollectionViewControllerIntegrated? {
        // This would be set by the UIKit controller when it's created
        // Implementation depends on how you want to establish the connection
        return nil // Placeholder - would need proper implementation
    }
    
    // MARK: - User Action Tracking
    
    /// Marks a user-initiated action to prevent unwanted automatic refreshes
    private func markUserAction() {
        lastUserAction = Date()
        isUserInitiatedAction = true
        logger.debug("Marked user action at \(self.lastUserAction)")
        
        // Reset the flag after cooldown period
        Task {
            try? await Task.sleep(nanoseconds: UInt64(userActionCooldownInterval * 1_000_000_000))
            isUserInitiatedAction = false
        }
    }
    
    /// Checks if enough time has passed since last user action to allow automatic operations
    private func canPerformAutomaticAction() -> Bool {
        let timeSinceLastUserAction = Date().timeIntervalSince(lastUserAction)
        return timeSinceLastUserAction > userActionCooldownInterval
    }
    
    // MARK: - Automatic Refresh
    
    /// Starts background task to periodically check and perform automatic refresh
    private func startAutomaticRefreshMonitoring() {
        logger.debug("🔄 Starting automatic refresh monitoring")
        
        autoRefreshTask = Task { @MainActor in
            while !Task.isCancelled {
                // Wait for check interval
                try? await Task.sleep(nanoseconds: UInt64(FeedConstants.automaticRefreshCheckInterval * 1_000_000_000))
                
                guard !Task.isCancelled else { break }
                
                // Check conditions and potentially refresh
                await checkAndPerformAutomaticRefresh()
            }
        }
    }
    
    /// Checks conditions and performs automatic refresh if appropriate
    private func checkAndPerformAutomaticRefresh() async {
        // Don't refresh if app is in background
        guard !isAppInBackground else {
            logger.debug("⏸️ Skipping auto-refresh: app in background")
            return
        }
        
        // Don't refresh if user is actively using the feed
        let timeSinceLastUserAction = Date().timeIntervalSince(lastUserAction)
        guard timeSinceLastUserAction > FeedConstants.userIdleTimeForAutoRefresh else {
            logger.debug("⏸️ Skipping auto-refresh: user active (\(Int(timeSinceLastUserAction))s since last action)")
            return
        }
        
        // Don't refresh if already loading
        guard loadingState == .idle else {
            logger.debug("⏸️ Skipping auto-refresh: already loading")
            return
        }
        
        // Check if enough time has passed since last refresh
        guard feedModel.shouldRefreshFeed(minInterval: FeedConstants.minimumRefreshInterval) else {
            logger.debug("⏸️ Skipping auto-refresh: too soon since last refresh")
            return
        }
        
        // All conditions met - perform background refresh
        logger.info("✅ Performing automatic background refresh (idle for \(Int(timeSinceLastUserAction))s)")
        
        // Use refreshIfNeeded which returns true if refresh was performed
        let didRefresh = await feedModel.refreshIfNeeded(
            fetch: feedType,
            minInterval: FeedConstants.minimumRefreshInterval
        )
        
        if didRefresh {
            logger.info("🔄 Automatic refresh completed successfully")
        }
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
        autoRefreshTask?.cancel()
        
        // Clear references
        refreshTask = nil
        loadMoreTask = nil
        updateTask = nil
        autoRefreshTask = nil
        
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
    
    /// Updates the fetch type while preserving scroll position (user-initiated)
    @MainActor
    func updateFetchType(_ newFetchType: FetchType, preserveScrollPosition: Bool = true) async {
        guard newFetchType.identifier != self.feedType.identifier else {
            logger.debug("Feed type unchanged, no update needed")
            return
        }
        
        logger.debug("Updating feed type from \(self.feedType.identifier) to \(newFetchType.identifier)")
        
        // Mark this as a user-initiated action
        markUserAction()
        
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
    /// Handle state invalidation events (restricted to prevent unwanted refreshes)
    func handleStateInvalidation(_ event: StateInvalidationEvent) async {
        switch event {
        case .feedUpdated(let fetchType):
            // Only refresh if this is the same feed type AND user hasn't acted recently
            if fetchType.identifier == self.feedType.identifier && canPerformAutomaticAction() {
                logger.debug("Received feed update for \(fetchType.identifier), refreshing")
                await backgroundRefresh() // Use background refresh to avoid disrupting UI
            } else {
                logger.debug("Skipping feed update refresh - recent user action or different feed")
            }
            
        case .feedListChanged:
            // Feed list changes shouldn't automatically refresh individual feeds
            // The user will refresh when they want to see changes
            logger.debug("Feed list changed, but skipping automatic refresh")
            
        case .accountSwitched:
            // Account switches are critical - always clear and reload
            logger.debug("Account switched, clearing and reloading feed")
            posts.removeAll()
            viewModelCache.removeAll()
            hasReachedEnd = false
            loadingState = .idle // Reset loading state
            errorMessage = nil // Clear any errors
            markUserAction() // Mark as user action since account switch is user-initiated
            
            // Use system flag to bypass user-initiated checks
            await loadInitialDataWithSystemFlag()
            
        case .authenticationCompleted:
            // When authentication completes, load initial data if we don't have any
            if posts.isEmpty {
                logger.debug("Authentication completed, loading initial feed data")
                markUserAction() // Mark as user action since auth completion is user-initiated
                await loadInitialData()
            }
            
        case .postCreated, .replyCreated:
            // Don't automatically refresh for new posts - let user pull to refresh
            // This prevents disrupting scroll position when user returns from post creation
            logger.debug("New post created, but skipping automatic refresh to preserve scroll position")
            
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
