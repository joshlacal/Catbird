//
//  MLSKeyPackageModel.swift
//  Catbird
//
//  MLS key package data model
//

import Foundation
import GRDB

/// MLS key package model (matches v1_initial_schema migration)
struct MLSKeyPackageModel: Codable, Sendable, Hashable, Identifiable {
  let keyPackageID: String
  let currentUserDID: String
  let keyPackageData: Data
  let credentialData: Data
  let createdAt: Date
  let expiresAt: Date?
  let isPublished: Bool
  let isUsed: Bool

  var id: String { keyPackageID }

  // MARK: - Initialization

  init(
    keyPackageID: String,
    currentUserDID: String,
    keyPackageData: Data,
    credentialData: Data,
    createdAt: Date = Date(),
    expiresAt: Date? = nil,
    isPublished: Bool = false,
    isUsed: Bool = false
  ) {
    self.keyPackageID = keyPackageID
    self.currentUserDID = currentUserDID
    self.keyPackageData = keyPackageData
    self.credentialData = credentialData
    self.createdAt = createdAt
    self.expiresAt = expiresAt
    self.isPublished = isPublished
    self.isUsed = isUsed
  }

  // MARK: - Update Methods

  /// Create copy marked as used
  func markAsUsed() -> MLSKeyPackageModel {
    MLSKeyPackageModel(
      keyPackageID: keyPackageID,
      currentUserDID: currentUserDID,
      keyPackageData: keyPackageData,
      credentialData: credentialData,
      createdAt: createdAt,
      expiresAt: expiresAt,
      isPublished: isPublished,
      isUsed: true
    )
  }

  /// Create copy marked as published
  func markAsPublished() -> MLSKeyPackageModel {
    MLSKeyPackageModel(
      keyPackageID: keyPackageID,
      currentUserDID: currentUserDID,
      keyPackageData: keyPackageData,
      credentialData: credentialData,
      createdAt: createdAt,
      expiresAt: expiresAt,
      isPublished: true,
      isUsed: isUsed
    )
  }

  // MARK: - Computed Properties

  /// Check if key package is expired
  var isExpired: Bool {
    guard let expiry = expiresAt else { return false }
    return Date() > expiry
  }

  /// Check if key package is available for use
  var isAvailable: Bool {
    !isUsed && !isExpired && isPublished
  }
}

// MARK: - GRDB Conformance
extension MLSKeyPackageModel: FetchableRecord, PersistableRecord {
  static let databaseTableName = "MLSKeyPackageModel"

  enum Columns {
    static let keyPackageID = Column("keyPackageID")
    static let currentUserDID = Column("currentUserDID")
    static let keyPackageData = Column("keyPackageData")
    static let credentialData = Column("credentialData")
    static let createdAt = Column("createdAt")
    static let expiresAt = Column("expiresAt")
    static let isPublished = Column("isPublished")
    static let isUsed = Column("isUsed")
  }
}
