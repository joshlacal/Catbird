import SwiftUI
import OSLog
import Petrel

// MARK: - Conversation List View

struct ConversationListView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State var chatManager: ChatManager
  var searchText: String = ""
  var onSelectConvo: (String) -> Void
  var onSelectSearchResult: ((ProfileDisplayable) -> Void)?

  private let logger = Logger(subsystem: "blue.catbird", category: "ConversationListView")

  var body: some View {
    List {
      if !searchText.isEmpty {
        searchResultsContent
      } else {
        conversationListContent
      }
    }
    .listStyle(.plain)
    .refreshable {
      logger.debug("Pull-to-refresh triggered on conversation list.")
      await chatManager.loadConversations(refresh: true)
    }
    .overlay {
      loadingOverlay
    }
  }
  
  // MARK: - View Components
  
  @ViewBuilder
  private var searchResultsContent: some View {
    if !chatManager.filteredProfiles.isEmpty {
      contactsSection
    }
    
    if !chatManager.filteredConversations.isEmpty {
      filteredConversationsSection
    }
    
    if chatManager.filteredProfiles.isEmpty && chatManager.filteredConversations.isEmpty && !searchText.isEmpty {
      noResultsMessage
    }
  }
  
  @ViewBuilder
  private var conversationListContent: some View {
    ForEach(chatManager.acceptedConversations) { convo in
      conversationRowView(for: convo, showMuteOption: true)
    }
    
    paginationContent
    emptyStateContent
  }
  
  @ViewBuilder
  private var contactsSection: some View {
    Section("Contacts") {
      ForEach(chatManager.filteredProfiles, id: \.did) { profileBasic in
        contactRowButton(for: profileBasic)
      }
    }
  }
  
  @ViewBuilder
  private var filteredConversationsSection: some View {
    Section("Conversations") {
      ForEach(chatManager.filteredConversations) { convo in
        conversationRowView(for: convo, showMuteOption: false)
      }
    }
  }
  
  @ViewBuilder
  private var noResultsMessage: some View {
    Text("No matching contacts or conversations")
      .foregroundColor(.secondary)
      .frame(maxWidth: .infinity, alignment: .center)
      .listRowSeparator(.hidden)
      .padding()
  }
  
  @ViewBuilder
  private var paginationContent: some View {
    let shouldShowLoadMore = !chatManager.acceptedConversations.isEmpty && 
                            chatManager.conversationsCursor != nil && 
                            !chatManager.loadingConversations
    
    let shouldShowProgress = chatManager.loadingConversations && 
                            !chatManager.acceptedConversations.isEmpty
    
    if shouldShowLoadMore {
      ProgressView("Loading more...")
        .frame(maxWidth: .infinity)
        .padding()
        .onAppear {
          Task {
            logger.debug("Reached end of conversation list, loading more.")
            await chatManager.loadConversations(refresh: false)
          }
        }
    } else if shouldShowProgress {
      ProgressView()
        .frame(maxWidth: .infinity)
        .padding()
    }
  }
  
  @ViewBuilder
  private var emptyStateContent: some View {
    if chatManager.acceptedConversations.isEmpty && !chatManager.loadingConversations {
      ContentUnavailableView {
        Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
      } description: {
        emptyStateDescription
      }
      .padding()
    }
  }
  
  @ViewBuilder
  private var emptyStateDescription: some View {
    VStack(spacing: DesignTokens.Spacing.sm) {
      Text("You haven't started any chats yet.")
        .enhancedAppBody()
      if appState.chatManager.messageRequestsCount > 0 {
        Text("Check your message requests above to see if anyone wants to chat with you.")
          .enhancedAppCaption()
          .foregroundColor(.secondary)
      }
    }
  }
  
  @ViewBuilder
  private var loadingOverlay: some View {
    if chatManager.loadingConversations && chatManager.acceptedConversations.isEmpty && searchText.isEmpty {
      ProgressView("Loading Chats...")
    }
  }
  
  // MARK: - Helper Methods
  
  private func contactRowButton(for profileBasic: ChatBskyActorDefs.ProfileViewBasic) -> some View {
    Button {
      onSelectSearchResult?(profileBasic)
    } label: {
      HStack {
        ChatProfileAvatarView(profile: profileBasic, size: 40)
        VStack(alignment: .leading) {
          Text(profileBasic.displayName ?? "")
            .appHeadline()
            .foregroundColor(.primary)
          Text("@\(profileBasic.handle.description)")
            .appSubheadline()
            .foregroundColor(.secondary)
        }
      }
    }
    .buttonStyle(.plain)
    .spacingSM(.vertical)
  }
  
  private func conversationRowView(for convo: ChatBskyConvoDefs.ConvoView, showMuteOption: Bool) -> some View {
    ConversationRow(
      convo: convo,
      did: appState.currentUserDID ?? ""
    )
    .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
    .contentShape(Rectangle())
    .onTapGesture {
      onSelectConvo(convo.id)
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      swipeActionsContent(for: convo, showMuteOption: showMuteOption)
    }
    .contextMenu {
      ConversationContextMenu(conversation: convo)
    }
    .listRowBackground(
      // Add selection highlight for iPad split view
      horizontalSizeClass == .regular && chatManager.conversations.first(where: { $0.id == convo.id }) != nil
        ? Color.accentColor.opacity(0.1)
        : Color.clear
    )
  }
  
  @ViewBuilder
  private func swipeActionsContent(for convo: ChatBskyConvoDefs.ConvoView, showMuteOption: Bool) -> some View {
    Button(role: .destructive) {
      Task { await chatManager.leaveConversation(convoId: convo.id) }
    } label: {
      Label("Delete", systemImage: "trash")
    }
    
    if showMuteOption {
      Button {
        if convo.muted {
          Task { await chatManager.unmuteConversation(convoId: convo.id) }
        } else {
          Task { await chatManager.muteConversation(convoId: convo.id) }
        }
      } label: {
        Label(convo.muted ? "Unmute" : "Mute", systemImage: convo.muted ? "bell" : "bell.slash")
      }
      .tint(convo.muted ? .blue : .orange)
    } else {
      Button {
        Task { await chatManager.muteConversation(convoId: convo.id) }
      } label: {
        Label("Mute", systemImage: "bell.slash")
      }
    }
  }
}