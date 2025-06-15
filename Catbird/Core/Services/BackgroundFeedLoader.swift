import Foundation
import Petrel
import os

// MARK: - Background Feed Loader

/// Manages background loading of feed content without disrupting user experience
@MainActor
final class BackgroundFeedLoader: ObservableObject {
  private let logger = Logger(subsystem: "blue.catbird", category: "BackgroundFeedLoader")
  
  // MARK: - Pending Content State
  
  struct PendingContent {
    let posts: [CachedFeedViewPost]
    let timestamp: Date
    let fetchType: FetchType
    let isFromRefresh: Bool
    
    var age: TimeInterval {
      Date().timeIntervalSince(timestamp)
    }
    
    var isStale: Bool {
      age > 300 // 5 minutes
    }
  }
  
  // MARK: - Properties
  
  private var pendingContentByFeed: [String: PendingContent] = [:]
  private var backgroundLoadTasks: [String: Task<Void, Never>] = [:]
  private let appState: AppState
  
  // MARK: - Published Properties
  
  @Published private(set) var pendingPostCounts: [String: Int] = [:]
  @Published private(set) var isBackgroundLoading: [String: Bool] = [:]
  
  // MARK: - Initialization
  
  init(appState: AppState) {
    self.appState = appState
  }
  
  // MARK: - Public Methods
  
  /// Start background loading for a feed without updating the UI
  func startBackgroundLoad(
    for fetchType: FetchType,
    currentPosts: [CachedFeedViewPost],
    forceRefresh: Bool = false
  ) {
    let feedId = fetchType.identifier
    
    // Cancel existing background load for this feed
    backgroundLoadTasks[feedId]?.cancel()
    
    // Mark as loading
    isBackgroundLoading[feedId] = true
    
    // Start background load task
    backgroundLoadTasks[feedId] = Task { @MainActor in
      defer {
        isBackgroundLoading[feedId] = false
        backgroundLoadTasks[feedId] = nil
      }
      
      await performBackgroundLoad(
        fetchType: fetchType,
        currentPosts: currentPosts,
        forceRefresh: forceRefresh
      )
    }
  }
  
  /// Get pending content for a feed
  func getPendingContent(for fetchType: FetchType) -> PendingContent? {
    let feedId = fetchType.identifier
    let pending = pendingContentByFeed[feedId]
    
    // Remove stale content
    if let pending = pending, pending.isStale {
      clearPendingContent(for: fetchType)
      return nil
    }
    
    return pending
  }
  
  /// Apply pending content and clear it
  func applyPendingContent(for fetchType: FetchType) -> [CachedFeedViewPost]? {
    let feedId = fetchType.identifier
    guard let pending = pendingContentByFeed[feedId], !pending.isStale else {
      clearPendingContent(for: fetchType)
      return nil
    }
    
    // Clear pending state
    clearPendingContent(for: fetchType)
    
    logger.info("Applied pending content for \(feedId): \(pending.posts.count) posts")
    return pending.posts
  }
  
  /// Get count of pending new posts
  func getPendingPostCount(for fetchType: FetchType) -> Int {
    pendingPostCounts[fetchType.identifier] ?? 0
  }
  
  /// Check if there is pending content available
  func hasPendingContent(for fetchType: FetchType) -> Bool {
    getPendingPostCount(for: fetchType) > 0
  }
  
  /// Clear pending content for a feed
  func clearPendingContent(for fetchType: FetchType) {
    let feedId = fetchType.identifier
    pendingContentByFeed.removeValue(forKey: feedId)
    pendingPostCounts.removeValue(forKey: feedId)
    logger.debug("Cleared pending content for \(feedId)")
  }
  
  /// Cancel background loading for a feed
  func cancelBackgroundLoad(for fetchType: FetchType) {
    let feedId = fetchType.identifier
    backgroundLoadTasks[feedId]?.cancel()
    backgroundLoadTasks[feedId] = nil
    isBackgroundLoading[feedId] = false
    logger.debug("Cancelled background load for \(feedId)")
  }
  
  /// Cancel all background loading
  func cancelAllBackgroundLoads() {
    for task in backgroundLoadTasks.values {
      task.cancel()
    }
    backgroundLoadTasks.removeAll()
    isBackgroundLoading.removeAll()
    logger.debug("Cancelled all background loads")
  }
  
  /// Check if a feed should be refreshed based on age and user activity
  func shouldRefreshFeed(
    fetchType: FetchType,
    minimumInterval: TimeInterval = 300, // 5 minutes
    userActivity: UserActivityTracker
  ) -> Bool {
    let feedModel = FeedModelContainer.shared.getModel(for: fetchType, appState: appState)
    
    // Check if enough time has passed since last refresh
    let timeSinceRefresh = Date().timeIntervalSince(feedModel.lastRefreshTime)
    if timeSinceRefresh < minimumInterval {
      return false
    }
    
    // Check user activity - don't auto-refresh if user is actively reading
    if userActivity.isActivelyReading {
      return false
    }
    
    // Check if user has been idle enough to warrant a background refresh
    if userActivity.timeSinceLastInteraction < 30 { // 30 seconds
      return false
    }
    
    return true
  }
  
  // MARK: - Private Methods
  
  private func performBackgroundLoad(
    fetchType: FetchType,
    currentPosts: [CachedFeedViewPost],
    forceRefresh: Bool
  ) async {
    let feedId = fetchType.identifier
    
      logger.debug("Starting background load for \(feedId)")
      
      // Get or create feed model
      let feedModel = FeedModelContainer.shared.getModel(for: fetchType, appState: appState)
      
      // Perform the load
      await feedModel.loadFeedWithFiltering(
        fetch: fetchType,
        forceRefresh: forceRefresh,
        strategy: .fullRefresh,
        filterSettings: appState.feedFilterSettings
      )
      
      // Get the new posts
      let newPosts = feedModel.applyFilters(withSettings: appState.feedFilterSettings)
      
      // Compare with current posts to determine what's new
      let (pendingPosts, newPostCount) = calculatePendingContent(
        currentPosts: currentPosts,
        newPosts: newPosts
      )
      
      // Store pending content if there are changes
      if newPostCount > 0 {
        let pendingContent = PendingContent(
          posts: pendingPosts,
          timestamp: Date(),
          fetchType: fetchType,
          isFromRefresh: forceRefresh
        )
        
        pendingContentByFeed[feedId] = pendingContent
        pendingPostCounts[feedId] = newPostCount
        
        logger.info("Background load completed for \(feedId): \(newPostCount) new posts available")
      } else {
        // No new content, clear any existing pending state
        clearPendingContent(for: fetchType)
        logger.debug("Background load completed for \(feedId): no new content")
      }
      
  }
  
  private func calculatePendingContent(
    currentPosts: [CachedFeedViewPost],
    newPosts: [CachedFeedViewPost]
  ) -> (pendingPosts: [CachedFeedViewPost], newPostCount: Int) {
    // Create sets of current post IDs for efficient lookup
    let currentPostIds = Set(currentPosts.map { $0.id })
    
    // Find truly new posts (not in current set)
    let actualNewPosts = newPosts.filter { !currentPostIds.contains($0.id) }
    
    // Also check if the order has changed significantly at the top
    let orderChanged = !currentPosts.isEmpty && 
                      !newPosts.isEmpty && 
                      currentPosts.first?.id != newPosts.first?.id
    
    if !actualNewPosts.isEmpty {
      // We have genuinely new posts
      return (newPosts, actualNewPosts.count)
    } else if orderChanged && newPosts.count >= currentPosts.count {
      // Order changed at top, treat as 1 "new" item for indicator purposes
      return (newPosts, 1)
    } else {
      // No meaningful changes
      return (newPosts, 0)
    }
  }
}

// MARK: - Background Load Strategy

extension BackgroundFeedLoader {
  enum LoadStrategy {
    case immediate
    case delayed(TimeInterval)
    case userTriggered
    case periodic
  }
  
  /// Start background load with a specific strategy
  func startBackgroundLoad(
    for fetchType: FetchType,
    currentPosts: [CachedFeedViewPost],
    strategy: LoadStrategy,
    forceRefresh: Bool = false
  ) {
    switch strategy {
    case .immediate:
      startBackgroundLoad(for: fetchType, currentPosts: currentPosts, forceRefresh: forceRefresh)
      
    case .delayed(let delay):
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(delay))
        if !Task.isCancelled {
          startBackgroundLoad(for: fetchType, currentPosts: currentPosts, forceRefresh: forceRefresh)
        }
      }
      
    case .userTriggered:
      startBackgroundLoad(for: fetchType, currentPosts: currentPosts, forceRefresh: true)
      
    case .periodic:
      // Start periodic background loading (could be enhanced with timer)
      startBackgroundLoad(for: fetchType, currentPosts: currentPosts, forceRefresh: forceRefresh)
    }
  }
}
