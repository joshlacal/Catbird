import SwiftUI
import OSLog
import Petrel
//import MCEmojiPicker

#if os(iOS)

// MARK: - Conversation View (Using Unified Chat UI)

struct ConversationView: View {
  @Environment(AppState.self) private var appState
  @Environment(SceneNavigationContext.self) private var sceneContext
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.horizontalSizeClass) private var hSizeClass
  @Environment(\.dismiss) private var dismiss
  let convoId: String

  private var contentMaxWidth: CGFloat {
    hSizeClass == .compact ? .infinity : 600
  }
  @State private var unifiedDataSource: BlueskyConversationDataSource?
  @State private var isInitialized = false
  @State private var draftAccountDID: String?
  @State private var draftSceneID: UUID?
  @State private var shareAwaitingReplacement: PendingChatShare?
  @State private var showShareReplacement = false
  private var chatNavigationPath: Binding<NavigationPath> {
    sceneContext.navigationManager.pathBinding(for: AppNavigationManager.chatTabIndex)
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

  private var isCurrentScene: Bool {
    !sceneContext.isInvalidated && sceneContext.accountDID == appState.userDID
  }

  // MARK: - Data Source Management

  @MainActor
  private func ensureUnifiedDataSource() {
    guard isCurrentScene, unifiedDataSource == nil else { return }
    draftAccountDID = sceneContext.accountDID
    draftSceneID = sceneContext.sceneID
    unifiedDataSource = BlueskyConversationDataSource(
      chatManager: chatManager,
      convoID: convoId,
      currentUserDID: appState.userDID
    )
  }

  @MainActor
  private func consumePendingShareIfNeeded() {
    guard isCurrentScene,
          draftAccountDID == sceneContext.accountDID,
          draftSceneID == sceneContext.sceneID,
          let pending = PendingChatShareStore.shared.peek(
            sceneID: sceneContext.sceneID, accountDID: sceneContext.accountDID, convoId: convoId
          ),
          let draft = unifiedDataSource?.draft else { return }
    if let existing = draft.value.postRef, existing != pending.postRef {
      shareAwaitingReplacement = pending
      showShareReplacement = true
      return
    }
    applyPendingShare(pending)
  }

  @MainActor
  private func applyPendingShare(_ pending: PendingChatShare) {
    guard isCurrentScene,
          draftAccountDID == sceneContext.accountDID,
          draftSceneID == sceneContext.sceneID,
          let draft = unifiedDataSource?.draft,
          let owned = PendingChatShareStore.shared.consume(
            sceneID: sceneContext.sceneID, accountDID: sceneContext.accountDID,
            convoId: convoId, expectedID: pending.id
          ) else { return }
    owned.apply(to: &draft.value)
  }

  /// Applies a Siri/Shortcuts draft (Messages-schema intents) targeting this
  /// conversation, only when the composer is empty so typed text is never lost.
  @MainActor
  private func consumePendingDraftIfNeeded() {
    guard isCurrentScene,
          draftAccountDID == sceneContext.accountDID,
          draftSceneID == sceneContext.sceneID,
          let dataSource = unifiedDataSource,
          dataSource.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let pending = ChatDraftHandoff.shared.peek(
            sceneID: sceneContext.sceneID, accountDID: sceneContext.accountDID,
            conversationID: convoId
          ),
          let owned = ChatDraftHandoff.shared.consume(
            sceneID: sceneContext.sceneID, accountDID: sceneContext.accountDID,
            conversationID: convoId, expectedID: pending.id
          ) else { return }
    dataSource.draftText = owned.text
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
    // Applied outside the 600pt width cap so the Dim/Black theme fills the
    // whole detail column on iPad, not just the transcript strip.
    .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
    .navigationTitle(conversationTitle)
    .toolbarTitleDisplayMode(.inline)
    .toolbar(.hidden, for: .tabBar)
    .toolbar {
      ToolbarItem(placement: .principal) {
        HStack(spacing: 4) {
          Text(conversationTitle)
            .font(.headline)
            .lineLimit(1)
          if currentConversation?.isGroupConversation == true {
            Image(systemName: "person.3.fill")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
          }
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
    .onChange(of: PendingChatShareStore.shared.revision) { _, _ in
      consumePendingShareIfNeeded()
    }
    .onChange(of: sceneContext.isInvalidated) { _, isInvalidated in
      if isInvalidated {
        shareAwaitingReplacement = nil
        showShareReplacement = false
      }
    }
    .alert("Replace Shared Post?", isPresented: $showShareReplacement) {
      Button("Keep Current", role: .cancel) {
        if isCurrentScene, let pending = shareAwaitingReplacement {
          PendingChatShareStore.shared.consume(
            sceneID: sceneContext.sceneID, accountDID: sceneContext.accountDID,
            convoId: convoId, expectedID: pending.id
          )
        }
        shareAwaitingReplacement = nil
      }
      Button("Replace Post") {
        if let pending = shareAwaitingReplacement { applyPendingShare(pending) }
        shareAwaitingReplacement = nil
      }
    } message: {
      Text("Your message already has a post attached. Your text and reply will be kept.")
    }
    .onReceive(NotificationCenter.default.publisher(for: ChatDraftHandoff.didStoreDraft)) { _ in
      consumePendingDraftIfNeeded()
    }
    .onChange(of: unifiedDataSource?.draftText) { _, text in
      if text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
        consumePendingDraftIfNeeded()
      }
    }
    .onDisappear {
      chatManager.stopMessagePolling(for: convoId)
      appState.chatHeartbeatManager.viewDisappeared()
    }
    .alert("Delete for Me?", isPresented: $showingDeleteAlert) {
      Button("Cancel", role: .cancel) {
        messageToDelete = nil
      }
      Button("Delete", role: .destructive) {
        if let messageId = messageToDelete {
          Task {
            await unifiedDataSource?.deleteMessage(messageID: messageId)
          }
        }
        messageToDelete = nil
      }
    } message: {
      Text("The message will be removed for you. Others in the conversation will still see it.")
    }
    .sheet(isPresented: $showingReportSheet, onDismiss: { messageToReport = nil }) {
      if let messageId = messageToReport,
         !convoId.isEmpty,
         let originalMessage = chatManager.originalMessagesMap[convoId]?[messageId] {
        ReportChatMessageView(
          message: originalMessage,
          convoId: convoId,
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
        },
        onDeleteMessage: { message in
          messageToDelete = message.id
          showingDeleteAlert = true
        },
        onReportMessage: { message in
          messageToReport = message.id
          showingReportSheet = true
        }
      )
      .overlay {
        transcriptStateOverlay(dataSource: dataSource)
      }
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
  
  // MARK: - Transcript States

  @ViewBuilder
  private func transcriptStateOverlay(dataSource: BlueskyConversationDataSource) -> some View {
    if dataSource.messages.isEmpty {
      Group {
        if dataSource.isLoading || !dataSource.hasCompletedInitialLoad {
          ProgressView()
        } else {
          ContentUnavailableView(
            "No Messages Yet",
            systemImage: "bubble.left",
            description: Text("Send a message to start the conversation.")
          )
        }
      }
      .allowsHitTesting(false)
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
      .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
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
      .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
    }
  
  // MARK: - Message Actions
  
  private func presentMessageActions(for message: BlueskyMessageAdapter) {
    PlatformHaptics.soft()
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
