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
}
