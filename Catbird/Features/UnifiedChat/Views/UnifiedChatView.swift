import SwiftUI
#if os(iOS)
//import MCEmojiPicker
#endif

/// Cross-platform unified chat view that uses UICollectionView on iOS and SwiftUI List on macOS
@available(iOS 16.0, macOS 13.0, *)
struct UnifiedChatView<DataSource: UnifiedChatDataSource>: View {
  @Environment(AppState.self) private var appState
  @Bindable var dataSource: DataSource
  @Binding var navigationPath: NavigationPath
  var title: String = "Chat"
  /// The conversation kind; an encrypted chat shows a lock beside its title.
  var kind: ChatConversationKind = .bluesky
  #if os(iOS)
  var composerConfig: InlineComposerConfig? = nil
  #endif
  var onMessageLongPress: ((DataSource.Message) -> Void)? = nil
  var onEditMessage: ((DataSource.Message) -> Void)? = nil
  var onReportMessage: ((DataSource.Message) -> Void)? = nil
  var onReply: ((DataSource.Message) -> Void)? = nil
  var onDeleteMessage: ((DataSource.Message) -> Void)? = nil

  @State private var showingEmojiPicker = false
  @State private var emojiPickerMessageID: String?
  @State private var unsendStatus: String?

  var body: some View {
    chatContent
      .navigationTitle(title)
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        if kind.showsLock {
          ToolbarItem(placement: .principal) {
            HStack(spacing: 4) {
              Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
              Text(title)
                .font(.headline)
                .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title), encrypted chat")
            .accessibilityIdentifier("chat.header.encrypted")
          }
        }
      }
      .overlay(alignment: .top) {
        if let unsendStatus {
          Label(unsendStatus, systemImage: unsendStatus.hasPrefix("Message unsent") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .accessibilityLabel(unsendStatus)
            .accessibilityIdentifier("mls-unsend-status")
        }
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
  }

  @ViewBuilder
  private var chatContent: some View {
    #if os(iOS)
    ChatCollectionViewBridge(
      dataSource: dataSource,
      navigationPath: $navigationPath,
      onMessageLongPress: onMessageLongPress,
      onRequestEmojiPicker: { messageID in
        emojiPickerMessageID = messageID
        showingEmojiPicker = true
      },
      onRetryMessage: { messageID in
        Task { await dataSource.retryFailedSend(pendingID: messageID) }
      },
      onEditMessage: onEditMessage,
      onUnsendMessage: { message in
        Task {
          let messageID = message.id
          await dataSource.deleteMessage(messageID: messageID)
          unsendStatus = dataSource.message(for: messageID) == nil
            ? "Message unsent for everyone."
            : "Message could not be unsent. Try again."
        }
      },
      onReply: onReply,
      composerConfig: composerConfig,
      onDeleteMessage: onDeleteMessage,
      onReportMessage: onReportMessage
    )
    #else
    ChatListView(
      dataSource: dataSource,
      navigationPath: $navigationPath,
      onRequestEmojiPicker: { messageID in
        emojiPickerMessageID = messageID
        showingEmojiPicker = true
      }
    )
    #endif
  }
}

// MARK: - Preview

#Preview {
  Text("Unified Chat Preview")
}
