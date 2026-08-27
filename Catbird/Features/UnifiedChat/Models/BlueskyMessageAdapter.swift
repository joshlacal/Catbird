import Foundation
import Petrel

/// Adapter that conforms ChatBskyConvoDefs.MessageView to UnifiedChatMessage
/// Adapter that conforms ChatBskyConvoDefs.MessageView and SystemMessageView to UnifiedChatMessage
struct BlueskyMessageAdapter: UnifiedChatMessage {
  let messageView: ChatBskyConvoDefs.MessageView?
  let systemMessageView: ChatBskyConvoDefs.SystemMessageView?
  let systemEvent: UnifiedSystemEvent?
  let systemGroupEvents: [UnifiedSystemEvent]?
  let isSystemGroup: Bool
  let isExpanded: Bool
  let currentUserDID: String
  let senderProfile: ChatBskyActorDefs.ProfileViewBasic?
  private let reactionViews: [ChatBskyConvoDefs.ReactionView]
  private let customID: String?
  private let customSentAt: Date?

  // MARK: - Initializers

  /// Initialize from standard user message
  init(
    messageView: ChatBskyConvoDefs.MessageView,
    currentUserDID: String,
    senderProfile: ChatBskyActorDefs.ProfileViewBasic? = nil,
    reactions: [ChatBskyConvoDefs.ReactionView] = []
  ) {
    self.messageView = messageView
    self.systemMessageView = nil
    self.systemEvent = nil
    self.systemGroupEvents = nil
    self.isSystemGroup = false
    self.isExpanded = false
    self.currentUserDID = currentUserDID
    self.senderProfile = senderProfile
    self.reactionViews = reactions
    self.customID = nil
    self.customSentAt = nil
  }

  /// Initialize from single system message
  init(
    systemMessageView: ChatBskyConvoDefs.SystemMessageView,
    relatedProfiles: [String: ChatBskyActorDefs.ProfileViewBasic] = [:]
  ) {
    self.messageView = nil
    self.systemMessageView = systemMessageView
    let event = Self.parseSystemEvent(systemMessageView: systemMessageView, relatedProfiles: relatedProfiles)
    self.systemEvent = event
    self.systemGroupEvents = nil
    self.isSystemGroup = false
    self.isExpanded = false
    self.currentUserDID = ""
    self.senderProfile = nil
    self.reactionViews = []
    self.customID = systemMessageView.id
    self.customSentAt = systemMessageView.sentAt.date
  }

  /// Initialize from collapsed/expanded system group
  init(
    systemGroupEvents: [UnifiedSystemEvent],
    groupID: String,
    isExpanded: Bool
  ) {
    self.messageView = nil
    self.systemMessageView = nil
    self.systemEvent = nil
    self.systemGroupEvents = systemGroupEvents
    self.isSystemGroup = true
    self.isExpanded = isExpanded
    self.currentUserDID = ""
    self.senderProfile = nil
    self.reactionViews = []
    self.customID = groupID
    self.customSentAt = systemGroupEvents.first?.sentAt ?? Date()
  }

  // MARK: - UnifiedChatMessage

  var id: String {
    customID ?? messageView?.id ?? UUID().uuidString
  }

  var text: String {
    if isSystemGroup, let events = systemGroupEvents {
      return "\(events.count) chat updates"
    }
    if let event = systemEvent {
      return event.messageText
    }
    return messageView?.text ?? ""
  }

  var isSystemMessage: Bool {
    systemMessageView != nil || isSystemGroup || systemEvent != nil
  }

  var replyContext: UnifiedMessageReplyContext? {
    guard let replyTo = messageView?.replyTo else { return nil }
    switch replyTo {
    case .chatBskyConvoDefsMessageView(let refView):
      let senderDID = refView.sender.did.didString()
      return UnifiedMessageReplyContext(
        kind: .message(
          id: refView.id,
          senderDID: senderDID,
          senderDisplayName: nil,
          text: refView.text
        ),
        referencedMessageID: refView.id,
        senderDisplayName: nil,
        previewText: refView.text,
        isTappable: true
      )
    case .chatBskyConvoDefsDeletedMessageView:
      return UnifiedMessageReplyContext(
        kind: .deleted,
        referencedMessageID: nil,
        senderDisplayName: nil,
        previewText: "Deleted message",
        isTappable: false
      )
    case .chatBskyConvoDefsMessageBeforeUserJoinedGroupView:
      return UnifiedMessageReplyContext(
        kind: .beforeUserJoined,
        referencedMessageID: nil,
        senderDisplayName: nil,
        previewText: "Message sent before you joined",
        isTappable: false
      )
    case .unexpected:
      return UnifiedMessageReplyContext(
        kind: .unexpected("Unsupported message"),
        referencedMessageID: nil,
        senderDisplayName: nil,
        previewText: "Unsupported message",
        isTappable: false
      )
    }
  }

  var attributedText: AttributedString {
    if isSystemMessage {
      return AttributedString(text)
    }
    guard let facets = messageView?.facets, !facets.isEmpty else {
      return ChatTextRenderer.attributedString(for: text)
    }

    guard let msg = messageView else {
      return ChatTextRenderer.attributedString(for: text)
    }

    let facetedText = AppBskyFeedPost(
      text: msg.text,
      entities: nil,
      facets: facets,
      reply: nil,
      embed: nil,
      langs: nil,
      labels: nil,
      tags: nil,
      createdAt: msg.sentAt
    ).facetsAsAttributedString

    return facetedText
  }

  var senderID: String {
    messageView?.sender.did.didString() ?? ""
  }

  var senderDisplayName: String? {
    if isSystemMessage { return nil }
    if let profileName = senderProfile?.displayName, !profileName.isEmpty {
      return profileName
    }

    if let profileHandle = senderProfile?.handle.description, !profileHandle.isEmpty {
      return profileHandle
    }

    return nil
  }

  var senderAvatarURL: URL? {
    if isSystemMessage { return nil }
    guard let avatarString = senderProfile?.avatar?.uriString() else { return nil }
    return URL(string: avatarString)
  }

  var sentAt: Date {
    customSentAt ?? messageView?.sentAt.date ?? Date()
  }

  var isFromCurrentUser: Bool {
    if isSystemMessage { return false }
    return senderID == currentUserDID
  }

  var reactions: [UnifiedReaction] {
    guard let msg = messageView else { return [] }
    return reactionViews.map { reaction in
      let reactorDID = reaction.sender.did.didString()
      return UnifiedReaction(
        messageID: msg.id,
        emoji: reaction.value,
        senderDID: reactorDID,
        isFromCurrentUser: reactorDID == currentUserDID,
        reactedAt: nil
      )
    }
  }

  var embed: UnifiedEmbed? {
    guard let embedUnion = messageView?.embed else { return nil }
    return convertEmbed(embedUnion)
  }

  var sendState: MessageSendState { .sent }

  // MARK: - Hashable

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(isExpanded)
    hasher.combine(isSystemGroup)
  }

  static func == (lhs: BlueskyMessageAdapter, rhs: BlueskyMessageAdapter) -> Bool {
    lhs.id == rhs.id &&
      lhs.text == rhs.text &&
      lhs.isExpanded == rhs.isExpanded &&
      lhs.isSystemGroup == rhs.isSystemGroup &&
      lhs.reactions == rhs.reactions &&
      lhs.replyContext == rhs.replyContext
  }

  // MARK: - System Event Parsing

  static func parseSystemEvent(
    systemMessageView: ChatBskyConvoDefs.SystemMessageView,
    relatedProfiles: [String: ChatBskyActorDefs.ProfileViewBasic]
  ) -> UnifiedSystemEvent {
    let sentAt = systemMessageView.sentAt.date
    let id = systemMessageView.id

    func name(for did: DID) -> String {
      let didStr = did.didString()
      if let profile = relatedProfiles[didStr] {
        if let displayName = profile.displayName, !displayName.isEmpty {
          return displayName
        }
        return "@" + profile.handle.description
      }
      return didStr
    }

    switch systemMessageView.data {
    case .chatBskyConvoDefsSystemMessageDataAddMember(let data):
      let memberName = name(for: data.member.did)
      let roleStr = data.role.rawValue
      let text = roleStr == "admin"
        ? "\(memberName) was added as an admin"
        : "\(memberName) was added to the group"
      return UnifiedSystemEvent(
        id: id,
        kind: .memberAdded(memberDID: data.member.did.didString(), role: roleStr),
        sentAt: sentAt,
        messageText: text,
        iconName: "person.badge.plus",
        referencedDIDs: [data.member.did.didString()],
        referencedNames: [data.member.did.didString(): memberName]
      )

    case .chatBskyConvoDefsSystemMessageDataRemoveMember(let data):
      let memberName = name(for: data.member.did)
      let removerName = name(for: data.removedBy.did)
      let text = data.member.did == data.removedBy.did
        ? "\(memberName) left the group"
        : "\(removerName) removed \(memberName)"
      return UnifiedSystemEvent(
        id: id,
        kind: .memberRemoved(memberDID: data.member.did.didString(), removedByDID: data.removedBy.did.didString()),
        sentAt: sentAt,
        messageText: text,
        iconName: "person.badge.minus",
        referencedDIDs: [data.member.did.didString(), data.removedBy.did.didString()],
        referencedNames: [
          data.member.did.didString(): memberName,
          data.removedBy.did.didString(): removerName
        ]
      )

    case .chatBskyConvoDefsSystemMessageDataMemberJoin(let data):
      let memberName = name(for: data.member.did)
      return UnifiedSystemEvent(
        id: id,
        kind: .memberJoined(memberDID: data.member.did.didString(), role: data.role.rawValue),
        sentAt: sentAt,
        messageText: "\(memberName) joined the group",
        iconName: "person.badge.plus",
        referencedDIDs: [data.member.did.didString()],
        referencedNames: [data.member.did.didString(): memberName]
      )

    case .chatBskyConvoDefsSystemMessageDataMemberLeave(let data):
      let memberName = name(for: data.member.did)
      return UnifiedSystemEvent(
        id: id,
        kind: .memberLeave(memberDID: data.member.did.didString()),
        sentAt: sentAt,
        messageText: "\(memberName) left the group",
        iconName: "person.badge.minus",
        referencedDIDs: [data.member.did.didString()],
        referencedNames: [data.member.did.didString(): memberName]
      )

    case .chatBskyConvoDefsSystemMessageDataLockConvo(let data):
      let lockerName = name(for: data.lockedBy.did)
      return UnifiedSystemEvent(
        id: id,
        kind: .convoLocked(byDID: data.lockedBy.did.didString()),
        sentAt: sentAt,
        messageText: "\(lockerName) locked the chat",
        iconName: "lock.fill",
        referencedDIDs: [data.lockedBy.did.didString()],
        referencedNames: [data.lockedBy.did.didString(): lockerName]
      )

    case .chatBskyConvoDefsSystemMessageDataUnlockConvo(let data):
      let unlockerName = name(for: data.unlockedBy.did)
      return UnifiedSystemEvent(
        id: id,
        kind: .convoUnlocked(byDID: data.unlockedBy.did.didString()),
        sentAt: sentAt,
        messageText: "\(unlockerName) unlocked the chat",
        iconName: "lock.open.fill",
        referencedDIDs: [data.unlockedBy.did.didString()],
        referencedNames: [data.unlockedBy.did.didString(): unlockerName]
      )

    case .chatBskyConvoDefsSystemMessageDataLockConvoPermanently(let data):
      let enderName = name(for: data.lockedBy.did)
      return UnifiedSystemEvent(
        id: id,
        kind: .convoEnded(byDID: data.lockedBy.did.didString()),
        sentAt: sentAt,
        messageText: "\(enderName) ended the chat",
        iconName: "lock.slash.fill",
        referencedDIDs: [data.lockedBy.did.didString()],
        referencedNames: [data.lockedBy.did.didString(): enderName]
      )

    case .chatBskyConvoDefsSystemMessageDataEditGroup(let data):
      let text: String
      if let newName = data.newName, !newName.isEmpty {
        text = "Group name changed to \"\(newName)\""
      } else {
        text = "Group name was updated"
      }
      return UnifiedSystemEvent(
        id: id,
        kind: .groupEdited(oldName: data.oldName, newName: data.newName),
        sentAt: sentAt,
        messageText: text,
        iconName: "pencil",
        referencedDIDs: [],
        referencedNames: [:]
      )

    case .chatBskyConvoDefsSystemMessageDataCreateJoinLink:
      return UnifiedSystemEvent(
        id: id,
        kind: .joinLinkCreated,
        sentAt: sentAt,
        messageText: "Join link created",
        iconName: "link.badge.plus"
      )

    case .chatBskyConvoDefsSystemMessageDataEditJoinLink:
      return UnifiedSystemEvent(
        id: id,
        kind: .joinLinkEdited,
        sentAt: sentAt,
        messageText: "Join link updated",
        iconName: "link"
      )

    case .chatBskyConvoDefsSystemMessageDataEnableJoinLink:
      return UnifiedSystemEvent(
        id: id,
        kind: .joinLinkEnabled,
        sentAt: sentAt,
        messageText: "Join link enabled",
        iconName: "link"
      )

    case .chatBskyConvoDefsSystemMessageDataDisableJoinLink:
      return UnifiedSystemEvent(
        id: id,
        kind: .joinLinkDisabled,
        sentAt: sentAt,
        messageText: "Join link disabled",
        iconName: "link"
      )

    case .unexpected:
      return UnifiedSystemEvent(
        id: id,
        kind: .generic("Chat updated"),
        sentAt: sentAt,
        messageText: "Chat updated",
        iconName: "info.circle"
      )
    }
  }

  // MARK: - Embed Conversion

  private func convertEmbed(_ embedUnion: ChatBskyConvoDefs.MessageViewEmbedUnion) -> UnifiedEmbed? {
    switch embedUnion {
    case .appBskyEmbedRecordView(let recordView):
      return convertRecord(recordView.record)
case .chatBskyEmbedJoinLinkView(let joinLinkView):
      return convertJoinLink(joinLinkView.joinLinkPreview)
    case .unexpected:
      return nil
    }
  }

  private func convertJoinLink(
    _ preview: ChatBskyEmbedJoinLink.ViewJoinLinkPreviewUnion
  ) -> UnifiedEmbed {
    switch preview {
    case .chatBskyGroupDefsJoinLinkPreviewView(let view):
      return .groupInvite(
        .preview(
          name: view.name,
          memberCount: view.memberCount,
          memberLimit: view.memberLimit,
          code: view.code
        )
      )
    case .chatBskyGroupDefsDisabledJoinLinkPreviewView(let view):
      return .groupInvite(.unavailable(code: view.code))
    case .chatBskyGroupDefsInvalidJoinLinkPreviewView(let view):
      return .groupInvite(.unavailable(code: view.code))
    case .unexpected:
      // Open union with unstable schemas: treat unknown members as unavailable
      // rather than dropping the embed (isKnownJoinLinkPreview pattern).
      return .groupInvite(.unavailable(code: nil))
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

/// Groups consecutive same-day system messages in Bluesky chat streams
enum BlueskySystemMessageGrouper {
  static func group(
    messages: [BlueskyMessageAdapter],
    expandedGroupIDs: Set<String> = []
  ) -> [BlueskyMessageAdapter] {
    var result: [BlueskyMessageAdapter] = []
    var currentSystemCluster: [BlueskyMessageAdapter] = []
    var currentClusterDate: Date? = nil

    func flushCluster() {
      guard !currentSystemCluster.isEmpty else { return }
      if currentSystemCluster.count < 4 {
        result.append(contentsOf: currentSystemCluster)
      } else {
        // Stable group ID based on first event in cluster
        let firstEvent = currentSystemCluster[0]
        let stableGroupID = "sysgroup_\(firstEvent.id)"
        let events = currentSystemCluster.compactMap { $0.systemEvent }
        let isExpanded = expandedGroupIDs.contains(stableGroupID)

        // Group header
        result.append(BlueskyMessageAdapter(
          systemGroupEvents: events,
          groupID: stableGroupID,
          isExpanded: isExpanded
        ))

        // If expanded, also include the individual items below the header
        if isExpanded {
          result.append(contentsOf: currentSystemCluster)
        }
      }
      currentSystemCluster.removeAll()
      currentClusterDate = nil
    }

    let calendar = Calendar.current

    for item in messages {
      if item.isSystemMessage && !item.isSystemGroup {
        if let clusterDate = currentClusterDate {
          if calendar.isDate(clusterDate, inSameDayAs: item.sentAt) {
            currentSystemCluster.append(item)
          } else {
            flushCluster()
            currentClusterDate = item.sentAt
            currentSystemCluster.append(item)
          }
        } else {
          currentClusterDate = item.sentAt
          currentSystemCluster.append(item)
        }
      } else {
        flushCluster()
        result.append(item)
      }
    }

    flushCluster()
    return result
  }
}
