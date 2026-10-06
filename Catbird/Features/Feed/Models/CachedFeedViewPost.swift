import Foundation
import SwiftData
import Petrel
import OSLog
import NaturalLanguage

private let cachedPostLogger = Logger(subsystem: "blue.catbird.Catbird", category: "CachedFeedViewPost")

/// A model class for caching feed posts in SwiftData
@Model
final class CachedFeedViewPost: Identifiable {
    /// Globally unique feed-entry identifier. `feedType` is encoded into this
    /// value so the deployed v4 store constraint remains migration-compatible.
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
    
    /// The original order position from the feed API (used to preserve pinned post order)
    var feedOrder: Int?
    
    /// Thread metadata (optional, for enhanced thread display)
    var threadDisplayMode: String?
    var threadPostCount: Int?
    var threadHiddenCount: Int?
    var isPartOfThread: Bool
    var isIncompleteThread: Bool

    /// Repost metadata extracted at cache time for cheap filtering.
    var isRepost: Bool
    var repostIndexedAt: Date?
    
    /// Serialized slice items for thread display (stores all posts in the thread)
    var serializedSliceItems: Data?
    
    /// Indicates if this is a temporary/optimistic post that hasn't been confirmed by the server
    @Transient var isTemporary: Bool = false

    /// Runtime-only Smart Filter state. Pending classifications deliberately
    /// persist as ordinary visible posts if the cache is written to disk.
    @Transient var smartFilterCollapseRuleID: String?
    @Transient var isSmartFilterPending: Bool = false

    /// Runtime-only Intent Control state.
    @Transient var intentHiddenRuleText: String?
    @Transient var isIntentDemoted: Bool = false

    /// Cached decoded FeedViewPost to avoid repeated JSON decoding
    @Transient private var _cachedFeedViewPost: AppBskyFeedDefs.FeedViewPost?
    // SwiftData replaces persisted-property setters, so didSet is not a cache
    // invalidation boundary. Validate against the bytes that produced each cache.
    // Data's copy-on-write storage lets primed values retain those bytes cheaply.
    @Transient private var _cachedFeedViewPostData: Data?
    @Transient private var _cachedSliceItems: [FeedSliceItem]?
    @Transient private var _cachedSliceItemsData: Data?
    @Transient private var _hasDecodedSliceItems: Bool = false

    private static let idDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Returns the stable identity of one feed entry. Repost attribution is part
    /// of the entry, so it must not share an identity with the organic variant.
    static func computeId(
        for feedViewPost: AppBskyFeedDefs.FeedViewPost,
        feedType: String
    ) -> String {
        let prefix = entryIdPrefix(
            for: feedViewPost.post.uri.uriString(),
            feedType: feedType
        )
        let base = "\(prefix)\(feedViewPost.post.cid)"
        if case .appBskyFeedDefsReasonRepost(let repost) = feedViewPost.reason {
            return "\(base)-repost-\(repost.by.did.didString())-\(idDateFormatter.string(from: repost.indexedAt.date))"
        }
        return base
    }

    /// Prefix shared by construction and URI-based lookups. Length delimiters
    /// keep a feed or URI that extends another value from matching broadly.
    static func entryIdPrefix(for uri: String, feedType: String) -> String {
        "\(feedType.utf8.count):\(feedType)|\(uri.utf8.count):\(uri)|"
    }
    
    /// Initializer from a FeedViewPost with backwards compatibility
    init?(feedViewPost: AppBskyFeedDefs.FeedViewPost) {
        let feedType = "timeline" // Default feed type for compatibility
        self.feedType = feedType
        self.id = Self.computeId(for: feedViewPost, feedType: feedType)
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
        self.feedOrder = nil

        // Extract repost metadata for efficient ID computation
        if case .appBskyFeedDefsReasonRepost(let reasonRepost) = feedViewPost.reason {
            self.isRepost = true
            self.repostIndexedAt = reasonRepost.indexedAt.date
        } else {
            self.isRepost = false
            self.repostIndexedAt = nil
        }
        self._cachedFeedViewPost = feedViewPost
        self._cachedFeedViewPostData = self.serializedPost
    }
    
    /// Full initializer with all parameters
    init?(from feedViewPost: AppBskyFeedDefs.FeedViewPost, cursor: String? = nil, feedType: String, feedOrder: Int? = nil) {
        self.feedType = feedType
        self.id = Self.computeId(for: feedViewPost, feedType: feedType)
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

        // Extract repost metadata for efficient ID computation
        if case .appBskyFeedDefsReasonRepost(let reasonRepost) = feedViewPost.reason {
            self.isRepost = true
            self.repostIndexedAt = reasonRepost.indexedAt.date
        } else {
            self.isRepost = false
            self.repostIndexedAt = nil
        }
        self._cachedFeedViewPost = feedViewPost
        self._cachedFeedViewPostData = self.serializedPost
    }
    
    /// Initializer with thread metadata
    init?(from enhanced: EnhancedCachedFeedViewPost, feedType: String = "timeline") {
        let feedViewPost = enhanced.feedViewPost
        self.feedType = feedType
        self.id = Self.computeId(for: feedViewPost, feedType: feedType)
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
        self.feedOrder = nil

        // Extract repost metadata for efficient ID computation
        if case .appBskyFeedDefsReasonRepost(let reasonRepost) = feedViewPost.reason {
            self.isRepost = true
            self.repostIndexedAt = reasonRepost.indexedAt.date
        } else {
            self.isRepost = false
            self.repostIndexedAt = nil
        }
        self._cachedFeedViewPost = feedViewPost
        self._cachedFeedViewPostData = self.serializedPost
    }

    /// Compatibility path for individual callers. Feed page preparation uses
    /// `PreparedFeedSlice.prepare` so serialization finishes before publication.
    convenience init?(from slice: FeedSlice, feedType: String = "timeline") {
        guard let prepared = PreparedFeedSlice(slice: slice) else { return nil }
        self.init(prepared: prepared, feedType: feedType)
    }

    /// Creates only the SwiftData model; all JSON work belongs to the prepared value.
    init(prepared: PreparedFeedSlice, feedType: String) {
        let slice = prepared.slice
        let feedViewPost = prepared.feedViewPost
        self.feedType = feedType
        self.id = Self.computeId(for: feedViewPost, feedType: feedType)
        self.serializedPost = prepared.serializedPost
        self.cursor = nil
        self.cachedAt = Date()

        // Extract creation date for sorting
        self.createdAt = prepared.createdAt

        // Store slice items for thread rendering
        self.serializedSliceItems = prepared.serializedSliceItems

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
        self.feedOrder = nil

        // Extract repost metadata for efficient ID computation
        if case .appBskyFeedDefsReasonRepost(let reasonRepost) = slice.reason {
            self.isRepost = true
            self.repostIndexedAt = reasonRepost.indexedAt.date
        } else {
            self.isRepost = false
            self.repostIndexedAt = nil
        }
        self._cachedFeedViewPost = feedViewPost
        self._cachedFeedViewPostData = prepared.serializedPost
        self._cachedSliceItems = slice.items
        self._cachedSliceItemsData = prepared.serializedSliceItems
        self._hasDecodedSliceItems = true
    }

    /// Reconstructs the original FeedViewPost, caching the result to avoid repeated JSON decoding
    var feedViewPost: AppBskyFeedDefs.FeedViewPost {
        get throws {
            let data = serializedPost
            if let cached = _cachedFeedViewPost, _cachedFeedViewPostData == data {
                return cached
            }

            let decoder = JSONDecoder()
            
            // First, try standard decoding
            do {
                let result = try decoder.decode(AppBskyFeedDefs.FeedViewPost.self, from: data)
                _cachedFeedViewPost = result
                _cachedFeedViewPostData = data
                return result
            } catch let DecodingError.keyNotFound(key, context) {
                // Check if this is a deeply nested embed issue
                let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
                let isNestedEmbedIssue = path.contains("embed") && path.contains("record") && path.components(separatedBy: "record").count > 2
                
                if isNestedEmbedIssue {
                    cachedPostLogger.warning("Cached post has malformed deeply nested embed at \(path), key '\(key.stringValue)' missing - this post has complex nesting that can't be decoded")
                    cachedPostLogger.debug("Full error context: \(context.debugDescription)")
                    
                    // These posts were cached with bad data - they need to be removed from cache
                    // The `try?` pattern where this is called will cause them to be skipped
                    throw DecodingError.keyNotFound(key, context)
                } else {
                    cachedPostLogger.error("Failed to decode cached post at \(path): \(String(describing: DecodingError.keyNotFound(key, context)))")
                    throw DecodingError.keyNotFound(key, context)
                }
            } catch let decodingError {
                cachedPostLogger.error("Failed to decode cached post: \(String(describing: decodingError))")
                throw decodingError
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
        let data = serializedSliceItems
        if _hasDecodedSliceItems, _cachedSliceItemsData == data { return _cachedSliceItems }
        _cachedSliceItems = data.flatMap {
            try? JSONDecoder().decode([FeedSliceItem].self, from: $0)
        }
        _cachedSliceItemsData = data
        _hasDecodedSliceItems = true
        return _cachedSliceItems
    }
    
    /// Computed property to check if this cached post represents a thread slice
    var isThreadSlice: Bool {
        return (sliceItems?.count ?? 0) > 1
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

// MARK: - Upsert Support

extension CachedFeedViewPost {
    /// Updates this cached post with values from another instance.
    /// Used for upsert operations to update existing records in place,
    /// avoiding SwiftData unique constraint violations.
    ///
    /// - Parameter source: The source post to copy values from
    func update(from source: CachedFeedViewPost) {
        // SwiftData may return the same registered object during persistence of
        // retained rows. Reassigning its bytes would invalidate its own caches.
        guard source !== self else { return }
        guard feedType == source.feedType else {
            cachedPostLogger.error(
                "Refusing cross-feed cache update from \(source.feedType, privacy: .public) to \(self.feedType, privacy: .public)"
            )
            return
        }
        self.serializedPost = source.serializedPost
        self._cachedFeedViewPost = source._cachedFeedViewPost
        self._cachedFeedViewPostData = source._cachedFeedViewPostData
        self.cursor = source.cursor
        self.cachedAt = source.cachedAt
        self.createdAt = source.createdAt
        self.feedOrder = source.feedOrder
        self.threadDisplayMode = source.threadDisplayMode
        self.threadPostCount = source.threadPostCount
        self.threadHiddenCount = source.threadHiddenCount
        self.isPartOfThread = source.isPartOfThread
        self.isIncompleteThread = source.isIncompleteThread
        self.isRepost = source.isRepost
        self.repostIndexedAt = source.repostIndexedAt
        self.serializedSliceItems = source.serializedSliceItems
        self._cachedSliceItems = source._cachedSliceItems
        self._cachedSliceItemsData = source._cachedSliceItemsData
        self._hasDecodedSliceItems = source._hasDecodedSliceItems
        // Note: id is not updated as it's the unique key
        // Note: isTemporary is @Transient and not persisted
    }
}

/// Immutable page-preparation output. Only Sendable protocol values and bytes
/// cross from the concurrent executor to the main actor's SwiftData models.
struct PreparedFeedSlice: Sendable {
    let slice: FeedSlice
    let feedViewPost: AppBskyFeedDefs.FeedViewPost
    let serializedPost: Data
    let serializedSliceItems: Data?
    let createdAt: Date

    init?(slice: FeedSlice) {
        guard let mainItem = slice.items.last else { return nil }
        let feedViewPost = AppBskyFeedDefs.FeedViewPost(
            post: mainItem.post,
            reply: slice.originalReply ?? Self.createReplyRefFromSlice(slice),
            reason: slice.reason,
            feedContext: slice.feedContext,
            reqId: nil
        )
        do {
            self.serializedPost = try JSONEncoder().encode(feedViewPost)
        } catch {
            cachedPostLogger.error("Failed to encode feedViewPost: \(error)")
            return nil
        }
        self.slice = slice
        self.feedViewPost = feedViewPost
        self.serializedSliceItems = try? JSONEncoder().encode(slice.items)
        self.createdAt = mainItem.record.createdAt.date
    }

    @concurrent
    static func prepare(_ slices: [FeedSlice]) async throws -> [PreparedFeedSlice] {
        let signpostID = PerformanceSignposts.beginFeedPreparation(itemCount: slices.count)
        defer { PerformanceSignposts.endFeedPreparation(id: signpostID, itemCount: slices.count) }
        try Task.checkCancellation()
        var prepared: [PreparedFeedSlice] = []
        prepared.reserveCapacity(slices.count)
        for slice in slices {
            try Task.checkCancellation()
            if let value = PreparedFeedSlice(slice: slice) { prepared.append(value) }
        }
        try Task.checkCancellation()
        return prepared
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
}
