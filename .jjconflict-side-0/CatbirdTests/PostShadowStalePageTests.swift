import Foundation
import Petrel
import PetrelCatbird
import Testing
@testable import Catbird

/// Regression coverage for the feed → thread → back flow: a thread fetch that
/// retires a like decision must not let the feed's older page (fetched before
/// the like was indexed) revert the post to unliked.
@Suite("PostShadowStalePageTests")
struct PostShadowStalePageTests {
  private static let serverLike = try! ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.feed.like/real1")

  @Test("Stale feed page after thread catch-up keeps the like")
  @MainActor
  func staleFeedPageAfterThreadCatchUpKeepsLike() async throws {
    let appState = AppState(userDID: "did:plc:viewer", client: await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL))
    let base = PostViewModelTestFixtures.testPost
    let uri = base.uri.uriString()
    let staleFeedPost = Self.post(base, like: nil, likeCount: 12)
    let freshThreadPost = Self.post(base, like: Self.serverLike, likeCount: 13)

    // 1. Like in the feed.
    await appState.postShadowManager.updateShadow(forUri: uri) { $0.decideLike(Self.serverLike) }

    // 2. Thread view hydrates with fresh data, retiring the decision.
    await PostViewModel(post: freshThreadPost, appState: appState).start(post: freshThreadPost)
    #expect(await appState.postShadowManager.getShadow(forUri: uri)?.likeDecided == false)

    // 3. Back in the feed, the cell re-runs start() with its stale payload.
    let feedViewModel = PostViewModel(post: staleFeedPost, appState: appState)
    await feedViewModel.start(post: staleFeedPost)

    #expect(feedViewModel.isLiked)
    #expect(feedViewModel.likeCount == 13)
    let merged = await appState.postShadowManager.mergeShadow(post: staleFeedPost)
    #expect(merged.viewer?.like == Self.serverLike)
    #expect(merged.likeCount == 13)
    #expect(await appState.postShadowManager.getShadow(forUri: uri)?.likeUri == Self.serverLike)
  }

  @Test("Non-authoritative hydration cannot clear a held like; authoritative can")
  func authoritativeHydrationControlsClearing() {
    var shadow = PostShadow()
    shadow.hydrateFromServer(likeUri: Self.serverLike, repostUri: nil, authoritative: true)

    // Restored or cached page that predates the like.
    shadow.hydrateFromServer(likeUri: nil, repostUri: nil, authoritative: false)
    #expect(shadow.likeUri == Self.serverLike)

    // Fresh network page reporting an unlike made on another device.
    shadow.hydrateFromServer(likeUri: nil, repostUri: nil, authoritative: true)
    #expect(shadow.likeUri == nil)
  }

  private static func post(
    _ base: AppBskyFeedDefs.PostView,
    like: ATProtocolURI?,
    likeCount: Int
  ) -> AppBskyFeedDefs.PostView {
    let viewer = AppBskyFeedDefs.ViewerState(
      repost: nil,
      like: like,
      bookmarked: base.viewer?.bookmarked,
      threadMuted: nil,
      replyDisabled: nil,
      embeddingDisabled: nil,
      pinned: nil,
      knownLikers: nil
    )
    return AppBskyFeedDefs.PostView(
      uri: base.uri,
      cid: base.cid,
      author: base.author,
      record: base.record,
      embed: base.embed,
      bookmarkCount: base.bookmarkCount,
      replyCount: base.replyCount,
      repostCount: base.repostCount,
      likeCount: likeCount,
      quoteCount: base.quoteCount,
      indexedAt: base.indexedAt,
      viewer: viewer,
      labels: base.labels,
      threadgate: base.threadgate,
      debug: nil
    )
  }
}
