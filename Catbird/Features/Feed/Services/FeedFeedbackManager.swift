//
//  FeedFeedbackManager.swift
//  Catbird
//
//  Feed interaction feedback manager for custom feeds and Discover
//  Based on Bluesky social-app implementation
//

import Foundation
import Petrel
import os


/// Queues and sends feed interaction feedback for one account. Every interaction names
/// the feed it belongs to and the account that recorded it, so nothing depends on which
/// feed loaded last, and nothing queued by one account is sent with another's session.
@MainActor
final class FeedFeedbackManager {

  /// How queued feedback reaches the feed generator; injectable for tests.
  struct Transport {
    /// The DID the client is signed in as right now.
    let authenticatedDID: @MainActor () async throws -> String?
    let send: @MainActor (FeedFeedbackDestination, [FeedFeedbackInteraction]) async throws -> Void
  }

  private enum DeliveryError: Error {
    case accountUnavailable
    case unconfirmed(Int)
  }

  private let logger = Logger(subsystem: "blue.catbird", category: "FeedFeedback")

  // MARK: - Properties

  /// The account that owns this manager; feedback is only queued and sent for it.
  let accountDID: String

  private let outbox: FeedFeedbackOutbox

  /// Admission for account work. While suspended (account switch, sign-out) nothing is
  /// queued or sent, and a send in flight holds an operation so a switch waits for it.
  private let accountServiceWork: AccountServiceWork

  private let transport: Transport

  /// Timer for throttled sending
  private var sendTimer: Timer?

  // MARK: - Constants

  /// Interactions allowed for third-party feeds
  private static let allowedThirdPartyInteractions: Set<String> = [
    "app.bsky.feed.defs#requestLess",
    "app.bsky.feed.defs#requestMore",
    "app.bsky.feed.defs#interactionLike",
    "app.bsky.feed.defs#interactionQuote",
    "app.bsky.feed.defs#interactionReply",
    "app.bsky.feed.defs#interactionRepost",
    "app.bsky.feed.defs#interactionSeen"
  ]

  /// Explicit preferences; a failed one is resent when the person asks again.
  private static let explicitPreferences: Set<String> = [
    "app.bsky.feed.defs#requestLess",
    "app.bsky.feed.defs#requestMore"
  ]

  /// Throttle interval for sending interactions (10 seconds)
  private static let sendThrottleInterval: TimeInterval = 10.0

  init(
    accountDID: String,
    accountServiceWork: AccountServiceWork,
    outbox: FeedFeedbackOutbox? = nil,
    transport: Transport
  ) {
    self.accountDID = accountDID
    self.accountServiceWork = accountServiceWork
    self.outbox = outbox ?? FeedFeedbackOutbox()
    self.transport = transport
  }

  /// Sends through the account's client, routing each request alone to its feed generator.
  convenience init(
    accountDID: String,
    accountServiceWork: AccountServiceWork,
    clientProvider: @escaping @MainActor () -> ATProtoClient?
  ) {
    self.init(accountDID: accountDID, accountServiceWork: accountServiceWork, transport: Transport(
      authenticatedDID: {
        guard let client = clientProvider() else { return nil }
        return try await client.getDid()
      },
      send: { destination, interactions in
        guard let client = clientProvider() else { throw DeliveryError.accountUnavailable }
        let input = AppBskyFeedSendInteractions.Input(
          feed: try ATProtocolURI(uriString: destination.target.feedURI),
          interactions: try interactions.map { item in
            AppBskyFeedDefs.Interaction(
              item: try ATProtocolURI(uriString: item.itemURI),
              event: item.event,
              feedContext: item.feedContext,
              reqId: item.requestID
            )
          }
        )
        // Route this request alone to the feed generator ({feedGeneratorDID}#bsky_fg).
        // A per-request proxy header overrides the client's default service
        // routing without leaking into concurrent requests.
        let network = await client.networkService
        let request = try await network.createURLRequest(
          endpoint: "app.bsky.feed.sendInteractions",
          method: "POST",
          headers: ["Content-Type": "application/json", "Accept": "application/json"],
          body: try JSONEncoder().encode(input),
          queryItems: nil
        )
        let (_, response) = try await network.performRequest(
          request,
          skipTokenRefresh: false,
          additionalHeaders: ["atproto-proxy": "\(destination.target.generatorDID)#bsky_fg"]
        )
        guard (200...299).contains(response.statusCode) else {
          throw DeliveryError.unconfirmed(response.statusCode)
        }
      }
    ))
  }

  // MARK: - Account Lifecycle

  /// Drops everything not yet sending. Called when this account's work is suspended
  /// (account switch, sign-out) so its feedback is never sent after the session changes.
  func discardPending() {
    sendTimer?.invalidate()
    sendTimer = nil
    outbox.discardPending()
  }

  // MARK: - Interaction Tracking

  /// Send a "show more" interaction for a post
  func sendShowMore(
    postURI: ATProtocolURI, target: FeedInteractionTarget?,
    feedContext: String? = nil, reqId: String? = nil
  ) {
    sendInteraction(
      event: "app.bsky.feed.defs#requestMore",
      postURI: postURI,
      target: target,
      feedContext: feedContext,
      reqId: reqId
    )
  }

  /// Send a "show less" interaction for a post
  func sendShowLess(
    postURI: ATProtocolURI, target: FeedInteractionTarget?,
    feedContext: String? = nil, reqId: String? = nil
  ) {
    sendInteraction(
      event: "app.bsky.feed.defs#requestLess",
      postURI: postURI,
      target: target,
      feedContext: feedContext,
      reqId: reqId
    )
  }

  /// Queue an interaction for the feed generator behind `target`, on behalf of this
  /// manager's account. A nil target means the post is not being shown in a feed that
  /// accepts feedback.
  func sendInteraction(
    event: String,
    postURI: ATProtocolURI,
    target: FeedInteractionTarget?,
    feedContext: String? = nil,
    reqId: String? = nil
  ) {
    guard let target, !accountServiceWork.isSuspended else { return }

    guard Self.allowedThirdPartyInteractions.contains(event) else {
      logger.warning("Interaction event not allowed: \(event)")
      return
    }

    let key = FeedFeedbackKey(
      destination: FeedFeedbackDestination(accountDID: accountDID, target: target),
      interaction: FeedFeedbackInteraction(
        itemURI: postURI.uriString(),
        event: event,
        feedContext: feedContext,
        requestID: reqId
      )
    )

    switch outbox.state(for: key) {
    case .unconfirmed where Self.explicitPreferences.contains(event):
      outbox.prepareRetry(key)
    case .some:
      logger.debug("Interaction already queued or sent, skipping")
      return
    case .none:
      guard outbox.enqueue(key) else {
        logger.warning("Feedback outbox is full, dropping \(event)")
        return
      }
    }

    // Schedule throttled send
    scheduleThrottledSend()

    logger.debug("Queued interaction: \(event) for post \(postURI.uriString()) in feed \(target.feedURI)")
  }

  /// Track when a post is seen
  func trackPostSeen(
    postURI: ATProtocolURI, target: FeedInteractionTarget?,
    feedContext: String? = nil, reqId: String? = nil
  ) {
    sendInteraction(
      event: "app.bsky.feed.defs#interactionSeen",
      postURI: postURI,
      target: target,
      feedContext: feedContext,
      reqId: reqId
    )
  }

  /// Track when a post is liked
  func trackLike(postURI: ATProtocolURI, target: FeedInteractionTarget?, feedContext: String? = nil) {
    sendInteraction(
      event: "app.bsky.feed.defs#interactionLike",
      postURI: postURI,
      target: target,
      feedContext: feedContext
    )
  }

  /// Track when a post is reposted
  func trackRepost(postURI: ATProtocolURI, target: FeedInteractionTarget?, feedContext: String? = nil) {
    sendInteraction(
      event: "app.bsky.feed.defs#interactionRepost",
      postURI: postURI,
      target: target,
      feedContext: feedContext
    )
  }

  /// Track when a user replies to a post
  func trackReply(postURI: ATProtocolURI, target: FeedInteractionTarget?, feedContext: String? = nil) {
    sendInteraction(
      event: "app.bsky.feed.defs#interactionReply",
      postURI: postURI,
      target: target,
      feedContext: feedContext
    )
  }

  /// Track when a user quotes a post
  func trackQuote(postURI: ATProtocolURI, target: FeedInteractionTarget?, feedContext: String? = nil) {
    sendInteraction(
      event: "app.bsky.feed.defs#interactionQuote",
      postURI: postURI,
      target: target,
      feedContext: feedContext
    )
  }

  // MARK: - Sending

  /// Schedule a throttled send of interactions. The first queued interaction starts
  /// the timer; later ones join that batch instead of postponing it.
  private func scheduleThrottledSend() {
    guard sendTimer == nil else { return }
    sendTimer = Timer.scheduledTimer(
      withTimeInterval: Self.sendThrottleInterval,
      repeats: false
    ) { [weak self] _ in
      Task { @MainActor in
        await self?.flushInteractions()
      }
    }
  }

  /// Immediately flush all queued interactions, one request per account and feed.
  /// Sends only while this account admits work and its client is still signed in as it.
  func flushInteractions() async {
    sendTimer?.invalidate()
    sendTimer = nil
    guard let operation = accountServiceWork.beginOperation() else { return }
    defer { accountServiceWork.endOperation(operation) }

    for destination in outbox.queuedDestinations {
      guard accountServiceWork.isCurrent(operation) else { break }
      await outbox.flush(destination) { [weak self] destination, interactions in
        guard let self else { throw DeliveryError.accountUnavailable }
        // The client's credentials may belong to another account by now; never send
        // one account's feedback under another's session.
        guard destination.accountDID == self.accountDID,
              self.accountServiceWork.isCurrent(operation),
              try await self.transport.authenticatedDID() == destination.accountDID,
              self.accountServiceWork.isCurrent(operation)
        else {
          self.logger.warning("Account changed before feedback could be sent to \(destination.target.generatorDID)")
          throw DeliveryError.accountUnavailable
        }
        do {
          try await self.transport.send(destination, interactions)
          self.logger.info("Sent \(interactions.count) interactions to feed generator \(destination.target.generatorDID)")
        } catch {
          self.logger.error("Error sending interactions to \(destination.target.generatorDID): \(error.localizedDescription)")
          throw error
        }
      }
    }
    // A feed with more than one request's worth of events sends the rest in the next batch.
    if !outbox.queuedDestinations.isEmpty, !accountServiceWork.isSuspended { scheduleThrottledSend() }
  }
}
