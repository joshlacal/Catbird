import CatbirdMLSCore
import GRDB
import OSLog
import Petrel
import SwiftUI
import CatbirdMLSService

#if os(iOS)

// MARK: - MLS Conversation List View

/// List view displaying end-to-end encrypted MLS conversations with encryption indicators
struct MLSConversationListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.composerTransitionNamespace) private var composerNamespace

    @Binding var selectedTab: Int
    
    @AppStorage("chatMode") private var chatModeRaw: String = ChatTabView.ChatMode.bluesky.rawValue

    @State private var viewModel: MLSConversationListViewModel?
    @State private var searchText = ""
    @State private var selectedConvoId: String?
    @State private var showingNewConversation = false
    @State private var showingJoinConversation = false
    @State private var showingChatRequests = false
    @State private var isLoadingConversations = false
    @State private var isInitializingMLS = false
    @State private var showingErrorAlert = false
    @State private var errorMessage: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var keyPackageStatus: KeyPackageStatus = .unknown
    @State private var conversations: [MLSConversationModel] = []
    @State private var conversationParticipants: [String: [MLSParticipantViewModel]] = [:]
    @State private var conversationUnreadCounts: [String: Int] = [:]
    @State private var pollingTask: Task<Void, Never>?
    @State private var recentMemberChanges: [String: MemberChangeInfo] = [:]
    @State private var pendingChatRequestCount: Int = 0
    @State private var pollCycleCount: Int = 0  // OOM FIX: Track poll cycles for periodic checkpoint
    
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
        .toolbar(selectedConvoId != nil && !shouldUseSplitView ? .hidden : .visible, for: .tabBar)
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
        .sheet(isPresented: $showingNewConversation) {
            MLSNewConversationView(onConversationCreated: {
                await refreshConversations()
            })
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
            
            if viewModel == nil {
                // NOTIFICATION FIX: If MLS is still initializing, wait for it to become ready
                // instead of immediately showing an error. This handles account switching.
                let maxWaitTime: TimeInterval = 10.0
                let checkInterval: TimeInterval = 0.3
                var elapsed: TimeInterval = 0
                
                // Wait for database to become available if MLS is initializing
                // CRITICAL FIX: Use labeled loop so break exits the while loop, not just the switch
                waitLoop: while appState.mlsDatabase == nil && elapsed < maxWaitTime {
                    let status = appState.mlsServiceState.status
                    switch status {
                    case .notStarted, .initializing, .retrying:
                        logger.debug("MLS service status: \(String(describing: status)), waiting...")
                        try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
                        elapsed += checkInterval
                    case .ready:
                        // Ready but database ref might be updating, give it a moment
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        elapsed += 0.1
                    case .failed, .databaseFailed:
                        // Don't wait for a failed state - exit the loop immediately
                        break waitLoop
                    }
                    
                    // Also check for account switch during wait
                    if isViewStale {
                        logger.warning("Account changed while waiting for MLS")
                        isAppStateStale = true
                        keyPackageStatus = .error("Account changed. Please go back and re-enter.")
                        stopPolling()
                        return
                    }
                }
                
                guard let database = appState.mlsDatabase,
                      let apiClient = await appState.getMLSAPIClient() else {
                    logger.error("Cannot initialize view: mlsDatabase or apiClient not available after waiting")

                    // Check MLS service state and provide appropriate error message
                    switch appState.mlsServiceState.status {
                    case .databaseFailed(let message):
                        errorMessage = "Database error: \(message)"
                    case .failed(let message):
                        errorMessage = message
                    case .notStarted, .initializing:
                        // Still not ready after waiting - show a helpful message
                        errorMessage = "MLS service is still initializing. Please try again in a moment."
                    default:
                        errorMessage = "MLS service not available"
                    }

                    showingErrorAlert = true
                    return
                }

                viewModel = MLSConversationListViewModel(
                    database: database,
                    apiClient: apiClient
                )
            }

            await initializeMLSAndLoadConversations()
            await loadRecentMemberChanges()
            await refreshChatRequestCount()
            
            // NOTIFICATION FIX: Check if there's a pending deep-link conversation to navigate to
            // This handles the case where targetMLSConversationId was set before .task completed
            if let pendingConvoId = appState.navigationManager.targetMLSConversationId {
                logger.info("Found pending deep-link navigation to: \(pendingConvoId.prefix(16))...")
                selectedConvoId = pendingConvoId
                appState.navigationManager.targetMLSConversationId = nil
            }
        }
        .onAppear {
            startPolling()
            
            // NOTIFICATION FIX: Also check for pending navigation on appear
            // This catches cases where the view is re-appearing with a pending target
            if let pendingConvoId = appState.navigationManager.targetMLSConversationId, selectedConvoId != pendingConvoId {
                logger.info("Found pending deep-link navigation on appear: \(pendingConvoId.prefix(16))...")
                selectedConvoId = pendingConvoId
                appState.navigationManager.targetMLSConversationId = nil
            }
        }
        .onDisappear {
            stopPolling()
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
    
    // MARK: - Initialization
    
    private func initializeMLSAndLoadConversations() async {
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
            isInitializingMLS = true
            keyPackageStatus = .checking
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

            // Sync conversations from server first
            do {
                try await manager.syncWithServer()
                logger.info("Synced conversations from server")
            } catch {
                logger.error("Failed to sync conversations: \(error.localizedDescription)")
            }

            // Then load from local database
            await loadMLSConversations()
            await MainActor.run {
                isInitializingMLS = false
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
        }
        .refreshable {
            // Sync from server first, then reload from database
            if let manager = await appState.getMLSConversationManager(timeout: 10.0) {
                try? await manager.syncWithServer()
            }
            await loadMLSConversations()
            await refreshChatRequestCount()
        }
        // On Catalyst, show FAB in sidebar to keep it constrained to the sidebar column
        #if targetEnvironment(macCatalyst)
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
                    unreadCount: conversationUnreadCounts[conversation.conversationID] ?? 0
                )
                    .tag(conversation.conversationID)
                    .accessibilityIdentifier("mls.convoRow.\(accessibilitySafeIdPrefix(conversation.conversationID))")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteConversation(conversation)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            archiveConversation(conversation)
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            toggleReadStatus(conversation)
                        } label: {
                            Label(unreadCountForConversation(conversation) > 0 ? "Mark Read" : "Mark Unread", 
                                  systemImage: unreadCountForConversation(conversation) > 0 ? "envelope.open" : "envelope.badge")
                        }
                        .tint(.blue)
                    }
            }
        }
        .listStyle(.plain)
        .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
        .accessibilityIdentifier("mls.conversationList")
    }
    
    // MARK: - Chat Mode Picker
    
    @ViewBuilder
    private var chatModePicker: some View {
        Picker("Chat Mode", selection: $chatModeRaw) {
            ForEach(ChatTabView.ChatMode.allCases, id: \.self) { mode in
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
        if searchText.isEmpty {
            return conversations
        }
        
        return conversations.filter { conversation in
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
            let isAlphaNum = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
            return isAlphaNum ? Character(scalar) : nil
        }
        let prefix = String(filtered.prefix(maxLength))
        return prefix.isEmpty ? "unknown" : prefix
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

            await MainActor.run {
                // Sort conversations: unread first, then by lastMessageAt
                let sortedConversations = acceptedConversations.sorted { lhs, rhs in
                    let lhsUnread = unreadCounts[lhs.conversationID] ?? 0
                    let rhsUnread = unreadCounts[rhs.conversationID] ?? 0
                    
                    // Unread conversations come first
                    if lhsUnread > 0 && rhsUnread == 0 {
                        return true
                    }
                    if rhsUnread > 0 && lhsUnread == 0 {
                        return false
                    }
                    
                    // Both have unread or both don't - sort by lastMessageAt
                    let lhsDate = lhs.lastMessageAt ?? lhs.createdAt
                    let rhsDate = rhs.lastMessageAt ?? rhs.createdAt
                    return lhsDate > rhsDate
                }
                conversations = sortedConversations
                conversationUnreadCounts = unreadCounts
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

        // IMPROVEMENT: Use centralized MLSProfileEnricher so profiles are cached
        // This ensures profiles are already in cache when opening a conversation detail
        var profilesByDID: [String: MLSProfileEnricher.ProfileData] = [:]
        if let client = appState.atProtoClient {
            profilesByDID = await appState.mlsProfileEnricher.ensureProfiles(
                for: Array(allDIDs),
                using: client,
                currentUserDID: userDID
            )
        }

        // Convert members to participants with enriched profile data
        var updatedParticipants: [String: [MLSParticipantViewModel]] = [:]
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
            updatedParticipants[convoID] = participants
        }

        await MainActor.run {
            conversationParticipants = updatedParticipants
        }
        logger.info("Loaded participants for \(membersByConvoID.count) conversations")
    }

    private func deleteConversation(_ conversation: MLSConversationModel) {
        // Note: Conversation deletion in E2EE chat requires careful handling:
        // 1. Server-side: User must leave the conversation via API (leaveConversation)
        // 2. Local-only: Delete conversation record from GRDB
        // 3. Crypto: Clean up MLS group state from FFI storage
        // For now, users should use the "Leave Conversation" option which handles all three.
        logger.info("Deleting conversation: \(conversation.conversationID)")
    }

    private func archiveConversation(_ conversation: MLSConversationModel) {
        // Note: Archive requires adding an 'isArchived' column to MLSConversationModel
        // and updating MLSStorage to support archival queries.
        // Archived conversations would be hidden from main list but still decryptable.
        logger.info("Archiving conversation: \(conversation.conversationID)")
    }

    private func toggleReadStatus(_ conversation: MLSConversationModel) {
        let convoID = conversation.conversationID
        let currentUnread = conversationUnreadCounts[convoID] ?? 0
        
        Task {
            do {
                if currentUnread > 0 {
                    // Mark all messages as read using smart routing
                    let markedCount = try await MLSGRDBManager.shared.write(for: appState.userDID) { db in
                        try MLSStorageHelpers.markAllMessagesAsReadSync(
                            in: db,
                            conversationID: convoID,
                            currentUserDID: appState.userDID
                        )
                    }
                    logger.info("Marked \(markedCount) messages as read in conversation \(convoID)")
                    
                    await MainActor.run {
                        conversationUnreadCounts[convoID] = 0
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
        // Sync from server first
        if let manager = await appState.getMLSConversationManager(timeout: 10.0) {
            try? await manager.syncWithServer()
        }
        // Then reload from local database
        await loadMLSConversations()
    }

    @MainActor
    private func refreshChatRequestCount() async {
        // Use local pending request count instead of server-side count
        guard let manager = await appState.getMLSConversationManager() else { return }
        do {
            let pendingRequests = try await manager.fetchPendingRequestConversations()
            pendingChatRequestCount = pendingRequests.count
        } catch {
            logger.debug("Failed to refresh chat request count: \(error.localizedDescription)")
        }
    }
}

// MARK: - MLS Conversation Row View

struct MLSConversationRowView: View {
    let conversation: MLSConversationModel
    let participants: [MLSParticipantViewModel]
    let recentMemberChange: MemberChangeInfo?
    let unreadCount: Int

    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    
    private var hasUnread: Bool { unreadCount > 0 }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.base) {
            // Composite avatar for group chat
            MLSGroupAvatarView(
                participants: participants,
                size: DesignTokens.Size.avatarMD
            )

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(conversationTitle)
                        .designCallout()
                        .fontWeight(hasUnread ? .semibold : .regular)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    // E2EE indicator
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: DesignTokens.Size.iconSM))
                        .foregroundColor(.green)
                        .accessibilityLabel("End-to-end encrypted")

                    Spacer()
                    
                    // Unread count badge
                    if unreadCount > 0 {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 22, height: 22)
                            Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .accessibilityLabel("\(unreadCount) unread messages")
                    } else if conversation.unacknowledgedMemberChanges > 0 {
                        ZStack {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 20, height: 20)
                            Text("\(conversation.unacknowledgedMemberChanges)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .accessibilityLabel("\(conversation.unacknowledgedMemberChanges) member changes")
                    }

                    if let timestamp = conversation.lastMessageAt {
                        Text(formatTimestamp(timestamp))
                            .designCaption()
                            .foregroundColor(hasUnread ? .accentColor : .secondary)
                            .fontWeight(hasUnread ? .medium : .regular)
                    }
                }

                HStack {
                    if let change = recentMemberChange {
                        HStack(spacing: 4) {
                            Image(systemName: change.icon)
                                .font(.system(size: 12))
                                .foregroundColor(change.color)

                            Text(change.text)
                                .designFootnote()
                                .foregroundColor(change.color)
                        }
                        .lineLimit(1)
                    } else {
                        Text("Epoch \(conversation.epoch)")
                            .designFootnote()
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    HStack(spacing: 2) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text("\(participants.count)")
                            .designFootnote()
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .spacingSM(.vertical)
        .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
    }

    private var conversationTitle: String {
        // Use conversation title if set
        if let title = conversation.title, !title.isEmpty {
            return title
        }

        // Fallback title for untitled conversations
        return "Secure Chat"
    }

    private func formatTimestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if calendar.dateComponents([.day], from: date, to: Date()).day! < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        } else {
            return date.formatted(date: .numeric, time: .omitted)
        }
    }
}

// MARK: - Supporting Models

struct MemberChangeInfo {
  let text: String
  let icon: String
  let color: Color

  static func from(
    event: MLSMembershipEventModel,
    profiles: [String: MLSProfileEnricher.ProfileData]
  ) -> MemberChangeInfo {
    let name = profiles[event.memberDID]?.displayName ??
               profiles[event.memberDID]?.handle ??
               "Someone"

    switch event.eventType {
    case .joined:
      return MemberChangeInfo(
        text: "\(name) joined",
        icon: "person.badge.plus",
        color: .green
      )
    case .left, .removed, .kicked:
      return MemberChangeInfo(
        text: "\(name) left",
        icon: "person.badge.minus",
        color: .orange
      )
    case .roleChanged:
      return MemberChangeInfo(
        text: "\(name) role changed",
        icon: "star.circle",
        color: .purple
      )
    case .deviceAdded:
      return MemberChangeInfo(
        text: "\(name) added device",
        icon: "laptopcomputer.and.iphone",
        color: .blue
      )
    case .deviceRemoved:
      return MemberChangeInfo(
        text: "\(name) removed device",
        icon: "iphone.slash",
        color: .orange
      )
    }
  }
}

// MARK: - Preview

#Preview {
    @Previewable @State var selectedTab = 4
    @Previewable @Environment(AppState.self) var appState
    MLSConversationListView(selectedTab: $selectedTab)
        .environment(AppStateManager.shared)
}

#endif
