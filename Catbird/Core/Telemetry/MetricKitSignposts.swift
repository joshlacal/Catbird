import Foundation
import MetricKit
import OSLog

/// MetricKitSignposts provides convenient signpost logging helpers for tracking
/// custom metrics throughout the Catbird app using MetricKit.
///
/// Usage:
/// ```swift
/// // Track a feed loading operation
/// MetricKitSignposts.beginFeedLoad(feedName: "Following")
/// // ... perform feed load ...
/// MetricKitSignposts.endFeedLoad(feedName: "Following", postCount: 50)
///
/// // Track with closure
/// let posts = await MetricKitSignposts.trackFeedLoad(feedName: "Following") {
///   await feedManager.loadFeed()
/// }
/// ```
@MainActor
enum MetricKitSignposts {
  
  // MARK: - Feed Loading
  
  private static var feedSignpostIDs: [String: OSSignpostID] = [:]
  
  /// Begins a feed loading signpost interval
  static func beginFeedLoad(feedName: String) {
    guard let log = MetricKitManager.shared.feedLoadingLog else { return }
    let signpostID = OSSignpostID(log: log)
    feedSignpostIDs[feedName] = signpostID
    
    mxSignpost(.begin, log: log, name: "FeedLoad", signpostID: signpostID)
  }
  
  /// Ends a feed loading signpost interval
  static func endFeedLoad(feedName: String, postCount: Int = 0, success: Bool = true) {
    guard let log = MetricKitManager.shared.feedLoadingLog,
          let signpostID = feedSignpostIDs.removeValue(forKey: feedName) else { return }
    
    mxSignpost(.end, log: log, name: "FeedLoad", signpostID: signpostID)
  }
  
  /// Tracks a feed loading operation with automatic begin/end signposts
  static func trackFeedLoad<T>(feedName: String, operation: () async throws -> T) async rethrows -> T {
    beginFeedLoad(feedName: feedName)
    do {
      let result = try await operation()
      endFeedLoad(feedName: feedName, success: true)
      return result
    } catch {
      endFeedLoad(feedName: feedName, success: false)
      throw error
    }
  }
  
  // MARK: - Image Loading
  
  private static var imageSignpostIDs: [String: OSSignpostID] = [:]
  
  /// Begins an image loading signpost interval
  static func beginImageLoad(url: String) {
    guard let log = MetricKitManager.shared.imageLoadingLog else { return }
    let signpostID = OSSignpostID(log: log)
    imageSignpostIDs[url] = signpostID
    
    mxSignpost(.begin, log: log, name: "ImageLoad", signpostID: signpostID)
  }
  
  /// Ends an image loading signpost interval
  static func endImageLoad(url: String, bytesLoaded: Int = 0, fromCache: Bool = false, success: Bool = true) {
    guard let log = MetricKitManager.shared.imageLoadingLog,
          let signpostID = imageSignpostIDs.removeValue(forKey: url) else { return }
    
    mxSignpost(.end, log: log, name: "ImageLoad", signpostID: signpostID)
  }
  
  // MARK: - Network Requests
  
  private static var networkSignpostIDs: [String: OSSignpostID] = [:]
  
  /// Begins a network request signpost interval
  static func beginNetworkRequest(endpoint: String, method: String = "GET") {
    guard let log = MetricKitManager.shared.networkRequestLog else { return }
    let signpostID = OSSignpostID(log: log)
    let key = "\(method):\(endpoint)"
    networkSignpostIDs[key] = signpostID
    
    mxSignpost(.begin, log: log, name: "NetworkRequest", signpostID: signpostID)
  }
  
  /// Ends a network request signpost interval
  static func endNetworkRequest(endpoint: String, method: String = "GET", statusCode: Int = 200, bytesTransferred: Int = 0) {
    guard let log = MetricKitManager.shared.networkRequestLog else { return }
    let key = "\(method):\(endpoint)"
    guard let signpostID = networkSignpostIDs.removeValue(forKey: key) else { return }
    
    mxSignpost(.end, log: log, name: "NetworkRequest", signpostID: signpostID)
  }
  
  // MARK: - Authentication
  
  private static var authSignpostID: OSSignpostID?
  
  /// Begins an authentication signpost interval
  static func beginAuthentication(type: String) {
    guard let log = MetricKitManager.shared.authenticationLog else { return }
    let signpostID = OSSignpostID(log: log)
    authSignpostID = signpostID
    
    mxSignpost(.begin, log: log, name: "Authentication", signpostID: signpostID)
  }
  
  /// Ends an authentication signpost interval
  static func endAuthentication(success: Bool) {
    guard let log = MetricKitManager.shared.authenticationLog,
          let signpostID = authSignpostID else { return }
    authSignpostID = nil
    
    mxSignpost(.end, log: log, name: "Authentication", signpostID: signpostID)
  }
  
  // MARK: - Post Composer
  
  private static var composerSignpostID: OSSignpostID?
  
  /// Begins a post composition signpost interval
  static func beginPostComposition() {
    guard let log = MetricKitManager.shared.composerLog else { return }
    let signpostID = OSSignpostID(log: log)
    composerSignpostID = signpostID
    
    mxSignpost(.begin, log: log, name: "PostComposition", signpostID: signpostID)
  }
  
  /// Ends a post composition signpost interval
  static func endPostComposition(posted: Bool, mediaCount: Int = 0, characterCount: Int = 0) {
    guard let log = MetricKitManager.shared.composerLog,
          let signpostID = composerSignpostID else { return }
    composerSignpostID = nil
    
    mxSignpost(.end, log: log, name: "PostComposition", signpostID: signpostID)
  }
  
  // MARK: - MLS Operations
  
  private static var mlsSignpostIDs: [String: OSSignpostID] = [:]
  
  /// Begins an MLS operation signpost interval
  static func beginMLSOperation(operation: String) {
    guard let log = MetricKitManager.shared.mlsOperationLog else { return }
    let signpostID = OSSignpostID(log: log)
    mlsSignpostIDs[operation] = signpostID
    
    mxSignpost(.begin, log: log, name: "MLSOperation", signpostID: signpostID)
  }
  
  /// Ends an MLS operation signpost interval
  static func endMLSOperation(operation: String, success: Bool = true) {
    guard let log = MetricKitManager.shared.mlsOperationLog,
          let signpostID = mlsSignpostIDs.removeValue(forKey: operation) else { return }
    
    mxSignpost(.end, log: log, name: "MLSOperation", signpostID: signpostID)
  }
  
  // MARK: - Animation Tracking
  
  private static var animationSignpostIDs: [String: OSSignpostID] = [:]
  
  /// Begins an animation interval for hitch tracking
  static func beginAnimation(name: String) {
    guard let log = MetricKitManager.shared.feedLoadingLog else { return }
    let signpostID = OSSignpostID(log: log)
    animationSignpostIDs[name] = signpostID
    
    // Use mxSignpostAnimationIntervalBegin for hitch ratio tracking
    mxSignpostAnimationIntervalBegin(log: log, name: "Animation", signpostID: signpostID)
  }
  
  /// Ends an animation interval
  static func endAnimation(name: String) {
    guard let log = MetricKitManager.shared.feedLoadingLog,
          let signpostID = animationSignpostIDs.removeValue(forKey: name) else { return }
    
    mxSignpost(.end, log: log, name: "Animation", signpostID: signpostID)
  }
  
  // MARK: - Generic Event
  
  /// Logs a single signpost event (not an interval)
  static func event(category: String, name: StaticString, message: String = "") {
    guard let log = MetricKitManager.shared.feedLoadingLog else { return }
    
    mxSignpost(.event, log: log, name: name)
  }
}

// MARK: - Non-isolated Helpers

/// Thread-safe signpost helpers that can be called from any context
enum MetricKitSignpostsSync {
  
  /// Logs a network request event synchronously
  static func networkEvent(endpoint: String, statusCode: Int, duration: TimeInterval) {
    Task { @MainActor in
      MetricKitSignposts.event(
        category: "Network",
        name: "RequestComplete",
        message: "\(endpoint) - \(statusCode) in \(String(format: "%.2f", duration * 1000))ms"
      )
    }
  }
  
  /// Logs an error event synchronously
  static func errorEvent(category: String, message: String) {
    Task { @MainActor in
      MetricKitSignposts.event(category: category, name: "Error", message: message)
    }
  }
}
