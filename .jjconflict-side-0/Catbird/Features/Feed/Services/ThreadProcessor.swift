import Foundation
import Petrel
import OSLog

/// Processes feed posts to detect and consolidate thread relationships

final class ThreadProcessor {
  
  // MARK: - Properties
  
  private let config: ThreadProcessingConfig
  private let logger = Logger(subsystem: "blue.catbird.app", category: "ThreadProcessor")
  
  // MARK: - Initialization
  
  init(config: ThreadProcessingConfig = .default) {
    self.config = config
  }
  
  // MARK: - Main Processing
  
  /// Processes a list of feed posts to detect threads and eliminate duplicates
  func processPostsForThreads(
    _ posts: [AppBskyFeedDefs.FeedViewPost]
  ) -> [EnhancedCachedFeedViewPost] {
    logger.debug("Processing \(posts.count) posts for thread consolidation")
    
    // Step 1: Build relationship maps
    let relationshipMaps = buildRelationshipMaps(posts)
    
    // Step 2: Identify thread chains
    let threadChains = identifyThreadChains(posts, using: relationshipMaps)
    
    // Step 3: Determine display modes for each chain
    let threadGroups = determineDisplayModes(for: threadChains, in: posts)
    
    // Step 4: Create enhanced posts with thread metadata
    let enhancedPosts = createEnhancedPosts(
      from: posts,
      threadGroups: threadGroups,
      relationshipMaps: relationshipMaps
    )
    
    // Step 5: Eliminate duplicates
    let finalPosts = eliminateDuplicates(enhancedPosts)
    
    logger.debug("Thread processing complete: \(posts.count) → \(finalPosts.count) posts")
    
    return finalPosts
  }
  
  // MARK: - Relationship Mapping
  
  private struct RelationshipMaps {
    let parentMap: [String: String] // child URI -> parent URI
    let childrenMap: [String: [String]] // parent URI -> [child URIs]
    let postMap: [String: AppBskyFeedDefs.FeedViewPost] // URI -> post
  }
  
  private func buildRelationshipMaps(
    _ posts: [AppBskyFeedDefs.FeedViewPost]
  ) -> RelationshipMaps {
    var parentMap: [String: String] = [:]
    var childrenMap: [String: [String]] = [:]
    var postMap: [String: AppBskyFeedDefs.FeedViewPost] = [:]
    
    // Build post lookup map
    for post in posts {
      let uri = post.post.uri.uriString()
      postMap[uri] = post
    }
    
    // Build parent-child relationships
    for post in posts {
      let childUri = post.post.uri.uriString()
      
      // Check if this post has a parent
      if let replyRef = post.reply {
        switch replyRef.parent {
        case .appBskyFeedDefsPostView(let parentView):
          let parentUri = parentView.uri.uriString()
          
          // Record parent relationship
          parentMap[childUri] = parentUri
          
          // Record child relationship
          if childrenMap[parentUri] == nil {
            childrenMap[parentUri] = []
          }
          childrenMap[parentUri]?.append(childUri)
          
        default:
          break
        }
      }
    }
    
    return RelationshipMaps(
      parentMap: parentMap,
      childrenMap: childrenMap,
      postMap: postMap
    )
  }
  
  // MARK: - Thread Chain Identification
  
  private func identifyThreadChains(
    _ posts: [AppBskyFeedDefs.FeedViewPost],
    using maps: RelationshipMaps
  ) -> [ThreadChain] {
    var visited: Set<String> = []
    var chains: [ThreadChain] = []
    
    for post in posts {
      let uri = post.post.uri.uriString()
      
      // Skip if already processed
      if visited.contains(uri) {
        continue
      }
      
      // Find the root of this thread
      let rootUri = findRootUri(for: uri, using: maps.parentMap)
      
      // If root is not in our current feed, start from this post
      let startUri = maps.postMap[rootUri] != nil ? rootUri : uri
      
      // Build chain starting from this point
      let chainPosts = buildChainFromPost(startUri, using: maps, visited: &visited)
      
      if chainPosts.count > 1 {
        let chain = ThreadChain(posts: chainPosts)
        chains.append(chain)
      }
    }
    
    return chains
  }
  
  private func findRootUri(for uri: String, using parentMap: [String: String]) -> String {
    var currentUri = uri
    var visited: Set<String> = []
    
    while let parentUri = parentMap[currentUri] {
      // Prevent infinite loops
      if visited.contains(currentUri) {
        break
      }
      visited.insert(currentUri)
      currentUri = parentUri
    }
    
    return currentUri
  }
  
  private func buildChainFromPost(
    _ startUri: String,
    using maps: RelationshipMaps,
    visited: inout Set<String>
  ) -> [AppBskyFeedDefs.FeedViewPost] {
    var chain: [AppBskyFeedDefs.FeedViewPost] = []
    var queue: [String] = [startUri]
    
    while !queue.isEmpty {
      let currentUri = queue.removeFirst()
      
      // Skip if already processed
      if visited.contains(currentUri) {
        continue
      }
      
      // Mark as visited
      visited.insert(currentUri)
      
      // Add post to chain if it exists in our feed
      if let post = maps.postMap[currentUri] {
        chain.append(post)
      }
      
      // Add children to queue (in chronological order)
      if let children = maps.childrenMap[currentUri] {
        let sortedChildren = children.compactMap { maps.postMap[$0] }
          .sorted { post1, post2 in
            guard case .knownType(let record1) = post1.post.record,
                  let feedPost1 = record1 as? AppBskyFeedPost,
                  case .knownType(let record2) = post2.post.record,
                  let feedPost2 = record2 as? AppBskyFeedPost else {
              return false
            }
            return feedPost1.createdAt.date < feedPost2.createdAt.date
          }
        
        queue.append(contentsOf: sortedChildren.map { $0.post.uri.uriString() })
      }
    }
    
    // Sort final chain chronologically
    return chain.sorted { post1, post2 in
      guard case .knownType(let record1) = post1.post.record,
            let feedPost1 = record1 as? AppBskyFeedPost,
            case .knownType(let record2) = post2.post.record,
            let feedPost2 = record2 as? AppBskyFeedPost else {
        return false
      }
      return feedPost1.createdAt.date < feedPost2.createdAt.date
    }
  }
  
  // MARK: - Display Mode Determination
  
  private func determineDisplayModes(
    for chains: [ThreadChain],
    in posts: [AppBskyFeedDefs.FeedViewPost]
  ) -> [ThreadGroup] {
    return chains.compactMap { chain in
      let displayMode = selectDisplayMode(for: chain)
      let processedPosts = selectPostsForDisplay(chain: chain, mode: displayMode)
      
      guard !processedPosts.isEmpty else { return nil }
      
      let rootPost = chain.posts.first
      let continuation = createContinuation(for: chain, mode: displayMode)
      
      return ThreadGroup(
        displayMode: displayMode,
        posts: processedPosts,
        rootPost: rootPost,
        continuation: continuation
      )
    }
  }
  
  private func selectDisplayMode(for chain: ThreadChain) -> ThreadDisplayMode {
    // Analyze chain characteristics
    let length = chain.length
    let isConversation = chain.isConversation
    let isSelfThread = chain.isSelfThread
    
    // Decision logic
    if length <= 2 {
      return .standard
    }
    
    if length <= config.maxExpandedThreadPosts {
      // Use expanded mode for short conversations or self-threads
      if isConversation || (isSelfThread && config.consolidateSelfReplies) {
        return .expandedThread(postCount: length)
      }
    }
    
    if length >= config.minPostsForCollapsedThread {
      // Use collapsed mode for longer threads
      let hiddenCount = max(0, length - 3) // Show first + last 2
      return .collapsedThread(hiddenCount: hiddenCount)
    }
    
    return .standard
  }
  
  private func selectPostsForDisplay(
    chain: ThreadChain,
    mode: ThreadDisplayMode
  ) -> [AppBskyFeedDefs.FeedViewPost] {
    switch mode {
    case .standard:
      // Standard: just parent + child (existing behavior)
      return Array(chain.posts.prefix(2))
      
    case .expandedThread(let count):
      // Expanded: up to N posts in sequence
      return Array(chain.posts.prefix(count))
      
    case .collapsedThread:
      // Collapsed: first post + last 2 posts
      if chain.posts.count <= 3 {
        return chain.posts
      }
      
      let first = chain.posts.first
      let lastTwo = Array(chain.posts.suffix(2))
      
      var result: [AppBskyFeedDefs.FeedViewPost] = []
      if let first = first {
        result.append(first)
      }
      result.append(contentsOf: lastTwo)
      
      return result
    }
  }
  
  private func createContinuation(
    for chain: ThreadChain,
    mode: ThreadDisplayMode
  ) -> ThreadContinuation? {
    switch mode {
    case .collapsedThread(let hiddenCount):
      if hiddenCount > 0 {
        let nextVisible = Array(chain.posts.suffix(2))
        return ThreadContinuation(
          hiddenPostCount: hiddenCount,
          nextVisiblePosts: nextVisible,
          fullThreadUri: chain.rootUri
        )
      }
      return nil
      
    default:
      return nil
    }
  }
  
  // MARK: - Enhanced Post Creation
  
  private func createEnhancedPosts(
    from posts: [AppBskyFeedDefs.FeedViewPost],
    threadGroups: [ThreadGroup],
    relationshipMaps: RelationshipMaps
  ) -> [EnhancedCachedFeedViewPost] {
    // Create lookup map for thread groups
    var threadGroupMap: [String: ThreadGroup] = [:]
    var threadsPostUris: Set<String> = []
    
    for group in threadGroups {
      for post in group.posts {
        let uri = post.post.uri.uriString()
        threadGroupMap[uri] = group
        threadsPostUris.insert(uri)
      }
    }
    
    // Create enhanced posts
    return posts.map { post in
      let uri = post.post.uri.uriString()
      let threadGroup = threadGroupMap[uri]
      let isPartOfLargerThread = threadsPostUris.contains(uri)
      
      return EnhancedCachedFeedViewPost(
        feedViewPost: post,
        threadGroup: threadGroup,
        isPartOfLargerThread: isPartOfLargerThread,
        isDuplicate: false
      )
    }
  }
  
  // MARK: - Duplicate Elimination
  
  private func eliminateDuplicates(
    _ enhancedPosts: [EnhancedCachedFeedViewPost]
  ) -> [EnhancedCachedFeedViewPost] {
    var result: [EnhancedCachedFeedViewPost] = []
    var processedUris: Set<String> = []
    
    for post in enhancedPosts {
      let uri = post.feedViewPost.post.uri.uriString()
      
      // Skip if this post is better represented in a thread group
      if shouldSkipForThreadConsolidation(post, in: enhancedPosts) {
        continue
      }
      
      // Skip duplicates
      if processedUris.contains(uri) {
        continue
      }
      
      processedUris.insert(uri)
      result.append(post)
    }
    
    return result
  }
  
  private func shouldSkipForThreadConsolidation(
    _ post: EnhancedCachedFeedViewPost,
    in allPosts: [EnhancedCachedFeedViewPost]
  ) -> Bool {
    let uri = post.feedViewPost.post.uri.uriString()
    
    // Don't skip if this post is the primary post in a thread group
    if let threadGroup = post.threadGroup,
        threadGroup.primaryPost?.post.uri.uriString() == uri {
      return false
    }
    
    // Skip if this post appears as a context post in another thread group
    for otherPost in allPosts {
      if let otherThreadGroup = otherPost.threadGroup,
         otherThreadGroup.contextPosts.contains(where: { $0.post.uri.uriString() == uri }),
         otherPost.id != post.id {
        return true
      }
    }
    
    return false
  }
}
