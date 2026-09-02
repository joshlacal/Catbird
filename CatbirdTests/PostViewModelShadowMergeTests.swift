import Foundation
import Petrel
import PetrelCatbird
import SwiftUI
import Testing
@testable import Catbird

@Suite("PostViewModelShadowMergeTests")
struct PostViewModelShadowMergeTests {
    @Test("Unrelated partial shadow retains server like and repost state")
    @MainActor
    func unrelatedPartialShadowRetainsServerLikeAndRepost() async throws {
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let appState = AppState(userDID: "did:plc:viewer", client: client)

        let post = PostViewModelTestFixtures.testPostWithLikeAndRepost
        let postUri = post.uri.uriString()

        // Seed an unrelated partial shadow (e.g., bookmark only) without like/repost decisions
        await appState.postShadowManager.updateShadow(forUri: postUri) { shadow in
            shadow.bookmarked = true
            shadow.pinned = true
        }

        let viewModel = PostViewModel(post: post, appState: appState)
        await viewModel.start(post: post)

        // Undecided like and repost must fall back to server viewer state
        #expect(viewModel.isLiked == true)
        #expect(viewModel.isReposted == true)
        #expect(viewModel.likeUri == post.viewer?.like)
        #expect(viewModel.repostUri == post.viewer?.repost)
        #expect(viewModel.isBookmarked == true)
        #expect(viewModel.likeCount == 12)
        #expect(viewModel.repostCount == 3)

        // mergeShadow must also fall back to server viewer state
        let merged = await appState.postShadowManager.mergeShadow(post: post)
        #expect(merged.viewer?.like == post.viewer?.like)
        #expect(merged.viewer?.repost == post.viewer?.repost)
        #expect(merged.viewer?.bookmarked == true)
        #expect(merged.viewer?.pinned == true)
        #expect(merged.likeCount == 12)
        #expect(merged.repostCount == 3)

        // When a fresher server payload arrives with updated counts, mergeShadow reflects them
        let freshPost = AppBskyFeedDefs.PostView(
            uri: post.uri,
            cid: post.cid,
            author: post.author,
            record: post.record,
            embed: post.embed,
            bookmarkCount: post.bookmarkCount,
            replyCount: post.replyCount,
            repostCount: 10,
            likeCount: 42,
            quoteCount: post.quoteCount,
            indexedAt: post.indexedAt,
            viewer: post.viewer,
            labels: post.labels,
            threadgate: post.threadgate,
            debug: nil
        )
        let freshMerged = await appState.postShadowManager.mergeShadow(post: freshPost)
        #expect(freshMerged.likeCount == 42)
        #expect(freshMerged.repostCount == 10)
    }

    @Test("Explicit optimistic unlike and unrepost overrides stale server state")
    @MainActor
    func explicitOptimisticUnlikeAndUnrepostOverridesStaleServerState() async throws {
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let appState = AppState(userDID: "did:plc:viewer", client: client)

        let post = PostViewModelTestFixtures.testPostWithLikeAndRepost
        let postUri = post.uri.uriString()

        // Optimistically unlike and unrepost via manager methods
        await appState.postShadowManager.setLiked(postUri: postUri, isLiked: false)
        await appState.postShadowManager.setReposted(postUri: postUri, isReposted: false)
        let viewModel = PostViewModel(post: post, appState: appState)
        await viewModel.start(post: post)

        // Explicit nil decision must override stale server post state
        #expect(viewModel.isLiked == false)
        #expect(viewModel.isReposted == false)
        #expect(viewModel.likeUri == nil)
        #expect(viewModel.repostUri == nil)
        #expect(viewModel.likeCount == 11)
        #expect(viewModel.repostCount == 2)

        // mergeShadow must also preserve explicit nil decision
        let merged = await appState.postShadowManager.mergeShadow(post: post)
        #expect(merged.viewer?.like == nil)
        #expect(merged.viewer?.repost == nil)
        #expect(merged.likeCount == 11)
        #expect(merged.repostCount == 2)
    }

    @Test("Decided and server agrees returns distinct fresh server counts for likes and reposts")
    @MainActor
    func decidedAndServerAgreesReturnsDistinctFreshServerCounts() async throws {
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let appState = AppState(userDID: "did:plc:viewer", client: client)
        let post = PostViewModelTestFixtures.testPostWithLikeAndRepost
        let postUri = post.uri.uriString()

        let likeUri = try ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.feed.like/like123")
        let repostUri = try ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.feed.repost/repost123")

        // Case 1: Positive like decision + server agrees (viewer.like == likeUri) -> yields fresh server count 43
        await appState.postShadowManager.updateShadow(forUri: postUri) { shadow in
            shadow.decideLike(likeUri)
        }
        var agreeingPost = AppBskyFeedDefs.PostView(
            uri: post.uri,
            cid: post.cid,
            author: post.author,
            record: post.record,
            embed: post.embed,
            bookmarkCount: post.bookmarkCount,
            replyCount: post.replyCount,
            repostCount: 3,
            likeCount: 43,
            quoteCount: post.quoteCount,
            indexedAt: post.indexedAt,
            viewer: AppBskyFeedDefs.ViewerState(
                repost: nil,
                like: likeUri,
                bookmarked: nil,
                threadMuted: nil,
                replyDisabled: nil,
                embeddingDisabled: nil,
                pinned: nil,
                knownLikers: nil
            ),
            labels: nil,
            threadgate: nil,
            debug: nil
        )
        var merged = await appState.postShadowManager.mergeShadow(post: agreeingPost)
        #expect(merged.viewer?.like == likeUri)
        #expect(merged.likeCount == 43)

        // Case 2: Negative like decision + server agrees (viewer.like == nil) -> yields fresh server count 40
        await appState.postShadowManager.updateShadow(forUri: postUri) { shadow in
            shadow.decideLike(nil)
        }
        agreeingPost = AppBskyFeedDefs.PostView(
            uri: post.uri,
            cid: post.cid,
            author: post.author,
            record: post.record,
            embed: post.embed,
            bookmarkCount: post.bookmarkCount,
            replyCount: post.replyCount,
            repostCount: 3,
            likeCount: 40,
            quoteCount: post.quoteCount,
            indexedAt: post.indexedAt,
            viewer: AppBskyFeedDefs.ViewerState(
                repost: nil,
                like: nil,
                bookmarked: nil,
                threadMuted: nil,
                replyDisabled: nil,
                embeddingDisabled: nil,
                pinned: nil,
                knownLikers: nil
            ),
            labels: nil,
            threadgate: nil,
            debug: nil
        )
        merged = await appState.postShadowManager.mergeShadow(post: agreeingPost)
        #expect(merged.viewer?.like == nil)
        #expect(merged.likeCount == 40)

        // Case 3: Positive repost decision + server agrees (viewer.repost == repostUri) -> yields fresh server count 22
        await appState.postShadowManager.updateShadow(forUri: postUri) { shadow in
            shadow.decideRepost(repostUri)
        }
        agreeingPost = AppBskyFeedDefs.PostView(
            uri: post.uri,
            cid: post.cid,
            author: post.author,
            record: post.record,
            embed: post.embed,
            bookmarkCount: post.bookmarkCount,
            replyCount: post.replyCount,
            repostCount: 22,
            likeCount: 12,
            quoteCount: post.quoteCount,
            indexedAt: post.indexedAt,
            viewer: AppBskyFeedDefs.ViewerState(
                repost: repostUri,
                like: nil,
                bookmarked: nil,
                threadMuted: nil,
                replyDisabled: nil,
                embeddingDisabled: nil,
                pinned: nil,
                knownLikers: nil
            ),
            labels: nil,
            threadgate: nil,
            debug: nil
        )
        merged = await appState.postShadowManager.mergeShadow(post: agreeingPost)
        #expect(merged.viewer?.repost == repostUri)
        #expect(merged.repostCount == 22)

        // Case 4: Negative repost decision + server agrees (viewer.repost == nil) -> yields fresh server count 15
        await appState.postShadowManager.updateShadow(forUri: postUri) { shadow in
            shadow.decideRepost(nil)
        }
        agreeingPost = AppBskyFeedDefs.PostView(
            uri: post.uri,
            cid: post.cid,
            author: post.author,
            record: post.record,
            embed: post.embed,
            bookmarkCount: post.bookmarkCount,
            replyCount: post.replyCount,
            repostCount: 15,
            likeCount: 12,
            quoteCount: post.quoteCount,
            indexedAt: post.indexedAt,
            viewer: AppBskyFeedDefs.ViewerState(
                repost: nil,
                like: nil,
                bookmarked: nil,
                threadMuted: nil,
                replyDisabled: nil,
                embeddingDisabled: nil,
                pinned: nil,
                knownLikers: nil
            ),
            labels: nil,
            threadgate: nil,
            debug: nil
        )
        merged = await appState.postShadowManager.mergeShadow(post: agreeingPost)
        #expect(merged.viewer?.repost == nil)
        #expect(merged.repostCount == 15)
    }
}
