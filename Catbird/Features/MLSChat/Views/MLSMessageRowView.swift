//
//  MLSMessageRowView.swift
//  Catbird
//
//  Message row for displaying pre-decrypted MLS messages
//

import SwiftUI
import OSLog

#if os(iOS)
import ExyteChat

/// Message row component with lazy decryption for MLS messages
/// Handles expired epoch keys gracefully with user-friendly error messages
struct MLSMessageRowView: View {
    let message: Message
    let conversationID: String
    @Binding var navigationPath: NavigationPath

    @Environment(AppState.self) private var appState
    @State private var decryptedText: String?
    @State private var embed: MLSEmbedData?
    @State private var errorMessage: String?
    @State private var isDecrypting = false

    private let logger = Logger(subsystem: "blue.catbird", category: "MLSMessageRow")
    private let storage = MLSStorage.shared

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
        VStack(alignment: message.user.isCurrentUser ? .trailing : .leading, spacing: DesignTokens.Spacing.xs) {
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
        MLSMessageView(
            text: decryptedText ?? message.text,
            embed: embed,
            isCurrentUser: message.user.isCurrentUser,
            timestamp: message.createdAt,
            senderName: message.user.name,
            senderAvatarURL: message.user.avatarURL,
            messageState: nil,
            onRetry: nil,
            navigationPath: $navigationPath
        )
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
            navigationPath: .constant(NavigationPath())
        )
        .environment(AppStateManager.shared)

        // Current user message
        MLSMessageRowView(
            message: Message(
                id: "2",
                user: User(id: "me", name: "You", avatarURL: nil, isCurrentUser: true),
                status: .sent,
                createdAt: Date(),
                text: "Hi there!"
            ),
            conversationID: "test-convo",
            navigationPath: .constant(NavigationPath())
        )
        .environment(AppStateManager.shared)
    }
    .padding()
}

#endif
