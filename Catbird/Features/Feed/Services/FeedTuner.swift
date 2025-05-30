import Foundation
import Petrel
import OSLog

// MARK: - Feed Slice Data Structures

/// Swift translation of Bluesky React Native TypeScript's FeedViewPost Slice
struct FeedSlice: Identifiable, Sendable {
  let id: String
  let items: [FeedSliceItem]
  let isIncompleteThread: Bool
  let isFallbackMarker: Bool
  let isOrphan: Bool
  let rootUri: String
  let feedPostUri: String
  let reason: AppBskyFeedDefs.FeedViewPostReasonUnion?
  let feedContext: String?
  
  init(
    items: [FeedSliceItem],
    isIncompleteThread: Bool = false,
    isFallbackMarker: Bool = false,
    isOrphan: Bool = false,
    rootUri: String,
    feedPostUri: String,
    reason: AppBskyFeedDefs.FeedViewPostReasonUnion? = nil,
    feedContext: String? = nil
  ) {
    self.id = feedPostUri
    self.items = items
    self.isIncompleteThread = isIncompleteThread
    self.isFallbackMarker = isFallbackMarker
    self.isOrphan = isOrphan
    self.rootUri = rootUri
    self.feedPostUri = feedPostUri
    self.reason = reason
    self.feedContext = feedContext
  }
  
  // React Native: slice.isReply, slice.isRepost, etc.
  var isReply: Bool {
    items.last?.record.reply != nil
  }
  
  var isRepost: Bool {
    reason != nil
  }
  
  var mainPost: AppBskyFeedDefs.PostView? {
    items.last?.post
  }
  
  var shouldShowAsThread: Bool {
    items.count > 1 && !isRepost
  }
}

/// Individual item within a feed slice
struct FeedSliceItem: Identifiable, Sendable, Codable {
  let id: String
  let post: AppBskyFeedDefs.PostView
  let record: AppBskyFeedPost
  let parentAuthor: AppBskyActorDefs.ProfileViewBasic?
  
  init(
    post: AppBskyFeedDefs.PostView,
    record: AppBskyFeedPost,
    parentAuthor: AppBskyActorDefs.ProfileViewBasic? = nil,
  ) {
    self.id = post.uri.uriString()
    self.post = post
    self.record = record
    self.parentAuthor = parentAuthor
  }
}

// MARK: - Feed Tuner

/// Swift equivalent of React Native's FeedTuner
/// Processes raw feed posts into slices by extracting embedded thread context
final class FeedTuner {
  private let logger = Logger(subsystem: "blue.catbird.app", category: "FeedTuner")
  
  // Deduplication tracking (like React Native)
  private var seenKeys: Set<String> = []
  private var seenUris: Set<String> = []
  
  /// Main processing method - converts raw posts to slices
  func tune(_ rawPosts: [AppBskyFeedDefs.FeedViewPost]) -> [FeedSlice] {
    logger.debug("🧵 FeedTuner.tune() called with \(rawPosts.count) raw posts")
    
    // Debug: Log posts with replies
    for post in rawPosts {
      if let reply = post.reply {
          logger.debug("🧵 Post \(post.post.uri.uriString()) has reply context: parent=\(String(describing: reply.parent)), root=\(String(describing: reply.root))")
      } else {
          logger.debug("🧵 Post \(post.post.uri.uriString()) has NO reply context")
      }
    }
    
    // Reset seen tracking for new batch
    seenKeys.removeAll()
    seenUris.removeAll()
    
    // Step 1: Convert each raw post into a slice (following React Native logic)
    logger.debug("🧵 Step 1: Creating slices from raw posts...")
    let slices = rawPosts.compactMap { post in
      logger.debug("🧵 Creating slice for post: \(post.post.uri.uriString())")
      let slice = createSlice(from: post)
      if let slice = slice {
        logger.debug("🧵 ✅ Created slice with \(slice.items.count) items")
      } else {
        logger.debug("🧵 ❌ Failed to create slice")
      }
      return slice
    }
    
    // Step 2: Apply deduplication (like React Native)
    logger.debug("🧵 Step 2: Deduplicating \(slices.count) slices...")
    let dedupedSlices = deduplicateSlices(slices)
    
    logger.debug("🧵 FeedTuner completed: \(rawPosts.count) posts → \(dedupedSlices.count) slices")
    
    // Final debug: log slice summary
    for slice in dedupedSlices {
      logger.debug("🧵 Final slice: \(slice.id) with \(slice.items.count) items")
    }
    
    return dedupedSlices
  }
  
  // MARK: - Slice Creation
  
  /// Creates a slice from a single FeedViewPost by extracting embedded thread context
  private func createSlice(from feedPost: AppBskyFeedDefs.FeedViewPost) -> FeedSlice? {
    // Extract the post record (following React Native pattern)
    guard case .knownType(let record) = feedPost.post.record,
          let postRecord = record as? AppBskyFeedPost else {
      logger.warning("Failed to decode post record for \(feedPost.post.uri.uriString())")
      return nil
    }
    
    var items: [FeedSliceItem] = []
    var isIncompleteThread = false
    let feedPostUri = feedPost.post.uri.uriString()
    
    // Determine root URI (React Native logic)
    let rootUri: String
    if case .appBskyFeedDefsPostView(let rootPost) = feedPost.reply?.root {
      rootUri = rootPost.uri.uriString()
    } else {
      rootUri = feedPostUri
    }
    
    // Add the main post (React Native: this.items.push)
    let mainItem = createSliceItem(
      post: feedPost.post,
      record: postRecord,
      grandparent: feedPost.reply?.grandparentAuthor
    )
    items.append(mainItem)
    
    // If no reply context, we're done (like React Native early returns)
    guard let reply = feedPost.reply else {
      return FeedSlice(
        items: items,
        isOrphan: postRecord.reply != nil, // orphan if reply data missing
        rootUri: rootUri,
        feedPostUri: feedPostUri,
        reason: feedPost.reason,
        feedContext: feedPost.feedContext
      )
    }
    
    // Skip complex thread building for reposts (React Native logic)
    if feedPost.reason != nil {
      return FeedSlice(
        items: items,
        rootUri: rootUri,
        feedPostUri: feedPostUri,
        reason: feedPost.reason,
        feedContext: feedPost.feedContext
      )
    }
    
    // Add parent post if available (React Native: this.items.unshift)
    if case .appBskyFeedDefsPostView(let parentPost) = reply.parent,
       case .knownType(let parentRecord) = parentPost.record,
       let parentPostRecord = parentRecord as? AppBskyFeedPost {
      
      let parentItem = createSliceItem(
        post: parentPost,
        record: parentPostRecord,
        grandparent: reply.grandparentAuthor
      )
      items.insert(parentItem, at: 0) // unshift = insert at beginning
    }
    
    // Add root post if different from parent (React Native logic)
    if case .appBskyFeedDefsPostView(let rootPost) = reply.root,
       case .knownType(let rootRecord) = rootPost.record,
       let rootPostRecord = rootRecord as? AppBskyFeedPost {
      
      let parentUri = getParentUri(from: reply.parent)
      let rootUri = rootPost.uri.uriString()
      
      // Only add root if it's different from parent
      if rootUri != parentUri {
        let rootItem = FeedSliceItem(
          post: rootPost,
          record: rootPostRecord
        )
        items.insert(rootItem, at: 0)
        
        // Check if thread is incomplete (React Native logic)
        if case .appBskyFeedDefsPostView(let parentPost) = reply.parent,
           case .knownType(let parentRecord) = parentPost.record,
           let parentPostRecord = parentRecord as? AppBskyFeedPost,
           let parentReplyParent = parentPostRecord.reply?.parent {
          
          // If parent's parent doesn't match root, we have gaps
          // parentReplyParent is a ComAtprotoRepoStrongRef (just URI + CID)
          if parentReplyParent.uri.uriString() != rootPost.uri.uriString() {
            isIncompleteThread = true
          }
        }
      }
    }
    
    let slice = FeedSlice(
      items: items,
      isIncompleteThread: isIncompleteThread,
      rootUri: rootUri,
      feedPostUri: feedPostUri,
      reason: feedPost.reason,
      feedContext: feedPost.feedContext
    )
    
    // Debug logging
    if items.count > 1 {
      logger.debug("Created slice for \(feedPostUri): \(items.count) items, incomplete=\(isIncompleteThread)")
      for (index, item) in items.enumerated() {
        logger.debug("  [\(index)]: \(item.post.uri.uriString())")
      }
    }
    
    return slice
  }
  
  // MARK: - Helper Methods
  
  private func createSliceItem(
    post: AppBskyFeedDefs.PostView,
    record: AppBskyFeedPost,
    grandparent: AppBskyActorDefs.ProfileViewBasic?
  ) -> FeedSliceItem {
    
    return FeedSliceItem(
      post: post,
      record: record,
      parentAuthor: grandparent
    )
  }
    
  private func getParentUri(from parent: AppBskyFeedDefs.ReplyRefParentUnion?) -> String? {
    switch parent {
    case .appBskyFeedDefsPostView(let parentPost):
      return parentPost.uri.uriString()
    default:
      return nil
    }
  }
  
  // MARK: - Deduplication
  
  /// Applies deduplication logic following React Native pattern
  private func deduplicateSlices(_ slices: [FeedSlice]) -> [FeedSlice] {
    var results: [FeedSlice] = []
    
    for slice in slices {
      // Skip if we've seen this exact slice before
      guard !seenKeys.contains(slice.id) else {
        logger.debug("Skipping duplicate slice: \(slice.id)")
        continue
      }
      
      // Check if any items were already seen
      let unseenItems = slice.items.filter { !seenUris.contains($0.post.uri.uriString()) }
      guard !unseenItems.isEmpty else {
        logger.debug("Skipping slice with all seen items: \(slice.id)")
        continue
      }
      
      // Mark as seen
      seenKeys.insert(slice.id)
      for item in slice.items {
        seenUris.insert(item.post.uri.uriString())
      }
      
      results.append(slice)
    }
    
    return results
  }
}
