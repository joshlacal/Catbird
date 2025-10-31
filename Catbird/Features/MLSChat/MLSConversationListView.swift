import SwiftUI
import Petrel
import OSLog

#if os(iOS)

// MARK: - MLS Conversation List View

/// List view displaying end-to-end encrypted MLS conversations with encryption indicators
struct MLSConversationListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    @State private var searchText = ""
    @State private var selectedConvoId: String?
    @State private var showingNewConversation = false
    @State private var isLoadingConversations = false
    @State private var isInitializingMLS = false
    @State private var showingErrorAlert = false
    @State private var errorMessage: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var keyPackageStatus: KeyPackageStatus = .unknown
    
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
            await loadMLSConversations()
            return
        }
        
        // Initialize MLS and publish key package
        do {
            keyPackageStatus = .publishing
            // AppState handles initialization and key package publishing
            await appState.initializeMLS()
            
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
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(keyPackageStatus.color.opacity(0.1))
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
                ForEach(filteredConversations, id: \.id) { conversation in
                    MLSConversationRowView(conversation: conversation)
                        .tag(conversation.id)
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
                                Label(conversation.unreadCount > 0 ? "Mark Read" : "Mark Unread",
                                      systemImage: conversation.unreadCount > 0 ? "envelope.open" : "envelope.badge")
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
    
    private var filteredConversations: [MLSConversationViewModel] {
        let conversations = appState.mlsConversations
        
        if searchText.isEmpty {
            return conversations
        }
        
        return conversations.filter { conversation in
            // Search by conversation name or participant names
            if let name = conversation.name, name.localizedCaseInsensitiveContains(searchText) {
                return true
            }
            
            // Search by participant handles
            return conversation.participants.contains { participant in
                participant.handle.localizedCaseInsensitiveContains(searchText) ||
                (participant.displayName?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }
    }
    
    // MARK: - Actions
    
    private func loadMLSConversations() async {
        isLoadingConversations = true
        defer { isLoadingConversations = false }
        
        await appState.loadMLSConversations()
    }
    
    private func deleteConversation(_ conversation: MLSConversationViewModel) {
        // TODO: Implement conversation deletion
        logger.info("Deleting conversation: \(conversation.id)")
    }
    
    private func archiveConversation(_ conversation: MLSConversationViewModel) {
        // TODO: Implement conversation archival
        logger.info("Archiving conversation: \(conversation.id)")
    }
    
    private func toggleReadStatus(_ conversation: MLSConversationViewModel) {
        // TODO: Toggle read/unread status
        logger.info("Toggling read status for conversation: \(conversation.id)")
    }
}

// MARK: - MLS Conversation Row View

struct MLSConversationRowView: View {
    let conversation: MLSConversationViewModel
    
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        HStack(spacing: DesignTokens.Spacing.base) {
            // Avatar or group icon
            if conversation.isGroupChat {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.2))
                        .frame(width: DesignTokens.Size.avatarMD, height: DesignTokens.Size.avatarMD)
                    
                    Image(systemName: "person.3.fill")
                        .font(.system(size: DesignTokens.Size.iconMD))
                        .foregroundColor(.accentColor)
                }
            } else {
                // Single participant avatar
                AsyncProfileImage(
                    url: conversation.participants.first?.avatarURL,
                    size: DesignTokens.Size.avatarMD
                )
            }
            
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
                    
                    if let timestamp = conversation.lastMessageTimestamp {
                        Text(formatTimestamp(timestamp))
                            .designCaption()
                            .foregroundColor(.secondary)
                    }
                }
                
                HStack {
                    if let lastMessage = conversation.lastMessagePreview {
                        Text(lastMessage)
                            .designFootnote()
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("No messages yet")
                            .designFootnote()
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .designCaption()
                            .foregroundColor(.white)
                            .padding(.horizontal, DesignTokens.Spacing.sm)
                            .padding(.vertical, DesignTokens.Spacing.xs)
                            .background(Color.accentColor)
                            .cornerRadius(DesignTokens.Size.radiusXL)
                            .accessibilityLabel("\(conversation.unreadCount) unread messages")
                    }
                }
            }
        }
        .spacingSM(.vertical)
        .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
    }
    
    private var conversationTitle: String {
        if let name = conversation.name {
            return name
        }
        
        if conversation.isGroupChat {
            let names = conversation.participants.prefix(3).map { $0.displayName ?? $0.handle }
            if conversation.participants.count > 3 {
                return names.joined(separator: ", ") + "..."
            }
            return names.joined(separator: ", ")
        }
        
        return conversation.participants.first?.displayName ?? conversation.participants.first?.handle ?? "Unknown"
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

// MARK: - MLS Conversation Model

struct MLSConversationViewModel: Identifiable {
    let id: String
    let name: String?
    let participants: [MLSParticipantViewModel]
    let lastMessagePreview: String?
    let lastMessageTimestamp: Date?
    let unreadCount: Int
    let isGroupChat: Bool
    let groupId: String?
}

struct MLSParticipantViewModel: Identifiable {
    let id: String
    let handle: String
    let displayName: String?
    let avatarURL: URL?
}



// MARK: - Preview

#Preview {
    MLSConversationListView()
        .environment(AppState.shared)
}

#endif
