import Observation
import OSLog
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
final class FeedModel: StateInvalidationSubscriber {
  // MARK: - Properties

  private let logger = Logger(OSLog.feedModel)
  let feedManager: FeedManager
  private let appState: AppState
  private let feedTuner = FeedTuner()

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
    
    // Subscribe to state invalidation events
    appState.stateInvalidationBus.subscribe(self)
    
    // Subscribe to social graph changes (mute/block/follow changes)
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("UserGraphChanged"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        await self?.handleSocialGraphChange()
      }
    }
  }
  
  deinit {
    // Unsubscribe from state invalidation events
    appState.stateInvalidationBus.unsubscribe(self)
    
    // Remove NotificationCenter observers
    NotificationCenter.default.removeObserver(self)
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
      logger.warning("🔥 FEED MODEL: No AT Proto client available - cannot load feed data for \(fetch.identifier)")
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

      // Process posts using FeedTuner (following React Native pattern)
      logger.debug("🔍 About to call feedTuner.tune() with \(fetchedPosts.count) posts")
      let filterSettings = await getFilterSettings()
      let slices = feedTuner.tune(fetchedPosts, filterSettings: filterSettings)
      logger.debug("🔍 FeedTuner returned \(slices.count) slices")
      let newPosts = slices.map { slice in
        // Convert to CachedFeedViewPost with thread metadata preserved
        return CachedFeedViewPost(from: slice, feedType: fetch.identifier)
      }

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
      
      // Update widget data
      FeedWidgetDataProvider.shared.updateWidgetData(from: newPosts, feedType: fetch)
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
  func setCachedFeed(_ cachedPosts: [AppBskyFeedDefs.FeedViewPost], cursor: String?) async {
    // Process posts using FeedTuner for consistency
    let filterSettings = await getFilterSettings()
    let slices = feedTuner.tune(cachedPosts, filterSettings: filterSettings)
    await MainActor.run {
      self.posts = slices.map { slice in
        return CachedFeedViewPost(from: slice, feedType: "timeline")
      }
      self.cursor = cursor
      self.hasMore = cursor != nil
      
      // Update widget data for cached feed
      FeedWidgetDataProvider.shared.updateWidgetData(from: self.posts, feedType: lastFeedType)
    }
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

      // Process new posts using FeedTuner
      let filterSettings = await getFilterSettings()
      let newSlices = feedTuner.tune(fetchedPosts, filterSettings: filterSettings)
      let newCachedPosts = newSlices.map { slice in
        return CachedFeedViewPost(from: slice, feedType: fetchType.identifier)
      }
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
  private func updatePosts(
    _ filteredPosts: [CachedFeedViewPost], strategy: FeedLoadStrategy, forceRefresh: Bool
  ) {
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

  // Helper function to deduplicate posts
  @MainActor
  private func deduplicatePosts(_ postsToFilter: [CachedFeedViewPost]) -> [CachedFeedViewPost] {
    // Set to collect all parent post URIs from replies
    var parentPostURIs = Set<String>()

    // First pass: collect all parent post URIs
    for cachedPost in postsToFilter {
      if let reply = cachedPost.feedViewPost.reply {
        switch reply.parent {
        case .appBskyFeedDefsPostView(let parentView):
          parentPostURIs.insert(parentView.uri.uriString())
        default:
          break
        }
      }
    }

    // Second pass: filter out standalone posts that are also parents in replies
    return postsToFilter.filter { cachedPost in
      let post = cachedPost.feedViewPost
      let postURI = post.post.uri.uriString()

      // If this post's URI is in the parent set AND it's not a reply itself, filter it out
      if parentPostURIs.contains(postURI) && post.reply == nil {
        return false
      }

      // Keep all other posts
      return true
    }
  }

  // Filter the current posts and return filtered posts, applying deduplication if active
  @MainActor
  func applyFilters(withSettings filterSettings: FeedFilterSettings) -> [CachedFeedViewPost] {
    let activeFilters = filterSettings.activeFilters
    let shouldDeduplicate = activeFilters.contains { $0.name == "Hide Duplicate Posts" }

    // Apply standard filters first (excluding the deduplication filter itself)
    let standardFilteredPosts = posts.filter { cachedPost in
      let post = cachedPost.feedViewPost
      for filter in activeFilters {
        // Skip the deduplication filter here, it's applied separately
        if filter.name == "Hide Duplicate Posts" { continue }

        if !filter.filterBlock(post) {
          return false
        }
      }
      return true
    }

    // Apply deduplication if the filter is active
    if shouldDeduplicate {
      return deduplicatePosts(standardFilteredPosts)
    } else {
      return standardFilteredPosts
    }
  }

  // Process and filter posts when loading, applying deduplication if active
  @MainActor
  func processAndFilterPosts(
    fetchedPosts: [AppBskyFeedDefs.FeedViewPost],
    newCursor: String?,
    filterSettings: FeedFilterSettings
  ) async -> [CachedFeedViewPost] {
    // First process posts using FeedTuner (following React Native pattern)
    logger.debug("🔍 processAndFilterPosts: About to call feedTuner.tune() with \(fetchedPosts.count) posts")
    let tunerSettings = await getFilterSettings()
    let slices = feedTuner.tune(fetchedPosts, filterSettings: tunerSettings)
    logger.debug("🔍 processAndFilterPosts: FeedTuner returned \(slices.count) slices")
    
    // Convert slices to cached posts
    let newCachedPosts = slices.map { slice in
      return CachedFeedViewPost(from: slice, feedType: "timeline")
    }

    let activeFilters = filterSettings.activeFilters
    let shouldDeduplicate = activeFilters.contains { $0.name == "Hide Duplicate Posts" }

    // Apply standard filters first (excluding the deduplication filter itself)
    let standardFilteredPosts = newCachedPosts.filter { cachedPost in
      let post = cachedPost.feedViewPost
      for filter in activeFilters {
        // Skip the deduplication filter here, it's applied separately
        if filter.name == "Hide Duplicate Posts" { continue }

        if !filter.filterBlock(post) {
          return false
        }
      }
      return true
    }

    // Apply deduplication if the filter is active
    if shouldDeduplicate {
      return deduplicatePosts(standardFilteredPosts)
    } else {
      return standardFilteredPosts
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
      logger.warning("🔥 FEED MODEL: No AT Proto client available - cannot load feed data for \(fetch.identifier)")
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

      // Process and filter posts (this now includes deduplication logic)
      let filteredPosts = await processAndFilterPosts(
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

      // Process and filter posts (this now includes deduplication logic)
      let filteredNewPosts = await processAndFilterPosts(
        fetchedPosts: fetchedPosts,
        newCursor: newCursor,
        filterSettings: filterSettings
      )

      // Filter out duplicates based on ID before appending
      let existingIds = Set(posts.map { $0.id })
      let uniqueNewPosts = filteredNewPosts.filter { !existingIds.contains($0.id) }

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
  
  // MARK: - State Invalidation Handling
  
  /// Handle state invalidation events from the central event bus
  func handleStateInvalidation(_ event: StateInvalidationEvent) async {
      logger.debug("Handling state invalidation event: \(String(describing: event))")
    
    switch event {
    case .postCreated(let post):
      // Add new post optimistically to timeline feeds
      if lastFeedType == .timeline {
        await addPostOptimistically(post)
      }
      
    case .replyCreated(let reply, let parentUri):
      // For timeline feeds, we might want to show the reply
      if lastFeedType == .timeline {
        // Check if the parent post is visible in the current feed
        let parentVisible = await MainActor.run {
          posts.contains { cachedPost in
            cachedPost.feedViewPost.post.uri.uriString() == parentUri
          }
        }
        
        if parentVisible {
          // If parent is visible, refresh to show the reply in context
          await refreshFeedAfterEvent()
        }
        // Otherwise, ignore - the reply will appear when timeline refreshes naturally
      }
      
    case .accountSwitched:
      // Clear and reload feed when account is switched
      await clearAndReloadFeed()
      
    case .authenticationCompleted:
      // Authentication completed - reload feed if it's empty
        Task { @MainActor in

        if posts.isEmpty {
                await clearAndReloadFeed()
            }
      }
      
    case .feedUpdated(let fetchType):
      // Refresh if this is the same feed type
      if lastFeedType.identifier == fetchType.identifier {
        await refreshFeedAfterEvent()
      }
      
    case .profileUpdated:
      // Refresh if this is a profile feed
      if case .author = lastFeedType {
        await refreshFeedAfterEvent()
      }
      
    case .threadUpdated:
      // Thread updates don't typically affect feed views
      break
      
    case .chatMessageReceived, .notificationsUpdated:
      // These don't affect feed content
      break
      
    case .postLiked, .postUnliked, .postReposted, .postUnreposted:
      // These are handled by PostShadowManager, no feed refresh needed
      break
    case .feedListChanged:
      // Feed list changes don't affect individual feed content,
      // this is handled at the feeds management level
      break
    }
  }
  
  /// Refresh the feed in response to a state invalidation event
  @MainActor
  private func refreshFeedAfterEvent() async {
    // Only refresh if we're not already loading
    guard !isLoading && !isLoadingMore else {
      return
    }
    
    // Use background refresh to avoid disrupting the user if we have posts,
    // otherwise do a full refresh to populate empty feed
    let strategy: FeedLoadStrategy = posts.isEmpty ? .fullRefresh : .backgroundRefresh
    await loadFeed(fetch: lastFeedType, forceRefresh: true, strategy: strategy)
  }
  
  /// Clear the current feed and reload it completely
  @MainActor
  private func clearAndReloadFeed() async {
    // Clear current posts
    posts.removeAll()
    cursor = nil
    hasMore = true
    error = nil
    
    // Reload the feed
    await loadFeed(fetch: lastFeedType, forceRefresh: true, strategy: .fullRefresh)
  }
  
  /// Add a new post optimistically to the feed
  @MainActor
  private func addPostOptimistically(_ post: AppBskyFeedDefs.PostView) async {
    logger.info("Adding post optimistically to feed: \(post.uri.uriString())")
    
    // Create a FeedViewPost wrapper
    let feedViewPost = AppBskyFeedDefs.FeedViewPost(
      post: post,
      reply: nil,
      reason: nil,
      feedContext: nil,
      reqId: nil
    )
    
    // Create a cached post with temporary flag
    var cachedPost = CachedFeedViewPost(from: feedViewPost, feedType: lastFeedType.identifier)
    cachedPost.isTemporary = true
    
    // Insert at the beginning of the feed
    posts.insert(cachedPost, at: 0)
    
    // Update post shadow for the new post
    await appState.postShadowManager.updateShadow(forUri: post.uri.uriString()) { shadow in
      // Mark as created by current user
      shadow.isOptimistic = true
    }
    
    // Schedule a background refresh to get the real post data
    Task {
      try? await Task.sleep(for: .seconds(1))
      await refreshFeedAfterEvent()
    }
  }
  
  /// Handle social graph changes (mute/block/follow state changes)
  @MainActor
  private func handleSocialGraphChange() async {
    logger.debug("Social graph changed, refiltering feed content")
    
    // Don't refresh if we don't have posts yet
    guard !posts.isEmpty else { return }
    
    // Reapply filters to existing posts using updated mute cache
    let filterSettings = await getFilterSettings()
    let tunedSlices = feedTuner.tune(posts.map { $0.feedViewPost }, filterSettings: filterSettings)
    let reprocessedPosts = tunedSlices.map { slice in
      return CachedFeedViewPost(from: slice, feedType: lastFeedType.identifier)
    }
    
    // Only update if the filtered content actually changed
    let currentIds = Set(posts.map { $0.id })
    let newIds = Set(reprocessedPosts.map { $0.id })
    
    if currentIds != newIds {
      posts = reprocessedPosts
      logger.debug("Feed content updated after social graph change: \(currentIds.count) -> \(newIds.count) posts")
    }
  }
  
  // MARK: - Helper Methods
  
  /// Get current feed filter settings from preferences and app settings
  private func getFilterSettings() async -> FeedTunerSettings {
    do {
      let preferences = try await appState.preferencesManager.getPreferences()
      let feedPref = preferences.feedViewPref
      
      // Get muted and blocked users from GraphManager
      let mutedUsers = await appState.graphManager.muteCache
      let blockedUsers = await appState.graphManager.blockCache
      
      return FeedTunerSettings(
        hideReplies: feedPref?.hideReplies ?? false,
        hideRepliesByUnfollowed: feedPref?.hideRepliesByUnfollowed ?? false,
        hideReposts: feedPref?.hideReposts ?? false,
        hideQuotePosts: feedPref?.hideQuotePosts ?? false,
        hideNonPreferredLanguages: appState.appSettings.hideNonPreferredLanguages,
        preferredLanguages: appState.appSettings.contentLanguages,
        mutedUsers: mutedUsers,
        blockedUsers: blockedUsers
      )
    } catch {
      logger.warning("Failed to get feed preferences, using defaults: \(error)")
      return .default
    }
  }
}
