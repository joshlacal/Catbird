//
//  MLSKeyPackageCache.swift
//  Catbird
//
//  Created by Claude Code
//

import Foundation
import OSLog

/// Actor-based cache for key package inventory counts
/// Reduces network calls by maintaining local state with smart invalidation
actor MLSKeyPackageCache {
  static let shared = MLSKeyPackageCache()

  // MARK: - Configuration

  struct CacheConfig {
    /// How long cached values are considered fresh
    let cacheTTL: TimeInterval

    /// Maximum drift before forcing server refresh
    let maxDriftCount: Int

    /// Minimum interval between server refreshes
    let minRefreshInterval: TimeInterval

    static let `default` = CacheConfig(
      cacheTTL: 3600, // 1 hour
      maxDriftCount: 20, // Refresh if local estimate drifts > 20 packages
      minRefreshInterval: 300 // Min 5 minutes between refreshes
    )
  }

  // MARK: - State

  private let logger = Logger(subsystem: "blue.catbird", category: "KeyPackageCache")
  private let config: CacheConfig

  /// Last count received from server (source of truth)
  private var serverCount: Int?

  /// Last time we fetched from server
  private var lastServerUpdate: Date?

  /// Our local estimate based on uploads/consumption
  private var estimatedCount: Int?

  /// Last time we updated local estimate
  private var lastLocalUpdate: Date?

  /// Track cumulative drift from server count
  private var cumulativeDrift: Int = 0

  // MARK: - Initialization

  init(config: CacheConfig = .default) {
    self.config = config
  }

  // MARK: - Cache Access

  /// Get cached count if available and fresh
  func getCachedCount() -> Int? {
    // Prefer estimated count if we have it and it's recent
    if let estimated = estimatedCount,
       let lastUpdate = lastLocalUpdate,
       Date().timeIntervalSince(lastUpdate) < config.cacheTTL {
      logger.debug("Returning cached estimate: \(estimated)")
      return estimated
    }

    // Fall back to server count if fresh enough
    if let server = serverCount,
       let lastUpdate = lastServerUpdate,
       Date().timeIntervalSince(lastUpdate) < config.cacheTTL {
      logger.debug("Returning cached server count: \(server)")
      return server
    }

    logger.debug("No fresh cached count available")
    return nil
  }

  /// Check if we should refresh from server
  func shouldRefreshFromServer() -> Bool {
    // Refresh if we have no data
    guard let lastUpdate = lastServerUpdate else {
      logger.info("Should refresh: no server data")
      return true
    }

    // Refresh if cache expired
    let elapsed = Date().timeIntervalSince(lastUpdate)
    if elapsed > config.cacheTTL {
        logger.info("Should refresh: cache expired (\(elapsed)s > \(self.config.cacheTTL)s)")
      return true
    }

    // Refresh if we haven't checked recently and drift is high
    if abs(cumulativeDrift) > config.maxDriftCount,
       elapsed > config.minRefreshInterval {
        logger.info("Should refresh: high drift (\(self.cumulativeDrift)) and min interval passed")
      return true
    }

    logger.debug("Should not refresh: cache is fresh")
    return false
  }

  // MARK: - Cache Updates

  /// Update cache with authoritative server count
  func updateFromServer(count: Int) {
    logger.info("Updating from server: \(count) packages")

    serverCount = count
    estimatedCount = count
    lastServerUpdate = Date()
    lastLocalUpdate = Date()
    cumulativeDrift = 0 // Reset drift since we have authoritative count
  }

  /// Update cache after uploading packages
  func updateAfterUpload(uploaded: Int) {
    guard uploaded > 0 else { return }

    logger.info("Recording upload of \(uploaded) packages")

    // Update estimated count
    if let current = estimatedCount {
      estimatedCount = current + uploaded
      cumulativeDrift += uploaded
    } else if let server = serverCount {
      estimatedCount = server + uploaded
      cumulativeDrift += uploaded
    } else {
      // No baseline, can't estimate
      estimatedCount = nil
    }

    lastLocalUpdate = Date()

    if let estimated = estimatedCount {
        logger.debug("New estimated count: \(estimated) (drift: \(self.cumulativeDrift))")
    }
  }

  /// Update cache after packages are consumed
  /// Note: This is best-effort since client may not know about all consumption
  func updateAfterConsumption(consumed: Int) {
    guard consumed > 0 else { return }

    logger.info("Recording consumption of \(consumed) packages")

    // Update estimated count
    if let current = estimatedCount {
      estimatedCount = max(0, current - consumed)
      cumulativeDrift -= consumed
    } else if let server = serverCount {
      estimatedCount = max(0, server - consumed)
      cumulativeDrift -= consumed
    } else {
      estimatedCount = nil
    }

    lastLocalUpdate = Date()

    if let estimated = estimatedCount {
        logger.debug("New estimated count: \(estimated) (drift: \(self.cumulativeDrift))")
    }
  }

  /// Invalidate the cache (force next call to refresh from server)
  func invalidate() {
    logger.info("Invalidating cache")

    serverCount = nil
    estimatedCount = nil
    lastServerUpdate = nil
    lastLocalUpdate = nil
    cumulativeDrift = 0
  }

  // MARK: - Debugging

  func getDebugInfo() -> String {
    """
    KeyPackageCache State:
      Server Count: \(serverCount?.description ?? "nil")
      Estimated Count: \(estimatedCount?.description ?? "nil")
      Last Server Update: \(lastServerUpdate?.description ?? "nil")
      Last Local Update: \(lastLocalUpdate?.description ?? "nil")
      Cumulative Drift: \(cumulativeDrift)
      Should Refresh: \(shouldRefreshFromServer())
    """
  }
}
