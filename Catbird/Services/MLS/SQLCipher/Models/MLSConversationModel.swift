//
//  MLSConversationModel.swift
//  Catbird
//
//  MLS conversation data model
//

import Foundation
import GRDB

/// MLS group conversation model
struct MLSConversationModel: Codable, Sendable, Hashable, Identifiable {
  let conversationID: String
  let currentUserDID: String
  let groupID: Data
  let epoch: Int64
  let title: String?
  let avatarURL: String?
  let createdAt: Date
  let updatedAt: Date
  let lastMessageAt: Date?
  let isActive: Bool
  let needsRejoin: Bool
  let rejoinRequestedAt: Date?

  var id: String { conversationID }

  // MARK: - Initialization

  init(
    conversationID: String,
    currentUserDID: String,
    groupID: Data,
    epoch: Int64 = 0,
    title: String? = nil,
    avatarURL: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    lastMessageAt: Date? = nil,
    isActive: Bool = true,
    needsRejoin: Bool = false,
    rejoinRequestedAt: Date? = nil
  ) {
    self.conversationID = conversationID
    self.currentUserDID = currentUserDID
    self.groupID = groupID
    self.epoch = epoch
    self.title = title
    self.avatarURL = avatarURL
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.lastMessageAt = lastMessageAt
    self.isActive = isActive
    self.needsRejoin = needsRejoin
    self.rejoinRequestedAt = rejoinRequestedAt
  }

  // MARK: - Update Methods

  /// Create updated copy with new epoch
  func withEpoch(_ newEpoch: Int64) -> MLSConversationModel {
    MLSConversationModel(
      conversationID: conversationID,
      currentUserDID: currentUserDID,
      groupID: groupID,
      epoch: newEpoch,
      title: title,
      avatarURL: avatarURL,
      createdAt: createdAt,
      updatedAt: Date(),
      lastMessageAt: lastMessageAt,
      isActive: isActive,
      needsRejoin: needsRejoin,
      rejoinRequestedAt: rejoinRequestedAt
    )
  }

  /// Create updated copy with new last message timestamp
  func withLastMessageAt(_ timestamp: Date) -> MLSConversationModel {
    MLSConversationModel(
      conversationID: conversationID,
      currentUserDID: currentUserDID,
      groupID: groupID,
      epoch: epoch,
      title: title,
      avatarURL: avatarURL,
      createdAt: createdAt,
      updatedAt: Date(),
      lastMessageAt: timestamp,
      isActive: isActive,
      needsRejoin: needsRejoin,
      rejoinRequestedAt: rejoinRequestedAt
    )
  }

  /// Create updated copy with active status
  func withActiveStatus(_ active: Bool) -> MLSConversationModel {
    MLSConversationModel(
      conversationID: conversationID,
      currentUserDID: currentUserDID,
      groupID: groupID,
      epoch: epoch,
      title: title,
      avatarURL: avatarURL,
      createdAt: createdAt,
      updatedAt: Date(),
      lastMessageAt: lastMessageAt,
      isActive: active,
      needsRejoin: needsRejoin,
      rejoinRequestedAt: rejoinRequestedAt
    )
  }

  /// Create updated copy with new title and avatar
  func withMetadata(title: String?, avatarURL: String?) -> MLSConversationModel {
    MLSConversationModel(
      conversationID: conversationID,
      currentUserDID: currentUserDID,
      groupID: groupID,
      epoch: epoch,
      title: title,
      avatarURL: avatarURL,
      createdAt: createdAt,
      updatedAt: Date(),
      lastMessageAt: lastMessageAt,
      isActive: isActive,
      needsRejoin: needsRejoin,
      rejoinRequestedAt: rejoinRequestedAt
    )
  }

  /// Create updated copy with rejoin state
  func withRejoinState(needsRejoin: Bool, rejoinRequestedAt: Date?) -> MLSConversationModel {
    MLSConversationModel(
      conversationID: conversationID,
      currentUserDID: currentUserDID,
      groupID: groupID,
      epoch: epoch,
      title: title,
      avatarURL: avatarURL,
      createdAt: createdAt,
      updatedAt: Date(),
      lastMessageAt: lastMessageAt,
      isActive: isActive,
      needsRejoin: needsRejoin,
      rejoinRequestedAt: rejoinRequestedAt
    )
  }
}

// MARK: - GRDB Conformance
extension MLSConversationModel: FetchableRecord, PersistableRecord {
  static let databaseTableName = "MLSConversationModel"

  enum Columns {
    static let conversationID = Column("conversationID")
    static let currentUserDID = Column("currentUserDID")
    static let groupID = Column("groupID")
    static let epoch = Column("epoch")
    static let title = Column("title")
    static let avatarURL = Column("avatarURL")
    static let createdAt = Column("createdAt")
    static let updatedAt = Column("updatedAt")
    static let lastMessageAt = Column("lastMessageAt")
    static let isActive = Column("isActive")
    static let needsRejoin = Column("needsRejoin")
    static let rejoinRequestedAt = Column("rejoinRequestedAt")
  }
}
