//
//  PerformanceSignposts.swift
//  Catbird
//
//  Performance instrumentation using os_signpost for Instruments visibility.
//  These signposts appear in Time Profiler and custom instruments templates.
//

import Foundation
import OSLog

/// Performance signposts for Instruments tracing.
/// Use these for development profiling - they appear in Time Profiler traces.
///
/// Usage:
/// ```swift
/// // Interval tracking
/// let id = PerformanceSignposts.beginCellConfiguration(postId: "abc123")
/// // ... configure cell ...
/// PerformanceSignposts.endCellConfiguration(id: id)
///
/// // Or use the closure-based API
/// PerformanceSignposts.trackCellConfiguration(postId: "abc123") {
///   configureCell()
/// }
/// ```
enum PerformanceSignposts {
  
  // MARK: - Subsystem & Categories
  
  private static let subsystem = "blue.catbird.performance"
  
  private static let feedLog = OSLog(subsystem: subsystem, category: "Feed")
  private static let cellLog = OSLog(subsystem: subsystem, category: "Cell")
  private static let imageLog = OSLog(subsystem: subsystem, category: "Image")
  private static let navigationLog = OSLog(subsystem: subsystem, category: "Navigation")
  private static let mlsLog = OSLog(subsystem: subsystem, category: "MLS")
  private static let networkLog = OSLog(subsystem: subsystem, category: "Network")
  private static let threadLog = OSLog(subsystem: subsystem, category: "Thread")
  
  // MARK: - Signpost ID Tracking
  
  /// Thread-safe signpost ID generator
  private static let signpostIDCounter = OSAllocatedUnfairLock(initialState: UInt64(0))
  
  private static func nextID() -> OSSignpostID {
    signpostIDCounter.withLock { counter in
      counter += 1
      return OSSignpostID(counter)
    }
  }
  
  // MARK: - Feed Operations
  
  static func beginFeedLoad(feedName: String) -> OSSignpostID {
    let id = nextID()
    os_signpost(.begin, log: feedLog, name: "FeedLoad", signpostID: id, "%{public}s", feedName)
    return id
  }
  
  static func endFeedLoad(id: OSSignpostID, postCount: Int, success: Bool) {
    os_signpost(.end, log: feedLog, name: "FeedLoad", signpostID: id, "posts: %d, success: %d", postCount, success ? 1 : 0)
  }
  
  static func trackFeedLoad<T>(feedName: String, _ operation: () async throws -> T) async rethrows -> T {
    let id = beginFeedLoad(feedName: feedName)
    do {
      let result = try await operation()
      endFeedLoad(id: id, postCount: 0, success: true)
      return result
    } catch {
      endFeedLoad(id: id, postCount: 0, success: false)
      throw error
    }
  }
  
  // MARK: - Cell Configuration
  
  static func beginCellConfiguration(postId: String) -> OSSignpostID {
    let id = nextID()
    os_signpost(.begin, log: cellLog, name: "CellConfig", signpostID: id, "%{public}s", postId)
    return id
  }
  
  static func endCellConfiguration(id: OSSignpostID) {
    os_signpost(.end, log: cellLog, name: "CellConfig", signpostID: id)
  }
  
  @inline(__always)
  static func trackCellConfiguration<T>(postId: String, _ operation: () -> T) -> T {
    let id = beginCellConfiguration(postId: postId)
    defer { endCellConfiguration(id: id) }
    return operation()
  }
  
  // MARK: - Image Loading
  
  static func beginImageLoad(url: String) -> OSSignpostID {
    let id = nextID()
    os_signpost(.begin, log: imageLog, name: "ImageLoad", signpostID: id, "%{public}s", url)
    return id
  }
  
  static func endImageLoad(id: OSSignpostID, fromCache: Bool, bytesLoaded: Int) {
    os_signpost(.end, log: imageLog, name: "ImageLoad", signpostID: id, "cache: %d, bytes: %d", fromCache ? 1 : 0, bytesLoaded)
  }
  
  static func imageCacheHit(url: String) {
    os_signpost(.event, log: imageLog, name: "CacheHit", "%{public}s", url)
  }
  
  static func imageCacheMiss(url: String) {
    os_signpost(.event, log: imageLog, name: "CacheMiss", "%{public}s", url)
  }
  
  // MARK: - Navigation
  
  private static var navigationStack: [OSSignpostID] = []
  
  static func beginNavigation(destination: String) -> OSSignpostID {
    let id = nextID()
    os_signpost(.begin, log: navigationLog, name: "Navigation", signpostID: id, "push: %{public}s", destination)
    return id
  }
  
  static func endNavigation(id: OSSignpostID) {
    os_signpost(.end, log: navigationLog, name: "Navigation", signpostID: id)
  }
  
  static func tabSwitch(from: String, to: String) {
    os_signpost(.event, log: navigationLog, name: "TabSwitch", "%{public}s -> %{public}s", from, to)
  }
  
  // MARK: - Thread View
  
  static func beginThreadLoad(postId: String) -> OSSignpostID {
    let id = nextID()
    os_signpost(.begin, log: threadLog, name: "ThreadLoad", signpostID: id, "%{public}s", postId)
    return id
  }
  
  static func endThreadLoad(id: OSSignpostID, replyCount: Int) {
    os_signpost(.end, log: threadLog, name: "ThreadLoad", signpostID: id, "replies: %d", replyCount)
  }
  
  // MARK: - MLS Operations
  
  static func beginMLSOperation(_ operation: String) -> OSSignpostID {
    let id = nextID()
    os_signpost(.begin, log: mlsLog, name: "MLSOperation", signpostID: id, "%{public}s", operation)
    return id
  }
  
  static func endMLSOperation(id: OSSignpostID, success: Bool) {
    os_signpost(.end, log: mlsLog, name: "MLSOperation", signpostID: id, "success: %d", success ? 1 : 0)
  }
  
  static func beginMLSDecrypt(messageCount: Int) -> OSSignpostID {
    let id = nextID()
    os_signpost(.begin, log: mlsLog, name: "MLSDecrypt", signpostID: id, "messages: %d", messageCount)
    return id
  }
  
  static func endMLSDecrypt(id: OSSignpostID, decryptedCount: Int) {
    os_signpost(.end, log: mlsLog, name: "MLSDecrypt", signpostID: id, "decrypted: %d", decryptedCount)
  }
  
  static func beginMLSEncrypt() -> OSSignpostID {
    let id = nextID()
    os_signpost(.begin, log: mlsLog, name: "MLSEncrypt", signpostID: id)
    return id
  }
  
  static func endMLSEncrypt(id: OSSignpostID) {
    os_signpost(.end, log: mlsLog, name: "MLSEncrypt", signpostID: id)
  }
  
  // MARK: - Network
  
  static func beginNetworkRequest(endpoint: String, method: String) -> OSSignpostID {
    let id = nextID()
    os_signpost(.begin, log: networkLog, name: "NetworkRequest", signpostID: id, "%{public}s %{public}s", method, endpoint)
    return id
  }
  
  static func endNetworkRequest(id: OSSignpostID, statusCode: Int, bytesReceived: Int) {
    os_signpost(.end, log: networkLog, name: "NetworkRequest", signpostID: id, "status: %d, bytes: %d", statusCode, bytesReceived)
  }
  
  // MARK: - Scroll Performance
  
  static func beginScroll() -> OSSignpostID {
    let id = nextID()
    os_signpost(.begin, log: feedLog, name: "Scroll", signpostID: id)
    return id
  }
  
  static func endScroll(id: OSSignpostID) {
    os_signpost(.end, log: feedLog, name: "Scroll", signpostID: id)
  }
  
  static func scrollFrame(fps: Double) {
    os_signpost(.event, log: feedLog, name: "ScrollFrame", "fps: %.1f", fps)
  }
  
  // MARK: - App Launch
  
  static func appLaunchMilestone(_ milestone: String) {
    os_signpost(.event, log: feedLog, name: "LaunchMilestone", "%{public}s", milestone)
  }
  
  // MARK: - Batch Operations (for N+1 detection)
  
  private static let batchLog = OSLog(subsystem: subsystem, category: "Batch")
  
  /// Begin tracking a batch operation (parallel API calls)
  static func beginBatchOperation(_ operation: String, count: Int) -> OSSignpostID {
    let id = nextID()
    os_signpost(.begin, log: batchLog, name: "BatchOperation", signpostID: id, "%{public}s count: %d", operation, count)
    return id
  }
  
  /// End tracking a batch operation
  static func endBatchOperation(id: OSSignpostID, successCount: Int, failureCount: Int) {
    os_signpost(.end, log: batchLog, name: "BatchOperation", signpostID: id, "success: %d, failed: %d", successCount, failureCount)
  }
}

// MARK: - Convenience Extensions

extension PerformanceSignposts {
  
  /// Track an async operation with automatic signpost begin/end
  static func track<T>(
    name: StaticString,
    log: OSLog = OSLog(subsystem: "blue.catbird.performance", category: "General"),
    _ operation: () async throws -> T
  ) async rethrows -> T {
    let id = nextID()
    os_signpost(.begin, log: log, name: name, signpostID: id)
    do {
      let result = try await operation()
      os_signpost(.end, log: log, name: name, signpostID: id)
      return result
    } catch {
      os_signpost(.end, log: log, name: name, signpostID: id)
      throw error
    }
  }
  
  /// Track a synchronous operation with automatic signpost begin/end
  @inline(__always)
  static func trackSync<T>(
    name: StaticString,
    log: OSLog = OSLog(subsystem: "blue.catbird.performance", category: "General"),
    _ operation: () throws -> T
  ) rethrows -> T {
    let id = nextID()
    os_signpost(.begin, log: log, name: name, signpostID: id)
    defer { os_signpost(.end, log: log, name: name, signpostID: id) }
    return try operation()
  }
}
