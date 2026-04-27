import CatbirdMLSCore
import GRDB
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

// MARK: - Chat Tab View

struct ChatTabView: View {
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
  @State private var showingNewMessageSheet = false
  @State private var showingSettings = false
  @State private var coordinator = UnifiedChatCoordinator()
  @State private var mlsPollingTask: Task<Void, Never>?
  @State private var mlsPollCycleCount: Int = 0
  fileprivate let logger = Logger(subsystem: "blue.catbird", category: "ChatUI")

  /// Per-account MLS chat enabled state
  private var mlsChatEnabledForCurrentAccount: Bool {
    ExperimentalSettings.shared.isMLSChatEnabled(for: appState.userDID)
  }

  /// Retained for external compatibility (ContentView, MLSConversationListView reference it).
  /// No longer drives view switching — the unified list shows both types together.
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

  // MARK: - Body

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
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
    .onDisappear(perform: handleOnDisappear)
    .onChange(of: selectedConvoId) { oldValue, newValue in
      handleConversationChange(oldValue: oldValue, newValue: newValue)
      if !shouldUseSplitView {
        columnVisibility = newValue != nil ? .detailOnly : .doubleColumn
      }
    }
    .onChange(of: appState.chatManager.acceptedConversations) { _, newValue in
      coordinator.blueskyConversations = newValue
    }
    .onChange(of: appState.navigationManager.targetConversationId) { _, newValue in
      if let convoId = newValue, convoId != selectedConvoId {
        selectedConvoId = convoId
        appState.navigationManager.targetConversationId = nil
      }
    }
    .onChange(of: appState.navigationManager.targetMLSConversationId) { _, newValue in
      if let convoId = newValue, convoId != selectedConvoId {
        selectedConvoId = convoId
        appState.navigationManager.targetMLSConversationId = nil
      }
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
        ForEach(coordinator.conversations) { item in
          unifiedRow(for: item)
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
    }
    .listStyle(.plain)
    .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
    .onChange(of: searchText) { _, newValue in
      appState.chatManager.searchLocal(searchTerm: newValue, currentUserDID: appState.userDID)
    }
    .refreshable {
      async let bsky: Void = appState.chatManager.loadConversations(refresh: true)
      async let mls: Void = loadMLSConversations()
      _ = await (bsky, mls)
    }
    .overlay {
      if coordinator.conversations.isEmpty && !appState.chatManager.loadingConversations {
        ContentUnavailableView {
          Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
        } description: {
          Text("You haven't started any chats yet.")
            .enhancedAppBody()
        }
      }
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

  // MARK: - Row Routing

  @ViewBuilder
  private func unifiedRow(for item: UnifiedConversation) -> some View {
    switch item {
    case .bluesky(let convo):
      ConversationRow(convo: convo, currentUserDID: appState.userDID)
        .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
        .modifier(ConditionalSwipeActions(conversation: convo, enabled: true))
        .contextMenu {
          ConversationContextMenu(conversation: convo)
        }
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
          leaveMLSConversation(convo)
        } label: {
          Label("Leave", systemImage: "trash")
        }
        Button {
          toggleMLSMute(convo)
        } label: {
          Label(convo.isMuted ? "Unmute" : "Mute",
                systemImage: convo.isMuted ? "bell" : "bell.slash")
        }
        .tint(convo.isMuted ? .blue : .orange)
      }
    }
  }

  // MARK: - Unified Detail

  @ViewBuilder
  private var unifiedDetailContent: some View {
    NavigationStack(path: chatNavigationPath) {
      if let convoId = selectedConvoId,
         let item = coordinator.conversations.first(where: { $0.id == convoId }) {
        switch item {
        case .bluesky:
          ConversationView(convoId: convoId)
            .id(convoId)
        case .mls:
          MLSConversationDetailView(conversationId: convoId)
            .id(convoId)
        }
      } else if let convoId = selectedConvoId {
        // Conversation selected but not yet in coordinator (e.g. deep-link before data loads)
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
            .contextMenu {
              ConversationContextMenu(conversation: convo)
            }
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

  // MARK: - Helper Properties

  private var shouldShowChatFAB: Bool {
    guard selectedTab == 4 else { return false }

    if DeviceInfo.isIPad {
      return true
    } else {
      return selectedConvoId == nil && chatNavigationPath.wrappedValue.isEmpty
    }
  }

  private var shouldShowPagination: Bool {
    !appState.chatManager.acceptedConversations.isEmpty &&
    appState.chatManager.conversationsCursor != nil &&
    !appState.chatManager.loadingConversations
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

  // MARK: - Event Handlers

  private func handleOnAppear() {
    // Bluesky DMs
    Task {
      if appState.chatManager.acceptedConversations.isEmpty && !appState.chatManager.loadingConversations {
        await appState.chatManager.loadConversations(refresh: true)
      }
    }
    appState.chatManager.startConversationsPolling()
    coordinator.blueskyConversations = appState.chatManager.acceptedConversations

    // MLS
    coordinator.mlsEnabled = mlsChatEnabledForCurrentAccount
    if mlsChatEnabledForCurrentAccount {
      Task { await loadMLSConversations() }
      startMLSPolling()

      // B8: kick off the full MLS init so the global WebSocket subscription
      // starts. Without this, `appState.initializeMLS()` only runs from
      // Settings or `MLSConversationListView`, so the global WS — which is
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
  }

  private func handleOnDisappear() {
    stopMLSPolling()
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

  // MARK: - MLS Data Loading

  @MainActor
  private func loadMLSConversations() async {
    guard mlsChatEnabledForCurrentAccount else {
      coordinator.mlsEnabled = false
      return
    }
    coordinator.mlsEnabled = true

    let userDID = appState.userDID

    do {
      let (loadedConversations, membersByConvoID) = try await MLSStorage.shared
        .fetchConversationsWithMembersUsingSmartRouting(currentUserDID: userDID)

      let acceptedConversations = loadedConversations.filter { $0.requestState != .pendingInbound }

      let unreadCounts = try await MLSGRDBManager.shared.read(for: userDID) { db in
        try MLSStorageHelpers.getUnreadCountsForAllConversationsSync(from: db, currentUserDID: userDID)
      }

      let (lastMessages, latestActivityByConvo) = try await MLSGRDBManager.shared.read(for: userDID) { db -> ([String: MLSLastMessagePreview], [String: Date]) in
        var previews: [String: MLSLastMessagePreview] = [:]
        var latestActivity: [String: Date] = [:]
        for conversation in acceptedConversations {
          let convoID = conversation.conversationID
          let recentMessages = try MLSMessageModel
            .filter(MLSMessageModel.Columns.conversationID == convoID)
            .filter(MLSMessageModel.Columns.currentUserDID == userDID)
            .order(MLSMessageModel.Columns.timestamp.desc)
            .limit(20)
            .fetchAll(db)

          if let newest = recentMessages.first {
            latestActivity[convoID] = newest.timestamp
          }

          for message in recentMessages {
            if message.processingError != nil {
              let text = message.parsedPayload?.text ?? ""
              if text.isEmpty || text.contains("Message unavailable")
                || text.contains("Decryption Failed") || text.contains("Self-sent message") {
                continue
              }
            }
            if let payload = message.parsedPayload {
              switch payload.messageType {
              case .text, .system, nil:
                if let plaintext = payload.text, !plaintext.isEmpty {
                  previews[convoID] = MLSLastMessagePreview(senderDID: message.senderID, text: plaintext)
                } else if case .some(.image(_)) = payload.embed {
                  previews[convoID] = MLSLastMessagePreview(senderDID: message.senderID, text: "Sent a photo")
                } else {
                  continue
                }
              case .reaction:
                previews[convoID] = MLSLastMessagePreview(senderDID: message.senderID, text: "Reacted to a message")
              case .readReceipt, .typing, .adminRoster, .adminAction, .deliveryAck, .recoveryRequest:
                continue
              }
            } else {
              continue
            }
            break
          }
        }
        return (previews, latestActivity)
      }

      let sortedConversations = acceptedConversations.sorted { lhs, rhs in
        let lhsDate = latestActivityByConvo[lhs.conversationID] ?? lhs.createdAt
        let rhsDate = latestActivityByConvo[rhs.conversationID] ?? rhs.createdAt
        return lhsDate > rhsDate
      }

      // Build participants from DB-cached profiles
      var participants: [String: [MLSParticipantViewModel]] = [:]
      var dbProfiles: [MLSProfileEnricher.ProfileData] = []
      for members in membersByConvoID.values {
        for member in members where member.handle != nil || member.displayName != nil {
          dbProfiles.append(MLSProfileEnricher.ProfileData(
            did: member.did, handle: member.handle ?? "",
            displayName: member.displayName, avatarURL: nil
          ))
        }
      }
      await appState.mlsProfileEnricher.seedFromDatabase(dbProfiles)

      let dbProfilesByDID = Dictionary(
        dbProfiles.map { (MLSProfileEnricher.canonicalDID($0.did), $0) },
        uniquingKeysWith: { first, _ in first }
      )
      for (convoID, members) in membersByConvoID {
        participants[convoID] = members.map { member in
          let canonicalDID = MLSProfileEnricher.canonicalDID(member.did)
          let profile = dbProfilesByDID[canonicalDID]
          return MLSParticipantViewModel(
            id: member.did,
            handle: profile?.handle ?? member.handle ?? member.did.split(separator: ":").last.map(String.init) ?? member.did,
            displayName: profile?.displayName ?? member.displayName,
            avatarURL: profile?.avatarURL
          )
        }
      }

      // Single state assignment to avoid flicker
      var newState = MLSConversationListState()
      newState.conversations = sortedConversations
      newState.participants = participants
      newState.unreadCounts = unreadCounts
      newState.lastMessages = lastMessages
      newState.latestActivity = latestActivityByConvo
      newState.isLoading = false
      coordinator.mlsState = newState

      // Background: enrich with network profiles
      Task {
        await enrichMLSParticipantsFromNetwork(membersByConvoID: membersByConvoID, userDID: userDID)
      }
    } catch {
      logger.error("Failed to load MLS conversations: \(error)")
    }
  }

  private func enrichMLSParticipantsFromNetwork(membersByConvoID: [String: [MLSMemberModel]], userDID: String) async {
    var allDIDs = Set<String>()
    for (_, members) in membersByConvoID {
      for member in members { allDIDs.insert(member.did) }
    }

    guard let client = appState.atProtoClient else { return }
    let profilesByDID = await appState.mlsProfileEnricher.ensureProfiles(
      for: Array(allDIDs), using: client, currentUserDID: userDID
    )
    guard !profilesByDID.isEmpty else { return }

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
        // Event-driven: reload on each WebSocket notification
        group.addTask {
          for await _ in stream {
            guard !Task.isCancelled else { break }
            await self.loadMLSConversations()
          }
        }
        // Fallback: slow poll every 120s for resilience
        group.addTask {
          var cycleCount = 0
          while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { break }
            await self.loadMLSConversations()
            cycleCount += 1
            if cycleCount % 5 == 0 {
              let userDID = self.appState.userDID
              Task.detached(priority: .utility) {
                try? await MLSGRDBManager.shared.checkpointDatabase(for: userDID)
              }
            }
          }
        }
      }
    }
  }

  private func stopMLSPolling() {
    mlsPollingTask?.cancel()
    mlsPollingTask = nil
  }

  private func leaveMLSConversation(_ conversation: MLSConversationModel) {
    let convoID = conversation.conversationID
    Task {
      guard let manager = await appState.getMLSConversationManager(timeout: 10.0) else { return }
      do {
        try await manager.leaveConversation(convoId: convoID)
        var updatedState = coordinator.mlsState
        updatedState.conversations.removeAll { $0.conversationID == convoID }
        updatedState.participants.removeValue(forKey: convoID)
        updatedState.unreadCounts.removeValue(forKey: convoID)
        updatedState.lastMessages.removeValue(forKey: convoID)
        updatedState.memberChanges.removeValue(forKey: convoID)
        coordinator.mlsState = updatedState
        if selectedConvoId == convoID { selectedConvoId = nil }
        await appState.updateMLSUnreadCount()
      } catch {
        logger.error("Failed to leave MLS conversation: \(error.localizedDescription)")
      }
    }
  }

  private func toggleMLSMute(_ conversation: MLSConversationModel) {
    let convoID = conversation.conversationID
    let newMutedUntil: Date? = conversation.isMuted ? nil : .distantFuture
    Task {
      guard let manager = await appState.getMLSConversationManager(timeout: 10.0) else { return }
      do {
        try await manager.storage.setMutedUntil(
          conversationID: convoID, currentUserDID: appState.userDID,
          mutedUntil: newMutedUntil, database: manager.database
        )
        await loadMLSConversations()
      } catch {
        logger.error("Failed to toggle MLS mute: \(error.localizedDescription)")
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

#if os(iOS)
#Preview("ChatTabView") {
  @Previewable @State var selectedTab = 3
  @Previewable @State var lastTappedTab: Int? = nil
  ChatTabView(selectedTab: $selectedTab, lastTappedTab: $lastTappedTab)
    .previewWithAuthenticatedState()
}
#endif
