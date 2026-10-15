import Foundation
import Petrel
import Testing

@testable import Catbird

// A shared post in a DM renders only a record whose labels were hydrated while the applied
// atproto-accept-labelers header named exactly the labelers the account's policy trusts. A getMessages
// page fetched under that header renders at once; any other copy only names a post the store confirms
// with one batched getPosts before the card shows it.

@Suite("DM shared-post label confirmation")
@MainActor
struct ChatRecordEmbedLabelConfirmationTests {
  private typealias Store = ChatRecordEmbedStore
  private typealias Fixtures = RenderingFixtures

  private static let bsky = RenderingFixtures.blueskyModerationDID
  private static let labeler = RenderingFixtures.customLabelerDID

  private let stateToken = ScopeToken()
  private let clientToken = ScopeToken()
  private let policy = RenderingFixtures.customLabelerPolicy(blurs: "content", severity: "alert")

  private var context: Store.Context {
    Store.Context(
      account: Fixtures.viewerDID, state: ObjectIdentifier(stateToken), client: ObjectIdentifier(clientToken))
  }

  /// The header and the policy both name the Bluesky moderation service and labeler.test.
  private var coveringScope: Store.Scope {
    Store.Scope(context: context, labelers: [Self.bsky, Self.labeler].sorted())
  }

  private func uri(_ index: Int) -> String {
    "at://\(Fixtures.authorDID)/app.bsky.feed.post/shared\(index)"
  }

  /// What getPosts returns under the covering header: the post carries labeler.test's `custom` label.
  private func labeledPost(_ uri: String) throws -> AppBskyFeedDefs.PostView {
    try Fixtures.post(uri: uri, labels: [Fixtures.label("custom", uri: uri, src: Self.labeler)])
  }

  /// A copy hydrated without labeler.test: the same post with no labels.
  private func unlabeledCopy(_ uri: String) throws -> Store.Record {
    Store.viewRecord(from: try Fixtures.post(uri: uri))
  }

  private func labeledCopy(_ uri: String) throws -> Store.Record {
    Store.viewRecord(from: try labeledPost(uri))
  }

  private func stub(serving uris: [String]) throws -> GetPostsStub {
    let stub = GetPostsStub(currentScope: coveringScope)
    for uri in uris { stub.posts[uri] = try labeledPost(uri) }
    return stub
  }

  private func quoted(_ record: Store.Record?) throws -> AppBskyEmbedRecord.ViewRecord {
    guard case .appBskyEmbedRecordViewRecord(let view)? = record else {
      throw ProbeFailure.notAViewRecord
    }
    return view
  }

  // MARK: - getMessages seeds

  @Test("A getMessages record hydrated under the covering header renders without a request")
  func seedHydratedUnderTheCoveringHeaderRendersAtOnce() async throws {
    let store = Store()
    let stub = try stub(serving: [uri(0)])
    let record = try labeledCopy(uri(0))

    store.seed(
      [Store.Seed(uri: uri(0), record: record, hydratedUnder: [Self.labeler, Self.bsky])],
      conversation: "convo", context: context)

    #expect(store.cachedRecord(uri: uri(0), scope: coveringScope) == record)
    #expect(try await store.load(uri: uri(0), source: stub.source(scope: coveringScope)) == record)
    #expect(stub.calls.isEmpty)
  }

  @Test("A record whose header is unknown stays covered until getPosts confirms it")
  func seedWithAnUnknownHeaderIsConfirmedFirst() async throws {
    let store = Store()
    let stub = try stub(serving: [uri(0)])
    let chatCopy = try unlabeledCopy(uri(0))

    store.seed([Store.Seed(uri: uri(0), record: chatCopy, hydratedUnder: nil)], conversation: "convo", context: context)

    #expect(store.cachedRecord(uri: uri(0), scope: coveringScope) == nil)
    #expect(stub.calls.isEmpty, "Seeding never sends a request")

    let confirmed = try await store.load(uri: uri(0), source: stub.source(scope: coveringScope))

    #expect(stub.calls == [[uri(0)]])
    #expect(store.cachedRecord(uri: uri(0), scope: coveringScope) == confirmed)
    #expect(try quoted(confirmed).labels?.map(\.val) == ["custom"])
    // The chat copy would have shown the post open; the confirmed record carries the labeler's gate.
    #expect(!PostModerationPresentation.make(quoted: try quoted(chatCopy), policy: policy).concealsBody)
    #expect(PostModerationPresentation.make(quoted: try quoted(confirmed), policy: policy).concealsBody)
  }

  @Test("A record hydrated under another header is not rendered under this one")
  func seedHydratedUnderAnotherHeaderIsNotRendered() async throws {
    let store = Store()
    let stub = try stub(serving: [uri(0)])

    store.seed(
      [Store.Seed(uri: uri(0), record: try unlabeledCopy(uri(0)), hydratedUnder: [Self.bsky])],
      conversation: "convo", context: context)

    #expect(store.cachedRecord(uri: uri(0), scope: coveringScope) == nil)
    let narrowScope = Store.Scope(context: context, labelers: [Self.bsky])
    #expect(store.cachedRecord(uri: uri(0), scope: narrowScope) != nil)

    _ = try await store.load(uri: uri(0), source: stub.source(scope: coveringScope))
    #expect(stub.calls == [[uri(0)]])
  }

  @Test("A getMessages record never replaces a getPosts record that carries more labels")
  func seedNeverReplacesAConfirmedRecordWithFewerLabels() async throws {
    let store = Store()
    let stub = try stub(serving: [uri(0)])
    let confirmed = try await store.load(uri: uri(0), source: stub.source(scope: coveringScope))

    store.seed(
      [Store.Seed(uri: uri(0), record: try unlabeledCopy(uri(0)), hydratedUnder: coveringScope.labelers)],
      conversation: "convo", context: context)

    #expect(store.cachedRecord(uri: uri(0), scope: coveringScope) == confirmed)
  }

  @Test("A getMessages record carrying every label getPosts returned and more replaces it")
  func seedWithMoreLabelsReplacesTheConfirmedRecord() async throws {
    let store = Store()
    let stub = GetPostsStub(currentScope: coveringScope)
    stub.posts[uri(0)] = try Fixtures.post(uri: uri(0))
    _ = try await store.load(uri: uri(0), source: stub.source(scope: coveringScope))
    let newer = try labeledCopy(uri(0))

    store.seed(
      [Store.Seed(uri: uri(0), record: newer, hydratedUnder: coveringScope.labelers)],
      conversation: "convo", context: context)

    #expect(store.cachedRecord(uri: uri(0), scope: coveringScope) == newer)
  }

  @Test("Seeding the same posts again sends no request")
  func repeatedSeedsSendNothing() throws {
    let store = Store()
    let seeds = try (0..<30).map { Store.Seed(uri: uri($0), record: try unlabeledCopy(uri($0)), hydratedUnder: nil) }

    for _ in 0..<3 { store.seed(seeds, conversation: "convo", context: context) }

    #expect(seeds.allSatisfy { store.cachedRecord(uri: $0.uri, scope: coveringScope) == nil })
  }

  // MARK: - Batching

  @Test("A load confirms the unconfirmed posts of its own conversation in the same request")
  func loadJoinsItsConversationsPendingPosts() async throws {
    let store = Store()
    let stub = try stub(serving: (0..<5).map(uri))
    store.seed(
      try [0, 1, 2].map { Store.Seed(uri: uri($0), record: try unlabeledCopy(uri($0)), hydratedUnder: nil) },
      conversation: "a", context: context)
    store.seed(
      try [3, 4].map { Store.Seed(uri: uri($0), record: try unlabeledCopy(uri($0)), hydratedUnder: nil) },
      conversation: "b", context: context)

    _ = try await store.load(uri: uri(1), source: stub.source(scope: coveringScope))

    #expect(stub.calls == [[uri(1), uri(0), uri(2)]])
    #expect(store.cachedRecord(uri: uri(0), scope: coveringScope) != nil)
    #expect(store.cachedRecord(uri: uri(3), scope: coveringScope) == nil)
  }

  @Test("A load sends one request of at most 25 posts, newest first; later loads take the rest")
  func loadSendsAtMostOneBatch() async throws {
    let store = Store()
    let uris = (0..<30).map(uri)
    let stub = try stub(serving: uris)
    stub.holds = true
    store.seed(
      try uris.map { Store.Seed(uri: $0, record: try unlabeledCopy($0), hydratedUnder: nil) },
      conversation: "convo", context: context)
    let source = stub.source(scope: coveringScope)

    let first = Task { try await store.load(uri: uris[0], source: source) }
    await waitUntil { stub.calls.count == 1 }
    let joined = Task { try await store.load(uri: uris[3], source: source) }
    await waitUntil { stub.pendingReplies == 1 }
    for _ in 0..<10 { await Task.yield() }
    #expect(stub.calls.count == 1, "A post already in flight joins its request")
    stub.release()
    _ = try await first.value
    _ = try await joined.value

    #expect(stub.calls == [Array(uris.prefix(25))])
    _ = try await store.load(uri: uris[27], source: source)
    #expect(stub.calls.last == [uris[27], uris[25], uris[26], uris[28], uris[29]])
  }

  // MARK: - Header changes and failures

  @Test("Results that land after the header changed are dropped")
  func resultsAfterAHeaderChangeAreDropped() async throws {
    let store = Store()
    let stub = try stub(serving: [uri(0)])
    stub.holds = true
    let load = Task { try await store.load(uri: uri(0), source: stub.source(scope: coveringScope)) }
    await waitUntil { stub.pendingReplies == 1 }

    stub.currentScope = nil
    stub.release()

    await #expect(throws: CancellationError.self) { try await load.value }
    #expect(store.cachedRecord(uri: uri(0), scope: coveringScope) == nil)
    #expect(!store.isUnavailable(uri: uri(0), scope: coveringScope))
  }

  @Test("A post getPosts does not return is remembered as unavailable")
  func missingPostIsRememberedAsUnavailable() async throws {
    let store = Store()
    let stub = GetPostsStub(currentScope: coveringScope)
    let source = stub.source(scope: coveringScope)

    await #expect(throws: ChatRecordEmbedUnavailableError.self) { try await store.load(uri: uri(0), source: source) }
    #expect(store.isUnavailable(uri: uri(0), scope: coveringScope))
    await #expect(throws: ChatRecordEmbedUnavailableError.self) { try await store.load(uri: uri(0), source: source) }
    #expect(stub.calls.count == 1, "A missing post is not requested again")

    store.seed(
      [Store.Seed(uri: uri(0), record: try unlabeledCopy(uri(0)), hydratedUnder: coveringScope.labelers)],
      conversation: "convo", context: context)
    #expect(store.cachedRecord(uri: uri(0), scope: coveringScope) == nil)
    #expect(store.isUnavailable(uri: uri(0), scope: coveringScope))
  }

  @Test("A failed request is left out of later batches until its own card retries")
  func failedPostsAreNotJoinedAutomatically() async throws {
    let store = Store()
    let stub = try stub(serving: [uri(0), uri(1), uri(2)])
    stub.failuresRemaining = 1
    let source = stub.source(scope: coveringScope)
    store.seed(
      try [0, 1].map { Store.Seed(uri: uri($0), record: try unlabeledCopy(uri($0)), hydratedUnder: nil) },
      conversation: "convo", context: context)

    await #expect(throws: URLError.self) { try await store.load(uri: uri(0), source: source) }
    #expect(stub.calls == [[uri(0), uri(1)]])

    store.seed(
      try [2, 0, 1].map { Store.Seed(uri: uri($0), record: try unlabeledCopy(uri($0)), hydratedUnder: nil) },
      conversation: "convo", context: context)
    _ = try await store.load(uri: uri(2), source: source)
    #expect(stub.calls.last == [uri(2)])

    _ = try await store.load(uri: uri(1), source: source)
    #expect(stub.calls.last == [uri(1)])
    #expect(store.cachedRecord(uri: uri(1), scope: coveringScope) != nil)
  }

  @Test("A card that leaves does not cancel the request another card awaits")
  func leavingConsumerDoesNotCancelTheBatch() async throws {
    let store = Store()
    let stub = try stub(serving: [uri(0)])
    stub.holds = true
    let source = stub.source(scope: coveringScope)
    let leaving = Task { try await store.load(uri: uri(0), source: source) }
    let staying = Task { try await store.load(uri: uri(0), source: source) }
    await waitUntil { stub.pendingReplies == 1 }

    leaving.cancel()
    stub.release()

    let record = try await staying.value
    await #expect(throws: CancellationError.self) { try await leaving.value }
    #expect(stub.calls.count == 1)
    #expect(store.cachedRecord(uri: uri(0), scope: coveringScope) == record)
  }

  @Test("The store keeps its newest entries at capacity")
  func capacityEvictsTheOldestEntry() throws {
    let store = Store()
    let seeds = try (0...Store.capacity).map {
      Store.Seed(uri: uri($0), record: try unlabeledCopy(uri($0)), hydratedUnder: coveringScope.labelers)
    }

    for seed in seeds { store.seed([seed], conversation: "convo", context: context) }

    #expect(store.cachedRecord(uri: uri(0), scope: coveringScope) == nil)
    #expect(store.cachedRecord(uri: uri(1), scope: coveringScope) != nil)
    #expect(store.cachedRecord(uri: uri(Store.capacity), scope: coveringScope) != nil)
  }

  // MARK: - Covering labelers

  @Test("Shared posts wait while no accept-labelers header is applied")
  func noAppliedHeaderCoversNothing() {
    #expect(Store.coveringLabelers(policyLabelerDIDs: [Self.bsky, Self.labeler], applied: nil) == nil)
  }

  @Test("Shared posts wait while the header lacks a labeler the policy trusts")
  func headerMissingATrustedLabelerCoversNothing() {
    #expect(Store.coveringLabelers(policyLabelerDIDs: [Self.bsky, Self.labeler], applied: [Self.bsky]) == nil)
  }

  @Test("Shared posts wait while the header names a labeler the policy does not trust yet")
  func headerAheadOfThePolicyCoversNothing() {
    #expect(Store.coveringLabelers(policyLabelerDIDs: [Self.bsky], applied: [Self.bsky, Self.labeler]) == nil)
  }

  @Test("A header naming the policy's labelers covers them, in any order")
  func matchingHeaderCoversThePolicy() {
    #expect(Store.coveringLabelers(policyLabelerDIDs: [Self.bsky, Self.labeler], applied: [Self.labeler, Self.bsky])
      == [Self.bsky, Self.labeler].sorted())
  }

  @Test("The 20-labeler header cap still covers a policy with more subscriptions")
  func cappedHeaderCoversALargePolicy() {
    let subscribed = (0..<30).map { "did:plc:statefixturelabeler\($0)" }
    let applied = PreferencesManager.acceptLabelers(subscribedDIDs: subscribed).map(\.did)
    let policyDIDs = [Self.bsky] + subscribed

    #expect(Store.coveringLabelers(policyLabelerDIDs: policyDIDs, applied: applied) == applied.sorted())
  }

  // MARK: - Label definitions

  @Test("A card stays covered while the definition of a trusted labeler's label is loading")
  func unresolvedTrustedLabelWaitsForDefinitions() throws {
    let record = try labeledCopy(uri(0))
    let withoutDefinitions = Fixtures.policy(labelerDIDs: [Self.labeler])

    #expect(Store.awaitsLabelDefinitions(record, policy: withoutDefinitions, definitionsLoading: true))
    #expect(!Store.awaitsLabelDefinitions(record, policy: withoutDefinitions, definitionsLoading: false))
    #expect(!Store.awaitsLabelDefinitions(record, policy: policy, definitionsLoading: true))
  }

  @Test("Labels the policy ignores anyway never hold a card")
  func untrustedOrNegatedLabelsDoNotWait() throws {
    let untrusted = Store.viewRecord(from: try Fixtures.post(
      uri: uri(0), labels: [Fixtures.label("custom", uri: uri(0), src: "did:web:elsewhere.test")]))
    let negated = Store.viewRecord(from: try Fixtures.post(uri: uri(1), labels: [
      ComAtprotoLabelDefs.Label(
        src: try DID(didString: Self.labeler), uri: URI(uriString: uri(1)), val: "custom", neg: true,
        cts: ATProtocolDate(date: Date()))
    ]))
    let withoutDefinitions = Fixtures.policy(labelerDIDs: [Self.labeler])

    #expect(!Store.awaitsLabelDefinitions(untrusted, policy: withoutDefinitions, definitionsLoading: true))
    #expect(!Store.awaitsLabelDefinitions(negated, policy: withoutDefinitions, definitionsLoading: true))
  }

  @Test("An unresolved label on the author holds the card too")
  func unresolvedAuthorLabelWaits() throws {
    let record = Store.viewRecord(from: try Fixtures.post(
      uri: uri(0),
      author: try Fixtures.profile(labels: [Fixtures.accountLabel("custom", src: Self.labeler)])))

    #expect(Store.awaitsLabelDefinitions(
      record, policy: Fixtures.policy(labelerDIDs: [Self.labeler]), definitionsLoading: true))
  }

  // MARK: - Mapping

  @Test("A getPosts view keeps its labels, author and embeds as a record")
  func viewRecordKeepsLabelsAuthorAndEmbeds() throws {
    let post = try Fixtures.post(
      uri: uri(0), labels: [Fixtures.label("custom", uri: uri(0), src: Self.labeler)], embed: Fixtures.imageEmbed)
    let view = try quoted(Store.viewRecord(from: post))

    #expect(view.uri == post.uri)
    #expect(view.cid == post.cid)
    #expect(view.author.did == post.author.did)
    #expect(view.labels == post.labels)
    guard case .appBskyEmbedImagesView? = view.embeds?.first else {
      Issue.record("The image embed must survive the mapping")
      return
    }
  }

  // MARK: - Helpers

  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<1_000 {
      if condition() { return }
      await Task.yield()
    }
  }
}

private enum ProbeFailure: Error {
  case notAViewRecord
}

private final class ScopeToken {}

/// Serves getPosts from a table, records each request's URIs, and can hold replies or fail once.
@MainActor
private final class GetPostsStub {
  var posts: [String: AppBskyFeedDefs.PostView] = [:]
  var currentScope: ChatRecordEmbedStore.Scope?
  var holds = false
  var failuresRemaining = 0
  private(set) var calls: [[String]] = []
  private var held: [CheckedContinuation<Void, Never>] = []

  init(currentScope: ChatRecordEmbedStore.Scope?) {
    self.currentScope = currentScope
  }

  var pendingReplies: Int { held.count }

  func source(scope: ChatRecordEmbedStore.Scope) -> ChatRecordEmbedStore.Source {
    ChatRecordEmbedStore.Source(
      scope: scope,
      currentScope: { [unowned self] in self.currentScope },
      fetch: { [unowned self] uris in try await self.fetch(uris) })
  }

  func release() {
    holds = false
    let replies = held
    held = []
    for reply in replies { reply.resume() }
  }

  private func fetch(_ uris: [ATProtocolURI]) async throws -> [AppBskyFeedDefs.PostView] {
    calls.append(uris.map { $0.uriString() })
    if holds {
      await withCheckedContinuation { held.append($0) }
    }
    if failuresRemaining > 0 {
      failuresRemaining -= 1
      throw URLError(.notConnectedToInternet)
    }
    return uris.compactMap { posts[$0.uriString()] }
  }
}
