import Foundation
import SwiftData
import Petrel

/// A model class for caching feed posts in SwiftData
@Model
final class CachedFeedViewPost: Identifiable {
    /// Unique identifier for the post
    @Attribute(.unique) var id: String
    
    /// The feed type this post belongs to
    var feedType: String
    
    /// Serialized FeedViewPost data
    var serializedPost: Data
    
    /// Cursor value for pagination
    var cursor: String?
    
    /// Timestamp when the post was cached
    var cachedAt: Date
    
    /// The post's creation timestamp for sorting
    var createdAt: Date
    
    /// Thread metadata (optional, for enhanced thread display)
    var threadDisplayMode: String?
    var threadPostCount: Int?
    var threadHiddenCount: Int?
    var isPartOfThread: Bool
    var isIncompleteThread: Bool
    
    /// Serialized slice items for thread display (stores all posts in the thread)
    var serializedSliceItems: Data?
    
    /// Indicates if this is a temporary/optimistic post that hasn't been confirmed by the server
    @Transient var isTemporary: Bool = false
    
    /// Initializer from a FeedViewPost with backwards compatibility
    init(feedViewPost: AppBskyFeedDefs.FeedViewPost) {
        self.id = "\(feedViewPost.post.uri.uriString())-\(feedViewPost.post.cid)"
        self.feedType = "timeline" // Default feed type for compatibility
        self.serializedPost = try! JSONEncoder().encode(feedViewPost)
        self.cursor = nil
        self.cachedAt = Date()
        
        // Extract creation date for sorting
        if case .knownType(let record) = feedViewPost.post.record,
           let feedPost = record as? AppBskyFeedPost {
            self.createdAt = feedPost.createdAt.date
        } else {
            self.createdAt = feedViewPost.post.indexedAt.date
        }
        
        // Initialize thread metadata with defaults
        self.threadDisplayMode = nil
        self.threadPostCount = nil
        self.threadHiddenCount = nil
        self.isPartOfThread = false
        self.isIncompleteThread = false
        self.serializedSliceItems = nil
    }
    
    /// Full initializer with all parameters
    init(from feedViewPost: AppBskyFeedDefs.FeedViewPost, cursor: String? = nil, feedType: String) {
        self.id = "\(feedViewPost.post.uri.uriString())-\(feedViewPost.post.cid)"
        self.feedType = feedType
        self.serializedPost = try! JSONEncoder().encode(feedViewPost)
        self.cursor = cursor
        self.cachedAt = Date()
        
        // Extract creation date for sorting
        if case .knownType(let record) = feedViewPost.post.record,
           let feedPost = record as? AppBskyFeedPost {
            self.createdAt = feedPost.createdAt.date
        } else {
            self.createdAt = feedViewPost.post.indexedAt.date
        }
        
        // Initialize thread metadata with defaults
        self.threadDisplayMode = nil
        self.threadPostCount = nil
        self.threadHiddenCount = nil
        self.isPartOfThread = false
        self.isIncompleteThread = false
        self.serializedSliceItems = nil
    }
    
    /// Initializer with thread metadata
    init(from enhanced: EnhancedCachedFeedViewPost, feedType: String = "timeline") {
        let feedViewPost = enhanced.feedViewPost
        self.id = "\(feedViewPost.post.uri.uriString())-\(feedViewPost.post.cid)"
        self.feedType = feedType
        self.serializedPost = try! JSONEncoder().encode(feedViewPost)
        self.cursor = nil
        self.cachedAt = Date()
        
        // Extract creation date for sorting
        if case .knownType(let record) = feedViewPost.post.record,
           let feedPost = record as? AppBskyFeedPost {
            self.createdAt = feedPost.createdAt.date
        } else {
            self.createdAt = feedViewPost.post.indexedAt.date
        }
        
        // Set thread metadata
        self.isPartOfThread = enhanced.isPartOfLargerThread
        self.isIncompleteThread = false
        
        if let threadGroup = enhanced.threadGroup {
            switch threadGroup.displayMode {
            case .standard:
                self.threadDisplayMode = "standard"
                self.threadPostCount = threadGroup.posts.count
                self.threadHiddenCount = 0
            case .expandedThread(let count):
                self.threadDisplayMode = "expanded"
                self.threadPostCount = count
                self.threadHiddenCount = 0
            case .collapsedThread(let hiddenCount):
                self.threadDisplayMode = "collapsed"
                self.threadPostCount = threadGroup.posts.count
                self.threadHiddenCount = hiddenCount
            }
        } else {
            self.threadDisplayMode = nil
            self.threadPostCount = nil
            self.threadHiddenCount = nil
        }
    }
    
    /// Initializer from FeedSlice (following React Native pattern)
    init(from slice: FeedSlice, feedType: String = "timeline") {
        // Use the main post (last item in slice, which is the actual feed post)
        guard let mainItem = slice.items.last else {
            fatalError("FeedSlice must have at least one item")
        }
        
        // Create a FeedViewPost from the slice data
        let feedViewPost = AppBskyFeedDefs.FeedViewPost(
            post: mainItem.post,
            reply: Self.createReplyRefFromSlice(slice),
            reason: slice.reason,
            feedContext: slice.feedContext
        )
        
        self.id = "\(mainItem.post.uri.uriString())-\(mainItem.post.cid)"
        self.feedType = feedType
        self.serializedPost = try! JSONEncoder().encode(feedViewPost)
        self.cursor = nil
        self.cachedAt = Date()
        
        // Extract creation date for sorting
        self.createdAt = mainItem.record.createdAt.date
        
        // Store slice items for thread rendering
        self.serializedSliceItems = try? JSONEncoder().encode(slice.items)
        
        // Set thread metadata from slice
        self.isPartOfThread = slice.shouldShowAsThread
        self.isIncompleteThread = slice.isIncompleteThread
        
        if slice.items.count > 1 {
            if slice.isIncompleteThread && slice.items.count >= 3 {
                // Collapsed thread mode (like React Native)
                self.threadDisplayMode = "collapsed"
                self.threadPostCount = slice.items.count
                self.threadHiddenCount = max(0, slice.items.count - 3)
                logger.debug("🔍 CachedFeedViewPost: \(mainItem.post.uri.uriString()) -> COLLAPSED (\(slice.items.count) items, incomplete=\(slice.isIncompleteThread))")
            } else {
                // Expanded thread mode
                self.threadDisplayMode = "expanded"
                self.threadPostCount = slice.items.count
                self.threadHiddenCount = 0
                logger.debug("🔍 CachedFeedViewPost: \(mainItem.post.uri.uriString()) -> EXPANDED (\(slice.items.count) items, incomplete=\(slice.isIncompleteThread))")
            }
        } else {
            // Standard mode
            self.threadDisplayMode = "standard"
            self.threadPostCount = 1
            self.threadHiddenCount = 0
        }
    }
    
    /// Creates ReplyRef from slice items (reconstructing the thread structure)
    private static func createReplyRefFromSlice(_ slice: FeedSlice) -> AppBskyFeedDefs.ReplyRef? {
        guard slice.items.count > 1 else { return nil }
        
        // Find parent (second to last item) and root (first item)
        let parentItem = slice.items.count > 1 ? slice.items[slice.items.count - 2] : nil
        let rootItem = slice.items.first
        
        guard let parentItem = parentItem, let rootItem = rootItem else { return nil }
        
        let parent = AppBskyFeedDefs.ReplyRefParentUnion.appBskyFeedDefsPostView(parentItem.post)
        let root = AppBskyFeedDefs.ReplyRefRootUnion.appBskyFeedDefsPostView(rootItem.post)
        
        // Use grandparent author if available
        let grandparentAuthor = slice.items.count > 2 ? slice.items[slice.items.count - 3].post.author : nil
        
        return AppBskyFeedDefs.ReplyRef(
            root: root,
            parent: parent,
            grandparentAuthor: grandparentAuthor
        )
    }
    
    /// Reconstructs the original FeedViewPost
    var feedViewPost: AppBskyFeedDefs.FeedViewPost {
        get {
            do {
                return try JSONDecoder().decode(AppBskyFeedDefs.FeedViewPost.self, from: serializedPost)
            } catch {
                fatalError("Failed to decode cached post: \(error)")
            }
        }
    }
    
    /// Accessor for post URI (for compatibility with existing code)
    var uri: ATProtocolURI {
        return feedViewPost.post.uri
    }
    
    /// Accessor for post viewer state (for compatibility)
    var viewer: AppBskyFeedDefs.ViewerState? {
        return feedViewPost.post.viewer
    }
    
    /// Reconstructs the slice items for thread rendering
    var sliceItems: [FeedSliceItem]? {
        guard let data = serializedSliceItems else { return nil }
        return try? JSONDecoder().decode([FeedSliceItem].self, from: data)
    }
}
