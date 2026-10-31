#if os(iOS)
import Foundation
import Petrel
import Testing
import UIKit
@testable import Catbird

/// A capped restore returns no cursor (the persisted one continues after the
/// last *persisted* post). Paginating from those rows with a nil cursor would
/// fetch page 1 and append the newest posts below older ones.
@Suite("Feed truncated restore pagination", .serialized)
@MainActor
struct FeedTruncatedRestoreTests {
  @Test("Rows restored without a cursor are flagged; a real cursor clears the flag")
  func restoredRowsWithoutCursorAreFlagged() async throws {
    let (appState, model) = await makeModel()
    defer { appState.cleanup() }

    await model.restorePersistedPosts(try Self.makePosts(count: 3), cursor: nil)
    #expect(model.restoredRowsLackCursor)
    #expect(model.cursor == nil)

    await model.setCachedFeed([], cursor: "fresh-head-cursor")
    #expect(!model.restoredRowsLackCursor)
  }

  @Test("Rows restored with their cursor paginate normally")
  func restoredRowsWithCursorAreNotFlagged() async throws {
    let (appState, model) = await makeModel()
    defer { appState.cleanup() }

    await model.restorePersistedPosts(try Self.makePosts(count: 3), cursor: "persisted-cursor")
    #expect(!model.restoredRowsLackCursor)
    #expect(model.cursor == "persisted-cursor")
    #expect(model.hasMore)
  }

  @Test("loadMore from cursorless restored rows reloads the head instead of appending page 1")
  func loadMoreReloadsHeadInsteadOfAppending() async throws {
    let (appState, model) = await makeModel()
    defer { appState.cleanup() }
    let restored = try Self.makePosts(count: 3)
    await model.restorePersistedPosts(restored, cursor: nil)

    await model.loadMore()

    // The fixture client cannot reach a server, so the head reload fails; what
    // matters is that loadMore took the head path, not the append path.
    #expect(model.loadMoreError == nil)
    #expect(model.posts.map(\.id) == restored.map(\.id))
    #expect(!model.isLoadingMore)
  }

  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal { .none }
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }

  private func makeModel() async -> (AppState, FeedModel) {
    let client = await ATProtoClient(baseURL: URL(string: "https://feed-truncated-restore.invalid")!)
    let appState = AppState(userDID: "did:plc:feedtruncatedrestore", client: client,
      regulatoryChecker: NoAgePrompt())
    let model = FeedModel(feedManager: FeedManager(client: nil, fetchType: .timeline), appState: appState)
    return (appState, model)
  }

  private static func makePosts(count: Int) throws -> [CachedFeedViewPost] {
    try (0..<count).map { index in
      let timestamp = ATProtocolDate(date: Date(timeIntervalSince1970: 1_700_000_000 - Double(index)))
      let author = AppBskyActorDefs.ProfileViewBasic(
        did: try DID(didString: "did:plc:truncatedrestoreauthor"),
        handle: try Handle(handleString: "truncated-restore.test"), displayName: "Restore fixture",
        pronouns: nil, avatar: nil, associated: nil, viewer: nil, labels: nil,
        createdAt: nil, verification: nil, status: nil, debug: nil)
      let record = AppBskyFeedPost(text: "restored post \(index)",
        entities: nil, facets: nil, reply: nil, embed: nil, langs: nil, labels: nil,
        tags: nil, createdAt: timestamp)
      let post = AppBskyFeedDefs.PostView(
        uri: try ATProtocolURI(uriString: "at://did:plc:truncatedrestoreauthor/app.bsky.feed.post/r\(index)"),
        cid: CID.fromDAGCBOR(Data("restored-\(index)".utf8)), author: author,
        record: .knownType(record), embed: nil, bookmarkCount: nil,
        replyCount: 0, repostCount: 0, likeCount: 0, quoteCount: nil,
        indexedAt: timestamp, viewer: nil, labels: nil, threadgate: nil, debug: nil)
      let feedPost = AppBskyFeedDefs.FeedViewPost(post: post, reply: nil, reason: nil,
        feedContext: nil, reqId: nil)
      return try #require(CachedFeedViewPost(from: feedPost, feedType: "timeline"))
    }
  }
}
#endif
