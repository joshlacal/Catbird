import Foundation
import SwiftUI

// MARK: - UnifiedChatDataSource

/// Protocol for chat data sources (Bluesky and MLS)
@MainActor
protocol UnifiedChatDataSource: Observable, AnyObject {
  associatedtype Message: UnifiedChatMessage

  var messages: [Message] { get }
  var draftText: String { get set }
  var isLoading: Bool { get }
  var error: Error? { get }
  var hasMoreMessages: Bool { get }

  func message(for id: String) -> Message?
  func loadMessages() async
  func loadMoreMessages() async
  func sendMessage(text: String) async
  func toggleReaction(messageID: String, emoji: String)
  func addReaction(messageID: String, emoji: String)
  func deleteMessage(messageID: String) async
}

// MARK: - UnifiedChatDataSourceEvent

enum UnifiedChatDataSourceEvent<Message: UnifiedChatMessage>: Sendable {
  case appended(Message)
  case updated(Message)
  case removed(messageID: String)
  case reactionSummaryChanged(messageID: String, summaries: [UnifiedReactionSummary])
  case typingStatusChanged(participantID: String, isTyping: Bool)
}
