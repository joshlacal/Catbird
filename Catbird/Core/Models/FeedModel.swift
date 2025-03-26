import Observation
import Petrel
import SwiftData
import SwiftUI

/// Defines different strategies for loading feed data
enum FeedLoadStrategy {
    /// Complete refresh - replaces all posts
    case fullRefresh
    /// Background refresh - loads new data but preserves UI state until complete
    case backgroundRefresh
    /// Only load if necessary (e.g., empty feed)
    case loadIfNeeded
}

/// Observable model for managing feed data and state
@Observable
final class FeedModel {
    // MARK: - Properties
    
    let feedManager: FeedManager
    private let appState: AppState
    
    @MainActor var posts: [CachedFeedViewPost] = []
    
    // State tracking
    @MainActor private(set) var isLoading = false
    @MainActor private(set) var isLoadingMore = false
    @MainActor private(set) var isBackgroundRefreshing = false
    @MainActor private(set) var hasMore = true
    @MainActor private(set) var error: Error?
    @MainActor private(set) var lastRefreshTime = Date.distantPast
    
    // Pagination
    @MainActor private var cursor: String?
    
    // Feed type tracking
    private(set) var lastFeedType: FetchType
    
    // MARK: - Initialization
    
    init(feedManager: FeedManager, appState: AppState) {
        self.feedManager = feedManager
        self.appState = appState
        self.lastFeedType = feedManager.fetchType
    }
    
    // MARK: - Feed Loading
    
    @MainActor
    func loadFeed(
        fetch: FetchType,
        forceRefresh: Bool = true,
        strategy: FeedLoadStrategy = .fullRefresh
    ) async {
        self.lastFeedType = fetch
        feedManager.updateFetchType(fetch)
        
        if isLoading || (strategy == .loadIfNeeded && !posts.isEmpty) {
            return
        }
        
        if strategy == .backgroundRefresh {
            isBackgroundRefreshing = true
        } else {
            isLoading = true
        }
        
        error = nil
        
        guard appState.atProtoClient != nil else {
            if strategy == .backgroundRefresh {
                isBackgroundRefreshing = false
            } else {
                isLoading = false
            }
            return
        }
        
        do {
            let (fetchedPosts, newCursor) = try await feedManager.fetchFeed(fetchType: fetch, cursor: nil)
            
            appState.storePrefetchedFeed(fetchedPosts, cursor: newCursor, for: fetch)
            
            let newPosts = fetchedPosts.map { CachedFeedViewPost(feedViewPost: $0) }
            
            if strategy == .backgroundRefresh && !posts.isEmpty {
                let existingIds = Set(posts.map { $0.id })
                let newIds = Set(newPosts.map { $0.id })
                let uniqueNewPostCount = newIds.subtracting(existingIds).count
                
                if uniqueNewPostCount > posts.count / 10 || forceRefresh {
                    self.posts = newPosts
                }
            } else {
                self.posts = newPosts
            }
            
            self.cursor = newCursor
            self.hasMore = newCursor != nil
            self.lastRefreshTime = Date()
            
            await refreshPostShadows(fetchedPosts)
        } catch {
            self.error = error
        }
        
        if strategy == .backgroundRefresh {
            isBackgroundRefreshing = false
        } else {
            isLoading = false
        }
    }
    
    @MainActor
    func setCachedFeed(_ cachedPosts: [AppBskyFeedDefs.FeedViewPost], cursor: String?) {
        self.posts = cachedPosts.map { CachedFeedViewPost(feedViewPost: $0) }
        self.cursor = cursor
        self.hasMore = cursor != nil
    }
    
    @MainActor
    func loadMore() async {
        guard !isLoading && !isLoadingMore && hasMore && cursor != nil else { return }
        
        isLoadingMore = true
        
        guard appState.atProtoClient != nil else {
            isLoadingMore = false
            return
        }
        
        let fetchType = feedManager.fetchType
        
        do {
            let (fetchedPosts, newCursor) = try await feedManager.fetchFeed(
                fetchType: fetchType,
                cursor: cursor
            )
            
            let newCachedPosts = fetchedPosts.map { CachedFeedViewPost(feedViewPost: $0) }
            let existingIds = Set(posts.map { $0.id })
            let uniqueNewPosts = newCachedPosts.filter { !existingIds.contains($0.id) }
            
            self.posts.append(contentsOf: uniqueNewPosts)
            self.cursor = newCursor
            self.hasMore = newCursor != nil
            
            await refreshPostShadows(fetchedPosts)
        } catch {
            self.error = error
        }
        
        isLoadingMore = false
    }
    
    func prefetchNextPage() async {
        let cursorValue = await MainActor.run { cursor }
        let shouldPrefetch = await MainActor.run { hasMore && !isLoadingMore && !isLoading }
        
        guard let cursor = cursorValue, shouldPrefetch else { return }
        
        let fetchType = feedManager.fetchType
        
        do {
            let (fetchedPosts, _) = try await feedManager.fetchFeed(
                fetchType: fetchType,
                cursor: cursor
            )
            await refreshPostShadows(fetchedPosts)
        } catch {
            // Ignore prefetch errors
        }
    }
    
    private func refreshPostShadows(_ posts: [AppBskyFeedDefs.FeedViewPost]) async {
        for post in posts {
            await appState.postShadowManager.updateShadow(forUri: post.post.uri.uriString()) { shadow in
                if let like = post.post.viewer?.like {
                    shadow.likeUri = like
                }
                if let repost = post.post.viewer?.repost {
                    shadow.repostUri = repost
                }
            }
        }
    }
    
    @MainActor
    func shouldRefreshFeed(minInterval: TimeInterval = 300) -> Bool {
        return Date().timeIntervalSince(lastRefreshTime) > minInterval
    }
    
    @MainActor
    func refreshIfNeeded(fetch: FetchType, minInterval: TimeInterval = 300) async -> Bool {
        if shouldRefreshFeed(minInterval: minInterval) {
            await loadFeed(
                fetch: fetch,
                forceRefresh: false,
                strategy: FeedLoadStrategy.backgroundRefresh
            )
            return true
        }
        return false
    }
    
    // MARK: - Helper Methods for MainActor properties
    
    @MainActor
    private func setLastFeedType(_ type: FetchType) {
        lastFeedType = type
    }
    
    @MainActor
    private func setIsLoading(_ value: Bool) {
        isLoading = value
    }
    
    @MainActor
    private func setIsLoadingMore(_ value: Bool) {
        isLoadingMore = value
    }
    
    @MainActor
    private func setIsBackgroundRefreshing(_ value: Bool) {
        isBackgroundRefreshing = value
    }
    
    @MainActor
    private func setError(_ error: Error?) {
        self.error = error
    }
    
    @MainActor
    private func setCursor(_ cursor: String?) {
        self.cursor = cursor
    }
    
    @MainActor
    private func setHasMore(_ value: Bool) {
        hasMore = value
    }
    
    @MainActor
    private func setLastRefreshTime(_ time: Date) {
        lastRefreshTime = time
    }
    
    @MainActor
    private func appendPosts(_ newPosts: [CachedFeedViewPost]) {
        posts.append(contentsOf: newPosts)
    }
    
    @MainActor
    private func updatePosts(_ filteredPosts: [CachedFeedViewPost], strategy: FeedLoadStrategy, forceRefresh: Bool) {
        if strategy == .backgroundRefresh && !posts.isEmpty {
            let existingIds = Set(posts.map { $0.id })
            let newIds = Set(filteredPosts.map { $0.id })
            let uniqueNewPostCount = newIds.subtracting(existingIds).count
            
            if uniqueNewPostCount > posts.count / 10 || forceRefresh {
                posts = filteredPosts
            }
        } else {
            posts = filteredPosts
        }
    }
    
    // MARK: - Feed Filtering Extensions
    
    // Filter the current posts and return filtered posts
    @MainActor
    func applyFilters(withSettings filterSettings: FeedFilterSettings) -> [CachedFeedViewPost] {
        let activeFilters = filterSettings.activeFilters
        
        // If no active filters, return all posts
        if activeFilters.isEmpty {
            return posts
        }
        
        // Apply filters to posts
        return posts.filter { cachedPost in
            let post = cachedPost.feedViewPost
            
            // Post passes if it passes ALL active filters
            for filter in activeFilters {
                if !filter.filterBlock(post) {
                    return false
                }
            }
            
            return true
        }
    }
    
    // Process and filter posts when loading
    @MainActor
    func processAndFilterPosts(
        fetchedPosts: [AppBskyFeedDefs.FeedViewPost],
        newCursor: String?,
        filterSettings: FeedFilterSettings
    ) -> [CachedFeedViewPost] {
        // First convert to cached posts
        let newCachedPosts = fetchedPosts.map { CachedFeedViewPost(feedViewPost: $0) }
        
        // If no active filters, return all posts
        if filterSettings.activeFilters.isEmpty {
            return newCachedPosts
        }
        
        // Apply filters
        return newCachedPosts.filter { cachedPost in
            let post = cachedPost.feedViewPost
            
            // Post passes if it passes ALL active filters
            for filter in filterSettings.activeFilters {
                if !filter.filterBlock(post) {
                    return false
                }
            }
            
            return true
        }
    }
    
    // Enhanced loadFeed method with filtering capabilities
    @MainActor
    func loadFeedWithFiltering(
        fetch: FetchType,
        forceRefresh: Bool = true,
        strategy: FeedLoadStrategy = .fullRefresh,
        filterSettings: FeedFilterSettings
    ) async {
        // Update feed type
        lastFeedType = fetch
        feedManager.updateFetchType(fetch)
        
        // Check if we should skip loading
        if isLoading || (strategy == .loadIfNeeded && !posts.isEmpty) {
            return
        }
        
        // Set loading state
        if strategy == .backgroundRefresh {
            isBackgroundRefreshing = true
        } else {
            isLoading = true
        }
        
        // Reset error state
        error = nil
        
        // Check for client availability
        guard let client = appState.atProtoClient else {
            if strategy == .backgroundRefresh {
                isBackgroundRefreshing = false
            } else {
                isLoading = false
            }
            return
        }
        
        do {
            // Fetch posts
            let (fetchedPosts, newCursor) = try await feedManager.fetchFeed(fetchType: fetch, cursor: nil)
            
            // Store in prefetch cache
            appState.storePrefetchedFeed(fetchedPosts, cursor: newCursor, for: fetch)
            
            // Process and filter posts
            let filteredPosts = processAndFilterPosts(
                fetchedPosts: fetchedPosts,
                newCursor: newCursor,
                filterSettings: filterSettings
            )
            
            // Update posts list
            updatePosts(filteredPosts, strategy: strategy, forceRefresh: forceRefresh)
            
            // Update pagination state
            cursor = newCursor
            hasMore = newCursor != nil
            lastRefreshTime = Date()
            
            // Update shadows
            await refreshPostShadows(fetchedPosts)
        } catch {
            // Handle errors
            self.error = error
        }
        
        // Reset loading state
        if strategy == .backgroundRefresh {
            isBackgroundRefreshing = false
        } else {
            isLoading = false
        }
    }
    
    // Enhanced loadMore method with filtering capabilities
    @MainActor
    func loadMoreWithFiltering(filterSettings: FeedFilterSettings) async {
        // Check if we can load more
        guard !isLoading && !isLoadingMore && hasMore && cursor != nil else {
            return
        }
        
        // Set loading state
        isLoadingMore = true
        
        // Check for client availability
        guard appState.atProtoClient != nil else {
            isLoadingMore = false
            return
        }
        
        // Get current fetch type
        let fetchType = feedManager.fetchType
        
        do {
            // Get current cursor
            let currentCursor = cursor
            
            // Fetch more posts
            let (fetchedPosts, newCursor) = try await feedManager.fetchFeed(
                fetchType: fetchType,
                cursor: currentCursor
            )
            
            // Process and filter posts
            let filteredPosts = processAndFilterPosts(
                fetchedPosts: fetchedPosts,
                newCursor: newCursor,
                filterSettings: filterSettings
            )
            
            // Filter out duplicates
            let existingIds = Set(posts.map { $0.id })
            let uniqueNewPosts = filteredPosts.filter { !existingIds.contains($0.id) }
            
            // Append unique posts
            posts.append(contentsOf: uniqueNewPosts)
            
            // Update pagination state
            cursor = newCursor
            hasMore = newCursor != nil
            
            // Update shadows
            await refreshPostShadows(fetchedPosts)
        } catch {
            // Handle errors
            self.error = error
        }
        
        // Reset loading state
        isLoadingMore = false
    }
}
