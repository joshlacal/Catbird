//
//  MLSConversation+ViewModel.swift
//  Catbird
//
//  CoreData to ViewModel conversion extensions for MLS entities
//

import Foundation
import Petrel
import CoreData

// MARK: - MLSConversation Extensions

extension MLSConversation {
  
  func toViewModel() -> MLSConversationViewModel {
    let participants = (members?.allObjects as? [MLSMember] ?? [])
      .filter { $0.isActive }
      .map { $0.toViewModel() }
    
    let sortedMessages = (messages?.allObjects as? [MLSMessage] ?? [])
      .sorted { ($0.timestamp ?? Date.distantPast) > ($1.timestamp ?? Date.distantPast) }
    
    let lastMessage = sortedMessages.first
    let lastMessagePreview = lastMessage.flatMap { message -> String? in
      guard let content = message.content else { return nil }
      
      if message.contentType == "text", let text = String(data: content, encoding: .utf8) {
        return text
      }
      
      switch message.contentType {
      case "image":
        return "📷 Image"
      case "video":
        return "🎥 Video"
      case "audio":
        return "🎵 Audio"
      case "file":
        return "📎 File"
      default:
        return "Message"
      }
    }
    
    let unreadMessages = sortedMessages.filter { !$0.isRead }
    
    let groupIdString: String? = {
      if let data = self.groupID, !data.isEmpty {
        return data.base64EncodedString()
      }
      return nil
    }()

    return MLSConversationViewModel(
      id: conversationID ?? UUID().uuidString,
      name: title,
      participants: participants,
      lastMessagePreview: lastMessagePreview,
      lastMessageTimestamp: lastMessageAt,
      unreadCount: unreadMessages.count,
      isGroupChat: Int(memberCount) > 2,
      groupId: groupIdString
    )
  }
  
  func toDetailViewModel(apiClient: MLSAPIClient, conversationManager: MLSConversationManager) -> MLSConversationDetailViewModel {
    return MLSConversationDetailViewModel(
      conversationId: conversationID ?? UUID().uuidString,
      apiClient: apiClient,
      conversationManager: conversationManager
    )
  }
}

// MARK: - MLSMember Extensions

extension MLSMember {
  
  func toViewModel() -> MLSParticipantViewModel {
    var avatarURL: URL?
    if let handle = handle {
      avatarURL = URL(string: "https://cdn.bsky.app/img/avatar/plain/\(handle)")
    }
    
    return MLSParticipantViewModel(
      id: memberID ?? UUID().uuidString,
      handle: handle ?? did ?? "unknown",
      displayName: displayName,
      avatarURL: avatarURL
    )
  }
  
  func toMemberViewModel() -> MLSMemberViewModel {
    return MLSMemberViewModel(
      id: memberID ?? UUID().uuidString,
      did: did ?? "",
      handle: handle,
      displayName: displayName,
      leafIndex: Int(leafIndex),
      role: role ?? "member",
      isActive: isActive,
      addedAt: addedAt ?? Date(),
      removedAt: removedAt
    )
  }
}

// MARK: - Supporting View Models


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

// MARK: - BlueCatbirdMlsDefs.ConvoView Extensions

extension BlueCatbirdMlsDefs.ConvoView {
  func toViewModel() -> MLSConversationViewModel {
    let participants = members.map { member in
      MLSParticipantViewModel(
        id: member.did.description,
        handle: member.did.description.split(separator: ":").last.map(String.init) ?? member.did.description,
        displayName: nil,
        avatarURL: nil
      )
    }
    
    let lastMessageDate = lastMessageAt?.date
    
    return MLSConversationViewModel(
      id: id,
      name: metadata?.name,
      participants: participants,
      lastMessagePreview: nil,
      lastMessageTimestamp: lastMessageDate,
      unreadCount: 0,
      isGroupChat: members.count > 2,
      groupId: groupId
    )
  }
}
