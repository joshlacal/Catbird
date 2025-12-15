import Foundation
import Petrel
import CatbirdMLSCore

#if os(iOS)

/// Optimistic message shown immediately before server confirmation
struct OptimisticMessage: Identifiable, Sendable {
  /// Temporary ID for optimistic message
  let id: UUID

  /// Conversation ID
  let conversationId: String

  /// Message text content
  let text: String

  /// Optional embed data
  let embed: MLSEmbedData?

  /// When the message was created locally
  let timestamp: Date

  /// Sender's DID
  let senderDID: String

  /// Current send state
  var state: MessageSendState

  init(
    conversationId: String,
    text: String,
    embed: MLSEmbedData? = nil,
    senderDID: String
  ) {
    self.id = UUID()
    self.conversationId = conversationId
    self.text = text
    self.embed = embed
    self.timestamp = Date()
    self.senderDID = senderDID
    self.state = .sending
  }
}

/// Unified message type for display (optimistic, confirmed, or system message)
/// Note: MessageView contains encrypted ciphertext only. Decrypted content
/// comes from MLSMessageModel cache and is displayed separately in the UI.
enum DisplayMessage: Identifiable {
  case optimistic(OptimisticMessage)
  case confirmed(BlueCatbirdMlsDefs.MessageView)
  case system(MLSSystemMessage)

  var id: String {
    switch self {
    case .optimistic(let msg):
      return msg.id.uuidString
    case .confirmed(let msg):
      return msg.id
    case .system(let msg):
      return msg.id
    }
  }

  var timestamp: Date {
    switch self {
    case .optimistic(let msg):
      return msg.timestamp
    case .confirmed(let msg):
      // MessageView.createdAt is the server timestamp
      return msg.createdAt.date
    case .system(let msg):
      return msg.timestamp
    }
  }

  var epoch: Int {
    switch self {
    case .optimistic:
      // Optimistic messages haven't been assigned an epoch yet
      // Use Int.max to sort them after all confirmed messages
      return Int.max
    case .confirmed(let msg):
      return msg.epoch
    case .system:
      // System messages sort by timestamp
      return 0
    }
  }

  var sequenceNumber: Int {
    switch self {
    case .optimistic:
      // Optimistic messages haven't been assigned a sequence number yet
      // Use Int.max to sort them after all confirmed messages
      return Int.max
    case .confirmed(let msg):
      return msg.seq
    case .system:
      // System messages sort by timestamp
      return 0
    }
  }

  var messageState: MessageSendState? {
    switch self {
    case .optimistic(let msg):
      return msg.state
    case .confirmed:
      return nil // Confirmed messages have no pending state
    case .system:
      return nil // System messages have no send state
    }
  }

  var isSystemMessage: Bool {
    if case .system = self {
      return true
    }
    return false
  }
}

/// User model for UI display
struct User: Equatable, Sendable {
    let id: String
    let name: String
    let avatarURL: URL?
    let isCurrentUser: Bool
}

/// Unified message model for UI display
struct Message: Identifiable, Equatable, Sendable {
    let id: String
    let user: User
    let status: MessageSendState?
    let createdAt: Date
    let text: String
    let embed: MLSEmbedData?
    
    init(id: String, user: User, status: MessageSendState?, createdAt: Date, text: String, embed: MLSEmbedData? = nil) {
        self.id = id
        self.user = user
        self.status = status
        self.createdAt = createdAt
        self.text = text
        self.embed = embed
    }
}

extension DisplayMessage {
    func toMessage(currentUserDID: String) -> Message {
        switch self {
        case .optimistic(let msg):
            return Message(
                id: msg.id.uuidString,
                user: User(
                    id: msg.senderDID,
                    name: "You", // Optimistic messages are always from current user
                    avatarURL: nil, // We could fetch this if needed
                    isCurrentUser: true
                ),
                status: msg.state,
                createdAt: msg.timestamp,
                text: msg.text,
                embed: msg.embed
            )
        case .confirmed(let msg):
            // Note: MessageView only contains encrypted ciphertext - no sender info.
            // Decrypted content comes from MLSMessageModel cache.
            // This case provides a placeholder; actual display uses MLSMessageModel.
            return Message(
                id: msg.id,
                user: User(
                    id: "unknown",
                    name: "Unknown",
                    avatarURL: nil,
                    isCurrentUser: false
                ),
                status: nil, // Confirmed messages are sent
                createdAt: msg.createdAt.date,
                text: "Encrypted Message", // Placeholder, actual decryption happens in view or cache
                embed: nil // Embeds handled separately or need decryption
            )
        case .system(let msg):
            // System messages use displayText method for formatted output
            return Message(
                id: msg.id,
                user: User(
                    id: "system",
                    name: "System",
                    avatarURL: nil,
                    isCurrentUser: false
                ),
                status: nil,
                createdAt: msg.timestamp,
                text: msg.type.defaultDisplayText,
                embed: nil
            )
        }
    }
}

extension SystemMessageType {
    /// Default display text when profiles aren't available
    var defaultDisplayText: String {
        switch self {
        case .memberJoined:
            return "A member joined the conversation"
        case .memberLeft:
            return "A member left the conversation"
        case .memberRemoved:
            return "A member was removed"
        case .memberKicked:
            return "A member was kicked"
        case .groupCreated:
            return "Conversation created"
        case .epochRotated:
            return "Security keys updated"
        case .adminPromoted:
            return "Admin promoted"
        case .deviceAdded:
            return "New device added"
        case .infoMessage:
            return "System notification"
        }
    }
}

#endif
