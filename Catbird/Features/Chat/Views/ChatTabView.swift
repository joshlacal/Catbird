import SwiftUI
import OSLog
import Petrel
import CatbirdMLSService

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
  @State private var mlsSettingsRefreshTrigger = false  // Triggers view refresh when MLS settings change
  fileprivate let logger = Logger(subsystem: "blue.catbird", category: "ChatUI")

  @AppStorage("chatMode") private var chatModeRaw: String = ChatMode.bluesky.rawValue
  
  /// Per-account MLS chat enabled state - computed from ExperimentalSettings
  private var mlsChatEnabledForCurrentAccount: Bool {
    // Access refresh trigger to make SwiftUI track this dependency
    _ = mlsSettingsRefreshTrigger
    return ExperimentalSettings.shared.isMLSChatEnabled(for: appState.userDID)
  }
  
  private var chatMode: ChatMode {
    get { ChatMode(rawValue: chatModeRaw) ?? .bluesky }
    nonmutating set { chatModeRaw = newValue.rawValue }
  }
  
  private var animatedChatModeRaw: Binding<String> {
    Binding(
      get: { chatModeRaw },
      set: { newValue in
        withAnimation(.easeInOut(duration: 0.2)) {
          chatModeRaw = newValue
        }
      }
    )
  }

  enum ChatMode: String, CaseIterable {
    case bluesky = "Bluesky DMs"
    case mls = "Catbird Groups"

    var icon: String {
      switch self {
      case .bluesky: return "bubble.left.and.bubble.right"
      case .mls: return "lock.shield"
      }
    }
  }

  private var chatNavigationPath: Binding<NavigationPath> {
    appState.navigationManager.pathBinding(for: 4)
  }
  
  private var shouldUseSplitView: Bool {
    DeviceInfo.isIPad || horizontalSizeClass == .regular
  }

  var body: some View {
    ZStack {
      switch chatMode {
      case .bluesky:
        blueskyContent
          .transition(.opacity)
      case .mls:
        mlsContent
          .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: chatModeRaw)
    .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
  }

  @ViewBuilder
  private var blueskyContent: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      chatSidebarContent
    } detail: {
      chatDetailContent
    }
    .navigationSplitViewStyle(.automatic)
    // Hide tab bar when viewing a conversation on iPhone
    .toolbar(selectedConvoId != nil && !shouldUseSplitView ? .hidden : .visible, for: .tabBar)
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
    .onChange(of: appState.navigationManager.targetConversationId) { oldValue, newValue in
      // Handle deep-link navigation to a specific conversation
      if let convoId = newValue, convoId != selectedConvoId {
        logger.info("Deep-link navigation to conversation: \(convoId)")
        selectedConvoId = convoId
        // Clear the target after setting to avoid repeated navigation
        appState.navigationManager.targetConversationId = nil
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

  @ViewBuilder
  private var mlsContent: some View {
    // Use computed property to check per-account setting directly
    if mlsChatEnabledForCurrentAccount {
      MLSConversationListView(selectedTab: $selectedTab)
    } else {
      mlsExperimentalGate
    }
  }
  
  @ViewBuilder
  private var mlsExperimentalGate: some View {
    NavigationStack {
      VStack(spacing: 0) {
        // Chat mode picker at top (matching NotificationsView pattern)
        chatModePicker
          .padding(.vertical, 8)
        
        VStack(spacing: 24) {
          Spacer()
          
          Image(systemName: "lock.shield")
            .font(.system(size: 64))
            .foregroundStyle(.secondary)
          
          Text("Catbird Groups")
            .font(.title2)
            .fontWeight(.semibold)
          
          Text("End-to-end encrypted group chat using the MLS protocol.")
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
          
          VStack(alignment: .leading, spacing: 12) {
            Label("Messages are encrypted on your device", systemImage: "checkmark.circle.fill")
            Label("Only group members can read messages", systemImage: "checkmark.circle.fill")
            Label("Server cannot access message content", systemImage: "checkmark.circle.fill")
          }
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(.vertical)
          
          Divider()
            .padding(.horizontal, 48)
          
          VStack(spacing: 8) {
            Label("Highly Experimental", systemImage: "exclamationmark.triangle.fill")
              .font(.headline)
              .foregroundStyle(.orange)
            
            Text("This feature is under active development. You may experience bugs, missing messages, or other issues. Use at your own risk.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
              .padding(.horizontal, 32)
              .lineLimit(nil)
          }
          .padding(.vertical)
          
          Toggle(isOn: Binding(
            get: { mlsChatEnabledForCurrentAccount },
            set: { newValue in
              if newValue {
                // Optimistically enable locally so the toggle reflects immediately
                ExperimentalSettings.shared.enableMLSChat(for: appState.userDID)
                mlsSettingsRefreshTrigger.toggle()

                Task {
                  // Perform server opt-in; if it fails, revert the local setting
                  await optInToMLS()
                  // After attempting opt-in, verify the effective state; if still not enabled, revert
                  if !ExperimentalSettings.shared.isMLSChatEnabled(for: appState.userDID) {
                    ExperimentalSettings.shared.disableMLSChat(for: appState.userDID)
                    mlsSettingsRefreshTrigger.toggle()
                  }
                }
              } else {
                // Immediately reflect off state locally, then inform server
                ExperimentalSettings.shared.disableMLSChat(for: appState.userDID)
                mlsSettingsRefreshTrigger.toggle()
                Task {
                  await optOutFromMLS()
                }
              }
            }
          )) {
            Text("Enable Catbird Groups")
              .fontWeight(.medium)
          }
          .toggleStyle(.switch)
          .padding(.horizontal, 48)
          .padding(.vertical, 8)
          
          Spacer()
        }
        .frame(maxWidth: .infinity)
      }
      .navigationTitle("Messages")
      #if os(iOS)
      .toolbarTitleDisplayMode(.large)
      #endif
      .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
    }
  }
  
  /// Opt in to MLS on the server and initialize device/key packages
  /// CRITICAL: Must initialize MLS before optIn to ensure key packages are uploaded
  @MainActor
  private func optInToMLS() async {
    let userDID = appState.userDID
    
    do {
      // Initialize MLS first (device registration + key packages)
      try await appState.initializeMLS()
      
      // Then call optIn to mark user as available
      guard let apiClient = await appState.getMLSAPIClient() else {
        logger.warning("Cannot opt in: MLS API client not available")
        return
      }
      _ = try await apiClient.optIn()
      
      // Save local setting only after successful server opt-in
      ExperimentalSettings.shared.enableMLSChat(for: userDID)
      logger.info("Successfully opted in to MLS chat")
    } catch {
      logger.error("Failed to opt in to MLS: \(error.localizedDescription)")
      // Failed to opt in - don't save local setting, user will need to try again
    }
  }
  
  /// Opt out from MLS on the server when user disables the feature
  @MainActor
  private func optOutFromMLS() async {
    guard let apiClient = await appState.getMLSAPIClient() else {
      logger.warning("Cannot opt out: MLS API client not available")
      return
    }
    
    do {
      let success = try await apiClient.optOut()
      if success {
        logger.info("Successfully opted out from MLS on server")
      } else {
        logger.warning("Opt-out returned false (user may not have been opted in)")
      }
    } catch {
      logger.error("Failed to opt out from MLS: \(error.localizedDescription)")
      // Don't show error to user - the local toggle is already off
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
      // Chat mode picker as first list item (like NotificationsView)
      chatModePicker
        .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
      
      if !searchText.isEmpty {
        searchResultsContent
      } else {
        mainConversationListContent
      }
    }
    .listStyle(.plain)
    .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
    .onChange(of: searchText) { _, newValue in
      appState.chatManager.searchLocal(searchTerm: newValue, currentUserDID: appState.userDID)
    }
    .refreshable {
      await appState.chatManager.loadConversations(refresh: true)
    }
    .overlay {
      conversationListOverlay
    }
    .navigationTitle("Messages")
    #if os(iOS)
    .toolbarTitleDisplayMode(.large)
    #endif
    .themedNavigationBar(appState.themeManager)
    .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 400)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        MessageRequestsButton()
      }
      ToolbarItem(placement: .primaryAction) {
        ChatToolbarMenu()
      }
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
      currentUserDID: appState.userDID
    )
    .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
    .modifier(ConditionalSwipeActions(conversation: convo, enabled: withSwipeActions))
    .contextMenu {
      ConversationContextMenu(conversation: convo)
    }
    .tag(convo.id)
  }
  
  // MARK: - Chat Mode Picker
  
  @ViewBuilder
  private var chatModePicker: some View {
    Picker("Chat Mode", selection: animatedChatModeRaw) {
      ForEach(ChatMode.allCases, id: \.self) { mode in
        Label(mode.rawValue, systemImage: mode.icon)
          .tag(mode.rawValue)
      }
    }
    .pickerStyle(.segmented)
    .frame(height: 36)
    .frame(maxWidth: 600)
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .listRowInsets(EdgeInsets())
    .listRowSeparator(.hidden)
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
    // Keep polling active so unread counts/notifications stay fresh even when leaving the chat tab.
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

