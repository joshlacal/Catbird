//
//  PostViewModel.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/28/24.
//

import Foundation
import Petrel
import PetrelCatbird
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
    private(set) var likeUri: ATProtocolURI?
    private(set) var repostUri: ATProtocolURI?

    /// Visibility context for the post (public or circle)
    var visibilityContext: PostVisibilityContext = .public
    private let authorDid: String?

    /// Capabilities available for this post given its visibility context
    var capabilities: PostCapabilities {
        let isAuthor = authorDid != nil && authorDid == appState.userDID
        return PostCapabilities.forContext(visibilityContext, isAuthor: isAuthor)
    }
    /// Logger for debugging
    let logger = Logger(subsystem: "blue.catbird", category: "PostViewModel")
    
    // MARK: - Initialization
    
    /// Initialize the view model with a post ID and app state
    /// - Parameters:
    ///   - postId: The URI string of the post
    ///   - postCid: The CID of the post
    ///   - appState: The app state
    ///   - authorDid: Optional author DID of the post
    ///   - visibilityContext: The visibility context of the post
    @MainActor
    init(
        postId: String,
        postCid: CID,
        appState: AppState,
        authorDid: String? = nil,
        visibilityContext: PostVisibilityContext = .public
    ) {
        self.postId = postId
        self.postCid = postCid
        self.appState = appState
        self.authorDid = authorDid
        self.visibilityContext = visibilityContext
    }
    
    /// Convenience initializer from a post view
    @MainActor
    convenience init(
        post: AppBskyFeedDefs.PostView,
        appState: AppState,
        visibilityContext: PostVisibilityContext = .public
    ) {
        self.init(
            postId: post.uri.uriString(),
            postCid: post.cid,
            appState: appState,
            authorDid: post.author.did.didString(),
            visibilityContext: visibilityContext
        )
        
        self.isLiked = post.viewer?.like != nil
        self.isReposted = post.viewer?.repost != nil
        self.isBookmarked = post.viewer?.bookmarked == true
        self.likeCount = post.likeCount ?? 0
        self.repostCount = post.repostCount ?? 0
        self.replyCount = post.replyCount ?? 0
        self.likeUri = post.viewer?.like
        self.repostUri = post.viewer?.repost
    }
    
    // MARK: - State Management
    
    /// Starts deterministic async initialization of the view model, reconciling shadow and server state
    @MainActor
    func start(post: AppBskyFeedDefs.PostView? = nil) async {
        if let post {
            await initializeFromServerState(post: post)
            guard !Task.isCancelled else { return }
        }
        await checkInteractionState()
    }
    
    /// Initialize the shadow state when a post is loaded
    @MainActor
    func initializeFromServerState(post: AppBskyFeedDefs.PostView) async {
        guard !Task.isCancelled else { return }
        
        // Reconcile shadow with server state
        await appState.postShadowManager.updateShadow(forUri: post.uri.uriString()) { shadow in
            shadow.hydrateFromServer(likeUri: post.viewer?.like, repostUri: post.viewer?.repost)
        }
        guard !Task.isCancelled else { return }
        
        let shadow = await appState.postShadowManager.getShadow(forUri: post.uri.uriString())
        guard !Task.isCancelled else { return }
        
        if let shadow, shadow.likeDecided {
            isLiked = shadow.likeUri != nil
            likeUri = shadow.likeUri
            if shadow.likeUri != nil && post.viewer?.like == nil {
                likeCount = (post.likeCount ?? 0) + 1
            } else if shadow.likeUri == nil && post.viewer?.like != nil {
                likeCount = max(0, (post.likeCount ?? 0) - 1)
            } else {
                likeCount = post.likeCount ?? 0
            }
        } else {
            isLiked = post.viewer?.like != nil
            likeUri = post.viewer?.like
            likeCount = post.likeCount ?? 0
        }
        
        if let shadow, shadow.repostDecided {
            isReposted = shadow.repostUri != nil
            repostUri = shadow.repostUri
            if shadow.repostUri != nil && post.viewer?.repost == nil {
                repostCount = (post.repostCount ?? 0) + 1
            } else if shadow.repostUri == nil && post.viewer?.repost != nil {
                repostCount = max(0, (post.repostCount ?? 0) - 1)
            } else {
                repostCount = post.repostCount ?? 0
            }
        } else {
            isReposted = post.viewer?.repost != nil
            repostUri = post.viewer?.repost
            repostCount = post.repostCount ?? 0
        }
        
        if let shadow, let bookmarked = shadow.bookmarked {
            isBookmarked = bookmarked
        } else {
            isBookmarked = post.viewer?.bookmarked == true
        }
        replyCount = post.replyCount ?? 0
    }
    
    /// Updates the interaction state from the shadow manager
    @MainActor
    func checkInteractionState() async {
        guard !Task.isCancelled else { return }
        if let shadow = await appState.postShadowManager.getShadow(forUri: postId) {
            guard !Task.isCancelled else { return }
            if shadow.likeDecided {
                isLiked = shadow.likeUri != nil
                likeUri = shadow.likeUri
            }
            if shadow.repostDecided {
                isReposted = shadow.repostUri != nil
                repostUri = shadow.repostUri
            }
            if let bookmarked = shadow.bookmarked {
                isBookmarked = bookmarked
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
    private func revertLikeState(wasLiked: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                self.isLiked = wasLiked
            }
            
            group.addTask { 
                await self.appState.postShadowManager.setLiked(postUri: self.postId, isLiked: wasLiked)
            }
        }
    }
    
    /// Reverts the repost state optimistically
    private func revertRepostState(wasReposted: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                self.isReposted = wasReposted
            }
            
            group.addTask {
                await self.appState.postShadowManager.setReposted(postUri: self.postId, isReposted: wasReposted)
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
        
        // Use task groups for optimistic updates
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                self.isLiked.toggle()
            }
            
            group.addTask {
                await self.appState.postShadowManager.setLiked(postUri: self.postId, isLiked: !wasLiked)
            }
        }
        
        do {
            if !wasLiked { // Creating a new like
                switch visibilityContext {
                case .public:
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
                        shadow.decideLike(response.uri)
                    }
                    
                    // Track interaction for feed feedback
                    if let postURI = try? ATProtocolURI(uriString: postId) {
                        appState.feedFeedbackManager.trackLike(postURI: postURI)
                    }
                case let .circle(circle):
                    let postRef = ComAtprotoRepoStrongRef(
                        uri: try ATProtocolURI(uriString: postId),
                        cid: postCid
                    )
                    let postView = AppBskyFeedDefs.PostView(
                        uri: postRef.uri,
                        cid: postRef.cid,
                        author: AppBskyActorDefs.ProfileViewBasic(
                            did: try DID(didString: "did:plc:author"),
                            handle: try Handle(handleString: "handle.invalid"),
                            displayName: nil,
                            pronouns: nil,
                            avatar: nil,
                            associated: nil,
                            viewer: nil,
                            labels: nil,
                            createdAt: nil,
                            verification: nil,
                            status: nil,
                            debug: nil
                        ),
                        record: ATProtocolValueContainer.knownType(
                            AppBskyFeedPost(
                                text: "",
                                entities: nil,
                                facets: nil,
                                reply: nil,
                                embed: nil,
                                langs: [],
                                labels: nil,
                                tags: nil,
                                createdAt: ATProtocolDate(date: Date())
                            )
                        ),
                        embed: nil,
                        bookmarkCount: nil,
                        replyCount: nil,
                        repostCount: nil,
                        likeCount: nil,
                        quoteCount: nil,
                        indexedAt: ATProtocolDate(date: Date()),
                        viewer: nil,
                        labels: nil,
                        threadgate: nil,
                        debug: nil
                    )
                    let service = appState.circleService
                    let responseUri = try await service.like(post: postView, circle: circle)
                    self.likeUri = responseUri
                    await appState.postShadowManager.updateShadow(forUri: postId) { shadow in
                        shadow.decideLike(responseUri)
                    }
                }
            } else { // Deleting an existing like
                switch visibilityContext {
                case .public:
                    guard let uri = likeUri else {
                        throw PostViewModelError.unableToFindRecordKey
                    }
                    
                    let did = try await client.getDid()
                    let input = ComAtprotoRepoDeleteRecord.Input(
                        repo: try ATIdentifier(string: did),
                        collection: try NSID(nsidString: "app.bsky.feed.like"),
                        rkey: try RecordKey(keyString: uri.recordKey ?? "")
                    )
                    
                    let responseCode = try await client.com.atproto.repo.deleteRecord(input: input).responseCode
                    
                    guard responseCode == 200 else {
                        throw PostViewModelError.requestFailed
                    }
                    
                    self.likeUri = nil
                    await appState.postShadowManager.updateShadow(forUri: postId) { shadow in
                        shadow.decideLike(nil)
                    }
                case let .circle(circle):
                    guard let uri = likeUri else {
                        throw CircleError.missingLikeUri
                    }
                    let service = appState.circleService
                    try await service.deleteLike(uri: uri, circle: circle)
                    self.likeUri = nil
                    await appState.postShadowManager.updateShadow(forUri: postId) { shadow in
                        shadow.decideLike(nil)
                    }
                }
            }
            return true
        } catch {
            // Revert optimistic update on any error
            await revertLikeState(wasLiked: wasLiked)
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
        guard capabilities.canRepost else {
            logger.info("Repost unavailable for visibility context")
            return false
        }
        guard let client = appState.atProtoClient else {
            throw PostViewModelError.missingClient
        }
        
        // Local copy for reverting if needed
        let wasReposted = isReposted
        
        // Use task groups for optimistic updates
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                self.isReposted.toggle()
            }
            
            group.addTask {
                await self.appState.postShadowManager.setReposted(postUri: self.postId, isReposted: !wasReposted)
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
                    shadow.decideRepost(response.uri)
                }
                
                // Track interaction for feed feedback
                if let postURI = try? ATProtocolURI(uriString: postId) {
                    appState.feedFeedbackManager.trackRepost(postURI: postURI)
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
                    await revertRepostState(wasReposted: wasReposted)
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
            await revertRepostState(wasReposted: wasReposted)
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
                
                await MainActor.run {
                    appState.toastManager.show(ToastItem(message: "Bookmarked", icon: "bookmark.fill"))
                }
                return true
                
            } else { // Deleting an existing bookmark
                try await appState.bookmarksManager.deleteBookmark(
                    postUri: postUri,
                    client: client
                )
                
                await MainActor.run {
                    appState.toastManager.show(ToastItem(message: "Bookmark removed", icon: "bookmark"))
                }
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
        guard capabilities.canQuote else {
            logger.info("Quote unavailable for visibility context")
            return false
        }
        guard let client = appState.atProtoClient else {
            throw PostViewModelError.missingClient
        }
        
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
            _ = try await client.com.atproto.repo.createRecord(input: input)
            
            // We don't save this URI as `self.repostUri` because it's the URI of the *new* quote post,
            // not a direct repost record of the original post.
            // We also don't update the shadow's `repostUri` for the original post.
            return true
        } catch {
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

    #if DEBUG
    func setLikedStateForTesting(isLiked: Bool, likeUri: ATProtocolURI?) {
        self.isLiked = isLiked
        self.likeUri = likeUri
    }
    #endif
}

extension PostViewModel {
    @MainActor
    public static func forCircleItem(
        _ item: BlueCatbirdCircleDefs.FeedItem,
        appState: AppState
    ) -> PostViewModel {
        PostViewModel(
            post: item.post.post,
            appState: appState,
            visibilityContext: .circle(item.circle)
        )
    }

    @MainActor
    public static func forCircle(
        post: AppBskyFeedDefs.PostView,
        circle: CircleSummary,
        appState: AppState
    ) -> PostViewModel {
        PostViewModel(
            post: post,
            appState: appState,
            visibilityContext: .circle(circle)
        )
    }
}
