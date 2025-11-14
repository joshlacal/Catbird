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
    @State private var isCreatingConversation = false
    @State private var creationProgress: String = ""
    @State private var showingError = false
    @State private var errorMessage: String?
    @State private var searchResults: [MLSParticipantViewModel] = []
    @State private var isSearching = false
    @State private var currentStep: CreationStep = .selectParticipants
    
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSNewConversation")
    
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
            .themedNavigationBar(appState.themeManager)
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
            if !selectedParticipants.isEmpty {
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
            .searchable(text: $searchText, prompt: "Search by name or handle")
            .onChange(of: searchText) { _, newValue in
                Task {
                    await searchParticipants(query: newValue)
                }
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
                    TextField("Group Name (optional)", text: $conversationName)
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
                    HStack {
                        Image(systemName: "person.3.fill")
                            .foregroundColor(.secondary)
                        Text("\(selectedParticipants.count) participant\(selectedParticipants.count == 1 ? "" : "s")")
                            .designBody()
                        Spacer()
                        Button("Edit") {
                            withAnimation {
                                currentStep = .selectParticipants
                            }
                        }
                        .designCaption()
                    }
                } header: {
                    Text("Participants")
                        .designCaption()
                }
                
                Section {
                    encryptionDetailRow(
                        icon: "lock.shield.fill",
                        title: "MLS Protocol",
                        detail: "Military-grade encryption"
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
                    Text("Your messages are encrypted end-to-end using the MLS protocol (RFC 9420). Only group members can decrypt and read messages.")
                        .designCaption()
                }
            }
            .listStyle(.insetGrouped)
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                ForEach(selectedParticipants.sorted(), id: \.self) { participantId in
                    if let participant = findParticipant(by: participantId) {
                        ParticipantChip(participant: participant) {
                            withAnimation(.spring(response: 0.3)) {
                                _ = selectedParticipants.remove(participantId)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(
            Color.secondary
                .opacity(0.05)
        )
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
                    ParticipantRow(
                        participant: participant,
                        isSelected: selectedParticipants.contains(participant.id)
                    ) {
                        toggleParticipant(participant)
                    }
                }
            }
        } header: {
            if !searchResults.isEmpty {
                Text("Search Results")
                    .designCaption()
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
    
    private func findParticipant(by id: String) -> MLSParticipantViewModel? {
        searchResults.first { $0.id == id }
    }
    
    private func toggleParticipant(_ participant: MLSParticipantViewModel) {
        withAnimation(.spring(response: 0.3)) {
            if selectedParticipants.contains(participant.id) {
                selectedParticipants.remove(participant.id)
            } else {
                selectedParticipants.insert(participant.id)
            }
        }
    }
    
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
            
            searchResults = actors.map { actor in
                MLSParticipantViewModel(
                    id: actor.did.description,
                    handle: actor.handle.description,
                    displayName: actor.displayName,
                    avatarURL: actor.avatar.flatMap { URL(string: $0.uriString()) }
                )
            }
            
        } catch {
            logger.error("Failed to search participants: \(error.localizedDescription)")
        }
    }
    
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
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DesignTokens.Spacing.base) {
                AsyncProfileImage(
                    url: participant.avatarURL,
                    size: DesignTokens.Size.avatarMD
                )
                
                VStack(alignment: .leading, spacing: 4) {
                    if let displayName = participant.displayName {
                        Text(displayName)
                            .designCallout()
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                    
                    Text("@\(participant.handle)")
                        .designCaption()
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.3))
                    .animation(.spring(response: 0.3), value: isSelected)
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
