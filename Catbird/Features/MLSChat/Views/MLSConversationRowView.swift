import CatbirdMLSCore
import SwiftUI

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
    guard let lastMessage, !lastMessage.isSystemMessage else { return "" }
    let did = lastMessage.senderDID
    if did.lowercased() == appState.userDID.lowercased() {
      return String(localized: "You")
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
            .foregroundStyle(.green)
            .accessibilityLabel("End-to-end encrypted")

          if appState.mlsSyncIncompleteConversationIDs.contains(conversation.conversationID) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
              .font(.system(size: 12))
              .foregroundStyle(.orange)
              .accessibilityLabel("Couldn't update. Catbird will try again.")
              .accessibilityIdentifier("mls-sync-incomplete-row")
          }

          Spacer()

          // Unread count badge
          if unreadCount > 0 {
            ZStack {
              Circle()
                .fill(Color.accentColor)
                .frame(width: 22, height: 22)
              if unreadCount > 99 {
                Text("99+", comment: "Badge label when unread message count exceeds 99")
                  .font(.system(size: 11, weight: .bold))
                  .foregroundColor(.white)
              } else {
                Text(unreadCount, format: .number)
                  .font(.system(size: 11, weight: .bold))
                  .foregroundColor(.white)
              }
            }
            .accessibilityLabel(
              Text(
                "\(unreadCount) unread messages",
                comment: "Accessibility label for unread message count badge. %lld is the number of unread messages."
              )
            )
          } else if conversation.unacknowledgedMemberChanges > 0 {
            ZStack {
              Circle()
                .fill(Color.blue)
                .frame(width: 20, height: 20)
              Text(conversation.unacknowledgedMemberChanges, format: .number)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
            }
            .accessibilityLabel(
              Text(
                "\(conversation.unacknowledgedMemberChanges) member changes",
                comment: "Accessibility label for unacknowledged group membership changes badge. %lld is the number of changes."
              )
            )
          }

          if let timestamp = conversation.lastMessageAt {
            Text(formatTimestamp(timestamp))
              .designCaption()
              .lineLimit(1)
              .fixedSize(horizontal: true, vertical: false)
              .foregroundColor(hasUnread ? .accentColor : .secondary)
              .fontWeight(hasUnread ? .medium : .regular)
          }
        }

        Group {
          if let lastMessage {
            if lastMessageSenderName.isEmpty {
              Text(lastMessage.text)
                .foregroundColor(.secondary)
            } else {
              Text(
                "\(lastMessageSenderName): \(lastMessage.text)",
                comment: "Conversation row preview with sender prefix. %1$@ is the sender's name, %2$@ is the message preview."
              )
                .foregroundColor(.secondary)
            }
          } else if let change = recentMemberChange {
            Label(change.text, systemImage: change.icon)
              .foregroundColor(change.color)
          } else {
            Group {
              if conversation.joinMethod == .externalCommit {
                Text("This device joined")
              } else {
                Text("No messages yet")
              }
            }
            .foregroundColor(.secondary)
          }
        }
        .designFootnote()
        .lineLimit(2)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .spacingSM(.vertical)
    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
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

    return String(localized: "Secure Chat", comment: "Fallback title for an unnamed encrypted chat")
  }

  private func formatTimestamp(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
      return date.formatted(date: .omitted, time: .shortened)
    } else if calendar.isDateInYesterday(date) {
      return String(localized: "Yesterday", comment: "Relative date label for messages sent yesterday")
    } else if calendar.dateComponents([.day], from: date, to: Date()).day! < 7 {
      return date.formatted(.dateTime.weekday(.wide))
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
               String(localized: "Someone")

    switch event.eventType {
    case .joined:
      return MemberChangeInfo(
        text: String(localized: "\(name) joined", comment: "Conversation row preview when a member joins. %@ is the member's name."),
        icon: "person.badge.plus",
        color: .green
      )
    case .left, .removed, .kicked:
      return MemberChangeInfo(
        text: String(localized: "\(name) left"),
        icon: "person.badge.minus",
        color: .orange
      )
    case .roleChanged:
      return MemberChangeInfo(
        text: String(localized: "\(name) role changed", comment: "Conversation row preview when a member's admin role changes. %@ is the member's name."),
        icon: "star.circle",
        color: .purple
      )
    case .deviceAdded:
      return MemberChangeInfo(
        text: String(localized: "\(name) added device", comment: "Conversation row preview when a member adds a device. %@ is the member's name."),
        icon: "laptopcomputer.and.iphone",
        color: .blue
      )
    case .deviceRemoved:
      return MemberChangeInfo(
        text: String(localized: "\(name) removed device", comment: "Conversation row preview when a member removes a device. %@ is the member's name."),
        icon: "iphone.slash",
        color: .orange
      )
    }
  }
}
