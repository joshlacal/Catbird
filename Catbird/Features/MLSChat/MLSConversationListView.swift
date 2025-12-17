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
    @State private var profileEnricher = MLSProfileEnricher()
    @State private var pollingTask: Task<Void, Never>?
    @State private var recentMemberChanges: [String: MemberChangeInfo] = [:]
    @State private var pendingChatRequestCount: Int = 0
    @State private var pollCycleCount: Int = 0  // OOM FIX: Track poll cycles for periodic checkpoint

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
        .overlay(alignment: .bottomTrailing) {
            if shouldShowChatFAB {
                ChatFAB(newMessageAction: {
                    showingNewConversation = true
                })
                .padding(.bottom, 20)
                .padding(.trailing, 20)
            }
        }
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
            if viewModel == nil {
                guard let database = appState.mlsDatabase,
                      let apiClient = await appState.getMLSAPIClient() else {
                    logger.error("Cannot initialize view: mlsDatabase or apiClient not available")

                    // Check MLS service state and provide appropriate error message
                    switch appState.mlsServiceState.status {
                    case .databaseFailed(let message):
                        errorMessage = "Database error: \(message)"
                    case .failed(let message):
                        errorMessage = message
                    case .notStarted, .initializing:
                        errorMessage = "MLS service is still initializing. Please wait..."
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
        }
        .onAppear {
            startPolling()
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
        await MainActor.run {
            isInitializingMLS = true
            keyPackageStatus = .checking
        }

        // Check if MLS is already initialized
        if let manager = await appState.getMLSConversationManager(), manager.isInitialized {
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
            if let manager = await appState.getMLSConversationManager() {
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
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showingJoinConversation = true
                    } label: {
                        Label("Join via ID", systemImage: "link")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("More options")
                }
                .disabled(!keyPackageStatus.isReady)
            }
        }
        .refreshable {
            // Sync from server first, then reload from database
            if let manager = await appState.getMLSConversationManager() {
                try? await manager.syncWithServer()
            }
            await loadMLSConversations()
            await refreshChatRequestCount()
        }
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
            guard let manager = await appState.getMLSConversationManager() else {
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
                
                Button {
                    showingJoinConversation = true
                } label: {
                    Label("Join via ID", systemImage: "link")
                }
                .buttonStyle(.bordered)
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
    
    // MARK: - Actions

    private func loadRecentMemberChanges() async {
        guard let manager = await appState.getMLSConversationManager()
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
            let db = try await MLSGRDBManager.shared.getDatabasePool(for: userDID)

            // Single batch query for conversations AND members (eliminates N+1)
            let (loadedConversations, membersByConvoID) = try await MLSStorage.shared.fetchConversationsWithMembers(
                currentUserDID: userDID,
                database: db
            )
            
            // Batch query for unread counts (single query for all conversations)
            let unreadCounts = try await MLSStorageHelpers.getUnreadCountsForAllConversations(
                from: db,
                currentUserDID: userDID
            )

            await MainActor.run {
                // Sort conversations: unread first, then by lastMessageAt
                let sortedConversations = loadedConversations.sorted { lhs, rhs in
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

        // Fetch profiles from Bluesky (network call, not DB)
        var profilesByDID: [String: MLSProfileEnricher.ProfileData] = [:]
        if let client = appState.atProtoClient {
            profilesByDID = await fetchProfilesForDIDs(Array(allDIDs), client: client)
        }

        // Convert members to participants with enriched profile data
        var updatedParticipants: [String: [MLSParticipantViewModel]] = [:]
        for (convoID, members) in membersByConvoID {
            let participants = members.map { member -> MLSParticipantViewModel in
                let profile = profilesByDID[member.did]
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

    private func fetchProfilesForDIDs(_ dids: [String], client: ATProtoClient) async -> [String: MLSProfileEnricher.ProfileData] {
        let uniqueDIDs = Array(Set(dids))
        let canonicalByOriginal = Dictionary(uniqueKeysWithValues: uniqueDIDs.map { ($0, MLSProfileEnricher.canonicalDID($0)) })
        let canonicalDIDs = Array(Set(canonicalByOriginal.values))

        var profilesByCanonicalDID: [String: MLSProfileEnricher.ProfileData] = [:]

        // Batch fetch profiles in chunks of 25 (AT Protocol limit)
        let batchSize = 25
        let batches = stride(from: 0, to: canonicalDIDs.count, by: batchSize).map {
            Array(canonicalDIDs[$0..<min($0 + batchSize, canonicalDIDs.count)])
        }

        for batch in batches {
            let actors = batch.compactMap { try? ATIdentifier(string: $0) }
            guard !actors.isEmpty else { continue }

            do {
                let params = AppBskyActorGetProfiles.Parameters(actors: actors)
                let (code, response) = try await client.app.bsky.actor.getProfiles(input: params)

                guard code >= 200 && code < 300, let profiles = response?.profiles else {
                    logger.warning("Profile fetch failed: HTTP \(code)")
                    continue
                }

                for profile in profiles {
                    let profileData = MLSProfileEnricher.ProfileData(from: profile)
                    profilesByCanonicalDID[profileData.did] = profileData
                }

            } catch {
                logger.error("Failed to fetch profile batch: \(error)")
            }
        }

        var profilesByOriginalDID: [String: MLSProfileEnricher.ProfileData] = [:]
        for (original, canonical) in canonicalByOriginal {
            if let profile = profilesByCanonicalDID[canonical] {
                profilesByOriginalDID[original] = profile
            }
        }

        logger.info("Fetched \(profilesByOriginalDID.count) profiles from Bluesky")
        return profilesByOriginalDID
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
                let db = try await MLSGRDBManager.shared.getDatabasePool(for: appState.userDID)
                
                if currentUnread > 0 {
                    // Mark all messages as read
                    let markedCount = try await MLSStorageHelpers.markAllMessagesAsRead(
                        in: db,
                        conversationID: convoID,
                        currentUserDID: appState.userDID
                    )
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
        if let manager = await appState.getMLSConversationManager() {
            try? await manager.syncWithServer()
        }
        // Then reload from local database
        await loadMLSConversations()
    }

    @MainActor
    private func refreshChatRequestCount() async {
        do {
            guard let apiClient = await appState.getMLSAPIClient() else { return }
            let output = try await apiClient.getChatRequestCount()
            pendingChatRequestCount = output.pendingCount
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
