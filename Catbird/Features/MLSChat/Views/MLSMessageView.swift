import SwiftUI
import CatbirdMLSCore

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
  let processingError: String? // Processing/decryption error
  let processingAttempts: Int // Number of processing attempts
  let validationFailureReason: String? // Validation failure reason

  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme
  @Binding var navigationPath: NavigationPath
  @State private var showingErrorDetails = false

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
        // Processing error banner (if present)
        if let error = processingError {
          processingErrorBanner(error: error)
        }

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
      .mlsBubbleBackground(isCurrentUser: isCurrentUser, hasError: processingError != nil)
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

  // MARK: - Processing Error Banner

  @ViewBuilder
  private func processingErrorBanner(error: String) -> some View {
    Button {
      showingErrorDetails = true
    } label: {
      HStack(spacing: DesignTokens.Spacing.xs) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundColor(.orange)
          .accessibilityLabel("Warning")

        Text("Message processing error")
          .designCaption()
          .foregroundColor(.primary)

        Spacer()

        Image(systemName: "info.circle")
          .font(.caption)
          .foregroundColor(.secondary)
          .accessibilityLabel("Tap for details")
      }
      .padding(DesignTokens.Spacing.sm)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Size.radiusSM)
          .fill(Color.orange.opacity(0.15))
      )
    }
    .buttonStyle(.plain)
    .accessibilityHint("Tap to view error details and recovery options")
    .sheet(isPresented: $showingErrorDetails) {
      errorDetailsSheet
    }
  }

  // MARK: - Error Details Sheet

  @ViewBuilder
  private var errorDetailsSheet: some View {
    NavigationStack {
      List {
        Section {
          HStack {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: 40))
              .foregroundColor(.orange)
              .frame(width: 60)
              .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
              Text("Message Processing Error")
                .designCallout()
                .foregroundColor(.primary)
              Text("This message could not be decrypted")
                .designFootnote()
                .foregroundColor(.secondary)
            }
          }
          .padding(.vertical, DesignTokens.Spacing.sm)
        }

        Section("Error Details") {
          if let error = processingError {
            DetailRow(label: "Error Message", value: error)
          }

          if let validationReason = validationFailureReason {
            DetailRow(label: "Validation Failure", value: validationReason)
          }

          DetailRow(label: "Processing Attempts", value: "\(processingAttempts)")
          DetailRow(label: "Timestamp", value: formatTimestamp(timestamp))
        }

        Section {
          VStack(alignment: .leading, spacing: DesignTokens.Spacing.base) {
            Text("Recovery Options")
              .designCallout()
              .foregroundColor(.primary)

            Text("To recover from this error, you may need to:")
              .designFootnote()
              .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
              BulletPoint(text: "Wait for the sender to resend the message")
              BulletPoint(text: "Leave and rejoin the conversation to sync encryption keys")
              BulletPoint(text: "Contact the conversation administrator if the issue persists")
            }
            .designFootnote()
            .foregroundColor(.secondary)
          }
          .padding(.vertical, DesignTokens.Spacing.sm)
        }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("Message Error")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            showingErrorDetails = false
          }
        }
      }
    }
  }

  // MARK: - Embed Rendering

  @ViewBuilder
  private func embedView(for embed: MLSEmbedData) -> some View {
    switch embed {
    case .link(let linkEmbed):
      MLSLinkCardView(linkEmbed: linkEmbed)

    case .gif(let gifEmbed):
      MLSGIFView(gifEmbed: gifEmbed)

    case .post(let postEmbed):
      ChatPostEmbedView(postEmbed: postEmbed, navigationPath: $navigationPath)
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

      case .delivered:
        Image(systemName: "checkmark.circle")
          .foregroundColor(isCurrentUser ? .white.opacity(0.7) : .secondary)
          .help("Delivered")

      case .read:
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(isCurrentUser ? .white.opacity(0.7) : .secondary)
          .help("Read")

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

// MARK: - Helper Views

private struct DetailRow: View {
  let label: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      Text(label)
        .designFootnote()
        .foregroundColor(.secondary)
      Text(value)
        .designBody()
        .foregroundColor(.primary)
    }
    .padding(.vertical, DesignTokens.Spacing.xs)
  }
}

private struct BulletPoint: View {
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
      Text("•")
        .foregroundColor(.secondary)
      Text(text)
        .foregroundColor(.secondary)
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
      processingError: nil,
      processingAttempts: 0,
      validationFailureReason: nil,
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
      processingError: nil,
      processingAttempts: 0,
      validationFailureReason: nil,
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
      onRetry: { },

      processingError: nil,
      processingAttempts: 0,
      validationFailureReason: nil,
      navigationPath: .constant(NavigationPath())
    )

    // Message with processing error
    MLSMessageView(
      text: "[Encrypted]",
      embed: nil,
      isCurrentUser: false,
      timestamp: Date(),
      senderName: "Bob",
      senderAvatarURL: nil,
      messageState: nil,
      onRetry: nil,
      processingError: "Failed to decrypt: epoch key not found",
      processingAttempts: 3,
      validationFailureReason: "Missing epoch context",
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
      processingError: nil,
      processingAttempts: 0,
      validationFailureReason: nil,
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
      processingError: nil,
      processingAttempts: 0,
      validationFailureReason: nil,
      navigationPath: .constant(NavigationPath())
    )
  }
  .padding()
  .environment(AppStateManager.shared)
}

// MARK: - Message Bubble Background for MLS

private extension View {
  @ViewBuilder
  func mlsBubbleBackground(isCurrentUser: Bool, hasError: Bool) -> some View {
    let cornerRadius = DesignTokens.Size.radiusMD

    if hasError {
      // Error state - use orange tint
      self.background(
        RoundedRectangle(cornerRadius: cornerRadius)
          .fill(Color.orange.opacity(0.2))
      )
    } else {
      // Standard solid bubble background (no glass effect on messages)
      self.background(
        RoundedRectangle(cornerRadius: cornerRadius)
          .fill(isCurrentUser ? Color.accentColor : Color.gray.opacity(0.2))
      )
    }
  }
}

#endif
