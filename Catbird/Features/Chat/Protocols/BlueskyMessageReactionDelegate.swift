#if os(iOS)
import ExyteChat
#endif
import Foundation
import OSLog

#if os(iOS)
class BlueskyMessageReactionDelegate: ReactionDelegate {
  private let chatManager: ChatManager
  private let convoId: String
  private let logger = Logger(subsystem: "blue.catbird", category: "BlueskyMessageReactionDelegate")
  private var reactionTask: Task<Void, Never>?

  init(chatManager: ChatManager, convoId: String) {
    self.chatManager = chatManager
    self.convoId = convoId
  }
  
  deinit {
    reactionTask?.cancel()
  }

  func didReact(to message: Message, reaction: DraftReaction) {
    // Cancel any existing reaction task to prevent concurrent operations
    reactionTask?.cancel()
    
    reactionTask = Task {
      do {
        try await chatManager.toggleReaction(
          convoId: convoId,
          messageId: message.id,
          emoji: mapReactionType(reaction.type)
        )
      } catch {
        // Handle cancellation and other errors gracefully
        if !(error is CancellationError) && !error.localizedDescription.lowercased().contains("cancel") {
          logger.error("Reaction delegate error: \(error.localizedDescription)")
          // Don't propagate error to UI - let ChatManager's error handling decide
        }
      }
    }
  }

  func reactions(for message: Message) -> [ReactionType]? {
    // Provide a set of default emoji reactions
    return [
      .emoji("😂"),
      .emoji("👍"),
      .emoji("❤️"),
      .emoji("😲"),
      .emoji("😢"),
      .emoji("🔥")
    ]
  }

  func canReact(to message: Message) -> Bool {
    return true
  }

  func allowEmojiSearch(for message: Message) -> Bool {
    return true
  }

  func shouldShowOverview(for message: Message) -> Bool {
    return !message.reactions.isEmpty
  }

  // Helper to map ExyteChat reaction types to backend's format
  private func mapReactionType(_ type: ReactionType) -> String {
    switch type {
    case .emoji(let emoji):
      return emoji
    }
  }
}
#endif
