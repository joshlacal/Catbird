#if os(iOS)
import Foundation
import Petrel
import Testing
@testable import Catbird

@MainActor
@Suite("Feed snapshot updates", .serialized)
struct FeedSnapshotUpdateTests {
  @Test("Same-ID server counters refresh without changing the post text")
  func sameTextRefreshesDecodedPost() throws {
    let old = try makePost(likeCount: 1, displayName: "Before")
    let model = FeedPostViewModel(post: old)
    #expect(model.displayText == "Feed fixture")
    #expect(model.likeCount == 1)
    #expect(model.authorDisplayName == "Before")

    let updated = try makePost(likeCount: 9, displayName: "After")
    model.updatePost(updated)
    #expect(model.displayText == "Feed fixture")
    #expect(model.likeCount == 9)
    #expect(model.authorDisplayName == "After")
  }

  @Test("An in-place cache mutation cannot hide a changed post or thread")
  func inPlaceMutationUsesValueSignature() throws {
    let post = try makePost(likeCount: 1)
    let model = FeedPostViewModel(post: post)
    let before = FeedPostContentSignature(post)
    #expect(model.likeCount == 1)
    post.serializedPost = try makePost(likeCount: 5).serializedPost
    post.threadDisplayMode = "expanded"
    post.threadPostCount = 2
    post.serializedSliceItems = Data("[]".utf8)
    #expect(before != FeedPostContentSignature(post))
    model.updatePost(post)
    #expect(model.likeCount == 5)
    #expect(model.post.threadPostCount == 2)
  }

  @Test("Pagination metadata does not invalidate presentation, but runtime row flags do")
  func presentationSignatureTracksOnlyRenderedState() throws {
    let post = try makePost(likeCount: 1)
    let before = FeedPostContentSignature(post)
    post.cursor = "next-page"
    post.cachedAt = Date()
    post.feedOrder = 99
    #expect(before == FeedPostContentSignature(post))
    post.smartFilterCollapseRuleID = "fixture-rule"
    #expect(before != FeedPostContentSignature(post))
    let collapsed = FeedPostContentSignature(post)
    post.isSmartFilterPending = true
    #expect(collapsed != FeedPostContentSignature(post))
    let pending = FeedPostContentSignature(post)
    post.intentHiddenRuleText = "fixture text"
    #expect(pending != FeedPostContentSignature(post))
    let hidden = FeedPostContentSignature(post)
    post.isTemporary = true
    #expect(hidden != FeedPostContentSignature(post))
  }

  @Test("Publications during a snapshot wait and coalesce to the latest state")
  func snapshotApplicationsAreSerial() async {
    let scheduler = FeedSnapshotUpdateScheduler()
    let fixture = SchedulerFixture()
    let first = Task { await scheduler.perform(fixture.apply) }
    while fixture.continuation == nil { await Task.yield() }
    fixture.state = 2
    let second = Task { await scheduler.perform(fixture.apply) }
    let third = Task { await scheduler.perform(fixture.apply) }
    // Allow both requests to enter while the first UIKit-like apply is suspended.
    while scheduler.requestCount < 3 { await Task.yield() }
    fixture.state = 3
    fixture.continuation?.resume()
    await first.value
    await second.value
    await third.value
    #expect(fixture.maximumActive == 1)
    #expect(fixture.appliedStates == [1, 3])
  }

  @Test("Cancellation drops queued publications and a finished drain can restart")
  func cancelledDrainCanRestart() async {
    let scheduler = FeedSnapshotUpdateScheduler()
    let fixture = SchedulerFixture()
    let first = Task { await scheduler.perform(fixture.apply) }
    while fixture.continuation == nil { await Task.yield() }
    fixture.state = 2
    let queued = Task { await scheduler.perform(fixture.apply) }
    while scheduler.requestCount < 2 { await Task.yield() }
    scheduler.cancel()
    fixture.continuation?.resume()
    await first.value
    await queued.value
    #expect(fixture.appliedStates == [1])
    fixture.state = 3
    await scheduler.perform(fixture.apply)
    #expect(fixture.appliedStates == [1, 3])
    #expect(fixture.maximumActive == 1)
  }

  @Test("A publication after cancellation waits behind the unfinished apply without being lost")
  func publicationAfterCancellationIsNotLost() async {
    let scheduler = FeedSnapshotUpdateScheduler()
    let fixture = SchedulerFixture()
    let first = Task { await scheduler.perform(fixture.apply) }
    while fixture.continuation == nil { await Task.yield() }
    fixture.state = 2
    let queued = Task { await scheduler.perform(fixture.apply) }
    while scheduler.requestCount < 2 { await Task.yield() }
    scheduler.cancel()
    fixture.state = 3
    let fresh = Task { await scheduler.perform(fixture.apply) }
    while scheduler.requestCount < 3 { await Task.yield() }
    fixture.continuation?.resume()
    await first.value
    await queued.value
    await fresh.value
    #expect(fixture.appliedStates == [1, 3])
    #expect(fixture.maximumActive == 1)
  }

  @MainActor
  private final class SchedulerFixture {
    var continuation: CheckedContinuation<Void, Never>?
    var appliedStates: [Int] = []
    var state = 1
    var active = 0
    var maximumActive = 0

    func apply() async {
      active += 1
      maximumActive = max(maximumActive, active)
      appliedStates.append(state)
      if appliedStates.count == 1 {
        await withCheckedContinuation { continuation = $0 }
      }
      active -= 1
    }
  }

  private func makePost(likeCount: Int, displayName: String = "Fixture") throws -> CachedFeedViewPost {
    let record = AppBskyFeedPost(
      text: "Feed fixture", entities: nil, facets: nil, reply: nil, embed: nil,
      langs: nil, labels: nil, tags: nil, createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 0)))
    let author = AppBskyActorDefs.ProfileViewBasic(
      did: try DID(didString: "did:plc:fixture"),
      handle: try Handle(handleString: "author.test"), displayName: displayName,
      pronouns: nil, avatar: nil, associated: nil, viewer: nil, labels: nil,
      createdAt: nil, verification: nil, status: nil, debug: nil)
    let post = AppBskyFeedDefs.PostView(
      uri: try ATProtocolURI(uriString: "at://did:plc:fixture/app.bsky.feed.post/one"),
      cid: CID.fromDAGCBOR(Data("cid-test".utf8)), author: author,
      record: .knownType(record), embed: nil, bookmarkCount: nil,
      replyCount: 0, repostCount: 0, likeCount: likeCount, quoteCount: nil,
      indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 0)),
      viewer: nil, labels: nil, threadgate: nil, debug: nil)
    let decoded = AppBskyFeedDefs.FeedViewPost(post: post, reply: nil, reason: nil,
      feedContext: nil, reqId: nil)
    return try #require(CachedFeedViewPost(from: decoded, feedType: "timeline"))
  }
}
#endif
