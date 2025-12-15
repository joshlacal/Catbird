import SwiftUI
import OSLog
import Petrel
#if os(iOS)
//import MCEmojiPicker
#endif

// MARK: - Conversation View (Using Unified Chat UI)

#if os(iOS)
struct ConversationView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme
  let convoId: String
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
      if #available(iOS 16.0, *) {
        chatContent
          .task {
            // Initialize data source before loading
            ensureUnifiedDataSource()
            if let dataSource = unifiedDataSource {
              await dataSource.loadMessages()
            }
            isInitialized = true
          }
      } else {
        // Fallback for iOS 15
        Text("Chat requires iOS 16 or later")
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: 600)
    .navigationTitle(conversationTitle)
    .toolbarTitleDisplayMode(.inline)
    .toolbar(.hidden, for: .tabBar)
    .toolbar {
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
    }
    .onDisappear {
      chatManager.stopMessagePolling(for: convoId)
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
  
  @available(iOS 16.0, *)
  @ViewBuilder
  private var chatContent: some View {
    if let dataSource = unifiedDataSource {
      VStack(spacing: 0) {
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
        .ignoresSafeArea()
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
        
        // Input bar at bottom with keyboard avoidance
        blueskyInputBar(dataSource: dataSource)
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
  
  @available(iOS 16.0, *)
  @ViewBuilder
  private func blueskyInputBar(dataSource: BlueskyConversationDataSource) -> some View {
    UnifiedInputBar(
      text: Binding(
        get: { dataSource.draftText },
        set: { dataSource.draftText = $0 }
      ),
      onSend: { text in
        Task { await dataSource.sendMessage(text: text) }
      }
    )
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
  
  // MARK: - Message Actions
  
  private func presentMessageActions(for message: BlueskyMessageAdapter) {
    let generator = UIImpactFeedbackGenerator(style: .soft)
    generator.impactOccurred()
    
    // Store for potential report/delete
    messageToReport = message.id
    messageToDelete = message.id
  }

  // Compute conversation title based on the other member
  private var conversationTitle: String {
    guard let convo = chatManager.conversations.first(where: { $0.id == convoId }) else {
      return "Chat"
    }

    let clientDid = appState.userDID

    if let otherMember = convo.members.first(where: { $0.did.didString() != clientDid }) {
      return otherMember.displayName ?? "@\(otherMember.handle.description)"
    }

    return convo.members.first?.displayName ?? "Chat"
  }
}

#else

// macOS version using unified chat
struct ConversationView: View {
  @Environment(AppState.self) private var appState
  let convoId: String
  @State private var unifiedDataSource: BlueskyConversationDataSource?

  @State private var showingEmojiPicker = false
  @State private var emojiPickerMessageID: String?

  private var chatNavigationPath: Binding<NavigationPath> {
    appState.navigationManager.pathBinding(for: 4)
  }

  private var chatManager: ChatManager {
    appState.chatManager
  }

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
      if let dataSource = unifiedDataSource {
        // ChatListView already includes the input bar
        ChatListView(
          dataSource: dataSource,
          navigationPath: chatNavigationPath,
          onRequestEmojiPicker: { messageID in
            emojiPickerMessageID = messageID
            showingEmojiPicker = true
          }
        )
        .task {
          await dataSource.loadMessages()
        }
        .customEmojiPicker(isPresented: $showingEmojiPicker) { emoji in
          guard let messageID = emojiPickerMessageID else { return }
          dataSource.addReaction(messageID: messageID, emoji: emoji)
          emojiPickerMessageID = nil
        }
        .onChange(of: showingEmojiPicker) { _, isPresented in
          if !isPresented {
            emojiPickerMessageID = nil
          }
        }
      } else {
        ProgressView()
      }
    }
    .navigationTitle(conversationTitle)
    .onAppear {
      ensureUnifiedDataSource()
      chatManager.startMessagePolling(for: convoId)
    }
    .onDisappear {
      chatManager.stopMessagePolling(for: convoId)
    }
  }

  private var conversationTitle: String {
    guard let convo = chatManager.conversations.first(where: { $0.id == convoId }) else {
      return "Chat"
    }
    let clientDid = appState.userDID
    if let otherMember = convo.members.first(where: { $0.did.didString() != clientDid }) {
      return otherMember.displayName ?? "@\(otherMember.handle.description)"
    }
    return convo.members.first?.displayName ?? "Chat"
  }
}

#endif
