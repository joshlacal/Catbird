//
//  MLSAdminRosterModel.swift
//  Catbird
//
//  MLS admin roster data model for encrypted admin list
//

import Foundation
import GRDB

/// MLS admin roster model for storing encrypted admin roster data
/// The roster is encrypted using the MLS group key and distributed via MLS
struct MLSAdminRosterModel: Codable, Sendable, Hashable, Identifiable {
  let convoID: String
  let version: Int
  let rosterHash: String
  let encryptedRoster: Data
  let updatedAt: Date

  var id: String { convoID }

  // MARK: - Initialization

  init(
    convoID: String,
    version: Int,
    rosterHash: String,
    encryptedRoster: Data,
    updatedAt: Date = Date()
  ) {
    self.convoID = convoID
    self.version = version
    self.rosterHash = rosterHash
    self.encryptedRoster = encryptedRoster
    self.updatedAt = updatedAt
  }

  // MARK: - Update Methods

  /// Create copy with updated roster
  func withNewVersion(version: Int, hash: String, roster: Data) -> MLSAdminRosterModel {
    MLSAdminRosterModel(
      convoID: convoID,
      version: version,
      rosterHash: hash,
      encryptedRoster: roster,
      updatedAt: Date()
    )
  }
}

// MARK: - GRDB Conformance
extension MLSAdminRosterModel: FetchableRecord, PersistableRecord {
  static let databaseTableName = "MLSAdminRosterModel"

  enum Columns {
    static let convoID = Column("convo_id")
    static let version = Column("version")
    static let rosterHash = Column("roster_hash")
    static let encryptedRoster = Column("encrypted_roster")
    static let updatedAt = Column("updated_at")
  }

  enum CodingKeys: String, CodingKey {
    case convoID = "convo_id"
    case version
    case rosterHash = "roster_hash"
    case encryptedRoster = "encrypted_roster"
    case updatedAt = "updated_at"
  }
}

// MARK: - Helpers

extension MLSAdminRosterModel {
  /// Get roster size in bytes
  var rosterSize: Int {
    encryptedRoster.count
  }

  /// Check if roster needs sync (older than 24 hours)
  var needsSync: Bool {
    Date().timeIntervalSince(updatedAt) > 86400 // 24 hours
  }
}
