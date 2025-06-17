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
  
  // Store post IDs for quick reference
  var postIds: [String]
  
  var isStale: Bool {
    Date().timeIntervalSince(timestamp) > 1800 // 30 minutes
  }
  
  var isRecentlyFresh: Bool {
    Date().timeIntervalSince(timestamp) < 300 // 5 minutes
  }
  
  init(feedIdentifier: String, postIds: [String]) {
    self.feedIdentifier = feedIdentifier
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
final class PersistentFeedStateManager {
  static let shared = PersistentFeedStateManager()
  
  private var modelContext: ModelContext?
  
  private let logger = Logger(
    subsystem: "blue.catbird", 
    category: "PersistentFeedState"
  )
  
  private init() {}
  
  func setModelContext(_ context: ModelContext) {
    self.modelContext = context
  }
  
  // MARK: - Scroll Position Persistence
  
  func saveScrollPosition(
    postId: String,
    offsetFromPost: CGFloat,
    feedIdentifier: String
  ) {
    guard let context = modelContext else {
      logger.warning("No ModelContext available for saving scroll position")
      return
    }
    
    do {
      // Remove existing scroll position for this feed
      let currentFeedId = feedIdentifier
      let descriptor = FetchDescriptor<PersistedScrollPosition>(
        predicate: #Predicate<PersistedScrollPosition> { position in
          position.feedIdentifier == currentFeedId
        }
      )
      
      let existingPositions = try context.fetch(descriptor)
      for position in existingPositions {
        context.delete(position)
      }
      
      // Save new position
      let position = PersistedScrollPosition(
        postId: postId,
        offsetFromPost: offsetFromPost,
        feedIdentifier: feedIdentifier
      )
      context.insert(position)
      try context.save()
      
      logger.debug("Saved scroll position for feed \(feedIdentifier): post \(postId)")
    } catch {
      logger.error("Failed to save scroll position: \(error)")
    }
  }
  
  func loadScrollPosition(for feedIdentifier: String) -> PersistedScrollPosition? {
    guard let context = modelContext else {
      logger.warning("No ModelContext available for loading scroll position")
      return nil
    }
    
    do {
      let currentFeedId = feedIdentifier
      let descriptor = FetchDescriptor<PersistedScrollPosition>(
        predicate: #Predicate<PersistedScrollPosition> { position in
          position.feedIdentifier == currentFeedId
        }
      )
      
      let positions = try context.fetch(descriptor)
      let position = positions.first
      
      if let position = position, !position.isStale {
        logger.debug("Loaded fresh scroll position for feed \(feedIdentifier)")
        return position
      } else if let position = position, position.isStale {
        logger.debug("Scroll position for feed \(feedIdentifier) is stale, removing")
        context.delete(position)
        try? context.save()
      }
      
      return nil
    } catch {
      logger.error("Failed to load scroll position: \(error)")
      return nil
    }
  }
  
  // MARK: - Feed Data Persistence
  
  func saveFeedData(_ posts: [CachedFeedViewPost], for feedIdentifier: String) {
    guard let context = modelContext else {
      logger.warning("No ModelContext available for saving feed data")
      return
    }
    
    do {
      // Remove existing feed state for this feed
      let currentFeedId = feedIdentifier
      let stateDescriptor = FetchDescriptor<PersistedFeedState>(
        predicate: #Predicate<PersistedFeedState> { state in
          state.feedIdentifier == currentFeedId
        }
      )
      
      let existingStates = try context.fetch(stateDescriptor)
      for state in existingStates {
        context.delete(state)
      }
      
      // Remove old cached posts for this feed type
      let postsDescriptor = FetchDescriptor<CachedFeedViewPost>(
        predicate: #Predicate<CachedFeedViewPost> { post in
          post.feedType == currentFeedId
        }
      )
      
      let existingPosts = try context.fetch(postsDescriptor)
      for post in existingPosts {
        context.delete(post)
      }
      
      // Save new feed state
      let postIds = posts.map { $0.id }
      let feedState = PersistedFeedState(feedIdentifier: feedIdentifier, postIds: postIds)
      context.insert(feedState)
      
      // Save new cached posts
      for post in posts {
        context.insert(post)
      }
      
      try context.save()
      logger.debug("Saved \(posts.count) posts for feed \(feedIdentifier)")
    } catch {
      logger.error("Failed to save feed data for \(feedIdentifier): \(error)")
    }
  }
  
  func loadFeedData(for feedIdentifier: String) -> [CachedFeedViewPost]? {
    guard let context = modelContext else {
      logger.warning("No ModelContext available for loading feed data")
      return nil
    }
    
    do {
      // Check if we have a fresh feed state
      let currentFeedId = feedIdentifier
      let stateDescriptor = FetchDescriptor<PersistedFeedState>(
        predicate: #Predicate<PersistedFeedState> { state in
          state.feedIdentifier == currentFeedId
        }
      )
      
      let feedStates = try context.fetch(stateDescriptor)
      guard let feedState = feedStates.first else {
        logger.debug("No cached feed state for \(feedIdentifier)")
        return nil
      }
      
      if feedState.isStale {
        logger.debug("Feed state for \(feedIdentifier) is stale, removing")
        context.delete(feedState)
        
        // Also remove stale cached posts
        let currentFeedId = feedIdentifier
        let postsDescriptor = FetchDescriptor<CachedFeedViewPost>(
          predicate: #Predicate<CachedFeedViewPost> { post in
            post.feedType == currentFeedId
          }
        )
        let stalePosts = try context.fetch(postsDescriptor)
        for post in stalePosts {
          context.delete(post)
        }
        
        try? context.save()
        return nil
      }
      
      // Load cached posts
      let postsDescriptor = FetchDescriptor<CachedFeedViewPost>(
        predicate: #Predicate<CachedFeedViewPost> { post in
          post.feedType == currentFeedId
        },
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
      )
      
      let cachedPosts = try context.fetch(postsDescriptor)
      
      if !cachedPosts.isEmpty {
        logger.debug("Loaded fresh feed data for \(feedIdentifier): \(cachedPosts.count) posts")
        return cachedPosts
      }
      
      return nil
    } catch {
      logger.error("Failed to load feed data: \(error)")
      return nil
    }
  }
  
  // MARK: - Feed Continuity Management
  
  func saveFeedContinuityInfo(
    feedIdentifier: String,
    hasNewContent: Bool = false,
    lastKnownTopPostId: String? = nil,
    newPostCount: Int = 0,
    gapDetected: Bool = false
  ) {
    guard let context = modelContext else {
      logger.warning("No ModelContext available for saving continuity info")
      return
    }
    
    do {
      // Remove existing continuity info for this feed
      let currentFeedId = feedIdentifier
      let descriptor = FetchDescriptor<FeedContinuityInfo>(
        predicate: #Predicate<FeedContinuityInfo> { info in
          info.feedIdentifier == currentFeedId
        }
      )
      
      let existingInfo = try context.fetch(descriptor)
      for info in existingInfo {
        context.delete(info)
      }
      
      // Save new continuity info
      let info = FeedContinuityInfo(
        feedIdentifier: feedIdentifier,
        hasNewContent: hasNewContent,
        lastKnownTopPostId: lastKnownTopPostId,
        newPostCount: newPostCount,
        gapDetected: gapDetected
      )
      context.insert(info)
      try context.save()
      
      logger.debug("Saved continuity info for feed \(feedIdentifier)")
    } catch {
      logger.error("Failed to save continuity info: \(error)")
    }
  }
  
  func loadFeedContinuityInfo(for feedIdentifier: String) -> FeedContinuityInfo? {
    guard let context = modelContext else {
      logger.warning("No ModelContext available for loading continuity info")
      return nil
    }
    
    do {
      let currentFeedId = feedIdentifier
      let descriptor = FetchDescriptor<FeedContinuityInfo>(
        predicate: #Predicate<FeedContinuityInfo> { info in
          info.feedIdentifier == currentFeedId
        }
      )
      
      let continuityInfo = try context.fetch(descriptor)
      return continuityInfo.first
    } catch {
      logger.error("Failed to load continuity info: \(error)")
      return nil
    }
  }
  
  // MARK: - Smart Refresh Logic
  
  func shouldRefreshFeed(
    feedIdentifier: String,
    lastUserRefresh: Date?,
    appBecameActiveTime: Date?
  ) -> Bool {
    guard let context = modelContext else {
      logger.warning("No ModelContext available for refresh check")
      return true
    }
    
    do {
      // Check if we have cached feed state
      let currentFeedId = feedIdentifier
      let stateDescriptor = FetchDescriptor<PersistedFeedState>(
        predicate: #Predicate<PersistedFeedState> { state in
          state.feedIdentifier == currentFeedId
        }
      )
      
      let feedStates = try context.fetch(stateDescriptor)
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
    guard let context = modelContext else {
      logger.warning("No ModelContext available for cleanup")
      return
    }
    
    do {
      // Clean up stale scroll positions
      let positionDescriptor = FetchDescriptor<PersistedScrollPosition>()
      let allPositions = try context.fetch(positionDescriptor)
      var cleanedPositions = 0
      
      for position in allPositions {
        if position.isStale {
          context.delete(position)
          cleanedPositions += 1
        }
      }
      
      // Clean up stale feed states
      let stateDescriptor = FetchDescriptor<PersistedFeedState>()
      let allStates = try context.fetch(stateDescriptor)
      var cleanedStates = 0
      
      for state in allStates {
        if state.isStale {
          context.delete(state)
          cleanedStates += 1
          
          // Also remove associated cached posts
          let stateFeedId = state.feedIdentifier
          let postsDescriptor = FetchDescriptor<CachedFeedViewPost>(
            predicate: #Predicate<CachedFeedViewPost> { post in
              post.feedType == stateFeedId
            }
          )
          let stalePosts = try context.fetch(postsDescriptor)
          for post in stalePosts {
            context.delete(post)
          }
        }
      }
      
      if cleanedPositions > 0 || cleanedStates > 0 {
        try context.save()
        logger.debug("Cleaned up \(cleanedPositions) stale scroll positions and \(cleanedStates) stale feed states")
      }
    } catch {
      logger.error("Failed to cleanup stale data: \(error)")
    }
  }
}
