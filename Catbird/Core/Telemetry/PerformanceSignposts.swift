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
  
  // MARK: - Subsystem & Signposters
  
  private static let subsystem = "blue.catbird.performance"
  
  private static let intervalsSignposter = OSSignposter(subsystem: subsystem, category: "Intervals")
  private static let feedSignposter = OSSignposter(subsystem: subsystem, category: "Feed")
  private static let chatSignposter = OSSignposter(subsystem: subsystem, category: "Chat")
  private static let listSignposter = OSSignposter(subsystem: subsystem, category: "List")
  private static let profileSignposter = OSSignposter(subsystem: subsystem, category: "Profile")
  private static let notificationsSignposter = OSSignposter(subsystem: subsystem, category: "Notifications")
  private static let cellSignposter = OSSignposter(subsystem: subsystem, category: "Cell")
  private static let imageSignposter = OSSignposter(subsystem: subsystem, category: "Image")
  private static let navigationSignposter = OSSignposter(subsystem: subsystem, category: "Navigation")
  private static let networkSignposter = OSSignposter(subsystem: subsystem, category: "Network")
  private static let threadSignposter = OSSignposter(subsystem: subsystem, category: "Thread")
  private static let batchSignposter = OSSignposter(subsystem: subsystem, category: "Batch")
  
  // MARK: - App Surface Comparison
  
  enum AppSurface: String, CaseIterable {
    case feed = "Feed"
    case chat = "Chat"
    case list = "List"
    case profile = "Profile"
    case notifications = "Notifications"
  }
  
  private static func appSurfaceSignposter(for surface: AppSurface) -> OSSignposter {
    switch surface {
    case .feed:
      feedSignposter
    case .chat:
      chatSignposter
    case .list:
      listSignposter
    case .profile:
      profileSignposter
    case .notifications:
      notificationsSignposter
    }
  }
  
  static func beginAppSurfaceLoad(_ surface: AppSurface, context: String) -> OSSignpostID {
    let signposter = appSurfaceSignposter(for: surface)
    guard signposter.isEnabled else { return .null }
    let id = signposter.makeSignpostID()
    _ = signposter.beginInterval("SurfaceLoad", id: id, "\(context, privacy: .public)")
    return id
  }
  
  static func endAppSurfaceLoad(_ surface: AppSurface, id: OSSignpostID, itemCount: Int, success: Bool) {
    let signposter = appSurfaceSignposter(for: surface)
    guard signposter.isEnabled, id != .null else { return }
    signposter.endInterval("SurfaceLoad", OSSignpostIntervalState.beginState(id: id), "items: \(itemCount, privacy: .public), success: \(success ? 1 : 0)")
  }
  
  static func trackAppSurfaceLoad<T>(
    _ surface: AppSurface,
    context: String,
    _ operation: () async throws -> T
  ) async rethrows -> T {
    let signposter = appSurfaceSignposter(for: surface)
    guard signposter.isEnabled else { return try await operation() }
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval("SurfaceLoad", id: id, "\(context, privacy: .public)")
    do {
      let result = try await operation()
      signposter.endInterval("SurfaceLoad", state, "items: 0, success: 1")
      return result
    } catch {
      signposter.endInterval("SurfaceLoad", state, "items: 0, success: 0")
      throw error
    }
  }
  
  // MARK: - Feed Operations
  
  static func beginFeedLoad(feedName: String) -> OSSignpostID {
    guard feedSignposter.isEnabled else { return .null }
    let id = feedSignposter.makeSignpostID()
    _ = feedSignposter.beginInterval("FeedLoad", id: id, "\(feedName, privacy: .public)")
    return id
  }
  
  static func endFeedLoad(id: OSSignpostID, postCount: Int, success: Bool) {
    guard feedSignposter.isEnabled, id != .null else { return }
    feedSignposter.endInterval("FeedLoad", OSSignpostIntervalState.beginState(id: id), "posts: \(postCount, privacy: .public), success: \(success ? 1 : 0)")
  }
  
  static func trackFeedLoad<T>(feedName: String, _ operation: () async throws -> T) async rethrows -> T {
    guard feedSignposter.isEnabled else { return try await operation() }
    let id = feedSignposter.makeSignpostID()
    let state = feedSignposter.beginInterval("FeedLoad", id: id, "\(feedName, privacy: .public)")
    do {
      let result = try await operation()
      feedSignposter.endInterval("FeedLoad", state, "posts: 0, success: 1")
      return result
    } catch {
      feedSignposter.endInterval("FeedLoad", state, "posts: 0, success: 0")
      throw error
    }
  }
  
  // MARK: - Cell Configuration
  
  /// Aggregate feed work only: never include account IDs, post IDs, or content.
  static func beginFeedPreparation(itemCount: Int) -> OSSignpostID {
    guard feedSignposter.isEnabled else { return .null }
    let id = feedSignposter.makeSignpostID()
    _ = feedSignposter.beginInterval("FeedPreparation", id: id, "items: \(itemCount, privacy: .public), main_thread: \(Thread.isMainThread ? 1 : 0)")
    return id
  }
  
  static func endFeedPreparation(id: OSSignpostID, itemCount: Int) {
    guard feedSignposter.isEnabled, id != .null else { return }
    feedSignposter.endInterval("FeedPreparation", OSSignpostIntervalState.beginState(id: id), "items: \(itemCount, privacy: .public), main_thread: \(Thread.isMainThread ? 1 : 0)")
  }
  
  static func beginFeedSnapshot(itemCount: Int, reconfiguredCount: Int) -> OSSignpostID {
    guard feedSignposter.isEnabled else { return .null }
    let id = feedSignposter.makeSignpostID()
    _ = feedSignposter.beginInterval("FeedSnapshot", id: id, "items: \(itemCount, privacy: .public), reconfigured: \(reconfiguredCount, privacy: .public)")
    return id
  }
  
  /// Offset and size deltas explain layout movement separately from CPU duration.
  /// A missing anchor is represented explicitly instead of reporting a false zero.
  static func endFeedSnapshot(
    id: OSSignpostID,
    offsetDelta: Double,
    heightDelta: Double,
    anchorDeltaBeforeRestore: Double?,
    anchorDeltaAfterRestore: Double?
  ) {
    guard feedSignposter.isEnabled, id != .null else { return }
    feedSignposter.endInterval(
      "FeedSnapshot",
      OSSignpostIntervalState.beginState(id: id),
      "offset_delta: \(offsetDelta), height_delta: \(heightDelta), anchor_before_restore: \(anchorDeltaBeforeRestore ?? 0), anchor_after_restore: \(anchorDeltaAfterRestore ?? 0), has_before: \(anchorDeltaBeforeRestore == nil ? 0 : 1), has_after: \(anchorDeltaAfterRestore == nil ? 0 : 1)"
    )
  }
  
  static func beginCellConfiguration(postId: String) -> OSSignpostID {
    guard cellSignposter.isEnabled else { return .null }
    let id = cellSignposter.makeSignpostID()
    _ = cellSignposter.beginInterval("CellConfig", id: id)
    return id
  }
  
  static func endCellConfiguration(id: OSSignpostID) {
    guard cellSignposter.isEnabled, id != .null else { return }
    cellSignposter.endInterval("CellConfig", OSSignpostIntervalState.beginState(id: id))
  }
  
  @inline(__always)
  static func trackCellConfiguration<T>(postId: String, _ operation: () -> T) -> T {
    guard cellSignposter.isEnabled else { return operation() }
    let id = cellSignposter.makeSignpostID()
    let state = cellSignposter.beginInterval("CellConfig", id: id)
    defer { cellSignposter.endInterval("CellConfig", state) }
    return operation()
  }
  
  // MARK: - Image Loading
  
  static func beginImageLoad(url: String) -> OSSignpostID {
    guard imageSignposter.isEnabled else { return .null }
    let id = imageSignposter.makeSignpostID()
    _ = imageSignposter.beginInterval("ImageLoad", id: id)
    return id
  }
  
  static func endImageLoad(id: OSSignpostID, fromCache: Bool, bytesLoaded: Int) {
    guard imageSignposter.isEnabled, id != .null else { return }
    imageSignposter.endInterval("ImageLoad", OSSignpostIntervalState.beginState(id: id), "cache: \(fromCache ? 1 : 0), bytes: \(bytesLoaded)")
  }
  
  static func imageCacheHit(url: String) {
    guard imageSignposter.isEnabled else { return }
    imageSignposter.emitEvent("CacheHit")
  }
  
  static func imageCacheMiss(url: String) {
    guard imageSignposter.isEnabled else { return }
    imageSignposter.emitEvent("CacheMiss")
  }
  
  // MARK: - Navigation
  
  static func beginNavigation(destination: String) -> OSSignpostID {
    guard navigationSignposter.isEnabled else { return .null }
    let id = navigationSignposter.makeSignpostID()
    _ = navigationSignposter.beginInterval("Navigation", id: id, "push: \(destination, privacy: .public)")
    return id
  }
  
  static func endNavigation(id: OSSignpostID) {
    guard navigationSignposter.isEnabled, id != .null else { return }
    navigationSignposter.endInterval("Navigation", OSSignpostIntervalState.beginState(id: id))
  }
  
  static func tabSwitch(from: String, to: String) {
    guard navigationSignposter.isEnabled else { return }
    navigationSignposter.emitEvent("TabSwitch", "\(from, privacy: .public) -> \(to, privacy: .public)")
  }
  
  // MARK: - Thread View
  
  static func beginThreadLoad(postId: String) -> OSSignpostID {
    guard threadSignposter.isEnabled else { return .null }
    let id = threadSignposter.makeSignpostID()
    _ = threadSignposter.beginInterval("ThreadLoad", id: id)
    return id
  }
  
  static func endThreadLoad(id: OSSignpostID, replyCount: Int) {
    guard threadSignposter.isEnabled, id != .null else { return }
    threadSignposter.endInterval("ThreadLoad", OSSignpostIntervalState.beginState(id: id), "replies: \(replyCount)")
  }
  
  // MARK: - Network
  
  static func beginNetworkRequest(endpoint: String, method: String) -> OSSignpostID {
    guard networkSignposter.isEnabled else { return .null }
    let id = networkSignposter.makeSignpostID()
    _ = networkSignposter.beginInterval("NetworkRequest", id: id, "\(method, privacy: .public) \(endpoint, privacy: .public)")
    return id
  }
  
  static func endNetworkRequest(id: OSSignpostID, statusCode: Int, bytesReceived: Int) {
    guard networkSignposter.isEnabled, id != .null else { return }
    networkSignposter.endInterval("NetworkRequest", OSSignpostIntervalState.beginState(id: id), "status: \(statusCode), bytes: \(bytesReceived)")
  }
  
  // MARK: - Scroll Performance
  
  static func beginScroll() -> OSSignpostID {
    guard feedSignposter.isEnabled else { return .null }
    let id = feedSignposter.makeSignpostID()
    _ = feedSignposter.beginInterval("Scroll", id: id)
    return id
  }
  
  static func endScroll(id: OSSignpostID) {
    guard feedSignposter.isEnabled, id != .null else { return }
    feedSignposter.endInterval("Scroll", OSSignpostIntervalState.beginState(id: id))
  }
  
  static func scrollFrame(fps: Double) {
    guard feedSignposter.isEnabled else { return }
    feedSignposter.emitEvent("ScrollFrame", "fps: \(fps)")
  }
  
  // MARK: - App Launch
  
  static func appLaunchMilestone(_ milestone: String) {
    guard feedSignposter.isEnabled else { return }
    feedSignposter.emitEvent("LaunchMilestone", "\(milestone, privacy: .public)")
  }
  
  // MARK: - Batch Operations (for N+1 detection)
  
  /// Begin tracking a batch operation (parallel API calls)
  static func beginBatchOperation(_ operation: String, count: Int) -> OSSignpostID {
    guard batchSignposter.isEnabled else { return .null }
    let id = batchSignposter.makeSignpostID()
    _ = batchSignposter.beginInterval("BatchOperation", id: id, "\(operation, privacy: .public) count: \(count)")
    return id
  }
  
  /// End tracking a batch operation
  static func endBatchOperation(id: OSSignpostID, successCount: Int, failureCount: Int) {
    guard batchSignposter.isEnabled, id != .null else { return }
    batchSignposter.endInterval("BatchOperation", OSSignpostIntervalState.beginState(id: id), "success: \(successCount), failed: \(failureCount)")
  }
}

// MARK: - Shared Intervals Contract

extension PerformanceSignposts {
  /// Shared contract for performance intervals across features.
  /// Backed by OSSignposter(subsystem: "blue.catbird.performance", category: "Intervals").
  nonisolated static func beginInterval(_ name: StaticString) -> OSSignpostIntervalState {
    guard intervalsSignposter.isEnabled else {
      return OSSignpostIntervalState.beginState(id: .null)
    }
    return intervalsSignposter.beginInterval(name)
  }
  
  nonisolated static func endInterval(_ name: StaticString, _ state: OSSignpostIntervalState) {
    guard intervalsSignposter.isEnabled else { return }
    intervalsSignposter.endInterval(name, state)
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
    let signposter = OSSignposter(logHandle: log)
    guard signposter.isEnabled else { return try await operation() }
    let state = signposter.beginInterval(name)
    do {
      let result = try await operation()
      signposter.endInterval(name, state)
      return result
    } catch {
      signposter.endInterval(name, state)
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
    let signposter = OSSignposter(logHandle: log)
    guard signposter.isEnabled else { return try operation() }
    let state = signposter.beginInterval(name)
    defer { signposter.endInterval(name, state) }
    return try operation()
  }
}
