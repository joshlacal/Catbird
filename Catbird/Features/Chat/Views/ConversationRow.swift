#if os(iOS)
import SwiftUI
import Petrel

// MARK: - Conversation Row

struct ConversationRow: View {
  let convo: ChatBskyConvoDefs.ConvoView
  let currentUserDID: String  // Current user's DID to identify the other member

  // Use @State for properties loaded asynchronously
  @State private var avatarImage: Image?  // Managed by ProfileAvatarView now
  @State private var displayName: String = ""
  @State private var handle: String = ""

  @Environment(AppState.self) private var appState
  // Determine the other member involved in the conversation
  private var otherMember: ChatBskyActorDefs.ProfileViewBasic? {
    // Handle edge case where currentUserDID might be empty
    guard !currentUserDID.isEmpty else {
      // If we don't have the current user's DID, return the first member as a fallback
      return convo.members.first
    }

    // Find the first member whose DID does not match the current user's DID
    return convo.members.first(where: { $0.did.didString() != currentUserDID })
  }
  
  // Accessibility description for screen readers
  private var accessibilityDescription: String {
    let userName = displayName.isEmpty ? handle : displayName
    let unreadText = convo.unreadCount > 0 ? ", \(convo.unreadCount) unread message\(convo.unreadCount == 1 ? "" : "s")" : ""
    
    var messageText = "No messages yet"
    if let lastMessage = convo.lastMessage {
      // Extract last message text for accessibility
      messageText = "Has messages"
    }
    
    return "Conversation with \(userName)\(unreadText). \(messageText)"
  }

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.base) {
      ChatProfileAvatarView(profile: otherMember, size: 50)
        .accessibilityLabel("\(displayName.isEmpty ? handle : displayName) profile picture")

      VStack(alignment: .leading, spacing: 4) {
        Text(displayName.isEmpty ? handle : displayName)  // Show handle if display name is empty
          .enhancedAppHeadline()
          .lineLimit(1)
          .accessibilityAddTraits(.isHeader)

        // Last message preview
        if let lastMessage = convo.lastMessage {
          LastMessagePreview(lastMessage: lastMessage)
            .accessibilityLabel("Last message")
        } else {
          Text("No messages yet")
            .appSubheadline()
            .foregroundColor(.gray)
            .accessibilityLabel("No messages in this conversation yet")
        }
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 6) {
        // Timestamp of the last message
        if let lastMessage = convo.lastMessage, let date = lastMessageDate(lastMessage) {
          Text(formatDate(date))
            .appCaption()
            .foregroundColor(.gray)
            .accessibilityLabel("Last message \(formatDate(date))")
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
            .accessibilityLabel("\(convo.unreadCount) unread message\(convo.unreadCount == 1 ? "" : "s")")
            .accessibilityAddTraits(.isStaticText)
        } else {
          // Keep alignment consistent even when no badge
          Spacer().frame(height: 20)  // Adjust height to match badge approx
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityDescription)
    .accessibilityAddTraits(.isButton)
    .accessibilityHint("Double tap to open conversation")
    .spacingMD(.vertical)
    .padding(.horizontal, DesignTokens.Spacing.sm) // Add horizontal padding to ensure content doesn't touch edges
    .frame(maxWidth: .infinity) // Make the HStack take the full width available
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

    // Check if the account has been deleted (Bluesky uses "missing.invalid" for deleted accounts)
    if profile.handle.description == "missing.invalid" {
      displayName = "Deleted Account"
      handle = ""
    } else {
      displayName = profile.displayName ?? ""  // Use empty string if nil
      handle = "@\(profile.handle.description)"
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
          .appCallout()
          .foregroundColor(.gray)
          .lineLimit(2)
      case .chatBskyConvoDefsDeletedMessageView:
        Text("Message deleted")
              .appCallout()
          .foregroundColor(.gray)
          .italic()
      case .unexpected:
        Text("Unsupported message")
              .appCallout()
          .foregroundColor(.gray)
          .italic()
      }
    }
  }
}
#endif
