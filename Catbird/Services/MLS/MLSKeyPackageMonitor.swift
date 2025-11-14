//
//  MLSKeyPackageMonitor.swift
//  Catbird
//
//  Created by Claude Code
//

import Foundation
import OSLog

/// Actor responsible for smart key package monitoring with predictive replenishment
actor MLSKeyPackageMonitor {
  private let logger = Logger(subsystem: "Catbird", category: "MLSKeyPackageMonitor")

  /// Consumption tracker for history and statistics
  private let consumptionTracker: MLSConsumptionTracker

  /// User DID for this monitor
  private let userDID: String

  /// Configuration parameters
  private let config: MonitorConfiguration

  /// Last known stats from server
  private var lastStats: EnhancedKeyPackageStats?

  /// Last time stats were fetched
  private var lastStatsFetch: Date?

  init(
    userDID: String,
    consumptionTracker: MLSConsumptionTracker? = nil,
    config: MonitorConfiguration = .default
  ) {
    self.userDID = userDID
    self.consumptionTracker = consumptionTracker ?? MLSConsumptionTracker(userDID: userDID)
    self.config = config
  }

  // MARK: - Public API

  /// Track consumption event (called after packages are consumed)
  func trackConsumption(count: Int, operation: ConsumptionOperation, context: String? = nil) async throws {
    guard count > 0 else { return }

    try await consumptionTracker.record(
      packagesConsumed: count,
      operation: operation,
      context: context
    )

    logger.info("📊 Tracked consumption: \(count) packages for \(operation.rawValue)")
  }

  /// Get consumption rate (packages per day)
  func getConsumptionRate() async throws -> Double {
    try await consumptionTracker.getConsumptionRate(days: config.consumptionWindowDays)
  }

  /// Get predicted time until depletion
  func getPredictedDepletion(currentInventory: Int) async throws -> TimeInterval? {
    try await consumptionTracker.getPredictedDepletion(currentInventory: currentInventory)
  }

  /// Check if replenishment is needed based on multiple criteria
  func shouldReplenish(stats: EnhancedKeyPackageStats) async throws -> Bool {
    // Update cache
    lastStats = stats
    lastStatsFetch = Date()

    // Criterion 1: Below threshold
    if stats.available < stats.threshold {
      logger.info("⚠️ Replenishment needed: below threshold (\(stats.available) < \(stats.threshold))")
      return true
    }

    // Criterion 2: Below dynamic threshold (based on consumption)
    if stats.available < stats.dynamicThreshold {
      logger.info("⚠️ Replenishment needed: below dynamic threshold (\(stats.available) < \(stats.dynamicThreshold))")
      return true
    }

    // Criterion 3: Critically low
    if stats.isCriticallyLow {
      logger.warning("🚨 Replenishment critical: inventory critically low (\(stats.available))")
      return true
    }

    // Criterion 4: Predicted depletion within threshold
    if let depletionTime = try await getPredictedDepletion(currentInventory: stats.available) {
      let depletionDays = depletionTime / (24 * 60 * 60)

      if depletionDays < config.predictedDepletionThresholdDays {
        logger.info("⚠️ Replenishment needed: predicted depletion in \(String(format: "%.1f", depletionDays)) days")
        return true
      }
    }

    // Criterion 5: Server recommendation (if available)
    if let needsReplenish = stats.needsReplenish, needsReplenish {
      logger.info("⚠️ Replenishment needed: server recommendation")
      return true
    }

    // Criterion 6: Consumption spike detected
    if try await consumptionTracker.hasConsumptionSpike() {
      logger.info("⚠️ Replenishment recommended: consumption spike detected")
      return true
    }

    logger.info("✅ No replenishment needed: inventory healthy (\(stats.available) available)")
    return false
  }

  /// Get optimal batch size based on consumption patterns
  func getOptimalBatchSize(currentInventory: Int) async throws -> Int {
    let rate = try await getConsumptionRate()

    // Target: config.targetInventoryDays days of inventory
    let targetInventory = Int(ceil(rate * Double(config.targetInventoryDays)))

    // Calculate needed packages
    let needed = max(targetInventory - currentInventory, 0)

    // Adaptive sizing with bounds
    let configBatchSize = min(
      max(needed, config.minimumBatchSize),
      config.maximumBatchSize
    )

    // 🛡️ FIX: Explicit API batch limit cap (never exceed 100 packages per batch)
    let batchSize = min(configBatchSize, 100)

    if configBatchSize > 100 {
      logger.warning("⚠️ Config recommended \(configBatchSize) packages, capping at API limit of 100")
    }

    logger.info("📦 Calculated optimal batch size: \(batchSize) (rate: \(String(format: "%.2f", rate))/day, target: \(targetInventory))")

    return batchSize
  }

  /// Get replenishment recommendation
  func getReplenishmentRecommendation(stats: EnhancedKeyPackageStats) async throws -> ReplenishmentRecommendation {
    let shouldReplenish = try await self.shouldReplenish(stats: stats)

    guard shouldReplenish else {
      return ReplenishmentRecommendation(
        shouldReplenish: false,
        recommendedBatchSize: 0,
        priority: .low,
        reason: "Inventory is healthy",
        depletionTime: nil
      )
    }

    // Calculate batch size
    let batchSize = try await getOptimalBatchSize(currentInventory: stats.available)

    // Determine priority
    let priority = determinePriority(stats: stats)

    // Get depletion time
    let depletionTime = try await getPredictedDepletion(currentInventory: stats.available)

    // Generate reason
    let reason = generateReason(stats: stats, depletionTime: depletionTime)

    return ReplenishmentRecommendation(
      shouldReplenish: true,
      recommendedBatchSize: batchSize,
      priority: priority,
      reason: reason,
      depletionTime: depletionTime
    )
  }

  /// Get consumption statistics
  func getStatistics(currentInventory: Int) async throws -> ConsumptionStatistics {
    try await consumptionTracker.getStatistics(currentInventory: currentInventory)
  }

  /// Check if consumption trend is increasing
  func hasIncreasingTrend() async throws -> Bool {
    let trend = try await consumptionTracker.getConsumptionTrend()
    return trend == .increasing
  }

  // MARK: - Private Helpers

  /// Determine replenishment priority based on stats
  private func determinePriority(stats: EnhancedKeyPackageStats) -> ReplenishmentPriority {
    // Critical: Very low inventory or imminent depletion
    if stats.available < 5 {
      return .critical
    }

    if let depletionDays = stats.predictedDepletionDays, depletionDays < 1 {
      return .critical
    }

    // High: Below threshold or depletion within 3 days
    if stats.available < stats.threshold {
      return .high
    }

    if let depletionDays = stats.predictedDepletionDays, depletionDays < 3 {
      return .high
    }

    // Normal: Preventive replenishment
    if stats.available < stats.dynamicThreshold {
      return .normal
    }

    // Low: Optional optimization
    return .low
  }

  /// Generate human-readable reason for replenishment
  private func generateReason(stats: EnhancedKeyPackageStats, depletionTime: TimeInterval?) -> String {
    var reasons: [String] = []

    if stats.available < 5 {
      reasons.append("critically low inventory (\(stats.available) packages)")
    } else if stats.available < stats.threshold {
      reasons.append("below threshold (\(stats.available) < \(stats.threshold))")
    }

    if let depletion = depletionTime {
      let days = depletion / (24 * 60 * 60)
      reasons.append("predicted depletion in \(String(format: "%.1f", days)) days")
    }

    if stats.needsReplenish == true {
      reasons.append("server recommendation")
    }

    if reasons.isEmpty {
      return "Preventive replenishment"
    }

    return reasons.joined(separator: "; ")
  }
}

// MARK: - Monitor Configuration

struct MonitorConfiguration: Sendable {
  /// Number of days to use for consumption rate calculation
  let consumptionWindowDays: Int

  /// Threshold for predicted depletion (days)
  let predictedDepletionThresholdDays: Double

  /// Target inventory in days of consumption
  let targetInventoryDays: Int

  /// Minimum batch size to upload
  let minimumBatchSize: Int

  /// Maximum batch size to upload
  let maximumBatchSize: Int

  init(
    consumptionWindowDays: Int = 7,
    predictedDepletionThresholdDays: Double = 3.0,
    targetInventoryDays: Int = 14,
    minimumBatchSize: Int = 10,
    maximumBatchSize: Int = 100  // 🛡️ FIX: Align with API batch limit
  ) {
    self.consumptionWindowDays = consumptionWindowDays
    self.predictedDepletionThresholdDays = predictedDepletionThresholdDays
    self.targetInventoryDays = targetInventoryDays
    self.minimumBatchSize = minimumBatchSize
    self.maximumBatchSize = maximumBatchSize
  }

  /// Default configuration
  static let `default` = MonitorConfiguration()

  /// Aggressive monitoring (for high-activity users)
  static let aggressive = MonitorConfiguration(
    consumptionWindowDays: 3,
    predictedDepletionThresholdDays: 2.0,
    targetInventoryDays: 21,
    minimumBatchSize: 20,
    maximumBatchSize: 100  // 🛡️ FIX: Align with API batch limit (was 300)
  )

  /// Conservative monitoring (for low-activity users)
  static let conservative = MonitorConfiguration(
    consumptionWindowDays: 14,
    predictedDepletionThresholdDays: 5.0,
    targetInventoryDays: 10,
    minimumBatchSize: 5,
    maximumBatchSize: 100
  )
}
