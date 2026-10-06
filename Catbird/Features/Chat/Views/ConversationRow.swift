import SwiftUI
import Petrel

// MARK: - Conversation Row

struct ConversationRow: View {
  let convo: ChatBskyConvoDefs.ConvoView
  let currentUserDID: String  // Current user's DID to identify the other member

  @Environment(AppState.self) private var appState

  private var displayLabel: String {
    convo.displayTitle(currentUserDID: currentUserDID)
  }

  private var groupAvatarParticipants: [ChatParticipant] {
    convo.displayMembersExcludingCurrentUser(currentUserDID: currentUserDID).map { member in
      ChatParticipant(
        id: member.did.didString(),
        handle: member.handle.description,
        displayName: member.displayName,
        avatarURL: member.finalAvatarURL()
      )
    }
  }
  
  // Accessibility description for screen readers
  private var accessibilityDescription: String {
    let unreadText = convo.unreadCount > 0 ? ", \(convo.unreadCount) unread message\(convo.unreadCount == 1 ? "" : "s")" : ""
    let conversationKind = convo.isGroupConversation ? "Group chat" : "Conversation with"
    let mutedText = convo.muted ? ", muted" : ""

    var messageText = "No messages yet"
    if let lastMessage = convo.lastMessage {
      messageText = LastMessagePreview.previewText(
        for: lastMessage,
        currentUserDID: currentUserDID,
        groupMembers: convo.isGroupConversation ? convo.members : []
      )
      if let date = lastMessageDate(lastMessage) {
        messageText += ", \(formatDate(date))"
      }
    }

    return "\(conversationKind) \(displayLabel)\(unreadText)\(mutedText). \(messageText)"
  }

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.base) {
      avatarView
        .accessibilityLabel(convo.isGroupConversation ? "\(displayLabel) group picture" : "\(displayLabel) profile picture")

      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        HStack(spacing: DesignTokens.Spacing.xs) {
          Text(displayLabel)
            .designCallout()
            .fontWeight(convo.unreadCount > 0 ? .semibold : .regular)
            .foregroundColor(.primary)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)

          if let directMember = convo.directDisplayMember(currentUserDID: currentUserDID),
             !convo.isGroupConversation,
             let badgeKind = VerificationBadge.kind(
              for: directMember.verification,
              did: directMember.did
             ) {
            VerificationBadgeView(kind: badgeKind)
              .font(.caption)
          }

          if convo.muted {
            Image(systemName: "bell.slash.fill")
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
          }

          Spacer()

          // Unread message count badge
          if convo.unreadCount > 0 {
            Text(convo.unreadCount > 99 ? "99+" : "\(convo.unreadCount)")
              .font(.caption2.weight(.bold))
              .foregroundColor(.white)
              .padding(.horizontal, 6)
              .frame(minWidth: 22, minHeight: 22)
              .background(Capsule().fill(Color.accentColor))
              .accessibilityLabel("\(convo.unreadCount) unread message\(convo.unreadCount == 1 ? "" : "s")")
          }

          // Timestamp of the last message
          if let lastMessage = convo.lastMessage, let date = lastMessageDate(lastMessage) {
            Text(formatDate(date))
              .designCaption()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
              .foregroundColor(convo.unreadCount > 0 ? .accentColor : .secondary)
              .fontWeight(convo.unreadCount > 0 ? .medium : .regular)
              .accessibilityLabel("Last message \(formatDate(date))")
          }
        }

        if let lastMessage = convo.lastMessage {
          LastMessagePreview(
            lastMessage: lastMessage,
            groupMembers: convo.isGroupConversation ? convo.members : []
          )
        } else {
          Text("No messages yet")
            .designFootnote()
            .foregroundColor(.secondary)
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityDescription)
    .accessibilityAddTraits(.isButton)
    .accessibilityHint("Double tap to open conversation")
    .spacingSM(.vertical)
    .alignmentGuide(.listRowSeparatorLeading) { _ in
      DesignTokens.Size.avatarLG + DesignTokens.Spacing.base
    }
    .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
    // Consider adding context menu for mute/leave actions
  }

  @ViewBuilder
  private var avatarView: some View {
    if convo.isGroupConversation {
      ChatGroupAvatarView(
        participants: groupAvatarParticipants,
        size: DesignTokens.Size.avatarLG
      )
    } else {
      ChatProfileAvatarView(
        profile: convo.directDisplayMember(currentUserDID: currentUserDID),
        size: DesignTokens.Size.avatarLG
      )
    }
  }

  // Helper to extract date from the last message union type
  private func lastMessageDate(_ lastMessage: ChatBskyConvoDefs.ConvoViewLastMessageUnion?) -> Date? {
    guard let message = lastMessage else { return nil }
    switch message {
    case .chatBskyConvoDefsMessageView(let msg):
      return msg.sentAt.date
    case .chatBskyConvoDefsDeletedMessageView:
      // Deleted messages might not have a useful timestamp for display,
      // or you might want to show when it was deleted if available.
      // For now, returning nil.
      return nil
    case .chatBskyConvoDefsSystemMessageView(let systemMessage):
      return systemMessage.sentAt.date
    case .unexpected:
      return nil
    }
  }

  // Date formatting helper
  private func formatDate(_ date: Date) -> String {
    let calendar = Calendar.current
    let now = Date()

    if calendar.isDateInToday(date) {
      return date.formatted(date: .omitted, time: .shortened)
    } else if calendar.isDateInYesterday(date) {
      return "Yesterday"
    } else if let daysAgo = calendar.dateComponents([.day], from: date, to: now).day, daysAgo < 7 {
      // Show day name for dates within the last week
      let formatter = DateFormatter()
      formatter.dateFormat = "EEEE"  // e.g., "Monday"
      return formatter.string(from: date)
    } else {
      // Show short date for older dates
      return date.formatted(date: .numeric, time: .omitted)
    }
  }
}

// MARK: - Last Message Preview Helper View

struct LastMessagePreview: View {
  @Environment(AppState.self) private var appState
  let lastMessage: ChatBskyConvoDefs.ConvoViewLastMessageUnion
  var groupMembers: [ChatBskyActorDefs.ProfileViewBasic] = []

  private static func senderPrefix(
    for messageView: ChatBskyConvoDefs.MessageView,
    currentUserDID: String,
    groupMembers: [ChatBskyActorDefs.ProfileViewBasic]
  ) -> String {
    let senderDID = messageView.sender.did.didString()
    if senderDID == currentUserDID {
      return "You: "
    }
    guard let sender = groupMembers.first(where: { $0.did.didString() == senderDID }) else {
      return ""
    }
    let name = sender.chatDisplayName
    let firstName = name.split(separator: " ").first.map(String.init) ?? name
    return firstName.isEmpty ? "" : "\(firstName): "
  }

  /// Plain-text preview of a conversation's last message, shared by the row
  /// and its VoiceOver label.
  static func previewText(
    for lastMessage: ChatBskyConvoDefs.ConvoViewLastMessageUnion,
    currentUserDID: String,
    groupMembers: [ChatBskyActorDefs.ProfileViewBasic]
  ) -> String {
    switch lastMessage {
    case .chatBskyConvoDefsMessageView(let messageView):
      let prefix = senderPrefix(for: messageView, currentUserDID: currentUserDID, groupMembers: groupMembers)
      guard messageView.text.isEmpty, let embed = messageView.embed else {
        return "\(prefix)\(messageView.text)"
      }
      switch embed {
      case .chatBskyEmbedJoinLinkView:
        return "\(prefix)Sent a group invite"
      default:
        return "\(prefix)Shared a post"
      }
    case .chatBskyConvoDefsDeletedMessageView:
      return "Message deleted"
    case .chatBskyConvoDefsSystemMessageView(let systemMessage):
      let profiles = Dictionary(
        groupMembers.map { ($0.did.didString(), $0) },
        uniquingKeysWith: { first, _ in first }
      )
      let event = BlueskyMessageAdapter.parseSystemEvent(systemMessageView: systemMessage, relatedProfiles: profiles)
      return event.messageText.isEmpty ? "Group updated" : event.messageText
    case .unexpected:
      return "Unsupported message"
    }
  }

  var body: some View {
    Group {
      switch lastMessage {
      case .chatBskyConvoDefsMessageView:
        Text(Self.previewText(for: lastMessage, currentUserDID: appState.userDID, groupMembers: groupMembers))
          .designFootnote()
          .foregroundColor(.secondary)
          .lineLimit(2)
      case .chatBskyConvoDefsDeletedMessageView:
        Text("Message deleted")
          .designFootnote()
          .foregroundColor(.secondary)
          .italic()
      case .chatBskyConvoDefsSystemMessageView:
        Text(Self.previewText(for: lastMessage, currentUserDID: appState.userDID, groupMembers: groupMembers))
          .designFootnote()
          .foregroundColor(.secondary)
          .italic()
      case .unexpected:
        Text("Unsupported message")
          .designFootnote()
          .foregroundColor(.secondary)
          .italic()
      }
    }
    .lineLimit(2)
    .multilineTextAlignment(.leading)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
