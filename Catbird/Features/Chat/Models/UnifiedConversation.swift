import Petrel
import SwiftUI

/// Identifiable wrapper for an entry in the conversation list.
enum UnifiedConversation: Identifiable {
  case bluesky(ChatBskyConvoDefs.ConvoView)

  var id: String {
    switch self {
    case .bluesky(let convo):
      return convo.id
    }
  }

  var lastActivityDate: Date {
    switch self {
    case .bluesky(let convo):
      switch convo.lastMessage {
      case .chatBskyConvoDefsMessageView(let message):
        return message.sentAt.date
      case .chatBskyConvoDefsDeletedMessageView(let message):
        return message.sentAt.date
      case .chatBskyConvoDefsSystemMessageView(let message):
        return message.sentAt.date
      case .unexpected, .none:
        return .distantPast
      }
    }
  }

  var isUnread: Bool {
    switch self {
    case .bluesky(let convo):
      return convo.unreadCount > 0
    }
  }

  var isBluesky: Bool {
    if case .bluesky = self { return true }
    return false
  }
}
