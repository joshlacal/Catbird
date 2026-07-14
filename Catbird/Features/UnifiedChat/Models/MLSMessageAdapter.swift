import CatbirdMLSCore
import Foundation
import Petrel
import PetrelCatbird

struct MLSMessageDisplayOrderKey: Comparable, Sendable {
  let epoch: Int
  let sequence: Int
  let sentAt: Date
  let messageID: String

  static func < (lhs: MLSMessageDisplayOrderKey, rhs: MLSMessageDisplayOrderKey) -> Bool {
    // The server `sequence` is the canonical, conversation-global delivery
    // order for MLS messages and is the SOLE ordering authority. epoch is not
    // used: sequence is already globally monotonic across epochs.
    //
    // This comparator must be a strict weak ordering — Array.sort produces
    // undefined, visibly out-of-order results otherwise. The previous version
    // compared some pairs by `sequence` and others by `sentAt`; because server-
    // sequence order and wall-clock order can disagree (optimistic local sends
    // with seq=0, redelivered past-epoch messages, sender clock skew), that mix
    // was INTRANSITIVE (A<B by seq, B<C by time, C<A by time) and corrupted the
    // whole sort.
    let lhsHasSeq = lhs.sequence > 0
    let rhsHasSeq = rhs.sequence > 0

    // Both confirmed: server sequence wins, full stop.
    if lhsHasSeq && rhsHasSeq {
      if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
      return lhs.messageID < rhs.messageID
    }
    // Exactly one confirmed: the sequenced (delivered) message always precedes a
    // not-yet-sequenced one (an optimistic local send, or a row whose seq has
    // not loaded yet — both are the newest content and belong at the bottom).
    if lhsHasSeq != rhsHasSeq {
      return lhsHasSeq
    }
    // Neither sequenced yet: fall back to send time, then id for stability.
    if lhs.sentAt != rhs.sentAt { return lhs.sentAt < rhs.sentAt }
    return lhs.messageID < rhs.messageID
  }
}

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
    let isEdited: Bool
    let editedAt: Date?
    let isTombstone: Bool
    let deletedAt: Date?
  }

  private let metadata: MessageMetadata
  /// Stable collection-view identity. Equals `id` except for messages that
  /// confirmed an optimistic pending send, which keep the pending entry's
  /// identity so the bubble reconfigures in place (no delete+insert flicker).
  let diffableID: String
  let currentUserDID: String
  let senderProfile: MLSProfileData?
  private let reactionsList: [MLSMessageReaction]
  private let currentSendState: MessageSendState
  let originalMessage: DecryptedMLSMessage

  init(
    messageView: BlueCatbirdMlsChatDefs.MessageView,
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
      validationFailureReason: nil,
      isEdited: false,
      editedAt: nil,
      isTombstone: false,
      deletedAt: nil
    )
    self.originalMessage = DecryptedMLSMessage(
      messageView: messageView,
      payload: payload,
      senderDID: senderDID
    )
    self.metadata = metadata
    self.diffableID = metadata.id
    self.currentUserDID = currentUserDID
    self.senderProfile = senderProfile
    self.reactionsList = reactions
    self.currentSendState = sendState
  }

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
      validationFailureReason: nil,
      isEdited: false,
      editedAt: nil,
      isTombstone: false,
      deletedAt: nil
    )
    self.diffableID = message.id
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
    isEdited: Bool = false,
    editedAt: Date? = nil,
    isTombstone: Bool = false,
    deletedAt: Date? = nil,
    senderProfile: MLSProfileData? = nil,
    reactions: [MLSMessageReaction] = [],
    embed: MLSEmbedData? = nil,
    sendState: MessageSendState = .sent,
    epoch: Int? = nil,
    sequence: Int? = nil,
    processingError: String? = nil,
    processingAttempts: Int? = nil,
    validationFailureReason: String? = nil,
    diffableID: String? = nil
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
      validationFailureReason: validationFailureReason,
      isEdited: isEdited,
      editedAt: editedAt,
      isTombstone: isTombstone,
      deletedAt: deletedAt
    )
    self.diffableID = diffableID ?? id
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

  /// The server sequence is scoped to the stable conversation, while MLS epoch is
  /// scoped to the current group and may reset when recovery rotates the group.
  var displayOrderKey: MLSMessageDisplayOrderKey {
    MLSMessageDisplayOrderKey(
      epoch: metadata.epoch ?? 0,
      sequence: metadata.sequence ?? 0,
      sentAt: metadata.sentAt,
      messageID: metadata.id
    )
  }

  static func sortsInDisplayOrder(_ lhs: MLSMessageAdapter, _ rhs: MLSMessageAdapter) -> Bool {
    lhs.displayOrderKey < rhs.displayOrderKey
  }

  static func sortedForDisplay(_ messages: [MLSMessageAdapter]) -> [MLSMessageAdapter] {
    var sequenced: [MLSMessageAdapter] = []
    var unsequenced: [MLSMessageAdapter] = []
    sequenced.reserveCapacity(messages.count)
    unsequenced.reserveCapacity(messages.count)

    for message in messages {
      if (message.mlsSequence ?? 0) > 0 {
        sequenced.append(message)
      } else {
        unsequenced.append(message)
      }
    }

    sequenced.sort { lhs, rhs in
      let lhsSequence = lhs.mlsSequence ?? 0
      let rhsSequence = rhs.mlsSequence ?? 0
      if lhsSequence != rhsSequence { return lhsSequence < rhsSequence }
      return lhs.id < rhs.id
    }
    guard !unsequenced.isEmpty else { return sequenced }

    unsequenced.sort { lhs, rhs in
      if lhs.sentAt != rhs.sentAt { return lhs.sentAt < rhs.sentAt }
      return lhs.id < rhs.id
    }

    var result: [MLSMessageAdapter] = []
    result.reserveCapacity(messages.count)
    var nextSequencedIndex = 0
    for row in unsequenced {
      while
        nextSequencedIndex < sequenced.count,
        sequenced[nextSequencedIndex].sentAt <= row.sentAt
      {
        result.append(sequenced[nextSequencedIndex])
        nextSequencedIndex += 1
      }
      result.append(row)
    }
    result.append(contentsOf: sequenced[nextSequencedIndex...])
    return result
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

  var canEdit: Bool {
    isFromCurrentUser && !isTombstone && embed == nil && isServerConfirmed
  }

  var canUnsend: Bool {
    isFromCurrentUser && !isTombstone && isServerConfirmed
  }

  private var isServerConfirmed: Bool {
    guard !id.hasPrefix(PendingMLSSend.idPrefix) else { return false }
    switch sendState {
    case .sent, .delivered, .read:
      return true
    case .sending, .failed:
      return false
    }
  }

  var isEdited: Bool { metadata.isEdited }

  var editedAt: Date? { metadata.editedAt }

  var isTombstone: Bool { metadata.isTombstone }

  var deletedAt: Date? { metadata.deletedAt }

  static func dateFromUnixMilliseconds(_ milliseconds: Int64?) -> Date? {
    guard let milliseconds else { return nil }
    return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
  }

  /// True if the message has valid decrypted content and is not a placeholder/error state
  /// Used by UI to suppress reaction display for undecryptable messages
  var isDecryptedAndValid: Bool {
    // A message is valid if it has non-empty text and no processing errors
    !text.isEmpty && processingError == nil && validationFailureReason == nil
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
      && lhs.reactions == rhs.reactions && lhs.isEdited == rhs.isEdited
      && lhs.editedAt == rhs.editedAt && lhs.isTombstone == rhs.isTombstone
      && lhs.deletedAt == rhs.deletedAt
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
    case .image(let imageEmbed):
      return .image(
        ImageEmbedData(
          blobId: imageEmbed.blobId,
          key: imageEmbed.key,
          iv: imageEmbed.iv,
          sha256: imageEmbed.sha256,
          contentType: imageEmbed.contentType,
          size: imageEmbed.size,
          width: imageEmbed.width,
          height: imageEmbed.height,
          altText: imageEmbed.altText,
          blurhash: imageEmbed.blurhash
        )
      )
    case .audio(let audioEmbed):
      return .audio(
        AudioEmbedData(
          blobId: audioEmbed.blobId,
          key: audioEmbed.key,
          iv: audioEmbed.iv,
          sha256: audioEmbed.sha256,
          contentType: audioEmbed.contentType,
          size: audioEmbed.size,
          durationMs: audioEmbed.durationMs,
          waveform: audioEmbed.waveform,
          transcript: audioEmbed.transcript
        )
      )
    case .unknown:
      return nil
    }
  }
}
