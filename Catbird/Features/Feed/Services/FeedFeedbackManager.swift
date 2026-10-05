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


/// Manages feed interaction feedback for custom feeds
@Observable
final class FeedFeedbackManager {
    
    private let logger = Logger(subsystem: "blue.catbird", category: "FeedFeedback")

  // MARK: - Properties
  
  /// Whether feedback is enabled for the current feed
  private(set) var isEnabled = false
  
  /// Current feed type being tracked
  private(set) var currentFeedType: FetchType?
  
  /// Interactions waiting to be sent, keyed by the feed generator DID they belong to,
  /// so reconfiguring for another feed never redirects queued items.
  private var interactionQueue: [String: Set<String>] = [:]
  
  /// History of sent interactions
  private var sentInteractions: Set<String> = []
  
  /// Timer for throttled sending
  private var sendTimer: Timer?
  
  /// AT Proto client for sending interactions
  private weak var client: ATProtoClient?
  
  /// Feed generator DID for proxying requests
  private var feedGeneratorDID: String?
  
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
  
  // MARK: - Configuration
  
  /// Configure the feedback manager for a specific feed
  @MainActor
  func configure(
    for feedType: FetchType,
    client: ATProtoClient?,
    feedGeneratorDID: String? = nil,
    canSendInteractions: Bool = false
  ) {
    // Only write observable properties when the value actually changes;
    // @Observable notifies on every assignment, and configure(for:) runs on every feed load.
    if currentFeedType != feedType {
      currentFeedType = feedType
    }
    self.client = client
    self.feedGeneratorDID = feedGeneratorDID
    
    // Enable feedback for custom feeds only (not timeline)
    let shouldEnable: Bool
    switch feedType {
    case .feed(let feed):
        // if can send interactions or is Discover feed
        if canSendInteractions || feed.uriString() == "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.generator/whats-hot" {
            shouldEnable = true
            logger.debug("FeedFeedback ENABLED for \(feedType.identifier) (canSend: \(canSendInteractions))")
        } else {
            shouldEnable = false
            logger.debug("FeedFeedback DISABLED for \(feedType.identifier) - interactions not accepted by generator")
        }
    case .timeline, .list, .author, .likes:
      shouldEnable = false
      logger.debug("FeedFeedback DISABLED for \(feedType.identifier) - not a custom feed")
    }
    if isEnabled != shouldEnable {
      isEnabled = shouldEnable
    }
  }
  
  /// Disable feedback and clear state
  @MainActor
  func disable() {
    if isEnabled {
      isEnabled = false
    }
    if currentFeedType != nil {
      currentFeedType = nil
    }
    feedGeneratorDID = nil
    
    // Flush any pending interactions before disabling
    Task {
      await flushInteractions()
    }
  }
  
  // MARK: - Interaction Tracking
  
  /// Send a "show more" interaction for a post
  func sendShowMore(postURI: ATProtocolURI, feedContext: String? = nil) {
    sendInteraction(
      event: "app.bsky.feed.defs#requestMore",
      postURI: postURI,
      feedContext: feedContext
    )
  }
  
  /// Send a "show less" interaction for a post
  func sendShowLess(postURI: ATProtocolURI, feedContext: String? = nil) {
    sendInteraction(
      event: "app.bsky.feed.defs#requestLess",
      postURI: postURI,
      feedContext: feedContext
    )
  }
  
  /// Send a generic interaction
  func sendInteraction(
    event: String,
    postURI: ATProtocolURI,
    feedContext: String? = nil,
    reqId: String? = nil
  ) {
    guard isEnabled else {
      logger.debug("Feedback disabled, ignoring interaction")
      return
    }
    
    // CRITICAL: We must have a feed generator DID to route interactions
    guard let feedGeneratorDID else {
      logger.debug("No feed generator DID available, cannot queue interaction")
      return
    }
    
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
    
    // Don't send duplicates
    guard !sentInteractions.contains(key) else {
      logger.debug("Interaction already sent, skipping")
      return
    }
    
    interactionQueue[feedGeneratorDID, default: []].insert(key)
    sentInteractions.insert(key)
    
    // Schedule throttled send
    scheduleThrottledSend()
    
    logger.debug("Queued interaction: \(event) for post \(postURI.uriString())")
  }
  
  /// Track when a post is seen
  func trackPostSeen(postURI: ATProtocolURI, feedContext: String? = nil) {
    sendInteraction(
      event: "app.bsky.feed.defs#interactionSeen",
      postURI: postURI,
      feedContext: feedContext
    )
  }
  
  /// Track when a post is liked
  func trackLike(postURI: ATProtocolURI, feedContext: String? = nil) {
    sendInteraction(
      event: "app.bsky.feed.defs#interactionLike",
      postURI: postURI,
      feedContext: feedContext
    )
  }
  
  /// Track when a post is reposted
  func trackRepost(postURI: ATProtocolURI, feedContext: String? = nil) {
    sendInteraction(
      event: "app.bsky.feed.defs#interactionRepost",
      postURI: postURI,
      feedContext: feedContext
    )
  }
  
  /// Track when a user replies to a post
  func trackReply(postURI: ATProtocolURI, feedContext: String? = nil) {
    sendInteraction(
      event: "app.bsky.feed.defs#interactionReply",
      postURI: postURI,
      feedContext: feedContext
    )
  }
  
  /// Track when a user quotes a post
  func trackQuote(postURI: ATProtocolURI, feedContext: String? = nil) {
    sendInteraction(
      event: "app.bsky.feed.defs#interactionQuote",
      postURI: postURI,
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
  
  /// Immediately flush all queued interactions
  @MainActor
  func flushInteractions() async {
    sendTimer?.invalidate()
    sendTimer = nil
    guard !interactionQueue.isEmpty else { return }
    guard let client = client else {
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
  
  deinit {
    sendTimer?.invalidate()
  }
}
