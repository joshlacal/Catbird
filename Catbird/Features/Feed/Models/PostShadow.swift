//
//  PostShadow.swift
//  Catbird
//
//  Created by Josh LaCalamito on 10/25/24.
//

import Foundation
import Petrel

/// A shadow state representation for posts
/// Maintains the UI state separate from server state for optimistic updates
struct PostShadow: Equatable, Sendable {
    var likeUri: ATProtocolURI?
    var repostUri: ATProtocolURI?
    var isDeleted: Bool = false
    var pinned: Bool = false
    var embed: AppBskyFeedDefs.PostViewEmbedUnion?
    
    // Shadow state for counts (for optimistic updates)
    var likeCount: Int?
    var repostCount: Int?
    
    // Flag to indicate this is an optimistic/temporary post
    var isOptimistic: Bool = false
}

/// Actor for managing post shadow state
/// Uses Swift concurrency to provide safe, isolated access to shadow state
actor PostShadowManager {
    // MARK: - Properties
    
    // Use UUIDs to uniquely identify each continuation for observation
    private var continuations: [String: [UUID: AsyncStream<PostShadow?>.Continuation]] = [:]
    
    // Map of URI -> Shadow state
    private var shadows: [String: PostShadow] = [:]
    
    // MARK: - Initialization
    
    /// Shared singleton instance
    static let shared = PostShadowManager()
    
    private init() {}
    
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
        shadows[uri]
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
        return getShadow(forUri: postUri)?.likeUri != nil
    }
    
    /// Sets the liked state for a post
    /// - Parameters:
    ///   - postUri: The post URI
    ///   - isLiked: Whether the post is liked
    func setLiked(postUri: String, isLiked: Bool) {
        updateShadow(forUri: postUri) { shadow in
            if isLiked {
                // Only create a placeholder URI if one doesn't exist
                if shadow.likeUri == nil {
                    // Create a URI with a proper structure so recordKey access works
                    let likeId = UUID().uuidString
                    shadow.likeUri = try? ATProtocolURI(uriString: "at://did:placeholder/app.bsky.feed.like/\(likeId)")
                }
            } else {
                shadow.likeUri = nil
            }
        }
    }
    
    /// Gets the like count for a post
    /// - Parameter postUri: The post URI
    /// - Returns: The like count or 0 if not available
    func getLikeCount(postUri: String) -> Int {
        return getShadow(forUri: postUri)?.likeCount ?? 0
    }
    
    /// Sets the like count for a post
    /// - Parameters:
    ///   - postUri: The post URI
    ///   - count: The new like count
    func setLikeCount(postUri: String, count: Int) {
        updateShadow(forUri: postUri) { shadow in
            shadow.likeCount = count
        }
    }
    
    /// Checks if a post is reposted in the shadow state
    /// - Parameter postUri: The post URI
    /// - Returns: True if the post is reposted
    func isReposted(postUri: String) -> Bool {
        return getShadow(forUri: postUri)?.repostUri != nil
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
                    shadow.repostUri = try? ATProtocolURI(uriString: "at://did:placeholder/app.bsky.feed.repost/\(repostId)")
                }
            } else {
                shadow.repostUri = nil
            }
        }
    }
    
    /// Gets the repost count for a post
    /// - Parameter postUri: The post URI
    /// - Returns: The repost count or 0 if not available
    func getRepostCount(postUri: String) -> Int {
        return getShadow(forUri: postUri)?.repostCount ?? 0
    }
    
    /// Sets the repost count for a post
    /// - Parameters:
    ///   - postUri: The post URI
    ///   - count: The new repost count
    func setRepostCount(postUri: String, count: Int) {
        updateShadow(forUri: postUri) { shadow in
            shadow.repostCount = count
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
        
        // Use shadow counts if available, otherwise use post counts
        let likeCount: Int
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

        let repostCount: Int
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
        
        let quoteCount = post.quoteCount ?? 0
        
        // Create a new viewer state with the shadow information
        let viewerState = AppBskyFeedDefs.ViewerState(
            repost: shadow.repostUri,
            like: shadow.likeUri,
            threadMuted: post.viewer?.threadMuted,
            replyDisabled: post.viewer?.replyDisabled,
            embeddingDisabled: post.viewer?.embeddingDisabled,
            pinned: shadow.pinned
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
            replyCount: post.replyCount,
            repostCount: repostCount,
            likeCount: likeCount,
            quoteCount: quoteCount,
            indexedAt: post.indexedAt,
            viewer: viewerState,
            labels: post.labels,
            threadgate: post.threadgate
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
}
