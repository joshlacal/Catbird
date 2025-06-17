import SwiftUI
import Petrel

// MARK: - Conversation Row

struct ConversationRow: View {
  let convo: ChatBskyConvoDefs.ConvoView
  let did: String  // Needed to identify the other member

  // Use @State for properties loaded asynchronously
  @State private var avatarImage: Image?  // Managed by ProfileAvatarView now
  @State private var displayName: String = ""
  @State private var handle: String = ""

  // Determine the other member involved in the conversation
  private var otherMember: ChatBskyActorDefs.ProfileViewBasic? {
    // Find the first member whose DID does not match the current user's DID
    return convo.members.first(where: { $0.did.didString() != did }) ?? nil
  }

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.base) {
      ChatProfileAvatarView(profile: otherMember, size: 50)

      VStack(alignment: .leading, spacing: 4) {
        Text(displayName.isEmpty ? handle : displayName)  // Show handle if display name is empty
          .enhancedAppHeadline()
          .lineLimit(1)

        // Last message preview
        if let lastMessage = convo.lastMessage {
          LastMessagePreview(lastMessage: lastMessage)
        } else {
          Text("No messages yet")
            .appSubheadline()
            .foregroundColor(.gray)
        }
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 6) {
        // Timestamp of the last message
        if let lastMessage = convo.lastMessage, let date = lastMessageDate(lastMessage) {
          Text(formatDate(date))
            .appCaption()
            .foregroundColor(.gray)
        }

        // Unread message count badge
        if convo.unreadCount > 0 {
          Text("\(convo.unreadCount)")
            .appCaption()
            .fontWeight(.bold)
            .foregroundColor(.white)
            .spacingSM(.horizontal)
            .spacingSM(.vertical)
            .background(Color.blue)
            .clipShape(Capsule())
        } else {
          // Keep alignment consistent even when no badge
          Spacer().frame(height: 20)  // Adjust height to match badge approx
        }
      }
    }
    .spacingMD(.vertical)
    .onAppear {
      // Load profile details when the row appears
      loadProfileDetails()
    }
    // Consider adding context menu for mute/leave actions
  }

  // Helper to extract date from the last message union type
  private func lastMessageDate(_ lastMessage: ChatBskyConvoDefs.ConvoViewLastMessageUnion?) -> Date? {
    guard let message = lastMessage else { return nil }
    switch message {
    case .chatBskyConvoDefsMessageView(let msg):
      return msg.sentAt.date
    case .chatBskyConvoDefsDeletedMessageView(let deletedMsg):
      // Deleted messages might not have a useful timestamp for display,
      // or you might want to show when it was deleted if available.
      // For now, returning nil.
      return nil
    case .unexpected:
      return nil
    }
  }

  // Load display name and handle from the other member's profile
  private func loadProfileDetails() {
    guard let profile = otherMember else {
      displayName = "Unknown User"
      handle = ""
      return
    }

    displayName = profile.displayName ?? ""  // Use empty string if nil
    handle = "@\(profile.handle.description)"
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
          Text(messageView.sender.did.didString() == appState.currentUserDID ? "You: \(messageView.text)" : messageView.text)
          .appSubheadline()
          .foregroundColor(.gray)
          .lineLimit(2)
      case .chatBskyConvoDefsDeletedMessageView:
        Text("Message deleted")
          .appSubheadline()
          .foregroundColor(.gray)
          .italic()
      case .unexpected:
        Text("Unsupported message")
          .appSubheadline()
          .foregroundColor(.gray)
          .italic()
      }
    }
  }
}