import SwiftUI

/// Displays grouped reactions below a message bubble
struct UnifiedMessageReactions: View {
  let reactions: [UnifiedReaction]
  let isCurrentUser: Bool
  var onReactionTapped: ((String) -> Void)? = nil
  var onReactionLongPress: ((String) -> Void)? = nil

  @Environment(\.colorScheme) private var colorScheme

  private var groupedReactions: [String: [UnifiedReaction]] {
    Dictionary(grouping: reactions, by: { $0.emoji })
  }

  var body: some View {
    HStack(spacing: 4) {
      if isCurrentUser {
        Spacer()
      }

      ForEach(Array(groupedReactions.keys.sorted()), id: \.self) { emoji in
        let reactionsForEmoji = groupedReactions[emoji] ?? []
        let count = reactionsForEmoji.count
        let userReacted = reactionsForEmoji.contains { $0.isFromCurrentUser }

        reactionPill(emoji: emoji, count: count, userReacted: userReacted)
          .onTapGesture {
            onReactionTapped?(emoji)
          }
          .highPriorityGesture(
            LongPressGesture(minimumDuration: 0.35)
              .onEnded { _ in
                onReactionLongPress?(emoji)
              }
          )
      }

      if !isCurrentUser {
        Spacer()
      }
    }
  }

  @ViewBuilder
  private func reactionPill(emoji: String, count: Int, userReacted: Bool) -> some View {
    HStack(spacing: 4) {
      Text(emoji)
        .font(.caption)

      if count > 1 {
        Text("\(count)")
          .font(.caption2)
          .fontWeight(.medium)
          .foregroundStyle(userReacted ? Color.accentColor : Color.secondary)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(userReacted ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .stroke(
              userReacted ? Color.accentColor.opacity(0.5) : Color.clear,
              lineWidth: 1
            )
        )
    )
    .animation(.easeInOut(duration: 0.2), value: userReacted)
    .animation(.easeInOut(duration: 0.2), value: count)
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 20) {
    UnifiedMessageReactions(
      reactions: [
        UnifiedReaction(messageID: "1", emoji: "👍", senderDID: "user1", isFromCurrentUser: true, reactedAt: nil),
        UnifiedReaction(messageID: "1", emoji: "👍", senderDID: "user2", isFromCurrentUser: false, reactedAt: nil),
        UnifiedReaction(messageID: "1", emoji: "❤️", senderDID: "user2", isFromCurrentUser: false, reactedAt: nil),
      ],
      isCurrentUser: false
    )

    UnifiedMessageReactions(
      reactions: [
        UnifiedReaction(messageID: "2", emoji: "😂", senderDID: "user1", isFromCurrentUser: false, reactedAt: nil),
      ],
      isCurrentUser: true
    )
  }
  .padding()
}
