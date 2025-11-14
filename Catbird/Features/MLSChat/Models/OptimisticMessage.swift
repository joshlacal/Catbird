import Foundation
import Petrel

#if os(iOS)

/// State of a message being sent
enum MessageSendState: Equatable {
  case sending
  case sent
  case failed(String) // Error message

  static func == (lhs: MessageSendState, rhs: MessageSendState) -> Bool {
    switch (lhs, rhs) {
    case (.sending, .sending), (.sent, .sent):
      return true
    case (.failed(let lhsError), .failed(let rhsError)):
      return lhsError == rhsError
    default:
      return false
    }
  }
}

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

/// Unified message type for display (optimistic or confirmed)
/// Note: MessageView contains encrypted ciphertext only. Decrypted content
/// comes from MLSMessageModel cache and is displayed separately in the UI.
enum DisplayMessage: Identifiable {
  case optimistic(OptimisticMessage)
  case confirmed(BlueCatbirdMlsDefs.MessageView)

  var id: String {
    switch self {
    case .optimistic(let msg):
      return msg.id.uuidString
    case .confirmed(let msg):
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
    }
  }

  var messageState: MessageSendState? {
    switch self {
    case .optimistic(let msg):
      return msg.state
    case .confirmed:
      return nil // Confirmed messages have no pending state
    }
  }
}

#endif
