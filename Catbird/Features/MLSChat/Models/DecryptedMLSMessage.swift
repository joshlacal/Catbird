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
}

extension DecryptedMLSMessage {
  /// Message text content
  var text: String {
    payload.text
  }

  /// Optional embed data
  var embed: MLSEmbedData? {
    payload.embed
  }

  /// Check if message is from specific sender
  func isFrom(_ did: String) -> Bool {
    senderDID == did
  }
}

#endif
