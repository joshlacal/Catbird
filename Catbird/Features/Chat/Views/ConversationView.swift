import SwiftUI
import OSLog
import Petrel
//import MCEmojiPicker

#if os(iOS)

// MARK: - Conversation View (Using Unified Chat UI)

struct ConversationView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.horizontalSizeClass) private var hSizeClass
  @Environment(\.dismiss) private var dismiss
  let convoId: String

  private var contentMaxWidth: CGFloat {
    hSizeClass == .compact ? .infinity : 600
  }
  @State private var unifiedDataSource: BlueskyConversationDataSource?
  @State private var isInitialized = false
  private var chatNavigationPath: Binding<NavigationPath> {
    appState.navigationManager.pathBinding(for: 4)
  }

  @State private var showingReportSheet = false
  @State private var messageToReport: String?
  @State private var showingDeleteAlert = false
  @State private var messageToDelete: String?
  @State private var showingEmojiPicker = false
  @State private var selectedEmoji = ""
  @State private var emojiPickerMessageID: String?

  private var chatManager: ChatManager {
    appState.chatManager
  }

  private let logger = Logger(subsystem: "blue.catbird", category: "ConversationView")

  // MARK: - Data Source Management

  @MainActor
  private func ensureUnifiedDataSource() {
    guard unifiedDataSource == nil else { return }
    unifiedDataSource = BlueskyConversationDataSource(
      chatManager: chatManager,
      convoID: convoId,
      currentUserDID: appState.userDID
    )
  }

  @MainActor
  private func consumePendingShareIfNeeded() {
    guard let pending = appState.navigationManager.pendingChatShare,
          pending.convoId == convoId else { return }
    guard let draft = unifiedDataSource?.draft else { return }
    draft.value.attachedEmbed = pending.previewEmbed
    draft.value.postRef = pending.postRef
    appState.navigationManager.pendingChatShare = nil
  }

  /// Applies a Siri/Shortcuts draft (Messages-schema intents) targeting this
  /// conversation, only when the composer is empty so typed text is never lost.
  @MainActor
  private func consumePendingDraftIfNeeded() {
    guard let dataSource = unifiedDataSource,
          dataSource.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let text = ChatDraftHandoff.shared.consume(for: convoId) else { return }
    dataSource.draftText = text
  }

  var body: some View {
      Group {
        chatContent
          .task {
            // Initialize data source before loading
            ensureUnifiedDataSource()
            consumePendingShareIfNeeded()
            consumePendingDraftIfNeeded()
            if let dataSource = unifiedDataSource {
              await dataSource.loadMessages()
            }
            isInitialized = true
          }
    }
    .frame(maxWidth: contentMaxWidth)
    .navigationTitle(conversationTitle)
    .toolbarTitleDisplayMode(.inline)
    .toolbar(.hidden, for: .tabBar)
    .toolbar {
      ToolbarItem(placement: .principal) {
        HStack(spacing: 4) {
          Text(conversationTitle)
            .font(.headline)
            .lineLimit(1)
          Image(systemName: conversationIconName)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
      }
      ToolbarItem(placement: .primaryAction) {
        ConversationToolbarMenu(conversation: chatManager.conversations.first { $0.id == convoId })
      }
    }
    .onAppear {
      ensureUnifiedDataSource()
      consumePendingShareIfNeeded()
      consumePendingDraftIfNeeded()
      Task {
        await chatManager.markConversationAsRead(convoId: convoId)
      }
      chatManager.startMessagePolling(for: convoId)
      appState.chatHeartbeatManager.viewAppeared()
    }
    .onReceive(NotificationCenter.default.publisher(for: ChatDraftHandoff.didStoreDraft)) { _ in
      consumePendingDraftIfNeeded()
    }
    .onDisappear {
      chatManager.stopMessagePolling(for: convoId)
      appState.chatHeartbeatManager.viewDisappeared()
    }
    .alert("Delete Message", isPresented: $showingDeleteAlert) {
      Button("Cancel", role: .cancel) { }
      Button("Delete", role: .destructive) {
        if let messageId = messageToDelete {
          Task {
            await unifiedDataSource?.deleteMessage(messageID: messageId)
          }
        }
      }
    } message: {
      Text("This will delete the message for you. Others will still be able to see it.")
    }
    .sheet(isPresented: $showingReportSheet) {
      if let messageId = messageToReport,
         !convoId.isEmpty,
         let originalMessage = chatManager.originalMessagesMap[convoId]?[messageId] {
        ReportChatMessageView(
          message: originalMessage,
          onDismiss: { showingReportSheet = false }
        )
      }
    }
  }
  
  // MARK: - Chat Content
  

  @ViewBuilder
  private var chatContent: some View {
    if let dataSource = unifiedDataSource {
      ChatCollectionViewBridge(
        dataSource: dataSource,
        navigationPath: chatNavigationPath,
        onMessageLongPress: { message in
          presentMessageActions(for: message)
        },
        onRequestEmojiPicker: { messageID in
          emojiPickerMessageID = messageID
          showingEmojiPicker = true
        },
        onReply: { message in
          guard !message.isSystemMessage else { return }
          dataSource.draft.value.replyTarget = message
        }
      )
      .onChange(of: selectedEmoji) { _, newEmoji in
        guard let messageID = emojiPickerMessageID, !newEmoji.isEmpty else { return }
        dataSource.addReaction(messageID: messageID, emoji: newEmoji)
        showingEmojiPicker = false
        selectedEmoji = ""
        emojiPickerMessageID = nil
      }
      .onChange(of: showingEmojiPicker) { _, isPresented in
        if !isPresented {
          selectedEmoji = ""
          emojiPickerMessageID = nil
        }
      }
      .chatTranscriptViewport {
        if chatNavigationPath.wrappedValue.isEmpty {
          if conversationBlockState.isBlocked {
            BlockedConversationFooter(
              convoId: convoId,
              isGroup: currentConversation?.isGroupConversation ?? false,
              blockState: conversationBlockState,
              onUnblocked: {
                Task {
                  await chatManager.refreshConversation(convoId: convoId)
                }
              },
              onLeft: {
                if !chatNavigationPath.wrappedValue.isEmpty {
                  chatNavigationPath.wrappedValue.removeLast()
                }
                dismiss()
              }
            )
          } else if isConversationLocked {
            lockedConversationBanner
          } else if isOtherMemberDeleted {
            deletedAccountBanner
          } else {
            blueskyInputBar(dataSource: dataSource)
          }
        }
      }
      .customEmojiPicker(isPresented: $showingEmojiPicker) { emoji in
        selectedEmoji = emoji
      }
    } else {
      // Show loading while data source is being created
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
  
  // MARK: - Input Bar
  

  @ViewBuilder
  private func blueskyInputBar(dataSource: BlueskyConversationDataSource) -> some View {
    VStack(spacing: 0) {
      if let staged = dataSource.draft.value.replyTarget {
        HStack(alignment: .center, spacing: 8) {
          Image(systemName: "arrowshape.turn.up.left.fill")
            .font(.caption2)
            .foregroundStyle(Color.accentColor)

          VStack(alignment: .leading, spacing: 2) {
            Text("Replying to \(staged.senderDisplayName ?? "message")")
              .font(.caption2)
              .fontWeight(.semibold)
              .foregroundStyle(.primary)
              .lineLimit(1)

            Text(staged.text)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }

          Spacer(minLength: 0)

          Button {
            dataSource.draft.value.replyTarget = nil
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Cancel reply")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
      }

      ChatMessageComposerView(
        text: Binding(
          get: { dataSource.draftText },
          set: { dataSource.draftText = $0 }
        ),
        attachedPost: Binding(
          get: { dataSource.draft.value.attachedEmbed },
          set: {
            dataSource.draft.value.attachedEmbed = $0
            if $0 == nil { dataSource.draft.value.postRef = nil }
          }
        ),
        conversationId: convoId,
        onSend: { _, _ in
          guard let submission = dataSource.draft.beginSend() else { return }
          Task { await dataSource.sendDraft(submission) }
        },
        clearsDraftOnSend: false,
        dismissKeyboardOnSend: false
      )
    }
  }

    // MARK: - Deleted Account Banner

    private var deletedAccountBanner: some View {
      HStack(spacing: 8) {
        Image(systemName: "person.slash")
          .foregroundStyle(.secondary)
        Text("This account has been deleted")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 16)
      .background(Color(.systemBackground))
  }

    // MARK: - Locked Conversation Banner

    private var lockedConversationBanner: some View {
      HStack(spacing: 8) {
        Image(systemName: "lock.fill")
          .foregroundStyle(.secondary)
        Text("This group chat is locked")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 16)
      .background(Color(.systemBackground))
    }
  
  // MARK: - Message Actions
  
  private func presentMessageActions(for message: BlueskyMessageAdapter) {
    PlatformHaptics.soft()
    
    // Store for potential report/delete
    messageToReport = message.id
    messageToDelete = message.id
  }

    private var currentConversation: ChatBskyConvoDefs.ConvoView? {
      chatManager.conversations.first(where: { $0.id == convoId })
    }

    private var conversationBlockState: BlueskyConversationBlockState {
      currentConversation?.moderationBlockState(currentUserDID: appState.userDID) ?? .none
    }

    // Check if the other member's account has been deleted
    private var isOtherMemberDeleted: Bool {
      guard let convo = chatManager.conversations.first(where: { $0.id == convoId }) else {
        return false
      }
      guard !convo.isGroupConversation else { return false }
      let clientDid = appState.userDID
      if let otherMember = convo.members.first(where: { $0.did.didString() != clientDid }) {
        return otherMember.handle.description == "missing.invalid"
      }
      return false
    }

    private var isConversationLocked: Bool {
      chatManager.conversations.first(where: { $0.id == convoId })?.isLockedForSending ?? false
    }

    private var conversationIconName: String {
      guard let convo = chatManager.conversations.first(where: { $0.id == convoId }) else {
        return "bubble.left.and.bubble.right"
      }
      return convo.isGroupConversation ? "person.3.fill" : "bubble.left.and.bubble.right"
    }

  // Compute conversation title based on the other member
  private var conversationTitle: String {
    guard let convo = chatManager.conversations.first(where: { $0.id == convoId }) else {
      return "Chat"
    }

    return convo.displayTitle(currentUserDID: appState.userDID)
  }
}

#Preview("ConversationView") {
  NavigationStack {
    ConversationView(convoId: "preview-conversation-id")
  }
  .previewWithAuthenticatedState()
}

#endif
