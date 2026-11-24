import SwiftUI
import Petrel

// MARK: - Conversation Row

struct ConversationRow: View {
  let convo: ChatBskyConvoDefs.ConvoView
  let currentUserDID: String  // Current user's DID to identify the other member

  @Environment(AppState.self) private var appState
  @Environment(\.locale) private var locale

  private var displayLabel: String {
    convo.displayTitle(currentUserDID: currentUserDID)
  }

  private var groupAvatarParticipants: [MLSParticipantViewModel] {
    convo.displayMembersExcludingCurrentUser(currentUserDID: currentUserDID).map { member in
      MLSParticipantViewModel(
        id: member.did.didString(),
        handle: member.handle.description,
        displayName: member.displayName,
        avatarURL: member.finalAvatarURL()
      )
    }
  }
  
  // Accessibility description for screen readers
  private var accessibilityDescription: String {
    var parts: [String] = []
    if convo.isGroupConversation {
      parts.append(
        String(
          localized: "Group chat \(displayLabel)",
          comment: "VoiceOver prefix for a group conversation row (%@ = group title)"
        )
      )
    } else {
      parts.append(
        String(
          localized: "Conversation with \(displayLabel)",
          comment: "VoiceOver prefix for a direct message row (%@ = participant name)"
        )
      )
    }

    if convo.unreadCount > 0 {
      parts.append(
        String(
          localized: "\(convo.unreadCount) unread messages",
          comment: "VoiceOver unread count for a conversation (%lld = unread message count)"
        )
      )
    }

    if convo.muted {
      parts.append(String(localized: "Muted", comment: "VoiceOver status when a conversation is muted"))
    }

    if let lastMessage = convo.lastMessage {
      let preview = LastMessagePreview.previewText(
        for: lastMessage,
        currentUserDID: currentUserDID,
        groupMembers: convo.isGroupConversation ? convo.members : []
      )
      if let date = lastMessageDate(lastMessage) {
        parts.append(
          String(
            localized: "\(preview), \(formatDate(date))",
            comment: "VoiceOver last message and timestamp (%1$@ = message preview, %2$@ = formatted timestamp)"
          )
        )
      } else {
        parts.append(preview)
      }
    } else {
      parts.append(String(localized: "No messages yet", comment: "Placeholder when a conversation has no messages"))
    }

    return parts.joined(separator: ", ")
  }

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.base) {
      avatarView
        .accessibilityLabel(
          convo.isGroupConversation
            ? Text("\(displayLabel) group picture", comment: "Accessibility label for group avatar (%@ = group title)")
            : Text("\(displayLabel) profile picture", comment: "Accessibility label for direct conversation avatar (%@ = participant name)")
        )

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
            Group {
              if convo.unreadCount > 99 {
                Text("99+", comment: "Badge text when unread message count exceeds 99")
              } else {
                Text(convo.unreadCount, format: .number)
              }
            }
            .font(.caption2.weight(.bold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(Capsule().fill(Color.accentColor))
            .accessibilityLabel(
              Text(
                "\(convo.unreadCount) unread messages",
                comment: "Accessibility label for unread message count badge (%lld = unread message count)"
              )
            )
          }

          // Timestamp of the last message
          if let lastMessage = convo.lastMessage, let date = lastMessageDate(lastMessage) {
            Text(formatDate(date))
              .designCaption()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
              .foregroundColor(convo.unreadCount > 0 ? .accentColor : .secondary)
              .fontWeight(convo.unreadCount > 0 ? .medium : .regular)
              .accessibilityLabel(
                Text(
                  "Last message \(formatDate(date))",
                  comment: "Accessibility label for last message timestamp (%@ = formatted date/time)"
                )
              )
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
      MLSGroupAvatarView(
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
      return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale))
    } else if calendar.isDateInYesterday(date) {
      return String(localized: "Yesterday", comment: "Timestamp label for messages sent yesterday")
    } else if let daysAgo = calendar.dateComponents([.day], from: date, to: now).day, daysAgo < 7 {
      // Show day name for dates within the last week
      return date.formatted(.dateTime.locale(locale).weekday(.wide))
    } else {
      // Short date with a two-digit year, as in Messages ("9/29/26", not "9/29/2026").
      return date.formatted(.dateTime.locale(locale).month(.defaultDigits).day().year(.twoDigits))
    }
  }
}

// MARK: - Last Message Preview Helper View

struct LastMessagePreview: View {
  @Environment(AppState.self) private var appState
  let lastMessage: ChatBskyConvoDefs.ConvoViewLastMessageUnion
  var groupMembers: [ChatBskyActorDefs.ProfileViewBasic] = []

  private static func senderFirstName(
    for messageView: ChatBskyConvoDefs.MessageView,
    groupMembers: [ChatBskyActorDefs.ProfileViewBasic]
  ) -> String? {
    let senderDID = messageView.sender.did.didString()
    guard let sender = groupMembers.first(where: { $0.did.didString() == senderDID }) else {
      return nil
    }
    let name = sender.chatDisplayName
    let firstName = name.split(separator: " ").first.map(String.init) ?? name
    return firstName.isEmpty ? nil : firstName
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
      let isSelf = messageView.sender.did.didString() == currentUserDID
      let firstName = isSelf ? nil : senderFirstName(for: messageView, groupMembers: groupMembers)

      guard messageView.text.isEmpty, let embed = messageView.embed else {
        if isSelf {
          return String(
            localized: "You: \(messageView.text)",
            comment: "Last message preview when sent by current user (%@ = message text)"
          )
        }
        if let firstName {
          return String(
            localized: "\(firstName): \(messageView.text)",
            comment: "Last message preview in a group chat (%1$@ = sender name, %2$@ = message text)"
          )
        }
        return messageView.text
      }
      switch embed {
      case .chatBskyEmbedJoinLinkView:
        if isSelf {
          return String(
            localized: "You: Sent a group invite",
            comment: "Last message preview when the current user sent a group invite"
          )
        }
        if let firstName {
          return String(
            localized: "\(firstName): Sent a group invite",
            comment: "Last message preview in a group when a member sent a group invite (%@ = sender name)"
          )
        }
        return String(
          localized: "Sent a group invite",
          comment: "Last message preview when a group invite was sent"
        )
      default:
        if isSelf {
          return String(
            localized: "You: Shared a post",
            comment: "Last message preview when the current user shared a post"
          )
        }
        if let firstName {
          return String(
            localized: "\(firstName): Shared a post",
            comment: "Last message preview in a group when a member shared a post (%@ = sender name)"
          )
        }
        return String(
          localized: "Shared a post",
          comment: "Last message preview when a post was shared"
        )
      }
    case .chatBskyConvoDefsDeletedMessageView:
      return String(localized: "Message deleted", comment: "Last message preview when the message was deleted")
    case .chatBskyConvoDefsSystemMessageView(let systemMessage):
      let profiles = Dictionary(
        groupMembers.map { ($0.did.didString(), $0) },
        uniquingKeysWith: { first, _ in first }
      )
      let event = BlueskyMessageAdapter.parseSystemEvent(systemMessageView: systemMessage, relatedProfiles: profiles)
      return event.messageText.isEmpty
        ? String(localized: "Group updated", comment: "Fallback last message preview for a group system event")
        : event.messageText
    case .unexpected:
      return String(localized: "Unsupported message", comment: "Last message preview for an unsupported message type")
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
