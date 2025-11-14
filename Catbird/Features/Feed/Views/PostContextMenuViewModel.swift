//
//  PostContextMenuViewModel.swift
//  Catbird
//
//  Created by Josh LaCalamito on 8/29/24.
//

import SwiftUI
import Petrel
import Observation
import OSLog

@Observable
final class PostContextMenuViewModel {
    let appState: AppState
    let post: AppBskyFeedDefs.PostView
    
    private let logger = Logger(subsystem: "blue.catbird", category: "PostContextMenu")
    
    // Reporting callback - will be set by PostView
    var onReportPost: (() -> Void)?
    
    // Add to list callback - will be set by PostView
    var onAddAuthorToList: (() -> Void)?
    
    // Bookmark callback - will be set by PostView
    var onToggleBookmark: (() -> Void)?
    

    // Thread summarization callback - wired by PostView when supported
    var onSummarizeThread: (() -> Void)?

    init(appState: AppState, post: AppBskyFeedDefs.PostView) {
        self.appState = appState
        self.post = post
    }

    func deletePost() async {
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
            }
        } catch {
            logger.debug("Error deleting post: \(error)")
        }
    }

    func blockUser() async {
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
            }
        } catch {
            logger.debug("Error muting user: \(error)")
        }
    }

    func muteThread() async {
        let input = AppBskyGraphMuteThread.Input(root: post.uri)
        do {
            let responseCode = try await appState.atProtoClient?.app.bsky.graph.muteThread(input: input)
            if responseCode == 200 {
                logger.debug("Thread muted successfully")
                
                // Also mute the thread in push notifications
                let threadRootURI: String
                if case let .knownType(replyRecord) = post.record,
                   let reply = replyRecord as? AppBskyFeedPost,
                   let replyRef = reply.reply {
                    let rootURI = replyRef.root.uri
                    threadRootURI = rootURI.uriString()
                } else {
                    // This is the thread root
                    threadRootURI = post.uri.uriString()
                }
                
                Task {
                    do {
                        try await appState.notificationManager.muteThreadNotifications(threadRootURI: threadRootURI)
                        logger.debug("Thread also muted for push notifications")
                    } catch {
                        logger.error("Failed to mute thread for push notifications: \(error.localizedDescription)")
                    }
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

    func reportPost() {
        // Trigger the reporting callback
        onReportPost?()
    }
    
    func addAuthorToList() {
        // Trigger the add to list callback
        onAddAuthorToList?()
    }
    
    func toggleBookmark() {
        // Trigger the bookmark callback
        onToggleBookmark?()
    }
    

    func summarizeThread() {
        onSummarizeThread?()
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
