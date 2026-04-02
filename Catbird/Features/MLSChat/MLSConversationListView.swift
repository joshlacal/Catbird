import CatbirdMLSCore
import GRDB
import OSLog
import Petrel
import SwiftUI

#if os(iOS)

// MARK: - MLS Conversation List View

/// List view displaying end-to-end encrypted MLS conversations with encryption indicators
struct MLSConversationListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.composerTransitionNamespace) private var composerNamespace

    @Binding var selectedTab: Int
    
    // chatMode is now stored per-account via appState.chatMode

    @State private var searchText = ""
    @State private var selectedConvoId: String?
    @State private var showingNewConversation = false
    @State private var showingJoinConversation = false
    @State private var showingChatRequests = false
    @State private var showingSettings = false
    @State private var isLoadingConversations = false
    @State private var isInitializingMLS = false
    @State private var showingErrorAlert = false
    @State private var errorMessage: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var keyPackageStatus: KeyPackageStatus = .unknown
    @State private var conversations: [MLSConversationModel] = []
    @State private var conversationParticipants: [String: [MLSParticipantViewModel]] = [:]
    @State private var conversationUnreadCounts: [String: Int] = [:]
    @State private var conversationLastMessages: [String: (senderDID: String, text: String)] = [:]
    @State private var conversationLatestActivity: [String: Date] = [:]
    @State private var pollingTask: Task<Void, Never>?
    @State private var stateObserver: MLSStateObserver?
    @State private var observedConversationManager: MLSConversationManager?
    @State private var isListViewVisible = false
    @State private var recentMemberChanges: [String: MemberChangeInfo] = [:]
    @State private var pendingChatRequestCount: Int = 0
    @State private var pollCycleCount: Int = 0  // OOM FIX: Track poll cycles for periodic checkpoint
    @State private var conversationToLeave: MLSConversationModel?
    @State private var showingLeaveConfirmation = false
    @State private var isLeavingConversation = false
    
    // ACCOUNT SWITCH FIX: Track stale AppState after account switch
    @State private var initialUserDID: String?  // Capture which user this view was created for
    @State private var isAppStateStale = false  // True when AppState doesn't match active user

    private let logger = Logger(subsystem: "blue.catbird", category: "MLSConversationList")
    
    /// Polling interval for conversation list updates (15 seconds)
    private let pollingInterval: TimeInterval = 15
    
    /// OOM FIX: Checkpoint WAL every N poll cycles to prevent memory bloat
    private let checkpointEveryNPolls: Int = 10
    
    enum KeyPackageStatus {
        case unknown
        case checking
        case ready
        case publishing
        case error(String)
        
        var message: String {
            switch self {
            case .unknown: return "Initializing..."
            case .checking: return "Checking encryption keys..."
            case .ready: return "Ready for secure messaging"
            case .publishing: return "Publishing encryption keys..."
            case .error(let msg): return "Error: \(msg)"
            }
        }
        
        var icon: String {
            switch self {
            case .unknown, .checking, .publishing: return "ellipsis.circle"
            case .ready: return "checkmark.shield.fill"
            case .error: return "exclamationmark.triangle.fill"
            }
        }
        
        var color: Color {
            switch self {
            case .unknown, .checking, .publishing: return .blue
            case .ready: return .green
            case .error: return .red
            }
        }
        
        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    private struct ConversationListSnapshot {
        let conversations: [MLSConversationModel]
        let conversationParticipants: [String: [MLSParticipantViewModel]]
        let conversationUnreadCounts: [String: Int]
        let conversationLastMessages: [String: (senderDID: String, text: String)]
        let conversationLatestActivity: [String: Date]
        let recentMemberChanges: [String: MemberChangeInfo]
        let pendingChatRequestCount: Int
        let selectedConversationId: String?
        let keyPackageStatus: KeyPackageStatus
        let capturedAt: Date
    }

    @MainActor
    private static var snapshotCacheByUserDID: [String: ConversationListSnapshot] = [:]

    private let snapshotMaxAge: TimeInterval = 180
    
    // ACCOUNT SWITCH FIX: Check if this view's AppState is stale (account switched)
    // Only consider stale during explicit account transitions, NOT during ephemeral push notification access
    private var isViewStale: Bool {
        // If an explicit account switch is in progress and the lifecycle has a different user, view is stale
        guard AppStateManager.shared.isTransitioning else { return false }
        guard let activeDID = AppStateManager.shared.lifecycle.userDID else { return false }
        return appState.userDID != activeDID
    }
        
    private var shouldUseSplitView: Bool {
        DeviceInfo.isIPad || horizontalSizeClass == .regular
    }
    
    private var shouldShowChatFAB: Bool {
        // Only show when we're on the chat tab
        guard selectedTab == 4 else { return false }
        
        if DeviceInfo.isIPad {
            // Always show on iPad (split view) when on chat tab
            return true
        } else {
            // On iPhone: show only when the list is visible (no conversation selected)
            return selectedConvoId == nil
        }
    }
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.automatic)
        .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
        // Hide tab bar when viewing a conversation on iPhone
        #if !targetEnvironment(macCatalyst)
        .toolbar(selectedConvoId != nil && !shouldUseSplitView ? .hidden : .visible, for: .tabBar)
        #endif
        // On Catalyst, the FAB is shown in sidebarContent; on iOS show it here
        #if !targetEnvironment(macCatalyst)
        .overlay(alignment: .bottomTrailing) {
            if shouldShowChatFAB {
                ChatFAB(newMessageAction: {
                    showingNewConversation = true
                })
                .padding(.bottom, 20)
                .padding(.trailing, 20)
            }
        }
        #endif
        .onChange(of: selectedConvoId) { oldValue, newValue in
            // On iPhone, manage column visibility based on selection
            if !shouldUseSplitView {
                if newValue != nil {
                    columnVisibility = .detailOnly
                } else {
                    columnVisibility = .doubleColumn
                }
            }
            
            // Clear unread count for the selected conversation
            // The detail view will mark messages as read, but we update the list immediately for better UX
            if let convoId = newValue, conversationUnreadCounts[convoId, default: 0] > 0 {
                Task {
                    // Optimistically clear the count in the UI
                    await MainActor.run {
                        conversationUnreadCounts[convoId] = 0
                    }
                }
            }
        }
        .onChange(of: appState.navigationManager.targetMLSConversationId) { oldValue, newValue in
            // Handle deep-link navigation to a specific MLS conversation (e.g., from notification tap)
            if let convoId = newValue, convoId != selectedConvoId {
                logger.info("Deep-link navigation to MLS conversation: \(convoId.prefix(16))...")
                selectedConvoId = convoId
                // Clear the target after setting to avoid repeated navigation
                appState.navigationManager.targetMLSConversationId = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MLSConversationLeft"))) { _ in
            // Ensure the split view detail clears when leaving a conversation
            selectedConvoId = nil
        }
        .alert("Error", isPresented: $showingErrorAlert) {
            Button("OK", role: .cancel) {}

            // Show retry button if MLS service failed and retries available
            if case .failed = appState.mlsServiceState.status,
               appState.mlsServiceState.retryCount < appState.mlsServiceState.maxRetries {
                Button("Retry") {
                    Task {
                        await appState.retryMLSInitialization()
                        // Try to initialize again after retry
                        await initializeMLSAndLoadConversations()
                    }
                }
            }
        } message: {
            if let errorMessage = errorMessage {
                Text(errorMessage)
            }

            // Show retry status
            if case .retrying(let attempt) = appState.mlsServiceState.status {
                Text("\nRetrying... (attempt \(attempt) of \(appState.mlsServiceState.maxRetries))")
            }
        }
        .alert("Leave Conversation?", isPresented: $showingLeaveConfirmation) {
            Button("Cancel", role: .cancel) {
                conversationToLeave = nil
            }
            Button("Leave", role: .destructive) {
                if let conversation = conversationToLeave {
                    leaveConversation(conversation)
                }
                conversationToLeave = nil
            }
        } message: {
            Text("Are you sure you want to leave this conversation? You will no longer be able to send or receive messages.")
        }
        .sheet(isPresented: $showingNewConversation) {
            MLSNewConversationView(
                onConversationCreated: {
                    await refreshConversations()
                },
                onNavigateToConversation: { convoId in
                    appState.navigationManager.targetMLSConversationId = convoId
                }
            )
            .environment(appState)
            .applyAppStateEnvironment(appState)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingJoinConversation) {
            MLSJoinConversationView(onJoinSuccess: {
                await refreshConversations()
            })
            .environment(appState)
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showingChatRequests, onDismiss: {
            Task { await refreshChatRequestCount() }
        }) {
            MLSChatRequestsView(onAcceptedConversation: { convoId in
                await refreshConversations()
                selectedConvoId = convoId
            })
            .environment(appState)
            .applyAppStateEnvironment(appState)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .task {
            // ACCOUNT SWITCH FIX: Capture initial user and check for stale state
            if initialUserDID == nil {
                initialUserDID = appState.userDID
            }
            
            // Check if AppState is stale (account switched since view was created)
            if isViewStale {
                logger.warning("MLSConversationListView: AppState is stale (view has \(appState.userDID), active is \(AppStateManager.shared.lifecycle.userDID ?? "nil"))")
                isAppStateStale = true
                keyPackageStatus = .error("Account changed. Please go back and re-enter.")
                stopPolling()
                return
            }

            let restoredSnapshot = await MainActor.run {
                restoreCachedSnapshotIfAvailable()
            }

            await initializeMLSAndLoadConversations(showLoadingUI: !restoredSnapshot)
            await loadRecentMemberChanges()
            await refreshChatRequestCount()
            await MainActor.run {
                cacheCurrentSnapshot()
            }
            
            // NOTIFICATION FIX: Check if there's a pending deep-link conversation to navigate to
            // This handles the case where targetMLSConversationId was set before .task completed
            if let pendingConvoId = appState.navigationManager.targetMLSConversationId {
                logger.info("Found pending deep-link navigation to: \(pendingConvoId.prefix(16))...")
                selectedConvoId = pendingConvoId
                appState.navigationManager.targetMLSConversationId = nil
            }
        }
        .onAppear {
            isListViewVisible = true
            startPolling()
            Task { await startStateObservation() }
            
            // NOTIFICATION FIX: Also check for pending navigation on appear
            // This catches cases where the view is re-appearing with a pending target
            if let pendingConvoId = appState.navigationManager.targetMLSConversationId, selectedConvoId != pendingConvoId {
                logger.info("Found pending deep-link navigation on appear: \(pendingConvoId.prefix(16))...")
                selectedConvoId = pendingConvoId
                appState.navigationManager.targetMLSConversationId = nil
            }
        }
        .onDisappear {
            isListViewVisible = false
            cacheCurrentSnapshot()
            stopPolling()
            Task { await stopStateObservation() }
        }
    }
    
    // MARK: - Polling
    
    private func startPolling() {
        guard pollingTask == nil else { return }
        logger.debug("Starting conversation list polling (interval: \(pollingInterval)s)")
        
        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
                
                guard !Task.isCancelled else { break }
                
                // ACCOUNT SWITCH FIX: Stop polling if AppState is stale
                if isViewStale {
                    logger.warning("⛔ Polling stopped - AppState is stale (account switched)")
                    await MainActor.run {
                        isAppStateStale = true
                        keyPackageStatus = .error("Account changed. Please go back and re-enter.")
                    }
                    break
                }
                
                // CIRCUIT BREAKER: Stop polling if database is in failed state
                if appState.mlsServiceState.status.shouldStopPolling {
                    logger.warning("⛔ Polling paused - MLS service in failed state")
                    continue
                }
                
                // OOM FIX: Increment poll counter and checkpoint periodically
                pollCycleCount += 1
                if pollCycleCount % checkpointEveryNPolls == 0 {
                    logger.debug("🔄 Periodic WAL checkpoint (poll cycle \(pollCycleCount))")
                    do {
                        try await MLSGRDBManager.shared.checkpointDatabase(for: appState.userDID)
                    } catch {
                        logger.warning("⚠️ Periodic checkpoint failed: \(error.localizedDescription)")
                    }
                }

                await refreshChatRequestCount()
                
                // Only refresh if MLS is ready
                guard case .ready = keyPackageStatus else { continue }
                
                logger.debug("Polling: refreshing conversation list")
                await refreshConversations()
            }
        }
    }
    
    private func stopPolling() {
        logger.debug("Stopping conversation list polling")
        pollingTask?.cancel()
        pollingTask = nil
    }

    @MainActor
    private func startStateObservation() async {
        guard stateObserver == nil else { return }
        let observer = MLSStateObserver { event in
            Task { @MainActor in
                await self.handleMLSStateEvent(event)
            }
        }

        stateObserver = observer
        guard let manager = await appState.getMLSConversationManager(timeout: 10.0) else {
            if stateObserver?.id == observer.id {
                stateObserver = nil
            }
            logger.debug("Skipping list state observation: conversation manager unavailable")
            return
        }

        guard isListViewVisible, stateObserver?.id == observer.id else {
            logger.debug("Skipping late list state observer registration after view disappearance")
            if stateObserver?.id == observer.id {
                stateObserver = nil
            }
            return
        }

        observedConversationManager = manager
        manager.addObserver(observer)
        logger.debug("Registered MLS state observer for conversation list")
    }

    @MainActor
    private func stopStateObservation() async {
        guard let observer = stateObserver else { return }

        if let manager = observedConversationManager {
            manager.removeObserver(observer)
        }

        stateObserver = nil
        observedConversationManager = nil
        logger.debug("Removed MLS state observer for conversation list")
    }

    @MainActor
    private func handleMLSStateEvent(_ event: MLSStateEvent) async {
        guard !isAppStateStale else { return }

        switch event {
        case .syncCompleted:
            await loadMLSConversations()
        default:
            break
        }
    }
    
    // MARK: - Initialization
    
    private func initializeMLSAndLoadConversations(showLoadingUI: Bool = true) async {
        // ACCOUNT SWITCH FIX: Early exit if view is stale
        if isViewStale {
            logger.warning("initializeMLSAndLoadConversations: Aborting - AppState is stale")
            await MainActor.run {
                isAppStateStale = true
                keyPackageStatus = .error("Account changed. Please go back and re-enter.")
                isInitializingMLS = false
            }
            stopPolling()
            return
        }
        
        await MainActor.run {
            if showLoadingUI {
                isInitializingMLS = true
            }
            if !keyPackageStatus.isReady {
                keyPackageStatus = .checking
            }
        }

        // CRITICAL FIX: Add timeout and proper error handling for account switching scenarios
        // Check if MLS is already initialized
        guard let manager = await appState.getMLSConversationManager(timeout: 15.0) else {
            // Manager not available - check why and update UI accordingly
            await MainActor.run {
                isInitializingMLS = false
                
                // ACCOUNT SWITCH FIX: Check for stale state first
                if isViewStale {
                    isAppStateStale = true
                    keyPackageStatus = .error("Account changed. Please go back and re-enter.")
                    return
                }
                
                // Check the service state for specific error messages
                switch appState.mlsServiceState.status {
                case .failed(let message):
                    keyPackageStatus = .error(message)
                    errorMessage = message
                case .databaseFailed(let message):
                    keyPackageStatus = .error(message)
                    errorMessage = message
                case .initializing:
                    // Still initializing - leave in checking state but don't show as error
                    keyPackageStatus = .checking
                default:
                    keyPackageStatus = .error("MLS service unavailable. Please try again.")
                    errorMessage = "MLS service unavailable. This may happen during account switching. Please wait a moment and try again."
                }
            }
            return
        }
        
        if manager.isInitialized {
            await MainActor.run {
                keyPackageStatus = .ready
            }

            // Load from local database first so the list paints immediately.
            await loadMLSConversations()
            await MainActor.run {
                isInitializingMLS = false
                cacheCurrentSnapshot()
            }

            // Refresh from server in background to avoid blocking UI on navigation.
            Task {
                await syncWithServerAndReloadConversations()
            }
            return
        }

        // Initialize MLS and publish key package
        do {
            await MainActor.run {
                keyPackageStatus = .publishing
            }
            // AppState handles initialization and key package publishing
            try await appState.initializeMLS()

            // Sync conversations after initialization
            if let manager = await appState.getMLSConversationManager(timeout: 10.0) {
                try? await manager.syncWithServer()
            }

            await MainActor.run {
                keyPackageStatus = .ready
            }
            await loadMLSConversations()
            await MainActor.run {
                cacheCurrentSnapshot()
            }
        } catch {
            logger.error("Failed to initialize MLS: \(error.localizedDescription)")
            await MainActor.run {
                keyPackageStatus = .error(error.localizedDescription)
            }
        }

        await MainActor.run {
            isInitializingMLS = false
        }
    }

    private func syncWithServerAndReloadConversations() async {
        if let manager = await appState.getMLSConversationManager(timeout: 10.0) {
            do {
                try await manager.syncWithServer()
                logger.info("Synced conversations from server")
            } catch {
                logger.error("Failed to sync conversations: \(error.localizedDescription)")
            }
        }

        await loadMLSConversations()
        await MainActor.run {
            cacheCurrentSnapshot()
        }
    }
    
    // MARK: - Sidebar Content
    
    @ViewBuilder
    private var sidebarContent: some View {
        VStack(spacing: 0) {
            // ACCOUNT SWITCH FIX: Show prominent stale state message
            if isAppStateStale {
                VStack(spacing: DesignTokens.Spacing.base) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    Text("Account Changed")
                        .font(.headline)
                    Text("The active account has changed. Please return to the chat list to continue.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
            } else {
                // Key package status banner
                if case .ready = keyPackageStatus {
                    // Don't show banner when ready
                } else {
                    keyPackageStatusBanner
                }
                
                ZStack {
                    conversationListContent
                        .searchable(text: $searchText, prompt: "Search E2EE chats")

                    if isInitializingMLS || (isLoadingConversations && filteredConversations.isEmpty) {
                        VStack(spacing: DesignTokens.Spacing.base) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text(loadingOverlayMessage)
                                .designCallout()
                                .foregroundColor(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("mls.convoList.loadingOverlay")
                    }

                    if shouldShowEmptyStateOverlay {
                        if conversations.isEmpty {
                            emptyStateView
                        } else {
                        noSearchResultsView
                    }
                }

                // Show retry status overlay
                if case .retrying(let attempt) = appState.mlsServiceState.status {
                    VStack(spacing: DesignTokens.Spacing.base) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Retrying... (attempt \(attempt) of \(appState.mlsServiceState.maxRetries))")
                            .designCallout()
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(DesignTokens.Size.radiusLG)
                }

                // Show failure with retry button
                if case .failed(let message) = appState.mlsServiceState.status,
                   appState.mlsServiceState.retryCount < appState.mlsServiceState.maxRetries,
                   filteredConversations.isEmpty {
                    VStack(spacing: DesignTokens.Spacing.base) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)

                        Text("MLS Service Error")
                            .designTitle2()
                            .foregroundColor(.primary)

                        Text(message)
                            .designBody()
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        Button {
                            Task {
                                await appState.retryMLSInitialization()
                                await initializeMLSAndLoadConversations()
                            }
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, DesignTokens.Spacing.base)
                    }
                    .padding()
                }
            }
            } // Close else block for isAppStateStale check
        }
        .navigationTitle("Messages")
        #if os(iOS)
        .toolbarTitleDisplayMode(.large)
        #endif
        .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 400)
        .themedNavigationBar(appState.themeManager)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                MLSChatRequestsButton(pendingCount: pendingChatRequestCount) {
                    showingChatRequests = true
                }
            }
//            ToolbarItem(placement: .primaryAction) {
//                Menu {
//                    Button {
//                        showingJoinConversation = true
//                    } label: {
//                        Label("Join via ID", systemImage: "link")
//                    }
//                } label: {
//                    Image(systemName: "ellipsis.circle")
//                        .accessibilityLabel("More options")
//                }
//                .disabled(!keyPackageStatus.isReady)
//            }
// Disable for now, have to figure out ID joining
            
            
              ToolbarItem(placement: .primaryAction) {
                ChatToolbarMenu()
              }
              ToolbarItem(placement: .primaryAction) {
                SettingsAvatarToolbarButton {
                  showingSettings = true
                }
              }

        }
        .sheet(isPresented: $showingSettings) {
          SettingsView()
            .applyAppStateEnvironment(appState)
            .environment(appState)
        }

        .refreshable {
            // Sync from server first, then reload from database
            if let manager = await appState.getMLSConversationManager(timeout: 10.0) {
                try? await manager.syncWithServer()
            }
            await loadMLSConversations()
            await refreshChatRequestCount()
        }
        // On Catalyst, the NSToolbar compose button replaces the ChatFAB
    }
    
    @ViewBuilder
    private var keyPackageStatusBanner: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            switch keyPackageStatus {
            case .checking, .publishing:
                ProgressView()
                    .scaleEffect(0.8)
            default:
                Image(systemName: keyPackageStatus.icon)
                    .foregroundColor(keyPackageStatus.color)
            }

            Text(keyPackageStatus.message)
                .designCaption()
                .foregroundColor(.secondary)

            Spacer()

            if case .error = keyPackageStatus {
                Button("Retry") {
                    Task {
                        await initializeMLSAndLoadConversations()
                    }
                }
                .designCaption()
                .buttonStyle(.bordered)
            } else if case .ready = keyPackageStatus {
                Menu {
                    Button {
                        Task {
                            await uploadKeyPackages()
                        }
                    } label: {
                        Label("Upload Key Packages", systemImage: "arrow.up.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(keyPackageStatus.color.opacity(0.1))
    }

    private func uploadKeyPackages() async {
        keyPackageStatus = .publishing

        do {
            guard let manager = await appState.getMLSConversationManager(timeout: 10.0) else {
                throw MLSInitializationError.noConversationManager
            }

            try await manager.smartRefreshKeyPackages()
            keyPackageStatus = .ready
            logger.info("✅ Manually uploaded key packages successfully")
        } catch {
            logger.error("❌ Failed to upload key packages: \(error.localizedDescription)")
            keyPackageStatus = .error(error.localizedDescription)
        }
    }
    
    // MARK: - Detail Content

    private var chatNavigationPath: Binding<NavigationPath> {
        appState.navigationManager.pathBinding(for: 4)
    }
    
    @ViewBuilder
    private var detailContent: some View {
        NavigationStack(path: chatNavigationPath) {
            if let convoId = selectedConvoId {
                MLSConversationDetailView(conversationId: convoId)
                    .id(convoId)
            } else {
                emptyDetailView
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
    
    @ViewBuilder
    private var emptyDetailView: some View {
        ContentUnavailableView {
            Label("No Conversation Selected", systemImage: "lock.shield")
        } description: {
            Text("Select a conversation to view encrypted messages")
                .foregroundColor(.secondary)
        }
        .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
    }
    
    // MARK: - Conversation List Content
    
    @ViewBuilder
    private var conversationListContent: some View {
        List(selection: $selectedConvoId) {
            // Chat mode picker as first list item (matching ChatTabView/NotificationsView)
            chatModePicker
                .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
            
            ForEach(filteredConversations) { conversation in
                MLSConversationRowView(
                    conversation: conversation,
                    participants: conversationParticipants[conversation.conversationID] ?? [],
                    recentMemberChange: recentMemberChanges[conversation.conversationID],
                    unreadCount: conversationUnreadCounts[conversation.conversationID] ?? 0,
                    lastMessage: conversationLastMessages[conversation.conversationID].map {
                        MLSLastMessagePreview(senderDID: $0.senderDID, text: $0.text)
                    }
                )
                    .tag(conversation.conversationID)
                    .accessibilityIdentifier("mls.convoRow.\(accessibilitySafeIdPrefix(conversation.conversationID))")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            conversationToLeave = conversation
                            showingLeaveConfirmation = true
                        } label: {
                            Label("Leave", systemImage: "trash")
                        }

                        Button {
                            toggleMute(conversation)
                        } label: {
                            Label(conversation.isMuted ? "Unmute" : "Mute",
                                  systemImage: conversation.isMuted ? "bell" : "bell.slash")
                        }
                        .tint(conversation.isMuted ? .blue : .orange)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if unreadCountForConversation(conversation) > 0 {
                            Button {
                                toggleReadStatus(conversation)
                            } label: {
                                Label("Mark Read", systemImage: "envelope.open")
                            }
                            .tint(.blue)
                        }
                    }
            }

            // Spacer so the FAB doesn't cover the last row
            Spacer()
                .frame(height: 80)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
        .accessibilityIdentifier("mls.conversationList")
    }
    
    // MARK: - Chat Mode Picker
    
    @ViewBuilder
    private var chatModePicker: some View {
        Picker("Chat Mode", selection: Bindable(appState).chatMode) {
            ForEach(ChatTabView.ChatMode.allCases, id: \.self) { mode in
                Label(mode.rawValue, systemImage: mode.icon)
                    .tag(mode.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .frame(height: 36)
        .frame(maxWidth: horizontalSizeClass == .compact ? .infinity : 600)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }
    
    @ViewBuilder
    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Secure Conversations", systemImage: "lock.shield")
        } description: {
            VStack(spacing: DesignTokens.Spacing.sm) {
                Text("You haven't started any end-to-end encrypted chats yet.")
                    .designBody()
                    .multilineTextAlignment(.center)
                Text("Tap the compose button to start a secure conversation.")
                    .designCaption()
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .spacingBase()
        } actions: {
            VStack(spacing: 12) {
                Button {
                    showingNewConversation = true
                } label: {
                    Label("New Secure Chat", systemImage: "plus.message")
                }
                .buttonStyle(.borderedProminent)
                
//                Button {
//                    showingJoinConversation = true
//                } label: {
//                    Label("Join via ID", systemImage: "link")
//                }
//                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    @ViewBuilder
    private var noSearchResultsView: some View {
        ContentUnavailableView {
            Label("No Matches", systemImage: "magnifyingglass")
        } description: {
            Text("Try a different search.")
                .designBody()
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    // MARK: - Filtered Conversations

    private var filteredConversations: [MLSConversationModel] {
        let base: [MLSConversationModel]
        if searchText.isEmpty {
            base = conversations
        } else {
            base = conversations.filter { conversation in
                // Search by conversation title
                if let title = conversation.title, title.localizedCaseInsensitiveContains(searchText) {
                    return true
                }

                // Search by conversation ID (contains participant info in some cases)
                if conversation.conversationID.localizedCaseInsensitiveContains(searchText) {
                    return true
                }

                return false
            }
        }
        // Sort by actual latest message timestamp from messages table
        return base.sorted { lhs, rhs in
            let lhsDate = conversationLatestActivity[lhs.conversationID] ?? lhs.createdAt
            let rhsDate = conversationLatestActivity[rhs.conversationID] ?? rhs.createdAt
            return lhsDate > rhsDate
        }
    }

    private var shouldShowEmptyStateOverlay: Bool {
        guard filteredConversations.isEmpty else { return false }
        guard !isInitializingMLS && !isLoadingConversations else { return false }
        guard keyPackageStatus.isReady else { return false }

        switch appState.mlsServiceState.status {
        case .failed, .retrying, .databaseFailed:
            return false
        case .notStarted, .initializing, .ready:
            break
        }
        return true
    }
    
    private var loadingOverlayMessage: String {
        if isInitializingMLS {
            if case .ready = keyPackageStatus {
                return "Loading encrypted chats..."
            }
            return "Setting up encryption..."
        }
        return "Loading encrypted chats..."
    }

    private func accessibilitySafeIdPrefix(_ value: String, maxLength: Int = 12) -> String {
        let filtered = value.unicodeScalars.compactMap { scalar -> Character? in
            guard scalar.isASCII else { return nil }
            let v = scalar.value
            let isDigit = v >= 48 && v <= 57
            let isUpper = v >= 65 && v <= 90
            let isLower = v >= 97 && v <= 122
            return (isDigit || isUpper || isLower) ? Character(scalar) : nil
        }
        let prefix = String(filtered.prefix(maxLength))
        return prefix.isEmpty ? "unknown" : prefix
    }

    @MainActor
    private func restoreCachedSnapshotIfAvailable() -> Bool {
        guard let snapshot = Self.snapshotCacheByUserDID[appState.userDID] else {
            return false
        }

        if Date().timeIntervalSince(snapshot.capturedAt) > snapshotMaxAge {
            Self.snapshotCacheByUserDID[appState.userDID] = nil
            return false
        }

        conversations = snapshot.conversations
        conversationParticipants = snapshot.conversationParticipants
        conversationUnreadCounts = snapshot.conversationUnreadCounts
        conversationLastMessages = snapshot.conversationLastMessages
        conversationLatestActivity = snapshot.conversationLatestActivity
        recentMemberChanges = snapshot.recentMemberChanges
        pendingChatRequestCount = snapshot.pendingChatRequestCount
        keyPackageStatus = snapshot.keyPackageStatus

        if let cachedSelection = snapshot.selectedConversationId,
           snapshot.conversations.contains(where: { $0.conversationID == cachedSelection }) {
            selectedConvoId = cachedSelection
        }

        return true
    }

    @MainActor
    private func cacheCurrentSnapshot() {
        guard !isAppStateStale else { return }
        guard keyPackageStatus.isReady ||
                !conversations.isEmpty ||
                !conversationParticipants.isEmpty ||
                !conversationUnreadCounts.isEmpty ||
                pendingChatRequestCount > 0 else {
            return
        }

        Self.snapshotCacheByUserDID[appState.userDID] = ConversationListSnapshot(
            conversations: conversations,
            conversationParticipants: conversationParticipants,
            conversationUnreadCounts: conversationUnreadCounts,
            conversationLastMessages: conversationLastMessages,
            conversationLatestActivity: conversationLatestActivity,
            recentMemberChanges: recentMemberChanges,
            pendingChatRequestCount: pendingChatRequestCount,
            selectedConversationId: selectedConvoId,
            keyPackageStatus: keyPackageStatus,
            capturedAt: Date()
        )
    }
    
    // MARK: - Actions

    private func loadRecentMemberChanges() async {
        guard let manager = await appState.getMLSConversationManager(timeout: 5.0)
               else { return }
        let storage = manager.storage
        let database = manager.database
        
        do {
            let recentEvents = try await storage.fetchRecentMembershipChanges(
                currentUserDID: appState.userDID,
                database: database
            )

            // Group by conversation, take most recent per conversation
            var changes: [String: MemberChangeInfo] = [:]
            for event in recentEvents {
                if changes[event.conversationID] == nil {
                    changes[event.conversationID] = MemberChangeInfo.from(
                        event: event,
                        profiles: [:] // Profile enrichment not wired here
                    )
                }
            }

            await MainActor.run {
                recentMemberChanges = changes
                cacheCurrentSnapshot()
            }
        } catch {
            logger.error("Failed to load recent member changes: \(error)")
        }
    }

    private func loadMLSConversations() async {
        let shouldStartLoad = await MainActor.run { () -> Bool in
            guard !isLoadingConversations else { return false }
            isLoadingConversations = true
            return true
        }
        guard shouldStartLoad else { return }
        defer {
            Task { @MainActor in
                isLoadingConversations = false
            }
        }

        let userDID = appState.userDID

        do {
            // Use smart routing - auto-routes to lightweight Queue if needed
            let (loadedConversations, membersByConvoID) = try await MLSStorage.shared.fetchConversationsWithMembersUsingSmartRouting(
                currentUserDID: userDID
            )
            
            // Filter out pending chat requests - they should appear in the Requests view instead
            let acceptedConversations = loadedConversations.filter { $0.requestState != .pendingInbound }
            
            // Batch query for unread counts (single query for all conversations)
            let unreadCounts = try await MLSGRDBManager.shared.read(for: userDID) { db in
                try MLSStorageHelpers.getUnreadCountsForAllConversationsSync(
                    from: db,
                    currentUserDID: userDID
                )
            }

            // Fetch last message preview and latest activity timestamp per conversation
            // Single DB read for both preview text and sort timestamps
            let (lastMessages, latestActivityByConvo) = try await MLSGRDBManager.shared.read(for: userDID) { db -> ([String: (senderDID: String, text: String)], [String: Date]) in
                var previews: [String: (senderDID: String, text: String)] = [:]
                var latestActivity: [String: Date] = [:]
                for conversation in acceptedConversations {
                    let convoID = conversation.conversationID
                    let recentMessages = try MLSMessageModel
                        .filter(MLSMessageModel.Columns.conversationID == convoID)
                        .filter(MLSMessageModel.Columns.currentUserDID == userDID)
                        .order(MLSMessageModel.Columns.timestamp.desc)
                        .limit(20)
                        .fetchAll(db)

                    // The first message's timestamp is the latest activity for sorting
                    if let newest = recentMessages.first {
                        latestActivity[convoID] = newest.timestamp
                    }

                    for message in recentMessages {
                        // Skip placeholder error messages (failed decryptions, self-sent errors)
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
                                    previews[convoID] = (senderDID: message.senderID, text: plaintext)
                                } else if case .some(.image(_)) = payload.embed {
                                    previews[convoID] = (senderDID: message.senderID, text: "Sent a photo")
                                } else {
                                    continue
                                }
                            case .reaction:
                                previews[convoID] = (senderDID: message.senderID, text: "Reacted to a message")
                            case .readReceipt, .typing, .adminRoster, .adminAction:
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

            await MainActor.run {
                // Sort by actual latest message timestamp from the messages table,
                // falling back to conversation createdAt for empty conversations
                let sortedConversations = acceptedConversations.sorted { lhs, rhs in
                    let lhsDate = latestActivityByConvo[lhs.conversationID] ?? lhs.createdAt
                    let rhsDate = latestActivityByConvo[rhs.conversationID] ?? rhs.createdAt
                    return lhsDate > rhsDate
                }

                // Only update state if data actually changed to avoid SwiftUI flickering
                let convoIDs = sortedConversations.map(\.conversationID)
                let existingIDs = conversations.map(\.conversationID)
                let countsChanged = unreadCounts != conversationUnreadCounts
                let activityChanged = latestActivityByConvo != conversationLatestActivity
                let messagesChanged = lastMessages.keys != conversationLastMessages.keys
                    || lastMessages.contains { key, val in conversationLastMessages[key]?.text != val.text || conversationLastMessages[key]?.senderDID != val.senderDID }

                if convoIDs != existingIDs || countsChanged || messagesChanged || activityChanged {
                    conversations = sortedConversations
                    conversationUnreadCounts = unreadCounts
                    conversationLastMessages = lastMessages
                    conversationLatestActivity = latestActivityByConvo
                    cacheCurrentSnapshot()
                }

                if selectedConvoId != nil, !acceptedConversations.contains(where: { $0.conversationID == selectedConvoId }) {
                    selectedConvoId = nil
                }
            }
            logger.info("Loaded \(loadedConversations.count) conversations from encrypted database")

            // Load members and enrich with profiles (no additional DB queries needed)
            await loadConversationParticipants(membersByConvoID: membersByConvoID, userDID: userDID)

        } catch {
            logger.error("Failed to load conversations: \(error)")
        }
    }

    private func loadConversationParticipants(membersByConvoID: [String: [MLSMemberModel]], userDID: String) async {
        var allDIDs = Set<String>()

        // Collect DIDs for profile fetching (no DB queries - data already loaded)
        for (_, members) in membersByConvoID {
            for member in members {
                allDIDs.insert(member.did)
            }
        }

        // Seed enricher cache from DB-persisted profiles so they're available immediately
        var dbProfiles: [MLSProfileEnricher.ProfileData] = []
        for members in membersByConvoID.values {
            for member in members where member.handle != nil || member.displayName != nil {
                dbProfiles.append(MLSProfileEnricher.ProfileData(
                    did: member.did,
                    handle: member.handle ?? "",
                    displayName: member.displayName,
                    avatarURL: nil
                ))
            }
        }
        await appState.mlsProfileEnricher.seedFromDatabase(dbProfiles)

        // Show DB-cached profiles immediately while network fetch runs
        let dbProfilesByDID = Dictionary(
            dbProfiles.map { (MLSProfileEnricher.canonicalDID($0.did), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var updatedParticipants: [String: [MLSParticipantViewModel]] = [:]
        for (convoID, members) in membersByConvoID {
            let participants = members.map { member -> MLSParticipantViewModel in
                let canonicalDID = MLSProfileEnricher.canonicalDID(member.did)
                let profile = dbProfilesByDID[canonicalDID]
                return MLSParticipantViewModel(
                    id: member.did,
                    handle: profile?.handle ?? member.handle ?? member.did.split(separator: ":").last.map(String.init) ?? member.did,
                    displayName: profile?.displayName ?? member.displayName,
                    avatarURL: profile?.avatarURL
                )
            }
            updatedParticipants[convoID] = participants
        }
        await MainActor.run {
            conversationParticipants = updatedParticipants
            cacheCurrentSnapshot()
        }

        // Fetch fresh profiles from network and update
        var profilesByDID: [String: MLSProfileEnricher.ProfileData] = [:]
        if let client = appState.atProtoClient {
            profilesByDID = await appState.mlsProfileEnricher.ensureProfiles(
                for: Array(allDIDs),
                using: client,
                currentUserDID: userDID
            )
        }

        // Re-apply with network-fetched profiles (includes avatars)
        guard !profilesByDID.isEmpty else { return }
        var enrichedParticipants: [String: [MLSParticipantViewModel]] = [:]
        for (convoID, members) in membersByConvoID {
            let participants = members.map { member -> MLSParticipantViewModel in
                let canonicalDID = MLSProfileEnricher.canonicalDID(member.did)
                let profile = profilesByDID[canonicalDID] ?? profilesByDID[member.did]
                return MLSParticipantViewModel(
                    id: member.did,
                    handle: profile?.handle ?? member.handle ?? member.did.split(separator: ":").last.map(String.init) ?? member.did,
                    displayName: profile?.displayName ?? member.displayName,
                    avatarURL: profile?.avatarURL
                )
            }
            enrichedParticipants[convoID] = participants
        }

        await MainActor.run {
            conversationParticipants = enrichedParticipants
            cacheCurrentSnapshot()
        }
        logger.info("Loaded participants for \(membersByConvoID.count) conversations")
    }

    private func leaveConversation(_ conversation: MLSConversationModel) {
        let convoID = conversation.conversationID
        logger.info("Leaving conversation: \(convoID)")
        isLeavingConversation = true

        Task {
            do {
                guard let manager = await appState.getMLSConversationManager(timeout: 10.0) else {
                    await MainActor.run {
                        isLeavingConversation = false
                        errorMessage = "MLS service not available."
                        showingErrorAlert = true
                    }
                    return
                }

                try await manager.leaveConversation(convoId: convoID)

                await MainActor.run {
                    logger.info("Successfully left conversation: \(convoID)")
                    conversations.removeAll { $0.conversationID == convoID }
                    conversationParticipants.removeValue(forKey: convoID)
                    conversationUnreadCounts.removeValue(forKey: convoID)
                    conversationLastMessages.removeValue(forKey: convoID)
                    recentMemberChanges.removeValue(forKey: convoID)

                    if selectedConvoId == convoID {
                        selectedConvoId = nil
                    }

                    isLeavingConversation = false
                    cacheCurrentSnapshot()
                }

                // Update badge count
                await appState.updateMLSUnreadCount()

                // Notify detail view if it was showing this conversation
                NotificationCenter.default.post(
                    name: Notification.Name("MLSConversationLeft"),
                    object: convoID
                )
            } catch {
                logger.error("Failed to leave conversation: \(error.localizedDescription)")
                await MainActor.run {
                    isLeavingConversation = false
                    errorMessage = "Failed to leave conversation: \(error.localizedDescription)"
                    showingErrorAlert = true
                }
            }
        }
    }

    private func toggleMute(_ conversation: MLSConversationModel) {
        let convoID = conversation.conversationID
        let newMutedUntil: Date? = conversation.isMuted ? nil : .distantFuture

        Task {
            do {
                guard let manager = await appState.getMLSConversationManager(timeout: 10.0) else { return }

                try await manager.storage.setMutedUntil(
                    conversationID: convoID,
                    currentUserDID: appState.userDID,
                    mutedUntil: newMutedUntil,
                    database: manager.database
                )

                logger.info("\(conversation.isMuted ? "Unmuted" : "Muted") conversation: \(convoID)")
                await loadMLSConversations()
            } catch {
                logger.error("Failed to toggle mute: \(error.localizedDescription)")
            }
        }
    }

    private func toggleReadStatus(_ conversation: MLSConversationModel) {
        let convoID = conversation.conversationID
        let currentUnread = conversationUnreadCounts[convoID] ?? 0
        
        Task {
            do {
                if currentUnread > 0 {
                    // Mark all messages as read using smart routing
                    let (markedCount, latestCursor) = try await MLSGRDBManager.shared.write(for: appState.userDID) { db in
                        let latestMessage = try MLSMessageModel
                            .filter(MLSMessageModel.Columns.conversationID == convoID)
                            .filter(MLSMessageModel.Columns.currentUserDID == appState.userDID)
                            .order(MLSMessageModel.Columns.epoch.desc, MLSMessageModel.Columns.sequenceNumber.desc)
                            .limit(1)
                            .fetchOne(db)
                        
                        let markedCount = try MLSStorageHelpers.markAllMessagesAsReadSync(
                            in: db,
                            conversationID: convoID,
                            currentUserDID: appState.userDID
                        )
                        
                        if let latestMessage {
                            _ = try MLSStorageHelpers.upsertReadFrontierSync(
                                in: db,
                                conversationID: convoID,
                                currentUserDID: appState.userDID,
                                epoch: latestMessage.epoch,
                                sequenceNumber: latestMessage.sequenceNumber,
                                messageID: latestMessage.messageID
                            )
                        }
                        
                        return (
                            markedCount,
                            latestMessage.map { (epoch: $0.epoch, sequenceNumber: $0.sequenceNumber, messageID: $0.messageID) }
                        )
                    }
                    logger.info("Marked \(markedCount) messages as read in conversation \(convoID)")
                    
                    await MainActor.run {
                        conversationUnreadCounts[convoID] = 0
                        cacheCurrentSnapshot()
                    }
                    
                    // Update AppState's MLS unread count
                    await appState.updateMLSUnreadCount()
                    
                    // Notify server
                    if let apiClient = await appState.getMLSAPIClient() {
                        try? await apiClient.updateRead(convoId: convoID, messageId: nil)
                    }
                }
            } catch {
                logger.error("Failed to toggle read status: \(error.localizedDescription)")
            }
        }
    }
    
    private func unreadCountForConversation(_ conversation: MLSConversationModel) -> Int {
        conversationUnreadCounts[conversation.conversationID] ?? 0
    }

    private func refreshConversations() async {
        await syncWithServerAndReloadConversations()
    }

    @MainActor
    private func refreshChatRequestCount() async {
        // Use local pending request count instead of server-side count
        guard let manager = await appState.getMLSConversationManager() else { return }
        do {
            let pendingRequests = try await manager.fetchPendingRequestConversations()
            pendingChatRequestCount = pendingRequests.count
            cacheCurrentSnapshot()
        } catch {
            logger.debug("Failed to refresh chat request count: \(error.localizedDescription)")
        }
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var selectedTab = 4
    AsyncPreviewContent { appState in
        MLSConversationListView(selectedTab: $selectedTab)
    }
}

#endif
