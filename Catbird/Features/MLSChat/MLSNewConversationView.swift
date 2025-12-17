import SwiftUI
import Petrel
import OSLog

#if os(iOS)

// MARK: - MLS New Conversation View (Redesigned)

/// Modern interface to create a new end-to-end encrypted group conversation
struct MLSNewConversationView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var conversationName = ""
    @State private var searchText = ""
    @State private var selectedParticipants: Set<String> = []
    @State private var selectionOrder: [String] = []
    @State private var selectedParticipantDetails: [String: MLSParticipantViewModel] = [:]
    @State private var isCreatingConversation = false
    @State private var creationProgress: String = ""
    @State private var showingError = false
    @State private var errorMessage: String?
    @State private var searchResults: [MLSParticipantViewModel] = []
    @State private var isSearching = false
    @State private var currentStep: CreationStep = .selectParticipants
    @State private var searchTask: Task<Void, Never>?
    @State private var participantOptInStatus: [String: Bool] = [:]  // Track which participants have opted into MLS
    let onConversationCreated: (@Sendable () async -> Void)?
    
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSNewConversation")
    private let searchDebounceInterval: Duration = .milliseconds(300)
    
    init(onConversationCreated: (@Sendable () async -> Void)? = nil) {
        self.onConversationCreated = onConversationCreated
    }
    
    enum CreationStep {
        case selectParticipants
        case configure
        case creating
        
        var title: String {
            switch self {
            case .selectParticipants: return "Add Participants"
            case .configure: return "Group Details"
            case .creating: return "Creating Group"
            }
        }
        
        var subtitle: String {
            switch self {
            case .selectParticipants: return "Select people to chat securely with"
            case .configure: return "Name your secure group (optional)"
            case .creating: return "Setting up end-to-end encryption..."
            }
        }
    }

    private var orderedSelectedParticipants: [MLSParticipantViewModel] {
        selectionOrder.compactMap { selectedParticipantDetails[$0] }
    }
    
    private var hasSelection: Bool {
        !orderedSelectedParticipants.isEmpty
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                contentView
                
                if isCreatingConversation {
                    creationOverlay
                }
            }
            .navigationTitle(currentStep.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isCreatingConversation)
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    nextButton
                }
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                }
            }
        }
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search by name or handle"
        )
    }
    
    // MARK: - Content Views
    
    @ViewBuilder
    private var contentView: some View {
        switch currentStep {
        case .selectParticipants:
            participantSelectionView
        case .configure:
            configurationView
        case .creating:
            Color.clear
        }
    }
    
    @ViewBuilder
    private var participantSelectionView: some View {
        VStack(spacing: 0) {
            // Progress indicator
            stepProgressView
            
            // Info banner
            infoBanner(
                icon: "lock.shield.fill",
                title: "End-to-End Encrypted",
                subtitle: "Only participants can read messages"
            )
            
            // Selected participants chips
            if hasSelection {
                selectedParticipantsChips
            }
            
            // Search and results
            List {
                if searchText.isEmpty {
                    recentContactsSection
                } else {
                    searchResultsSection
                }
            }
            .listStyle(.insetGrouped)
            .onChange(of: searchText) { _, newValue in
                searchTask?.cancel()
                searchTask = Task {
                    do {
                        try await Task.sleep(for: searchDebounceInterval)
                        await searchParticipants(query: newValue)
                    } catch {
                        // Task cancelled - ignore
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                selectionActionBar
            }
        }
    }
    
    @ViewBuilder
    private var configurationView: some View {
        VStack(spacing: 0) {
            // Progress indicator
            stepProgressView
            
            List {
                Section {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.base) {
                        Text("Group Preview")
                            .designFootnote()
                            .foregroundColor(.secondary)
                        
                        // Group preview card
                        groupPreviewCard
                    }
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                }
                
                Section {
                    TextField("Group Name (required)", text: $conversationName)
                        .designBody()
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                } header: {
                    Label("Group Name", systemImage: "text.bubble")
                        .designCaption()
                } footer: {
                    Text("Give your secure group a name, or leave blank for a default name")
                        .designCaption()
                }
                
                Section {
                    SelectedParticipantsSummaryList(participants: orderedSelectedParticipants)
                        .padding(.vertical, DesignTokens.Spacing.sm)
                    Button {
                        withAnimation(.spring(response: 0.25)) {
                            currentStep = .selectParticipants
                        }
                    } label: {
                        Label("Edit Selection", systemImage: "slider.horizontal.3")
                            .fontWeight(.semibold)
                    }
                } header: {
                    Text("Participants")
                        .designCaption()
                } footer: {
                    Text("Everyone listed will join this secure group once it is created.")
                        .designCaption()
                }
                
                Section {
                    encryptionDetailRow(
                        icon: "lock.shield.fill",
                        title: "MLS Protocol",
                        detail: "RFC 9420 standard"
                    )
                    encryptionDetailRow(
                        icon: "key.fill",
                        title: "Forward Secrecy",
                        detail: "Unique keys per message"
                    )
                    encryptionDetailRow(
                        icon: "checkmark.seal.fill",
                        title: "Verified Identity",
                        detail: "AT Protocol DIDs"
                    )
                } header: {
                    Label("Security Features", systemImage: "checkmark.shield")
                        .designCaption()
                } footer: {
                    Text("Your messages are encrypted end-to-end using the MLS protocol. Only group members can decrypt and read messages.")
                        .designCaption()
                }
            }
            .listStyle(.insetGrouped)
        }
    }
    
    @ViewBuilder
    private var selectionActionBar: some View {
        if currentStep == .selectParticipants {
            VStack(spacing: DesignTokens.Spacing.sm) {
                HStack {
                    if hasSelection {
                        Label("\(selectedParticipants.count) selected", systemImage: "person.3")
                            .designCaption()
                            .foregroundColor(.secondary)
                    } else {
                        Label("Select at least one person", systemImage: "person.badge.plus")
                            .designCaption()
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                
                Button {
                    withAnimation(.spring(response: 0.25)) {
                        currentStep = .configure
                    }
                } label: {
                    Text(hasSelection ? "Continue (\(selectedParticipants.count))" : "Continue")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasSelection)
            }
            .padding(.horizontal)
            .padding(.vertical, DesignTokens.Spacing.base)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                Divider()
            }
        }
    }
    
    // MARK: - Supporting Views
    
    @ViewBuilder
    private var stepProgressView: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            ForEach(0..<2, id: \.self) { index in
                Rectangle()
                    .fill(index == 0 ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(height: 3)
                    .cornerRadius(1.5)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }
    
    @ViewBuilder
    private func infoBanner(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: DesignTokens.Size.iconLG))
                .foregroundColor(.green)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .designCallout()
                    .fontWeight(.semibold)
                Text(subtitle)
                    .designCaption()
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .background(Color.green.opacity(0.1))
        .cornerRadius(DesignTokens.Size.radiusMD)
        .padding(.horizontal)
        .padding(.top, 12)
    }
    
    @ViewBuilder
    private var groupPreviewCard: some View {
        HStack(spacing: DesignTokens.Spacing.base) {
            // Group icon
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: 56, height: 56)
                Image(systemName: "person.3.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.accentColor)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(conversationName.isEmpty ? "Secure Group" : conversationName)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                
                HStack(spacing: 4) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                    Text("\(selectedParticipants.count) member\(selectedParticipants.count == 1 ? "" : "s") • E2E Encrypted")
                        .designCaption()
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(DesignTokens.Size.radiusMD)
    }
    
    @ViewBuilder
    private func encryptionDetailRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: DesignTokens.Size.iconMD))
                .foregroundColor(.green)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .designCallout()
                Text(detail)
                    .designCaption()
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
    
    @ViewBuilder
    private var selectedParticipantsChips: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                Label("Selected (\(selectedParticipants.count))", systemImage: "person.fill.checkmark")
                    .designCaption()
                    .foregroundColor(.secondary)
                Spacer()
                Button("Clear") {
                    withAnimation(.spring(response: 0.3)) {
                        clearSelectedParticipants()
                    }
                }
                .designCaption()
                .disabled(selectedParticipants.isEmpty)
            }
            .padding(.horizontal)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    ForEach(orderedSelectedParticipants, id: \.id) { participant in
                        ParticipantChip(participant: participant) {
                            withAnimation(.spring(response: 0.3)) {
                                removeParticipant(participant)
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
        .background(
            Color.secondary.opacity(0.05)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Size.radiusMD))
    }
    
    @ViewBuilder
    private var recentContactsSection: some View {
        Section {
            // For now, show empty state until we add recent contacts tracking
            EmptyStateRow(
                icon: "person.2",
                message: "Search above to find people"
            )
        } header: {
            Text("Add Participants")
                .designCaption()
        }
    }
    
    @ViewBuilder
    private var searchResultsSection: some View {
        Section {
            if isSearching {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical)
            } else if searchResults.isEmpty {
                EmptyStateRow(
                    icon: "magnifyingglass",
                    message: "No results found"
                )
            } else {
                ForEach(searchResults, id: \.id) { participant in
                    let isOptedIn = participantOptInStatus[participant.id] ?? false
                    ParticipantRow(
                        participant: participant,
                        isSelected: selectedParticipants.contains(participant.id),
                        isMLSAvailable: isOptedIn
                    ) {
                        if isOptedIn {
                            toggleParticipant(participant)
                        }
                    }
                    .disabled(!isOptedIn)
                    .opacity(isOptedIn ? 1.0 : 0.6)
                }
            }
        } header: {
            if !searchResults.isEmpty {
                Text("Search Results")
                    .designCaption()
            }
        } footer: {
            if !searchResults.isEmpty && searchResults.contains(where: { participantOptInStatus[$0.id] == false }) {
                Text("Users without the lock icon haven't enabled Catbird Groups yet.")
                    .designCaption()
                    .foregroundColor(.secondary)
            }
        }
    }
    
    @ViewBuilder
    private var nextButton: some View {
        if currentStep == .selectParticipants {
            Button("Next") {
                withAnimation {
                    currentStep = .configure
                }
            }
            .disabled(selectedParticipants.isEmpty)
            .fontWeight(.semibold)
        } else if currentStep == .configure {
            Button("Create") {
                Task {
                    await createMLSConversation()
                }
            }
            .disabled(isCreatingConversation)
            .fontWeight(.semibold)
        }
    }
    
    @ViewBuilder
    private var creationOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            
            VStack(spacing: DesignTokens.Spacing.lg) {
                // Animated lock icon
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.2))
                        .frame(width: 80, height: 80)
                    
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.green)
                        .symbolEffect(.pulse)
                }
                
                VStack(spacing: DesignTokens.Spacing.sm) {
                    Text("Creating Secure Group")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                    
                    Text(creationProgress)
                        .designCallout()
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.2)
            }
            .padding(32)
            .background(.ultraThinMaterial)
            .cornerRadius(DesignTokens.Size.radiusLG)
            .shadow(radius: 20)
        }
    }
    
    // MARK: - Helper Functions
    
    private func toggleParticipant(_ participant: MLSParticipantViewModel) {
        withAnimation(.spring(response: 0.3)) {
            if selectedParticipants.contains(participant.id) {
                removeParticipant(participant)
            } else {
                addParticipant(participant)
            }
        }
    }
    
    private func addParticipant(_ participant: MLSParticipantViewModel) {
        selectedParticipants.insert(participant.id)
        selectedParticipantDetails[participant.id] = participant
        if !selectionOrder.contains(participant.id) {
            selectionOrder.append(participant.id)
        }
    }
    
    private func removeParticipant(_ participant: MLSParticipantViewModel) {
        selectedParticipants.remove(participant.id)
        selectedParticipantDetails.removeValue(forKey: participant.id)
        selectionOrder.removeAll { $0 == participant.id }
    }
    
    private func clearSelectedParticipants() {
        selectedParticipants.removeAll()
        selectionOrder.removeAll()
        selectedParticipantDetails.removeAll()
    }
    
    @MainActor
    private func searchParticipants(query: String) async {
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        
        isSearching = true
        defer { isSearching = false }
        
        do {
            logger.info("Searching for participants: \(query)")
            
             let client = appState.client
            let params = AppBskyActorSearchActorsTypeahead.Parameters(q: query, limit: 20)
            let (code, response) = try await client.app.bsky.actor.searchActorsTypeahead(input: params)
            
            guard code >= 200 && code < 300, let actors = response?.actors else {
                logger.warning("Search failed with code: \(code)")
                searchResults = []
                return
            }
            
            // Map actors to view models
            var results = actors.map { actor in
                MLSParticipantViewModel(
                    id: actor.did.description,
                    handle: actor.handle.description,
                    displayName: actor.displayName,
                    avatarURL: actor.avatar.flatMap { URL(string: $0.uriString()) }
                )
            }
            
            // Check MLS opt-in status for all search results
            if let apiClient = await appState.getMLSAPIClient() {
                let dids = results.compactMap { try? DID(didString: $0.id) }
                if !dids.isEmpty {
                    do {
                        let statuses = try await apiClient.getOptInStatus(dids: dids)
                        for status in statuses {
                            participantOptInStatus[status.did] = status.optedIn
                        }
                        logger.info("Checked MLS opt-in status for \(statuses.count) users")
                    } catch {
                        logger.warning("Failed to check MLS opt-in status: \(error.localizedDescription)")
                        // Continue without opt-in status - will show warning on selection
                    }
                }
            }
            
            searchResults = results
            
            for participant in searchResults where selectedParticipants.contains(participant.id) {
                selectedParticipantDetails[participant.id] = participant
            }
            
        } catch {
            logger.error("Failed to search participants: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    private func createMLSConversation() async {
        guard !selectedParticipants.isEmpty else { return }
        guard let database = appState.mlsDatabase,
              let conversationManager = await appState.getMLSConversationManager() else {
            errorMessage = "MLS service not available"
            showingError = true
            return
        }

        isCreatingConversation = true
        currentStep = .creating

        do {
            creationProgress = "Fetching encryption keys..."
            logger.info("Creating MLS conversation with \(selectedParticipants.count) participants")

            let viewModel = MLSNewConversationViewModel(
                database: database,
                conversationManager: conversationManager
            )
            
            if !conversationName.isEmpty {
                viewModel.conversationName = conversationName
            }
            
            viewModel.selectedMembers = Array(selectedParticipants)
            
            creationProgress = "Setting up secure group..."
            
            // Create the conversation
            await viewModel.createConversation()
            
            if let error = viewModel.error {
                throw error
            }
            
            creationProgress = "Finalizing..."
            
            // Reload conversations
            await appState.reloadMLSConversations()
            if let onConversationCreated {
                await onConversationCreated()
            }
            
            logger.info("Successfully created MLS conversation")
            dismiss()
            
        } catch {
            logger.error("Failed to create MLS conversation: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            showingError = true
            currentStep = .configure
        }
        
        isCreatingConversation = false
    }
}

// MARK: - Supporting Components

struct ParticipantRow: View {
    let participant: MLSParticipantViewModel
    let isSelected: Bool
    var isMLSAvailable: Bool = true  // Default to true for backward compatibility
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DesignTokens.Spacing.base) {
                ZStack(alignment: .bottomTrailing) {
                    AsyncProfileImage(
                        url: participant.avatarURL,
                        size: DesignTokens.Size.avatarMD
                    )
                    
                    // MLS availability indicator
                    if isMLSAvailable {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                            .background(
                                Circle()
                                    .fill(Color(.systemBackground))
                                    .frame(width: 16, height: 16)
                            )
                            .offset(x: 2, y: 2)
                    }
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        if let displayName = participant.displayName {
                            Text(displayName)
                                .designCallout()
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                    }
                    
                    HStack(spacing: 4) {
                        Text("@\(participant.handle)")
                            .designCaption()
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        
                        if !isMLSAvailable {
                            Text("• Not available")
                                .designCaption()
                                .foregroundColor(.orange)
                        }
                    }
                }
                
                Spacer()
                
                if isMLSAvailable {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24))
                        .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.3))
                        .animation(.spring(response: 0.3), value: isSelected)
                } else {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary.opacity(0.3))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ParticipantChip: View {
    let participant: MLSParticipantViewModel
    let onRemove: () -> Void
    
    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            AsyncProfileImage(
                url: participant.avatarURL,
                size: 28
            )
            
            Text(participant.displayName ?? participant.handle)
                .designCaption()
                .lineLimit(1)
            
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.15))
        .cornerRadius(20)
    }
}

struct SelectedParticipantsSummaryList: View {
    let participants: [MLSParticipantViewModel]
    
    var body: some View {
        if participants.isEmpty {
            Text("No participants selected")
                .designCaption()
                .foregroundColor(.secondary)
        } else {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                ForEach(participants, id: \.id) { participant in
                    HStack(spacing: DesignTokens.Spacing.base) {
                        AsyncProfileImage(
                            url: participant.avatarURL,
                            size: DesignTokens.Size.avatarSM
                        )
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(participant.displayName ?? participant.handle)
                                .designCallout()
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Text("@\(participant.handle)")
                                .designCaption()
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                }
            }
        }
    }
}

struct EmptyStateRow: View {
    let icon: String
    let message: String
    
    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundColor(.secondary.opacity(0.5))
                Text(message)
                    .designCallout()
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 32)
            Spacer()
        }
    }
}

#endif
