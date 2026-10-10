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
@available(iOS 26, macOS 26, *)
enum MetricKitSignposts {

  private static let lock = NSLock()

  // MARK: - Feed Loading

  private static var feedSignpostIDs: [String: OSSignpostID] = [:]

  /// Begins a feed loading signpost interval
  static func beginFeedLoad(feedName: String) {
    let log = MetricKitManager.feedLoadingLog
    let signpostID = OSSignpostID(log: log)
    lock.withLock {
      feedSignpostIDs[feedName] = signpostID
    }

    os_signpost(.begin, log: log, name: "FeedLoad", signpostID: signpostID)
  }

  /// Ends a feed loading signpost interval
  static func endFeedLoad(feedName: String, postCount: Int = 0, success: Bool = true) {
    let log = MetricKitManager.feedLoadingLog
    guard let signpostID = lock.withLock({ feedSignpostIDs.removeValue(forKey: feedName) }) else { return }

    os_signpost(.end, log: log, name: "FeedLoad", signpostID: signpostID)
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
    let log = MetricKitManager.imageLoadingLog
    let signpostID = OSSignpostID(log: log)
    lock.withLock {
      imageSignpostIDs[url] = signpostID
    }

    os_signpost(.begin, log: log, name: "ImageLoad", signpostID: signpostID)
  }

  /// Ends an image loading signpost interval
  static func endImageLoad(url: String, bytesLoaded: Int = 0, fromCache: Bool = false, success: Bool = true) {
    let log = MetricKitManager.imageLoadingLog
    guard let signpostID = lock.withLock({ imageSignpostIDs.removeValue(forKey: url) }) else { return }

    os_signpost(.end, log: log, name: "ImageLoad", signpostID: signpostID)
  }

  // MARK: - Network Requests

  private static var networkSignpostIDs: [String: OSSignpostID] = [:]

  /// Begins a network request signpost interval
  static func beginNetworkRequest(endpoint: String, method: String = "GET") {
    let log = MetricKitManager.networkRequestLog
    let signpostID = OSSignpostID(log: log)
    let key = "\(method):\(endpoint)"
    lock.withLock {
      networkSignpostIDs[key] = signpostID
    }

    os_signpost(.begin, log: log, name: "NetworkRequest", signpostID: signpostID)
  }

  /// Ends a network request signpost interval
  static func endNetworkRequest(endpoint: String, method: String = "GET", statusCode: Int = 200, bytesTransferred: Int = 0) {
    let log = MetricKitManager.networkRequestLog
    let key = "\(method):\(endpoint)"
    guard let signpostID = lock.withLock({ networkSignpostIDs.removeValue(forKey: key) }) else { return }

    os_signpost(.end, log: log, name: "NetworkRequest", signpostID: signpostID)
  }

  // MARK: - Authentication

  private static var authSignpostID: OSSignpostID?

  /// Begins an authentication signpost interval
  static func beginAuthentication(type: String) {
    let log = MetricKitManager.authenticationLog
    let signpostID = OSSignpostID(log: log)
    lock.withLock {
      authSignpostID = signpostID
    }

    os_signpost(.begin, log: log, name: "Authentication", signpostID: signpostID)
  }

  /// Ends an authentication signpost interval
  static func endAuthentication(success: Bool) {
    let log = MetricKitManager.authenticationLog
    guard let signpostID = lock.withLock({ () -> OSSignpostID? in
      let id = authSignpostID
      authSignpostID = nil
      return id
    }) else { return }

    os_signpost(.end, log: log, name: "Authentication", signpostID: signpostID)
  }

  // MARK: - Post Composer

  private static var composerSignpostID: OSSignpostID?

  /// Begins a post composition signpost interval
  static func beginPostComposition() {
    let log = MetricKitManager.composerLog
    let signpostID = OSSignpostID(log: log)
    lock.withLock {
      composerSignpostID = signpostID
    }

    os_signpost(.begin, log: log, name: "PostComposition", signpostID: signpostID)
  }

  /// Ends a post composition signpost interval
  static func endPostComposition(posted: Bool, mediaCount: Int = 0, characterCount: Int = 0) {
    let log = MetricKitManager.composerLog
    guard let signpostID = lock.withLock({ () -> OSSignpostID? in
      let id = composerSignpostID
      composerSignpostID = nil
      return id
    }) else { return }

    os_signpost(.end, log: log, name: "PostComposition", signpostID: signpostID)
  }

  // MARK: - Animation Tracking

  private static var animationSignpostIDs: [String: OSSignpostID] = [:]

  /// Begins an animation interval for hitch tracking
  static func beginAnimation(name: String) {
    let log = MetricKitManager.feedLoadingLog
    let signpostID = OSSignpostID(log: log)
    lock.withLock {
      animationSignpostIDs[name] = signpostID
    }

    os_signpost(.begin, log: log, name: "Animation", signpostID: signpostID)
  }

  /// Ends an animation interval
  static func endAnimation(name: String) {
    let log = MetricKitManager.feedLoadingLog
    guard let signpostID = lock.withLock({ animationSignpostIDs.removeValue(forKey: name) }) else { return }

    os_signpost(.end, log: log, name: "Animation", signpostID: signpostID)
  }

  // MARK: - Generic Event

  /// Logs a single signpost event (not an interval)
  static func event(category: String, name: StaticString, message: String = "") {
    let log = MetricKitManager.feedLoadingLog
    os_signpost(.event, log: log, name: name)
  }
}

// MARK: - Non-isolated Helpers

/// Thread-safe signpost helpers that can be called from any context
@available(iOS 26, macOS 26, *)
enum MetricKitSignpostsSync {
  
  /// Logs a network request event synchronously
  static func networkEvent(endpoint: String, statusCode: Int, duration: TimeInterval) {
    MetricKitSignposts.event(
      category: "Network",
      name: "RequestComplete",
      message: "\(endpoint) - \(statusCode) in \(String(format: "%.2f", duration * 1000))ms"
    )
  }

  /// Logs an error event synchronously
  static func errorEvent(category: String, message: String) {
    MetricKitSignposts.event(category: category, name: "Error", message: message)
  }
}
