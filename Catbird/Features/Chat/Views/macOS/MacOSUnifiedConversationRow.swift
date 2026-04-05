#if os(macOS)
import CatbirdMLSCore
import NukeUI
import Petrel
import SwiftUI

// MARK: - macOS Unified Conversation Row

/// Displays a single conversation row in the macOS sidebar, handling both Bluesky DM
/// and MLS encrypted conversation types with Mac-native density and styling.
@available(macOS 13.0, *)
struct MacOSUnifiedConversationRow: View {
  let item: UnifiedConversation
  let currentUserDID: String

  var body: some View {
    switch item {
    case .bluesky(let convo):
      blueskyRow(convo)
    case .mls(let convo, let participants, let unreadCount, let lastMessage, let memberChange, _):
      mlsRow(convo, participants: participants, unreadCount: unreadCount,
             lastMessage: lastMessage, memberChange: memberChange)
    }
  }

  // MARK: - Bluesky DM Row

  @ViewBuilder
  private func blueskyRow(_ convo: ChatBskyConvoDefs.ConvoView) -> some View {
    let otherMembers = convo.members.filter { $0.did.description != currentUserDID }

    HStack(spacing: 10) {
      // Avatar
      if let firstMember = otherMembers.first, let avatar = firstMember.avatar, let avatarURL = URL(string: avatar.description) {
        LazyImage(url: avatarURL) { state in
          if let image = state.image {
            image.resizable().scaledToFill()
          } else {
            Circle().fill(Color.gray.opacity(0.3))
          }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
      } else {
        Image(systemName: "person.circle.fill")
          .font(.system(size: 36))
          .foregroundStyle(.tertiary)
      }

      // Content
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(displayName(for: otherMembers))
            .font(.body)
            .fontWeight(convo.unreadCount > 0 ? .semibold : .regular)
            .lineLimit(1)

          Spacer()

          if let lastMessage = convo.lastMessage,
             case .chatBskyConvoDefsMessageView(let msg) = lastMessage {
            Text(msg.sentAt.date, style: .relative)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        HStack {
          if let lastMessage = convo.lastMessage {
            Text(lastMessageText(lastMessage))
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }

          Spacer()

          if convo.unreadCount > 0 {
            Text("\(convo.unreadCount)")
              .font(.caption2)
              .fontWeight(.semibold)
              .foregroundStyle(.white)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(.blue, in: Capsule())
          }
        }
      }
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }

  // MARK: - MLS Row

  @ViewBuilder
  private func mlsRow(
    _ convo: MLSConversationModel,
    participants: [MLSParticipantViewModel],
    unreadCount: Int,
    lastMessage: MLSLastMessagePreview?,
    memberChange: MemberChangeInfo?
  ) -> some View {
    HStack(spacing: 10) {
      // Group avatar
      groupAvatar(participants: participants)

      // Content
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          HStack(spacing: 4) {
            Image(systemName: "lock.fill")
              .font(.caption2)
              .foregroundStyle(.green)
            Text(groupName(convo, participants: participants))
              .font(.body)
              .fontWeight(unreadCount > 0 ? .semibold : .regular)
              .lineLimit(1)
          }

          Spacer()

          Text(convo.updatedAt, style: .relative)
              .font(.caption)
              .foregroundStyle(.secondary)
        }

        HStack {
          if let memberChange {
            Text(memberChange.text)
              .font(.subheadline)
              .foregroundStyle(.orange)
              .lineLimit(1)
          } else if let lastMessage {
            Text(lastMessage.text)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          } else {
            Text("\(participants.count) members")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }

          Spacer()

          if unreadCount > 0 {
            Text("\(unreadCount)")
              .font(.caption2)
              .fontWeight(.semibold)
              .foregroundStyle(.white)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(.blue, in: Capsule())
          }
        }
      }
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }

  // MARK: - Helpers

  private func displayName(for members: [ChatBskyActorDefs.ProfileViewBasic]) -> String {
    if members.isEmpty { return "Conversation" }
    if members.count == 1, let member = members.first {
      return member.displayName ?? member.handle.description
    }
    let names = members.prefix(3).map { $0.displayName ?? $0.handle.description }
    return names.joined(separator: ", ")
  }

  private func lastMessageText(_ message: ChatBskyConvoDefs.ConvoViewLastMessageUnion) -> String {
    switch message {
    case .chatBskyConvoDefsMessageView(let msg):
      return msg.text
    case .chatBskyConvoDefsDeletedMessageView:
      return "Message deleted"
    case .unexpected:
      return ""
    }
  }

  private func groupName(_ convo: MLSConversationModel, participants: [MLSParticipantViewModel]) -> String {
    if let title = convo.title, !title.isEmpty { return title }
    let otherParticipants = participants.filter { $0.id != currentUserDID }
    if otherParticipants.isEmpty { return "Group" }
    let names = otherParticipants.prefix(3).map { $0.displayName ?? $0.handle }
    return names.joined(separator: ", ")
  }

  @ViewBuilder
  private func groupAvatar(participants: [MLSParticipantViewModel]) -> some View {
    let otherParticipants = participants.filter { $0.id != currentUserDID }
    let displayParticipants = Array(otherParticipants.prefix(2))

    ZStack {
      if displayParticipants.count >= 2 {
        avatarImage(for: displayParticipants[1])
          .frame(width: 24, height: 24)
          .clipShape(Circle())
          .offset(x: 8, y: 8)

        avatarImage(for: displayParticipants[0])
          .frame(width: 24, height: 24)
          .clipShape(Circle())
          .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
          .offset(x: -4, y: -4)
      } else if let participant = displayParticipants.first {
        avatarImage(for: participant)
          .frame(width: 36, height: 36)
          .clipShape(Circle())
      } else {
        Image(systemName: "person.2.circle.fill")
          .font(.system(size: 36))
          .foregroundStyle(.tertiary)
      }
    }
    .frame(width: 36, height: 36)
  }

  @ViewBuilder
  private func avatarImage(for participant: MLSParticipantViewModel) -> some View {
    if let avatarURL = participant.avatarURL {
      LazyImage(url: avatarURL) { state in
        if let image = state.image {
          image.resizable().scaledToFill()
        } else {
          Circle().fill(Color.gray.opacity(0.3))
        }
      }
    } else {
      Circle()
        .fill(Color.gray.opacity(0.3))
        .overlay {
          Text(String((participant.displayName ?? participant.handle).prefix(1)).uppercased())
            .font(.caption2)
            .foregroundStyle(.white)
        }
    }
  }
}
#endif
