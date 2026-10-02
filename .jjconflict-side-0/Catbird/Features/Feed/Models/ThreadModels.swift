import Foundation
import Petrel
import SwiftUI

// MARK: - Thread Display Models

/// Defines how a thread should be displayed in the feed
enum ThreadDisplayMode: Hashable, Sendable {
  /// Standard display: parent + main post (current behavior, max 2 posts)
  case standard
  
  /// Expanded thread: 2-3 consecutive posts shown in sequence
  case expandedThread(postCount: Int)
  
  /// Collapsed thread: root + "[...] View full thread" + bottom 2 replies
  case collapsedThread(hiddenCount: Int)
}

/// Represents a group of posts that should be displayed together as a thread
struct ThreadGroup: Identifiable, Hashable, Sendable {
  let id: String
  let displayMode: ThreadDisplayMode
  let posts: [AppBskyFeedDefs.FeedViewPost]
  let rootPost: AppBskyFeedDefs.FeedViewPost?
  let continuation: ThreadContinuation?
  
  init(
    displayMode: ThreadDisplayMode,
    posts: [AppBskyFeedDefs.FeedViewPost],
    rootPost: AppBskyFeedDefs.FeedViewPost? = nil,
    continuation: ThreadContinuation? = nil
  ) {
    self.id = posts.first?.post.uri.uriString() ?? UUID().uuidString
    self.displayMode = displayMode
    self.posts = posts
    self.rootPost = rootPost
    self.continuation = continuation
  }
  
  /// The main post to display (usually the last in the sequence)
  var primaryPost: AppBskyFeedDefs.FeedViewPost? {
    posts.last
  }
  
  /// Additional context posts to show before the primary post
  var contextPosts: [AppBskyFeedDefs.FeedViewPost] {
    Array(posts.dropLast())
  }
}

/// Represents hidden posts in a collapsed thread display
struct ThreadContinuation: Hashable, Sendable {
  let hiddenPostCount: Int
  let nextVisiblePosts: [AppBskyFeedDefs.FeedViewPost]
  let fullThreadUri: String?
  
  init(
    hiddenPostCount: Int,
    nextVisiblePosts: [AppBskyFeedDefs.FeedViewPost] = [],
    fullThreadUri: String? = nil
  ) {
    self.hiddenPostCount = hiddenPostCount
    self.nextVisiblePosts = nextVisiblePosts
    self.fullThreadUri = fullThreadUri
  }
}

// MARK: - Thread Chain Analysis

/// Represents a chain of connected posts in a thread
struct ThreadChain: Hashable, Sendable {
  let posts: [AppBskyFeedDefs.FeedViewPost]
  let rootUri: String
  let participants: Set<String> // DIDs of authors
  let isConversation: Bool // More than one participant
  let isSelfThread: Bool // Single author responding to themselves
  
  init(posts: [AppBskyFeedDefs.FeedViewPost]) {
    self.posts = posts
    self.rootUri = posts.first?.post.uri.uriString() ?? ""
    
    let authors = Set(posts.map { $0.post.author.did.didString() })
    self.participants = authors
    self.isConversation = authors.count > 1
    self.isSelfThread = authors.count == 1
  }
  
  var length: Int { posts.count }
  var isShort: Bool { length <= 3 }
  var isLong: Bool { length > 3 }
}

// MARK: - Enhanced Cached Feed Post

/// Extended version of CachedFeedViewPost that includes thread metadata
struct EnhancedCachedFeedViewPost: Identifiable, Hashable {
  let id: String
  let feedViewPost: AppBskyFeedDefs.FeedViewPost
  let threadGroup: ThreadGroup?
  let isPartOfLargerThread: Bool
  let isDuplicate: Bool // Marked for removal due to thread consolidation
  
  init(
    feedViewPost: AppBskyFeedDefs.FeedViewPost,
    threadGroup: ThreadGroup? = nil,
    isPartOfLargerThread: Bool = false,
    isDuplicate: Bool = false
  ) {
    self.feedViewPost = feedViewPost
    self.threadGroup = threadGroup
    self.isPartOfLargerThread = isPartOfLargerThread
    self.isDuplicate = isDuplicate
    
    // Create a unique ID that includes thread context
    if let threadGroup = threadGroup {
      self.id = "\(threadGroup.id)-\(feedViewPost.post.uri.uriString())"
    } else {
      self.id = feedViewPost.post.uri.uriString()
    }
  }
  
  /// Whether this post should be rendered with thread-aware UI
  var shouldDisplayAsThread: Bool {
    threadGroup != nil && !isDuplicate
  }
  
  /// The display mode for this post's thread representation
  var displayMode: ThreadDisplayMode {
    threadGroup?.displayMode ?? .standard
  }
}

// MARK: - Thread Processing Configuration

/// Configuration options for thread processing behavior
struct ThreadProcessingConfig {
  /// Maximum number of posts to show in expanded thread mode
  let maxExpandedThreadPosts: Int
  
  /// Minimum number of posts required to consider collapsed thread mode
  let minPostsForCollapsedThread: Int
  
  /// Whether to prioritize showing conversations between different users
  let prioritizeConversations: Bool
  
  /// Whether to consolidate self-reply chains
  let consolidateSelfReplies: Bool
  
  /// Time threshold for considering posts as part of the same thread
  let threadTimeThreshold: TimeInterval
  
  static let `default` = ThreadProcessingConfig(
    maxExpandedThreadPosts: 3,
    minPostsForCollapsedThread: 4,
    prioritizeConversations: true,
    consolidateSelfReplies: true,
    threadTimeThreshold: 3600 // 1 hour
  )
}
