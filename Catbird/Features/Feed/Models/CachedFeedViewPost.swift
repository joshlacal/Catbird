import Foundation
import SwiftData
import Petrel
import OSLog
import NaturalLanguage

private let cachedPostLogger = Logger(subsystem: "blue.catbird.Catbird", category: "CachedFeedViewPost")

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
    init?(feedViewPost: AppBskyFeedDefs.FeedViewPost) {
        self.id = "\(feedViewPost.post.uri.uriString())-\(feedViewPost.post.cid)"
        self.feedType = "timeline" // Default feed type for compatibility
        do {
            self.serializedPost = try JSONEncoder().encode(feedViewPost)
        } catch {
            cachedPostLogger.error("Failed to encode feedViewPost: \(error)")
            return nil
        }
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
        self.isTemporary = false // Default to false for cached posts

    }
    
    /// Full initializer with all parameters
    init?(from feedViewPost: AppBskyFeedDefs.FeedViewPost, cursor: String? = nil, feedType: String) {
        self.id = "\(feedViewPost.post.uri.uriString())-\(feedViewPost.post.cid)"
        self.feedType = feedType
        do {
            self.serializedPost = try JSONEncoder().encode(feedViewPost)
        } catch {
            cachedPostLogger.error("Failed to encode feedViewPost: \(error)")
            return nil
        }
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
        self.isTemporary = false
    }
    
    /// Initializer with thread metadata
    init?(from enhanced: EnhancedCachedFeedViewPost, feedType: String = "timeline") {
        let feedViewPost = enhanced.feedViewPost
        self.id = "\(feedViewPost.post.uri.uriString())-\(feedViewPost.post.cid)"
        self.feedType = feedType
        do {
            self.serializedPost = try JSONEncoder().encode(feedViewPost)
        } catch {
            cachedPostLogger.error("Failed to encode feedViewPost: \(error)")
            return nil
        }
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
        self.serializedSliceItems = nil
        self.isTemporary = false
    }
    
    /// Initializer from FeedSlice (following React Native pattern)
    init?(from slice: FeedSlice, feedType: String = "timeline") {
        // Use the main post (last item in slice, which is the actual feed post)
        guard let mainItem = slice.items.last else {
            cachedPostLogger.warning("FeedSlice has no items, cannot create CachedFeedViewPost")
            return nil
        }

        // Create a FeedViewPost from the slice data
        let feedViewPost = AppBskyFeedDefs.FeedViewPost(
            post: mainItem.post,
            reply: slice.originalReply ?? Self.createReplyRefFromSlice(slice),
            reason: slice.reason,
            feedContext: slice.feedContext,
            reqId: nil
        )

        self.id = "\(mainItem.post.uri.uriString())-\(mainItem.post.cid)"
        self.feedType = feedType
        do {
            self.serializedPost = try JSONEncoder().encode(feedViewPost)
        } catch {
            cachedPostLogger.error("Failed to encode feedViewPost: \(error)")
            return nil
        }
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
            } else {
                // Expanded thread mode
                self.threadDisplayMode = "expanded"
                self.threadPostCount = slice.items.count
                self.threadHiddenCount = 0
            }
        } else {
            // Standard mode
            self.threadDisplayMode = "standard"
            self.threadPostCount = 1
            self.threadHiddenCount = 0
        }

        self.isTemporary = false
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
        get throws {
            do {
                return try JSONDecoder().decode(AppBskyFeedDefs.FeedViewPost.self, from: serializedPost)
            } catch {
                cachedPostLogger.error("Failed to decode cached post: \(error)")
                throw error
            }
        }
    }
    
    /// Accessor for post URI (for compatibility with existing code)
    var uri: ATProtocolURI? {
        try? feedViewPost.post.uri
    }

    /// Accessor for post viewer state (for compatibility)
    var viewer: AppBskyFeedDefs.ViewerState? {
        (try? feedViewPost)?.post.viewer
    }
    
    /// Reconstructs the slice items for thread rendering
    var sliceItems: [FeedSliceItem]? {
        guard let data = serializedSliceItems else { return nil }
        return try? JSONDecoder().decode([FeedSliceItem].self, from: data)
    }
    
    /// Computed property to check if this cached post represents a thread slice
    var isThreadSlice: Bool {
        return sliceItems != nil && (sliceItems?.count ?? 0) > 1
    }
    
    /// Computed property to get the thread slice representation
    var threadSlice: FeedSlice? {
        guard let items = sliceItems, !items.isEmpty else { return nil }
        guard let fvp = try? feedViewPost else { return nil }

        // Reconstruct FeedSlice from cached data
        let rootUri: String
        if let reply = fvp.reply,
           case .appBskyFeedDefsPostView(let rootPost) = reply.root {
            rootUri = rootPost.uri.uriString()
        } else {
            rootUri = fvp.post.uri.uriString()
        }

        return FeedSlice(
            items: items,
            isIncompleteThread: isIncompleteThread,
            rootUri: rootUri,
            feedPostUri: fvp.post.uri.uriString(),
            reason: fvp.reason,
            feedContext: fvp.feedContext
        )
    }
    
}

// MARK: - Embedding helpers

extension CachedFeedViewPost {
    /// Extract the primary AppBskyFeedPost contained in this cached item (the main visible post/reply).
    var mainFeedPost: AppBskyFeedPost? {
        guard let fvp = try? self.feedViewPost else { return nil }
        if case let .knownType(record) = fvp.post.record, let post = record as? AppBskyFeedPost {
            return post
        }
        return nil
    }

    /// Extract ancillary AppBskyFeedPost objects referenced by this feed row (parent/root/quoted if available).
    func ancillaryFeedPosts() -> [AppBskyFeedPost] {
        var results: [AppBskyFeedPost] = []
        guard let fvp = try? self.feedViewPost else { return results }

        // Parent
        if let reply = fvp.reply {
            if case .appBskyFeedDefsPostView(let parent) = reply.parent,
               case let .knownType(rec) = parent.record,
               let p = rec as? AppBskyFeedPost {
                results.append(p)
            }
            // Root
            if case .appBskyFeedDefsPostView(let root) = reply.root,
               case let .knownType(rec) = root.record,
               let r = rec as? AppBskyFeedPost {
                results.append(r)
            }
        }

        // Quoted record (if any)
        if let embed = fvp.post.embed {
            switch embed {
            case .appBskyEmbedRecordView(let recordView):
                if case .appBskyEmbedRecordViewRecord(let vr) = recordView.record,
                   case let .knownType(rec) = vr.value,
                   let qp = rec as? AppBskyFeedPost { results.append(qp) }
            case .appBskyEmbedRecordWithMediaView(let recordWithMedia):
                if case .appBskyEmbedRecordViewRecord(let vr) = recordWithMedia.record.record,
                   case let .knownType(rec) = vr.value,
                   let qp = rec as? AppBskyFeedPost { results.append(qp) }
            default: break
            }
        }

        return results
    }
}
