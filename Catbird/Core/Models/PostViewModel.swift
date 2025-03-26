//
//  PostViewModel.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/28/24.
//

import Foundation
import Petrel
import Observation

/// ViewModel for managing post state and interactions
@Observable
final class PostViewModel {
    // MARK: - Properties
    
    /// The unique identifier for the post
    let postId: String
    
    /// The content identifier (CID) for the post
    let postCid: String
    
    /// Reference to the app state
    private(set) var appState: AppState
    
    /// Whether the post is liked by the current user
    private(set) var isLiked: Bool = false
    
    /// Whether the post is reposted by the current user
    private(set) var isReposted: Bool = false
    
    /// Current counts (updated via shadow state)
    @MainActor private(set) var likeCount: Int = 0
    @MainActor private(set) var repostCount: Int = 0
    @MainActor private(set) var replyCount: Int = 0
    
    // Store the actual like and repost URIs
    private var likeUri: ATProtocolURI?
    private var repostUri: ATProtocolURI?
    
    // MARK: - Initialization
    
    /// Initialize the view model with a post ID and app state
    /// - Parameters:
    ///   - postId: The URI string of the post
    ///   - postCid: The CID of the post
    ///   - appState: The app state
    init(postId: String, postCid: String, appState: AppState) {
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
        Task {
            await initializeFromServerState(post: post)
        }
    }
    
    // MARK: - State Management
    
    /// Initialize the shadow state when a post is loaded
    @MainActor
    func initializeFromServerState(post: AppBskyFeedDefs.PostView) async {
        // First update the local state
        isLiked = post.viewer?.like != nil
        isReposted = post.viewer?.repost != nil
        likeCount = post.likeCount ?? 0
        repostCount = post.repostCount ?? 0
        replyCount = post.replyCount ?? 0
        
        // Store URIs directly in view model for backup
        likeUri = post.viewer?.like
        repostUri = post.viewer?.repost
        
        // Check if shadow already exists to avoid redundant initialization
        let existingShadow = await appState.postShadowManager.getShadow(forUri: postId)
        
        // Only initialize if needed
        if let likeUri = post.viewer?.like, existingShadow?.likeUri == nil {
            await appState.postShadowManager.updateShadow(forUri: postId) { shadow in
                shadow.likeUri = likeUri
                shadow.likeCount = post.likeCount
                print("Initialized shadow with like URI: \(likeUri.uriString())")
                if let recordKey = likeUri.recordKey {
                    print("Like record key: \(recordKey)")
                }
            }
        }
        
        if let repostUri = post.viewer?.repost, existingShadow?.repostUri == nil {
            await appState.postShadowManager.updateShadow(forUri: postId) { shadow in
                shadow.repostUri = repostUri
                shadow.repostCount = post.repostCount
                print("Initialized shadow with repost URI: \(repostUri.uriString())")
            }
        }
    }
    
    /// Updates the interaction state from the shadow manager
    @MainActor
    func checkInteractionState() async {
        if let shadow = await appState.postShadowManager.getShadow(forUri: postId) {
            isLiked = shadow.likeUri != nil
            isReposted = shadow.repostUri != nil
            
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
    
    /// Toggle the like status of the post
    @discardableResult
    func toggleLike() async throws -> Bool {
        guard let client = appState.atProtoClient else { return false }
        
        // Local copy of state variables in case we need to revert
        let wasLiked = isLiked
        let currentLikeCount = await likeCount
        
        // Start with optimistic update
        await MainActor.run {
            isLiked.toggle()
        }
        
        // Optimistically update shadow state
        await appState.postShadowManager.setLiked(postUri: postId, isLiked: !wasLiked)
        
        do {
            if !wasLiked {  // Creating a new like
                // Create like record
                let post = ComAtprotoRepoStrongRef(
                    uri: try ATProtocolURI(uriString: postId),
                    cid: postCid
                )
                let likeRecord = AppBskyFeedLike(
                    subject: post,
                    createdAt: .init(date: Date())
                )
                
                let input = ComAtprotoRepoCreateRecord.Input(
                    repo: try await client.getDid(),
                    collection: "app.bsky.feed.like",
                    record: .knownType(likeRecord)
                )
                
                let (responseCode, response) = try await client.com.atproto.repo.createRecord(input: input)
                
                if responseCode == 200, let uri = response?.uri {
                    // Save the URI both in shadow manager and locally
                    self.likeUri = uri
                    
                    // Update shadow with real URI
                    await appState.postShadowManager.updateShadow(forUri: postId) { shadow in
                        shadow.likeUri = uri
                        print("Created like with URI: \(uri.uriString())")
                        
                        // Store the record key explicitly for easier access later
                        if let recordKey = uri.recordKey {
                            print("Like record key: \(recordKey)")
                        }
                    }
                    return true
                } else {
                    // Revert optimistic update on failure
                    await MainActor.run {
                        isLiked = wasLiked
                    }
                    await appState.postShadowManager.setLiked(postUri: postId, isLiked: wasLiked)
                    await appState.postShadowManager.setLikeCount(postUri: postId, count: currentLikeCount)
                    return false
                }
                
            } else {  // Deleting an existing like
                // Delete like record
                let userDid = try await client.getDid()
                let collection = "app.bsky.feed.like"
                
                // First try using our locally cached URI
                var recordKey = ""
                if let uri = self.likeUri {
                    print("Using locally cached like URI: \(uri.uriString())")
                    recordKey = uri.recordKey ?? ""
                }
                
                // If that fails, try shadow manager
                if recordKey.isEmpty {
                    if let shadow = await appState.postShadowManager.getShadow(forUri: postId),
                       let likeUri = shadow.likeUri {
                        print("Found like URI in shadow: \(likeUri.uriString())")
                        recordKey = likeUri.recordKey ?? ""
                    }
                }
                
                // If we still don't have a valid rkey, we can't proceed
                if recordKey.isEmpty {
                    print("Error: Unable to find valid like record key")
                    // Revert optimistic update
                    await MainActor.run {
                        isLiked = wasLiked
                    }
                    await appState.postShadowManager.setLiked(postUri: postId, isLiked: wasLiked)
                    await appState.postShadowManager.setLikeCount(postUri: postId, count: currentLikeCount)
                    return false
                }
                
                print("Deleting like with record key: \(recordKey)")
                
                let input = ComAtprotoRepoDeleteRecord.Input(
                    repo: userDid,
                    collection: collection,
                    rkey: recordKey  // Use just the record key
                )
                let response = try await client.com.atproto.repo.deleteRecord(input: input)
                
                if response.responseCode == 200 {
                    // Clear the local URI since we've successfully deleted it
                    self.likeUri = nil
                    return true
                } else {
                    print("Failed to delete like: HTTP \(response.responseCode)")
                    // Revert optimistic update on failure
                    await MainActor.run {
                        isLiked = wasLiked
                    }
                    await appState.postShadowManager.setLiked(postUri: postId, isLiked: wasLiked)
                    await appState.postShadowManager.setLikeCount(postUri: postId, count: currentLikeCount)
                    return false
                }
            }
        } catch {
            // Revert optimistic update on error
            await MainActor.run {
                isLiked = wasLiked
            }
            
            await appState.postShadowManager.setLiked(postUri: postId, isLiked: wasLiked)
            await appState.postShadowManager.setLikeCount(postUri: postId, count: currentLikeCount)
            
            print("Error toggling like: \(error)")
            return false
        }
    }
    
    /// Toggle the repost status of the post
    @discardableResult
    func toggleRepost() async throws -> Bool {
        guard let client = appState.atProtoClient else { return false }
        
        // Local copy of state variables in case we need to revert
        let wasReposted = isReposted
        let currentRepostCount = await repostCount
        
        // Start with optimistic update
        await MainActor.run {
            isReposted.toggle()
        }
        
        // Optimistically update shadow state
        await appState.postShadowManager.setReposted(postUri: postId, isReposted: !wasReposted)
        await appState.postShadowManager.setRepostCount(
            postUri: postId,
            count: wasReposted ? max(0, currentRepostCount - 1) : currentRepostCount + 1
        )
        
        do {
            if !wasReposted {  // Creating a new repost
                // Create repost record
                let post = ComAtprotoRepoStrongRef(
                    uri: try ATProtocolURI(uriString: postId),
                    cid: postCid
                )
                let repostRecord = AppBskyFeedRepost(
                    subject: post,
                    createdAt: .init(date: Date())
                )
                
                let input = ComAtprotoRepoCreateRecord.Input(
                    repo: try await client.getDid(),
                    collection: "app.bsky.feed.repost",
                    record: .knownType(repostRecord)
                )
                
                let (responseCode, response) = try await client.com.atproto.repo.createRecord(input: input)
                
                if responseCode == 200, let uri = response?.uri {
                    // Save the URI both in shadow manager and locally
                    self.repostUri = uri
                    
                    // Update shadow with real URI
                    await appState.postShadowManager.updateShadow(forUri: postId) { shadow in
                        shadow.repostUri = uri
                        print("Created repost with URI: \(uri.uriString())")
                        
                        // Store the record key explicitly for easier access later
                        if let recordKey = uri.recordKey {
                            print("Repost record key: \(recordKey)")
                        }
                    }
                    return true
                } else {
                    // Revert optimistic update on failure
                    await MainActor.run {
                        isReposted = wasReposted
                    }
                    await appState.postShadowManager.setReposted(postUri: postId, isReposted: wasReposted)
                    await appState.postShadowManager.setRepostCount(postUri: postId, count: currentRepostCount)
                    return false
                }
                
            } else {  // Deleting an existing repost
                // Delete repost record
                let userDid = try await client.getDid()
                let collection = "app.bsky.feed.repost"
                
                // First try using our locally cached URI
                var recordKey = ""
                if let uri = self.repostUri {
                    print("Using locally cached repost URI: \(uri.uriString())")
                    recordKey = uri.recordKey ?? ""
                }
                
                // If that fails, try shadow manager
                if recordKey.isEmpty {
                    if let shadow = await appState.postShadowManager.getShadow(forUri: postId),
                       let repostUri = shadow.repostUri {
                        print("Found repost URI in shadow: \(repostUri.uriString())")
                        recordKey = repostUri.recordKey ?? ""
                    }
                }
                
                // If we still don't have a valid rkey, we can't proceed
                if recordKey.isEmpty {
                    print("Error: Unable to find valid repost record key")
                    // Revert optimistic update
                    await MainActor.run {
                        isReposted = wasReposted
                    }
                    await appState.postShadowManager.setReposted(postUri: postId, isReposted: wasReposted)
                    await appState.postShadowManager.setRepostCount(postUri: postId, count: currentRepostCount)
                    return false
                }
                
                print("Deleting repost with record key: \(recordKey)")
                
                let input = ComAtprotoRepoDeleteRecord.Input(
                    repo: userDid,
                    collection: collection,
                    rkey: recordKey  // Use just the record key
                )
                let response = try await client.com.atproto.repo.deleteRecord(input: input)
                
                if response.responseCode == 200 {
                    // Clear the local URI since we've successfully deleted it
                    self.repostUri = nil
                    return true
                } else {
                    print("Failed to delete repost: HTTP \(response.responseCode)")
                    // Revert optimistic update on failure
                    await MainActor.run {
                        isReposted = wasReposted
                    }
                    await appState.postShadowManager.setReposted(postUri: postId, isReposted: wasReposted)
                    await appState.postShadowManager.setRepostCount(postUri: postId, count: currentRepostCount)
                    return false
                }
            }
        } catch {
            // Revert optimistic update on error
            await MainActor.run {
                isReposted = wasReposted
            }
            
            await appState.postShadowManager.setReposted(postUri: postId, isReposted: wasReposted)
            await appState.postShadowManager.setRepostCount(postUri: postId, count: currentRepostCount)
            
            print("Error toggling repost: \(error)")
            return false
        }
    }
    
    /// Create a quote post
    @discardableResult
    func createQuotePost(text: String) async throws -> Bool {
        guard let client = appState.atProtoClient else { return false }
        
        // Get current state for reverting if needed
        let wasReposted = isReposted
        let currentRepostCount = await repostCount
        
        // Optimistically update repost state
        await MainActor.run {
            isReposted = true
        }
        
        // Optimistically update shadow state
        await appState.postShadowManager.setReposted(postUri: postId, isReposted: true)
        await appState.postShadowManager.setRepostCount(postUri: postId, count: currentRepostCount + 1)
        
        do {
            // Create quote post record
            let post = ComAtprotoRepoStrongRef(
                uri: try ATProtocolURI(uriString: postId),
                cid: postCid
            )
            
            let embed = AppBskyEmbedRecord(record: post)
            let quotePost = AppBskyFeedPost(
                text: text,
                entities: [],
                facets: [],
                reply: nil,
                embed: .appBskyEmbedRecord(embed),
                langs: [],
                labels: nil,
                tags: [],
                createdAt: .init(date: Date())
            )
            
            let input = ComAtprotoRepoCreateRecord.Input(
                repo: try await client.getDid(),
                collection: "app.bsky.feed.post",
                record: .knownType(quotePost)
            )
            
            let (responseCode, response) = try await client.com.atproto.repo.createRecord(input: input)
            
            if responseCode == 200 {
                // Save URI locally
                if let uri = response?.uri {
                    self.repostUri = uri
                }
                
                // Update shadow state to indicate it's a quote post
                await appState.postShadowManager.updateShadow(forUri: postId) { shadow in
                    shadow.repostUri = response?.uri
                }
                
                return true
            } else {
                // Revert optimistic update on failure
                await MainActor.run {
                    isReposted = wasReposted
                }
                await appState.postShadowManager.setReposted(postUri: postId, isReposted: wasReposted)
                await appState.postShadowManager.setRepostCount(postUri: postId, count: currentRepostCount)
                return false
            }
        } catch {
            // Revert optimistic update on error
            await MainActor.run {
                isReposted = wasReposted
            }
            await appState.postShadowManager.setReposted(postUri: postId, isReposted: wasReposted)
            await appState.postShadowManager.setRepostCount(postUri: postId, count: currentRepostCount)
            
            print("Error creating quote post: \(error)")
            return false
        }
    }
}
