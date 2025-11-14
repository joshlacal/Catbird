import SwiftUI

#if os(iOS)

/// Custom message view for MLS encrypted messages with embed support
struct MLSMessageView: View {
  let text: String
  let embed: MLSEmbedData?
  let isCurrentUser: Bool
  let timestamp: Date
  let senderName: String
  let senderAvatarURL: URL?
  let messageState: MessageSendState? // nil for confirmed messages
  let onRetry: (() -> Void)? // Retry action for failed messages

  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme
  @Binding var navigationPath: NavigationPath

  var body: some View {
    HStack(alignment: .bottom, spacing: DesignTokens.Spacing.sm) {
      // Avatar for other users
      if !isCurrentUser {
        AsyncProfileImage(url: senderAvatarURL, size: DesignTokens.Size.avatarSM)
          .frame(width: DesignTokens.Size.avatarSM, height: DesignTokens.Size.avatarSM)
      }

      VStack(alignment: isCurrentUser ? .trailing : .leading, spacing: DesignTokens.Spacing.xs) {
        // Sender name (for other users only)
        if !isCurrentUser {
          Text(senderName)
            .designCaption()
            .foregroundColor(.secondary)
            .padding(.horizontal, DesignTokens.Spacing.sm)
        }

        // Message bubble
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
        // Text content
        if !text.isEmpty {
          Text(text)
            .designBody()
            .foregroundColor(isCurrentUser ? .white : .primary)
        }

        // Embed rendering
        if let embed = embed {
          embedView(for: embed)
        }

        // Timestamp and state indicator
        HStack(spacing: DesignTokens.Spacing.xs) {
          Spacer()

          // State indicator for optimistic messages
          if let state = messageState {
            stateIndicator(for: state)
          }

          Text(formatTimestamp(timestamp))
            .designCaption()
            .foregroundColor(isCurrentUser ? .white.opacity(0.7) : .secondary)
        }
      }
      .padding(DesignTokens.Spacing.base)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Size.radiusMD)
          .fill(isCurrentUser ? Color.accentColor : Color.gray.opacity(0.2))
      )
      .frame(maxWidth: 280, alignment: isCurrentUser ? .trailing : .leading)
      }
      .frame(maxWidth: .infinity, alignment: isCurrentUser ? .trailing : .leading)

      // Spacer for current user messages (avatar on right, implicit)
      if isCurrentUser {
        Spacer()
          .frame(width: DesignTokens.Size.avatarSM)
      }
    }
  }

  // MARK: - Embed Rendering

  @ViewBuilder
  private func embedView(for embed: MLSEmbedData) -> some View {
    switch embed {
    case .record(let recordEmbed):
      MLSRecordEmbedLoader(recordEmbed: recordEmbed, navigationPath: $navigationPath)

    case .link(let linkEmbed):
      MLSLinkCardView(linkEmbed: linkEmbed)

    case .gif(let gifEmbed):
      MLSGIFView(gifEmbed: gifEmbed)
    }
  }

  // MARK: - State Indicator

  @ViewBuilder
  private func stateIndicator(for state: MessageSendState) -> some View {
    Group {
      switch state {
      case .sending:
        Image(systemName: "clock")
          .symbolEffect(.pulse)
          .foregroundColor(isCurrentUser ? .white.opacity(0.7) : .secondary)
          .help("Sending...")

      case .sent:
        Image(systemName: "checkmark")
          .foregroundColor(isCurrentUser ? .white.opacity(0.7) : .secondary)
          .help("Sent")

      case .failed(let errorMessage):
        Button {
          onRetry?()
        } label: {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(.red)
        }
        .buttonStyle(.plain)
        .help("Failed to send. Tap to retry.\n\(errorMessage)")
      }
    }
    .font(.caption2)
  }

  // MARK: - Helpers

  private func formatTimestamp(_ date: Date) -> String {
    let calendar = Calendar.current
    let now = Date()

    if calendar.isDateInToday(date) {
      return date.formatted(date: .omitted, time: .shortened)
    } else if calendar.isDateInYesterday(date) {
      return "Yesterday \(date.formatted(date: .omitted, time: .shortened))"
    } else if let daysAgo = calendar.dateComponents([.day], from: date, to: now).day, daysAgo < 7 {
      return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    } else {
      return date.formatted(date: .abbreviated, time: .shortened)
    }
  }
}

// MARK: - Preview

#Preview {
    @Previewable @Environment(AppState.self) var appState
  VStack(spacing: 20) {
    // Plain text message
    MLSMessageView(
      text: "Hello! This is a test message.",
      embed: nil,
      isCurrentUser: false,
      timestamp: Date(),
      senderName: "Alice",
      senderAvatarURL: nil,
      messageState: nil,
      onRetry: nil,
      navigationPath: .constant(NavigationPath())
    )

    // Sending message (optimistic)
    MLSMessageView(
      text: "Sending message...",
      embed: nil,
      isCurrentUser: true,
      timestamp: Date(),
      senderName: "You",
      senderAvatarURL: nil,
      messageState: .sending,
      onRetry: nil,
      navigationPath: .constant(NavigationPath())
    )

    // Failed message
    MLSMessageView(
      text: "Failed to send",
      embed: nil,
      isCurrentUser: true,
      timestamp: Date(),
      senderName: "You",
      senderAvatarURL: nil,
      messageState: .failed("Network error"),
      onRetry: { print("Retry tapped") },
      navigationPath: .constant(NavigationPath())
    )

    // Message with GIF embed
    MLSMessageView(
      text: "Check this out!",
      embed: .gif(MLSGIFEmbed(
        tenorURL: "https://tenor.com/view/...",
        mp4URL: "https://media.tenor.com/.../video.mp4",
        title: "Dancing Cat"
      )),
      isCurrentUser: true,
      timestamp: Date(),
      senderName: "You",
      senderAvatarURL: nil,
      messageState: nil,
      onRetry: nil,
      navigationPath: .constant(NavigationPath())
    )

    // Message with link embed
    MLSMessageView(
      text: "Interesting article",
      embed: .link(MLSLinkEmbed(
        url: "https://example.com/article",
        title: "The Future of Decentralized Social Media",
        description: "An in-depth look at how AT Protocol is changing social networking...",
        domain: "example.com"
      )),
      isCurrentUser: false,
      timestamp: Date().addingTimeInterval(-3600),
      senderName: "Bob",
      senderAvatarURL: nil,
      messageState: nil,
      onRetry: nil,
      navigationPath: .constant(NavigationPath())
    )
  }
  .padding()
  .environment(AppStateManager.shared)
}

#endif
