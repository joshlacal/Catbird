import Foundation
import Petrel
import OSLog
import OrderedCollections

/// Feed filtering preferences for FeedTuner
/// Matches Bluesky's app.bsky.actor.defs#feedViewPref specification
struct FeedTunerSettings {
    // Server-synced FeedViewPref settings
    let hideReplies: Bool
    let hideRepliesByUnfollowed: Bool 
    let hideRepliesByLikeCount: Int?  // Hide replies with fewer than this many likes
    let hideReposts: Bool
    let hideQuotePosts: Bool
    
    // App-level settings
    let hideNonPreferredLanguages: Bool
    let preferredLanguages: [String]
    let mutedUsers: Set<String>
    let blockedUsers: Set<String>
    
    // Quick filter settings from QuickFilterSheet
    let hideLinks: Bool
    let onlyTextPosts: Bool
    let onlyMediaPosts: Bool
    
    // Content label filtering
    let contentLabelPreferences: [ContentLabelPreference]
    let hideAdultContent: Bool
    
    // Post hiding
    let hiddenPosts: Set<String>
    
    // Current user DID for self-reply detection
    let currentUserDid: String?
    
    static let `default` = FeedTunerSettings(
        hideReplies: false,
        hideRepliesByUnfollowed: false,
        hideRepliesByLikeCount: nil,
        hideReposts: false,
        hideQuotePosts: false,
        hideNonPreferredLanguages: false,
        preferredLanguages: [],
        mutedUsers: [],
        blockedUsers: [],
        hideLinks: false,
        onlyTextPosts: false,
        onlyMediaPosts: false,
        contentLabelPreferences: [],
        hideAdultContent: false,
        hiddenPosts: [],
        currentUserDid: nil
    )
}

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
  let originalReply: AppBskyFeedDefs.ReplyRef?  // Preserve original reply context for reposts
  
  init(
    items: [FeedSliceItem],
    isIncompleteThread: Bool = false,
    isFallbackMarker: Bool = false,
    isOrphan: Bool = false,
    rootUri: String,
    feedPostUri: String,
    reason: AppBskyFeedDefs.FeedViewPostReasonUnion? = nil,
    feedContext: String? = nil,
    originalReply: AppBskyFeedDefs.ReplyRef? = nil
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
    self.originalReply = originalReply
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
  
  // Store current filter settings for slice validation
  private var currentFilterSettings: FeedTunerSettings = .default
  
  // Content filtering service
  private let contentFilterService = ContentFilterService()
  
  /// Main processing method - converts raw posts to slices
  func tune(_ rawPosts: [AppBskyFeedDefs.FeedViewPost], filterSettings: FeedTunerSettings = .default) async -> [FeedSlice] {
    logger.debug("🧵 FeedTuner.tune() called with \(rawPosts.count) raw posts")
    
    // Apply content filtering first using centralized service
    let filteredPosts = await contentFilterService.filterFeedViewPosts(rawPosts, settings: filterSettings)
    logger.debug("🧵 Filtered \(rawPosts.count) posts to \(filteredPosts.count) posts")
    
    // Reset seen tracking for new batch
    seenKeys.removeAll()
    seenUris.removeAll()
    
    // Store filter settings for use in slice creation
    self.currentFilterSettings = filterSettings
    
    // Use OrderedDictionary to preserve feed order and prevent randomization
    var rootGroups: OrderedDictionary<String, [AppBskyFeedDefs.FeedViewPost]> = [:]
    
    // Group posts by root URI while preserving order
    for post in filteredPosts {
      let rootUri: String
      if case .appBskyFeedDefsPostView(let rootPost) = post.reply?.root {
        rootUri = rootPost.uri.uriString()
      } else {
        rootUri = post.post.uri.uriString()
      }
      
      if rootGroups[rootUri] == nil {
        rootGroups[rootUri] = []
      }
      rootGroups[rootUri]?.append(post)
    }
    
    logger.debug("🧵 Grouped \(filteredPosts.count) posts into \(rootGroups.count) root threads")
    
    // Process each group to create ONE slice per thread (prevents duplicates)
    var allSlices: [FeedSlice] = []
    
    for (rootUri, postsInGroup) in rootGroups {
      // Create only ONE slice per thread group to prevent duplicates
      if let threadSlice = createThreadSlice(from: postsInGroup, rootUri: rootUri) {
        // Apply slice-level filtering to handle individual items within threads
        if let filteredSlice = filterSliceItems(threadSlice, settings: filterSettings) {
          allSlices.append(filteredSlice)
        }
      }
    }
    
    // Apply deduplication as final safety net
    let dedupedSlices = deduplicateSlicesOptimized(allSlices)
    
    logger.debug("🧵 FeedTuner completed: \(rawPosts.count) posts → \(filteredPosts.count) filtered → \(dedupedSlices.count) slices (fixed duplicates & order)")
    
    return dedupedSlices
  }
  
  // MARK: - Slice Item Filtering
  
  /// Filter individual items within a slice based on quick filter settings
  /// Returns nil if all items are filtered out, otherwise returns a new slice with filtered items
  private func filterSliceItems(_ slice: FeedSlice, settings: FeedTunerSettings) -> FeedSlice? {
    // Check hideReplies FIRST - this hides ALL replies unconditionally
    if settings.hideReplies && slice.isReply {
      // Exception: Don't hide the user's own replies
      if let currentUserDid = settings.currentUserDid,
         let replyAuthorDid = slice.items.last?.post.author.did.didString(),
         replyAuthorDid == currentUserDid {
        // Let user's own replies through
      } else {
        logger.debug("Filtered slice: hideReplies enabled, hiding reply \(slice.id)")
        return nil
      }
    }
    
    // Check hideRepliesByUnfollowed - hide replies TO posts from users you don't follow
    // Key: Must follow someone in the ORIGINAL THREAD (parent or root), EXCLUDING the reply author
    // This prevents seeing followed bots/users spamming replies to unfollowed users
    if settings.hideRepliesByUnfollowed && slice.isReply {
      // Get the reply post (last item in slice)
      guard let replyItem = slice.items.last else { return nil }
      
      let replyAuthor = replyItem.post.author.handle
      let replyAuthorDid = replyItem.post.author.did.didString()
      
      // Exception 1: Don't hide the user's own replies
      if let currentUserDid = settings.currentUserDid,
         replyAuthorDid == currentUserDid {
        logger.debug("Showing reply: user's own reply by @\(replyAuthor)")
        return slice
      }
      
      // Check if we follow ANYONE in the ORIGINAL THREAD (parent or root)
      // CRITICAL: We exclude the reply author from this check
      // This ensures we only see replies to conversations we're actually interested in
      var followsSomeoneInThread = false
      var followedAuthors: [String] = []
      
      // Check all items in the slice EXCEPT the last one (which is the reply itself)
      // These represent the parent/root posts in the thread
      for item in slice.items.dropLast() {
        let itemAuthor = item.post.author.handle
        let itemDid = item.post.author.did.didString()
        let isFollowed = item.post.author.viewer?.following != nil
        
        logger.debug("  Thread item: @\(itemAuthor) (DID: \(itemDid), followed: \(isFollowed))")
        
        // CRITICAL: Skip if this thread item is the same person as the reply author
        // This prevents showing bot self-replies or followed users replying to their own threads
        if itemDid == replyAuthorDid {
          logger.debug("  Skipping thread item - same as reply author")
          continue
        }
        
        if isFollowed {
          followsSomeoneInThread = true
          followedAuthors.append(itemAuthor.description)
        }
        // Also check if it's the current user's post
        if let currentUserDid = settings.currentUserDid, itemDid == currentUserDid {
          followsSomeoneInThread = true
          followedAuthors.append("\(itemAuthor) (you)")
        }
      }
      
      if followsSomeoneInThread {
        logger.debug("✅ Showing reply by @\(replyAuthor): follows \(followedAuthors.joined(separator: ", ")) in thread")
        return slice
      }
      
      // Hide if we don't follow anyone in the thread (other than the reply author)
      let threadAuthors = slice.items.dropLast().map { $0.post.author.handle.description }.joined(separator: ", ")
      logger.debug("🚫 Filtered slice: reply by @\(replyAuthor) to thread with no OTHER followed users [@\(threadAuthors)]")
      return nil
    }
    
    // Check hideRepliesByLikeCount - hide replies with insufficient likes
    if let minLikeCount = settings.hideRepliesByLikeCount, slice.isReply {
      // Get the reply post (last item in slice)
      guard let replyItem = slice.items.last else { return nil }
      
      let likeCount = replyItem.post.likeCount ?? 0
      if likeCount < minLikeCount {
        let replyAuthor = replyItem.post.author.handle
        logger.debug("🚫 Filtered slice: reply by @\(replyAuthor) has \(likeCount) likes (minimum: \(minLikeCount))")
        return nil
      }
    }
    
    // If no quick filters are active, return original slice
    if !settings.hideLinks && !settings.onlyTextPosts && !settings.onlyMediaPosts {
      return slice
    }
    
    var filteredItems: [FeedSliceItem] = []
    
    for item in slice.items {
      var shouldInclude = true
      
      // Check for links
      if settings.hideLinks {
        var hasLink = false
        
        // Check embed for external links
        if let embed = item.post.embed {
          switch embed {
          case .appBskyEmbedExternalView:
            hasLink = true
          case .appBskyEmbedRecordWithMediaView(let recordWithMedia):
            if case .appBskyEmbedExternalView = recordWithMedia.media {
              hasLink = true
            }
          default:
            break
          }
        }
        
        // Check facets for links
        if !hasLink, let facets = item.record.facets {
          for facet in facets {
            for feature in facet.features {
              if case .appBskyRichtextFacetLink = feature {
                hasLink = true
                break
              }
            }
            if hasLink { break }
          }
        }
        
        if hasLink {
          shouldInclude = false
        }
      }
      
      // Check for text-only posts
      if settings.onlyTextPosts && shouldInclude {
        if item.post.embed != nil {
          shouldInclude = false
        }
      }
      
      // Check for media posts
      if settings.onlyMediaPosts && shouldInclude {
        var hasMedia = false
        
        if let embed = item.post.embed {
          switch embed {
          case .appBskyEmbedImagesView, .appBskyEmbedVideoView:
            hasMedia = true
          case .appBskyEmbedRecordWithMediaView(let recordWithMedia):
            switch recordWithMedia.media {
            case .appBskyEmbedImagesView, .appBskyEmbedVideoView:
              hasMedia = true
            default:
              break
            }
          default:
            break
          }
        }
        
        if !hasMedia {
          shouldInclude = false
        }
      }
      
      if shouldInclude {
        filteredItems.append(item)
      }
    }
    
    // If all items were filtered out, return nil to remove the entire slice
    guard !filteredItems.isEmpty else {
      logger.debug("Filtered out entire slice (all items removed): \(slice.id)")
      return nil
    }
    
    // If some items were filtered, create a new slice with remaining items
    if filteredItems.count != slice.items.count {
      logger.debug("Filtered slice from \(slice.items.count) to \(filteredItems.count) items")
      return FeedSlice(
        items: filteredItems,
        isIncompleteThread: slice.isIncompleteThread || filteredItems.count < slice.items.count,
        isFallbackMarker: slice.isFallbackMarker,
        isOrphan: slice.isOrphan,
        rootUri: slice.rootUri,
        feedPostUri: slice.feedPostUri,
        reason: slice.reason,
        feedContext: slice.feedContext,
        originalReply: slice.originalReply
      )
    }
    
    return slice
  }
  
  // MARK: - Thread Slice Creation
  
  /// Creates a single slice from a group of related posts (prevents duplicates)
  private func createThreadSlice(from posts: [AppBskyFeedDefs.FeedViewPost], rootUri: String) -> FeedSlice? {
    guard !posts.isEmpty else { return nil }
    
    // Sort posts by creation time for proper thread ordering
    let sortedPosts = posts.sorted { post1, post2 in
      guard case .knownType(let record1) = post1.post.record,
            let feedPost1 = record1 as? AppBskyFeedPost,
            case .knownType(let record2) = post2.post.record,
            let feedPost2 = record2 as? AppBskyFeedPost else {
        return false
      }
      return feedPost1.createdAt < feedPost2.createdAt
    }
    
    // Select the primary post for this thread:
    // Use the most recent post in the group (the actual post that appeared in the feed)
    let primaryPost = sortedPosts.last! // Most recent post (the reply)
    
    // Create slice from the primary post
    return createSlice(from: primaryPost)
  }
  
  // MARK: - Single Slice Creation
  
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
        feedContext: feedPost.feedContext,
        originalReply: feedPost.reply  // Preserve reply context for reposts
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
  
  /// Optimized deduplication with batch operations and reduced allocations
  private func deduplicateSlicesOptimized(_ slices: [FeedSlice]) -> [FeedSlice] {
    var results: [FeedSlice] = []
    results.reserveCapacity(slices.count) // Pre-allocate to reduce reallocations
    
    // Use batch operations for better performance
    var newSeenKeys: Set<String> = seenKeys
    var newSeenUris: Set<String> = seenUris
    
    for slice in slices {
      // Skip if we've seen this exact slice before
      guard !newSeenKeys.contains(slice.id) else {
        continue
      }
      
      // Collect all URIs in this slice
      let sliceUris = slice.items.map { $0.post.uri.uriString() }
      
      // Check if any items were already seen using set intersection
      let unseenUriCount = Set(sliceUris).subtracting(newSeenUris).count
      guard unseenUriCount > 0 else {
        continue
      }
      
      // Mark as seen (batch operations)
      newSeenKeys.insert(slice.id)
      newSeenUris.formUnion(sliceUris)
      
      results.append(slice)
    }
    
    // Update instance variables
    seenKeys = newSeenKeys
    seenUris = newSeenUris
    
    return results
  }
}
