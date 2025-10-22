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
  
  /// Queue of interactions to send
  private var interactionQueue: Set<String> = []
  
  /// History of sent interactions (weak to avoid memory leaks)
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
  
  // MARK: - Initialization
  
  init() {}
  
  // MARK: - Configuration
  
  /// Configure the feedback manager for a specific feed
  func configure(
    for feedType: FetchType,
    client: ATProtoClient?,
    feedGeneratorDID: String? = nil,
    canSendInteractions: Bool = false
  ) {
    self.currentFeedType = feedType
    self.client = client
    self.feedGeneratorDID = feedGeneratorDID
    
    // Enable feedback for custom feeds only (not timeline)
    switch feedType {
    case .feed(let feed):
        // if can send interactions or is Discover feed
        if canSendInteractions || feed.uriString() == "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.generator/whats-hot" {
            isEnabled = true
        } else {
            isEnabled = false
        }
    case .timeline, .list, .author, .likes:
      isEnabled = false
    }
    
      logger.debug("FeedFeedback configured for \(feedType.identifier), enabled: \(self.isEnabled)")
  }
  
  /// Disable feedback and clear state
  func disable() {
    isEnabled = false
    currentFeedType = nil
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
    guard feedGeneratorDID != nil else {
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
    
    interactionQueue.insert(key)
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
  
  /// Schedule a throttled send of interactions
  private func scheduleThrottledSend() {
    // Cancel existing timer
    sendTimer?.invalidate()
    
    // Create new timer
    sendTimer = Timer.scheduledTimer(
      withTimeInterval: Self.sendThrottleInterval,
      repeats: false
    ) { [weak self] _ in
      Task {
        await self?.flushInteractions()
      }
    }
  }
  
  /// Immediately flush all queued interactions
  func flushInteractions() async {
    guard !interactionQueue.isEmpty else { return }
    guard let client = client else {
      logger.warning("No client available to send interactions")
      return
    }
    
    // CRITICAL: We must have a feed generator DID to route the request
    guard let feedDID = feedGeneratorDID else {
        logger.warning("No feed generator DID available, cannot send interactions. Discarding \(self.interactionQueue.count) queued interactions.")
      interactionQueue.removeAll()
      return
    }
    
    let interactions = interactionQueue.map { parseInteractionKey($0) }
    interactionQueue.removeAll()
    
    do {
      let input = AppBskyFeedSendInteractions.Input(interactions: interactions)
      
      // Set the atproto-proxy header to route request to the feed generator
      // Format: {feedGeneratorDID}#bsky_fg
      await client.setHeader(name: "atproto-proxy", value: "\(feedDID)#bsky_fg")
      
      // Send the interactions
      let (responseCode, _) = try await client.app.bsky.feed.sendInteractions(input: input)
      
      // CRITICAL: Remove the proxy header after the request to prevent header pollution
      await client.removeHeader(name: "atproto-proxy")
      
      if responseCode == 200 {
        logger.info("Successfully sent \(interactions.count) interactions to feed generator \(feedDID)")
      } else {
        logger.warning("Failed to send interactions to \(feedDID), status code: \(responseCode)")
      }
    } catch {
      // Make sure to remove the proxy header even on error
      await client.removeHeader(name: "atproto-proxy")
      logger.error("Error sending interactions to \(feedDID): \(error.localizedDescription)")
    }
  }
  
  deinit {
    sendTimer?.invalidate()
    
    // Try to flush on deinit (best effort)
    Task {
      await flushInteractions()
    }
  }
}
