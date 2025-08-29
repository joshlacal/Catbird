import ExyteChat
import Foundation

class BlueskyMessageReactionDelegate: ReactionDelegate {
  private let chatManager: ChatManager
  private let convoId: String

  init(chatManager: ChatManager, convoId: String) {
    self.chatManager = chatManager
    self.convoId = convoId
  }

  func didReact(to message: Message, reaction: DraftReaction) {
    Task {
      try await chatManager.toggleReaction(
        convoId: convoId,
        messageId: message.id,
        emoji: mapReactionType(reaction.type)
      )
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
