import CatbirdMLSCore
import Foundation
import Petrel

#if os(iOS)

  /// Represents a decrypted MLS message with sender information
  /// This pairs the encrypted MessageView from the server with decrypted payload and sender
  struct DecryptedMLSMessage: Identifiable, Sendable {
    /// Unique message identifier
    let id: String

    /// Conversation ID
    let convoId: String

    /// Epoch number when message was sent
    let epoch: Int

    /// Sequence number within epoch
    let seq: Int

    /// When the message was created
    let createdAt: Date

    /// Decrypted message payload (text and embeds)
    let payload: MLSMessagePayload

    /// Sender's DID extracted from MLS credential
    let senderDID: String

    /// Initialize from MessageView after decryption
    init(
      messageView: BlueCatbirdMlsDefs.MessageView,
      payload: MLSMessagePayload,
      senderDID: String
    ) {
      self.id = messageView.id
      self.convoId = messageView.convoId
      self.epoch = messageView.epoch
      self.seq = messageView.seq
      self.createdAt = messageView.createdAt.date
      self.payload = payload
      self.senderDID = senderDID
    }

    /// Simplified initializer for creating from storage data
    init(
      id: String,
      convoId: String,
      text: String,
      senderDID: String,
      createdAt: Date,
      embed: MLSEmbedData? = nil,
      epoch: Int = 0,
      seq: Int = 0
    ) {
      self.id = id
      self.convoId = convoId
      self.epoch = epoch
      self.seq = seq
      self.createdAt = createdAt
      self.payload = MLSMessagePayload.text(text, embed: embed)
      self.senderDID = senderDID
    }
  }

  extension DecryptedMLSMessage {
    /// Message type discriminator (text, reaction, readReceipt, typing, etc.)
    var messageType: MLSMessageType {
      payload.messageType
    }

    /// Whether this is a displayable chat message (vs control message)
    var isTextMessage: Bool {
      payload.messageType == .text
    }

    /// Whether this is a control message (reaction, read receipt, typing)
    var isControlMessage: Bool {
      switch payload.messageType {
      case .reaction, .readReceipt, .typing:
        return true
      case .text, .adminRoster, .adminAction:
        return false
      }
    }

    /// Message text content (for text messages)
    var text: String? {
      payload.text
    }

    /// Optional embed data (for text messages)
    var embed: MLSEmbedData? {
      payload.embed
    }

    /// Reaction payload (for reaction messages)
    var reaction: MLSReactionPayload? {
      payload.reaction
    }

    /// Read receipt payload (for read receipt messages)
    var readReceipt: MLSReadReceiptPayload? {
      payload.readReceipt
    }

    /// Typing payload (for typing indicator messages)
    var typing: MLSTypingPayload? {
      payload.typing
    }

    /// Check if message is from specific sender
    func isFrom(_ did: String) -> Bool {
      senderDID == did
    }
  }

#endif
