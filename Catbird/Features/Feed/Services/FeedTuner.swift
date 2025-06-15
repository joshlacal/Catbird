import Foundation
import Petrel
import OSLog
import OrderedCollections

/// Feed filtering preferences for FeedTuner
struct FeedTunerSettings {
    let hideReplies: Bool
    let hideRepliesByUnfollowed: Bool 
    let hideReposts: Bool
    let hideQuotePosts: Bool
    let hideNonPreferredLanguages: Bool
    let preferredLanguages: [String]
    let mutedUsers: Set<String>
    let blockedUsers: Set<String>
    
    static let `default` = FeedTunerSettings(
        hideReplies: false,
        hideRepliesByUnfollowed: false,
        hideReposts: false,
        hideQuotePosts: false,
        hideNonPreferredLanguages: false,
        preferredLanguages: [],
        mutedUsers: [],
        blockedUsers: []
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
  func tune(_ rawPosts: [AppBskyFeedDefs.FeedViewPost], filterSettings: FeedTunerSettings = .default) -> [FeedSlice] {
    logger.debug("🧵 FeedTuner.tune() called with \(rawPosts.count) raw posts")
    
    // Apply content filtering first
    let filteredPosts = applyContentFiltering(rawPosts, settings: filterSettings)
    logger.debug("🧵 Filtered \(rawPosts.count) posts to \(filteredPosts.count) posts")
    
    // Reset seen tracking for new batch
    seenKeys.removeAll()
    seenUris.removeAll()
    
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
        allSlices.append(threadSlice)
      }
    }
    
    // Apply deduplication as final safety net
    let dedupedSlices = deduplicateSlicesOptimized(allSlices)
    
    logger.debug("🧵 FeedTuner completed: \(rawPosts.count) posts → \(filteredPosts.count) filtered → \(dedupedSlices.count) slices (fixed duplicates & order)")
    
    return dedupedSlices
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
    // 1. If root post is in the feed, use it
    // 2. Otherwise, use the most recent post in the group
    let primaryPost: AppBskyFeedDefs.FeedViewPost
    if let rootPost = sortedPosts.first(where: { $0.post.uri.uriString() == rootUri }) {
      primaryPost = rootPost
    } else {
      primaryPost = sortedPosts.last! // Most recent post
    }
    
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
  
  // MARK: - Content Filtering
  
  /// Apply content filtering based on user preferences
  private func applyContentFiltering(_ posts: [AppBskyFeedDefs.FeedViewPost], settings: FeedTunerSettings) -> [AppBskyFeedDefs.FeedViewPost] {
    var filteredPosts: [AppBskyFeedDefs.FeedViewPost] = []
    
    for post in posts {
      // Check if post author is blocked (blocks are stronger than mutes)
      let authorDID = post.post.author.did.didString()
      if settings.blockedUsers.contains(authorDID) {
        logger.debug("Filtering out post from blocked user: \(post.post.author.handle)")
        continue
      }
      
      // Check if post author is muted
      if settings.mutedUsers.contains(authorDID) {
        logger.debug("Filtering out post from muted user: \(post.post.author.handle)")
        continue
      }
      
      // Check if root post author is blocked (for replies to blocked users)
      if let reply = post.reply,
         case .appBskyFeedDefsPostView(let rootPost) = reply.root {
        let rootAuthorDID = rootPost.author.did.didString()
        if settings.blockedUsers.contains(rootAuthorDID) {
          logger.debug("Filtering out reply to blocked user: \(rootPost.author.handle)")
          continue
        }
        if settings.mutedUsers.contains(rootAuthorDID) {
          logger.debug("Filtering out reply to muted user: \(rootPost.author.handle)")
          continue
        }
      }
      
      // Check if parent post author is blocked/muted (for replies in threads)
      if let reply = post.reply,
         case .appBskyFeedDefsPostView(let parentPost) = reply.parent {
        let parentAuthorDID = parentPost.author.did.didString()
        if settings.blockedUsers.contains(parentAuthorDID) {
          logger.debug("Filtering out reply to blocked parent: \(parentPost.author.handle)")
          continue
        }
        if settings.mutedUsers.contains(parentAuthorDID) {
          logger.debug("Filtering out reply to muted parent: \(parentPost.author.handle)")
          continue
        }
      }
      
      // Check if this is a reply
      let isReply = post.reply != nil
      if settings.hideReplies && isReply {
        logger.debug("Filtering out reply post: \(post.post.uri.uriString())")
        continue
      }
      
      // Check if this is a repost (has reason)
      let isRepost = post.reason != nil
      if isRepost {
        // Check if the reposter is blocked/muted
        if case .appBskyFeedDefsReasonRepost(let repostReason) = post.reason {
          let reposterDID = repostReason.by.did.didString()
          if settings.blockedUsers.contains(reposterDID) {
            logger.debug("Filtering out repost by blocked user: \(repostReason.by.handle)")
            continue
          }
          if settings.mutedUsers.contains(reposterDID) {
            logger.debug("Filtering out repost by muted user: \(repostReason.by.handle)")
            continue
          }
        }
        
        // Check if user wants to hide all reposts
        if settings.hideReposts {
          logger.debug("Filtering out repost: \(post.post.uri.uriString())")
          continue
        }
      }
      
      // Apply language filtering if enabled
      if settings.hideNonPreferredLanguages && !settings.preferredLanguages.isEmpty {
        // Extract post record to check languages
        if case .knownType(let record) = post.post.record,
           let feedPost = record as? AppBskyFeedPost {
          
          var hasPreferredLanguage = false
          
          // First check if post has language metadata
          if let postLanguages = feedPost.langs, !postLanguages.isEmpty {
            // Check if any of the post's languages match user's preferred languages
            hasPreferredLanguage = postLanguages.contains { postLangContainer in
              settings.preferredLanguages.contains { prefLang in
                // Compare language codes (e.g., "en" == "en")
                let postLangCode = postLangContainer.lang.languageCode?.identifier ?? postLangContainer.lang.minimalIdentifier
                return postLangCode == prefLang
              }
            }
          } else {
            // No language metadata - use language detection
            let postText = feedPost.text
            if !postText.isEmpty {
              let detectedLanguage = LanguageDetector.shared.detectLanguage(for: postText)
              if let detectedLang = detectedLanguage {
                hasPreferredLanguage = settings.preferredLanguages.contains(detectedLang)
                logger.debug("Detected language '\(detectedLang)' for post without language metadata")
              } else {
                // Could not detect language - allow it through
                hasPreferredLanguage = true
              }
            } else {
              // No text content - allow it through (might be image-only post)
              hasPreferredLanguage = true
            }
          }
          
          if !hasPreferredLanguage {
            logger.debug("Filtering out post with non-preferred language")
            continue
          }
        }
        // If we can't decode the post, allow it through
      }
      
      // Check if this is a quote post
      // Quote posts have embedded records that are posts
      let isQuotePost: Bool = {
        guard case .knownType(let record) = post.post.record,
              let feedPost = record as? AppBskyFeedPost else {
          return false
        }
        
        if let embed = feedPost.embed {
          switch embed {
          case .appBskyEmbedRecord(let recordEmbed):
            // This indicates a quote post (embedded record)
            return true
          case .appBskyEmbedRecordWithMedia(let recordWithMedia):
            // This indicates a quote post with media
            return true
          default:
            break
          }
        }
        return false
      }()
      
      if settings.hideQuotePosts && isQuotePost {
        logger.debug("Filtering out quote post: \(post.post.uri.uriString())")
        continue
      }
      
      // Check if this is a reply from someone we don't follow
      if settings.hideRepliesByUnfollowed && isReply {
        // Check if the post author is followed by the current user
        let isFollowing = post.post.author.viewer?.following != nil
        
        if !isFollowing {
          logger.debug("Filtering out reply from unfollowed user: \(post.post.author.handle)")
          continue
        }
      }
      
      // If we reach here, the post passed all filters
      filteredPosts.append(post)
    }
    
    return filteredPosts
  }
}
