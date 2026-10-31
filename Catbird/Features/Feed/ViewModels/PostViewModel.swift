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
    private(set) var postId: String
    
    /// The content identifier (CID) for the post
    private(set) var postCid: CID
    
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
    private(set) var authorDid: String?

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
    
    /// Reconfigures the view model in-place when a feed cell is reused for a new post.
    @MainActor
    func configure(
        post: AppBskyFeedDefs.PostView,
        appState: AppState,
        visibilityContext: PostVisibilityContext = .public
    ) {
        self.postId = post.uri.uriString()
        self.postCid = post.cid
        self.appState = appState
        self.authorDid = post.author.did.didString()
        self.visibilityContext = visibilityContext
        self.isLiked = post.viewer?.like != nil
        self.isReposted = post.viewer?.repost != nil
        self.isBookmarked = post.viewer?.bookmarked == true
        self.likeCount = post.likeCount ?? 0
        self.repostCount = post.repostCount ?? 0
        self.replyCount = post.replyCount ?? 0
        self.likeUri = post.viewer?.like
        self.repostUri = post.viewer?.repost
    }

    /// Starts deterministic async initialization of the view model, reconciling shadow and server state
    @MainActor
    @discardableResult
    func start(post: AppBskyFeedDefs.PostView? = nil) async -> AppBskyFeedDefs.PostView? {
        if let post {
            return await initializeFromServerState(post: post)
        }
        await checkInteractionState()
        return nil
    }
    
    /// Initialize the shadow state when a post is loaded
    @MainActor
    @discardableResult
    func initializeFromServerState(post: AppBskyFeedDefs.PostView) async -> AppBskyFeedDefs.PostView? {
        guard !Task.isCancelled else { return nil }
        
        // Reconcile shadow with server state and derive merged post in a single actor hop
        let merged = await appState.postShadowManager.reconcileAndMergeShadow(post: post)
        guard !Task.isCancelled, post.uri.uriString() == postId else { return nil }

        // Assign only changed values: every observable write invalidates the views reading
        // it, and this runs for each row right after its first render.
        let liked = merged.viewer?.like != nil
        if isLiked != liked { isLiked = liked }
        if likeUri != merged.viewer?.like { likeUri = merged.viewer?.like }
        if likeCount != merged.likeCount ?? 0 { likeCount = merged.likeCount ?? 0 }

        let reposted = merged.viewer?.repost != nil
        if isReposted != reposted { isReposted = reposted }
        if repostUri != merged.viewer?.repost { repostUri = merged.viewer?.repost }
        if repostCount != merged.repostCount ?? 0 { repostCount = merged.repostCount ?? 0 }

        let bookmarked = merged.viewer?.bookmarked == true
        if isBookmarked != bookmarked { isBookmarked = bookmarked }
        if replyCount != merged.replyCount ?? 0 { replyCount = merged.replyCount ?? 0 }
        return merged
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
    @MainActor
    private func revertLikeState(wasLiked: Bool, source: AppState) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                guard self.appState === source else { return }
                self.isLiked = wasLiked
            }
            
            group.addTask { 
                await source.postShadowManager.setLiked(postUri: self.postId, isLiked: wasLiked)
            }
        }
    }
    
    /// Reverts the repost state optimistically
    @MainActor
    private func revertRepostState(wasReposted: Bool, source: AppState) async {
        let previousRepostUri = repostUri
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                guard self.appState === source else { return }
                self.isReposted = wasReposted
            }
            
            group.addTask {
                if wasReposted, let previousRepostUri {
                    await source.postShadowManager.updateShadow(forUri: self.postId) { shadow in
                        shadow.decideRepost(previousRepostUri)
                    }
                } else {
                    await source.postShadowManager.setReposted(postUri: self.postId, isReposted: wasReposted)
                }
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
    
    @MainActor
    private func requireInteractionAccess(source: AppState, client: ATProtoClient, did: String? = nil) throws {
        try Task.checkCancellation()
        guard appState === source, source.atProtoClient === client,
              !source.isAccountSwitchSuspended,
              did == nil || did == source.userDID else { throw CancellationError() }
        try source.ageAccess.require(.generalContent)
    }

    /// Toggle the like status of the post
    /// - Parameter via: Optional reference to the repost that led to discovering this content.
    ///   When set, creates a "like-via-repost" notification for the author of the referenced repost.
    ///   Only set this when the user discovered this post through someone else's repost.
    ///   Example: Alice posts → Bob reposts → Carol likes via Bob's repost → `via` = Bob's repost record
    ///   Note: Attribution is controlled by the enableViaAttribution setting
    @MainActor
    @discardableResult
    func toggleLike(
        via: ComAtprotoRepoStrongRef? = nil,
        feedInteractionTarget: FeedInteractionTarget? = nil
    ) async throws -> Bool {
        guard let client = appState.atProtoClient else {
            throw PostViewModelError.missingClient // Throw error instead of returning false
        }
        let source = appState
        if !isLiked { try requireInteractionAccess(source: source, client: client) }
        
        // Local copy for reverting if needed
        let wasLiked = isLiked
        
        // Use task groups for optimistic updates
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                guard self.appState === source else { return }
                self.isLiked.toggle()
            }
            
            group.addTask {
                await source.postShadowManager.setLiked(postUri: self.postId, isLiked: !wasLiked)
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
                    let enableAttribution = source.appSettings.enableViaAttribution
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
                    try requireInteractionAccess(source: source, client: client, did: did)
                    let (code, data) = try await client.com.atproto.repo.createRecord(input: input)
                    guard appState === source, source.atProtoClient === client,
                          !source.isAccountSwitchSuspended else { throw CancellationError() }
                    
                    guard code == 200, let response = data else {
                        throw PostViewModelError.requestFailed
                    }
                    // Save the URI both in shadow manager and locally
                    self.likeUri = response.uri
                    
                    // Update shadow with real URI
                    await source.postShadowManager.updateShadow(forUri: postId) { shadow in
                        shadow.decideLike(response.uri)
                    }
                    
                    // Tell the feed the post was liked from, when it accepts feedback
                    if let postURI = try? ATProtocolURI(uriString: postId) {
                        await source.feedFeedbackManager.trackLike(postURI: postURI, target: feedInteractionTarget)
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
                    await source.postShadowManager.updateShadow(forUri: postId) { shadow in
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
            if appState === source { await revertLikeState(wasLiked: wasLiked, source: source) }
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
    @MainActor
    @discardableResult
    func toggleRepost(
        via: ComAtprotoRepoStrongRef? = nil,
        feedInteractionTarget: FeedInteractionTarget? = nil
    ) async throws -> Bool {
        guard capabilities.canRepost else {
            logger.info("Repost unavailable for visibility context")
            return false
        }
        guard let client = appState.atProtoClient else {
            throw PostViewModelError.missingClient
        }
        let source = appState
        if !isReposted { try requireInteractionAccess(source: source, client: client) }
        
        // Local copy for reverting if needed
        let wasReposted = isReposted
        // Unreposting clears the shadow URI, so retain it before the optimistic update.
        let previousShadowRepostUri = await source.postShadowManager.getShadow(forUri: postId)?.repostUri
        guard appState === source, source.atProtoClient === client,
              !source.isAccountSwitchSuspended else { throw CancellationError() }
        let previousRepostUri: ATProtocolURI?
        if let repostUri = self.repostUri, repostUri.recordKey?.isEmpty == false {
            previousRepostUri = repostUri
        } else {
            previousRepostUri = previousShadowRepostUri ?? self.repostUri
        }
        
        // Use task groups for optimistic updates
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                guard self.appState === source else { return }
                self.isReposted.toggle()
            }
            
            group.addTask {
                await source.postShadowManager.setReposted(postUri: self.postId, isReposted: !wasReposted)
            }
        }
        
        do {
            if !wasReposted { // Creating a new repost
                let postRef = ComAtprotoRepoStrongRef(
                    uri: try ATProtocolURI(uriString: postId),
                    cid: postCid
                )
                // Check if via attribution is enabled in settings
                let enableAttribution = source.appSettings.enableViaAttribution
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
                
                try requireInteractionAccess(source: source, client: client, did: did)
                let (code, data) = try await client.com.atproto.repo.createRecord(input: input)
                guard appState === source, source.atProtoClient === client,
                      !source.isAccountSwitchSuspended else { throw CancellationError() }
                
                guard code == 200, let response = data else {
                    throw PostViewModelError.requestFailed
                }

                // Save the URI both in shadow manager and locally
                self.repostUri = response.uri
                
                // Update shadow with real URI
                await source.postShadowManager.updateShadow(forUri: postId) { shadow in
                    shadow.decideRepost(response.uri)
                }
                
                // Tell the feed the post was reposted from, when it accepts feedback
                if let postURI = try? ATProtocolURI(uriString: postId) {
                    await source.feedFeedbackManager.trackRepost(postURI: postURI, target: feedInteractionTarget)
                }
                
                return true
                
            } else { // Deleting an existing repost
                let collection = "app.bsky.feed.repost"
                
                guard let recordKey = previousRepostUri?.recordKey, !recordKey.isEmpty else {
                    throw PostViewModelError.unableToFindRecordKey
                }
                
                let did = try await client.getDid()
                let input = ComAtprotoRepoDeleteRecord.Input(
                    repo: try ATIdentifier(string: did),
                    collection: try NSID(nsidString: collection),
                    rkey: try RecordKey(keyString: recordKey)
                )
                
                let responseCode = try await client.com.atproto.repo.deleteRecord(input: input).responseCode
                guard (200...299).contains(responseCode) else {
                    throw PostViewModelError.repostRemovalFailed(statusCode: responseCode)
                }
                
                // Clear the local URI since we've successfully deleted it
                self.repostUri = nil
                // Shadow state already updated optimistically
                return true
            }
        } catch {
            // Revert optimistic update on any error
            if appState === source {
                self.repostUri = previousRepostUri
                await revertRepostState(wasReposted: wasReposted, source: source)
            }
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
    @MainActor
    @discardableResult
    func createQuotePost(text: String) async throws -> Bool {
        guard capabilities.canQuote else {
            logger.info("Quote unavailable for visibility context")
            return false
        }
        guard let client = appState.atProtoClient else {
            throw PostViewModelError.missingClient
        }
        let source = appState
        try requireInteractionAccess(source: source, client: client)
        
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
            try requireInteractionAccess(source: source, client: client, did: did)
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
    enum PostViewModelError: LocalizedError {
        case missingClient
        case unableToFindRecordKey
        case requestFailed
        case repostRemovalFailed(statusCode: Int)

        var errorDescription: String? {
            switch self {
            case .missingClient:
                return "Your account is unavailable. Please sign in and try again."
            case .unableToFindRecordKey:
                return "The interaction record could not be found. Refresh the post and try again."
            case .requestFailed:
                return "The request could not be completed. Please try again."
            case .repostRemovalFailed:
                return "Your repost couldn’t be removed. Try again."
            }
        }
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
