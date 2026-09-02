//
//  PostShadow.swift
//  Catbird
//
//  Created by Josh LaCalamito on 10/25/24.
//

import Foundation
import OSLog
import Petrel


/// A shadow state representation for posts
/// Maintains the UI state separate from server state for optimistic updates
struct PostShadow: Equatable, Sendable {
    private(set) var likeUri: ATProtocolURI?
    private(set) var repostUri: ATProtocolURI?
    private(set) var likeDecided: Bool = false
    private(set) var repostDecided: Bool = false
    var bookmarked: Bool?  // Changed from bookmarkUri to bookmarked since AT Protocol uses Bool
    var isDeleted: Bool = false
    var pinned: Bool = false
    var embed: AppBskyFeedDefs.PostViewEmbedUnion?
    
    // Flag to indicate this is an optimistic/temporary post
    var isOptimistic: Bool = false

    init(
        likeUri: ATProtocolURI? = nil,
        repostUri: ATProtocolURI? = nil,
        likeDecided: Bool = false,
        repostDecided: Bool = false,
        bookmarked: Bool? = nil,
        isDeleted: Bool = false,
        pinned: Bool = false,
        embed: AppBskyFeedDefs.PostViewEmbedUnion? = nil,
        isOptimistic: Bool = false
    ) {
        self.likeUri = likeUri
        self.repostUri = repostUri
        self.likeDecided = likeDecided
        self.repostDecided = repostDecided
        self.bookmarked = bookmarked
        self.isDeleted = isDeleted
        self.pinned = pinned
        self.embed = embed
        self.isOptimistic = isOptimistic
    }

    /// Explicitly records a user/local decision for liking or unliking
    mutating func decideLike(_ uri: ATProtocolURI?) {
        self.likeUri = uri
        self.likeDecided = true
    }

    /// Explicitly records a user/local decision for reposting or unreposting
    mutating func decideRepost(_ uri: ATProtocolURI?) {
        self.repostUri = uri
        self.repostDecided = true
    }

    /// Reconciles shadow state with server viewer state.
    /// Undecided state updates from server while remaining undecided.
    /// Decided state: if server caught up to local decision, retires decision;
    /// if server still disagrees, preserves local decision.
    mutating func hydrateFromServer(likeUri serverLikeUri: ATProtocolURI?, repostUri serverRepostUri: ATProtocolURI?) {
        if !likeDecided {
            self.likeUri = serverLikeUri
        } else if (self.likeUri != nil) == (serverLikeUri != nil) {
            // Server has caught up to our decision
            self.likeDecided = false
            self.likeUri = serverLikeUri
        }

        if !repostDecided {
            self.repostUri = serverRepostUri
        } else if (self.repostUri != nil) == (serverRepostUri != nil) {
            // Server has caught up to our decision
            self.repostDecided = false
            self.repostUri = serverRepostUri
        }
    }
}

/// Actor for managing post shadow state
/// Uses Swift concurrency to provide safe, isolated access to shadow state
actor PostShadowManager {
    private let logger = Logger(subsystem: "blue.catbird", category: "PostShadowManager")

    // MARK: - Properties
    
    // Use UUIDs to uniquely identify each continuation for observation
    private var continuations: [String: [UUID: AsyncStream<PostShadow?>.Continuation]] = [:]
    
    // Map of URI -> Shadow state
    private var shadows: [String: PostShadow] = [:]
    
    /// Public initializer
    init() {}
    
    // MARK: - Shadow Management
    
    /// Updates shadow state for a post
    /// - Parameters:
    ///   - uri: The post URI to update
    ///   - updates: A closure that modifies the shadow state
    func updateShadow(forUri uri: String, updates: (inout PostShadow) -> Void) {
        var shadow = shadows[uri] ?? PostShadow()
        updates(&shadow)
        shadows[uri] = shadow
        notifyObservers(uri: uri, shadow: shadow)
    }
    
    /// Gets the current shadow state for a post
    /// - Parameter uri: The post URI
    /// - Returns: The shadow state, if any
    func getShadow(forUri uri: String) -> PostShadow? {
        guard !uri.isEmpty else {
            #if DEBUG
            logger.debug("PostShadowManager: Warning - empty URI provided to getShadow")
            #endif
            return nil
        }
        return shadows[uri]
    }
    
    /// Removes shadow state for a post
    /// - Parameter uri: The post URI to remove
    func removeShadow(forUri uri: String) {
        shadows.removeValue(forKey: uri)
        notifyObservers(uri: uri, shadow: nil)
    }
    
    // MARK: - Observation
    
    /// Creates an async stream of shadow updates for a post
    /// - Parameter uri: The post URI to observe
    /// - Returns: An AsyncStream of shadow state updates
    func shadowUpdates(forUri uri: String) -> AsyncStream<PostShadow?> {
        AsyncStream { continuation in
            // Generate a unique identifier for this continuation
            let id = UUID()
            continuations[uri, default: [:]][id] = continuation
            
            // Yield the current value immediately
            continuation.yield(getShadow(forUri: uri))
            
            // Clean up when the stream is terminated
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeContinuation(id: id, forUri: uri)
                }
            }
        }
    }
    
    private func removeContinuation(id: UUID, forUri uri: String) {
        continuations[uri]?.removeValue(forKey: id)
        if continuations[uri]?.isEmpty == true {
            continuations.removeValue(forKey: uri)
        }
    }
    
    private func notifyObservers(uri: String, shadow: PostShadow?) {
        guard let observers = continuations[uri] else { return }
        for continuation in observers.values {
            continuation.yield(shadow)
        }
    }
    
    // MARK: - Helper Methods for Optimistic Updates
    
    /// Checks if a post is liked in the shadow state
    /// - Parameter postUri: The post URI
    /// - Returns: True if the post is liked
    func isLiked(postUri: String) -> Bool {
        guard let shadow = getShadow(forUri: postUri) else { return false }
        return shadow.likeDecided && shadow.likeUri != nil
    }
    
    /// Sets the liked state for a post
    /// - Parameters:
    ///   - postUri: The post URI
    ///   - isLiked: Whether the post is liked
    func setLiked(postUri: String, isLiked: Bool) {
        updateShadow(forUri: postUri) { shadow in
            if isLiked {
                if shadow.likeUri == nil {
                    // Create a URI with a proper structure so recordKey access works
                    let likeId = UUID().uuidString
                    shadow.decideLike(try? ATProtocolURI(uriString: "at://did:plc:placeholder/app.bsky.feed.like/\(likeId)"))
                } else {
                    shadow.decideLike(shadow.likeUri)
                }
            } else {
                shadow.decideLike(nil)
            }
        }
    }
    
    
    /// Checks if a post is reposted in the shadow state
    /// - Parameter postUri: The post URI
    /// - Returns: True if the post is reposted
    func isReposted(postUri: String) -> Bool {
        guard let shadow = getShadow(forUri: postUri) else { return false }
        return shadow.repostDecided && shadow.repostUri != nil
    }
    
    /// Sets the reposted state for a post
    /// - Parameters:
    ///   - postUri: The post URI
    ///   - isReposted: Whether the post is reposted
    func setReposted(postUri: String, isReposted: Bool) {
        updateShadow(forUri: postUri) { shadow in
            if isReposted {
                // Only create a placeholder URI if one doesn't exist
                if shadow.repostUri == nil {
                    // Create a URI with a proper structure so recordKey access works
                    let repostId = UUID().uuidString
                    shadow.decideRepost(try? ATProtocolURI(uriString: "at://did:plc:placeholder/app.bsky.feed.repost/\(repostId)"))
                } else {
                    shadow.decideRepost(shadow.repostUri)
                }
            } else {
                shadow.decideRepost(nil)
            }
        }
    }
    
    
    /// Checks if a post is bookmarked in the shadow state
    /// - Parameter postUri: The post URI
    /// - Returns: True if the post is bookmarked
    func isBookmarked(postUri: String) -> Bool {
        guard !postUri.isEmpty else {
            #if DEBUG
            logger.debug("PostShadowManager: Warning - empty postUri provided to isBookmarked")
            #endif
            return false
        }
        return getShadow(forUri: postUri)?.bookmarked == true
    }
    
    /// Sets the bookmarked state for a post
    /// - Parameters:
    ///   - postUri: The post URI
    ///   - isBookmarked: Whether the post is bookmarked
    func setBookmarked(postUri: String, isBookmarked: Bool) {
        updateShadow(forUri: postUri) { shadow in
            shadow.bookmarked = isBookmarked
        }
    }
    
    // MARK: - Shadow Application
    
    /// Merges shadow state with a post to create an updated post view
    /// - Parameter post: The original post view from the API
    /// - Returns: A new post view with shadow state applied
    func mergeShadow(post: AppBskyFeedDefs.PostView) -> AppBskyFeedDefs.PostView {
        guard let shadow = getShadow(forUri: post.uri.uriString()) else {
            return post
        }
        
        if shadow.isDeleted {
            return post // Or handle deleted state as needed
        }
        
        // Use shadow decisions if available, otherwise use post counts
        let finalLikeUri: ATProtocolURI?
        let likeCount: Int
        if shadow.likeDecided {
            finalLikeUri = shadow.likeUri
            if shadow.likeUri != nil && post.viewer?.like == nil {
                // We liked but server doesn't know yet - add 1 to server count
                likeCount = (post.likeCount ?? 0) + 1
            } else if shadow.likeUri == nil && post.viewer?.like != nil {
                // We unliked but server doesn't know yet - subtract 1 from server count
                likeCount = max(0, (post.likeCount ?? 0) - 1)
            } else {
                // Server and local state are in sync - use server count
                likeCount = post.likeCount ?? 0
            }
        } else {
            finalLikeUri = post.viewer?.like
            likeCount = post.likeCount ?? 0
        }

        let finalRepostUri: ATProtocolURI?
        let repostCount: Int
        if shadow.repostDecided {
            finalRepostUri = shadow.repostUri
            if shadow.repostUri != nil && post.viewer?.repost == nil {
                // We reposted but server doesn't know yet - add 1 to server count
                repostCount = (post.repostCount ?? 0) + 1
            } else if shadow.repostUri == nil && post.viewer?.repost != nil {
                // We unreposted but server doesn't know yet - subtract 1 from server count
                repostCount = max(0, (post.repostCount ?? 0) - 1)
            } else {
                // Server and local state are in sync - use server count
                repostCount = post.repostCount ?? 0
            }
        } else {
            finalRepostUri = post.viewer?.repost
            repostCount = post.repostCount ?? 0
        }
        
        let quoteCount = post.quoteCount ?? 0
        
        // Create a new viewer state with the shadow information
        let viewerState = AppBskyFeedDefs.ViewerState(
            repost: finalRepostUri,
            like: finalLikeUri,
            bookmarked: shadow.bookmarked ?? post.viewer?.bookmarked,
            threadMuted: post.viewer?.threadMuted,
            replyDisabled: post.viewer?.replyDisabled,
            embeddingDisabled: post.viewer?.embeddingDisabled,
            pinned: shadow.pinned,
            knownLikers: post.viewer?.knownLikers
        )
        // Handle embed merging
        var finalEmbed = post.embed
        if let shadowEmbed = shadow.embed {
            switch (post.embed, shadowEmbed) {
            case (.appBskyEmbedRecordView, .appBskyEmbedRecordView(let shadowEmbed)):
                finalEmbed = .appBskyEmbedRecordView(shadowEmbed)
            case (.appBskyEmbedRecordWithMediaView, .appBskyEmbedRecordWithMediaView(let shadowEmbed)):
                finalEmbed = .appBskyEmbedRecordWithMediaView(shadowEmbed)
            default:
                // Keep original embed if types don't match
                break
            }
        }
        
        // Create and return a new PostView with the updated values
        return AppBskyFeedDefs.PostView(
            uri: post.uri,
            cid: post.cid,
            author: post.author,
            record: post.record,
            embed: finalEmbed,
            bookmarkCount: post.bookmarkCount,
            replyCount: post.replyCount,
            repostCount: repostCount,
            likeCount: likeCount,
            quoteCount: quoteCount,
            indexedAt: post.indexedAt,
            viewer: viewerState,
            labels: post.labels,
            threadgate: post.threadgate,
            debug: nil

        )
    }
    
    /// Updates the embed for a post
    /// - Parameters:
    ///   - uri: The post URI
    ///   - embed: The new embed to apply
    func updateEmbed(forUri uri: String, embed: AppBskyFeedDefs.PostViewEmbedUnion) {
        updateShadow(forUri: uri) { shadow in
            shadow.embed = embed
        }
    }
    
    // MARK: - Account Switching
    
    /// Clears all shadow state
    /// This should be called when switching accounts to prevent state leakage between accounts
    func clearAll() {
        logger.info("Clearing all shadow state (count: \(self.shadows.count))")
        
        // Clear all shadows
        shadows.removeAll()
        
        // Notify all observers with nil to clear their state
        for (uri, observers) in continuations {
            for continuation in observers.values {
                continuation.yield(nil)
            }
        }
        
        // Clear continuations
        continuations.removeAll()
        
        logger.debug("Shadow state cleared successfully")
    }
}
