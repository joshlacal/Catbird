#if os(macOS)
import CatbirdMLSCore
import OSLog
import Petrel
import SwiftUI

// MARK: - macOS Bluesky Conversation Detail

/// Displays a single Bluesky DM conversation on macOS using the shared ChatListView
/// for message rendering and UnifiedInputBar for composition.
@available(macOS 13.0, *)
struct MacOSBlueskyConversationView: View {
  @Environment(AppState.self) private var appState
  let convoId: String

  @State private var dataSource: BlueskyConversationDataSource?
  @State private var navigationPath = NavigationPath()
  @State private var showingEmojiPicker = false
  @State private var emojiPickerMessageID: String?
  @State private var showingDeleteAlert = false
  @State private var messageToDelete: String?

  private var chatManager: ChatManager {
    appState.chatManager
  }

  private let logger = Logger(subsystem: "blue.catbird", category: "MacOSBlueskyConvo")

  var body: some View {
    Group {
      if let dataSource {
        ChatListView(
          dataSource: dataSource,
          navigationPath: $navigationPath,
          onRequestEmojiPicker: { messageID in
            emojiPickerMessageID = messageID
            showingEmojiPicker = true
          }
        )
      } else {
        ProgressView("Loading...")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .navigationTitle(conversationTitle)
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
    }
    .task {
      ensureDataSource()
      if let dataSource {
        await dataSource.loadMessages()
      }
    }
    .onAppear {
      ensureDataSource()
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
    .customEmojiPicker(isPresented: $showingEmojiPicker) { emoji in
      guard let messageID = emojiPickerMessageID else { return }
      dataSource?.addReaction(messageID: messageID, emoji: emoji)
      emojiPickerMessageID = nil
    }
    .alert("Delete Message", isPresented: $showingDeleteAlert) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        if let messageId = messageToDelete {
          Task { await dataSource?.deleteMessage(messageID: messageId) }
        }
      }
    } message: {
      Text("This will delete the message for you. Others will still be able to see it.")
    }
  }

  // MARK: - Data Source

  @MainActor
  private func ensureDataSource() {
    guard dataSource == nil else { return }
    dataSource = BlueskyConversationDataSource(
      chatManager: chatManager,
      convoID: convoId,
      currentUserDID: appState.userDID
    )
  }

  // MARK: - Conversation Info

  private var conversationTitle: String {
    guard let convo = chatManager.conversations.first(where: { $0.id == convoId }) else {
      return "Messages"
    }
    let otherMembers = convo.members.filter { $0.did.description != appState.userDID }
    if let first = otherMembers.first {
      return first.displayName ?? first.handle.description
    }
    return "Messages"
  }
}
#endif
