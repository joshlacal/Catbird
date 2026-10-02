import Foundation
import Petrel
import PetrelCatbird
import SwiftUI
import Testing
@testable import Catbird

@Suite("PostViewModelLifecycleTests")
struct PostViewModelLifecycleTests {
    @Test("PostViewModel synchronously initializes viewer state without async tasks in init")
    @MainActor
    func postViewModelSynchronousInitialization() async throws {
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let appState = AppState(userDID: "did:plc:viewer", client: client)

        let post = PostViewModelTestFixtures.testPost
        let postUri = post.uri.uriString()

        // Seed a conflicting shadow before constructing PostViewModel
        let repostUri = try ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.feed.repost/repost999")
        await appState.postShadowManager.updateShadow(forUri: postUri) { shadow in
            shadow.decideRepost(repostUri)
        }
        let viewModel = PostViewModel(post: post, appState: appState)

        // Yield to allow any putative async tasks spawned in init to run
        await Task.yield()

        // Verify synchronous state is populated from server post without consuming shadow
        #expect(viewModel.isLiked == true)
        #expect(viewModel.isReposted == false)
        #expect(viewModel.isBookmarked == true)
        #expect(viewModel.likeCount == 12)
        #expect(viewModel.repostCount == 3)
        #expect(viewModel.replyCount == 5)

        // Verify shadow manager was not mutated/overwritten by init
        let shadow = await appState.postShadowManager.getShadow(forUri: postUri)
        #expect(shadow?.repostUri == repostUri)
    }

    @Test("PostViewModel.start reconciles with postShadowManager deterministically")
    @MainActor
    func postViewModelStartReconcilesShadow() async throws {
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let appState = AppState(userDID: "did:plc:viewer", client: client)

        let post = PostViewModelTestFixtures.testPost
        let postUri = post.uri.uriString()

        // Seed a shadow update in PostShadowManager before start
        let repostUri = try ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.feed.repost/repost456")
        await appState.postShadowManager.updateShadow(forUri: postUri) { shadow in
            shadow.decideRepost(repostUri)
        }
        let viewModel = PostViewModel(post: post, appState: appState)
        // Before start, reposted is false as in server post
        #expect(viewModel.isReposted == false)

        // Run deterministic async start
        await viewModel.start(post: post)

        // Shadow reconciliation must be reflected immediately without calling checkInteractionState()
        #expect(viewModel.isReposted == true)
        #expect(viewModel.repostCount == 4)
    }

    @Test("PostViewModel.start respects Task cancellation")
    @MainActor
    func postViewModelStartRespectsCancellation() async throws {
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let appState = AppState(userDID: "did:plc:viewer", client: client)

        let post = PostViewModelTestFixtures.testPost
        let postUri = post.uri.uriString()

        // Seed a shadow update in PostShadowManager before start
        let repostUri = try ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.feed.repost/repost456")
        await appState.postShadowManager.updateShadow(forUri: postUri) { shadow in
            shadow.decideRepost(repostUri)
        }
        let viewModel = PostViewModel(post: post, appState: appState)

        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await viewModel.start(post: post)
        }
        await task.value

        // Pre-cancelled start must not reconcile shadow or mutate state
        #expect(viewModel.isReposted == false)
    }

    @Test("PostViewModel.start preserves cleared URI and derives decremented counts from payload")
    @MainActor
    func postViewModelStartPreservesClearedShadow() async throws {
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let appState = AppState(userDID: "did:plc:viewer", client: client)

        let post = PostViewModelTestFixtures.testPostWithLikeAndRepost
        let postUri = post.uri.uriString()

        // Seed an existing shadow representing an optimistic unlike and unrepost
        await appState.postShadowManager.updateShadow(forUri: postUri) { shadow in
            shadow.decideLike(nil)
            shadow.decideRepost(nil)
        }

        let viewModel = PostViewModel(post: post, appState: appState)

        // Before start, synchronous state reflects the server post
        #expect(viewModel.isLiked == true)
        #expect(viewModel.isReposted == true)
        #expect(viewModel.likeCount == 12)
        #expect(viewModel.repostCount == 3)
        #expect(viewModel.likeUri != nil)
        #expect(viewModel.repostUri != nil)

        // Run deterministic async start
        await viewModel.start(post: post)

        // Verify existing shadow was not overwritten by server state
        let shadow = await appState.postShadowManager.getShadow(forUri: postUri)
        #expect(shadow?.likeUri == nil)
        #expect(shadow?.repostUri == nil)
        #expect(shadow?.likeDecided == true)
        #expect(shadow?.repostDecided == true)

        // Verify view model reconciled with authoritative shadow (derived 12-1 and 3-1)
        #expect(viewModel.isLiked == false)
        #expect(viewModel.isReposted == false)
        #expect(viewModel.likeUri == nil)
        #expect(viewModel.repostUri == nil)
        #expect(viewModel.likeCount == 11)
        #expect(viewModel.repostCount == 2)
    }

    @Test("PostViewModel.start seeds server interaction URIs and counts when no shadow exists")
    @MainActor
    func postViewModelStartSeedsShadowWhenAbsent() async throws {
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let appState = AppState(userDID: "did:plc:viewer", client: client)

        let post = PostViewModelTestFixtures.testPostWithLikeAndRepost
        let postUri = post.uri.uriString()

        // Ensure no shadow exists initially
        let initialShadow = await appState.postShadowManager.getShadow(forUri: postUri)
        #expect(initialShadow == nil)

        let viewModel = PostViewModel(post: post, appState: appState)
        await viewModel.start(post: post)

        // Shadow should be seeded with server interactions
        let shadow = await appState.postShadowManager.getShadow(forUri: postUri)
        #expect(shadow?.likeUri == post.viewer?.like)
        #expect(shadow?.repostUri == post.viewer?.repost)
        #expect(shadow?.likeDecided == false)
        #expect(shadow?.repostDecided == false)
        #expect(viewModel.isLiked == true)
        #expect(viewModel.isReposted == true)
        #expect(viewModel.likeCount == 12)
        #expect(viewModel.repostCount == 3)
    }
}

enum PostViewModelTestFixtures {
    static var testPost: AppBskyFeedDefs.PostView {
        let author = AppBskyActorDefs.ProfileViewBasic(
            did: try! DID(didString: "did:plc:testauthor"),
            handle: try! Handle(handleString: "testauthor.bsky.social"),
            displayName: "Test Author",
            pronouns: nil,
            avatar: nil,
            associated: nil,
            viewer: nil,
            labels: nil,
            createdAt: nil,
            verification: nil,
            status: nil,
            debug: nil
        )
        let post = AppBskyFeedPost(
            text: "Hello lifecycle test",
            entities: nil,
            facets: nil,
            reply: nil,
            embed: nil,
            langs: [],
            labels: nil,
            tags: nil,
            createdAt: ATProtocolDate(date: Date())
        )
        let viewer = AppBskyFeedDefs.ViewerState(
            repost: nil,
            like: try? ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.feed.like/like123"),
            bookmarked: true,
            threadMuted: nil,
            replyDisabled: nil,
            embeddingDisabled: nil,
            pinned: nil,
            knownLikers: nil
        )
        return AppBskyFeedDefs.PostView(
            uri: try! ATProtocolURI(uriString: "at://did:plc:testauthor/app.bsky.feed.post/post123"),
            cid: CID.fromDAGCBOR(Data("test-lifecycle-post".utf8)),
            author: author,
            record: ATProtocolValueContainer.knownType(post),
            embed: nil,
            bookmarkCount: nil,
            replyCount: 5,
            repostCount: 3,
            likeCount: 12,
            quoteCount: 1,
            indexedAt: ATProtocolDate(date: Date()),
            viewer: viewer,
            labels: nil,
            threadgate: nil,
            debug: nil
        )
    }

    static var testPostWithLikeAndRepost: AppBskyFeedDefs.PostView {
        let author = AppBskyActorDefs.ProfileViewBasic(
            did: try! DID(didString: "did:plc:testauthor"),
            handle: try! Handle(handleString: "testauthor.bsky.social"),
            displayName: "Test Author",
            pronouns: nil,
            avatar: nil,
            associated: nil,
            viewer: nil,
            labels: nil,
            createdAt: nil,
            verification: nil,
            status: nil,
            debug: nil
        )
        let post = AppBskyFeedPost(
            text: "Hello lifecycle test with like and repost",
            entities: nil,
            facets: nil,
            reply: nil,
            embed: nil,
            langs: [],
            labels: nil,
            tags: nil,
            createdAt: ATProtocolDate(date: Date())
        )
        let viewer = AppBskyFeedDefs.ViewerState(
            repost: try? ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.feed.repost/repost123"),
            like: try? ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.feed.like/like123"),
            bookmarked: true,
            threadMuted: nil,
            replyDisabled: nil,
            embeddingDisabled: nil,
            pinned: nil,
            knownLikers: nil
        )
        return AppBskyFeedDefs.PostView(
            uri: try! ATProtocolURI(uriString: "at://did:plc:testauthor/app.bsky.feed.post/post123"),
            cid: CID.fromDAGCBOR(Data("test-lifecycle-post-like-repost".utf8)),
            author: author,
            record: ATProtocolValueContainer.knownType(post),
            embed: nil,
            bookmarkCount: nil,
            replyCount: 5,
            repostCount: 3,
            likeCount: 12,
            quoteCount: 1,
            indexedAt: ATProtocolDate(date: Date()),
            viewer: viewer,
            labels: nil,
            threadgate: nil,
            debug: nil
        )
    }
}
