import SwiftUI
import OSLog
import Petrel
import CatbirdMLSService
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
        
          // Input bar at bottom with keyboard avoidance (hidden for deleted accounts)
          if isOtherMemberDeleted {
            deletedAccountBanner
          } else {
            blueskyInputBar(dataSource: dataSource)
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
            },
            isOtherMemberDeleted: isOtherMemberDeleted
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

#endif
