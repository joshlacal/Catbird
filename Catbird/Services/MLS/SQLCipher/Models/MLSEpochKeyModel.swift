//
//  MLSEpochKeyModel.swift
//  Catbird
//
//  MLS epoch key tracking model
//

import Foundation
import GRDB

/// MLS epoch key tracking model (matches v1_initial_schema migration)
struct MLSEpochKeyModel: Codable, Sendable, Hashable, Identifiable {
  let epochKeyID: String
  let conversationID: String
  let currentUserDID: String
  let epoch: Int64
  let keyMaterial: Data
  let createdAt: Date
  let expiresAt: Date?
  let isActive: Bool

  var id: String { epochKeyID }

  // MARK: - Initialization

  init(
    epochKeyID: String,
    conversationID: String,
    currentUserDID: String,
    epoch: Int64,
    keyMaterial: Data,
    createdAt: Date = Date(),
    expiresAt: Date? = nil,
    isActive: Bool = true
  ) {
    self.epochKeyID = epochKeyID
    self.conversationID = conversationID
    self.currentUserDID = currentUserDID
    self.epoch = epoch
    self.keyMaterial = keyMaterial
    self.createdAt = createdAt
    self.expiresAt = expiresAt
    self.isActive = isActive
  }

  // MARK: - Update Methods

  /// Create copy marked as inactive
  func markAsInactive() -> MLSEpochKeyModel {
    MLSEpochKeyModel(
      epochKeyID: epochKeyID,
      conversationID: conversationID,
      currentUserDID: currentUserDID,
      epoch: epoch,
      keyMaterial: keyMaterial,
      createdAt: createdAt,
      expiresAt: expiresAt,
      isActive: false
    )
  }

  // MARK: - Computed Properties

  /// Check if epoch key is expired
  var isExpired: Bool {
    guard let expiry = expiresAt else { return false }
    return Date() > expiry
  }

  /// Age of epoch key in seconds
  var ageInSeconds: TimeInterval {
    Date().timeIntervalSince(createdAt)
  }

  /// Age of epoch key in days
  var ageInDays: Int {
    Int(ageInSeconds / 86400)
  }
}

// MARK: - GRDB Conformance
extension MLSEpochKeyModel: FetchableRecord, PersistableRecord {
  static let databaseTableName = "MLSEpochKeyModel"

  enum Columns {
    static let epochKeyID = Column("epochKeyID")
    static let conversationID = Column("conversationID")
    static let currentUserDID = Column("currentUserDID")
    static let epoch = Column("epoch")
    static let keyMaterial = Column("keyMaterial")
    static let createdAt = Column("createdAt")
    static let expiresAt = Column("expiresAt")
    static let isActive = Column("isActive")
  }
}
