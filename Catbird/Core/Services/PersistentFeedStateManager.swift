import Foundation
import OSLog
import SwiftData
import Petrel

// MARK: - SwiftData Models for Persistence

@Model
final class PersistedScrollPosition {
  var postId: String
  var offsetFromPost: Double
  var timestamp: Date
  var feedIdentifier: String
  
  var isStale: Bool {
    Date().timeIntervalSince(timestamp) > 1800 // 30 minutes
  }
  
  init(postId: String, offsetFromPost: CGFloat, feedIdentifier: String) {
    self.postId = postId
    self.offsetFromPost = Double(offsetFromPost)
    self.timestamp = Date()
    self.feedIdentifier = feedIdentifier
  }
}

@Model
final class PersistedFeedState {
  var feedIdentifier: String
  var timestamp: Date
  var totalPostCount: Int
  var cursor: String?
  
  // Store post IDs for quick reference
  var postIds: [String]
  
  var isStale: Bool {
    Date().timeIntervalSince(timestamp) > 1800 // 30 minutes
  }
  
  var isRecentlyFresh: Bool {
    Date().timeIntervalSince(timestamp) < 300 // 5 minutes
  }
  
  init(feedIdentifier: String, postIds: [String], cursor: String?) {
    self.feedIdentifier = feedIdentifier
    self.cursor = cursor
    self.postIds = postIds
    self.timestamp = Date()
    self.totalPostCount = postIds.count
  }
}

@Model
final class FeedContinuityInfo {
  var feedIdentifier: String
  var hasNewContent: Bool
  var lastKnownTopPostId: String?
  var newPostCount: Int
  var gapDetected: Bool
  var lastRefreshTime: Date
  
  init(feedIdentifier: String, hasNewContent: Bool = false, lastKnownTopPostId: String? = nil, newPostCount: Int = 0, gapDetected: Bool = false) {
    self.feedIdentifier = feedIdentifier
    self.hasNewContent = hasNewContent
    self.lastKnownTopPostId = lastKnownTopPostId
    self.newPostCount = newPostCount
    self.gapDetected = gapDetected
    self.lastRefreshTime = Date()
  }
}

// MARK: - Persistent Feed State Manager

/// Manages persistent storage of feed scroll positions and cached data using SwiftData
/// This is a ModelActor to ensure thread-safe database access off the main thread.
@ModelActor
actor PersistentFeedStateManager {
    private static var _shared: PersistentFeedStateManager?
    private static let lock = NSLock()

    nonisolated static var shared: PersistentFeedStateManager {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let existing = _shared {
                return existing
            }
            fatalError("PersistentFeedStateManager.shared accessed before initialization. Call initialize(with:) first.")
        }
    }

    nonisolated static func initialize(with container: ModelContainer) {
        lock.lock()
        defer { lock.unlock() }
        if _shared == nil {
            _shared = PersistentFeedStateManager(modelContainer: container)
        }
        // Also initialize the DatabaseActorProvider for other components
        Task { @MainActor in
            DatabaseActorProvider.initialize(with: container)
        }
    }

    private let logger = Logger(
        subsystem: "blue.catbird",
        category: "PersistentFeedState"
    )
  
  // MARK: - Scroll Position Persistence
  
  func saveScrollPosition(
    postId: String,
    offsetFromPost: CGFloat,
    feedIdentifier: String
  ) {
    do {
      // Remove existing scroll position for this feed
      let currentFeedId = feedIdentifier
      let descriptor = FetchDescriptor<PersistedScrollPosition>(
        predicate: #Predicate<PersistedScrollPosition> { position in
          position.feedIdentifier == currentFeedId
        }
      )

      let existingPositions = try modelContext.fetch(descriptor)
      for position in existingPositions {
        modelContext.delete(position)
      }

      // Save new position
      let position = PersistedScrollPosition(
        postId: postId,
        offsetFromPost: offsetFromPost,
        feedIdentifier: feedIdentifier
      )
      modelContext.insert(position)
      try modelContext.save()

      logger.debug("Saved scroll position for feed \(feedIdentifier): post \(postId)")
    } catch {
      logger.error("Failed to save scroll position: \(error)")
    }
  }
  
  func loadScrollPosition(for feedIdentifier: String) -> PersistedScrollPosition? {
    do {
      let currentFeedId = feedIdentifier
      let descriptor = FetchDescriptor<PersistedScrollPosition>(
        predicate: #Predicate<PersistedScrollPosition> { position in
          position.feedIdentifier == currentFeedId
        }
      )

      let positions = try modelContext.fetch(descriptor)
      let position = positions.first

      if let position = position, !position.isStale {
        logger.debug("Loaded fresh scroll position for feed \(feedIdentifier)")
        return position
      } else if let position = position, position.isStale {
        logger.debug("Scroll position for feed \(feedIdentifier) is stale, removing")
        modelContext.delete(position)
        try? modelContext.save()
      }

      return nil
    } catch {
      logger.error("Failed to load scroll position: \(error)")
      return nil
    }
  }
  
  // MARK: - Feed Data Persistence
  
  func saveFeedData(_ posts: [CachedFeedViewPost], for feedIdentifier: String) {
    saveFeedData(posts, for: feedIdentifier, cursor: nil)
  }
  
  func saveFeedData(
    _ posts: [CachedFeedViewPost],
    for feedIdentifier: String,
    cursor: String?
  ) {
    do {
      let currentFeedId = feedIdentifier
      
      // Deduplicate posts by ID to prevent unique constraint violations
      // Keep the first occurrence of each post (preserves feed order)
      var seenIds = Set<String>()
      let uniquePosts = posts.filter { post in
        if seenIds.contains(post.id) {
          return false
        }
        seenIds.insert(post.id)
        return true
      }

      // Handle PersistedFeedState (no unique constraint conflict risk here)
      let stateDescriptor = FetchDescriptor<PersistedFeedState>(
        predicate: #Predicate<PersistedFeedState> { state in
          state.feedIdentifier == currentFeedId
        }
      )

      let existingStates = try modelContext.fetch(stateDescriptor)
      let existingCursor = existingStates.first?.cursor
      for state in existingStates {
        modelContext.delete(state)
      }

      // Collect IDs of new posts
      let newPostIds = Set(uniquePosts.map { $0.id })

      // Fetch existing posts for this feed (for cleanup of old posts)
      let feedPostsDescriptor = FetchDescriptor<CachedFeedViewPost>(
        predicate: #Predicate<CachedFeedViewPost> { post in
          post.feedType == currentFeedId
        }
      )
      let existingFeedPosts = try modelContext.fetch(feedPostsDescriptor)

      // Delete posts from this feed that are NOT in the new set
      for post in existingFeedPosts where !newPostIds.contains(post.id) {
        modelContext.delete(post)
      }

      // IMPORTANT: Fetch ALL existing posts by ID (across ALL feeds) to handle unique constraint
      // The same post can appear in multiple feeds, but has a global unique constraint on id
      let allPostsDescriptor = FetchDescriptor<CachedFeedViewPost>()
      let allExistingPosts = try modelContext.fetch(allPostsDescriptor)
      let existingPostsById = Dictionary(
        allExistingPosts.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first }
      )

      // Upsert new posts: update existing records in place, insert new ones
      // This avoids unique constraint violations by checking against ALL existing posts
      let (updated, inserted) = modelContext.batchUpsert(
        uniquePosts,
        existingModels: Array(existingPostsById.values.filter { newPostIds.contains($0.id) }),
        uniqueKeyPath: \.id,
        update: { existing, new in existing.update(from: new) }
      )

      // Save new feed state
      let postIds = uniquePosts.map { $0.id }
      let feedState = PersistedFeedState(
        feedIdentifier: feedIdentifier,
        postIds: postIds,
        cursor: cursor ?? existingCursor
      )
      modelContext.insert(feedState)

      try modelContext.save()
      let duplicates = posts.count - uniquePosts.count
      if duplicates > 0 {
        logger.debug("Saved \(uniquePosts.count) posts for feed \(feedIdentifier) (updated: \(updated), inserted: \(inserted), deduplicated: \(duplicates))")
      } else {
        logger.debug("Saved \(uniquePosts.count) posts for feed \(feedIdentifier) (updated: \(updated), inserted: \(inserted))")
      }
    } catch {
      logger.error("Failed to save feed data for \(feedIdentifier): \(error)")
    }
  }
  
  /// Returns both cached posts and the persisted cursor (if available)
  func loadFeedBundle(for feedIdentifier: String) -> (posts: [CachedFeedViewPost], cursor: String?)? {
    do {
      // Check if we have a fresh feed state
      let currentFeedId = feedIdentifier
      let stateDescriptor = FetchDescriptor<PersistedFeedState>(
        predicate: #Predicate<PersistedFeedState> { state in
          state.feedIdentifier == currentFeedId
        }
      )

      let feedStates = try modelContext.fetch(stateDescriptor)
      guard let feedState = feedStates.first else {
        logger.debug("No cached feed state for \(feedIdentifier)")
        return nil
      }

      if feedState.isStale {
        logger.debug("Feed state for \(feedIdentifier) is stale, removing")
        modelContext.delete(feedState)

        // Also remove stale cached posts
        let currentFeedId = feedIdentifier
        let postsDescriptor = FetchDescriptor<CachedFeedViewPost>(
          predicate: #Predicate<CachedFeedViewPost> { post in
            post.feedType == currentFeedId
          }
        )
        let stalePosts = try modelContext.fetch(postsDescriptor)
        for post in stalePosts {
          modelContext.delete(post)
        }

        try? modelContext.save()
        return nil
      }

      // Do not surface cache older than the recent freshness window to avoid showing stale content on launch
      guard feedState.isRecentlyFresh else {
        logger.debug("Cached feed state for \(feedIdentifier) is older than the freshness window, skipping restore to avoid stale UI")
        return nil
      }

      // Load cached posts
      let postsDescriptor = FetchDescriptor<CachedFeedViewPost>(
        predicate: #Predicate<CachedFeedViewPost> { post in
          post.feedType == currentFeedId
        },
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
      )

      let cachedPosts = try modelContext.fetch(postsDescriptor)

      return (cachedPosts, feedState.cursor)
    } catch {
      logger.error("Failed to load feed data: \(error)")
      return nil
    }
  }
  
  /// Backward-compatible helper that only returns posts
  func loadFeedData(for feedIdentifier: String) -> [CachedFeedViewPost]? {
    return loadFeedBundle(for: feedIdentifier)?.posts
  }
  
  // MARK: - Feed Continuity Management
  
  func saveFeedContinuityInfo(
    feedIdentifier: String,
    hasNewContent: Bool = false,
    lastKnownTopPostId: String? = nil,
    newPostCount: Int = 0,
    gapDetected: Bool = false
  ) {
    do {
      // Remove existing continuity info for this feed
      let currentFeedId = feedIdentifier
      let descriptor = FetchDescriptor<FeedContinuityInfo>(
        predicate: #Predicate<FeedContinuityInfo> { info in
          info.feedIdentifier == currentFeedId
        }
      )

      let existingInfo = try modelContext.fetch(descriptor)
      for info in existingInfo {
        modelContext.delete(info)
      }

      // Save new continuity info
      let info = FeedContinuityInfo(
        feedIdentifier: feedIdentifier,
        hasNewContent: hasNewContent,
        lastKnownTopPostId: lastKnownTopPostId,
        newPostCount: newPostCount,
        gapDetected: gapDetected
      )
      modelContext.insert(info)
      try modelContext.save()

      logger.debug("Saved continuity info for feed \(feedIdentifier)")
    } catch {
      logger.error("Failed to save continuity info: \(error)")
    }
  }
  
  func loadFeedContinuityInfo(for feedIdentifier: String) -> FeedContinuityInfo? {
    do {
      let currentFeedId = feedIdentifier
      let descriptor = FetchDescriptor<FeedContinuityInfo>(
        predicate: #Predicate<FeedContinuityInfo> { info in
          info.feedIdentifier == currentFeedId
        }
      )

      let continuityInfo = try modelContext.fetch(descriptor)
      return continuityInfo.first
    } catch {
      logger.error("Failed to load continuity info: \(error)")
      return nil
    }
  }
  
  // MARK: - Cache Cleanup
  
  /// Remove invalid posts from cache (posts that fail to decode)
  func removeInvalidPosts(withIds postIds: [String]) async {
    do {
      for postId in postIds {
        let descriptor = FetchDescriptor<CachedFeedViewPost>(
          predicate: #Predicate<CachedFeedViewPost> { post in
            post.id == postId
          }
        )
        let posts = try modelContext.fetch(descriptor)
        for post in posts {
          modelContext.delete(post)
        }
      }
      try modelContext.save()
      logger.info("Removed \(postIds.count) invalid posts from cache")
    } catch {
      logger.error("Failed to remove invalid posts: \(error)")
    }
  }
  
  // MARK: - Smart Refresh Logic
  
  func shouldRefreshFeed(
    feedIdentifier: String,
    lastUserRefresh: Date?,
    appBecameActiveTime: Date?
  ) -> Bool {
    do {
      // Check if we have cached feed state
      let currentFeedId = feedIdentifier
      let stateDescriptor = FetchDescriptor<PersistedFeedState>(
        predicate: #Predicate<PersistedFeedState> { state in
          state.feedIdentifier == currentFeedId
        }
      )

      let feedStates = try modelContext.fetch(stateDescriptor)
      guard let feedState = feedStates.first else {
        logger.debug("No cached data for \(feedIdentifier), should refresh")
        return true
      }

      // Don't refresh if data is very fresh (< 5 minutes)
      if feedState.isRecentlyFresh {
        logger.debug("Feed data is very fresh for \(feedIdentifier), skipping refresh")
        return false
      }

      // Refresh if data is stale (> 30 minutes)
      if feedState.isStale {
        logger.debug("Feed data is stale for \(feedIdentifier), should refresh")
        return true
      }

      // Refresh if app became active after being backgrounded for >10 minutes
      if let appActiveTime = appBecameActiveTime,
         Date().timeIntervalSince(appActiveTime) > 600 {
        logger.debug("App was backgrounded long enough, should refresh \(feedIdentifier)")
        return true
      }

      // Refresh if user last pulled to refresh >2 minutes ago
      if let lastRefresh = lastUserRefresh,
         Date().timeIntervalSince(lastRefresh) > 120 {
        logger.debug("Last user refresh was >2 minutes ago for \(feedIdentifier), should refresh")
        return true
      }

      logger.debug("No refresh needed for \(feedIdentifier)")
      return false
    } catch {
      logger.error("Failed to check refresh need: \(error)")
      return true
    }
  }
  
  // MARK: - Cleanup
  
  func cleanupStaleData() {
    do {
      // Clean up stale scroll positions
      let positionDescriptor = FetchDescriptor<PersistedScrollPosition>()
      let allPositions = try modelContext.fetch(positionDescriptor)
      var cleanedPositions = 0

      for position in allPositions {
        if position.isStale {
          modelContext.delete(position)
          cleanedPositions += 1
        }
      }

      // Clean up stale feed states
      let stateDescriptor = FetchDescriptor<PersistedFeedState>()
      let allStates = try modelContext.fetch(stateDescriptor)
      var cleanedStates = 0

      for state in allStates {
        if state.isStale {
          modelContext.delete(state)
          cleanedStates += 1

          // Also remove associated cached posts
          let stateFeedId = state.feedIdentifier
          let postsDescriptor = FetchDescriptor<CachedFeedViewPost>(
            predicate: #Predicate<CachedFeedViewPost> { post in
              post.feedType == stateFeedId
            }
          )
          let stalePosts = try modelContext.fetch(postsDescriptor)
          for post in stalePosts {
            modelContext.delete(post)
          }
        }
      }

      if cleanedPositions > 0 || cleanedStates > 0 {
        try modelContext.save()
        logger.debug("Cleaned up \(cleanedPositions) stale scroll positions and \(cleanedStates) stale feed states")
      }
    } catch {
      logger.error("Failed to cleanup stale data: \(error)")
    }
  }

  // MARK: - Account Switching Support

  /// Clears all persisted feed data to avoid cross-account contamination
  func clearAll() async {
    do {
      let feedStates = try modelContext.fetch(FetchDescriptor<PersistedFeedState>())
      feedStates.forEach { modelContext.delete($0) }

      let cachedPosts = try modelContext.fetch(FetchDescriptor<CachedFeedViewPost>())
      cachedPosts.forEach { modelContext.delete($0) }

      let scrollPositions = try modelContext.fetch(FetchDescriptor<PersistedScrollPosition>())
      scrollPositions.forEach { modelContext.delete($0) }

      let continuityInfo = try modelContext.fetch(FetchDescriptor<FeedContinuityInfo>())
      continuityInfo.forEach { modelContext.delete($0) }

      try modelContext.save()
      logger.info("Cleared all persisted feed data after account switch")
    } catch {
      logger.error("Failed to clear persisted feed data: \(error)")
    }
  }
}
