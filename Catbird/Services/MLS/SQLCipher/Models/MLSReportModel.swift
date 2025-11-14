//
//  MLSReportModel.swift
//  Catbird
//
//  MLS moderation report data model
//

import Foundation
import GRDB

/// MLS moderation report model for tracking user reports in conversations
struct MLSReportModel: Codable, Sendable, Hashable, Identifiable {
  let id: String
  let convoID: String
  let reporterDID: String
  let reportedDID: String
  let reason: String
  let details: String?
  let status: String
  let action: String?
  let resolutionNotes: String?
  let createdAt: Date
  let resolvedAt: Date?

  // MARK: - Initialization

  init(
    id: String,
    convoID: String,
    reporterDID: String,
    reportedDID: String,
    reason: String,
    details: String? = nil,
    status: String = "pending",
    action: String? = nil,
    resolutionNotes: String? = nil,
    createdAt: Date = Date(),
    resolvedAt: Date? = nil
  ) {
    self.id = id
    self.convoID = convoID
    self.reporterDID = reporterDID
    self.reportedDID = reportedDID
    self.reason = reason
    self.details = details
    self.status = status
    self.action = action
    self.resolutionNotes = resolutionNotes
    self.createdAt = createdAt
    self.resolvedAt = resolvedAt
  }

  // MARK: - Update Methods

  /// Create copy with resolved status
  func withResolution(action: String, notes: String?) -> MLSReportModel {
    MLSReportModel(
      id: id,
      convoID: convoID,
      reporterDID: reporterDID,
      reportedDID: reportedDID,
      reason: reason,
      details: details,
      status: "resolved",
      action: action,
      resolutionNotes: notes,
      createdAt: createdAt,
      resolvedAt: Date()
    )
  }

  /// Create copy with dismissed status
  func withDismissal(notes: String?) -> MLSReportModel {
    MLSReportModel(
      id: id,
      convoID: convoID,
      reporterDID: reporterDID,
      reportedDID: reportedDID,
      reason: reason,
      details: details,
      status: "dismissed",
      action: "no_action",
      resolutionNotes: notes,
      createdAt: createdAt,
      resolvedAt: Date()
    )
  }
}

// MARK: - GRDB Conformance
extension MLSReportModel: FetchableRecord, PersistableRecord {
  static let databaseTableName = "MLSReportModel"

  enum Columns {
    static let id = Column("id")
    static let convoID = Column("convo_id")
    static let reporterDID = Column("reporter_did")
    static let reportedDID = Column("reported_did")
    static let reason = Column("reason")
    static let details = Column("details")
    static let status = Column("status")
    static let action = Column("action")
    static let resolutionNotes = Column("resolution_notes")
    static let createdAt = Column("created_at")
    static let resolvedAt = Column("resolved_at")
  }

  enum CodingKeys: String, CodingKey {
    case id
    case convoID = "convo_id"
    case reporterDID = "reporter_did"
    case reportedDID = "reported_did"
    case reason
    case details
    case status
    case action
    case resolutionNotes = "resolution_notes"
    case createdAt = "created_at"
    case resolvedAt = "resolved_at"
  }
}

// MARK: - Helpers

extension MLSReportModel {
  /// Check if report is pending review
  var isPending: Bool {
    status == "pending"
  }

  /// Check if report is resolved
  var isResolved: Bool {
    status == "resolved" || status == "dismissed"
  }

  /// Human-readable status
  var statusDescription: String {
    switch status {
    case "pending": return "Pending Review"
    case "resolved": return "Resolved"
    case "dismissed": return "Dismissed"
    default: return status.capitalized
    }
  }
}
