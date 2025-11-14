//
//  MLSMessageReactionModel.swift
//  Catbird
//
//  MLS message reaction data model
//

import Foundation
import GRDB

/// MLS message reaction model (matches v1_initial_schema migration)
struct MLSMessageReactionModel: Codable, Sendable, Hashable, Identifiable {
  let reactionID: String
  let messageID: String
  let conversationID: String
  let currentUserDID: String
  let senderDID: String
  let reaction: String
  let action: Action
  let createdAt: Date

  var id: String { reactionID }

  // MARK: - Action Enum

  /// Action type
  enum Action: String, Codable, Sendable {
    case add
    case remove
  }
}

// MARK: - GRDB Conformance
extension MLSMessageReactionModel: FetchableRecord, PersistableRecord {
  static let databaseTableName = "MLSMessageReactionModel"

  enum Columns {
    static let reactionID = Column("reactionID")
    static let messageID = Column("messageID")
    static let conversationID = Column("conversationID")
    static let currentUserDID = Column("currentUserDID")
    static let senderDID = Column("actorDID")
    static let reaction = Column("emoji")
    static let action = Column("action")
    static let createdAt = Column("timestamp")
  }

  enum CodingKeys: String, CodingKey {
    case reactionID
    case messageID
    case conversationID
    case currentUserDID
    case senderDID = "actorDID"
    case reaction = "emoji"
    case action
    case createdAt = "timestamp"
  }
}

// MARK: - MLSMessageReactionModel

extension MLSMessageReactionModel {
  // MARK: - Computed Properties

  /// Check if reaction is an addition
  var isAddition: Bool {
    action == .add
  }

  /// Check if reaction is a removal
  var isRemoval: Bool {
    action == .remove
  }
}
