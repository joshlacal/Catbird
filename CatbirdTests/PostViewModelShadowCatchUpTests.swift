import Foundation
import Petrel
import PetrelCatbird
import SwiftUI
import Testing
@testable import Catbird

@Suite("PostViewModelShadowCatchUpTests")
struct PostViewModelShadowCatchUpTests {
    @Test("Server catch-up retires optimistic decision, and later server changes win")
    @MainActor
    func serverCatchUpRetiresDecisionAndCountAndLaterServerChangesWin() async throws {
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let appState = AppState(userDID: "did:plc:viewer", client: client)

        let post = PostViewModelTestFixtures.testPostWithLikeAndRepost
        let postUri = post.uri.uriString()

        // 1. User unlikes optimistically (server still has like with 12 likes)
        await appState.postShadowManager.setLiked(postUri: postUri, isLiked: false)

        let initialShadow = await appState.postShadowManager.getShadow(forUri: postUri)
        #expect(initialShadow?.likeDecided == true)
        #expect(initialShadow?.likeUri == nil)

        // Disagreement branch: mergeShadow preserves optimistic unliked state (12 - 1 = 11)
        let disagreeMerged = await appState.postShadowManager.mergeShadow(post: post)
        #expect(disagreeMerged.viewer?.like == nil)
        #expect(disagreeMerged.likeCount == 11)

        // 2. Server catches up: server payload reports like == nil, likeCount = 40
        let caughtUpViewer = AppBskyFeedDefs.ViewerState(
            repost: post.viewer?.repost,
            like: nil,
            bookmarked: post.viewer?.bookmarked,
            threadMuted: nil,
            replyDisabled: nil,
            embeddingDisabled: nil,
            pinned: nil,
            knownLikers: nil
        )
        let caughtUpPost = AppBskyFeedDefs.PostView(
            uri: post.uri,
            cid: post.cid,
            author: post.author,
            record: post.record,
            embed: post.embed,
            bookmarkCount: post.bookmarkCount,
            replyCount: post.replyCount,
            repostCount: post.repostCount,
            likeCount: 40,
            quoteCount: post.quoteCount,
            indexedAt: post.indexedAt,
            viewer: caughtUpViewer,
            labels: post.labels,
            threadgate: post.threadgate,
            debug: nil
        )

        // Before start() retires the shadow, mergeShadow on an agreeing payload must yield the server count (40)
        let agreeMerged = await appState.postShadowManager.mergeShadow(post: caughtUpPost)
        #expect(agreeMerged.likeCount == 40)
        #expect(agreeMerged.viewer?.like == nil)

        // Hydrate from caught-up server state
        let vm = PostViewModel(post: caughtUpPost, appState: appState)
        await vm.start(post: caughtUpPost)

        // Shadow decision must be retired
        let retiredShadow = await appState.postShadowManager.getShadow(forUri: postUri)
        #expect(retiredShadow?.likeDecided == false)
        #expect(retiredShadow?.likeUri == nil)

        // 3. Later server changes win (count increases on server while still unliked)
        let laterPost = AppBskyFeedDefs.PostView(
            uri: post.uri,
            cid: post.cid,
            author: post.author,
            record: post.record,
            embed: post.embed,
            bookmarkCount: post.bookmarkCount,
            replyCount: post.replyCount,
            repostCount: post.repostCount,
            likeCount: 45,
            quoteCount: post.quoteCount,
            indexedAt: post.indexedAt,
            viewer: caughtUpViewer,
            labels: post.labels,
            threadgate: post.threadgate,
            debug: nil
        )
        let laterMerged = await appState.postShadowManager.mergeShadow(post: laterPost)
        #expect(laterMerged.viewer?.like == nil)
        #expect(laterMerged.likeCount == 45)

        // 4. Post re-liked on another device: fresh server like URI and count win
        let crossDeviceLikeUri = try ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.feed.like/crossDevice999")
        let crossDeviceViewer = AppBskyFeedDefs.ViewerState(
            repost: post.viewer?.repost,
            like: crossDeviceLikeUri,
            bookmarked: post.viewer?.bookmarked,
            threadMuted: nil,
            replyDisabled: nil,
            embeddingDisabled: nil,
            pinned: nil,
            knownLikers: nil
        )
        let crossDevicePost = AppBskyFeedDefs.PostView(
            uri: post.uri,
            cid: post.cid,
            author: post.author,
            record: post.record,
            embed: post.embed,
            bookmarkCount: post.bookmarkCount,
            replyCount: post.replyCount,
            repostCount: post.repostCount,
            likeCount: 46,
            quoteCount: post.quoteCount,
            indexedAt: post.indexedAt,
            viewer: crossDeviceViewer,
            labels: post.labels,
            threadgate: post.threadgate,
            debug: nil
        )
        let crossDeviceVm = PostViewModel(post: crossDevicePost, appState: appState)
        await crossDeviceVm.start(post: crossDevicePost)

        #expect(crossDeviceVm.isLiked == true)
        #expect(crossDeviceVm.likeUri == crossDeviceLikeUri)
        #expect(crossDeviceVm.likeCount == 46)

        let crossDeviceMerged = await appState.postShadowManager.mergeShadow(post: crossDevicePost)
        #expect(crossDeviceMerged.viewer?.like == crossDeviceLikeUri)
        #expect(crossDeviceMerged.likeCount == 46)
    }

    @Test("Optimistic merge applied twice stays ±1 not ±2 (double-merge idempotence)")
    @MainActor
    func optimisticMergeDoubleMergeIsIdempotent() async throws {
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let appState = AppState(userDID: "did:plc:viewer", client: client)
        let post = PostViewModelTestFixtures.testPost
        let postUri = post.uri.uriString()

        // 1. Optimistic Like: server like == nil, count 42
        let unlikedPost = AppBskyFeedDefs.PostView(
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
        await appState.postShadowManager.setLiked(postUri: postUri, isLiked: true)
        let firstLikeMerge = await appState.postShadowManager.mergeShadow(post: unlikedPost)
        #expect(firstLikeMerge.likeCount == 43)
        #expect(firstLikeMerge.viewer?.like != nil)

        // Re-merging the already-merged post view must stay 43, NOT 44
        let secondLikeMerge = await appState.postShadowManager.mergeShadow(post: firstLikeMerge)
        #expect(secondLikeMerge.likeCount == 43)
        #expect(secondLikeMerge.viewer?.like != nil)

        // 2. Optimistic Unlike: server like != nil, count 42
        let likedServerUri = try ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.feed.like/serverLike")
        let likedPost = AppBskyFeedDefs.PostView(
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
            viewer: AppBskyFeedDefs.ViewerState(
                repost: nil,
                like: likedServerUri,
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
        await appState.postShadowManager.setLiked(postUri: postUri, isLiked: false)
        let firstUnlikeMerge = await appState.postShadowManager.mergeShadow(post: likedPost)
        #expect(firstUnlikeMerge.likeCount == 41)
        #expect(firstUnlikeMerge.viewer?.like == nil)

        // Re-merging the already-merged post view must stay 41, NOT 40
        let secondUnlikeMerge = await appState.postShadowManager.mergeShadow(post: firstUnlikeMerge)
        #expect(secondUnlikeMerge.likeCount == 41)
        #expect(secondUnlikeMerge.viewer?.like == nil)

        // 3. Optimistic Repost: server repost == nil, count 10
        await appState.postShadowManager.setReposted(postUri: postUri, isReposted: true)
        let firstRepostMerge = await appState.postShadowManager.mergeShadow(post: unlikedPost)
        #expect(firstRepostMerge.repostCount == 11)
        #expect(firstRepostMerge.viewer?.repost != nil)

        // Re-merging must stay 11, NOT 12
        let secondRepostMerge = await appState.postShadowManager.mergeShadow(post: firstRepostMerge)
        #expect(secondRepostMerge.repostCount == 11)
        #expect(secondRepostMerge.viewer?.repost != nil)

        // 4. Optimistic Unrepost: server repost != nil, count 10
        let repostServerUri = try ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.feed.repost/serverRepost")
        let repostedPost = AppBskyFeedDefs.PostView(
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
            viewer: AppBskyFeedDefs.ViewerState(
                repost: repostServerUri,
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
        await appState.postShadowManager.setReposted(postUri: postUri, isReposted: false)
        let firstUnrepostMerge = await appState.postShadowManager.mergeShadow(post: repostedPost)
        #expect(firstUnrepostMerge.repostCount == 9)
        #expect(firstUnrepostMerge.viewer?.repost == nil)

        // Re-merging must stay 9, NOT 8
        let secondUnrepostMerge = await appState.postShadowManager.mergeShadow(post: firstUnrepostMerge)
        #expect(secondUnrepostMerge.repostCount == 9)
        #expect(secondUnrepostMerge.viewer?.repost == nil)

        // 5. Non-negativity: unlike on 0 count never goes negative
        let zeroCountPost = AppBskyFeedDefs.PostView(
            uri: post.uri,
            cid: post.cid,
            author: post.author,
            record: post.record,
            embed: post.embed,
            bookmarkCount: post.bookmarkCount,
            replyCount: 0,
            repostCount: 0,
            likeCount: 0,
            quoteCount: 0,
            indexedAt: post.indexedAt,
            viewer: AppBskyFeedDefs.ViewerState(
                repost: repostServerUri,
                like: likedServerUri,
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
        let zeroMerged = await appState.postShadowManager.mergeShadow(post: zeroCountPost)
        #expect(zeroMerged.likeCount == 0)
        #expect(zeroMerged.repostCount == 0)
    }

    @Test("PostShadowManager setLiked(false) and setReposted(false) create explicit nil decisions")
    @MainActor
    func postShadowManagerSetLikedAndSetRepostedCreateExplicitDecisions() async throws {
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let appState = AppState(userDID: "did:plc:viewer", client: client)
        let uri1 = "at://did:plc:viewer/app.bsky.feed.post/postExplicit1"
        let uri2 = "at://did:plc:viewer/app.bsky.feed.post/postExplicit2"

        // setLiked(false) on empty shadow
        await appState.postShadowManager.setLiked(postUri: uri1, isLiked: false)
        let shadow1 = await appState.postShadowManager.getShadow(forUri: uri1)
        #expect(shadow1?.likeDecided == true)
        #expect(shadow1?.likeUri == nil)

        // setReposted(false) on empty shadow
        await appState.postShadowManager.setReposted(postUri: uri1, isReposted: false)
        let shadow1Updated = await appState.postShadowManager.getShadow(forUri: uri1)
        #expect(shadow1Updated?.repostDecided == true)
        #expect(shadow1Updated?.repostUri == nil)

        // setLiked(true) creates non-nil placeholder URI
        await appState.postShadowManager.setLiked(postUri: uri2, isLiked: true)
        let shadow2 = await appState.postShadowManager.getShadow(forUri: uri2)
        #expect(shadow2?.likeDecided == true)
        #expect(shadow2?.likeUri != nil)

        // setReposted(true) creates non-nil placeholder URI
        await appState.postShadowManager.setReposted(postUri: uri2, isReposted: true)
        let shadow2Updated = await appState.postShadowManager.getShadow(forUri: uri2)
        #expect(shadow2Updated?.repostDecided == true)
        #expect(shadow2Updated?.repostUri != nil)
    }

    @Test("PostShadow hydration reconciles correctly and preserves decisions against stale pages")
    @MainActor
    func postShadowHydrationReconciliation() async throws {
        let serverLikeUri = try ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.feed.like/serverLike1")
        let serverRepostUri = try ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.feed.repost/serverRepost1")

        // (a) Decided shadow with likeUri == nil survives a page whose payload still carries viewer.like (no clobber)
        var shadowA = PostShadow()
        shadowA.decideLike(nil)
        shadowA.hydrateFromServer(likeUri: serverLikeUri, repostUri: nil)
        #expect(shadowA.likeDecided == true)
        #expect(shadowA.likeUri == nil)

        // (b) Undecided bookmark-only shadow is hydrated with the server like/repost URI and stays likeDecided == false
        var shadowB = PostShadow(bookmarked: true)
        shadowB.hydrateFromServer(likeUri: serverLikeUri, repostUri: serverRepostUri)
        #expect(shadowB.likeDecided == false)
        #expect(shadowB.likeUri == serverLikeUri)
        #expect(shadowB.repostDecided == false)
        #expect(shadowB.repostUri == serverRepostUri)
        #expect(shadowB.bookmarked == true)

        // (c) Decided shadow whose state matches page payload is retired
        var shadowC = PostShadow()
        shadowC.decideLike(serverLikeUri)
        shadowC.hydrateFromServer(likeUri: serverLikeUri, repostUri: nil)
        #expect(shadowC.likeDecided == false)
        #expect(shadowC.likeUri == serverLikeUri)

        // (d) Cross-device URI replacement: local like URI X, server reports URI Y (both liked) -> retired, adopts Y
        let localPlaceholderUri = try ATProtocolURI(uriString: "at://did:plc:placeholder/app.bsky.feed.like/local123")
        var shadowD = PostShadow()
        shadowD.decideLike(localPlaceholderUri)
        shadowD.hydrateFromServer(likeUri: serverLikeUri, repostUri: nil)
        #expect(shadowD.likeDecided == false)
        #expect(shadowD.likeUri == serverLikeUri)
    }
}
