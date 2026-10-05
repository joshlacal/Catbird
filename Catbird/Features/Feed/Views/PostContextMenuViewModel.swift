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
                    let deletedURI = post.uri.uriString()
                    await MainActor.run {
                        NotificationCenter.default.post(name: .feedPostDeleted, object: deletedURI)
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
                } else {
                    logger.error("Deleting post returned status \(responseCode ?? -1)")
                    await showFailureToast("Couldn’t delete this post. Try again.")
                }
            } catch {
                logger.error("Error deleting post: \(error)")
                await showFailureToast(
                    UserFacingError.message(for: error, action: "delete this post")
                )
            }
        }
    }

    func blockUser() async {
        do {
            guard try await appState.graphManager.block(did: post.author.did.didString()) else {
                await showFailureToast("Couldn’t block this account. Try again.")
                return
            }
            appState.toastManager.show(ToastItem(message: "User blocked", icon: "hand.raised.fill", duration: 2.5))
        } catch {
            logger.error("Error blocking user: \(error)")
            await showFailureToast(
                UserFacingError.message(for: error, action: "block this account")
            )
        }
    }

    func muteUser() async {
        do {
            guard try await appState.graphManager.mute(did: post.author.did.didString()) else {
                await showFailureToast("Couldn’t mute this account. Try again.")
                return
            }
            appState.toastManager.show(ToastItem(message: "User muted", icon: "speaker.slash.fill", duration: 2.5))
        } catch {
            logger.error("Error muting user: \(error)")
            await showFailureToast(
                UserFacingError.message(for: error, action: "mute this account")
            )
        }
    }

    func muteThread() async {
        do {
            guard try await appState.graphManager.muteThread(threadRootUri: resolvedRootPostURI ?? post.uri) else {
                await showFailureToast("Couldn’t mute this thread. Try again.")
                return
            }
            appState.toastManager.show(ToastItem(message: "Thread muted", icon: "bell.slash.fill", duration: 2.5))
        } catch {
            logger.error("Error muting thread: \(error)")
            await showFailureToast(
                UserFacingError.message(for: error, action: "mute this thread")
            )
        }
    }

    /// Shows a failure toast; a `nil` message (a cancelled request) shows nothing.
    private func showFailureToast(_ message: String?) async {
        guard let message else { return }
        await MainActor.run {
            appState.toastManager.show(
                ToastItem(
                    message: message,
                    icon: "exclamationmark.triangle.fill",
                    duration: 3
                )
            )
        }
    }

    func hidePost() async {
        let postURI = post.uri.uriString()
        let saved = await appState.postHidingManager.hidePost(postURI)
        logger.debug("Post hidden: \(postURI), saved: \(saved)")
        
        // Show confirmation toast
        await MainActor.run {
            if saved {
                NotificationCenter.default.post(name: .feedPostVisibilityChanged, object: nil)
            }
            appState.toastManager.show(saved
                ? ToastItem(message: "Post hidden", icon: "checkmark.circle.fill")
                : ToastItem(message: "Couldn’t hide post. Try again.", icon: "exclamationmark.triangle.fill"))
        }
    }
    
    func unhidePost() async {
        let postURI = post.uri.uriString()
        let saved = await appState.postHidingManager.unhidePost(postURI)
        logger.debug("Post unhidden: \(postURI), saved: \(saved)")
        
        // Show confirmation toast
        await MainActor.run {
            if saved {
                NotificationCenter.default.post(name: .feedPostVisibilityChanged, object: nil)
            }
            appState.toastManager.show(saved
                ? ToastItem(message: "Post unhidden", icon: "checkmark.circle.fill")
                : ToastItem(message: "Couldn’t unhide post. Try again.", icon: "exclamationmark.triangle.fill"))
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
                        message: UserFacingError.message(for: error, action: "update your pinned post")
                            ?? "Couldn’t update your pinned post. Try again.",
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
                        message: "Couldn’t detach the quote. Try again.",
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
                        message: "Couldn’t re-attach the quote. Try again.",
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
                        message: UserFacingError.message(for: error, action: "hide this reply")
                            ?? "Couldn’t hide this reply. Try again.",
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
                        message: UserFacingError.message(for: error, action: "show this reply")
                            ?? "Couldn’t show this reply. Try again.",
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
    

    /// Send "show more like this" feedback to the feed the post is shown in
    @MainActor
    func sendShowMore(target: FeedInteractionTarget) {
        appState.feedFeedbackManager.sendShowMore(postURI: post.uri, target: target)
        logger.debug("Sent 'show more' feedback for post: \(self.post.uri.uriString())")
        
        // Show confirmation toast
        appState.toastManager.show(
            ToastItem(
                message: "Feedback sent",
                icon: "checkmark.circle.fill"
            )
        )
    }
    
    /// Send "show less like this" feedback to the feed the post is shown in
    @MainActor
    func sendShowLess(target: FeedInteractionTarget) {
        appState.feedFeedbackManager.sendShowLess(postURI: post.uri, target: target)
        logger.debug("Sent 'show less' feedback for post: \(self.post.uri.uriString())")
        
        // Show confirmation toast
        appState.toastManager.show(
            ToastItem(
                message: "Feedback sent",
                icon: "checkmark.circle.fill"
            )
        )
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

extension Notification.Name {
    static let threadUpdated = Notification.Name("ThreadUpdated")
    static let feedUpdated = Notification.Name("FeedUpdated")
}
