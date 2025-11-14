//
//  MLSConsumptionTracker.swift
//  Catbird
//
//  Created by Claude Code
//

import Foundation
import GRDB
import OSLog

/// Actor responsible for tracking key package consumption history and calculating statistics
/// Uses SQLCipher/GRDB for encrypted persistence
actor MLSConsumptionTracker {
  private let logger = Logger(subsystem: "Catbird", category: "MLSConsumptionTracker")

  /// Maximum number of days to retain consumption history
  private let retentionDays: Int

  /// Current user DID
  private let userDID: String

  /// GRDB manager for database access
  private let dbManager: MLSGRDBManager

  init(userDID: String, dbManager: MLSGRDBManager = .shared, retentionDays: Int = 30) {
    self.userDID = userDID
    self.dbManager = dbManager
    self.retentionDays = retentionDays

    // Schedule initial cleanup
    Task {
      await cleanupOldRecords()
    }
  }

  // MARK: - Public API

  /// Record a new consumption event
  func record(
    packagesConsumed: Int,
    operation: ConsumptionOperation,
    context: String? = nil
  ) async throws {
    let record = ConsumptionRecord(
      packagesConsumed: packagesConsumed,
      operation: operation,
      context: context
    )

    // Store in database
    let db = try await dbManager.getDatabaseQueue(for: userDID)

    try await db.write { database in
      let model = MLSConsumptionRecordModel(from: record, userDID: userDID)
      try model.insert(database)
    }

    logger.info("📊 Recorded consumption: \(packagesConsumed) packages for \(operation.rawValue)")

    // Clean up old records periodically
    await cleanupOldRecords()
  }

  /// Get consumption statistics for the tracked period
  func getStatistics(currentInventory: Int? = nil) async throws -> ConsumptionStatistics {
    let db = try await dbManager.getDatabaseQueue(for: userDID)

    return try await db.read { database in
      // Get all recent records
      let records = try MLSConsumptionRecordModel
        .withinDays(retentionDays, userDID: userDID)
        .fetchAll(database)

      guard !records.isEmpty else {
        return .empty
      }

      // Calculate basic metrics
      let totalConsumed = records.reduce(0) { $0 + $1.packagesConsumed }
      let trackedDays = retentionDays
      let averageDaily = Double(totalConsumed) / Double(trackedDays)

      // Calculate time-windowed consumption
      let last24h = try MLSConsumptionRecordModel.totalConsumption(
        withinHours: 24,
        userDID: userDID,
        db: database
      )

      let last7d = try MLSConsumptionRecordModel.totalConsumption(
        withinDays: 7,
        userDID: userDID,
        db: database
      )

      // Calculate peak daily consumption (inline to avoid actor isolation issues)
      let peakDaily: Int = {
        let sql = """
          SELECT MAX(daily_total) as peak
          FROM (
            SELECT DATE(timestamp) as day, SUM(packagesConsumed) as daily_total
            FROM MLSConsumptionRecordModel
            WHERE currentUserDID = ? AND timestamp >= ?
            GROUP BY DATE(timestamp)
          )
        """
        let cutoffDate = Date().addingTimeInterval(-TimeInterval(retentionDays * 24 * 60 * 60))
        return (try? Int.fetchOne(database, sql: sql, arguments: [userDID, cutoffDate])) ?? 0
      }()

      return ConsumptionStatistics(
        averageDailyConsumption: averageDaily,
        totalConsumed: totalConsumed,
        trackedDays: trackedDays,
        last24Hours: last24h,
        last7Days: last7d,
        peakDailyConsumption: peakDaily,
        currentInventory: currentInventory
      )
    }
  }

  /// Get consumption rate (packages per day) over the specified window
  func getConsumptionRate(days: Int = 7) async throws -> Double {
    let db = try await dbManager.getDatabaseQueue(for: userDID)

    return try await db.read { database in
      let total = try MLSConsumptionRecordModel.totalConsumption(
        withinDays: days,
        userDID: userDID,
        db: database
      )

      return Double(total) / Double(days)
    }
  }

  /// Get predicted time until depletion (in seconds) based on current inventory
  func getPredictedDepletion(currentInventory: Int) async throws -> TimeInterval? {
    let rate = try await getConsumptionRate(days: 7)

    guard rate > 0 else {
      return nil  // No consumption, won't deplete
    }

    let daysUntilDepletion = Double(currentInventory) / rate
    return daysUntilDepletion * 24 * 60 * 60  // Convert to seconds
  }

  /// Check if there's been a recent spike in consumption
  func hasConsumptionSpike() async throws -> Bool {
    let last24hRate = try await getConsumptionRate(days: 1)
    let weeklyRate = try await getConsumptionRate(days: 7)

    // Spike detected if last 24h is 3x the weekly average
    return last24hRate > (weeklyRate * 3)
  }

  /// Get all consumption records (for debugging/analysis)
  func getAllRecords() async throws -> [ConsumptionRecord] {
    let db = try await dbManager.getDatabaseQueue(for: userDID)

    return try await db.read { database in
      try MLSConsumptionRecordModel
        .orderedByTimestamp(userDID: userDID)
        .fetchAll(database)
        .map { $0.toDomainModel() }
    }
  }

  /// Clear all consumption history
  func clearHistory() async throws {
    let db = try await dbManager.getDatabaseQueue(for: userDID)

    try await db.write { database in
      try MLSConsumptionRecordModel
        .forUser(userDID)
        .deleteAll(database)
    }

    logger.info("🗑️ Cleared all consumption history")
  }

  // MARK: - Private Helpers

  /// Remove records older than retention period
  private func cleanupOldRecords() async {
    do {
      let db = try await dbManager.getDatabaseQueue(for: userDID)
      let cutoffDate = Date().addingTimeInterval(-TimeInterval(retentionDays * 24 * 60 * 60))

      try await db.write { database in
        let deletedCount = try MLSConsumptionRecordModel
          .forUser(userDID)
          .filter(Column("timestamp") < cutoffDate)
          .deleteAll(database)

        if deletedCount > 0 {
          logger.info("🗑️ Cleaned up \(deletedCount) old consumption records")
        }
      }
    } catch {
      logger.error("❌ Failed to cleanup old records: \(error.localizedDescription)")
    }
  }
}

// MARK: - Consumption Analysis Extensions

extension MLSConsumptionTracker {
  /// Get consumption breakdown by operation type
  func getConsumptionByOperation(days: Int = 30) async throws -> [ConsumptionOperation: Int] {
    let db = try await dbManager.getDatabaseQueue(for: userDID)

    return try await db.read { database in
      let records = try MLSConsumptionRecordModel
        .withinDays(days, userDID: userDID)
        .fetchAll(database)

      var breakdown: [ConsumptionOperation: Int] = [:]
      for record in records {
        let operation = ConsumptionOperation(rawValue: record.operation) ?? .unknown
        breakdown[operation, default: 0] += record.packagesConsumed
      }

      return breakdown
    }
  }

  /// Get consumption trend (increasing, decreasing, stable)
  func getConsumptionTrend() async throws -> ConsumptionTrend {
    let last3Days = try await getConsumptionRate(days: 3)
    let last7Days = try await getConsumptionRate(days: 7)

    let difference = last3Days - last7Days
    let percentageChange = last7Days > 0 ? (difference / last7Days) : 0

    if percentageChange > 0.2 {
      return .increasing
    } else if percentageChange < -0.2 {
      return .decreasing
    } else {
      return .stable
    }
  }
}

/// Consumption trend indicator
enum ConsumptionTrend: String, Sendable {
  case increasing = "increasing"
  case decreasing = "decreasing"
  case stable = "stable"
}
