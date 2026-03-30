#if os(macOS)
import NukeUI
import os
import SwiftUI

/// Native macOS SwiftUI chat message list — equivalent of the iOS ChatCollectionViewController.
/// Uses ScrollView + LazyVStack with date separators, typing indicator, history boundaries,
/// scroll-to-bottom on new messages, and load-more-on-scroll-to-top pagination.
@available(macOS 13.0, *)
struct ChatListView<DataSource: UnifiedChatDataSource>: View {
  @Environment(AppState.self) private var appState
  @Bindable var dataSource: DataSource
  @Binding var navigationPath: NavigationPath
  var onRequestEmojiPicker: ((String) -> Void)? = nil
  var isOtherMemberDeleted: Bool = false

  private let chatLogger = Logger(subsystem: "blue.catbird", category: "ChatListView")

  // MARK: - Item Model

  /// Mirrors the iOS Item enum so we can intersperse date separators and boundaries
  /// between messages in a single flat list.
  private enum Item: Identifiable, Equatable {
    case message(id: String)
    case dateSeparator(Date)
    case typingIndicator(avatarURL: URL?)
    case historyBoundary(id: String, text: String)

    var id: String {
      switch self {
      case .message(let id): return "msg-\(id)"
      case .dateSeparator(let date): return "date-\(date.timeIntervalSince1970)"
      case .typingIndicator: return "typing"
      case .historyBoundary(let id, _): return "hb-\(id)"
      }
    }

    static func == (lhs: Item, rhs: Item) -> Bool {
      lhs.id == rhs.id
    }
  }

  // MARK: - State

  @State private var scrollProxy: ScrollViewProxy?
  @State private var reactionOverlay: (messageID: String, bubbleGlobalFrame: CGRect, isFromCurrentUser: Bool)?
  @State private var reactionBarSize: CGSize = .zero
  @State private var hasPerformedInitialScroll = false
  @State private var lastScrollToBottomTrigger: Int = 0
  @State private var isLoadingOlderMessages = false

  // MARK: - Body

  var body: some View {
    ZStack {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 4) {
            // Older-messages loading indicator
            if dataSource.hasMoreMessages {
              ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .onAppear {
                  loadOlderMessagesIfNeeded()
                }
            }

            ForEach(items) { item in
              itemView(for: item)
            }
          }
          .padding(.top, 8)
          .padding(.bottom, 8)
        }
        .onAppear {
          scrollProxy = proxy
          // Defer initial scroll so layout has settled.
          DispatchQueue.main.async {
            scrollToBottom(animated: false)
            hasPerformedInitialScroll = true
          }
        }
        .onChange(of: dataSource.messages.count) { _, _ in
          // Auto-scroll when new messages arrive.
          if hasPerformedInitialScroll {
            scrollToBottom(animated: true)
          }
        }
        .onChange(of: dataSource.scrollToBottomTrigger) { _, newValue in
          if newValue != lastScrollToBottomTrigger {
            lastScrollToBottomTrigger = newValue
            scrollToBottom(animated: true)
          }
        }
      }

      // Reaction overlay
      if let overlay = reactionOverlay {
        reactionOverlayView(overlay: overlay)
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

  // MARK: - Items

  /// Build the flat list of display items from the data source, inserting date separators
  /// and handling history boundary markers, exactly like the iOS snapshot builder.
  private var items: [Item] {
    var result: [Item] = []
    var seenDays = Set<Date>()
    var seenMessageIDs = Set<String>()
    let calendar = Calendar.current

    for message in dataSource.messages {
      guard seenMessageIDs.insert(message.id).inserted else { continue }

      let messageDay = calendar.startOfDay(for: message.sentAt)
      if seenDays.insert(messageDay).inserted {
        result.append(.dateSeparator(messageDay))
      }

      if message.id.hasPrefix("hb-") {
        result.append(.historyBoundary(id: message.id, text: message.text))
      } else {
        result.append(.message(id: message.id))
      }
    }

    if dataSource.showsTypingIndicator {
      result.append(.typingIndicator(avatarURL: dataSource.typingParticipantAvatarURL))
    }

    return result
  }

  // MARK: - Item Views

  @ViewBuilder
  private func itemView(for item: Item) -> some View {
    switch item {
    case .message(let id):
      if let message = dataSource.message(for: id) {
        UnifiedMessageBubble(
          message: message,
          navigationPath: $navigationPath,
          onReactionTapped: { emoji in
            dataSource.toggleReaction(messageID: id, emoji: emoji)
          },
          onAddReaction: { emoji in
            dataSource.addReaction(messageID: id, emoji: emoji)
          },
          onRequestEmojiPicker: { messageID in
            onRequestEmojiPicker?(messageID)
          },
          onLongPress: { bubbleGlobalFrame in
            reactionOverlay = (id, bubbleGlobalFrame, message.isFromCurrentUser)
          },
          onReactionLongPress: nil,
          groupPosition: UnifiedMessageGrouping.groupPosition(
            for: id,
            in: dataSource.messages
          )
        )
        .id(id)
        .padding(.horizontal, 12)
      }

    case .dateSeparator(let date):
      Text(date, format: .dateTime.month().day().year())
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)

    case .typingIndicator(let avatarURL):
      MacTypingIndicatorView(avatarURL: avatarURL)
        .id("typing-indicator")

    case .historyBoundary(_, let text):
      HistoryBoundaryView(text: text)
    }
  }

  // MARK: - Reaction Overlay

  @ViewBuilder
  private func reactionOverlayView(
    overlay: (messageID: String, bubbleGlobalFrame: CGRect, isFromCurrentUser: Bool)
  ) -> some View {
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
          (overlay.isFromCurrentUser
            ? (overlay.bubbleGlobalFrame.maxX - reactionBarSize.width)
            : overlay.bubbleGlobalFrame.minX)
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

  // MARK: - Actions

  private func scrollToBottom(animated: Bool) {
    guard let lastItem = items.last else { return }
    if animated {
      withAnimation(.easeOut(duration: 0.3)) {
        scrollProxy?.scrollTo(lastItem.id, anchor: .bottom)
      }
    } else {
      scrollProxy?.scrollTo(lastItem.id, anchor: .bottom)
    }
  }

  private func loadOlderMessagesIfNeeded() {
    guard
      dataSource.hasMoreMessages,
      !dataSource.isLoading,
      !isLoadingOlderMessages
    else { return }

    isLoadingOlderMessages = true
    Task {
      await dataSource.loadMoreMessages()
      await MainActor.run { isLoadingOlderMessages = false }
    }
  }
}

// MARK: - Typing Indicator (macOS)

@available(macOS 13.0, *)
private struct MacTypingIndicatorView: View {
  let avatarURL: URL?
  @State private var animate = false

  var body: some View {
    HStack(spacing: 8) {
      if let avatarURL {
        LazyImage(url: avatarURL) { state in
          if let image = state.image {
            image
              .resizable()
              .scaledToFill()
          } else {
            Circle()
              .fill(Color.gray.opacity(0.3))
          }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
      } else {
        Circle()
          .fill(Color.gray.opacity(0.3))
          .frame(width: 28, height: 28)
      }

      HStack(spacing: 6) {
        ForEach(0..<3, id: \.self) { index in
          Circle()
            .fill(Color.secondary)
            .frame(width: 8, height: 8)
            .scaleEffect(animate ? 1.0 : 0.6)
            .opacity(animate ? 1 : 0.4)
            .animation(
              .easeInOut(duration: 0.6)
                .repeatForever()
                .delay(Double(index) * 0.15),
              value: animate
            )
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, 12)
    .onAppear { animate = true }
  }
}

#Preview {
  Text("macOS Chat Preview")
}
#endif
