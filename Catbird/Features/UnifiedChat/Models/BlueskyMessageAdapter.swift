import Foundation
import Petrel

/// Adapter that conforms ChatBskyConvoDefs.MessageView to UnifiedChatMessage
struct BlueskyMessageAdapter: UnifiedChatMessage {
  let messageView: ChatBskyConvoDefs.MessageView
  let currentUserDID: String
  let senderProfile: ChatBskyActorDefs.ProfileViewBasic?
  private let reactionViews: [ChatBskyConvoDefs.ReactionView]

  init(
    messageView: ChatBskyConvoDefs.MessageView,
    currentUserDID: String,
    senderProfile: ChatBskyActorDefs.ProfileViewBasic? = nil,
    reactions: [ChatBskyConvoDefs.ReactionView] = []
  ) {
    self.messageView = messageView
    self.currentUserDID = currentUserDID
    self.senderProfile = senderProfile
    self.reactionViews = reactions
  }

  // MARK: - UnifiedChatMessage

  var id: String { messageView.id }

  var text: String { messageView.text }

  var senderID: String { messageView.sender.did.didString() }

  var senderDisplayName: String? {
    if let profileName = senderProfile?.displayName, !profileName.isEmpty {
      return profileName
    }

    // Note: MessageViewSender only has `did` field per the AT Protocol spec
    // Profile display name/handle must come from senderProfile lookup

    if let profileHandle = senderProfile?.handle.description, !profileHandle.isEmpty {
      return profileHandle
    }

    return nil
  }

  var senderAvatarURL: URL? {
    guard let avatarString = senderProfile?.avatar?.uriString() else { return nil }
    return URL(string: avatarString)
  }

  var sentAt: Date {
    messageView.sentAt.date
  }

  var isFromCurrentUser: Bool {
    senderID == currentUserDID
  }

  var reactions: [UnifiedReaction] {
    reactionViews.map { reaction in
      let reactorDID = reaction.sender.did.didString()
      return UnifiedReaction(
        messageID: messageView.id,
        emoji: reaction.value,
        senderDID: reactorDID,
        isFromCurrentUser: reactorDID == currentUserDID,
        reactedAt: nil
      )
    }
  }

  var embed: UnifiedEmbed? {
    guard let embedUnion = messageView.embed else { return nil }
    return convertEmbed(embedUnion)
  }

  var sendState: MessageSendState { .sent }

  // MARK: - Hashable

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  static func == (lhs: BlueskyMessageAdapter, rhs: BlueskyMessageAdapter) -> Bool {
    lhs.id == rhs.id &&
    lhs.text == rhs.text &&
    lhs.reactions == rhs.reactions
  }

  // MARK: - Embed Conversion

  private func convertEmbed(_ embedUnion: ChatBskyConvoDefs.MessageViewEmbedUnion) -> UnifiedEmbed? {
    switch embedUnion {
    case .appBskyEmbedRecordView(let recordView):
      return convertRecord(recordView.record)
    case .unexpected:
      return nil
    }
  }

  private func convertRecord(_ recordUnion: AppBskyEmbedRecord.ViewRecordUnion?) -> UnifiedEmbed? {
    guard let recordUnion else { return nil }

    switch recordUnion {
    case .appBskyEmbedRecordViewRecord(let record):
      return .blueskyRecord(
        recordData: BlueskyRecordEmbedData(
          uri: record.uri.uriString(),
          cid: record.cid.string
        )
      )
    default:
      return nil
    }
  }
}
