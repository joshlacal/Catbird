import Foundation

// MARK: - UnifiedChatMessage

/// Protocol that unifies Bluesky Chat and MLS Chat messages
protocol UnifiedChatMessage: Identifiable, Hashable, Sendable {
  var id: String { get }
  var text: String { get }
  var senderID: String { get }
  var senderDisplayName: String? { get }
  var senderAvatarURL: URL? { get }
  var sentAt: Date { get }
  var isFromCurrentUser: Bool { get }
  var reactions: [UnifiedReaction] { get }
  var embed: UnifiedEmbed? { get }
  var sendState: MessageSendState { get }
}

// MARK: - MessageSendState

/// Message send state
enum MessageSendState: Hashable, Sendable {
  case sending
  case sent
  case delivered
  case read
  case failed(String)
}
