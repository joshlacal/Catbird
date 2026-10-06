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


/// Queues and sends feed interaction feedback. Every interaction names the feed
/// it belongs to, so nothing depends on which feed loaded or appeared last.
@MainActor
final class FeedFeedbackManager {
    
    private let logger = Logger(subsystem: "blue.catbird", category: "FeedFeedback")

  // MARK: - Properties
  
  /// Interactions waiting to be sent, keyed by the feed generator DID they belong to.
  private var interactionQueue: [String: Set<String>] = [:]
  
  /// History of sent interactions, keyed by generator DID plus interaction key
  private var sentInteractions: Set<String> = []
  
  /// Timer for throttled sending
  private var sendTimer: Timer?
  
  /// Supplies the signed-in account's AT Proto client when a batch is sent
  private let clientProvider: @MainActor () -> ATProtoClient?
  
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
  
  /// Throttle interval for sending interactions (10 seconds)
  private static let sendThrottleInterval: TimeInterval = 10.0
  
  init(clientProvider: @escaping @MainActor () -> ATProtoClient?) {
    self.clientProvider = clientProvider
  }
  
  // MARK: - Interaction Tracking
  
  /// Send a "show more" interaction for a post
  func sendShowMore(postURI: ATProtocolURI, target: FeedInteractionTarget?, feedContext: String? = nil) {
    sendInteraction(
      event: "app.bsky.feed.defs#requestMore",
      postURI: postURI,
      target: target,
      feedContext: feedContext
    )
  }
  
  /// Send a "show less" interaction for a post
  func sendShowLess(postURI: ATProtocolURI, target: FeedInteractionTarget?, feedContext: String? = nil) {
    sendInteraction(
      event: "app.bsky.feed.defs#requestLess",
      postURI: postURI,
      target: target,
      feedContext: feedContext
    )
  }
  
  /// Queue an interaction for the feed generator behind `target`.
  /// A nil target means the post is not being shown in a feed that accepts feedback.
  func sendInteraction(
    event: String,
    postURI: ATProtocolURI,
    target: FeedInteractionTarget?,
    feedContext: String? = nil,
    reqId: String? = nil
  ) {
    guard let target else { return }
    
    guard Self.allowedThirdPartyInteractions.contains(event) else {
      logger.warning("Interaction event not allowed: \(event)")
      return
    }
    
    let key = interactionKey(
      postURI: postURI,
      event: event,
      feedContext: feedContext,
      reqId: reqId
    )
    let historyKey = "\(target.generatorDID)|\(key)"
    
    // Don't send duplicates
    guard !sentInteractions.contains(historyKey) else {
      logger.debug("Interaction already sent, skipping")
      return
    }
    
    interactionQueue[target.generatorDID, default: []].insert(key)
    sentInteractions.insert(historyKey)
    
    // Schedule throttled send
    scheduleThrottledSend()
    
    logger.debug("Queued interaction: \(event) for post \(postURI.uriString()) in feed \(target.feedURI)")
  }
  
  /// Track when a post is seen
  func trackPostSeen(postURI: ATProtocolURI, target: FeedInteractionTarget?, feedContext: String? = nil) {
    sendInteraction(
      event: "app.bsky.feed.defs#interactionSeen",
      postURI: postURI,
      target: target,
      feedContext: feedContext
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
  
  // MARK: - Private Methods
  
  /// Generate a unique key for an interaction
  private func interactionKey(
    postURI: ATProtocolURI,
    event: String,
    feedContext: String?,
    reqId: String?
  ) -> String {
    return "\(postURI.uriString())|\(event)|\(feedContext ?? "")|\(reqId ?? "")"
  }
  
  /// Parse an interaction key back into components
  private func parseInteractionKey(_ key: String) -> AppBskyFeedDefs.Interaction {
    let components = key.split(separator: "|").map(String.init)
    return AppBskyFeedDefs.Interaction(
      item: try? ATProtocolURI(uriString: components[0]),
      event: components.count > 1 ? components[1] : nil,
      feedContext: components.count > 2 && !components[2].isEmpty ? components[2] : nil,
      reqId: components.count > 3 && !components[3].isEmpty ? components[3] : nil
    )
  }
  
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
  
  /// Immediately flush all queued interactions, one request per feed generator
  func flushInteractions() async {
    sendTimer?.invalidate()
    sendTimer = nil
    guard !interactionQueue.isEmpty else { return }
    guard let client = clientProvider() else {
      logger.warning("No client available to send interactions")
      return
    }
    
    let batches = interactionQueue
    interactionQueue.removeAll()
    
    for (feedDID, keys) in batches where !keys.isEmpty {
      let interactions = keys.map { parseInteractionKey($0) }
      do {
        // Route this request alone to the feed generator ({feedGeneratorDID}#bsky_fg).
        // A per-request proxy header overrides the client's default service
        // routing without leaking into concurrent requests.
        let input = AppBskyFeedSendInteractions.Input(interactions: interactions)
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
          additionalHeaders: ["atproto-proxy": "\(feedDID)#bsky_fg"]
        )
        
        if (200...299).contains(response.statusCode) {
          logger.info("Successfully sent \(interactions.count) interactions to feed generator \(feedDID)")
        } else {
          logger.warning("Failed to send interactions to \(feedDID), status code: \(response.statusCode)")
        }
      } catch {
        logger.error("Error sending interactions to \(feedDID): \(error.localizedDescription)")
      }
    }
  }
}
