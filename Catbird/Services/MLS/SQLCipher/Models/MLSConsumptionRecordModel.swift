//
//  MLSConsumptionRecordModel.swift
//  Catbird
//
//  Created by Claude Code
//

import Foundation
import GRDB

/// GRDB record for tracking key package consumption events
struct MLSConsumptionRecordModel: Codable, FetchableRecord, PersistableRecord, Sendable {
  /// Unique identifier for the consumption record
  var recordID: String

  /// User DID (for per-user isolation)
  var currentUserDID: String

  /// When the consumption occurred
  var timestamp: Date

  /// Number of packages consumed in this event
  var packagesConsumed: Int

  /// The operation that caused consumption
  var operation: String  // ConsumptionOperation raw value

  /// Optional context (e.g., conversation ID, number of members)
  var context: String?

  // MARK: - Table Definition

  static let databaseTableName = "MLSConsumptionRecordModel"

  enum Columns {
    static let recordID = Column(CodingKeys.recordID)
    static let currentUserDID = Column(CodingKeys.currentUserDID)
    static let timestamp = Column(CodingKeys.timestamp)
    static let packagesConsumed = Column(CodingKeys.packagesConsumed)
    static let operation = Column(CodingKeys.operation)
    static let context = Column(CodingKeys.context)
  }
}

// MARK: - Convenience Initializers

extension MLSConsumptionRecordModel {
  /// Create from ConsumptionRecord domain model
  init(from record: ConsumptionRecord, userDID: String) {
    self.recordID = UUID().uuidString
    self.currentUserDID = userDID
    self.timestamp = record.timestamp
    self.packagesConsumed = record.packagesConsumed
    self.operation = record.operation.rawValue
    self.context = record.context
  }

  /// Convert to domain model
  func toDomainModel() -> ConsumptionRecord {
    ConsumptionRecord(
      timestamp: timestamp,
      packagesConsumed: packagesConsumed,
      operation: ConsumptionOperation(rawValue: operation) ?? .unknown,
      context: context
    )
  }
}

// MARK: - Query Helpers

extension MLSConsumptionRecordModel {
  /// Filter records for a specific user
  static func forUser(_ userDID: String) -> QueryInterfaceRequest<MLSConsumptionRecordModel> {
    filter(Columns.currentUserDID == userDID)
  }

  /// Filter records within a time window (days)
  static func withinDays(_ days: Int, userDID: String) -> QueryInterfaceRequest<MLSConsumptionRecordModel> {
    let cutoff = Date().addingTimeInterval(-TimeInterval(days * 24 * 60 * 60))
    return forUser(userDID).filter(Columns.timestamp >= cutoff)
  }

  /// Filter records within a time window (hours)
  static func withinHours(_ hours: Int, userDID: String) -> QueryInterfaceRequest<MLSConsumptionRecordModel> {
    let cutoff = Date().addingTimeInterval(-TimeInterval(hours * 60 * 60))
    return forUser(userDID).filter(Columns.timestamp >= cutoff)
  }

  /// Get records ordered by timestamp (newest first)
  static func orderedByTimestamp(userDID: String) -> QueryInterfaceRequest<MLSConsumptionRecordModel> {
    forUser(userDID).order(Columns.timestamp.desc)
  }

  /// Get total consumption count within a time window
  static func totalConsumption(withinDays days: Int, userDID: String, db: Database) throws -> Int {
    try withinDays(days, userDID: userDID)
      .select(sum(Columns.packagesConsumed))
      .asRequest(of: Int.self)
      .fetchOne(db) ?? 0
  }

  /// Get total consumption count within hours
  static func totalConsumption(withinHours hours: Int, userDID: String, db: Database) throws -> Int {
    try withinHours(hours, userDID: userDID)
      .select(sum(Columns.packagesConsumed))
      .asRequest(of: Int.self)
      .fetchOne(db) ?? 0
  }
}
