//
//  KeyPackageStats+Extensions.swift
//  Catbird
//
//  Created by Claude Code
//

import Foundation

/// Enhanced key package statistics from server
/// This extends the basic stats returned by blue.catbird.mls.getKeyPackageStats
struct EnhancedKeyPackageStats: Codable, Sendable {
  /// Current number of available (unconsumed) packages
  let available: Int

  /// Server-recommended minimum threshold
  let threshold: Int

  /// Total packages uploaded (lifetime)
  let total: Int

  /// Total packages consumed (lifetime)
  let consumed: Int

  /// Packages consumed in last 24 hours (NEW - from server)
  let consumedLast24h: Int?

  /// Packages consumed in last 7 days (NEW - from server)
  let consumedLast7d: Int?

  /// Average daily consumption rate (NEW - from server)
  let averageDailyConsumption: Double?

  /// Predicted days until depletion (NEW - from server)
  let predictedDepletionDays: Double?

  /// Server recommendation to replenish (NEW - from server)
  let needsReplenish: Bool?

  init(
    available: Int,
    threshold: Int,
    total: Int,
    consumed: Int,
    consumedLast24h: Int? = nil,
    consumedLast7d: Int? = nil,
    averageDailyConsumption: Double? = nil,
    predictedDepletionDays: Double? = nil,
    needsReplenish: Bool? = nil
  ) {
    self.available = available
    self.threshold = threshold
    self.total = total
    self.consumed = consumed
    self.consumedLast24h = consumedLast24h
    self.consumedLast7d = consumedLast7d
    self.averageDailyConsumption = averageDailyConsumption
    self.predictedDepletionDays = predictedDepletionDays
    self.needsReplenish = needsReplenish
  }

  /// Whether replenishment is recommended (server or client-calculated)
  var shouldReplenish: Bool {
    // Prefer server recommendation if available
    if let needsReplenish = needsReplenish {
      return needsReplenish
    }

    // Fallback: client-side calculation
    return available < threshold
  }

  /// Estimated packages needed to reach target inventory
  func packagesNeeded(target: Int = 100) -> Int {
    max(target - available, 0)
  }

  /// Dynamic threshold based on consumption rate
  var dynamicThreshold: Int {
    // If server provides consumption rate, use it
    if let avgDaily = averageDailyConsumption, avgDaily > 0 {
      // Target: 3 days of inventory as threshold
      return max(threshold, Int(ceil(avgDaily * 3)))
    }

    // Fallback to server threshold
    return threshold
  }

  /// Whether inventory is critically low
  var isCriticallyLow: Bool {
    available < (threshold / 2) || available < 5
  }

  /// Whether inventory is healthy
  var isHealthy: Bool {
    available >= dynamicThreshold
  }
}

extension EnhancedKeyPackageStats {
  /// Create from basic stats (for backward compatibility)
  static func from(basic: BasicKeyPackageStats) -> EnhancedKeyPackageStats {
    EnhancedKeyPackageStats(
      available: basic.available,
      threshold: basic.threshold,
      total: basic.total,
      consumed: basic.consumed
    )
  }
}

/// Basic stats structure (matches current server response)
struct BasicKeyPackageStats: Codable, Sendable {
  let available: Int
  let threshold: Int
  let total: Int
  let consumed: Int
}

/// Replenishment recommendation
struct ReplenishmentRecommendation: Sendable {
  /// Whether replenishment is needed
  let shouldReplenish: Bool

  /// Recommended number of packages to upload
  let recommendedBatchSize: Int

  /// Priority level (critical, high, normal, low)
  let priority: ReplenishmentPriority

  /// Human-readable reason
  let reason: String

  /// Predicted time until depletion (if applicable)
  let depletionTime: TimeInterval?
}

/// Priority levels for replenishment
enum ReplenishmentPriority: String, Sendable {
  case critical = "critical"  // < 5 packages or will deplete in < 24h
  case high = "high"          // < threshold or will deplete in < 3 days
  case normal = "normal"      // Preventive replenishment
  case low = "low"            // Optional optimization
}
