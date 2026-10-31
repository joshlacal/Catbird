import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("Feed feedback outbox")
@MainActor
struct FeedFeedbackOutboxTests {
  private static let feedA = FeedInteractionTarget(
    feedURI: "at://did:plc:creator/app.bsky.feed.generator/a", generatorDID: "did:web:a.example")
  private static let feedB = FeedInteractionTarget(
    feedURI: "at://did:plc:creator/app.bsky.feed.generator/b", generatorDID: "did:web:b.example")
  private let alice = FeedFeedbackDestination(accountDID: "did:plc:alice", target: feedA)
  private let bob = FeedFeedbackDestination(accountDID: "did:plc:bob", target: feedB)

  private func key(
    _ destination: FeedFeedbackDestination, item: String = "post",
    event: String = "app.bsky.feed.defs#requestMore", context: String? = nil,
    requestID: String? = nil
  ) -> FeedFeedbackKey {
    FeedFeedbackKey(destination: destination, interaction: FeedFeedbackInteraction(
      itemURI: "at://did:plc:author/app.bsky.feed.post/\(item)", event: event,
      feedContext: context, requestID: requestID))
  }

  // MARK: - Outbox

  @Test("A failed event stays unconfirmed until it is explicitly retried")
  func failureRequiresExplicitRetry() async {
    let outbox = FeedFeedbackOutbox()
    let preference = key(alice)
    outbox.enqueue(preference)
    await outbox.flush(alice) { _, _ in throw FakeFailure.unacknowledged }
    #expect(outbox.state(for: preference) == .unconfirmed)

    let seen = key(alice, item: "new", event: "app.bsky.feed.defs#interactionSeen")
    outbox.enqueue(seen)
    var sent: [[FeedFeedbackInteraction]] = []
    await outbox.flush(alice) { _, batch in sent.append(batch) }
    #expect(sent == [[seen.interaction]])
    #expect(outbox.state(for: preference) == .unconfirmed)

    outbox.prepareRetry(preference)
    await outbox.flush(alice) { _, batch in sent.append(batch) }
    #expect(sent == [[seen.interaction], [preference.interaction]])
    #expect(outbox.state(for: preference) == .confirmed)
  }

  @Test("Batches never mix accounts or feeds")
  func destinationsNeverMix() async {
    let outbox = FeedFeedbackOutbox()
    let sameAccountOtherFeed = FeedFeedbackDestination(accountDID: alice.accountDID, target: Self.feedB)
    let events = [key(alice), key(bob), key(sameAccountOtherFeed)]
    for event in events { outbox.enqueue(event) }
    #expect(outbox.queuedDestinations == [alice, bob, sameAccountOtherFeed])
    for expected in events {
      await outbox.flush(expected.destination) { destination, batch in
        #expect(destination == expected.destination)
        #expect(batch == [expected.interaction])
      }
      #expect(outbox.state(for: expected) == .confirmed)
    }
    #expect(outbox.queuedDestinations.isEmpty)
  }

  @Test("Opaque feed context and request IDs reach the sender exactly as given")
  func opaqueFieldsSurvive() async {
    let outbox = FeedFeedbackOutbox()
    let missingContext = key(alice, requestID: "request|with|pipes")
    let emptyContext = key(alice, context: "", requestID: "request|with|pipes")
    let opaqueContext = key(alice, context: "ctx|segment", requestID: nil)
    for event in [missingContext, emptyContext, opaqueContext] { outbox.enqueue(event) }
    await outbox.flush(alice) { _, batch in
      #expect(batch == [missingContext.interaction, emptyContext.interaction, opaqueContext.interaction])
      #expect(batch[0].feedContext == nil)
      #expect(batch[0].requestID == "request|with|pipes")
      #expect(batch[1].feedContext == "")
      #expect(batch[2].feedContext == "ctx|segment")
    }
  }

  @Test("Acknowledgment confirms only the batch that was sending")
  func acknowledgmentRemovesOnlyTheAwaitingBatch() async {
    let outbox = FeedFeedbackOutbox()
    let first = key(alice, item: "first")
    let later = key(alice, item: "later")
    let gate = SendGate()
    outbox.enqueue(first)
    let send = Task { await outbox.flush(alice, send: gate.send) }
    await gate.waitUntilStarted()
    #expect(outbox.state(for: first) == .sending)

    outbox.enqueue(first)
    outbox.enqueue(later)
    await outbox.flush(alice) { _, _ in Issue.record("A second batch started during an in-flight batch") }
    #expect(gate.batches == [[first.interaction]])
    gate.release()
    await send.value
    #expect(outbox.state(for: first) == .confirmed)
    #expect(outbox.state(for: later) == .queued)
    await outbox.flush(alice) { _, batch in #expect(batch == [later.interaction]) }
    #expect(outbox.state(for: later) == .confirmed)
  }

  @Test("A failed batch keeps later events queued")
  func failedBatchKeepsLaterEvents() async {
    let outbox = FeedFeedbackOutbox()
    let first = key(alice, item: "first")
    let later = key(alice, item: "later")
    let gate = SendGate(failure: .unacknowledged)
    outbox.enqueue(first)
    let send = Task { await outbox.flush(alice, send: gate.send) }
    await gate.waitUntilStarted()
    outbox.enqueue(later)
    gate.release()
    await send.value
    #expect(outbox.state(for: first) == .unconfirmed)
    #expect(outbox.state(for: later) == .queued)
    await outbox.flush(alice) { _, batch in #expect(batch == [later.interaction]) }
    #expect(outbox.state(for: first) == .unconfirmed)
  }

  @Test("A confirmed duplicate is not sent again")
  func confirmedDuplicateDoesNotSendAgain() async {
    let outbox = FeedFeedbackOutbox()
    let event = key(alice)
    outbox.enqueue(event)
    await outbox.flush(alice) { _, _ in }
    outbox.enqueue(event)
    await outbox.flush(alice) { _, _ in Issue.record("An acknowledged duplicate was sent again") }
    #expect(outbox.state(for: event) == .confirmed)
  }

  @Test("A full outbox rejects new events without losing failed ones")
  func capacityRejectsNewWork() async {
    let outbox = FeedFeedbackOutbox(pendingLimit: 1)
    let retained = key(alice)
    let rejected = key(alice, item: "other")
    #expect(outbox.enqueue(retained))
    await outbox.flush(alice) { _, _ in throw FakeFailure.unacknowledged }
    #expect(!outbox.enqueue(rejected))
    #expect(outbox.state(for: rejected) == nil)
    outbox.prepareRetry(retained)
    await outbox.flush(alice) { _, batch in #expect(batch == [retained.interaction]) }
    #expect(outbox.enqueue(rejected))
  }

  @Test("A feed's events beyond one request's limit stay queued for the next batch")
  func batchLimitLeavesOverflowQueued() async {
    let outbox = FeedFeedbackOutbox()
    let events = (0...FeedFeedbackOutbox.batchLimit).map { key(alice, item: String($0)) }
    for event in events { outbox.enqueue(event) }
    await outbox.flush(alice) { _, batch in
      #expect(batch == events.prefix(FeedFeedbackOutbox.batchLimit).map(\.interaction))
    }
    #expect(outbox.state(for: events[FeedFeedbackOutbox.batchLimit - 1]) == .confirmed)
    #expect(outbox.state(for: events[FeedFeedbackOutbox.batchLimit]) == .queued)
  }

  @Test("Bounded confirmed history never evicts pending events")
  func boundedHistoryKeepsPendingEvents() async {
    let outbox = FeedFeedbackOutbox(historyLimit: 1)
    let failed = key(alice, item: "failed")
    outbox.enqueue(failed)
    await outbox.flush(alice) { _, _ in throw FakeFailure.unacknowledged }
    let first = key(alice, item: "first")
    let second = key(alice, item: "second")
    outbox.enqueue(first)
    await outbox.flush(alice) { _, _ in }
    outbox.enqueue(second)
    await outbox.flush(alice) { _, _ in }
    #expect(outbox.state(for: first) == nil)
    #expect(outbox.state(for: second) == .confirmed)
    #expect(outbox.state(for: failed) == .unconfirmed)
  }

  @Test("Discarding drops queued and unconfirmed events but lets a sending batch finish")
  func discardKeepsOnlyTheSendingBatch() async {
    let outbox = FeedFeedbackOutbox()
    let sending = key(alice, item: "sending")
    let failed = key(bob, item: "failed")
    let queued = key(bob, item: "queued")
    outbox.enqueue(failed)
    await outbox.flush(bob) { _, _ in throw FakeFailure.unacknowledged }
    outbox.enqueue(sending)
    let gate = SendGate()
    let send = Task { await outbox.flush(alice, send: gate.send) }
    await gate.waitUntilStarted()
    outbox.enqueue(queued)

    outbox.discardPending()
    #expect(outbox.state(for: failed) == nil)
    #expect(outbox.state(for: queued) == nil)
    #expect(outbox.queuedDestinations.isEmpty)
    gate.release()
    await send.value
    #expect(outbox.state(for: sending) == .confirmed)
  }

  // MARK: - Manager account scoping

  @Test("Feedback is sent with the queuing account's session, one request per feed, with its context")
  func managerSendsPerFeedWithContext() async throws {
    let harness = ManagerHarness(accountDID: "did:plc:alice")
    let post = try ATProtocolURI(uriString: "at://did:plc:author/app.bsky.feed.post/one")
    harness.manager.sendShowMore(postURI: post, target: Self.feedA, feedContext: "ctx|a", reqId: "req|1")
    harness.manager.trackPostSeen(postURI: post, target: Self.feedB)
    harness.manager.trackPostSeen(postURI: post, target: nil)
    await harness.manager.flushInteractions()

    #expect(harness.sent.map { $0.destination } == [
      FeedFeedbackDestination(accountDID: "did:plc:alice", target: Self.feedA),
      FeedFeedbackDestination(accountDID: "did:plc:alice", target: Self.feedB)
    ])
    #expect(harness.sent.first?.interactions == [FeedFeedbackInteraction(
      itemURI: post.uriString(), event: "app.bsky.feed.defs#requestMore",
      feedContext: "ctx|a", requestID: "req|1")])
  }

  @Test("Feedback queued before an account switch is dropped and never sent with the next account")
  func managerDropsFeedbackOnAccountSwitch() async throws {
    let harness = ManagerHarness(accountDID: "did:plc:alice")
    let post = try ATProtocolURI(uriString: "at://did:plc:author/app.bsky.feed.post/one")
    harness.manager.sendShowLess(postURI: post, target: Self.feedA)

    // What AppState does when this account is switched away from or signed out.
    harness.work.suspend()
    harness.manager.discardPending()
    harness.manager.sendShowMore(postURI: post, target: Self.feedA)
    harness.authenticatedDID = "did:plc:bob"
    await harness.manager.flushInteractions()
    #expect(harness.sent.isEmpty)

    // Rolling back to the same account later does not resurrect the dropped feedback.
    harness.authenticatedDID = "did:plc:alice"
    harness.work.resume()
    await harness.manager.flushInteractions()
    #expect(harness.sent.isEmpty)
  }

  @Test("A client signed in as another account never sends this account's feedback")
  func managerRefusesMismatchedSession() async throws {
    let harness = ManagerHarness(accountDID: "did:plc:alice")
    let post = try ATProtocolURI(uriString: "at://did:plc:author/app.bsky.feed.post/one")
    harness.manager.sendShowMore(postURI: post, target: Self.feedA)
    harness.authenticatedDID = "did:plc:bob"
    await harness.manager.flushInteractions()
    #expect(harness.sent.isEmpty)

    // Asking again once the right account is back sends it; a repeated "seen" does not.
    harness.authenticatedDID = "did:plc:alice"
    harness.manager.sendShowMore(postURI: post, target: Self.feedA)
    await harness.manager.flushInteractions()
    #expect(harness.sent.count == 1)
    harness.manager.sendShowMore(postURI: post, target: Self.feedA)
    await harness.manager.flushInteractions()
    #expect(harness.sent.count == 1, "Confirmed feedback is not sent twice")
  }

  @Test("A send in flight holds the account open so a switch waits for it")
  func managerSendHoldsAccountOperation() async throws {
    let gate = SendGate()
    let harness = ManagerHarness(accountDID: "did:plc:alice", gate: gate)
    let post = try ATProtocolURI(uriString: "at://did:plc:author/app.bsky.feed.post/one")
    harness.manager.trackPostSeen(postURI: post, target: Self.feedA)
    let flush = Task { await harness.manager.flushInteractions() }
    await gate.waitUntilStarted()
    harness.work.suspend()
    await #expect(throws: AccountServiceWork.BarrierError.self) {
      try await harness.work.drain(timeout: .milliseconds(50))
    }
    gate.release()
    await flush.value
    try await harness.work.drain(timeout: .seconds(1))
  }

  // MARK: - Helpers

  private enum FakeFailure: Error { case unacknowledged }

  @MainActor
  private final class ManagerHarness {
    let work = AccountServiceWork()
    var authenticatedDID: String?
    private(set) var sent: [(destination: FeedFeedbackDestination, interactions: [FeedFeedbackInteraction])] = []
    private(set) var manager: FeedFeedbackManager!

    init(accountDID: String, gate: SendGate? = nil) {
      authenticatedDID = accountDID
      manager = FeedFeedbackManager(accountDID: accountDID, accountServiceWork: work, transport: .init(
        authenticatedDID: { [unowned self] in self.authenticatedDID },
        send: { [unowned self] destination, interactions in
          if let gate { try await gate.send(destination, interactions) }
          self.sent.append((destination, interactions))
        }
      ))
    }
  }

  @MainActor
  private final class SendGate {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    private let failure: FakeFailure?
    private(set) var batches: [[FeedFeedbackInteraction]] = []

    init(failure: FakeFailure? = nil) { self.failure = failure }

    func send(_ destination: FeedFeedbackDestination, _ batch: [FeedFeedbackInteraction]) async throws {
      batches.append(batch)
      started = true
      waiter?.resume()
      waiter = nil
      await withCheckedContinuation { continuation = $0 }
      if let failure { throw failure }
    }

    func waitUntilStarted() async {
      if !started { await withCheckedContinuation { waiter = $0 } }
    }

    func release() {
      continuation?.resume()
      continuation = nil
    }
  }
}
