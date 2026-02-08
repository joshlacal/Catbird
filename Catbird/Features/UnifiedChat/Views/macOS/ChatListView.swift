#if os(macOS)
import SwiftUI

/// macOS SwiftUI fallback for the chat view
@available(macOS 13.0, *)
struct ChatListView<DataSource: UnifiedChatDataSource>: View {
  @Environment(AppState.self) private var appState
  @Bindable var dataSource: DataSource
  @Binding var navigationPath: NavigationPath
  var onRequestEmojiPicker: ((String) -> Void)? = nil
  var isOtherMemberDeleted: Bool = false

  @State private var scrollProxy: ScrollViewProxy?
  @State private var reactionOverlay: (messageID: String, bubbleGlobalFrame: CGRect, isFromCurrentUser: Bool)?
  @State private var reactionBarSize: CGSize = .zero

  var body: some View {
    ZStack {
      ScrollViewReader { proxy in
        List {
          ForEach(Array(dataSource.messages.enumerated()), id: \.element.id) { index, message in
            UnifiedMessageBubble(
              message: message,
              navigationPath: $navigationPath,
              onReactionTapped: { emoji in
                dataSource.toggleReaction(messageID: message.id, emoji: emoji)
              },
              onAddReaction: { emoji in
                dataSource.addReaction(messageID: message.id, emoji: emoji)
              },
              onRequestEmojiPicker: { messageID in
                onRequestEmojiPicker?(messageID)
              },
              onLongPress: { bubbleGlobalFrame in
                reactionOverlay = (message.id, bubbleGlobalFrame, message.isFromCurrentUser)
              },
              groupPosition: UnifiedMessageGrouping.groupPosition(for: index, in: dataSource.messages)
            )
            .id(message.id)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
            .listRowBackground(Color.clear)
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .onAppear {
          scrollProxy = proxy
          scrollToBottom(animated: false)
        }
        .onChange(of: dataSource.messages.count) { _, _ in
          scrollToBottom(animated: true)
        }
      }

      if let overlay = reactionOverlay {
        GeometryReader { geo in
          let container = geo.frame(in: .global)

          Color.clear
            .contentShape(Rectangle())
            .onTapGesture { reactionOverlay = nil }

          UnifiedQuickReactionBar(
            quickReactions: UnifiedQuickReactionBar.defaultQuickReactions,
            onReactionSelected: { emoji in
              dataSource.addReaction(messageID: overlay.messageID, emoji: emoji)
              reactionOverlay = nil
            },
            onMoreTapped: {
              reactionOverlay = nil
              onRequestEmojiPicker?(overlay.messageID)
            }
          )
          .background(
            GeometryReader { barProxy in
              Color.clear
                .onAppear { reactionBarSize = barProxy.size }
                .onChange(of: barProxy.size) { _, newValue in reactionBarSize = newValue }
            }
          )
          .position(
            x: (
              (overlay.isFromCurrentUser ? (overlay.bubbleGlobalFrame.maxX - reactionBarSize.width) : overlay.bubbleGlobalFrame.minX)
              - container.minX
              + (reactionBarSize.width / 2)
            ),
            y: (
              (overlay.bubbleGlobalFrame.minY - reactionBarSize.height - 8)
              - container.minY
              + (reactionBarSize.height / 2)
            )
          )
        }
        .ignoresSafeArea()
      }
    }
    .safeAreaInset(edge: .bottom) {
      if isOtherMemberDeleted {
        HStack(spacing: 8) {
          Image(systemName: "person.slash")
            .foregroundStyle(.secondary)
          Text("This account has been deleted")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(nsColor: .windowBackgroundColor))
      } else {
        UnifiedInputBar(
          text: Binding(
            get: { dataSource.draftText },
            set: { dataSource.draftText = $0 }
          ),
          onSend: { text in
            Task {
              await dataSource.sendMessage(text: text)
            }
          }
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
      }
    }
    .task {
      await dataSource.loadMessages()
    }
  }

  // MARK: - Actions

  private func scrollToBottom(animated: Bool) {
    guard let lastMessage = dataSource.messages.last else { return }
    if animated {
      withAnimation(.easeOut(duration: 0.3)) {
        scrollProxy?.scrollTo(lastMessage.id, anchor: .bottom)
      }
    } else {
      scrollProxy?.scrollTo(lastMessage.id, anchor: .bottom)
    }
  }
}

#Preview {
  Text("macOS Chat Preview")
}
#endif
