import OSLog
import Petrel
import SwiftUI

#if os(iOS)

// MARK: - Chat Tab View

struct ChatTabView: View {
  @Environment(SceneNavigationContext.self) private var sceneContext
  @Environment(AppState.self) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.composerTransitionNamespace) private var composerNamespace

  private var contentMaxWidth: CGFloat {
    horizontalSizeClass == .compact ? .infinity : 600
  }

  @Binding var selectedTab: Int
  @Binding var lastTappedTab: Int?
  @State private var selectedConvoId: String?
  @State private var searchText = ""
  @State private var isShowingErrorAlert = false
  @State private var lastErrorMessage: String?
  @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
  @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
  @State private var showingNewMessageSheet = false
  @State private var showingSettings = false
  @State private var coordinator = UnifiedChatCoordinator()
  @State private var coordinatorAccountDID: String?
  fileprivate let logger = Logger(subsystem: "blue.catbird", category: "ChatUI")

  private var chatNavigationPath: Binding<NavigationPath> {
    sceneContext.navigationManager.pathBinding(for: 4)
  }

  private var shouldUseSplitView: Bool {
    horizontalSizeClass == .regular
  }

  // MARK: - Body

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn) {
      unifiedSidebarContent
    } detail: {
      unifiedDetailContent
    }
    .navigationSplitViewStyle(.automatic)
    #if !targetEnvironment(macCatalyst)
    .toolbar(selectedConvoId != nil && !shouldUseSplitView ? .hidden : .visible, for: .tabBar)
    #endif
    .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
    .onAppear(perform: handleOnAppear)
    .onChange(of: selectedConvoId) { oldValue, newValue in
      handleConversationChange(oldValue: oldValue, newValue: newValue)
      preferredCompactColumn = newValue != nil ? .detail : .sidebar
      if !shouldUseSplitView {
        columnVisibility = newValue != nil ? .detailOnly : .doubleColumn
      }
    }
    .onChange(of: preferredCompactColumn) { _, column in
      guard !shouldUseSplitView, column == .sidebar, preferredCompactColumn == .sidebar else { return }
      if sceneContext.navigationManager.targetConversationId != nil ||
          sceneContext.navigationManager.chatRootRequestID != nil {
        consumeNavigationRequests()
      } else {
        returnToConversationList()
      }
    }
    .onChange(of: lastTappedTab) { _, tab in
      guard tab == AppNavigationManager.chatTabIndex, selectedTab == tab else { return }
      lastTappedTab = nil
      sceneContext.navigationManager.requestChatRoot()
      consumeNavigationRequests()
    }
    .onChange(of: appState.chatManager.acceptedConversations) { _, newValue in
      resetUnifiedListForCurrentAccountIfNeeded()
      guard coordinatorAccountDID == appState.userDID else { return }
      coordinator.blueskyConversations = newValue
    }
    .onChange(of: appState.userDID) { _, _ in
      handleAccountContextChanged()
    }
    .onChange(of: sceneContext.navigationManager.targetConversationId) { _, _ in
      consumeNavigationRequests()
    }
    .onChange(of: sceneContext.navigationManager.chatRootRequestID) { _, _ in
      consumeNavigationRequests()
    }
    .onChange(of: appState.chatManager.errorState) { oldError, newError in
      handleErrorStateChange(oldError: oldError, newError: newError)
    }
    .alert(isPresented: $isShowingErrorAlert, content: createErrorAlert)
    .sheet(isPresented: $showingNewMessageSheet) {
      NewConversationView()
        .composerZoomTransition(namespace: composerNamespace)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
    .sheet(isPresented: $showingSettings) {
      SettingsView()
        .applyAppStateEnvironment(appState)
        .environment(appState)
    }
    #if !targetEnvironment(macCatalyst)
    .overlay(alignment: .bottomTrailing) {
      if shouldShowChatFAB {
        ChatFAB(newMessageAction: {
          showingNewMessageSheet = true
        })
        .nuxNudge(id: .groupChatsAnnouncement)
        .padding(.bottom, 20)
        .padding(.trailing, 20)
      }
    }
    #endif
  }

  // MARK: - Unified Sidebar

  @ViewBuilder
  private var unifiedSidebarContent: some View {
    List(selection: $selectedConvoId) {
      if !searchText.isEmpty {
        searchResultsContent
      } else {
        Section {
          ForEach(coordinator.conversations) { item in
            unifiedRow(for: item)
              .listRowSeparator(item.id == coordinator.conversations.first?.id ? .hidden : .visible, edges: .top)
          }

          if shouldShowPagination {
            paginationView
          }

          Spacer()
            .frame(height: 80)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
        .listSectionSeparator(.hidden, edges: .top)
      }
    }
    // Keyed on the account, not per row: explicit `.id()` on rows inside a List's
    // ForEach breaks the collection view diff (UICollectionView "invalid number of
    // items in section" crash when an update lands mid-transition).
    .id(appState.userDID)
    .listStyle(.plain)
    .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
    .onChange(of: searchText) { _, newValue in
      appState.chatManager.searchLocal(searchTerm: newValue, currentUserDID: appState.userDID)
    }
    .refreshable {
      await appState.chatManager.loadConversations(refresh: true, userInitiated: true)
    }
    .overlay {
      listOverlay
    }
    .navigationTitle("Messages")
    #if os(iOS)
    .toolbarTitleDisplayMode(.large)
    #endif
    .themedNavigationBar(appState.themeManager)
    .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 400)
    #if !targetEnvironment(macCatalyst)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        MessageRequestsButton()
      }
      if shouldUseSplitView {
        ToolbarItem(placement: .primaryAction) {
          Button {
            showingNewMessageSheet = true
          } label: {
            Label("New Message", systemImage: "square.and.pencil")
          }
        }
      }
      ToolbarItem(placement: .primaryAction) {
        ChatToolbarMenu()
      }
      ToolbarItem(placement: .primaryAction) {
        SettingsAvatarToolbarButton {
          showingSettings = true
        }
      }
    }
    #endif
  }

  // MARK: - Empty, Loading and Error States

  @ViewBuilder
  private var listOverlay: some View {
    let chatManager = appState.chatManager
    if !searchText.isEmpty {
      if chatManager.filteredProfiles.isEmpty && chatManager.filteredConversations.isEmpty {
        ContentUnavailableView.search(text: searchText)
      }
    } else if coordinator.conversations.isEmpty {
      if chatManager.loadingConversations || !chatManager.hasAttemptedConversationsLoad {
        ProgressView()
      } else if chatManager.lastConversationsLoadFailed {
        ContentUnavailableView {
          Label("Couldn’t Load Messages", systemImage: "wifi.exclamationmark")
        } description: {
          Text("Check your connection and try again.")
            .enhancedAppBody()
        } actions: {
          Button("Try Again") {
            Task { await chatManager.loadConversations(refresh: true, userInitiated: true) }
          }
        }
      } else {
        ContentUnavailableView {
          Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
        } description: {
          Text("You haven’t started any chats yet.")
            .enhancedAppBody()
        } actions: {
          Button("New Message") {
            showingNewMessageSheet = true
          }
        }
      }
    }
  }

  // MARK: - Row Routing

  @ViewBuilder
  private func unifiedRow(for item: UnifiedConversation) -> some View {
    switch item {
    case .bluesky(let convo):
      ConversationRow(convo: convo, currentUserDID: appState.userDID)
        .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
        .modifier(ConditionalSwipeActions(conversation: convo, enabled: true))
        .modifier(ConversationContextMenu(conversation: convo))
        .tag(item.id)
    }
  }

  // MARK: - Unified Detail

  @ViewBuilder
  private var unifiedDetailContent: some View {
    NavigationStack(path: chatNavigationPath) {
      if let convoId = selectedConvoId {
        // Keep the detail identity stable while a deep-linked conversation's
        // sidebar row arrives; list membership must not replace its lifecycle.
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

  // MARK: - Search Results

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
          ConversationRow(convo: convo, currentUserDID: appState.userDID)
            .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
            .modifier(ConditionalSwipeActions(conversation: convo, enabled: true))
            .modifier(ConversationContextMenu(conversation: convo))
            .tag(convo.id)
        }
      }
    }
  }

  @ViewBuilder
  private func contactRow(for profileBasic: ChatBskyActorDefs.ProfileViewBasic) -> some View {
    Button {
      startConversation(with: profileBasic)
    } label: {
      HStack {
        ChatProfileAvatarView(profile: profileBasic, size: 40)
        VStack(alignment: .leading) {
          Text(profileBasic.chatDisplayName)
            .appHeadline()
            .foregroundColor(.primary)
          Text("@\(profileBasic.handle.description)")
            .appSubheadline()
            .foregroundColor(.secondary)
          if profileBasic.chatDisabled == true {
            Text("Can’t be messaged")
              .appCaption()
              .foregroundColor(.secondary)
          }
        }
      }
      .spacingSM(.vertical)
    }
    .buttonStyle(.plain)
    .disabled(profileBasic.chatDisabled == true)
    .opacity(profileBasic.chatDisabled == true ? 0.5 : 1)
    .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
  }

  // MARK: - Helper Properties

  /// The floating New Message button only shows over the bare list; split
  /// layouts use the sidebar toolbar button so it never covers the composer.
  private var shouldShowChatFAB: Bool {
    guard selectedTab == 4, !shouldUseSplitView else { return false }
    return selectedConvoId == nil && chatNavigationPath.wrappedValue.isEmpty
  }

  private var shouldShowPagination: Bool {
    !appState.chatManager.acceptedConversations.isEmpty &&
    appState.chatManager.conversationsCursor != nil &&
    !appState.chatManager.loadingConversations
  }

  @ViewBuilder
  private var paginationView: some View {
    ProgressView("Loading more…")
      .frame(maxWidth: .infinity)
      .padding()
      .onAppear {
        Task {
          await appState.chatManager.loadConversations(refresh: false)
        }
      }
  }

  // MARK: - Event Handlers

  private func handleOnAppear() {
    resetUnifiedListForCurrentAccountIfNeeded()

    // A root request or conversation link can arrive before this tab mounts.
    consumeNavigationRequests()

    // Bluesky DMs
    Task {
      if appState.chatManager.acceptedConversations.isEmpty && !appState.chatManager.loadingConversations {
        await appState.chatManager.loadConversations(refresh: true, userInitiated: true)
      }
    }
    appState.chatManager.startConversationsPolling()
    coordinator.blueskyConversations = appState.chatManager.acceptedConversations
  }

  @MainActor
  private func resetUnifiedListForCurrentAccountIfNeeded() {
    let currentUserDID = appState.userDID
    guard coordinatorAccountDID != currentUserDID else { return }

    coordinatorAccountDID = currentUserDID
    selectedConvoId = nil
    searchText = ""
    coordinator.reset()
    coordinator.blueskyConversations = appState.chatManager.acceptedConversations
  }

  private func handleAccountContextChanged() {
    Task { @MainActor in
      resetUnifiedListForCurrentAccountIfNeeded()
      if let convoId = selectedConvoId {
        if !coordinator.conversations.contains(where: { $0.id == convoId }) {
          selectedConvoId = nil
          chatNavigationPath.wrappedValue = NavigationPath()
        }
      }
      await appState.chatManager.loadConversations(refresh: true)
    }
  }

  private func handleConversationChange(oldValue: String?, newValue: String?) {
    if oldValue != newValue && newValue != nil {
      chatNavigationPath.wrappedValue = NavigationPath()
    }
  }

  private func consumeNavigationRequests() {
    let navigation = sceneContext.navigationManager
    if navigation.consumeChatRootRequest() {
      returnToConversationList()
    }
    // Consume even an already-selected ID so a later appearance cannot replay it.
    if let convoId = navigation.consumeTargetConversation() {
      selectedConvoId = convoId
      preferredCompactColumn = .detail
      if !shouldUseSplitView {
        columnVisibility = .detailOnly
      }
    }
  }

  private func returnToConversationList() {
    selectedConvoId = nil
    sceneContext.navigationManager.targetConversationId = nil
    chatNavigationPath.wrappedValue = NavigationPath()
    columnVisibility = .doubleColumn
    preferredCompactColumn = .sidebar
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
      title: Text("Messages"),
      message: Text(lastErrorMessage ?? "Something went wrong. Try again."),
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
  @State private var showingOwnerLeaveAlert = false
  @State private var showingLeaveAlert = false

  func body(content: Content) -> some View {
    if enabled {
      content
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
          Button(role: .destructive) {
            // Group owners can't leave until the group is locked
            // (`OwnerCannotLeave`) — confirm the lock-then-leave path instead.
            if conversation.isOwnedGroupConversation(currentUserDID: appState.userDID) {
              showingOwnerLeaveAlert = true
            } else {
              showingLeaveAlert = true
            }
          } label: {
            Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
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
        .alert("Leave Conversation?", isPresented: $showingLeaveAlert) {
          Button("Cancel", role: .cancel) { }
          Button("Leave", role: .destructive) {
            Task { await appState.chatManager.leaveConversation(convoId: conversation.id) }
          }
        } message: {
          Text("The conversation will be removed from your list. Your messages will be deleted for you, but not for the other participants.")
        }
        .alert("Lock & Leave Group", isPresented: $showingOwnerLeaveAlert) {
          Button("Cancel", role: .cancel) { }
          Button("Lock & Leave", role: .destructive) {
            Task { await appState.chatManager.lockAndLeaveConversation(convoId: conversation.id) }
          }
        } message: {
          Text("As the owner, you must lock this group before leaving. Your messages will be deleted for you, but not for the other participants.")
        }
    } else {
      content
    }
  }
}

#endif

#if os(iOS)
#Preview("ChatTabView") {
  @Previewable @State var selectedTab = 3
  @Previewable @State var lastTappedTab: Int? = nil
  ChatTabView(selectedTab: $selectedTab, lastTappedTab: $lastTappedTab)
    .previewWithAuthenticatedState()
}
#endif
