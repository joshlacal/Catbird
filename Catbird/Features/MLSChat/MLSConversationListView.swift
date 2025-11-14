import SwiftUI
import Petrel
import OSLog
import GRDB

#if os(iOS)

// MARK: - MLS Conversation List View

/// List view displaying end-to-end encrypted MLS conversations with encryption indicators
struct MLSConversationListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var viewModel: MLSConversationListViewModel?
    @State private var searchText = ""
    @State private var selectedConvoId: String?
    @State private var showingNewConversation = false
    @State private var isLoadingConversations = false
    @State private var isInitializingMLS = false
    @State private var showingErrorAlert = false
    @State private var errorMessage: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var keyPackageStatus: KeyPackageStatus = .unknown
    @State private var conversations: [MLSConversationModel] = []
    @State private var conversationParticipants: [String: [MLSParticipantViewModel]] = [:]
    @State private var profileEnricher = MLSProfileEnricher()

    private let logger = Logger(subsystem: "blue.catbird", category: "MLSConversationList")
    
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
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.automatic)
        .onChange(of: selectedConvoId) { oldValue, newValue in
            // On iPhone, manage column visibility based on selection
            if !shouldUseSplitView {
                if newValue != nil {
                    columnVisibility = .detailOnly
                } else {
                    columnVisibility = .doubleColumn
                }
            }
        }
        .alert("Error", isPresented: $showingErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            if let errorMessage = errorMessage {
                Text(errorMessage)
            }
        }
        .sheet(isPresented: $showingNewConversation) {
            MLSNewConversationView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task {
            if viewModel == nil {
                guard let database = appState.mlsDatabase,
                      let apiClient = await appState.getMLSAPIClient() else {
                    logger.error("Cannot initialize view: mlsDatabase or apiClient not available")
                    errorMessage = "MLS service not available. Please restart the app."
                    showingErrorAlert = true
                    return
                }

                viewModel = MLSConversationListViewModel(
                    database: database,
                    apiClient: apiClient
                )
            }

            await initializeMLSAndLoadConversations()
        }
    }
    
    // MARK: - Initialization
    
    private func initializeMLSAndLoadConversations() async {
        isInitializingMLS = true
        keyPackageStatus = .checking

        // Check if MLS is already initialized
        if let manager = await appState.getMLSConversationManager(), manager.isInitialized {
            keyPackageStatus = .ready
            isInitializingMLS = false

            // Sync conversations from server first
            do {
                try await manager.syncWithServer()
                logger.info("Synced conversations from server")
            } catch {
                logger.error("Failed to sync conversations: \(error.localizedDescription)")
            }

            // Then load from local database
            await loadMLSConversations()
            return
        }

        // Initialize MLS and publish key package
        do {
            keyPackageStatus = .publishing
            // AppState handles initialization and key package publishing
            try await appState.initializeMLS()

            // Sync conversations after initialization
            if let manager = await appState.getMLSConversationManager() {
                try? await manager.syncWithServer()
            }

            keyPackageStatus = .ready
            await loadMLSConversations()
        } catch {
            logger.error("Failed to initialize MLS: \(error.localizedDescription)")
            keyPackageStatus = .error(error.localizedDescription)
        }

        isInitializingMLS = false
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
                        Text(isInitializingMLS ? "Setting up encryption..." : "Loading encrypted chats...")
                            .designCallout()
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Secure Messages")
        .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 400)
        .themedNavigationBar(appState.themeManager)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewConversation = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .accessibilityLabel("New secure conversation")
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
    
    @ViewBuilder
    private var detailContent: some View {
        if let convoId = selectedConvoId {
            MLSConversationDetailView(conversationId: convoId)
                .id(convoId)
        } else {
            emptyDetailView
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
        if filteredConversations.isEmpty && !isLoadingConversations {
            emptyStateView
        } else {
            List(selection: $selectedConvoId) {
                ForEach(filteredConversations) { conversation in
                    MLSConversationRowView(
                        conversation: conversation,
                        participants: conversationParticipants[conversation.conversationID] ?? []
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
                                Label("Mark Read", systemImage: "envelope.open")
                            }
                            .tint(.blue)
                        }
                }
            }
            .listStyle(.plain)
            .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
        }
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
            Button {
                showingNewConversation = true
            } label: {
                Label("New Secure Chat", systemImage: "plus.message")
            }
            .buttonStyle(.borderedProminent)
        }
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
    
    // MARK: - Actions

    private func loadMLSConversations() async {
        isLoadingConversations = true
        defer { isLoadingConversations = false }

        let userDID = appState.userDID

        do {
            let db = try await MLSGRDBManager.shared.getDatabaseQueue(for: userDID)

            // Load conversations
            conversations = try await db.read { db in
                try MLSConversationModel
                    .filter(MLSConversationModel.Columns.isActive == true)
                    .order(MLSConversationModel.Columns.lastMessageAt.desc)
                    .fetchAll(db)
            }
            logger.info("Loaded \(self.conversations.count) conversations from encrypted database")

            // Load members and enrich with profiles
            await loadConversationParticipants(db: db, userDID: userDID)

        } catch {
            logger.error("Failed to load conversations: \(error)")
            conversations = []
        }
    }

    private func loadConversationParticipants(db: DatabaseQueue, userDID: String) async {
        var allDIDs = Set<String>()
        var membersByConversation: [String: [MLSMemberModel]] = [:]

        // Fetch members for all conversations
        do {
            for conversation in conversations {
                let members = try await db.read { db in
                    try MLSMemberModel
                        .filter(MLSMemberModel.Columns.conversationID == conversation.conversationID)
                        .filter(MLSMemberModel.Columns.currentUserDID == userDID)
                        .filter(MLSMemberModel.Columns.isActive == true)
                        .order(MLSMemberModel.Columns.addedAt)
                        .fetchAll(db)
                }
                membersByConversation[conversation.conversationID] = members

                // Collect DIDs for profile fetching
                for member in members {
                    allDIDs.insert(member.did)
                }
            }

            // Fetch profiles from Bluesky
            var profilesByDID: [String: MLSProfileEnricher.ProfileData] = [:]
            if let client = appState.atProtoClient {
                profilesByDID = await fetchProfilesForDIDs(Array(allDIDs), client: client)
            }

            // Convert members to participants with enriched profile data
            for (convoID, members) in membersByConversation {
                let participants = members.map { member -> MLSParticipantViewModel in
                    let profile = profilesByDID[member.did]
                    return MLSParticipantViewModel(
                        id: member.did,
                        handle: profile?.handle ?? member.handle ?? member.did.split(separator: ":").last.map(String.init) ?? member.did,
                        displayName: profile?.displayName ?? member.displayName,
                        avatarURL: profile?.avatarURL
                    )
                }
                conversationParticipants[convoID] = participants
            }

            logger.info("Loaded participants for \(membersByConversation.count) conversations")

        } catch {
            logger.error("Failed to load conversation participants: \(error)")
        }
    }

    private func fetchProfilesForDIDs(_ dids: [String], client: ATProtoClient) async -> [String: MLSProfileEnricher.ProfileData] {
        var profilesByDID: [String: MLSProfileEnricher.ProfileData] = [:]

        // Batch fetch profiles in chunks of 25 (AT Protocol limit)
        let batchSize = 25
        let batches = stride(from: 0, to: dids.count, by: batchSize).map {
            Array(dids[$0..<min($0 + batchSize, dids.count)])
        }

        for batch in batches {
            do {
                let actors = try batch.map { try ATIdentifier(string: $0) }
                let params = AppBskyActorGetProfiles.Parameters(actors: actors)
                let (code, response) = try await client.app.bsky.actor.getProfiles(input: params)

                guard code >= 200 && code < 300, let profiles = response?.profiles else {
                    logger.warning("Profile fetch failed: HTTP \(code)")
                    continue
                }

                // Cache profiles
                for profile in profiles {
                    let profileData = MLSProfileEnricher.ProfileData(from: profile)
                    profilesByDID[profileData.did] = profileData
                }

            } catch {
                logger.error("Failed to fetch profile batch: \(error)")
            }
        }

        logger.info("Fetched \(profilesByDID.count) profiles from Bluesky")
        return profilesByDID
    }

    private func deleteConversation(_ conversation: MLSConversationModel) {
        // TODO: Implement conversation deletion via storage
        logger.info("Deleting conversation: \(conversation.conversationID)")
    }

    private func archiveConversation(_ conversation: MLSConversationModel) {
        // TODO: Implement conversation archival via storage
        logger.info("Archiving conversation: \(conversation.conversationID)")
    }

    private func toggleReadStatus(_ conversation: MLSConversationModel) {
        // TODO: Toggle read/unread status via storage
        logger.info("Toggling read status for conversation: \(conversation.conversationID)")
    }
}

// MARK: - MLS Conversation Row View

struct MLSConversationRowView: View {
    let conversation: MLSConversationModel
    let participants: [MLSParticipantViewModel]

    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

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
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    // E2EE indicator
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: DesignTokens.Size.iconSM))
                        .foregroundColor(.green)
                        .accessibilityLabel("End-to-end encrypted")

                    Spacer()

                    if let timestamp = conversation.lastMessageAt {
                        Text(formatTimestamp(timestamp))
                            .designCaption()
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    Text("Epoch \(conversation.epoch)")
                        .designFootnote()
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Spacer()
                }
            }
        }
        .spacingSM(.vertical)
        .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
    }

    private var conversationTitle: String {
        if let title = conversation.title, !title.isEmpty {
            return title
        }

        // TODO: Fetch member count from MLSMemberModel table when needed
        if let title = conversation.title {
            return title
        }

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

// MARK: - Preview

#Preview {
    @Previewable @Environment(AppState.self) var appState
    MLSConversationListView()
        .environment(AppStateManager.shared)
}

#endif
