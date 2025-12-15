import Foundation

/// Helpers for detecting when a chat message needs its cell re-rendered.
enum UnifiedChatRenderSignature {
  static func messageSignature<Message: UnifiedChatMessage>(for message: Message) -> String {
    let reactionsSignature = reactionsSignature(for: message.reactions)
    let profileSignature = message.senderDisplayName ?? ""
    let avatarSignature = message.senderAvatarURL?.absoluteString ?? ""
    let embedSignature = message.embed.map { String($0.hashValue) } ?? ""

    return [
      message.text,
      reactionsSignature,
      String(describing: message.sendState),
      profileSignature,
      avatarSignature,
      embedSignature,
    ].joined(separator: "|")
  }

  static func reactionsSignature(for reactions: [UnifiedReaction]) -> String {
    guard !reactions.isEmpty else { return "" }
    let grouped = Dictionary(grouping: reactions, by: { $0.emoji })
    return grouped.keys.sorted().map { emoji in
      let reactionsForEmoji = grouped[emoji] ?? []
      let count = reactionsForEmoji.count
      let userReacted = reactionsForEmoji.contains { $0.isFromCurrentUser } ? "1" : "0"
      return "\(emoji)=\(count),\(userReacted)"
    }
    .joined(separator: ";")
  }
}

