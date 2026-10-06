import Foundation
import Petrel
import SwiftData
import SwiftUI
import Synchronization
import Testing
import UIKit
import Vision

@testable import Catbird

/// Regression tests for repost-header corruption: cached feed-entry identity must
/// distinguish organic and repost variants, and must remain scoped to its feed.
@Suite("CachedFeedViewPost identity")
struct CachedFeedViewPostIdentityTests {
  @Test("Generator request context survives tuning, preparation and cache reconstruction",
    arguments: [nil, "context|segment"] as [String?])
  @MainActor
  func feedbackContextSurvivesFeedPreparation(feedContext: String?) async throws {
    let requestID = "request|with|pipes"
    let entry = try makeFeedViewPost(rkey: "feedback-context",
      feedContext: feedContext, reqId: requestID)
    let slices = await FeedTuner().tune([entry])
    let slice = try #require(slices.first)
    #expect(slice.feedContext == feedContext)
    #expect(slice.reqId == requestID)
    let prepared = try #require(PreparedFeedSlice(slice: slice))
    let serialized = try JSONDecoder().decode(AppBskyFeedDefs.FeedViewPost.self,
      from: prepared.serializedPost)
    #expect(serialized.feedContext == feedContext)
    #expect(serialized.reqId == requestID)
    let cached = CachedFeedViewPost(prepared: prepared, feedType: "feed:feedback-context")
    #expect(try cached.feedViewPost.reqId == requestID)
    #expect(cached.threadSlice?.reqId == requestID)
    #expect(cached.threadSlice?.feedContext == feedContext)
  }

  @Test("Freshly cached posts reuse the already decoded API value")
  @MainActor
  func freshPostAvoidsJSONRoundTrip() throws {
    let counter = DecodeCounter()
    let debug = countingDebugValue(counter)
    let entry = try makeFeedViewPost(rkey: "fresh-cache", debug: debug)
    let cached = try #require(CachedFeedViewPost(from: entry, feedType: "timeline"))

    #expect(try cached.feedViewPost == entry)
    #expect(try cached.feedViewPost == entry)
    #expect(counter.value == 0)
  }

  @Test("Repeated thread rendering decodes cold slice storage once")
  @MainActor
  func coldSliceDecodesOnce() throws {
    let counter = DecodeCounter()
    let debug = countingDebugValue(counter)
    let root = try makeFeedViewPost(rkey: "cached-root", debug: debug)
    let reply = try makeFeedViewPost(rkey: "cached-reply", debug: debug)
    let items = try [root, reply].map(sliceItem)
    let cached = try #require(CachedFeedViewPost(from: reply, feedType: "timeline"))
    _ = try cached.feedViewPost
    counter.reset()
    cached.serializedSliceItems = try JSONEncoder().encode(items)

    #expect(cached.isThreadSlice)
    #expect(cached.sliceItems?.map(\.id) == items.map(\.id))
    #expect(cached.threadSlice?.items.map(\.id) == items.map(\.id))
    #expect(counter.value == 2)
  }

  @Test("Replacing serialized payload invalidates the decoded post and slice")
  @MainActor
  func serializedReplacementInvalidatesCache() throws {
    let first = try makeFeedViewPost(rkey: "first-cache")
    let second = try makeFeedViewPost(rkey: "second-cache")
    let firstItems = try [first].map(sliceItem)
    let secondItems = try [second].map(sliceItem)
    let cached = try #require(CachedFeedViewPost(from: first, feedType: "timeline"))
    cached.serializedSliceItems = try JSONEncoder().encode(firstItems)
    _ = try cached.feedViewPost
    _ = cached.sliceItems

    cached.serializedPost = try JSONEncoder().encode(second)
    cached.serializedSliceItems = try JSONEncoder().encode(secondItems)
    #expect(try cached.feedViewPost == second)
    #expect(cached.sliceItems?.map(\.id) == secondItems.map(\.id))

    cached.serializedSliceItems = Data("malformed".utf8)
    #expect(cached.sliceItems == nil)
    cached.serializedSliceItems = nil
    #expect(cached.sliceItems == nil)
    cached.serializedSliceItems = try JSONEncoder().encode(firstItems)
    #expect(cached.sliceItems?.map(\.id) == firstItems.map(\.id))
  }

  @Test("Cache upsert retains the source's decoded post")
  @MainActor
  func upsertRetainsDecodedSource() throws {
    let counter = DecodeCounter()
    let debug = countingDebugValue(counter)
    let entry = try makeFeedViewPost(rkey: "upsert-cache", debug: debug)
    let original = try #require(CachedFeedViewPost(from: entry, feedType: "timeline"))
    let replacement = try #require(CachedFeedViewPost(from: entry, feedType: "timeline"))
    _ = try replacement.feedViewPost
    counter.reset()

    original.update(from: replacement)
    #expect(try original.feedViewPost == entry)
    #expect(counter.value == 0)
  }

  @Test("Upserting a source with unread storage changes cannot transfer stale decoded values")
  @MainActor
  func upsertFromMutatedSourceValidatesCacheBytes() throws {
    let counter = DecodeCounter()
    let first = try makeFeedViewPost(rkey: "upsert-first")
    let second = try makeFeedViewPost(rkey: "upsert-second", debug: countingDebugValue(counter))
    let firstItem = try sliceItem(first)
    let secondItem = try sliceItem(second)
    let source = try #require(CachedFeedViewPost(
      from: FeedSlice(items: [firstItem], rootUri: firstItem.id, feedPostUri: firstItem.id),
      feedType: "timeline"
    ))
    let target = try #require(CachedFeedViewPost(from: first, feedType: "timeline"))
    source.serializedPost = try JSONEncoder().encode(second)
    source.serializedSliceItems = try JSONEncoder().encode([secondItem])

    target.update(from: source)
    #expect(try withoutDecodeCounter(target.feedViewPost) == withoutDecodeCounter(second))
    #expect(target.sliceItems?.map(\.id) == [secondItem.id])
    #expect(counter.value == 2)
    #expect(try withoutDecodeCounter(target.feedViewPost) == withoutDecodeCounter(second))
    #expect(target.sliceItems?.map(\.id) == [secondItem.id])
    #expect(counter.value == 2)
  }

  @Test("Fetched storage decodes once and validates replacements after materialization")
  @MainActor
  func fetchedCacheValidatesStoredBytes() throws {
    let counter = DecodeCounter()
    let first = try makeFeedViewPost(rkey: "fetched-first", debug: countingDebugValue(counter))
    let second = try makeFeedViewPost(rkey: "fetched-second", debug: countingDebugValue(counter))
    let firstItem = try sliceItem(first)
    let secondItem = try sliceItem(second)
    let container = try makeInMemoryContainer()
    let writer = ModelContext(container)
    let saved = try #require(CachedFeedViewPost(
      from: FeedSlice(items: [firstItem], rootUri: firstItem.id, feedPostUri: firstItem.id),
      feedType: "timeline"
    ))
    writer.insert(saved)
    try writer.save()

    let reader = ModelContext(container)
    let fetched = try #require(reader.fetch(FetchDescriptor<CachedFeedViewPost>()).first)
    #expect(fetched !== saved)
    counter.reset()
    #expect(try fetched.feedViewPost.post.uri == first.post.uri)
    #expect(fetched.sliceItems?.map(\.id) == [firstItem.id])
    #expect(try fetched.feedViewPost.post.uri == first.post.uri)
    #expect(fetched.sliceItems?.map(\.id) == [firstItem.id])
    #expect(counter.value == 2)

    fetched.serializedPost = try JSONEncoder().encode(second)
    fetched.serializedSliceItems = try JSONEncoder().encode([secondItem])
    #expect(try withoutDecodeCounter(fetched.feedViewPost) == withoutDecodeCounter(second))
    #expect(fetched.sliceItems?.map(\.id) == [secondItem.id])
    #expect(try withoutDecodeCounter(fetched.feedViewPost) == withoutDecodeCounter(second))
    #expect(fetched.sliceItems?.map(\.id) == [secondItem.id])
    #expect(counter.value == 4)
  }

  private func withoutDecodeCounter(
    _ entry: AppBskyFeedDefs.FeedViewPost
  ) -> AppBskyFeedDefs.FeedViewPost {
    // The counting decoder returns .object rather than .knownType, so Petrel
    // preserves its synthetic $type as .unknownType after decoding. Exclude only
    // that instrumentation field; compare every production payload field.
    let post = entry.post
    return AppBskyFeedDefs.FeedViewPost(
      post: AppBskyFeedDefs.PostView(
        uri: post.uri, cid: post.cid, author: post.author, record: post.record,
        embed: post.embed, bookmarkCount: post.bookmarkCount, replyCount: post.replyCount,
        repostCount: post.repostCount, likeCount: post.likeCount, quoteCount: post.quoteCount,
        indexedAt: post.indexedAt, viewer: post.viewer, labels: post.labels,
        threadgate: post.threadgate, debug: nil
      ),
      reply: entry.reply, reason: entry.reason, feedContext: entry.feedContext, reqId: entry.reqId
    )
  }

  @Test("Persisting the same model instance preserves decoded post and slice caches")
  @MainActor
  func sameInstanceUpsertPreservesCaches() throws {
    let counter = DecodeCounter()
    let entry = try makeFeedViewPost(rkey: "same-instance", debug: countingDebugValue(counter))
    let item = try sliceItem(entry)
    let slice = FeedSlice(items: [item], rootUri: item.id, feedPostUri: item.id)
    let cached = try #require(CachedFeedViewPost(from: slice, feedType: "timeline"))
    cached.update(from: cached)
    #expect(try cached.feedViewPost.post.uri == entry.post.uri)
    #expect(cached.sliceItems?.map(\.id) == [item.id])
    #expect(counter.value == 0)
  }

  private final class DecodeCounter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
    func reset() { count.withLock { $0 = 0 } }
  }

  private func countingDebugValue(_ counter: DecodeCounter) -> ATProtocolValueContainer {
    // Each fixture owns a decoder name, so parallel tests cannot replace a
    // production decoder or observe one another's work.
    let type = "blue.catbird.test.cache-\(UUID().uuidString.lowercased())"
    ATProtocolValueContainer.registerDecoder(forType: type) { _ in
      counter.increment()
      return .object(["$type": .string(type)])
    }
    return .object(["$type": .string(type)])
  }

  private func sliceItem(_ entry: AppBskyFeedDefs.FeedViewPost) throws -> FeedSliceItem {
    guard case .knownType(let value) = entry.post.record,
          let record = value as? AppBskyFeedPost else {
      throw NSError(domain: "FeedCacheFixture", code: 1)
    }
    return FeedSliceItem(post: entry.post, record: record)
  }

  @Test("Prepared pages preserve ordering and thread metadata without redecoding")
  @MainActor
  func preparedPagePreservesSlices() async throws {
    let entries = try ["prepared-one", "prepared-two", "prepared-three"].map { try makeFeedViewPost(rkey: $0) }
    let items = try entries.map(sliceItem)
    let slices = [
      FeedSlice(items: [items[0]], rootUri: items[0].id, feedPostUri: items[0].id),
      FeedSlice(items: [], rootUri: "empty", feedPostUri: "empty"),
      FeedSlice(items: items, isIncompleteThread: true, rootUri: items[0].id,
                feedPostUri: items[2].id, feedContext: "fixture-context")
    ]
    let prepared = try await PreparedFeedSlice.prepare(slices)
    let cached = prepared.map { CachedFeedViewPost(prepared: $0, feedType: "fixture-timeline") }
    #expect(cached.map { try? $0.feedViewPost.post.uri.uriString() } == [items[0].id, items[2].id])
    #expect(cached.last?.sliceItems?.map(\.id) == items.map(\.id))
    #expect(cached.last?.isIncompleteThread == true)
    #expect(cached.last?.threadDisplayMode == "collapsed")
    #expect(try cached.last?.feedViewPost.feedContext == "fixture-context")
  }

  @Test("Canceled preparation returns no partial page")
  @MainActor
  func canceledPreparationDoesNotReturnPartialPage() async throws {
    let entry = try makeFeedViewPost(rkey: "cancel-prepare")
    let item = try sliceItem(entry)
    let slice = FeedSlice(items: [item], rootUri: item.id, feedPostUri: item.id)
    let task = Task { try await PreparedFeedSlice.prepare([slice]) }
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Canceled preparation must throw before publication")
    } catch is CancellationError {
      // Expected: the throwing structured call observes the caller's cancellation.
    }
  }

  @Test("A newer accepted cached page rejects a suspended older page")
  @MainActor
  func newGenerationRejectsOlderPreparation() async throws {
    let gate = PreparationGate()
    let model = await makePreparationModel(gate: gate)
    let oldEntry = try makeFeedViewPost(rkey: "older-page")
    let newEntry = try makeFeedViewPost(rkey: "newer-page")
    let older = Task { await model.setCachedFeed([oldEntry], cursor: "older-cursor") }
    await gate.waitUntilStarted()
    await model.setCachedFeed([newEntry], cursor: "newer-cursor")
    await gate.release()
    await older.value
    #expect(try model.posts.first?.feedViewPost.post.uri == newEntry.post.uri)
    #expect(model.currentCursor() == "newer-cursor")
  }

  @Test("An already canceled replacement cannot supersede active preparation")
  @MainActor
  func canceledReplacementDoesNotTakeGeneration() async throws {
    let gate = PreparationGate()
    let model = await makePreparationModel(gate: gate)
    let accepted = try makeFeedViewPost(rkey: "accepted-page")
    let discarded = try makeFeedViewPost(rkey: "already-canceled-page")
    let active = Task { await model.setCachedFeed([accepted], cursor: "accepted-cursor") }
    await gate.waitUntilStarted()
    let canceled = Task { await model.setCachedFeed([discarded], cursor: "discarded-cursor") }
    canceled.cancel()
    await canceled.value
    await gate.release()
    await active.value
    #expect(try model.posts.first?.feedViewPost.post.uri == accepted.post.uri)
    #expect(model.currentCursor() == "accepted-cursor")
    #expect(await gate.preparationCount == 1)
  }

  @Test("A feed switch rejects suspended work from the previous feed")
  @MainActor
  func feedSwitchRejectsOlderPreparation() async throws {
    let gate = PreparationGate()
    let model = await makePreparationModel(gate: gate)
    let entry = try makeFeedViewPost(rkey: "prior-feed")
    let older = Task { await model.setCachedFeed([entry], cursor: "prior-cursor") }
    await gate.waitUntilStarted()
    // FeedManager has no client, so this changes the selected feed without
    // performing transport or an authenticated account action.
    await model.loadFeed(fetch: .author("did:plc:anotherauthor"))
    await gate.release()
    await older.value
    #expect(model.posts.isEmpty)
    #expect(model.currentCursor() == nil)
    #expect(model.lastFeedType == .author("did:plc:anotherauthor"))
    #expect(!model.isLoading)
  }

  @Test("An account reset rejects suspended preparation and retains cleared pagination")
  @MainActor
  func resetRejectsOlderPreparation() async throws {
    let gate = PreparationGate()
    let model = await makePreparationModel(gate: gate)
    let entry = try makeFeedViewPost(rkey: "before-reset")
    let older = Task { await model.setCachedFeed([entry], cursor: "before-reset-cursor") }
    await gate.waitUntilStarted()
    await model.handleStateInvalidation(.accountSwitched)
    await gate.release()
    await older.value
    #expect(model.posts.isEmpty)
    #expect(model.currentCursor() == nil)
    #expect(!model.isLoading)
  }

  @Test("Canceling a suspended preparation leaves the current page untouched")
  @MainActor
  func cancelRejectsSuspendedPreparation() async throws {
    let gate = PreparationGate()
    let model = await makePreparationModel(gate: gate)
    let current = try makeFeedViewPost(rkey: "current-page")
    let incoming = try makeFeedViewPost(rkey: "canceled-page")
    model.posts = [try #require(CachedFeedViewPost(from: current, feedType: "fixture"))]
    let task = Task { await model.setCachedFeed([incoming], cursor: "canceled-cursor") }
    await gate.waitUntilStarted()
    task.cancel()
    await gate.release()
    await task.value
    #expect(try model.posts.first?.feedViewPost.post.uri == current.post.uri)
    #expect(model.currentCursor() == nil)
  }

  @Test("Cached custom-feed preparation uses the selected feed's identity")
  @MainActor
  func customFeedPreparationKeepsScope() async throws {
    let model = await makePreparationModel(fetch: .author("did:plc:customauthor"))
    let entry = try makeFeedViewPost(rkey: "custom-scope")
    await model.setCachedFeed([entry], cursor: "custom-cursor")
    #expect(model.posts.count == 1)
    #expect(model.posts.first?.feedType == "did:plc:cachepublicationfixture-\(model.lastFeedType.identifier)")
    #expect(model.currentCursor() == "custom-cursor")
  }

  @Test("Refilter retries against the current page when pagination appends during preparation")
  @MainActor
  func refilterKeepsPostsAppendedWhileSuspended() async throws {
    let gate = PreparationGate()
    let model = await makePreparationModel(gate: gate, fetch: .author("did:plc:customauthor"))
    let original = try makeFeedViewPost(rkey: "before-append")
    let appended = try makeFeedViewPost(rkey: "appended-page")
    let feedKey = "did:plc:cachepublicationfixture-\(model.lastFeedType.identifier)"
    model.posts = [try #require(CachedFeedViewPost(from: original, feedType: feedKey))]
    let refilter = Task { await model.handleSocialGraphChange() }
    await gate.waitUntilStarted()
    model.posts.append(try #require(CachedFeedViewPost(from: appended, feedType: feedKey)))
    await gate.release()
    await refilter.value
    #expect(model.posts.compactMap { try? $0.feedViewPost.post.uri } == [original.post.uri, appended.post.uri])
    #expect(await gate.preparationCount == 2)
  }

  @Test("Preparation failure propagates instead of becoming an empty filtered page")
  @MainActor
  func preparationFailureDoesNotPublishEmptyPage() async throws {
    let fetch = FetchType.author("did:plc:customauthor")
    let model = await makePreparationModel(fetch: fetch, failPreparation: true)
    let entry = try makeFeedViewPost(rkey: "kept-on-failure")
    model.posts = [try #require(CachedFeedViewPost(from: entry, feedType: "fixture"))]
    do {
      _ = try await model.processAndFilterPosts(
        fetchedPosts: [entry], newCursor: "failed-cursor",
        filterSettings: FeedFilterSettings(accountDID: "did:plc:cachepublicationfixture"), feedType: fetch
      )
      Issue.record("Preparation failures must propagate to the loading operation")
    } catch PreparationFailure.injected {
      #expect(try model.posts.first?.feedViewPost.post.uri == entry.post.uri)
      #expect(model.currentCursor() == nil)
    }
  }

  private enum PreparationFailure: Error { case injected }

  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal { .none }
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }

  @MainActor
  private func makePreparationModel(
    gate: PreparationGate? = nil, fetch: FetchType = .timeline, failPreparation: Bool = false
  ) async -> FeedModel {
    let client = await ATProtoClient(baseURL: URL(string: "https://cache-publication.invalid")!)
    let appState = AppState(userDID: "did:plc:cachepublicationfixture", client: client, regulatoryChecker: NoAgePrompt())
    let manager = FeedManager(client: nil, fetchType: fetch)
    return FeedModel(feedManager: manager, appState: appState, prepareSlices: { slices in
      if let gate { await gate.holdFirstPreparation() }
      if failPreparation { throw PreparationFailure.injected }
      return try await PreparedFeedSlice.prepare(slices)
    })
  }

  private actor PreparationGate {
    private var started = false
    private(set) var preparationCount = 0
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func holdFirstPreparation() async {
      preparationCount += 1
      guard !started else { return }
      started = true
      startWaiter?.resume()
      startWaiter = nil
      await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilStarted() async {
      if started { return }
      await withCheckedContinuation { startWaiter = $0 }
    }

    func release() {
      releaseWaiter?.resume()
      releaseWaiter = nil
    }
  }

  @Test("A reused feed view model accepts enriched thread context with the same payload")
  @MainActor
  func viewModelAcceptsThreadEnrichment() throws {
    let reply = try makeFeedViewPost(rkey: "thread-reply")
    let root = try makeFeedViewPost(rkey: "thread-root")
    let original = try #require(CachedFeedViewPost(from: reply, feedType: "timeline"))
    let enriched = try #require(CachedFeedViewPost(from: reply, feedType: "timeline"))
    // Preserve exactly the same API payload: only cached thread context changes.
    enriched.serializedPost = original.serializedPost
    let items = try [root, reply].map { entry -> FeedSliceItem in
      guard case .knownType(let value) = entry.post.record,
            let record = value as? AppBskyFeedPost else {
        throw NSError(domain: "FeedThreadFixture", code: 1)
      }
      return FeedSliceItem(post: entry.post, record: record)
    }
    enriched.serializedSliceItems = try JSONEncoder().encode(items)
    enriched.threadDisplayMode = "expanded"
    enriched.threadPostCount = 2
    enriched.isPartOfThread = true

    let viewModel = FeedPostViewModel(post: original)
    viewModel.showingFullText = true
    viewModel.updatePost(enriched)

    #expect(viewModel.post === enriched)
    #expect(viewModel.post.sliceItems?.map(\.id) == items.map(\.id))
    #expect(viewModel.post.threadDisplayMode == "expanded")
    #expect(viewModel.showingFullText)
  }

  @Test("Two-post self thread retains root and feed reply")
  func twoPostSelfThread() async throws {
    let posts = try makeThread(count: 2)
    let slices = await FeedTuner().tune([posts[1]])
    #expect(slices.count == 1)
    #expect(slices.first?.items.map(\.id) == posts.map { $0.post.uri.uriString() })
    #expect(slices.first?.isIncompleteThread == false)
  }

  @Test("Three-post self thread retains all connected context")
  func threePostSelfThread() async throws {
    let posts = try makeThread(count: 3)
    let slices = await FeedTuner().tune([posts[2]])
    #expect(slices.count == 1)
    #expect(slices.first?.items.map(\.id) == posts.map { $0.post.uri.uriString() })
    #expect(slices.first?.isIncompleteThread == false)
  }

  @Test("Reply bump deduplicates the root without losing the triggering reply")
  func replyBumpRetainsReply() async throws {
    let posts = try makeThread(count: 2)
    for input in [posts, Array(posts.reversed())] {
      let slices = await FeedTuner().tune(input)
      #expect(slices.count == 1)
      #expect(slices.first?.items.map(\.id) == posts.map { $0.post.uri.uriString() })
      #expect(slices.first?.feedPostUri == posts[1].post.uri.uriString())
    }
  }

  @Test("Equal timestamps and a later-dated root cannot replace the feed reply")
  func replyRelationshipsOutrankTimestamps() async throws {
    let posts = try makeThread(count: 3)
    for rootDate in ["2025-06-04T00:00:00.000Z", "2025-06-05T00:00:00.000Z"] {
      let adjusted = try posts.enumerated().map { index, entry in
        try replacingMainPostJSON(entry) { post in
          var record = try #require(post["record"] as? [String: Any])
          record["createdAt"] = index == 0 ? rootDate : "2025-06-04T00:00:00.000Z"
          post["record"] = record
        }
      }
      let slices = await FeedTuner().tune(Array(adjusted.reversed()))
      #expect(slices.count == 1)
      #expect(slices.first?.feedPostUri == posts[2].post.uri.uriString())
      #expect(slices.first?.items.map(\.id) == posts.map { $0.post.uri.uriString() })
    }
  }

  @Test("Sibling replies preserve server order despite a later sibling timestamp")
  func siblingReplySelectionPreservesFeedOrder() async throws {
    let posts = try makeThread(count: 2)
    let firstReply = posts[1]
    let laterSibling = try replacingMainPostJSON(firstReply) { post in
      post["uri"] = "at://did:plc:author/app.bsky.feed.post/later-sibling"
      var record = try #require(post["record"] as? [String: Any])
      record["createdAt"] = "2025-06-05T00:00:00.000Z"
      record["text"] = "A later sibling reply"
      post["record"] = record
    }
    let slices = await FeedTuner().tune([firstReply, laterSibling, posts[0]])
    #expect(slices.count == 1)
    #expect(slices.first?.feedPostUri == firstReply.post.uri.uriString())
    #expect(slices.first?.items.map(\.id) == [posts[0], firstReply].map { $0.post.uri.uriString() })

    let reversed = await FeedTuner().tune([laterSibling, firstReply, posts[0]])
    #expect(reversed.count == 1)
    #expect(reversed.first?.feedPostUri == laterSibling.post.uri.uriString())
  }

  @Test("Standalone feed post stays a single row")
  func standaloneStaysStandalone() async throws {
    let post = try makeFeedViewPost(rkey: "standalone")
    let slices = await FeedTuner().tune([post])
    #expect(slices.count == 1)
    #expect(slices.first?.items.map(\.id) == [post.post.uri.uriString()])
    #expect(slices.first?.shouldShowAsThread == false)
  }

  @Test("Long thread uses bounded root-parent-reply context and marks its gap")
  func longThreadStaysBounded() async throws {
    let posts = try makeThread(count: 5)
    let slices = await FeedTuner().tune([posts[4]])
    #expect(slices.count == 1)
    #expect(slices.first?.items.map(\.id) == [posts[0], posts[3], posts[4]].map { $0.post.uri.uriString() })
    #expect(slices.first?.isIncompleteThread == true)
  }

  @Test("Followed self-thread survives unfollowed-reply filtering with its context")
  func followedSelfThreadKeepsContext() async throws {
    let posts = try makeThread(count: 3, followed: true)
    let settings = FeedTunerSettings(
      hideReplies: false, hideRepliesByUnfollowed: true, hideRepliesByLikeCount: nil,
      hideReposts: false, hideQuotePosts: false,
      hideNonPreferredLanguages: false, preferredLanguages: [],
      mutedUsers: [], blockedUsers: [], hideLinks: false,
      onlyTextPosts: false, onlyMediaPosts: false,
      contentLabelPreferences: [], hideAdultContent: false, hiddenPosts: [],
      currentUserDid: "did:plc:reader"
    )
    let filtered = await ContentFilterService().filterFeedViewPosts([posts[2]], settings: settings)
    #expect(filtered.count == 1)
    let slices = await FeedTuner().tune([posts[2]], filterSettings: settings)
    #expect(slices.count == 1)
    #expect(slices.first?.items.map(\.id) == posts.map { $0.post.uri.uriString() })
  }

  @Test("An unfollowed author's self-thread remains excluded")
  func unfollowedSelfThreadIsExcluded() async throws {
    let posts = try makeThread(count: 2)
    let settings = contextFilterSettings()
    let filtered = await ContentFilterService().filterFeedViewPosts([posts[1]], settings: settings)
    let slices = await FeedTuner().tune([posts[1]], filterSettings: settings)
    #expect(filtered.isEmpty)
    #expect(slices.isEmpty)
  }

  @Test("Following only the reply author does not qualify unfollowed context")
  func followedReplyToUnfollowedContextIsExcluded() async throws {
    let posts = try makeThread(count: 2)
    let reply = try replacingMainPostJSON(posts[1]) { post in
      var author = try #require(post["author"] as? [String: Any])
      author["did"] = "did:plc:followed-replier"
      author["viewer"] = ["following": "at://did:plc:reader/app.bsky.graph.follow/replier"]
      post["author"] = author
      post["uri"] = "at://did:plc:followed-replier/app.bsky.feed.post/reply"
    }
    let settings = contextFilterSettings()
    let filtered = await ContentFilterService().filterFeedViewPosts([reply], settings: settings)
    let slices = await FeedTuner().tune([reply], filterSettings: settings)
    #expect(filtered.isEmpty)
    #expect(slices.isEmpty)
  }

  @Test("Followed thread context does not bypass adult-content filtering")
  func followedContextStillChecksAdultLabels() async throws {
    let posts = try makeThread(count: 2, followed: true)
    let reply = try replacingMainPostJSON(posts[1]) { post in
      post["labels"] = [[
        "src": "did:plc:labeler", "uri": posts[1].post.uri.uriString(),
        "val": "porn", "cts": "2025-06-04T00:00:00.000Z"
      ]]
    }
    let allowed = await ContentFilterService().filterFeedViewPosts([reply], settings: contextFilterSettings())
    #expect(allowed.count == 1)
    let settings = contextFilterSettings(hideAdultContent: true)
    let filtered = await ContentFilterService().filterFeedViewPosts([reply], settings: settings)
    let slices = await FeedTuner().tune([reply], filterSettings: settings)
    #expect(filtered.isEmpty)
    #expect(slices.isEmpty)
  }

  private func contextFilterSettings(hideAdultContent: Bool = false) -> FeedTunerSettings {
    FeedTunerSettings(
      hideReplies: false, hideRepliesByUnfollowed: true, hideRepliesByLikeCount: nil,
      hideReposts: false, hideQuotePosts: false,
      hideNonPreferredLanguages: false, preferredLanguages: [],
      mutedUsers: [], blockedUsers: [], hideLinks: false,
      onlyTextPosts: false, onlyMediaPosts: false,
      contentLabelPreferences: [], hideAdultContent: hideAdultContent, hiddenPosts: [],
      currentUserDid: "did:plc:reader"
    )
  }

  private func replacingMainPostJSON(
    _ entry: AppBskyFeedDefs.FeedViewPost,
    mutate: (inout [String: Any]) throws -> Void
  ) throws -> AppBskyFeedDefs.FeedViewPost {
    var envelope = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
    var post = try #require(envelope["post"] as? [String: Any])
    try mutate(&post)
    envelope["post"] = post
    return try JSONDecoder().decode(AppBskyFeedDefs.FeedViewPost.self, from: JSONSerialization.data(withJSONObject: envelope))
  }

  /// Encode ordinary fixture posts and attach protocol reply context, including
  /// the record's strong references used to distinguish connected and gapped threads.
  private func makeThread(count: Int, followed: Bool = false, texts: [String]? = nil) throws -> [AppBskyFeedDefs.FeedViewPost] {
    var posts: [AppBskyFeedDefs.FeedViewPost] = []
    for index in 0..<count {
      let base = try makeFeedViewPost(rkey: "thread-\(index)")
      var envelope = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
      var post = try #require(envelope["post"] as? [String: Any])
      var record = try #require(post["record"] as? [String: Any])
      record["createdAt"] = "2025-06-04T00:00:0\(index).000Z"
      if let texts { record["text"] = texts[index] }
      if followed {
        var author = try #require(post["author"] as? [String: Any])
        author["viewer"] = ["following": "at://did:plc:reader/app.bsky.graph.follow/author"]
        post["author"] = author
      }
      if let parent = posts.last, let root = posts.first {
        var rootJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(root.post)) as? [String: Any])
        var parentJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(parent.post)) as? [String: Any])
        record["reply"] = [
          "root": ["uri": root.post.uri.uriString(), "cid": try #require(rootJSON["cid"] as? String)],
          "parent": ["uri": parent.post.uri.uriString(), "cid": try #require(parentJSON["cid"] as? String)]
        ]
        rootJSON["$type"] = "app.bsky.feed.defs#postView"
        parentJSON["$type"] = "app.bsky.feed.defs#postView"
        envelope["reply"] = ["root": rootJSON, "parent": parentJSON]
      }
      post["record"] = record
      envelope["post"] = post
      posts.append(try JSONDecoder().decode(AppBskyFeedDefs.FeedViewPost.self, from: JSONSerialization.data(withJSONObject: envelope)))
    }
    return posts
  }

  @Test("Repost gets a distinct id from the organic post")
  func repostIdDiffersFromOrganic() throws {
    let organic = try makeFeedViewPost(rkey: "abc123")
    let reposted = try makeFeedViewPost(
      rkey: "abc123",
      repostedBy: "did:plc:reposter",
      repostIndexedAt: Date(timeIntervalSince1970: 1_750_000_000)
    )

    let organicCached = try #require(CachedFeedViewPost(from: organic, feedType: "timeline"))
    let repostCached = try #require(CachedFeedViewPost(from: reposted, feedType: "timeline"))

    #expect(organicCached.id != repostCached.id)
    #expect(repostCached.id.hasPrefix(organicCached.id))
  }

  @Test("Repost id is stable across repeated construction")
  func repostIdIsStable() throws {
    let repostDate = Date(timeIntervalSince1970: 1_750_000_000)
    let first = try makeFeedViewPost(
      rkey: "abc123",
      repostedBy: "did:plc:reposter",
      repostIndexedAt: repostDate
    )
    let second = try makeFeedViewPost(
      rkey: "abc123",
      repostedBy: "did:plc:reposter",
      repostIndexedAt: repostDate
    )

    let firstCached = try #require(CachedFeedViewPost(from: first, feedType: "timeline"))
    let secondCached = try #require(CachedFeedViewPost(from: second, feedType: "timeline"))

    #expect(firstCached.id == secondCached.id)
  }

  @Test("Organic timeline row survives caching the repost variant under a profile feed")
  func repostVariantDoesNotClobberOrganicRow() throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)

    let organic = try makeFeedViewPost(rkey: "abc123")
    let timelineRow = try #require(CachedFeedViewPost(from: organic, feedType: "timeline"))
    context.insert(timelineRow)
    try context.save()

    let reposted = try makeFeedViewPost(
      rkey: "abc123",
      repostedBy: "did:plc:reposter",
      repostIndexedAt: Date(timeIntervalSince1970: 1_750_000_000)
    )
    let profileRow = try #require(
      CachedFeedViewPost(from: reposted, feedType: "profile-did:plc:reposter")
    )
    context.insert(profileRow)
    try context.save()

    let timelinePosts = try context.fetch(
      FetchDescriptor<CachedFeedViewPost>(
        predicate: #Predicate { $0.feedType == "timeline" }
      )
    )
    #expect(timelinePosts.count == 1)
    let timelineDecoded = try #require(try? timelinePosts.first?.feedViewPost)
    #expect(timelineDecoded.reason == nil, "timeline's organic post must not grow a repost header")
    #expect(timelinePosts.first?.isRepost == false)

    let profilePosts = try context.fetch(
      FetchDescriptor<CachedFeedViewPost>(
        predicate: #Predicate { $0.feedType == "profile-did:plc:reposter" }
      )
    )
    #expect(profilePosts.count == 1)
    let profileDecoded = try #require(try? profilePosts.first?.feedViewPost)
    if case .appBskyFeedDefsReasonRepost = profileDecoded.reason {
      // Expected.
    } else {
      Issue.record("profile feed's row must keep its repost reason")
    }
  }

  @Test("Identical organic post cached under two feeds keeps both rows")
  func samePostCoexistsAcrossFeeds() throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)

    let post = try makeFeedViewPost(rkey: "abc123")
    let timelineRow = try #require(CachedFeedViewPost(from: post, feedType: "timeline"))
    context.insert(timelineRow)
    try context.save()

    let profileRow = try #require(
      CachedFeedViewPost(from: post, feedType: "profile-did:plc:author")
    )
    context.insert(profileRow)
    try context.save()

    let all = try context.fetch(FetchDescriptor<CachedFeedViewPost>())
    #expect(all.count == 2)
    #expect(Set(all.map(\.feedType)) == ["timeline", "profile-did:plc:author"])
  }

  @Test("Identical organic post has a distinct stable identity in each feed")
  func samePostIdentityIncludesFeedScope() throws {
    let post = try makeFeedViewPost(rkey: "abc123")
    let timeline = try #require(CachedFeedViewPost(from: post, feedType: "timeline"))
    let profile = try #require(
      CachedFeedViewPost(from: post, feedType: "profile-did:plc:author")
    )

    #expect(timeline.id != profile.id)
    #expect(timeline.id == CachedFeedViewPost.computeId(for: post, feedType: "timeline"))
    #expect(
      profile.id
        == CachedFeedViewPost.computeId(for: post, feedType: "profile-did:plc:author")
    )
  }

  @Test("App Entity annotation uses the underlying post URI, not the feed-scoped cache id")
  func appEntityAnnotationUsesUnderlyingURI() throws {
    let post = try makeFeedViewPost(rkey: "entity123")
    let cached = try #require(CachedFeedViewPost(from: post, feedType: "timeline"))

    #expect(!cached.id.hasPrefix("at://"))
    #expect(
      AppEntityAnnotationIdentifiers.postURI(for: cached)
        == "at://did:plc:author/app.bsky.feed.post/entity123"
    )
  }

  @Test("Updating a cached row cannot move it into another feed")
  func updateRefusesCrossFeedSource() throws {
    let organic = try makeFeedViewPost(rkey: "abc123")
    let repost = try makeFeedViewPost(
      rkey: "abc123",
      repostedBy: "did:plc:reposter",
      repostIndexedAt: Date(timeIntervalSince1970: 1_750_000_000)
    )
    let timeline = try #require(CachedFeedViewPost(from: organic, feedType: "timeline"))
    let originalData = timeline.serializedPost
    let profile = try #require(
      CachedFeedViewPost(from: repost, feedType: "profile-did:plc:reposter")
    )

    timeline.update(from: profile)

    #expect(timeline.feedType == "timeline")
    #expect(timeline.serializedPost == originalData)
    #expect(timeline.isRepost == false)
  }

  @Test("Primary feed persistence keeps the same post in two feeds")
  func primaryPersistenceKeepsFeedScopedRows() async throws {
    let schema = Schema([
      CachedFeedViewPost.self,
      PersistedScrollPosition.self,
      PersistedFeedState.self,
      FeedContinuityInfo.self,
    ])
    let configuration = ModelConfiguration(
      "CachedFeedPrimaryPath-InMemory",
      schema: schema,
      isStoredInMemoryOnly: true,
      cloudKitDatabase: .none
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let manager = PersistentFeedStateManager(modelContainer: container)
    let post = try makeFeedViewPost(rkey: "abc123")
    let timeline = try #require(CachedFeedViewPost(from: post, feedType: "timeline"))
    let profile = try #require(
      CachedFeedViewPost(from: post, feedType: "profile-did:plc:author")
    )

    await manager.saveFeedData([timeline], for: "timeline")
    await manager.saveFeedData([profile], for: "profile-did:plc:author")

    let context = ModelContext(container)
    let rows = try context.fetch(FetchDescriptor<CachedFeedViewPost>())
    #expect(rows.count == 2)
    #expect(Set(rows.map(\.feedType)) == ["timeline", "profile-did:plc:author"])
  }

  @Test("Primary feed upsert matches both feed type and entry id")
  func primaryFeedUpsertScopesIdentity() throws {
    let source = try sourceFile(
      "Catbird/Features/Feed/Services/PersistentFeedStateManager.swift"
    )

    #expect(source.contains("post.feedType == currentFeedId && post.id == postId"))
    #expect(!source.contains("IMPORTANT: Fetch ALL existing posts by ID (across ALL feeds)"))
  }

  @Test("Thread cache lookup prefix recognizes scoped IDs without URI-prefix collisions")
  func threadCacheLookupUsesScopedEntryPrefix() throws {
    let post = try makeFeedViewPost(rkey: "abc123")
    let cached = try #require(
      CachedFeedViewPost(from: post, feedType: "thread-cache")
    )
    let uri = post.post.uri.uriString()
    let prefix = CachedFeedViewPost.entryIdPrefix(for: uri, feedType: "thread-cache")
    let longerURIPrefix = CachedFeedViewPost.entryIdPrefix(
      for: "\(uri)-different",
      feedType: "thread-cache"
    )

    #expect(cached.id.starts(with: prefix))
    #expect(!cached.id.starts(with: longerURIPrefix))

    let source = try sourceFile("Catbird/Features/Feed/Services/ThreadManager.swift")
    #expect(
      source.contains(
        "CachedFeedViewPost.entryIdPrefix(for: uriString, feedType: threadCacheFeedType)"
      )
    )
    #expect(source.contains("post.id.starts(with: entryPrefix)"))
    #expect(!source.contains("post.id.starts(with: uriString)"))
  }

  @Test("Thread cache upsert is scoped to feed identity")
  func threadCacheUpsertScopesIdentity() throws {
    let source = try sourceFile("Catbird/Features/Feed/Services/ThreadManager.swift")

    #expect(source.contains("let postFeedType = cachedPost.feedType"))
    #expect(source.contains("post.id == postId && post.feedType == postFeedType"))
  }

  @Test("Notification cache upsert is scoped to feed identity")
  func notificationCacheUpsertScopesIdentity() throws {
    let source = try sourceFile(
      "Catbird/Features/Notifications/Services/NotificationManager.swift"
    )

    #expect(source.contains("let postFeedType = cachedPost.feedType"))
    #expect(source.contains("post.id == postId && post.feedType == postFeedType"))
  }

  @Test("Raw FeedViewPost initializer renders without a cache wrapper")
  @MainActor
  func rawFeedViewPostInitializerRendersWithoutCacheWrapper() async throws {
    let rawPost = try makeFeedViewPost(rkey: "raw-post-render-test")
    let enhanced = EnhancedFeedPost(feedViewPost: rawPost, path: .constant(NavigationPath()))
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:testuser", client: client)
    let renderer = ImageRenderer(content: enhanced.environment(appState).environment(SceneNavigationContext(appState: appState, sceneID: UUID())).frame(width: 402))

    #expect(enhanced.id == rawPost.id)
    #expect(enhanced.feedViewPost == rawPost)
    #expect(renderer.uiImage != nil)
  }

  @Test("Short cached threads render readable root and reply pixels")
  @MainActor
  func shortCachedThreadsRenderAtIncreasingHeights() async throws {
    let sentinels = ["THREAD ROOT ALPHA", "THREAD REPLY BRAVO", "THREAD REPLY CHARLIE"]
    let posts = try makeThread(count: 3, texts: sentinels)
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:testuser", client: client)
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    var heights: [CGFloat] = []

    for count in 1...3 {
      let slices = await FeedTuner().tune([posts[count - 1]])
      let slice = try #require(slices.first)
      #expect(slice.items.count == count)
      let cached = try #require(CachedFeedViewPost(from: slice, feedType: "timeline"))
      let content = EnhancedFeedPost(cachedPost: cached, path: .constant(NavigationPath()))
        .applyAppStateEnvironment(appState).environment(SceneNavigationContext(appState: appState, sceneID: UUID()))
        .environment(\.fontManager, appState.fontManager)
        .environment(\.horizontalSizeClass, .compact)
        .environment(\.dynamicTypeSize, .medium)
        .environment(\.colorScheme, .light)
        .frame(width: 402)
        .fixedSize(horizontal: false, vertical: true)
      let host = UIHostingController(rootView: content)
      let window = UIWindow(windowScene: scene)
      let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
      window.frame = CGRect(x: 0, y: 0, width: 402, height: 1200)
      window.rootViewController = host
      window.backgroundColor = .white
      host.overrideUserInterfaceStyle = .light
      window.isHidden = false
      defer {
        let becameKey = window.isKeyWindow
        window.isHidden = true
        window.rootViewController = nil
        if becameKey { previousKeyWindow?.makeKey() }
      }

      // A visible UIKit hierarchy supports content ImageRenderer cannot capture.
      // Yield for layout, then require the actual captured pixels to contain text.
      let deadline = ContinuousClock.now + .seconds(2)
      var lastPNG = Data()
      var transcript = ""
      var captureError = ""
      var drewHierarchy = false
      var readable = false
      var height: CGFloat = 0
      repeat {
        try await Task.sleep(for: .milliseconds(50))
        let size = host.sizeThatFits(in: CGSize(width: 402, height: 1200))
        height = ceil(size.height)
        guard height.isFinite, height > 0, height <= 1200 else {
          captureError = "Invalid fitted height: \(height)"
          break
        }
        window.frame.size = CGSize(width: 402, height: height)
        host.view.frame = window.bounds
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
          drewHierarchy = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        lastPNG = image.pngData() ?? Data()
        do {
          let cgImage = try #require(image.cgImage)
          let request = VNRecognizeTextRequest()
          request.recognitionLevel = .accurate
          request.recognitionLanguages = ["en-US"]
          request.usesLanguageCorrection = false
          try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
          transcript = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
          let normalized = transcript.uppercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
          readable = drewHierarchy
            && sentinels.prefix(count).allSatisfy { normalized.contains($0) }
            && sentinels.dropFirst(count).allSatisfy { !normalized.contains($0) }
          captureError = ""
        } catch {
          captureError = String(describing: error)
        }
      } while !readable && ContinuousClock.now < deadline

      // Preserve the last failed capture too; dimensions alone cannot pass this test.
      if !lastPNG.isEmpty {
        Attachment.record(Array(lastPNG), named: "feed-thread-\(count)-posts-uikit.png")
      }
      let receipt = "height=\(height), drawHierarchy=\(drewHierarchy), readable=\(readable)\n"
        + "error=\(captureError)\nOCR:\n\(transcript)"
      Attachment.record(Array(receipt.utf8), named: "feed-thread-\(count)-posts-ocr.txt")
      #expect(!lastPNG.isEmpty, "UIKit capture must produce a PNG")
      #expect(drewHierarchy, "UIKit must complete hierarchy capture")
      #expect(readable, "Expected only the first \(count) body sentinels in captured pixels; see OCR attachment")
      heights.append(height)
    }

    #expect(heights[0] > 0)
    #expect(heights[1] > heights[0])
    #expect(heights[2] > heights[1])
  }

  @Test("EnhancedFeedPost does not snapshot cached payload in initializer")
  @MainActor
  func enhancedFeedPostDoesNotSnapshotCachedPayloadInInitializer() throws {
    let post = try makeFeedViewPost(rkey: "lazy-payload-test")
    let cached = try #require(CachedFeedViewPost(from: post, feedType: "timeline"))
    let enhanced = EnhancedFeedPost(cachedPost: cached, path: .constant(NavigationPath()))

    cached.serializedPost = Data("invalid-payload".utf8)

    #expect(enhanced.feedViewPost == nil)
  }

  private func sourceFile(_ relativePath: String) throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(
      contentsOf: repositoryRoot.appendingPathComponent(relativePath),
      encoding: .utf8
    )
  }

  private func makeInMemoryContainer() throws -> ModelContainer {
    let schema = Schema([CachedFeedViewPost.self])
    let configuration = ModelConfiguration(
      "CachedFeedViewPostIdentityTests-InMemory",
      schema: schema,
      isStoredInMemoryOnly: true,
      cloudKitDatabase: .none
    )
    return try ModelContainer(for: schema, configurations: [configuration])
  }

  private func makeFeedViewPost(
    rkey: String,
    repostedBy reposterDID: String? = nil,
    repostIndexedAt: Date? = nil,
    debug: ATProtocolValueContainer? = nil,
    feedContext: String? = nil,
    reqId: String? = nil
  ) throws -> AppBskyFeedDefs.FeedViewPost {
    let record = AppBskyFeedPost(
      text: "Post \(rkey)",
      entities: nil,
      facets: nil,
      reply: nil,
      embed: nil,
      langs: nil,
      labels: nil,
      tags: nil,
      createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_749_000_000))
    )

    let post = AppBskyFeedDefs.PostView(
      uri: try ATProtocolURI(uriString: "at://did:plc:author/app.bsky.feed.post/\(rkey)"),
      cid: CID.fromDAGCBOR(Data("post-\(rkey)".utf8)),
      author: try makeProfile(did: "did:plc:author"),
      record: .knownType(record),
      embed: nil,
      bookmarkCount: nil,
      replyCount: 0,
      repostCount: 0,
      likeCount: 0,
      quoteCount: nil,
      indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_749_000_100)),
      viewer: nil,
      labels: nil,
      threadgate: nil,
      debug: debug
    )

    let reason: AppBskyFeedDefs.FeedViewPostReasonUnion?
    if let reposterDID {
      reason = .appBskyFeedDefsReasonRepost(
        AppBskyFeedDefs.ReasonRepost(
          by: try makeProfile(did: reposterDID),
          uri: nil,
          cid: nil,
          indexedAt: ATProtocolDate(
            date: repostIndexedAt ?? Date(timeIntervalSince1970: 1_750_000_000)
          )
        )
      )
    } else {
      reason = nil
    }

    return AppBskyFeedDefs.FeedViewPost(
      post: post,
      reply: nil,
      reason: reason,
      feedContext: feedContext,
      reqId: reqId
    )
  }

  private func makeProfile(did: String) throws -> AppBskyActorDefs.ProfileViewBasic {
    AppBskyActorDefs.ProfileViewBasic(
      did: try DID(didString: did),
      handle: try Handle(handleString: "user.bsky.social"),
      displayName: "User",
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
  }
}
