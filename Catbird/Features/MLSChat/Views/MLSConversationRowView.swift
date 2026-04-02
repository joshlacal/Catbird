import CatbirdMLSCore
import SwiftUI

#if os(iOS)

// MARK: - MLS Conversation Row View

struct MLSConversationRowView: View {
  let conversation: MLSConversationModel
  let participants: [MLSParticipantViewModel]
  let recentMemberChange: MemberChangeInfo?
  let unreadCount: Int
  var lastMessage: MLSLastMessagePreview? = nil

  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme

  private var hasUnread: Bool { unreadCount > 0 }

  private var lastMessageSenderName: String {
    guard let lastMessage else { return "" }
    let did = lastMessage.senderDID
    if did.lowercased() == appState.userDID.lowercased() {
      return "You"
    }
    if let participant = participants.first(where: { $0.id.lowercased() == did.lowercased() }) {
      if let name = participant.displayName, !name.isEmpty { return name }
      if !participant.handle.isEmpty { return participant.handle }
    }
    return ""
  }

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.base) {
      // Composite avatar for group chat
      MLSGroupAvatarView(
        participants: participants,
        size: DesignTokens.Size.avatarLG,
        groupAvatarData: conversation.avatarImageData,
        currentUserDID: appState.userDID
      )

      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        HStack(spacing: DesignTokens.Spacing.xs) {
          Text(conversationTitle)
            .designCallout()
            .fontWeight(hasUnread ? .semibold : .regular)
            .foregroundColor(.primary)
            .lineLimit(1)

          // E2EE indicator
          Image(systemName: "lock.shield.fill")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .accessibilityLabel("End-to-end encrypted")

          Spacer()

          // Unread count badge
          if unreadCount > 0 {
            ZStack {
              Circle()
                .fill(Color.accentColor)
                .frame(width: 22, height: 22)
              Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
            }
            .accessibilityLabel("\(unreadCount) unread messages")
          } else if conversation.unacknowledgedMemberChanges > 0 {
            ZStack {
              Circle()
                .fill(Color.blue)
                .frame(width: 20, height: 20)
              Text("\(conversation.unacknowledgedMemberChanges)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
            }
            .accessibilityLabel("\(conversation.unacknowledgedMemberChanges) member changes")
          }

          if let timestamp = conversation.lastMessageAt {
            Text(formatTimestamp(timestamp))
              .designCaption()
              .foregroundColor(hasUnread ? .accentColor : .secondary)
              .fontWeight(hasUnread ? .medium : .regular)
          }
        }

        HStack {
          if let change = recentMemberChange {
            HStack(spacing: 4) {
              Image(systemName: change.icon)
                .font(.system(size: 12))
                .foregroundColor(change.color)

              Text(change.text)
                .designFootnote()
                .foregroundColor(change.color)
            }
            .lineLimit(1)
          } else if let lastMessage {
            Text(lastMessageSenderName.isEmpty ? lastMessage.text : "\(lastMessageSenderName): \(lastMessage.text)")
              .designFootnote()
              .foregroundColor(.secondary)
              .lineLimit(1)
          } else {
            Text(conversation.joinMethod == .externalCommit ? "This device joined" : "Encrypted chat")
              .designFootnote()
              .foregroundColor(.secondary)
              .italic()
              .lineLimit(1)
          }

          Spacer()

          HStack(spacing: 2) {
            Image(systemName: "person.2.fill")
              .font(.system(size: 10))
              .foregroundColor(.secondary)
            Text("\(participants.count)")
              .designFootnote()
              .foregroundColor(.secondary)
          }
        }
      }
    }
    .spacingSM(.vertical)
    .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
  }

  private var conversationTitle: String {
    // Use conversation title if set (typically group chats)
    if let title = conversation.title, !title.isEmpty {
      return title
    }

    // For 1:1 conversations, show the other participant's name
    let currentUserDID = appState.userDID
    let others = participants.filter { $0.id.lowercased() != currentUserDID.lowercased() }
    if let other = others.first {
      return other.displayName ?? other.handle
    }

    return "Secure Chat"
  }

  private func formatTimestamp(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
      return date.formatted(date: .omitted, time: .shortened)
    } else if calendar.isDateInYesterday(date) {
      return "Yesterday"
    } else if calendar.dateComponents([.day], from: date, to: Date()).day! < 7 {
      return date.formatted(.dateTime.weekday(.abbreviated))
    } else {
      return date.formatted(date: .numeric, time: .omitted)
    }
  }
}

// MARK: - Supporting Models

struct MemberChangeInfo {
  let text: String
  let icon: String
  let color: Color

  static func from(
    event: MLSMembershipEventModel,
    profiles: [String: MLSProfileEnricher.ProfileData]
  ) -> MemberChangeInfo {
    let name = profiles[event.memberDID]?.displayName ??
               profiles[event.memberDID]?.handle ??
               "Someone"

    switch event.eventType {
    case .joined:
      return MemberChangeInfo(
        text: "\(name) joined",
        icon: "person.badge.plus",
        color: .green
      )
    case .left, .removed, .kicked:
      return MemberChangeInfo(
        text: "\(name) left",
        icon: "person.badge.minus",
        color: .orange
      )
    case .roleChanged:
      return MemberChangeInfo(
        text: "\(name) role changed",
        icon: "star.circle",
        color: .purple
      )
    case .deviceAdded:
      return MemberChangeInfo(
        text: "\(name) added device",
        icon: "laptopcomputer.and.iphone",
        color: .blue
      )
    case .deviceRemoved:
      return MemberChangeInfo(
        text: "\(name) removed device",
        icon: "iphone.slash",
        color: .orange
      )
    }
  }
}

#endif
