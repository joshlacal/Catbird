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

  @State private var showingEmojiPicker = false
  @State private var emojiPickerMessageID: String?

  var body: some View {
    chatContent
      .navigationTitle(title)
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
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
      onRequestEmojiPicker: { messageID in
        emojiPickerMessageID = messageID
        showingEmojiPicker = true
      }
    )
    .ignoresSafeArea()
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
