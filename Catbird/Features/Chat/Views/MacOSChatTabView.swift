#if os(macOS)
import OSLog
import Petrel
import SwiftUI

// MARK: - macOS Chat Tab View

/// Lightweight macOS chat tab that mirrors the iOS ChatTabView using
/// cross-platform Bluesky DM APIs. Uses NavigationSplitView with a
/// conversation sidebar and a detail pane.
@available(macOS 13.0, *)
struct MacOSChatTabView: View {
  @Environment(AppState.self) private var appState
  @Binding var selectedTab: Int
  @Binding var lastTappedTab: Int?

  @State private var conversations: [ChatBskyConvoDefs.ConvoView] = []
  @State private var selectedConvoId: String?
  @State private var isLoading = false
  @State private var cursor: String?
  @State private var navigationPath = NavigationPath()

  private let logger = Logger(subsystem: "blue.catbird", category: "MacOSChatTab")

  var body: some View {
    NavigationSplitView {
      sidebar
        .navigationTitle("Messages")
    } detail: {
      detail
    }
    .task {
      await loadConversations()
    }
    .onChange(of: lastTappedTab) { _, newValue in
      // Double-tap on Chat tab returns to conversation list
      if newValue == 4 {
        selectedConvoId = nil
      }
    }
  }

  // MARK: - Sidebar

  @ViewBuilder
  private var sidebar: some View {
    Group {
      if isLoading && conversations.isEmpty {
        ProgressView("Loading conversations...")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if conversations.isEmpty {
        VStack(spacing: 12) {
          Image(systemName: "bubble.left.and.bubble.right")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
          Text("No Messages")
            .font(.headline)
          Text("Start a conversation to see it here.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(conversations, id: \.id, selection: $selectedConvoId) { convo in
          MacOSConversationRow(convo: convo, currentUserDID: appState.userDID)
        }
        .listStyle(.sidebar)
      }
    }
  }

  // MARK: - Detail

  @ViewBuilder
  private var detail: some View {
    if selectedConvoId != nil {
      // Placeholder until BlueskyConversationDataSource is ported to macOS
      Text("Select a conversation")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      Text("Select a conversation")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  // MARK: - Data Loading

  private func loadConversations() async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }

    do {
      let (_, data) = try await appState.client.chat.bsky.convo
        .listConvos(input: .init(limit: 50))
      if let data {
        conversations = data.convos
        cursor = data.cursor
      }
    } catch {
      logger.error("Failed to load conversations: \(error.localizedDescription)")
    }
  }
}

// MARK: - Conversation Row

@available(macOS 13.0, *)
private struct MacOSConversationRow: View {
  let convo: ChatBskyConvoDefs.ConvoView
  let currentUserDID: String

  private var otherMembers: [ChatBskyActorDefs.ProfileViewBasic] {
    convo.members.filter { $0.did.description != currentUserDID }
  }

  private var displayName: String {
    if let first = otherMembers.first {
      return first.displayName ?? first.handle.description
    }
    return "Conversation"
  }

  private var lastMessageText: String {
    guard let lastMessage = convo.lastMessage else { return "" }
    switch lastMessage {
    case .chatBskyConvoDefsMessageView(let msg):
      return msg.text
    case .chatBskyConvoDefsDeletedMessageView:
      return "Message deleted"
    case .unexpected:
      return ""
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(displayName)
          .fontWeight(convo.unreadCount > 0 ? .semibold : .regular)
          .lineLimit(1)

        Spacer()

        if convo.unreadCount > 0 {
          Circle()
            .fill(.blue)
            .frame(width: 8, height: 8)
        }
      }

      if !lastMessageText.isEmpty {
        Text(lastMessageText)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.vertical, 4)
  }
}
#endif
