//
//  PostContextMenuViewModel.swift
//  Catbird
//
//  Created by Josh LaCalamito on 8/29/24.
//


import SwiftUI
import Petrel
import Observation


@Observable
final class PostContextMenuViewModel {
    let appState: AppState
    let post: AppBskyFeedDefs.PostView
    
    // Reporting callback - will be set by PostView
    var onReportPost: (() -> Void)? = nil

    init(appState: AppState, post: AppBskyFeedDefs.PostView) {
        self.appState = appState
        self.post = post
    }

    func deletePost() async {
        guard let did = appState.currentUserDID else { return }
        do {
            let input = ComAtprotoRepoDeleteRecord.Input(
                repo: try ATIdentifier(string:did),
                collection: try NSID(nsidString:"app.bsky.feed.post"),
                rkey: try RecordKey(keyString:post.uri.recordKey ?? "")
            )

            let responseCode = try await appState.atProtoClient?.com.atproto.repo.deleteRecord(input: input).responseCode
            if responseCode == 200 {
                print("Post deleted successfully")
            }
        } catch {
            print("Error deleting post: \(error)")
        }
    }

    func blockUser() async  {
        guard let did = appState.currentUserDID else { return }
        let block = AppBskyGraphBlock(subject: post.author.did, createdAt: ATProtocolDate(date: Date()))
        do {
            let input = ComAtprotoRepoCreateRecord.Input(
                repo: try ATIdentifier(string: did),
                collection: try NSID(nsidString: "app.bsky.graph.block"),
                record: ATProtocolValueContainer.knownType(block)
            )

            let result = try await appState.atProtoClient?.com.atproto.repo.createRecord(input: input)
            if let (responseCode, data) = result {
                if responseCode == 200 {
                    
                    print("User blocked successfully")
                }
            }
        } catch {
            print("Error blocking user: \(error)")
        }
    }

    func muteUser() async {
        do {
            let input = AppBskyGraphMuteActor.Input(actor: try ATIdentifier(string: post.author.did.didString()))

            let responseCode = try await appState.atProtoClient?.app.bsky.graph.muteActor(input: input)
            if responseCode == 200 {
                print("User muted successfully")
            }
        } catch {
            print("Error muting user: \(error)")
        }
    }

    func muteThread() async {
        let input = AppBskyGraphMuteThread.Input(root: post.uri)
        do {
            let responseCode = try await appState.atProtoClient?.app.bsky.graph.muteThread(input: input)
            if responseCode == 200 {
                print("Thread muted successfully")
            }
        } catch {
            print("Error muting thread: \(error)")
        }
    }

    func reportPost() {
        // Trigger the reporting callback
        onReportPost?()
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
