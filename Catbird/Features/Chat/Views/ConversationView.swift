import SwiftUI
import OSLog
import Petrel
import CatbirdMLSCore
#if os(iOS)
//import MCEmojiPicker
#endif

// MARK: - Conversation View (Using Unified Chat UI)

#if os(iOS)
struct ConversationView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.horizontalSizeClass) private var hSizeClass
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

  var body: some View {
      Group {
        chatContent
          .task {
            // Initialize data source before loading
            ensureUnifiedDataSource()
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
          Image(systemName: "bubble.left.and.bubble.right")
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
      Task {
        await chatManager.markConversationAsRead(convoId: convoId)
      }
      chatManager.startMessagePolling(for: convoId)
      appState.chatHeartbeatManager.viewAppeared()
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
        }
      )
      .ignoresSafeArea(.container)
      .ignoresSafeArea(.keyboard)
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
      .safeAreaInset(edge: .bottom) {
        if chatNavigationPath.wrappedValue.isEmpty {
          if isOtherMemberDeleted {
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
      MLSMessageComposerView(
      text: Binding(
        get: { dataSource.draftText },
        set: { dataSource.draftText = $0 }
      ),
        attachedEmbed: .constant(nil),
        conversationId: convoId,
        onSend: { text, _ in
        Task { await dataSource.sendMessage(text: text) }
        },
        supportsEmbeds: false,
        showsAttachmentMenu: false,
        dismissKeyboardOnSend: false
      )
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
  
  // MARK: - Message Actions
  
  private func presentMessageActions(for message: BlueskyMessageAdapter) {
    let generator = UIImpactFeedbackGenerator(style: .soft)
    generator.impactOccurred()
    
    // Store for potential report/delete
    messageToReport = message.id
    messageToDelete = message.id
  }

    // Check if the other member's account has been deleted
    private var isOtherMemberDeleted: Bool {
      guard let convo = chatManager.conversations.first(where: { $0.id == convoId }) else {
        return false
      }
      let clientDid = appState.userDID
      if let otherMember = convo.members.first(where: { $0.did.didString() != clientDid }) {
        return otherMember.handle.description == "missing.invalid"
      }
      return false
    }

  // Compute conversation title based on the other member
  private var conversationTitle: String {
    guard let convo = chatManager.conversations.first(where: { $0.id == convoId }) else {
      return "Chat"
    }

    let clientDid = appState.userDID

    if let otherMember = convo.members.first(where: { $0.did.didString() != clientDid }) {
        // Show "Deleted Account" for deleted users
        if otherMember.handle.description == "missing.invalid" {
          return "Deleted Account"
        }
      return otherMember.displayName ?? "@\(otherMember.handle.description)"
    }

    return convo.members.first?.displayName ?? "Chat"
  }
}

#Preview("ConversationView") {
  NavigationStack {
    ConversationView(convoId: "preview-conversation-id")
  }
  .previewWithAuthenticatedState()
}

#endif
