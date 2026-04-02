import CatbirdMLSCore
import Petrel
import SwiftUI

/// Wraps both Bluesky DM and MLS conversation types into a single identifiable type
/// for the unified conversation list.
enum UnifiedConversation: Identifiable {
  case bluesky(ChatBskyConvoDefs.ConvoView)
  case mls(
    conversation: MLSConversationModel,
    participants: [MLSParticipantViewModel],
    unreadCount: Int,
    lastMessage: MLSLastMessagePreview?,
    memberChange: MemberChangeInfo?,
    lastActivityDate: Date
  )

  var id: String {
    switch self {
    case .bluesky(let convo):
      return convo.id
    case .mls(let convo, _, _, _, _, _):
      return convo.conversationID
    }
  }

  var lastActivityDate: Date {
    switch self {
    case .bluesky(let convo):
      if case .chatBskyConvoDefsMessageView(let msg) = convo.lastMessage {
        return msg.sentAt.date
      }
      return .distantPast
    case .mls(_, _, _, _, _, let date):
      return date
    }
  }

  var isUnread: Bool {
    switch self {
    case .bluesky(let convo):
      return convo.unreadCount > 0
    case .mls(_, _, let unreadCount, _, _, _):
      return unreadCount > 0
    }
  }

  var isBluesky: Bool {
    if case .bluesky = self { return true }
    return false
  }

  var isMLS: Bool {
    if case .mls = self { return true }
    return false
  }
}
