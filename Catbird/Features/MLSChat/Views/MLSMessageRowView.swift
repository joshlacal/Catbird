import CatbirdMLSService
//
//  MLSMessageRowView.swift
//  Catbird
//
//  Message row for displaying pre-decrypted MLS messages
//

import CatbirdMLSCore
import OSLog
import SwiftUI

//import MCEmojiPicker

#if os(iOS)

  /// Message row component with lazy decryption for MLS messages
  /// Handles expired epoch keys gracefully with user-friendly error messages
  struct MLSMessageRowView: View {
    let message: Message
    let conversationID: String
    let reactions: [MLSMessageReaction]

    let currentUserDID: String?
    let participantProfiles: [String: MLSProfileEnricher.ProfileData]
    let onAddReaction: (String, String) -> Void  // (messageId, emoji)
    let onRemoveReaction: (String, String) -> Void  // (messageId, emoji)
    @Binding var navigationPath: NavigationPath

    @Environment(AppState.self) private var appState
    @State private var decryptedText: String?
    @State private var embed: MLSEmbedData?
    @State private var errorMessage: String?
    @State private var isDecrypting = false
    @State private var showingReactionPicker = false
    @State private var showingFullEmojiPicker = false
    @State private var showingReactionDetails = false
    @State private var selectedEmoji = ""

    private let logger = Logger(subsystem: "blue.catbird", category: "MLSMessageRow")
    private let storage = MLSStorage.shared

    /// Common reaction emojis for quick picker
    private let quickReactions = ["👍", "❤️", "😂", "😮", "😢", "🎉"]

    var body: some View {
      Group {
        if isDecrypting {
          loadingView
        } else if let errorMessage = errorMessage {
          errorView(errorMessage: errorMessage)
        } else {
          messageView
        }
      }
      .task {
        await performDecryption()
      }
    }

    // MARK: - Subviews

    private var loadingView: some View {
      HStack {
        ProgressView()
          .scaleEffect(0.8)
        Text("Decrypting...")
          .designCaption()
          .foregroundColor(.secondary)
      }
      .padding(DesignTokens.Spacing.base)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Size.radiusMD)
          .fill(Color.gray.opacity(0.1))
      )
      .frame(maxWidth: 280, alignment: message.user.isCurrentUser ? .trailing : .leading)
    }

    private func errorView(errorMessage: String) -> some View {
      VStack(
        alignment: message.user.isCurrentUser ? .trailing : .leading,
        spacing: DesignTokens.Spacing.xs
      ) {
        HStack(spacing: DesignTokens.Spacing.xs) {
          Image(systemName: "lock.trianglebadge.exclamationmark")
            .font(.caption)
            .foregroundColor(.orange)

          Text(errorMessage)
            .designCaption()
            .foregroundColor(.secondary)
            .multilineTextAlignment(message.user.isCurrentUser ? .trailing : .leading)
        }
        .padding(DesignTokens.Spacing.sm)
        .background(
          RoundedRectangle(cornerRadius: DesignTokens.Size.radiusMD)
            .fill(Color.orange.opacity(0.1))
        )
        .frame(maxWidth: 280, alignment: message.user.isCurrentUser ? .trailing : .leading)
      }
    }

    private var messageView: some View {
      VStack(
        alignment: message.user.isCurrentUser ? .trailing : .leading,
        spacing: DesignTokens.Spacing.xs
      ) {
        MLSMessageView(
          text: decryptedText ?? message.text,
          embed: embed,
          isCurrentUser: message.user.isCurrentUser,
          timestamp: message.createdAt,
          senderName: message.user.name,
          senderAvatarURL: message.user.avatarURL,
          messageState: nil,
          onRetry: nil,
          processingError: nil,
          processingAttempts: 0,
          validationFailureReason: nil,
          navigationPath: $navigationPath
        )
        .contextMenu {
          // Reaction quick picker in context menu
          ForEach(quickReactions, id: \.self) { emoji in
            Button {
              let isReacted = reactions.contains {
                $0.reaction == emoji && $0.senderDID == currentUserDID
              }
              if isReacted {
                onRemoveReaction(message.id, emoji)
              } else {
                onAddReaction(message.id, emoji)
              }
            } label: {
              let isReacted = reactions.contains {
                $0.reaction == emoji && $0.senderDID == currentUserDID
              }
              Text("\(emoji) \(isReacted ? "Remove" : "React")")
            }
          }

          Divider()

          // Open full emoji picker
          Button {
            showingFullEmojiPicker = true
          } label: {
            Label("More Reactions...", systemImage: "face.smiling")
          }
        }
        // MCEmojiPicker popover attached to the message
        .onChange(of: selectedEmoji) { _, newEmoji in
          if !newEmoji.isEmpty {
            onAddReaction(message.id, newEmoji)
            selectedEmoji = ""
          }
        }

        // Reactions display
        if !reactions.isEmpty {
          reactionsView
        }


      }
    }

    /// Display reactions under the message
    @ViewBuilder
    private var reactionsView: some View {
      let summaries = reactions.summarize(currentUserDID: currentUserDID)

      HStack(spacing: DesignTokens.Spacing.xs) {
        ForEach(summaries) { summary in
          // Using a custom view instead of Button to allow simultaneous gestures
          HStack(spacing: 2) {
            Text(summary.reaction)
              .font(.caption)

            if summary.count > 1 {
              Text("\(summary.count)")
                .font(.caption2)
                .foregroundColor(.secondary)
            }
          }
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(
            Capsule()
              .fill(
                summary.isReactedByCurrentUser
                  ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.15))
          )
          .contentShape(Capsule())
          .onTapGesture {
            // Toggle reaction
            if summary.isReactedByCurrentUser {
              onRemoveReaction(message.id, summary.reaction)
            } else {
              onAddReaction(message.id, summary.reaction)
            }
          }
          .onLongPressGesture(minimumDuration: 0.3) {
            showingReactionDetails = true
          }
        }
      }
      .frame(maxWidth: 280, alignment: message.user.isCurrentUser ? .trailing : .leading)
      .sheet(isPresented: $showingReactionDetails) {
        MLSReactionDetailsSheet(
          reactions: reactions,
          participantProfiles: participantProfiles,
          currentUserDID: currentUserDID,
          onAddReaction: { emoji in
            onAddReaction(message.id, emoji)
          },
          onRemoveReaction: { emoji in
            onRemoveReaction(message.id, emoji)
          }
        )
      }
    }

    // MARK: - Decryption Logic

    private func performDecryption() async {
      // Messages are already decrypted in loadConversationAndMessages()
      // Just use the pre-decrypted text from the Message object
      // DO NOT attempt re-decryption - that causes SecretReuseError!
      await MainActor.run {
        decryptedText = message.text
        isDecrypting = false
      }

      logger.debug("Using pre-decrypted text for message: \(message.id)")
    }
  }

  // MARK: - Preview

  #Preview {
    @Previewable @Environment(AppState.self) var appState
    VStack(spacing: 20) {
      // Loading state
      MLSMessageRowView(
        message: Message(
          id: "1",
          user: User(id: "alice", name: "Alice", avatarURL: nil, isCurrentUser: false),
          status: .sent,
          createdAt: Date(),
          text: "Hello!"
        ),
        conversationID: "test-convo",
        reactions: [
          MLSMessageReaction(messageId: "1", reaction: "👍", senderDID: "did:plc:user1"),
          MLSMessageReaction(messageId: "1", reaction: "👍", senderDID: "did:plc:user2"),
          MLSMessageReaction(messageId: "1", reaction: "❤️", senderDID: "did:plc:user1"),
        ],

        currentUserDID: "did:plc:user1",
        participantProfiles: [:],
        onAddReaction: { _, _ in },
        onRemoveReaction: { _, _ in },
        navigationPath: .constant(NavigationPath())
      )
      .environment(AppStateManager.shared)

      // Current user message with read receipt
      MLSMessageRowView(
        message: Message(
          id: "2",
          user: User(id: "me", name: "You", avatarURL: nil, isCurrentUser: true),
          status: .sent,
          createdAt: Date(),
          text: "Hi there!"
        ),
        conversationID: "test-convo",
        reactions: [],

        currentUserDID: "did:plc:me",
        participantProfiles: [:],
        onAddReaction: { _, _ in },
        onRemoveReaction: { _, _ in },
        navigationPath: .constant(NavigationPath())
      )
      .environment(AppStateManager.shared)
    }
    .padding()
  }

#endif
