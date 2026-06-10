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

  private var subtitleLabel: String? {
    convo.displaySubtitle(currentUserDID: currentUserDID)
  }
  
  // Accessibility description for screen readers
  private var accessibilityDescription: String {
    let unreadText = convo.unreadCount > 0 ? ", \(convo.unreadCount) unread message\(convo.unreadCount == 1 ? "" : "s")" : ""
    let conversationKind = convo.isGroupConversation ? "Group chat" : "Conversation with"
    
    let messageText = convo.lastMessage == nil ? "No messages yet" : "Has messages"
    
    return "\(conversationKind) \(displayLabel)\(unreadText). \(messageText)"
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

          Image(systemName: convo.isGroupConversation ? "person.3.fill" : "bubble.left.and.bubble.right")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)

          Spacer()

          // Unread message count badge
          if convo.unreadCount > 0 {
            ZStack {
              Circle()
                .fill(Color.accentColor)
                .frame(width: 22, height: 22)
              Text(convo.unreadCount > 99 ? "99+" : "\(convo.unreadCount)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
            }
            .accessibilityLabel("\(convo.unreadCount) unread message\(convo.unreadCount == 1 ? "" : "s")")
          }

          // Timestamp of the last message
          if let lastMessage = convo.lastMessage, let date = lastMessageDate(lastMessage) {
            Text(formatDate(date))
              .designCaption()
              .foregroundColor(convo.unreadCount > 0 ? .accentColor : .secondary)
              .fontWeight(convo.unreadCount > 0 ? .medium : .regular)
              .accessibilityLabel("Last message \(formatDate(date))")
          }
        }

        // Last message preview
        if let lastMessage = convo.lastMessage {
          HStack(spacing: DesignTokens.Spacing.xs) {
            if let subtitleLabel {
              Text(subtitleLabel)
                .designFootnote()
                .foregroundColor(.secondary)
                .lineLimit(1)

              Text("-")
                .designFootnote()
                .foregroundColor(.secondary)
            }

            LastMessagePreview(lastMessage: lastMessage)
              .accessibilityLabel("Last message")
          }
        } else {
          HStack(spacing: DesignTokens.Spacing.xs) {
            if let subtitleLabel {
              Text(subtitleLabel)
                .designFootnote()
                .foregroundColor(.secondary)
                .lineLimit(1)

              Text("-")
                .designFootnote()
                .foregroundColor(.secondary)
            }

            Text("No messages yet")
              .designFootnote()
              .foregroundColor(.secondary)
              .accessibilityLabel("No messages in this conversation yet")
          }
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityDescription)
    .accessibilityAddTraits(.isButton)
    .accessibilityHint("Double tap to open conversation")
    .spacingSM(.vertical)
    // Consider adding context menu for mute/leave actions
  }

  @ViewBuilder
  private var avatarView: some View {
    if convo.isGroupConversation {
      ZStack {
        Circle()
          .fill(Color.accentColor.opacity(0.14))
        Image(systemName: "person.3.fill")
          .font(.system(size: DesignTokens.Size.avatarLG * 0.38, weight: .semibold))
          .foregroundStyle(Color.accentColor)
      }
      .frame(width: DesignTokens.Size.avatarLG, height: DesignTokens.Size.avatarLG)
      .overlay(Circle().stroke(Color.gray.opacity(0.1), lineWidth: 1))
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

  var body: some View {
    Group {
      switch lastMessage {
      case .chatBskyConvoDefsMessageView(let messageView):
        Text(messageView.sender.did.didString() == appState.userDID ? "You: \(messageView.text)" : messageView.text)
          .designFootnote()
          .foregroundColor(.secondary)
          .lineLimit(2)
      case .chatBskyConvoDefsDeletedMessageView:
        Text("Message deleted")
          .designFootnote()
          .foregroundColor(.secondary)
          .italic()
      case .chatBskyConvoDefsSystemMessageView:
        Text("System message")
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
  }
}
