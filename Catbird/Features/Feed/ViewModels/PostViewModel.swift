//
//  PostViewModel.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/28/24.
//

import Foundation
import Petrel
import Observation
import OSLog

/// ViewModel for managing post state and interactions
@Observable
final class PostViewModel {
    // MARK: - Properties
    
    /// The unique identifier for the post
    let postId: String
    
    /// The content identifier (CID) for the post
    let postCid: CID
    
    /// Reference to the app state
    private(set) var appState: AppState
    
    /// Whether the post is liked by the current user
    private(set) var isLiked: Bool = false
    
    /// Whether the post is reposted by the current user
    private(set) var isReposted: Bool = false
    
    /// Whether the post is bookmarked by the current user
    private(set) var isBookmarked: Bool = false
    
    /// Current counts (updated via shadow state)
    @MainActor private(set) var likeCount: Int = 0
    @MainActor private(set) var repostCount: Int = 0
    @MainActor private(set) var replyCount: Int = 0
    
    // Store the actual like, repost, and bookmark URIs
    private var likeUri: ATProtocolURI?
    private var repostUri: ATProtocolURI?
    
    // Task for initialization
    private var initializationTask: Task<Void, Never>?
    
    /// Logger for debugging
    let logger = Logger(subsystem: "blue.catbird", category: "PostViewModel")
    
    // MARK: - Initialization
    
    /// Initialize the view model with a post ID and app state
    /// - Parameters:
    ///   - postId: The URI string of the post
    ///   - postCid: The CID of the post
    ///   - appState: The app state
    init(postId: String, postCid: CID, appState: AppState) {
        self.postId = postId
        self.postCid = postCid
        self.appState = appState
        
        // Check initial state from post shadow manager
        Task {
            await checkInteractionState()
        }
    }
    
    /// Convenience initializer from a post view
    convenience init(post: AppBskyFeedDefs.PostView, appState: AppState) {
        self.init(
            postId: post.uri.uriString(),
            postCid: post.cid,
            appState: appState
        )
        
        // Initialize shadow state from the server's post data
        // Properly managed task
        initializationTask = Task {
            // Check for cancellation before starting
            guard !Task.isCancelled else { return }
            await initializeFromServerState(post: post)
        }
    }
    
    // MARK: - Deinitialization
    
    deinit {
        initializationTask?.cancel()
    }
    
    // MARK: - State Management
    
    /// Initialize the shadow state when a post is loaded
    @MainActor
    func initializeFromServerState(post: AppBskyFeedDefs.PostView) async {
        // First update the local state
        isLiked = post.viewer?.like != nil
        isReposted = post.viewer?.repost != nil
        isBookmarked = post.viewer?.bookmarked == true
        likeCount = post.likeCount ?? 0
        repostCount = post.repostCount ?? 0
        replyCount = post.replyCount ?? 0
        
        // Store URIs directly in view model for backup
        likeUri = post.viewer?.like
        repostUri = post.viewer?.repost
        // bookmarkUri will be set separately from the shadow since bookmarked is Bool, not URI
        
        // Check if shadow already exists to avoid redundant initialization
        let existingShadow = await appState.postShadowManager.getShadow(forUri: post.uri.uriString())
        
        // Batch shadow updates if needed
        var needsShadowUpdate = false
        var likeUriToSet: ATProtocolURI?
        var repostUriToSet: ATProtocolURI?
        
        if let likeUri = post.viewer?.like, existingShadow?.likeUri == nil {
            likeUriToSet = likeUri
            needsShadowUpdate = true
        }
        
        if let repostUri = post.viewer?.repost, existingShadow?.repostUri == nil {
            repostUriToSet = repostUri
            needsShadowUpdate = true
        }
        
        // For bookmarks, we only track the boolean state in the post, not the URI
        // The URI is managed by BookmarksManager
        
        if needsShadowUpdate {
            await appState.postShadowManager.updateShadow(forUri: post.uri.uriString()) { shadow in
                if let likeUri = likeUriToSet {
                    shadow.likeUri = likeUri
                    shadow.likeCount = post.likeCount
                }
                if let repostUri = repostUriToSet {
                    shadow.repostUri = repostUri
                    shadow.repostCount = post.repostCount
                }
            }
        }
    }
    
    /// Updates the interaction state from the shadow manager
    @MainActor
    func checkInteractionState() async {
        if let shadow = await appState.postShadowManager.getShadow(forUri: postId) {
            isLiked = shadow.likeUri != nil
            isReposted = shadow.repostUri != nil
            isBookmarked = shadow.bookmarked == true
            
            // Update our backup copy of URIs
            if isLiked && likeUri == nil {
                likeUri = shadow.likeUri
            }
            if isReposted && repostUri == nil {
                repostUri = shadow.repostUri
            }
        }
    }
    
    /// Updates counts based on a PostView
    @MainActor
    func updateCounts(from post: AppBskyFeedDefs.PostView) {
        likeCount = post.likeCount ?? 0
        repostCount = post.repostCount ?? 0
        replyCount = post.replyCount ?? 0
    }
    
    /// Updates the app state reference
    func updateAppState(_ newState: AppState) {
        self.appState = newState
    }
    
    // MARK: - Post Interactions
    
    /// Reverts the like state optimistically
    private func revertLikeState(wasLiked: Bool, originalCount: Int) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                self.isLiked = wasLiked
                // Note: likeCount is already @MainActor, direct update is fine if needed,
                // but shadow manager handles count revert.
            }
            
            group.addTask { 
                await self.appState.postShadowManager.setLiked(postUri: self.postId, isLiked: wasLiked)
                await self.appState.postShadowManager.setLikeCount(postUri: self.postId, count: originalCount)
            }
        }
    }
    
    /// Reverts the repost state optimistically
    private func revertRepostState(wasReposted: Bool, originalCount: Int) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                self.isReposted = wasReposted
                // Note: repostCount is already @MainActor.
            }
            
            group.addTask {
                await self.appState.postShadowManager.setReposted(postUri: self.postId, isReposted: wasReposted)
                await self.appState.postShadowManager.setRepostCount(postUri: self.postId, count: originalCount)
            }
        }
    }
    
    /// Reverts the bookmark state optimistically
    private func revertBookmarkState(wasBookmarked: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                self.isBookmarked = wasBookmarked
            }
            
            group.addTask {
                await self.appState.postShadowManager.setBookmarked(postUri: self.postId, isBookmarked: wasBookmarked)
            }
        }
    }
    
    /// Toggle the like status of the post
    /// - Parameter via: Optional reference to the repost that led to discovering this content.
    ///   When set, creates a "like-via-repost" notification for the author of the referenced repost.
    ///   Only set this when the user discovered this post through someone else's repost.
    ///   Example: Alice posts → Bob reposts → Carol likes via Bob's repost → `via` = Bob's repost record
    ///   Note: Attribution is controlled by the enableViaAttribution setting
    @discardableResult
    func toggleLike(via: ComAtprotoRepoStrongRef? = nil) async throws -> Bool {
        guard let client = appState.atProtoClient else {
            throw PostViewModelError.missingClient // Throw error instead of returning false
        }
        
        // Local copy for reverting if needed
        let wasLiked = isLiked
        let currentLikeCount = await likeCount // Read MainActor property
        
        // Use task groups for optimistic updates
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                self.isLiked.toggle()
            }
            
            group.addTask {
                await self.appState.postShadowManager.setLiked(postUri: self.postId, isLiked: !wasLiked)
                // Optimistically update count in shadow
                await self.appState.postShadowManager.setLikeCount(
                    postUri: self.postId,
                    count: wasLiked ? max(0, currentLikeCount - 1) : currentLikeCount + 1
                )
            }
        }
        
        do {
            if !wasLiked { // Creating a new like
                let postRef = ComAtprotoRepoStrongRef(
                    uri: try ATProtocolURI(uriString: postId),
                    cid: postCid
                )
                // Check if via attribution is enabled in settings
                let enableAttribution = appState.appSettings.enableViaAttribution
                let viaReference = enableAttribution ? via : nil
                
                let likeRecord = AppBskyFeedLike(
                    subject: postRef,
                    createdAt: .init(date: Date()),
                    via: viaReference
                )
                
                let did = try await client.getDid()
                let input = ComAtprotoRepoCreateRecord.Input(
                    repo: try ATIdentifier(string: did),
                    collection: try NSID(nsidString: "app.bsky.feed.like"),
                    record: .knownType(likeRecord)
                )
                
                // Use try for result handling
                let (code, data) = try await client.com.atproto.repo.createRecord(input: input)
                
                guard code == 200, let response = data else {
                    throw PostViewModelError.requestFailed
                }
                // Save the URI both in shadow manager and locally
                self.likeUri = response.uri
                
                // Update shadow with real URI
                await appState.postShadowManager.updateShadow(forUri: postId) { shadow in
                    shadow.likeUri = response.uri
                }
                return true
                
            } else { // Deleting an existing like
                let collection = "app.bsky.feed.like"
                
                // Determine record key (prefer local, fallback to shadow)
                var recordKey = ""
                if let uri = self.likeUri {
                    recordKey = uri.recordKey ?? ""
                }
                
                if recordKey.isEmpty {
                    if let shadow = await appState.postShadowManager.getShadow(forUri: postId),
                       let likeUri = shadow.likeUri {
                        recordKey = likeUri.recordKey ?? ""
                    }
                }
                
                guard !recordKey.isEmpty else {
                    #if DEBUG
                    logger.error("Error: Unable to find valid like record key for deletion.")
                    #endif
                    // Revert optimistic update
                    await revertLikeState(wasLiked: wasLiked, originalCount: currentLikeCount)
                    return false // Indicate failure
                }
                
                let did = try await client.getDid()
                let input = ComAtprotoRepoDeleteRecord.Input(
                    repo: try ATIdentifier(string: did),
                    collection: try NSID(nsidString: collection),
                    rkey: try RecordKey(keyString: recordKey)
                )
                
                // Use try for result handling
                _ = try await client.com.atproto.repo.deleteRecord(input: input)
                
                // Clear the local URI since we've successfully deleted it
                self.likeUri = nil
                // Shadow state already updated optimistically, confirm with server state later if needed
                return true
            }
        } catch {
            // Revert optimistic update on any error
            await revertLikeState(wasLiked: wasLiked, originalCount: currentLikeCount)
            #if DEBUG
            logger.error("Error toggling like: \(error)")
            #endif
            // Re-throw the error for the caller to handle if necessary
            throw error
        }
    }
    
    /// Toggle the repost status of the post
    /// - Parameter via: Optional reference to the repost that led to discovering this content.
    ///   When set, creates a "repost-via-repost" notification for the author of the referenced repost.
    ///   Only set this when the user discovered this post through someone else's repost.
    ///   Example: Alice posts → Bob reposts → Carol reposts via Bob's repost → `via` = Bob's repost record
    ///   Note: Attribution is controlled by the enableViaAttribution setting
    @discardableResult
    func toggleRepost(via: ComAtprotoRepoStrongRef? = nil) async throws -> Bool {
        guard let client = appState.atProtoClient else {
            throw PostViewModelError.missingClient
        }
        
        // Local copy for reverting if needed
        let wasReposted = isReposted
        let currentRepostCount = await repostCount // Read MainActor property
        
        // Use task groups for optimistic updates
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                self.isReposted.toggle()
            }
            
            group.addTask {
                await self.appState.postShadowManager.setReposted(postUri: self.postId, isReposted: !wasReposted)
                await self.appState.postShadowManager.setRepostCount(
                    postUri: self.postId,
                    count: wasReposted ? max(0, currentRepostCount - 1) : currentRepostCount + 1
                )
            }
        }
        
        do {
            if !wasReposted { // Creating a new repost
                let postRef = ComAtprotoRepoStrongRef(
                    uri: try ATProtocolURI(uriString: postId),
                    cid: postCid
                )
                // Check if via attribution is enabled in settings
                let enableAttribution = appState.appSettings.enableViaAttribution
                let viaReference = enableAttribution ? via : nil
                
                let repostRecord = AppBskyFeedRepost(
                    subject: postRef,
                    createdAt: .init(date: Date()),
                    via: viaReference
                )
                let did = try await client.getDid()
                let input = ComAtprotoRepoCreateRecord.Input(
                    repo: try ATIdentifier(string: did),
                    collection: try NSID(nsidString: "app.bsky.feed.repost"),
                    record: .knownType(repostRecord)
                )
                
                let (code, data) = try await client.com.atproto.repo.createRecord(input: input)
                
                guard code == 200, let response = data else {
                    throw PostViewModelError.requestFailed
                }

                // Save the URI both in shadow manager and locally
                self.repostUri = response.uri
                
                // Update shadow with real URI
                await appState.postShadowManager.updateShadow(forUri: postId) { shadow in
                    shadow.repostUri = response.uri
                }
                return true
                
            } else { // Deleting an existing repost
                let collection = "app.bsky.feed.repost"
                
                // Determine record key (prefer local, fallback to shadow)
                var recordKey = ""
                if let uri = self.repostUri {
                    recordKey = uri.recordKey ?? ""
                }
                
                if recordKey.isEmpty {
                    if let shadow = await appState.postShadowManager.getShadow(forUri: postId),
                       let repostUri = shadow.repostUri {
                        recordKey = repostUri.recordKey ?? ""
                    }
                }
                
                guard !recordKey.isEmpty else {
                    // Revert optimistic update
                    await revertRepostState(wasReposted: wasReposted, originalCount: currentRepostCount)
                    return false // Indicate failure
                }
                
                let did = try await client.getDid()
                let input = ComAtprotoRepoDeleteRecord.Input(
                    repo: try ATIdentifier(string: did),
                    collection: try NSID(nsidString: collection),
                    rkey: try RecordKey(keyString: recordKey)
                )
                
                // Use try for result handling
                _ = try await client.com.atproto.repo.deleteRecord(input: input)
                
                // Clear the local URI since we've successfully deleted it
                self.repostUri = nil
                // Shadow state already updated optimistically
                return true
            }
        } catch {
            // Revert optimistic update on any error
            await revertRepostState(wasReposted: wasReposted, originalCount: currentRepostCount)
            #if DEBUG
            logger.error("Error toggling repost: \(error)")
            #endif
            // Re-throw the error
            throw error
        }
    }
    
    /// Toggle the bookmark status of the post
    @discardableResult
    func toggleBookmark() async throws -> Bool {
        guard let client = appState.atProtoClient else {
            throw PostViewModelError.missingClient
        }
        
        // Local copy for reverting if needed
        let wasBookmarked = isBookmarked
        
        // Use task groups for optimistic updates
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                self.isBookmarked.toggle()
            }
            
            group.addTask {
                await self.appState.postShadowManager.setBookmarked(postUri: self.postId, isBookmarked: !wasBookmarked)
            }
        }
        
        do {
            let postUri = try ATProtocolURI(uriString: postId)
            
            if !wasBookmarked { // Creating a new bookmark
                _ = try await appState.bookmarksManager.createBookmark(
                    postUri: postUri,
                    postCid: postCid,
                    client: client
                )
                
                return true
                
            } else { // Deleting an existing bookmark
                try await appState.bookmarksManager.deleteBookmark(
                    postUri: postUri,
                    client: client
                )
                
                return true
            }
        } catch {
            // Revert optimistic update on any error
            await revertBookmarkState(wasBookmarked: wasBookmarked)
            #if DEBUG
            logger.error("Error toggling bookmark: \(error)")
            #endif
            // Re-throw the error
            throw error
        }
    }
    
    /// Create a quote post
    @discardableResult
    func createQuotePost(text: String) async throws -> Bool {
        guard let client = appState.atProtoClient else {
            throw PostViewModelError.missingClient
        }
        
        // Get current state for reverting if needed
        // Note: Quote posting *adds* a new post, it doesn't modify the original's repost state directly
        // in the same way a simple repost does. The UI might show the original as "reposted"
        // conceptually, but the action creates a *new* post record.
        // We'll optimistically update the shadow's repost count for immediate feedback,
        // but we won't toggle `isReposted` here as it refers to a direct repost record.
        // The server response doesn't give us a direct repost URI for the *original* post
        // when quoting.
        
        let currentRepostCount = await repostCount // Read MainActor property
        
        // Optimistically update shadow state count
        await appState.postShadowManager.setRepostCount(postUri: postId, count: currentRepostCount + 1)
        // We don't set `isReposted = true` or `setReposted` because this isn't a direct repost record.
        
        do {
            // Create quote post record
            let postRef = ComAtprotoRepoStrongRef(
                uri: try ATProtocolURI(uriString: postId),
                cid: postCid
            )
            
            let embed = AppBskyEmbedRecord(record: postRef)
            let quotePost = AppBskyFeedPost(
                text: text,
                entities: [], // Consider adding entity/facet detection later
                facets: [],   // Consider adding entity/facet detection later
                reply: nil,
                embed: .appBskyEmbedRecord(embed),
                langs: [], // Detect language later if needed
                labels: nil,
                tags: [], // Extract tags later if needed
                createdAt: .init(date: Date())
            )
            let did = try await client.getDid()
            let input = ComAtprotoRepoCreateRecord.Input(
                repo: try ATIdentifier(string: did),
                collection: try NSID(nsidString: "app.bsky.feed.post"),
                record: .knownType(quotePost)
            )
            
            // Use try for result handling
            let response = try await client.com.atproto.repo.createRecord(input: input)
            
            // We don't save this URI as `self.repostUri` because it's the URI of the *new* quote post,
            // not a direct repost record of the original post.
            // We also don't update the shadow's `repostUri` for the original post.
                        
            // The optimistic count update remains.
            return true
            
        } catch {
            // Revert optimistic count update on error
            await appState.postShadowManager.setRepostCount(postUri: postId, count: currentRepostCount)
            
            #if DEBUG
            logger.error("Error creating quote post: \(error)")
            #endif
            // Re-throw the error
            throw error
        }
    }
    
    // Errors
    enum PostViewModelError: Error {
        case missingClient
        case unableToFindRecordKey
        case requestFailed
    }
}
