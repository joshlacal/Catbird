import CatbirdMLSCore
import OSLog
import Petrel
import SwiftUI

#if os(iOS)

// MARK: - MLSListChangeObserver

/// Bridges StateInvalidationBus MLS events to an AsyncStream
private final class MLSListChangeObserver: StateInvalidationSubscriber {
  let continuation: AsyncStream<Void>.Continuation

  init(continuation: AsyncStream<Void>.Continuation) {
    self.continuation = continuation
  }

  func isInterestedIn(_ event: StateInvalidationEvent) -> Bool {
    if case .mlsConversationListChanged = event { return true }
    return false
  }

  func handleStateInvalidation(_ event: StateInvalidationEvent) async {
    continuation.yield()
  }
}

// MARK: - MLS Conversation Prompt

/// Single confirmation/status prompt for MLS conversation destructive actions.
///
/// Deliberately one value driving one `.alert` layer. These conversation lists
/// live in the eagerly-built `MainContentView` tab tree, where every extra
/// modifier layer enlarges the composed view value on the main thread stack.
/// Separate alerts per action overflowed the 1 MB device stack at launch.
struct MLSConversationPrompt: Identifiable {
  enum Kind {
    case confirmDeleteForMe(MLSConversationModel, targetDID: String)
    case confirmLeave(MLSConversationModel)
    case status
  }

  let id = UUID()
  let kind: Kind
  let title: String
  let message: String

  static func deleteForMe(_ conversation: MLSConversationModel, targetDID: String) -> Self {
    .init(
      kind: .confirmDeleteForMe(conversation, targetDID: targetDID),
      title: String(localized: "Delete Conversation for Me?", comment: "Alert title confirming local deletion of an encrypted conversation"),
      message: String(
        localized: "This will remove the conversation and its message history from this device only. You will not leave the conversation, and other participants will not be affected. This cannot be undone.",
        comment: "Alert message explaining local-only deletion of an encrypted conversation"
      )
    )
  }

  static func leave(_ conversation: MLSConversationModel) -> Self {
    .init(
      kind: .confirmLeave(conversation),
      title: String(localized: "Leave Conversation?", comment: "Alert title confirming leaving an encrypted conversation"),
      message: String(
        localized: "Are you sure you want to leave this conversation? You will no longer be able to send or receive messages.",
        comment: "Alert message explaining consequences of leaving an encrypted conversation"
      )
    )
  }

  static func status(title: String, message: String) -> Self {
    .init(kind: .status, title: title, message: message)
  }
}

// MARK: - Chat Tab View

struct ChatTabView: View {
  @Environment(SceneNavigationContext.self) private var sceneContext
  @Environment(AppState.self) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.composerTransitionNamespace) private var composerNamespace
  @Environment(\.scenePhase) private var scenePhase

  private var contentMaxWidth: CGFloat {
    horizontalSizeClass == .compact ? .infinity : 600
  }

  @Binding var selectedTab: Int
  @Binding var lastTappedTab: Int?
  @State private var selectedConvoId: String?
  /// A first message's new conversation, held while a destination (such as the person's
  /// profile) is pushed over its draft screen, so finishing the send doesn't pop it.
  @State private var pendingDraftHandoff: (selection: String, conversation: String)?
  @State private var searchText = ""
  @State private var isShowingErrorAlert = false
  @State private var lastErrorMessage: String?
  @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
  @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
  @State private var showingNewMessageSheet = false
  @State private var showingSettings = false
  @State private var coordinator = UnifiedChatCoordinator()
  @State private var mlsPollingTask: Task<Void, Never>?
  @State private var mlsPollCycleCount: Int = 0
  @State private var coordinatorAccountDID: String?
  // Eager-fetch coalescing: prevents redundant batches when mount + scene-active fire close together
  @State private var lastEagerRefreshAt: Date?
  @State private var isTabVisible = false
  fileprivate let logger = Logger(subsystem: "blue.catbird", category: "ChatUI")
  @State private var mlsConversationPrompt: MLSConversationPrompt?
  @State private var deviceApproval = DeviceApprovalModel()

  /// Maximum convos to fetch in a single eager-refresh batch.
  /// Bounds battery + network cost; remaining convos catch up via per-convo WS on open
  /// or via the existing fallback poll loop.
  private let eagerRefreshTopN: Int = 10

  /// Throttle window for eager refresh — avoids double-firing when onAppear and scenePhase
  /// transitions happen close together (e.g. tab focus + foreground).
  private let eagerRefreshThrottle: TimeInterval = 5

  /// Per-account MLS chat enabled state
  private var mlsChatEnabledForCurrentAccount: Bool {
    appState.isMLSRuntimeAllowed
  }

  /// Retained for backwards compatibility.
  /// No longer drives view switching — the unified list shows both types together.
  enum ChatMode: String, CaseIterable {
    case bluesky = "Bluesky DMs"
    case mls = "Catbird Groups"

    var displayName: String {
      switch self {
      case .bluesky:
        return String(localized: "Bluesky DMs", comment: "Chat mode label for Bluesky direct messages")
      case .mls:
        return String(localized: "Catbird Groups", comment: "Chat mode label for Catbird encrypted groups")
      }
    }

    var icon: String {
      switch self {
      case .bluesky: return "bubble.left.and.bubble.right"
      case .mls: return "lock.shield"
      }
    }
  }

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
    .background(MLSIntroSheetHost())
    .onAppear(perform: handleOnAppear)
    .onDisappear(perform: handleOnDisappear)
    .onChange(of: scenePhase) { oldPhase, newPhase in
      handleScenePhaseChange(from: oldPhase, to: newPhase)
    }
    .onChange(of: selectedConvoId) { oldValue, newValue in
      handleConversationChange(oldValue: oldValue, newValue: newValue)
      publishOpenConversation()
      preferredCompactColumn = newValue != nil ? .detail : .sidebar
      if !shouldUseSplitView {
        columnVisibility = newValue != nil ? .detailOnly : .doubleColumn
      }
    }
    .onChange(of: preferredCompactColumn) { _, column in
      guard !shouldUseSplitView, column == .sidebar, preferredCompactColumn == .sidebar else { return }
      if sceneContext.navigationManager.targetConversationId != nil ||
          sceneContext.navigationManager.targetMLSConversationId != nil ||
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
    .onChange(of: sceneContext.navigationManager.targetMLSConversationId) { _, _ in
      consumeNavigationRequests()
    }
    .onChange(of: appState.chatManager.errorState) { oldError, newError in
      handleErrorStateChange(oldError: oldError, newError: newError)
    }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MLSConversationLeft"))) { note in
      // MLSConversationDetailView/MLSGroupDetailView post this after a successful
      // leave. Its own `dismiss()` is a no-op here since this view is hosted inline
      // (driven by `selectedConvoId`), not sheet-presented — without this, leaving
      // via the Chat Info sheet left the just-left conversation's detail screen
      // stuck on screen showing a "couldn't load messages" error.
      if let convoID = note.object as? String, convoID == selectedConvoId {
        selectedConvoId = nil
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MLSConversationDeleted"))) { note in
      guard let convoID = note.object as? String else { return }
      if let noteDID = note.userInfo?["userDID"] as? String {
        guard noteDID == appState.userDID else { return }
      }
      var updatedState = coordinator.mlsState
      updatedState.conversations.removeAll { $0.conversationID == convoID }
      updatedState.participants.removeValue(forKey: convoID)
      updatedState.unreadCounts.removeValue(forKey: convoID)
      updatedState.lastMessages.removeValue(forKey: convoID)
      updatedState.memberChanges.removeValue(forKey: convoID)
      coordinator.mlsState = updatedState
      if convoID == selectedConvoId {
        selectedConvoId = nil
      }
    }
    // One alert layer, not three: this body sits inside the eagerly-built
    // MainContentView tab tree, where each extra modifier layer grows the
    // composed view value. Three stacked alerts here exhausted the 1 MB
    // device main-thread stack at launch (EXC_BAD_ACCESS on the stack guard).
    .alert(
      mlsConversationPrompt?.title ?? "",
      isPresented: .init(
        get: { mlsConversationPrompt != nil },
        set: { if !$0 { mlsConversationPrompt = nil } }
      ),
      presenting: mlsConversationPrompt
    ) { prompt in
      switch prompt.kind {
      case .confirmDeleteForMe(let convo, let targetDID):
        Button("Cancel", role: .cancel) { mlsConversationPrompt = nil }
        Button("Delete for Me", role: .destructive) {
          mlsConversationPrompt = nil
          deleteMLSConversationForMe(convo, targetDID: targetDID)
        }
      case .confirmLeave(let convo):
        Button("Cancel", role: .cancel) { mlsConversationPrompt = nil }
        Button("Leave", role: .destructive) {
          mlsConversationPrompt = nil
          leaveMLSConversation(convo)
        }
      case .status:
        Button("OK", role: .cancel) { mlsConversationPrompt = nil }
      }
    } message: { prompt in
      Text(prompt.message)
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
        if mlsChatEnabledForCurrentAccount,
           let eligibility = appState.spacesEligibility,
           !eligibility.eligible {
          Section {
            MLSSpacesRequiredGateView(
              eligibility: eligibility,
              onReauthorizeScopes: { present in
                await appState.reauthorizeSpacesForMLS(present: present)
              },
              onRefreshCheck: {
                try? await appState.initializeMLS()
              }
            )
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
          }
        }

        if mlsChatEnabledForCurrentAccount, deviceApproval.copy != nil {
          Section {
            DeviceApprovalCard(model: deviceApproval)
              .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
              .listRowSeparator(.hidden)
          }
        }

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
    .modifier(DeviceApprovalTracking(model: deviceApproval))
    .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
    .onChange(of: searchText) { _, newValue in
      appState.chatManager.searchLocal(searchTerm: newValue, currentUserDID: appState.userDID)
    }
    .refreshable {
      async let bsky: Void = appState.chatManager.loadConversations(refresh: true, userInitiated: true)
      async let mls: Void = {
        await appState.loadMLSConversations()
        await loadMLSConversations()
      }()
      _ = await (bsky, mls)
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

    case .mls(let convo, let participants, let unreadCount, let lastMessage, let memberChange, _):
      MLSConversationRowView(
        conversation: convo,
        participants: participants,
        recentMemberChange: memberChange,
        unreadCount: unreadCount,
        lastMessage: lastMessage
      )
      .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
      .tag(item.id)
      .swipeActions(edge: .trailing, allowsFullSwipe: false) {
        Button(role: .destructive) {
          mlsConversationPrompt = .deleteForMe(convo, targetDID: appState.userDID)
        } label: {
          Label("Delete for Me", systemImage: "trash")
        }
        Button(role: .destructive) {
          mlsConversationPrompt = .leave(convo)
        } label: {
          Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
        }
        Button {
          toggleMLSMute(convo)
        } label: {
          if convo.isMuted {
            Label("Unmute", systemImage: "bell")
          } else {
            Label("Mute", systemImage: "bell.slash")
          }
        }
        .tint(convo.isMuted ? Color.accentColor : .orange)
      }
    }
  }

  // MARK: - Unified Detail

  @ViewBuilder
  private var unifiedDetailContent: some View {
    NavigationStack(path: chatNavigationPath) {
      if let convoId = selectedConvoId {
        // Keep the detail identity stable while a deep-linked conversation's
        // sidebar row arrives; list membership must not replace its lifecycle.
        // Before the row arrives, route by id shape so MLS deep links don't open
        // the Bluesky detail view.
        if let recipientDID = MLSDirectDraftRoute.recipientDID(fromSelectionID: convoId) {
          // No chat with this person yet: the chat screen for them, whose first message
          // creates the conversation and then selects it.
          MLSDirectDraftConversationView(recipientDID: recipientDID) { conversationID in
            // The send can finish after they have moved on; only replace this screen, and
            // wait until anything pushed over it has been popped.
            guard selectedConvoId == convoId else { return }
            if chatNavigationPath.wrappedValue.isEmpty {
              showConversation(conversationID)
            } else {
              pendingDraftHandoff = (convoId, conversationID)
            }
          }
          .id("\(convoId):\(appState.userDID)")
        } else if isMLSConversation(convoId) {
          MLSRequestConversationGate(conversationID: convoId) {
            MLSConversationDetailView(conversationId: convoId)
          }
          .id("\(convoId):\(appState.userDID)")
        } else {
          ConversationView(convoId: convoId, isChatTabSelection: true)
            .id(convoId)
        }
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
    // A destination pushed over the conversation takes the screen until it is popped. Observed
    // on the detail stack rather than added to the body's chain (see the note at its alert).
    .onChange(of: chatNavigationPath.wrappedValue.isEmpty) { _, isEmpty in
      publishOpenConversation()
      if isEmpty, let handoff = pendingDraftHandoff {
        pendingDraftHandoff = nil
        if selectedConvoId == handoff.selection {
          showConversation(handoff.conversation)
        }
      }
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
          Text(verbatim: "@\(profileBasic.handle.description)")
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
    isTabVisible = true
    appState.chatManager.setChatTabVisible(true)
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

    // MLS
    coordinator.mlsEnabled = mlsChatEnabledForCurrentAccount
    if mlsChatEnabledForCurrentAccount {
      Task {
        // Initial DB-backed load paints the list from local cache.
        await loadMLSConversations()
        // After cache paints, eagerly fetch + decrypt the latest message for the
        // top-N most-recently-active convos so previews + unread counts reflect
        // server state without requiring the user to tap into each convo.
        await performEagerRefreshIfNeeded(reason: "mount")
      }
      startMLSPolling()

      // B8: kick off the full MLS init so the global WebSocket subscription
      // starts. Without this, `appState.initializeMLS()` only runs from
      // Settings or direct convo entry, so the global WS — which is
      // the ONLY transport that delivers `groupResetEvent` for convos the
      // user hasn't manually opened — never connects on a normal Chat-tab
      // launch. Effect: server-side auto-resets (Phase 2 sweep, quorum)
      // never reach `handleGroupReset` for any convo unless the user taps
      // into it, so the post-reset bootstrap path can't fire and the convo
      // stays broken in the UI.
      //
      // initializeMLS() is idempotent — its inner gate
      // (`mlsGlobalWebSocketSubscriptionStarted`) makes the subscribe call
      // a no-op after the first success in this AppState lifetime, so
      // calling it on every Chat-tab appearance is safe.
      Task {
        do {
          try await appState.initializeMLS()
        } catch {
          logger.error("MLS init failed from ChatTabView.onAppear: \(error.localizedDescription)")
        }
      }
    }
    publishOpenConversation()
  }

  private func handleOnDisappear() {
    isTabVisible = false
    appState.chatManager.setChatTabVisible(false)
    publishOpenConversation()
    stopMLSPolling()
  }

  /// Tells ChatManager which Bluesky conversation this tab shows. Its polling follows this
  /// selection rather than ConversationView's appearance, which a split view can report out
  /// of order. MLS conversations poll through their own detail view.
  private func publishOpenConversation() {
    appState.chatManager.setChatTabConversation(
      Self.shownConversation(
        selection: selectedConvoId,
        isTabVisible: isTabVisible,
        hasPushedDestination: !chatNavigationPath.wrappedValue.isEmpty,
        isMLS: { isMLSConversation($0) }
      )
    )
  }

  /// The selected Bluesky conversation while it is on screen: the tab is visible and no
  /// destination (a profile, a post) is pushed over it. A pushed ConversationView polls as
  /// its own view appears and disappears.
  static func shownConversation(
    selection: String?, isTabVisible: Bool, hasPushedDestination: Bool, isMLS: (String) -> Bool
  ) -> String? {
    guard isTabVisible, !hasPushedDestination, let selection, !isMLS(selection) else { return nil }
    return selection
  }

  @MainActor
  private func resetUnifiedListForCurrentAccountIfNeeded() {
    let currentUserDID = appState.userDID
    guard coordinatorAccountDID != currentUserDID else { return }

    coordinatorAccountDID = currentUserDID
    selectedConvoId = nil
    searchText = ""
    lastEagerRefreshAt = nil
    coordinator.reset()
    coordinator.mlsEnabled = mlsChatEnabledForCurrentAccount
    coordinator.blueskyConversations = appState.chatManager.acceptedConversations
  }

  private func handleAccountContextChanged() {
    stopMLSPolling()
    Task { @MainActor in
      resetUnifiedListForCurrentAccountIfNeeded()
      if let convoId = selectedConvoId {
        if !coordinator.conversations.contains(where: { $0.id == convoId }) {
          selectedConvoId = nil
          chatNavigationPath.wrappedValue = NavigationPath()
        }
      }
      await appState.chatManager.loadConversations(refresh: true)
      if mlsChatEnabledForCurrentAccount {
        await loadMLSConversations()
        startMLSPolling()
      }
    }
  }

  private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
    // Only react when transitioning into the active phase; ignore inactive/background.
    guard newPhase == .active, oldPhase != .active else { return }
    guard mlsChatEnabledForCurrentAccount else { return }
    Task {
      // Reload from DB first so any messages decrypted by NSE while we were
      // backgrounded are reflected, then eagerly refresh top-N from server.
      await loadMLSConversations()
      await performEagerRefreshIfNeeded(reason: "foreground")
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
      showConversation(convoId)
    }
    if let convoId = navigation.targetMLSConversationId {
      navigation.targetMLSConversationId = nil
      showConversation(convoId)
    }
  }

  private func showConversation(_ convoId: String) {
    selectedConvoId = convoId
    preferredCompactColumn = .detail
    if !shouldUseSplitView {
      columnVisibility = .detailOnly
    }
  }

  /// Routes by the coordinator's merged list once the row is present, and by id
  /// shape for deep links that arrive before the lists load.
  private func isMLSConversation(_ convoId: String) -> Bool {
    if MLSDirectDraftRoute.recipientDID(fromSelectionID: convoId) != nil { return true }
    if let item = coordinator.conversations.first(where: { $0.id == convoId }) {
      return item.isMLS
    }
    return UnifiedConversation.idLooksLikeMLSConversation(convoId)
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
    let messageView: Text = if let lastErrorMessage {
      Text(lastErrorMessage)
    } else {
      Text("Something went wrong. Try again.")
    }
    return Alert(
      title: Text("Messages"),
      message: messageView,
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

  // MARK: - MLS Data Loading

  @MainActor
  private func loadMLSConversations() async {
    resetUnifiedListForCurrentAccountIfNeeded()

    guard mlsChatEnabledForCurrentAccount else {
      coordinator.mlsEnabled = false
      return
    }
    coordinator.mlsEnabled = true

    let userDID = appState.userDID
    guard let mlsCoordinator = await appState.getOrOpenMLSCoordinator() else {
      var idleState = coordinator.mlsState
      idleState.isLoading = false
      coordinator.mlsState = idleState
      return
    }

    do {
      let rows = try await mlsCoordinator.listConversations(limit: 100)
      let defaults = UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier) ?? .standard
      let deletedForMe = MLSDeletedForMe(accountDID: userDID, defaults: defaults)

      let loadedConversations: [MLSConversationModel] = rows.compactMap { row in
        let muteKey = "mls.mutedUntil.\(userDID.lowercased()).\(row.conversationId)"
        let mutedSeconds = defaults.double(forKey: muteKey)
        let mutedUntil = mutedSeconds > 0 ? Date(timeIntervalSince1970: mutedSeconds) : nil
        let base = MLSConversationModel(row: row, currentUserDID: userDID)
        return MLSConversationModel(
          conversationID: base.conversationID,
          currentUserDID: base.currentUserDID,
          groupID: base.groupID,
          epoch: base.epoch,
          generation: base.generation,
          sequencerDID: base.sequencerDID,
          spaceURI: base.spaceURI,
          joinMethod: base.joinMethod,
          joinEpoch: base.joinEpoch,
          title: base.title,
          description: base.description,
          createdAt: base.createdAt,
          updatedAt: base.updatedAt,
          lastMessageAt: base.lastMessageAt,
          unreadCount: base.unreadCount,
          mutedUntil: mutedUntil
        )
      }

      let identityRecords = loadedConversations.map {
        MLSConversationIdentityBoundary.Record(
          conversationID: $0.conversationID,
          groupID: $0.groupID.hexEncodedString()
        )
      }
      guard let canonicalRecords = try? MLSConversationIdentityBoundary.canonicalize(identityRecords) else {
        logger.warning("Refusing live MLS conversations with ambiguous identity rows")
        return
      }
      let canonicalIDs = Set(canonicalRecords.map(\.conversationID))

      for conversation in loadedConversations {
        if !canonicalIDs.contains(conversation.conversationID) {
          let reason = !MLSConversationIdentityBoundary.isCanonicalStableID(conversation.conversationID)
            ? "non-canonical conversation ID"
            : "unresolved or ambiguous identity mapping"
          logger.warning("Excluding non-canonical MLS conversation row from live list: conversationID=\(conversation.conversationID, privacy: .public), groupID=\(conversation.groupID.hexEncodedString(), privacy: .public), reason=\(reason, privacy: .public)")
        }
      }

      guard appState.userDID == userDID else { return }
      let acceptedConversations = loadedConversations.filter {
        canonicalIDs.contains($0.conversationID)
      }

      var canonicalMembersByConvoID: [String: [MLSMemberModel]] = [:]
      var unreadCounts: [String: Int] = [:]
      var canonicalLastMessages: [String: MLSLastMessagePreview] = [:]
      var canonicalLatestActivity: [String: Date] = [:]
      var deletedForMeIDs = Set<String>()

      for conversation in acceptedConversations {
        let convoID = conversation.conversationID
        let messageRows = (try? await mlsCoordinator.listMessages(conversationId: convoID, limit: 20)) ?? []
        let recentMessages = messageRows.map { MLSMessageModel(row: $0, currentUserDID: userDID) }

        // A chat deleted for this account stays out of the list until someone writes in it again.
        let latestWrittenAt = recentMessages.lazy
          .filter { MLSDeletedForMe.bringsChatBack($0.parsedPayload()) }
          .map(\.timestamp)
          .max()
        if deletedForMe.isHidden(convoID, latestMessageAt: latestWrittenAt) {
          deletedForMeIDs.insert(convoID)
          continue
        }
        unreadCounts[convoID] = conversation.unreadCount

        if let newest = recentMessages.first {
          canonicalLatestActivity[convoID] = newest.timestamp
        }

        // The group's own members first, so a conversation the other person has not
        // written in yet still names them.
        let groupMembers = (try? await mlsCoordinator.listMembers(conversationId: convoID)) ?? []
        let memberDIDs = MLSConversationListMembers.memberDIDs(
          groupMembers: groupMembers,
          recentSenders: recentMessages.map(\.senderID)
        )
        canonicalMembersByConvoID[convoID] = memberDIDs.map { memberDID in
          MLSMemberModel(
            memberID: "\(convoID):\(memberDID)",
            conversationID: convoID,
            currentUserDID: userDID,
            did: memberDID
          )
        }

        for message in recentMessages {
          guard let payload = message.parsedPayload() else { continue }
          switch payload.messageType {
          case .text, .system:
            if let plaintext = payload.text, !plaintext.isEmpty {
              canonicalLastMessages[convoID] = MLSLastMessagePreview(senderDID: message.senderID, text: plaintext)
            } else if case .some(.image(_)) = payload.embed {
              canonicalLastMessages[convoID] = MLSLastMessagePreview(
                senderDID: message.senderID,
                text: String(localized: "Sent a photo", comment: "Conversation list preview when the last message is a photo")
              )
            } else {
              continue
            }
          case .reaction:
            canonicalLastMessages[convoID] = MLSLastMessagePreview(
              senderDID: message.senderID,
              text: String(localized: "Reacted to a message", comment: "Conversation list preview when the last activity is an emoji reaction")
            )
          case .readReceipt, .typing, .adminRoster, .adminAction, .deliveryAck, .recoveryRequest,
               .edit, .unknown:
            continue
          }
          break
        }
      }

      let sortedConversations = acceptedConversations.filter {
        !deletedForMeIDs.contains($0.conversationID)
      }.sorted { lhs, rhs in
        let lhsDate = canonicalLatestActivity[lhs.conversationID] ?? lhs.createdAt
        let rhsDate = canonicalLatestActivity[rhs.conversationID] ?? rhs.createdAt
        return lhsDate > rhsDate
      }
      var seenConvoIDs = Set<String>()
      let dedupedConversations = sortedConversations.filter {
        canonicalIDs.contains($0.conversationID) && seenConvoIDs.insert($0.conversationID).inserted
      }

      guard coordinatorAccountDID == userDID else {
        logger.debug("Discarding MLS list load for stale account \(userDID)")
        return
      }

      var participants: [String: [MLSParticipantViewModel]] = [:]
      for (convoID, members) in canonicalMembersByConvoID {
        participants[convoID] = members.map { member in
          MLSParticipantViewModel(
            id: member.did,
            handle: member.handle ?? member.did.split(separator: ":").last.map(String.init) ?? member.did,
            displayName: member.displayName,
            avatarURL: nil
          )
        }
      }

      // Single state assignment to avoid flicker
      var newState = MLSConversationListState()
      newState.conversations = dedupedConversations
      newState.participants = participants
      newState.unreadCounts = unreadCounts
      newState.lastMessages = canonicalLastMessages
      newState.latestActivity = canonicalLatestActivity
      newState.isLoading = false
      coordinator.mlsState = newState

      // Background: enrich with network profiles
      Task {
        await enrichMLSParticipantsFromNetwork(membersByConvoID: canonicalMembersByConvoID, userDID: userDID)
      }
    } catch {
      logger.error("Failed to load MLS conversations: \(error)")
    }
  }

  private func enrichMLSParticipantsFromNetwork(membersByConvoID: [String: [MLSMemberModel]], userDID: String) async {
    guard coordinatorAccountDID == userDID else { return }

    var allDIDs = Set<String>()
    for (_, members) in membersByConvoID {
      for member in members { allDIDs.insert(member.did) }
    }

    guard let client = appState.atProtoClient else { return }
    let profilesByDID = await appState.mlsProfileEnricher.ensureProfiles(
      for: Array(allDIDs), using: client, currentUserDID: userDID
    )
    guard !profilesByDID.isEmpty else { return }
    guard coordinatorAccountDID == userDID else { return }

    var enrichedParticipants: [String: [MLSParticipantViewModel]] = [:]
    for (convoID, members) in membersByConvoID {
      enrichedParticipants[convoID] = members.map { member in
        let canonicalDID = MLSProfileEnricher.canonicalDID(member.did)
        let profile = profilesByDID[canonicalDID] ?? profilesByDID[member.did]
        return MLSParticipantViewModel(
          id: member.did,
          handle: profile?.handle ?? member.handle ?? member.did.split(separator: ":").last.map(String.init) ?? member.did,
          displayName: profile?.displayName ?? member.displayName,
          avatarURL: profile?.avatarURL
        )
      }
    }

    let existingParticipants = coordinator.mlsState.participants
    let changed = enrichedParticipants.contains { key, val in
      guard let existing = existingParticipants[key] else { return true }
      return existing != val
    }
    if changed {
      var updatedState = coordinator.mlsState
      updatedState.participants = enrichedParticipants
      coordinator.mlsState = updatedState
    }
  }

  // MARK: - MLS Eager Refresh

  @MainActor
  private func performEagerRefreshIfNeeded(reason: String) async {
    guard mlsChatEnabledForCurrentAccount else { return }

    let allConversations = coordinator.mlsState.conversations
    guard !allConversations.isEmpty else {
      logger.debug("Eager refresh (\(reason)): skipped — conversation cache empty")
      return
    }

    if let last = lastEagerRefreshAt, Date().timeIntervalSince(last) < eagerRefreshThrottle {
      logger.debug("Eager refresh (\(reason)): throttled (last fired \(Date().timeIntervalSince(last))s ago)")
      return
    }
    lastEagerRefreshAt = Date()

    await loadMLSConversations()
    appState.updateMLSUnreadCount()
  }

  // MARK: - MLS Polling & Actions

  private func startMLSPolling() {
    mlsPollingTask?.cancel()
    mlsPollingTask = Task {
      let bus = appState.stateInvalidationBus

      // Bridge bus events to AsyncStream
      let stream = AsyncStream<Void> { continuation in
        let observer = MLSListChangeObserver(continuation: continuation)
        bus.subscribe(observer)
        continuation.onTermination = { _ in
          bus.unsubscribe(observer)
        }
      }

      // Run event-driven refresh and slow fallback poll concurrently
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          for await _ in stream {
            guard !Task.isCancelled else { break }
            await self.loadMLSConversations()
          }
        }
        group.addTask {
          while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { break }
            await self.loadMLSConversations()
          }
        }
      }
    }
  }

  private func stopMLSPolling() {
    mlsPollingTask?.cancel()
    mlsPollingTask = nil
  }

  private func deleteMLSConversationForMe(_ conversation: MLSConversationModel, targetDID: String) {
    let convoID = conversation.conversationID
    guard appState.userDID == targetDID else {
      logger.warning("Account switched before deleteMLSConversationForMe confirmed; dropping mutation")
      return
    }
    MLSDeletedForMe(accountDID: targetDID).hide(convoID)

    var updatedState = coordinator.mlsState
    updatedState.conversations.removeAll { $0.conversationID == convoID }
    updatedState.participants.removeValue(forKey: convoID)
    updatedState.unreadCounts.removeValue(forKey: convoID)
    updatedState.lastMessages.removeValue(forKey: convoID)
    updatedState.memberChanges.removeValue(forKey: convoID)
    coordinator.mlsState = updatedState
    if selectedConvoId == convoID { selectedConvoId = nil }

    NotificationCenter.default.post(
      name: Notification.Name("MLSConversationDeleted"),
      object: convoID,
      userInfo: ["userDID": targetDID]
    )
    appState.updateMLSUnreadCount()
  }

  private func leaveMLSConversation(_ conversation: MLSConversationModel) {
    let convoID = conversation.conversationID
    let expectedUserDID = appState.userDID
    Task {
      guard let mlsCoordinator = await appState.getOrOpenMLSCoordinator() else { return }
      do {
        _ = try await mlsCoordinator.leaveConversation(conversationId: convoID)
        await MainActor.run {
          guard appState.userDID == expectedUserDID else { return }
          var updatedState = coordinator.mlsState
          updatedState.conversations.removeAll { $0.conversationID == convoID }
          updatedState.participants.removeValue(forKey: convoID)
          updatedState.unreadCounts.removeValue(forKey: convoID)
          updatedState.lastMessages.removeValue(forKey: convoID)
          updatedState.memberChanges.removeValue(forKey: convoID)
          coordinator.mlsState = updatedState
          if selectedConvoId == convoID { selectedConvoId = nil }
        }
        if await MainActor.run(body: { appState.userDID == expectedUserDID }) {
          appState.updateMLSUnreadCount()
        }
      } catch {
        logger.error("Failed to leave MLS conversation: \(error.localizedDescription)")
      }
    }
  }

  private func toggleMLSMute(_ conversation: MLSConversationModel) {
    let convoID = conversation.conversationID
    let defaults = UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier) ?? .standard
    let muteKey = "mls.mutedUntil.\(appState.userDID.lowercased()).\(convoID)"
    if conversation.isMuted {
      defaults.removeObject(forKey: muteKey)
    } else {
      defaults.set(Date.distantFuture.timeIntervalSince1970, forKey: muteKey)
    }
    Task {
      await loadMLSConversations()
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
            if conversation.muted {
              Label("Unmute", systemImage: "bell")
            } else {
              Label("Mute", systemImage: "bell.slash")
            }
          }
          .tint(conversation.muted ? Color.accentColor : .orange)
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
