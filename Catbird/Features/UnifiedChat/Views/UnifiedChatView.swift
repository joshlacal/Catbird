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
  var title: String = String(localized: "Chat", comment: "Default navigation title for a chat conversation")
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

  private enum UnsendStatus {
    case unsent
    case failed

    var message: LocalizedStringResource {
      switch self {
      case .unsent:
        return LocalizedStringResource("Message unsent for everyone.", comment: "Status banner when an encrypted message is successfully unsent")
      case .failed:
        return LocalizedStringResource("Message could not be unsent. Try again.", comment: "Status banner when unsending an encrypted message fails")
      }
    }

    var systemImage: String {
      switch self {
      case .unsent: return "checkmark.circle.fill"
      case .failed: return "exclamationmark.triangle.fill"
      }
    }
  }

  @State private var showingEmojiPicker = false
  @State private var emojiPickerMessageID: String?
  @State private var unsendStatus: UnsendStatus?

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
            .accessibilityLabel(
              Text(
                "\(title), encrypted chat",
                comment: "Accessibility label for encrypted chat header. %@ is the conversation title."
              )
            )
            .accessibilityIdentifier("chat.header.encrypted")
          }
        }
      }
      .overlay(alignment: .top) {
        if let unsendStatus {
          Label {
            Text(unsendStatus.message)
          } icon: {
            Image(systemName: unsendStatus.systemImage)
          }
          .font(.footnote)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(.regularMaterial, in: Capsule())
          .accessibilityLabel(Text(unsendStatus.message))
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
          unsendStatus = dataSource.message(for: messageID) == nil ? .unsent : .failed
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
  Text(verbatim: "Unified Chat Preview")
}
