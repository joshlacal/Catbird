import Foundation
import OSLog
import Petrel

/// Events that can trigger state invalidation across the app
enum StateInvalidationEvent {
  case postCreated(AppBskyFeedDefs.PostView)
  case replyCreated(AppBskyFeedDefs.PostView, parentUri: String)
  case postLiked(uri: String)
  case postUnliked(uri: String)
  case postReposted(uri: String)
  case postUnreposted(uri: String)
  case accountSwitched
  case authenticationCompleted  // Fired when authentication becomes available
  case feedUpdated(FetchType)
  case profileUpdated(did: String)
  case threadUpdated(rootUri: String)
  case chatMessageReceived
  case notificationsUpdated
  case feedListChanged  // New event for when feeds are added/removed
}

/// Central event bus for coordinating state invalidation across the app
/// This solves the core issue where views don't refresh after mutations
final class StateInvalidationBus {
  // MARK: - Properties
  
  private let logger = Logger(OSLog.stateInvalidation)
  
  /// Subscribers to state invalidation events
  private var subscribers: [StateInvalidationSubscriber] = []
  
  /// Event history for debugging (keep last 50 events)
  private var eventHistory: [StateInvalidationEvent] = []
  private let maxHistorySize = 50
  
  /// Throttling to prevent overeager invalidation
  private var lastEventTimes: [String: Date] = [:]
  private let throttleInterval: TimeInterval = 0.5 // 500ms throttle
  
  // MARK: - Subscription Management
  
  /// Subscribe to state invalidation events
  func subscribe(_ subscriber: StateInvalidationSubscriber) {
    subscribers.append(subscriber)
    logger.debug("New subscriber added: \(type(of: subscriber))")
  }
  
  /// Unsubscribe from state invalidation events
  func unsubscribe(_ subscriber: StateInvalidationSubscriber) {
    subscribers.removeAll { $0 === subscriber }
    logger.debug("Subscriber removed: \(type(of: subscriber))")
  }
  
  // MARK: - Event Broadcasting
  
  /// Notify all subscribers of a state invalidation event
  @MainActor
  func notify(_ event: StateInvalidationEvent) {
    let eventKey = self.eventKey(event)
    let now = Date()
    
    // Check if we should throttle this event
    if let lastTime = lastEventTimes[eventKey],
       now.timeIntervalSince(lastTime) < throttleInterval {
      logger.debug("Throttling event: \(self.eventDescription(event)) (last fired \(String(format: "%.3f", now.timeIntervalSince(lastTime)))s ago)")
      return
    }
    
    lastEventTimes[eventKey] = now
    logger.info("Broadcasting event: \(self.eventDescription(event))")
    
    // Add to history
    eventHistory.append(event)
    if eventHistory.count > maxHistorySize {
      eventHistory.removeFirst()
    }
    
    // Only notify subscribers that are interested in this event
    var interestedCount = 0
    for subscriber in subscribers {
      if subscriber.isInterestedIn(event) {
        interestedCount += 1
        Task { @MainActor in
          await subscriber.handleStateInvalidation(event)
        }
      }
    }
    
    logger.debug("Event broadcast to \(interestedCount) of \(self.subscribers.count) subscribers")
  }
  
  // MARK: - Convenience Methods
  
  /// Convenience method for post creation events
  @MainActor
  func notifyPostCreated(_ post: AppBskyFeedDefs.PostView) {
    notify(.postCreated(post))
  }
  
  /// Convenience method for reply creation events
  @MainActor
  func notifyReplyCreated(_ reply: AppBskyFeedDefs.PostView, parentUri: String) {
    notify(.replyCreated(reply, parentUri: parentUri))
  }
  
  /// Convenience method for account switching
  @MainActor
  func notifyAccountSwitched() {
    notify(.accountSwitched)
  }
  
  /// Convenience method for authentication completion
  @MainActor
  func notifyAuthenticationCompleted() {
    notify(.authenticationCompleted)
  }
  
  /// Convenience method for feed updates
  @MainActor
  func notifyFeedUpdated(_ fetchType: FetchType) {
    notify(.feedUpdated(fetchType))
  }
  
  /// Convenience method for profile updates
  @MainActor
  func notifyProfileUpdated(_ did: String) {
    notify(.profileUpdated(did: did))
  }
  
  /// Convenience method for thread updates
  @MainActor
  func notifyThreadUpdated(_ rootUri: String) {
    notify(.threadUpdated(rootUri: rootUri))
  }
  
  // MARK: - Debugging
  
  /// Get recent event history for debugging
  func getEventHistory() -> [StateInvalidationEvent] {
    return eventHistory
  }
  
  /// Get current subscriber count
  var subscriberCount: Int {
    return subscribers.count
  }
  
  /// Clear event history
  func clearHistory() {
    eventHistory.removeAll()
    logger.debug("Event history cleared")
  }
  
  /// Clear throttle cache (useful for testing)
  func clearThrottleCache() {
    lastEventTimes.removeAll()
    logger.debug("Throttle cache cleared")
  }
  
  // MARK: - Private Helpers
  
  /// Generate a key for throttling similar events
  private func eventKey(_ event: StateInvalidationEvent) -> String {
    switch event {
    case .postCreated:
      return "postCreated"
    case .replyCreated:
      return "replyCreated"
    case .postLiked:
      return "postLiked"
    case .postUnliked:
      return "postUnliked"
    case .postReposted:
      return "postReposted"
    case .postUnreposted:
      return "postUnreposted"
    case .accountSwitched:
      return "accountSwitched"
    case .authenticationCompleted:
      return "authenticationCompleted"
    case .feedUpdated(let fetchType):
      return "feedUpdated_\(fetchType.identifier)"
    case .profileUpdated(let did):
      return "profileUpdated_\(did)"
    case .threadUpdated(let rootUri):
      return "threadUpdated_\(rootUri)"
    case .chatMessageReceived:
      return "chatMessageReceived"
    case .notificationsUpdated:
      return "notificationsUpdated"
    case .feedListChanged:
      return "feedListChanged"
    }
  }
  
  private func eventDescription(_ event: StateInvalidationEvent) -> String {
    switch event {
    case .postCreated(let post):
      return "postCreated(uri: \(post.uri))"
    case .replyCreated(let reply, let parentUri):
      return "replyCreated(uri: \(reply.uri), parent: \(parentUri))"
    case .postLiked(let uri):
      return "postLiked(uri: \(uri))"
    case .postUnliked(let uri):
      return "postUnliked(uri: \(uri))"
    case .postReposted(let uri):
      return "postReposted(uri: \(uri))"
    case .postUnreposted(let uri):
      return "postUnreposted(uri: \(uri))"
    case .accountSwitched:
      return "accountSwitched"
    case .authenticationCompleted:
      return "authenticationCompleted"
    case .feedUpdated(let fetchType):
      return "feedUpdated(type: \(fetchType.identifier))"
    case .profileUpdated(let did):
      return "profileUpdated(did: \(did))"
    case .threadUpdated(let rootUri):
      return "threadUpdated(root: \(rootUri))"
    case .chatMessageReceived:
      return "chatMessageReceived"
    case .notificationsUpdated:
      return "notificationsUpdated"
    case .feedListChanged:
      return "feedListChanged"
    }
  }
}

/// Protocol for objects that want to receive state invalidation events
protocol StateInvalidationSubscriber: AnyObject {
  /// Handle a state invalidation event
  func handleStateInvalidation(_ event: StateInvalidationEvent) async
  
  /// Check if this subscriber is interested in a specific event
  /// Default implementation returns true for backward compatibility
  func isInterestedIn(_ event: StateInvalidationEvent) -> Bool
}

/// Default implementation that maintains backward compatibility
extension StateInvalidationSubscriber {
  func isInterestedIn(_ event: StateInvalidationEvent) -> Bool {
    return true // By default, receive all events (current behavior)
  }
}

/// Extension to add debugging capabilities
extension StateInvalidationBus {
  /// Generate a debug report of the current state
  func generateDebugReport() -> String {
    var report = "=== StateInvalidationBus Debug Report ===\n"
    report += "Subscribers: \(subscriberCount)\n"
    report += "Recent Events (\(eventHistory.count)):\n"
    
    for (index, event) in eventHistory.enumerated() {
      report += "  \(index + 1). \(eventDescription(event))\n"
    }
    
    return report
  }
}
