import CatbirdMLSCore
import Foundation
import Petrel

/// Adapter that conforms MLS messages to UnifiedChatMessage
struct MLSMessageAdapter: UnifiedChatMessage {
  struct MLSProfileData: Sendable {
    let displayName: String?
    let avatarURL: URL?
    let handle: String?
  }

  struct MLSMessageDebugInfo: Sendable {
    let messageID: String
    let conversationID: String
    let senderDID: String
    let sentAt: Date
    let epoch: Int?
    let sequence: Int?
    let processingError: String?
    let processingAttempts: Int?
    let validationFailureReason: String?
  }

  private struct MessageMetadata: Sendable {
    let id: String
    let convoID: String
    let text: String
    let senderDID: String
    let sentAt: Date
    let embed: MLSEmbedData?
    let epoch: Int?
    let sequence: Int?
    let processingError: String?
    let processingAttempts: Int?
    let validationFailureReason: String?
  }

  private let metadata: MessageMetadata
  let currentUserDID: String
  let senderProfile: MLSProfileData?
  private let reactionsList: [MLSMessageReaction]
  private let currentSendState: MessageSendState
  #if os(iOS)
    let originalMessage: DecryptedMLSMessage
  #endif

  init(
    messageView: BlueCatbirdMlsDefs.MessageView,
    payload: MLSMessagePayload,
    senderDID: String,
    currentUserDID: String,
    senderProfile: MLSProfileData? = nil,
    reactions: [MLSMessageReaction] = [],
    sendState: MessageSendState = .sent
  ) {
    let metadata = MessageMetadata(
      id: messageView.id,
      convoID: messageView.convoId,
      text: payload.text ?? "",
      senderDID: senderDID,
      sentAt: messageView.createdAt.date,
      embed: payload.embed,
      epoch: messageView.epoch,
      sequence: messageView.seq,
      processingError: nil,
      processingAttempts: nil,
      validationFailureReason: nil
    )
    #if os(iOS)
      self.originalMessage = DecryptedMLSMessage(
        messageView: messageView,
        payload: payload,
        senderDID: senderDID
      )
    #endif
    self.metadata = metadata
    self.currentUserDID = currentUserDID
    self.senderProfile = senderProfile
    self.reactionsList = reactions
    self.currentSendState = sendState
  }

  #if os(iOS)
    init(
      message: DecryptedMLSMessage,
      currentUserDID: String,
      senderProfile: MLSProfileData? = nil,
      reactions: [MLSMessageReaction] = [],
      sendState: MessageSendState = .sent
    ) {
      self.originalMessage = message
      self.metadata = MessageMetadata(
        id: message.id,
        convoID: message.convoId,
        text: message.text ?? "",
        senderDID: message.senderDID,
        sentAt: message.createdAt,
        embed: message.embed,
        epoch: nil,
        sequence: nil,
        processingError: nil,
        processingAttempts: nil,
        validationFailureReason: nil
      )
      self.currentUserDID = currentUserDID
      self.senderProfile = senderProfile
      self.reactionsList = reactions
      self.currentSendState = sendState
    }

    /// Simplified initializer for creating adapters from storage data
    /// Used when we don't have a full DecryptedMLSMessage or MessageView
    init(
      id: String,
      convoID: String = "",
      text: String,
      senderDID: String,
      currentUserDID: String,
      sentAt: Date,
      senderProfile: MLSProfileData? = nil,
      reactions: [MLSMessageReaction] = [],
      embed: MLSEmbedData? = nil,
      sendState: MessageSendState = .sent,
      epoch: Int? = nil,
      sequence: Int? = nil,
      processingError: String? = nil,
      processingAttempts: Int? = nil,
      validationFailureReason: String? = nil
    ) {
      self.metadata = MessageMetadata(
        id: id,
        convoID: convoID,
        text: text,
        senderDID: senderDID,
        sentAt: sentAt,
        embed: embed,
        epoch: epoch,
        sequence: sequence,
        processingError: processingError,
        processingAttempts: processingAttempts,
        validationFailureReason: validationFailureReason
      )
      self.currentUserDID = currentUserDID
      self.senderProfile = senderProfile
      self.reactionsList = reactions
      self.currentSendState = sendState
      // Create a minimal placeholder for originalMessage
      // This is used when loading from storage where we don't have the full MessageView
      self.originalMessage = DecryptedMLSMessage(
        id: id,
        convoId: "",
        text: text,
        senderDID: senderDID,
        createdAt: sentAt,
        embed: embed
      )
    }
  #endif

  /// Accessor for the MLS profile data
  var mlsProfile: MLSProfileData? {
    senderProfile
  }

  /// Accessor for the raw MLS embed data (used when rebuilding adapters)
  var mlsEmbed: MLSEmbedData? {
    metadata.embed
  }

  var mlsConversationID: String {
    metadata.convoID
  }

  var mlsEpoch: Int? {
    metadata.epoch
  }

  var mlsSequence: Int? {
    metadata.sequence
  }

  var processingError: String? {
    metadata.processingError
  }

  var processingAttempts: Int? {
    metadata.processingAttempts
  }

  var validationFailureReason: String? {
    metadata.validationFailureReason
  }

  var debugInfo: MLSMessageDebugInfo? {
    guard processingError != nil || validationFailureReason != nil else { return nil }
    return MLSMessageDebugInfo(
      messageID: id,
      conversationID: metadata.convoID,
      senderDID: metadata.senderDID,
      sentAt: metadata.sentAt,
      epoch: metadata.epoch,
      sequence: metadata.sequence,
      processingError: metadata.processingError,
      processingAttempts: metadata.processingAttempts,
      validationFailureReason: metadata.validationFailureReason
    )
  }

  // MARK: - UnifiedChatMessage

  var id: String { metadata.id }

  var text: String { metadata.text }

  var senderID: String { metadata.senderDID }

  var senderDisplayName: String? {
    if let name = senderProfile?.displayName, !name.isEmpty {
      return name
    }

    if let handle = senderProfile?.handle, !handle.isEmpty {
      return handle
    }

    return nil
  }

  var senderAvatarURL: URL? {
    senderProfile?.avatarURL
  }

  var sentAt: Date {
    metadata.sentAt
  }

  var isFromCurrentUser: Bool {
    metadata.senderDID == currentUserDID
  }

  var reactions: [UnifiedReaction] {
    reactionsList.map { reaction in
      UnifiedReaction(
        messageID: metadata.id,
        emoji: reaction.reaction,
        senderDID: reaction.senderDID,
        isFromCurrentUser: reaction.senderDID == currentUserDID,
        reactedAt: reaction.reactedAt
      )
    }
  }

  var embed: UnifiedEmbed? {
    guard let embedData = metadata.embed else { return nil }
    return convertEmbed(embedData)
  }

  var sendState: MessageSendState { currentSendState }

  // MARK: - Hashable

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  static func == (lhs: MLSMessageAdapter, rhs: MLSMessageAdapter) -> Bool {
    lhs.id == rhs.id && lhs.text == rhs.text && lhs.sendState == rhs.sendState
      && lhs.reactions == rhs.reactions
  }

  // MARK: - Embed Conversion

  private func convertEmbed(_ embed: MLSEmbedData) -> UnifiedEmbed? {
    switch embed {
    case .link(let link):
      guard let url = URL(string: link.url) else { return nil }
      let thumbURL = link.thumbnailURL.flatMap { URL(string: $0) }
      return .link(
        LinkEmbedData(
          url: url,
          title: link.title,
          description: link.description,
          thumbnailURL: thumbURL
        )
      )
    case .gif(let gif):
      guard let url = URL(string: gif.mp4URL) else { return nil }
      let previewURL = gif.thumbnailURL.flatMap { URL(string: $0) }
      return .gif(
        GIFEmbedData(
          url: url,
          previewURL: previewURL,
          width: gif.width,
          height: gif.height
        )
      )
    case .post(let post):
      return .post(
        PostEmbedData(
          uri: post.uri,
          cid: post.cid ?? "",
          authorDID: post.authorDid,
          authorHandle: post.authorHandle,
          text: post.text
        )
      )
    }
  }
}
