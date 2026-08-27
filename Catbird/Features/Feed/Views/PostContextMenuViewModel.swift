//
//  PostContextMenuViewModel.swift
//  Catbird
//
//  Created by Josh LaCalamito on 8/29/24.
//

import SwiftUI
import Petrel
import PetrelCatbird
import Observation
import OSLog

@Observable
final class PostContextMenuViewModel {
    let appState: AppState
    let post: AppBskyFeedDefs.PostView
    let allowsThreadSummary: Bool
    let visibilityContext: PostVisibilityContext
    
    private let logger = Logger(subsystem: "blue.catbird", category: "PostContextMenu")
    
    // Reporting callback - will be set by PostView
    var onReportPost: (() -> Void)?
    
    // Add to list callback - will be set by PostView
    var onAddAuthorToList: (() -> Void)?
    
    // Bookmark callback - will be set by PostView
    var onToggleBookmark: (() -> Void)?
    

    // Thread summarization callback - wired by PostView when supported
    var onSummarizeThread: (() -> Void)?

    // Thread moderation and context
    var rootPostURI: ATProtocolURI?
    var rootAuthorDID: String?
    var isReplyHiddenByThreadgate: Bool = false
    private var isPinnedOverride: Bool?
    private var isQuoteDetachedOverride: Bool?

    /// The root URI from the post's own reply record, when present.
    private var embeddedReplyRoot: ATProtocolURI? {
        if case .knownType(let record) = post.record,
           let feedPost = record as? AppBskyFeedPost {
            return feedPost.reply?.root.uri
        }
        return nil
    }

    var resolvedRootPostURI: ATProtocolURI? {
        rootPostURI ?? embeddedReplyRoot ?? post.uri
    }

    var resolvedRootAuthorDID: String? {
        if let rootAuthorDID = rootAuthorDID {
            return rootAuthorDID
        }
        if let replyRoot = embeddedReplyRoot {
            return replyRoot.authority
        }
        if case .knownType(let record) = post.record, record is AppBskyFeedPost {
            return post.author.did.didString()
        }
        if let rootURI = rootPostURI {
            return rootURI.authority
        }
        return post.author.did.didString()
    }

    var isRootAuthor: Bool {
        guard let rootDID = resolvedRootAuthorDID else {
            return false
        }
        return rootDID == appState.userDID
    }

    init(
        appState: AppState,
        post: AppBskyFeedDefs.PostView,
        allowsThreadSummary: Bool = false,
        visibilityContext: PostVisibilityContext = .public,
        rootPostURI: ATProtocolURI? = nil,
        rootAuthorDID: String? = nil,
        isReplyHiddenByThreadgate: Bool = false
    ) {
        self.appState = appState
        self.post = post
        self.allowsThreadSummary = allowsThreadSummary
        self.visibilityContext = visibilityContext
        self.rootPostURI = rootPostURI
        self.rootAuthorDID = rootAuthorDID
        self.isReplyHiddenByThreadgate = isReplyHiddenByThreadgate
    }

    func deletePost(visibilityContext: PostVisibilityContext? = nil) async {
        let effectiveContext = visibilityContext ?? self.visibilityContext
        switch effectiveContext {
        case .public:
            let did = appState.userDID
            do {
                let input = ComAtprotoRepoDeleteRecord.Input(
                    repo: try ATIdentifier(string: did),
                    collection: try NSID(nsidString: "app.bsky.feed.post"),
                    rkey: try RecordKey(keyString: post.uri.recordKey ?? "")
                )

                let responseCode = try await appState.atProtoClient?.com.atproto.repo.deleteRecord(input: input).responseCode
                if responseCode == 200 {
                    logger.debug("Post deleted successfully")
                    
                    await appState.postShadowManager.updateShadow(forUri: post.uri.uriString()) { shadow in
                        shadow.isDeleted = true
                    }
                    
                    // Show deletion toast and notify invalidations
                    await MainActor.run {
                        appState.stateInvalidationBus.notify(.feedUpdated(.timeline))
                        appState.stateInvalidationBus.notify(.profileUpdated(did: did))
                        if let rootURI = resolvedRootPostURI?.uriString() {
                            appState.stateInvalidationBus.notify(.threadUpdated(rootUri: rootURI))
                        }
                        appState.toastManager.show(
                            ToastItem(
                                message: "Post deleted",
                                icon: "trash.fill",
                                duration: 2.5
                            )
                        )
                    }
                }
            } catch {
                logger.debug("Error deleting post: \(error)")
            }
        case let .circle(circle):
            let did = appState.userDID
            do {
                try await appState.circleService.deletePost(uri: post.uri, circle: circle)
                await appState.postShadowManager.updateShadow(forUri: post.uri.uriString()) { shadow in
                    shadow.isDeleted = true
                }
                await MainActor.run {
                    appState.stateInvalidationBus.notify(.feedUpdated(.timeline))
                    appState.stateInvalidationBus.notify(.profileUpdated(did: did))
                    if let rootURI = resolvedRootPostURI?.uriString() {
                        appState.stateInvalidationBus.notify(.threadUpdated(rootUri: rootURI))
                    }
                    appState.toastManager.show(
                        ToastItem(
                            message: "Post deleted",
                            icon: "trash.fill",
                            duration: 2.5
                        )
                    )
                }
            } catch {
                logger.debug("Error deleting circle post: \(error)")
            }
        }
    }

    func blockUser() async {
        let targetDid = post.author.did.didString()

        // Prefer the MLS-aware coordinator when available — it publishes the
        // block record AND auto-leaves any shared MLS groups. Falls back to
        // the raw createRecord path on non-MLS installs so that existing
        // behavior is preserved.
        let coordinator = await MainActor.run { appState.mlsBlockCoordinator }
        if let coord = coordinator {
            do {
                try await coord.block(did: targetDid)
                logger.debug("User blocked successfully via MLSBlockCoordinator")
                await MainActor.run {
                    appState.toastManager.show(
                        ToastItem(
                            message: "User blocked",
                            icon: "hand.raised.fill",
                            duration: 2.5
                        )
                    )
                }
            } catch {
                logger.debug("Error blocking user via coordinator: \(error)")
            }
            return
        }

        // Fallback: publish the block record directly.
        let did = appState.userDID
        let block = AppBskyGraphBlock(subject: post.author.did, createdAt: ATProtocolDate(date: Date()))
        do {
            let input = ComAtprotoRepoCreateRecord.Input(
                repo: try ATIdentifier(string: did),
                collection: try NSID(nsidString: "app.bsky.graph.block"),
                record: ATProtocolValueContainer.knownType(block)
            )

            let result = try await appState.atProtoClient?.com.atproto.repo.createRecord(input: input)
            if let (responseCode, _) = result {
                if responseCode == 200 {

                    logger.debug("User blocked successfully")

                    // Show block toast
                    await MainActor.run {
                        appState.toastManager.show(
                            ToastItem(
                                message: "User blocked",
                                icon: "hand.raised.fill",
                                duration: 2.5
                            )
                        )
                    }
                }
            }
        } catch {
            logger.debug("Error blocking user: \(error)")
        }
    }

    func muteUser() async {
        do {
            let input = AppBskyGraphMuteActor.Input(actor: try ATIdentifier(string: post.author.did.didString()))

            let responseCode = try await appState.atProtoClient?.app.bsky.graph.muteActor(input: input)
            if responseCode == 200 {
                logger.debug("User muted successfully")
                
                // Show mute toast
                await MainActor.run {
                    appState.toastManager.show(
                        ToastItem(
                            message: "User muted",
                            icon: "speaker.slash.fill",
                            duration: 2.5
                        )
                    )
                }
            }
        } catch {
            logger.debug("Error muting user: \(error)")
        }
    }

    func muteThread() async {
        guard case .public = visibilityContext else {
            logger.debug("muteThread skipped: private circle post context")
            return
        }
        let input = AppBskyGraphMuteThread.Input(root: post.uri)
        do {
            let responseCode = try await appState.atProtoClient?.app.bsky.graph.muteThread(input: input)
            if responseCode == 200 {
                logger.debug("Thread muted successfully")
                
                // Show thread mute toast
                await MainActor.run {
                    appState.toastManager.show(
                        ToastItem(
                            message: "Thread muted",
                            icon: "bell.slash.fill",
                            duration: 2.5
                        )
                    )
                }
            }
        } catch {
            logger.debug("Error muting thread: \(error)")
        }
    }
    
    func hidePost() async {
        let postURI = post.uri.uriString()
        await appState.postHidingManager.hidePost(postURI)
        logger.debug("Post hidden: \(postURI)")
        
        // Show confirmation toast
        await MainActor.run {
            appState.toastManager.show(ToastItem(message: "Post hidden", icon: "checkmark.circle.fill"))
        }
    }
    
    func unhidePost() async {
        let postURI = post.uri.uriString()
        await appState.postHidingManager.unhidePost(postURI)
        logger.debug("Post unhidden: \(postURI)")
        
        // Show confirmation toast
        await MainActor.run {
            appState.toastManager.show(ToastItem(message: "Post unhidden", icon: "checkmark.circle.fill"))
        }
    }
    
    @MainActor var isPostHidden: Bool {
        appState.postHidingManager.isHidden(post.uri.uriString())
    }
    var isPinned: Bool {
        if let override = isPinnedOverride {
            return override
        }
        return post.viewer?.pinned == true
    }

    func togglePin() async {
        let did = appState.userDID
        let postURI = post.uri.uriString()
        do {
            if isPinned {
                try await appState.postManager.unpinPost()
                await appState.postShadowManager.updateShadow(forUri: postURI) { shadow in
                    shadow.pinned = false
                }
                await MainActor.run {
                    isPinnedOverride = false
                    appState.stateInvalidationBus.notify(.profileUpdated(did: did))
                    appState.stateInvalidationBus.notify(.feedUpdated(.author(did)))
                    appState.stateInvalidationBus.notify(.feedUpdated(.timeline))
                    appState.toastManager.show(
                        ToastItem(
                            message: "Post unpinned from profile",
                            icon: "pin.slash.fill",
                            duration: 2.5
                        )
                    )
                }
            } else {
                var previousPinnedUri: String?
                if let client = appState.atProtoClient {
                    let getRecordParams = ComAtprotoRepoGetRecord.Parameters(
                        repo: try ATIdentifier(string: did),
                        collection: try NSID(nsidString: "app.bsky.actor.profile"),
                        rkey: try RecordKey(keyString: "self")
                    )
                    if let (_, output) = try? await client.com.atproto.repo.getRecord(input: getRecordParams),
                       let existingRecord = output,
                       case let .knownType(value) = existingRecord.value,
                       let existingProfile = value as? AppBskyActorProfile,
                       let pinnedRef = existingProfile.pinnedPost {
                        previousPinnedUri = pinnedRef.uri.uriString()
                    }
                }

                try await appState.postManager.pinPost(uri: post.uri, cid: post.cid.string)

                if let prevUri = previousPinnedUri, prevUri != postURI {
                    await appState.postShadowManager.updateShadow(forUri: prevUri) { shadow in
                        shadow.pinned = false
                    }
                }

                await appState.postShadowManager.updateShadow(forUri: postURI) { shadow in
                    shadow.pinned = true
                }
                await MainActor.run {
                    isPinnedOverride = true
                    appState.stateInvalidationBus.notify(.profileUpdated(did: did))
                    appState.stateInvalidationBus.notify(.feedUpdated(.author(did)))
                    appState.stateInvalidationBus.notify(.feedUpdated(.timeline))
                    appState.toastManager.show(
                        ToastItem(
                            message: "Post pinned to profile",
                            icon: "pin.fill",
                            duration: 2.5
                        )
                    )
                }
            }
        } catch {
            logger.error("Error toggling pinned post: \(error)")
            await MainActor.run {
                appState.toastManager.show(
                    ToastItem(
                        message: "Failed to update pinned post",
                        icon: "exclamationmark.triangle.fill",
                        duration: 2.5
                    )
                )
            }
        }
    }

    // MARK: - Detached / Quote Posts (G14)

    /// The quoted post URI if this post quotes a post authored by the signed-in user.
    var quotedPostURI: ATProtocolURI? {
        let did = appState.userDID
        guard let embed = post.embed else { return nil }
        switch embed {
        case .appBskyEmbedRecordView(let recordView):
            switch recordView.record {
            case .appBskyEmbedRecordViewRecord(let viewRecord):
                if viewRecord.author.did.didString() == did {
                    return viewRecord.uri
                }
            case .appBskyEmbedRecordViewDetached(let viewDetached):
                if viewDetached.uri.authority == did {
                    return viewDetached.uri
                }
            case .appBskyEmbedRecordViewNotFound, .appBskyEmbedRecordViewBlocked, .appBskyFeedDefsGeneratorView,
                 .appBskyGraphDefsListView, .appBskyLabelerDefsLabelerView, .appBskyGraphDefsStarterPackViewBasic,
                 .unexpected:
                break
            }
        case .appBskyEmbedRecordWithMediaView(let recordWithMediaView):
            switch recordWithMediaView.record.record {
            case .appBskyEmbedRecordViewRecord(let viewRecord):
                if viewRecord.author.did.didString() == did {
                    return viewRecord.uri
                }
            case .appBskyEmbedRecordViewDetached(let viewDetached):
                if viewDetached.uri.authority == did {
                    return viewDetached.uri
                }
            case .appBskyEmbedRecordViewNotFound, .appBskyEmbedRecordViewBlocked, .appBskyFeedDefsGeneratorView,
                 .appBskyGraphDefsListView, .appBskyLabelerDefsLabelerView, .appBskyGraphDefsStarterPackViewBasic,
                 .unexpected:
                break
            }
        case .appBskyEmbedImagesView, .appBskyEmbedExternalView, .appBskyEmbedVideoView, .appBskyEmbedGalleryView, .unexpected:
            break
        }
        return nil
    }

    /// Whether this post's quote of the signed-in user's post is currently detached.
    var isQuoteDetached: Bool {
        if let override = isQuoteDetachedOverride {
            return override
        }
        guard let embed = post.embed else { return false }
        switch embed {
        case .appBskyEmbedRecordView(let recordView):
            if case .appBskyEmbedRecordViewDetached = recordView.record {
                return true
            }
        case .appBskyEmbedRecordWithMediaView(let recordWithMediaView):
            if case .appBskyEmbedRecordViewDetached = recordWithMediaView.record.record {
                return true
            }
        default:
            break
        }
        return false
    }

    func detachQuote() async {
        guard let quotedURI = quotedPostURI else { return }
        do {
            try await appState.postManager.setQuoteDetached(
                quotedPostURI: quotedURI,
                quotePostURI: post.uri,
                detached: true
            )
            let rootURI = resolvedRootPostURI?.uriString() ?? post.uri.uriString()
            await appState.postShadowManager.updateShadow(forUri: post.uri.uriString()) { shadow in
                if case .appBskyEmbedRecordView = self.post.embed {
                    let detachedRecord = AppBskyEmbedRecord.ViewRecordUnion.appBskyEmbedRecordViewDetached(
                        AppBskyEmbedRecord.ViewDetached(uri: quotedURI, detached: true)
                    )
                    let newRecordView = AppBskyEmbedRecord.View(record: detachedRecord)
                    shadow.embed = .appBskyEmbedRecordView(newRecordView)
                } else if case .appBskyEmbedRecordWithMediaView(let rwmView) = self.post.embed {
                    let detachedRecord = AppBskyEmbedRecord.ViewRecordUnion.appBskyEmbedRecordViewDetached(
                        AppBskyEmbedRecord.ViewDetached(uri: quotedURI, detached: true)
                    )
                    let newRecordView = AppBskyEmbedRecord.View(record: detachedRecord)
                    let newRwmView = AppBskyEmbedRecordWithMedia.View(record: newRecordView, media: rwmView.media)
                    shadow.embed = .appBskyEmbedRecordWithMediaView(newRwmView)
                }
            }
            await MainActor.run {
                isQuoteDetachedOverride = true
                appState.toastManager.show(
                    ToastItem(
                        message: "Quote detached",
                        icon: "checkmark.circle.fill",
                        duration: 2.5
                    )
                )
                appState.stateInvalidationBus.notify(.threadUpdated(rootUri: rootURI))
                appState.stateInvalidationBus.notify(.feedUpdated(.timeline))
            }
        } catch {
            logger.error("Error detaching quote: \(error)")
            await MainActor.run {
                appState.toastManager.show(
                    ToastItem(
                        message: "Failed to detach quote",
                        icon: "exclamationmark.triangle.fill",
                        duration: 2.5
                    )
                )
            }
        }
    }

    func reattachQuote() async {
        guard let quotedURI = quotedPostURI else { return }
        do {
            try await appState.postManager.setQuoteDetached(
                quotedPostURI: quotedURI,
                quotePostURI: post.uri,
                detached: false
            )
            let rootURI = resolvedRootPostURI?.uriString() ?? post.uri.uriString()
            await appState.postShadowManager.updateShadow(forUri: post.uri.uriString()) { shadow in
                shadow.embed = self.post.embed
            }
            await MainActor.run {
                isQuoteDetachedOverride = false
                appState.toastManager.show(
                    ToastItem(
                        message: "Quote re-attached",
                        icon: "checkmark.circle.fill",
                        duration: 2.5
                    )
                )
                appState.stateInvalidationBus.notify(.threadUpdated(rootUri: rootURI))
                appState.stateInvalidationBus.notify(.feedUpdated(.timeline))
            }
        } catch {
            logger.error("Error reattaching quote: \(error)")
            await MainActor.run {
                appState.toastManager.show(
                    ToastItem(
                        message: "Failed to re-attach quote",
                        icon: "exclamationmark.triangle.fill",
                        duration: 2.5
                    )
                )
            }
        }
    }

    // MARK: - Threadgate Reply Moderation (G13)

    func hideReplyForEveryone() async {
        guard let rootURI = resolvedRootPostURI else { return }
        do {
            try await appState.postManager.setReplyHidden(
                rootPostURI: rootURI,
                replyURI: post.uri,
                hidden: true
            )
            await MainActor.run {
                isReplyHiddenByThreadgate = true
                appState.toastManager.show(
                    ToastItem(
                        message: "Reply hidden for everyone",
                        icon: "eye.slash",
                        duration: 2.5
                    )
                )
                appState.stateInvalidationBus.notify(.threadUpdated(rootUri: rootURI.uriString()))
                appState.stateInvalidationBus.notify(.feedUpdated(.timeline))
            }
        } catch {
            logger.error("Error hiding reply for everyone: \(error)")
            await MainActor.run {
                appState.toastManager.show(
                    ToastItem(
                        message: error.localizedDescription,
                        icon: "exclamationmark.triangle.fill",
                        duration: 2.5
                    )
                )
            }
        }
    }

    func unhideReplyForEveryone() async {
        guard let rootURI = resolvedRootPostURI else { return }
        do {
            try await appState.postManager.setReplyHidden(
                rootPostURI: rootURI,
                replyURI: post.uri,
                hidden: false
            )
            await MainActor.run {
                isReplyHiddenByThreadgate = false
                appState.toastManager.show(
                    ToastItem(
                        message: "Reply visible to everyone",
                        icon: "eye",
                        duration: 2.5
                    )
                )
                appState.stateInvalidationBus.notify(.threadUpdated(rootUri: rootURI.uriString()))
                appState.stateInvalidationBus.notify(.feedUpdated(.timeline))
            }
        } catch {
            logger.error("Error showing reply for everyone: \(error)")
            await MainActor.run {
                appState.toastManager.show(
                    ToastItem(
                        message: error.localizedDescription,
                        icon: "exclamationmark.triangle.fill",
                        duration: 2.5
                    )
                )
            }
        }
    }

    func addAuthorToList() {
        // Trigger the add to list callback
        onAddAuthorToList?()
    }
    
    func toggleBookmark() {
        // Trigger the bookmark callback
        onToggleBookmark?()
    }
    

    /// Send "show more like this" feedback
    func sendShowMore() {
        guard appState.feedFeedbackManager.isEnabled else { return }
        appState.feedFeedbackManager.sendShowMore(postURI: post.uri)
        logger.debug("Sent 'show more' feedback for post: \(self.post.uri.uriString())")
        
        // Show confirmation toast
        appState.toastManager.show(
            ToastItem(
                message: "Feedback sent",
                icon: "checkmark.circle.fill"
            )
        )
    }
    
    /// Send "show less like this" feedback
    func sendShowLess() {
        guard appState.feedFeedbackManager.isEnabled else { return }
        appState.feedFeedbackManager.sendShowLess(postURI: post.uri)
        logger.debug("Sent 'show less' feedback for post: \(self.post.uri.uriString())")
        
        // Show confirmation toast
        appState.toastManager.show(
            ToastItem(
                message: "Feedback sent",
                icon: "checkmark.circle.fill"
            )
        )
    }
    
    /// Whether feed feedback is available for the current feed
    var isFeedbackEnabled: Bool {
        appState.feedFeedbackManager.isEnabled
    }
    
    /// Creates a report subject for this post
    func createReportSubject() -> ComAtprotoModerationCreateReport.InputSubjectUnion {
        return .comAtprotoRepoStrongRef(
            ComAtprotoRepoStrongRef(uri: post.uri, cid: post.cid)
        )
    }
    
    /// Returns a description of the post for reporting purposes
    func getReportDescription() -> String {
        return "Post by @\(post.author.handle)"
    }
}

extension PostContextMenuViewModel {
    public static func forCircleItem(
        _ item: BlueCatbirdCircleDefs.FeedItem,
        appState: AppState,
        allowsThreadSummary: Bool = false
    ) -> PostContextMenuViewModel {
        PostContextMenuViewModel(
            appState: appState,
            post: item.post.post,
            allowsThreadSummary: allowsThreadSummary,
            visibilityContext: .circle(item.circle)
        )
    }

    public static func forCircle(
        post: AppBskyFeedDefs.PostView,
        circle: CircleSummary,
        appState: AppState,
        allowsThreadSummary: Bool = false
    ) -> PostContextMenuViewModel {
        PostContextMenuViewModel(
            appState: appState,
            post: post,
            allowsThreadSummary: allowsThreadSummary,
            visibilityContext: .circle(circle)
        )
    }
}

extension Notification.Name {
    static let threadUpdated = Notification.Name("ThreadUpdated")
    static let feedUpdated = Notification.Name("FeedUpdated")
}
