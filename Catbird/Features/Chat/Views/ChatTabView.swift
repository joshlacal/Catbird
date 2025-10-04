import SwiftUI
import OSLog
import Petrel

#if os(iOS)

// MARK: - Chat Tab View

struct ChatTabView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.composerTransitionNamespace) private var composerNamespace
  @Binding var selectedTab: Int
  @Binding var lastTappedTab: Int?
  @State private var selectedConvoId: String?
  @State private var searchText = ""
  @State private var isShowingErrorAlert = false
  @State private var lastErrorMessage: String?
  @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
  @State private var showingNewMessageSheet = false
  fileprivate let logger = Logger(subsystem: "blue.catbird", category: "ChatUI")

  private var chatNavigationPath: Binding<NavigationPath> {
    appState.navigationManager.pathBinding(for: 4)
  }
  
  private var shouldUseSplitView: Bool {
    DeviceInfo.isIPad || horizontalSizeClass == .regular
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      chatSidebarContent
    } detail: {
      chatDetailContent
    }
    .navigationSplitViewStyle(.automatic)
    .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
    .onAppear(perform: handleOnAppear)
    .onDisappear(perform: handleOnDisappear)
    .onChange(of: selectedConvoId) { oldValue, newValue in
      handleConversationChange(oldValue: oldValue, newValue: newValue)
      
      // On iPhone, manage column visibility based on selection
      if !shouldUseSplitView {
        if newValue != nil {
          columnVisibility = .detailOnly
        } else {
            columnVisibility = .doubleColumn
        }
      }
    }
    .onChange(of: appState.chatManager.errorState) { oldError, newError in
      handleErrorStateChange(oldError: oldError, newError: newError)
    }
    .alert(isPresented: $isShowingErrorAlert, content: createErrorAlert)
    .sheet(isPresented: $showingNewMessageSheet) {
      NewMessageView()
        .composerZoomTransition(namespace: composerNamespace)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.thinMaterial)
    }
    .overlay(alignment: .bottomTrailing) {
      if shouldShowChatFAB {
        ChatFAB(newMessageAction: {
          showingNewMessageSheet = true
        })
        .padding(.bottom, 20)
        .padding(.trailing, 20)
      }
    }
  }
  
  // MARK: - Sidebar Content
  
  @ViewBuilder
  private var chatSidebarContent: some View {
    ZStack(alignment: .bottom) {
      conversationList
      // FAB moved to a global overlay; nothing else needed here
    }
  }
  
  @ViewBuilder
  private var conversationList: some View {
    List(selection: $selectedConvoId) {
      if !searchText.isEmpty {
        searchResultsContent
      } else {
        mainConversationListContent
      }
    }
    .listStyle(.plain)
    .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
    .navigationTitle("Messages")
    .themedNavigationBar(appState.themeManager)
    .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 400)
    .searchable(text: $searchText, prompt: "Search")
    .onChange(of: searchText) { _, newValue in
      appState.chatManager.searchLocal(searchTerm: newValue, currentUserDID: appState.currentUserDID)
    }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        MessageRequestsButton()
      }
      ToolbarItem(placement: .primaryAction) {
        ChatToolbarMenu()
      }
    }
    .refreshable {
      await appState.chatManager.loadConversations(refresh: true)
    }
    .overlay {
      conversationListOverlay
    }
  }
  
  @ViewBuilder
  private var searchResultsContent: some View {
    if !appState.chatManager.filteredProfiles.isEmpty {
      Section("Contacts") {
        ForEach(appState.chatManager.filteredProfiles, id: \.did) { profileBasic in
          contactRow(for: profileBasic)
        }
      }
    }
    
    if !appState.chatManager.filteredConversations.isEmpty {
      Section("Conversations") {
        ForEach(appState.chatManager.filteredConversations) { convo in
          conversationRow(for: convo, withSwipeActions: true)
        }
      }
    }
  }
  
  @ViewBuilder
  private var mainConversationListContent: some View {
    ForEach(appState.chatManager.acceptedConversations) { convo in
      conversationRow(for: convo, withSwipeActions: true)
    }
    
    if shouldShowPagination {
      paginationView
    }
  }
  
  @ViewBuilder
  private var conversationListOverlay: some View {
    if appState.chatManager.loadingConversations && appState.chatManager.acceptedConversations.isEmpty {
      ProgressView("Loading Chats...")
    } else if appState.chatManager.acceptedConversations.isEmpty && !appState.chatManager.loadingConversations {
      emptyConversationsView
    }
  }
  
  @ViewBuilder
  private var emptyConversationsView: some View {
    ContentUnavailableView {
      Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
    } description: {
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
  }
  
  @ViewBuilder
  private var paginationView: some View {
    ProgressView("Loading more...")
      .frame(maxWidth: .infinity)
      .padding()
      .onAppear {
        Task {
          await appState.chatManager.loadConversations(refresh: false)
        }
      }
  }
  
  // MARK: - Detail Content
  
  @ViewBuilder
  private var chatDetailContent: some View {
    NavigationStack(path: chatNavigationPath) {
      if let convoId = selectedConvoId {
        ConversationView(convoId: convoId)
          .id(convoId)
      } else {
        EmptyConversationView()
      }
    }
    .navigationDestination(for: NavigationDestination.self) { destination in
      NavigationHandler.viewForDestination(
        destination,
        path: chatNavigationPath,
        appState: appState,
        selectedTab: $selectedTab
      )
    }
  }
  
  // MARK: - Row Components
  
  @ViewBuilder
  private func contactRow(for profileBasic: ChatBskyActorDefs.ProfileViewBasic) -> some View {
    Button {
      startConversation(with: profileBasic)
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
      .spacingSM(.vertical)
    }
    .buttonStyle(.plain)
    .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
    .listRowInsets(EdgeInsets())
  }
  
  @ViewBuilder
  private func conversationRow(for convo: ChatBskyConvoDefs.ConvoView, withSwipeActions: Bool) -> some View {
    ConversationRow(
      convo: convo,
      did: appState.currentUserDID ?? ""
    )
    .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
    .modifier(ConditionalSwipeActions(conversation: convo, enabled: withSwipeActions))
    .contextMenu {
      ConversationContextMenu(conversation: convo)
    }
    .tag(convo.id)
  }
  
  // MARK: - Helper Properties
  
  private var shouldShowChatFAB: Bool {
    // Only show when we're on the chat tab (selectedTab == 4)
    guard selectedTab == 4 else { return false }

    if DeviceInfo.isIPad {
      // Always show on iPad (split view) when on chat tab
      return true
    } else {
      // On iPhone: show only when the list is visible (no conversation selected and stack is at root)
      return selectedConvoId == nil && chatNavigationPath.wrappedValue.isEmpty
    }
  }
  
  private var shouldShowPagination: Bool {
    !appState.chatManager.acceptedConversations.isEmpty &&
    appState.chatManager.conversationsCursor != nil &&
    !appState.chatManager.loadingConversations
  }
  
  // MARK: - Event Handlers
  
  private func handleOnAppear() {
    Task {
      if appState.chatManager.acceptedConversations.isEmpty && !appState.chatManager.loadingConversations {
        logger.debug("ChatTabView appeared, loading conversations.")
        await appState.chatManager.loadConversations(refresh: true)
      } else {
        logger.debug("ChatTabView appeared, conversations already loaded or loading.")
      }
    }
    appState.chatManager.startConversationsPolling()
  }
  
  private func handleOnDisappear() {
    appState.chatManager.stopConversationsPolling()
  }
  
  private func handleConversationChange(oldValue: String?, newValue: String?) {
    if oldValue != newValue && newValue != nil {
      chatNavigationPath.wrappedValue = NavigationPath()
    }
  }
  
  private func handleErrorStateChange(oldError: ChatManager.ChatError?, newError: ChatManager.ChatError?) {
    if let error = newError, !isShowingErrorAlert {
      let errorMessage = error.localizedDescription
      if lastErrorMessage != errorMessage {
        lastErrorMessage = errorMessage
        isShowingErrorAlert = true
      }
    } else if newError == nil {
      isShowingErrorAlert = false
      lastErrorMessage = nil
    }
  }
  
  private func createErrorAlert() -> Alert {
    Alert(
      title: Text("Chat Error"),
      message: Text(lastErrorMessage ?? "An unknown error occurred."),
      dismissButton: .default(Text("OK")) {
        appState.chatManager.errorState = nil
        lastErrorMessage = nil
      }
    )
  }

  private func startConversation(with profile: ChatBskyActorDefs.ProfileViewBasic) {
    Task {
      logger.debug("Starting conversation with user: \(profile.handle.description)")

      if let convoId = await appState.chatManager.startConversationWith(userDID: profile.did.didString()) {
        logger.debug("Successfully started conversation with ID: \(convoId)")
        await MainActor.run {
          selectedConvoId = convoId
        }
      } else {
        logger.error("Failed to start conversation with user: \(profile.handle.description)")
      }
    }
  }
}

// MARK: - Supporting Views

private struct ConditionalSwipeActions: ViewModifier {
  let conversation: ChatBskyConvoDefs.ConvoView
  let enabled: Bool
  @Environment(AppState.self) private var appState
  
  func body(content: Content) -> some View {
    if enabled {
      content
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
          Button(role: .destructive) {
            Task { await appState.chatManager.leaveConversation(convoId: conversation.id) }
          } label: {
            Label("Delete", systemImage: "trash")
          }
          
          Button {
            if conversation.muted {
              Task { await appState.chatManager.unmuteConversation(convoId: conversation.id) }
            } else {
              Task { await appState.chatManager.muteConversation(convoId: conversation.id) }
            }
          } label: {
            Label(conversation.muted ? "Unmute" : "Mute", systemImage: conversation.muted ? "bell" : "bell.slash")
          }
          .tint(conversation.muted ? .blue : .orange)
        }
    } else {
      content
    }
  }
}

#endif
