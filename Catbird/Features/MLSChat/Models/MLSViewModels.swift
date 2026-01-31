import CatbirdMLSService
//
//  MLSViewModels.swift
//  Catbird
//
//  View model types for MLS UI (SQLiteData-based)
//

import Foundation
import Petrel

// MARK: - View Models

/// ViewModel for conversation list display
public struct MLSConversationViewModel: Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String?
  public let participants: [MLSParticipantViewModel]
  public let lastMessagePreview: String?
  public let lastMessageTimestamp: Date?
  public let unreadCount: Int
  public let isGroupChat: Bool
  public let groupId: String?

  public init(
    id: String,
    name: String?,
    participants: [MLSParticipantViewModel],
    lastMessagePreview: String?,
    lastMessageTimestamp: Date?,
    unreadCount: Int,
    isGroupChat: Bool,
    groupId: String?
  ) {
    self.id = id
    self.name = name
    self.participants = participants
    self.lastMessagePreview = lastMessagePreview
    self.lastMessageTimestamp = lastMessageTimestamp
    self.unreadCount = unreadCount
    self.isGroupChat = isGroupChat
    self.groupId = groupId
  }
}

/// ViewModel for conversation participant display
public struct MLSParticipantViewModel: Identifiable, Hashable, Sendable {
  public let id: String
  public let handle: String
  public let displayName: String?
  public let avatarURL: URL?

  public init(
    id: String,
    handle: String,
    displayName: String?,
    avatarURL: URL?
  ) {
    self.id = id
    self.handle = handle
    self.displayName = displayName
    self.avatarURL = avatarURL
  }
}

/// ViewModel for message display
struct MLSMessageViewModel: Identifiable {
  let id: String
  let content: String
  let contentType: String
  let timestamp: Date
  let senderID: String
  let senderHandle: String
  let senderDisplayName: String?
  let isCurrentUser: Bool
  let isDelivered: Bool
  let isRead: Bool
  let isSent: Bool
  let error: String?
}

/// ViewModel for member management
struct MLSMemberViewModel: Identifiable {
  let id: String
  let did: String
  let handle: String?
  let displayName: String?
  let leafIndex: Int
  let role: String
  let isActive: Bool
  let addedAt: Date
  let removedAt: Date?
}

// MARK: - Server Model to ViewModel Conversion

extension BlueCatbirdMlsDefs.ConvoView {
  func toViewModel(unreadCount: Int = 0) -> MLSConversationViewModel {
    // Split complex map to prevent type checker explosion
    let participants: [MLSParticipantViewModel] = members.map { member in
      let didStr = member.did.description
      let lastPart = didStr.split(separator: ":").last
      let handle = lastPart.map(String.init) ?? didStr

      return MLSParticipantViewModel(
        id: didStr,
        handle: handle,
        displayName: nil,
        avatarURL: nil
      )
    }

    let lastMessageDate: Date? = lastMessageAt?.date

    return MLSConversationViewModel(
      id: groupId,
      name: metadata?.name,
      participants: participants,
      lastMessagePreview: nil,
      lastMessageTimestamp: lastMessageDate,
      unreadCount: unreadCount,
      isGroupChat: members.count > 2,
      groupId: groupId
    )
  }
}
