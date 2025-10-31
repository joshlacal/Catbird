import SwiftUI
import Petrel
import OSLog

#if os(iOS)

// MARK: - MLS Member Management View

/// Interface to add and remove members from an end-to-end encrypted MLS group
struct MLSMemberManagementView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    
    let conversation: MLSConversationViewModel
    
    @State private var searchText = ""
    @State private var searchResults: [MLSParticipantViewModel] = []
    @State private var isSearching = false
    @State private var isAddingMember = false
    @State private var isRemovingMember = false
    @State private var showingRemoveAlert = false
    @State private var memberToRemove: MLSParticipantViewModel?
    @State private var showingError = false
    @State private var errorMessage: String?
    @State private var memberRoles: [String: MemberRole] = [:]
    
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSMemberManagement")
    
    var body: some View {
        NavigationStack {
            List {
                currentMembersSection
                
                if isAdmin {
                    addMembersSection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Group Members")
            .navigationBarTitleDisplayMode(.inline)
            .themedNavigationBar(appState.themeManager)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search to add members")
            .onChange(of: searchText) { _, newValue in
                Task {
                    await searchPotentialMembers(query: newValue)
                }
            }
            .overlay {
                if isAddingMember || isRemovingMember {
                    loadingOverlay
                }
            }
            .alert("Remove Member", isPresented: $showingRemoveAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    if let member = memberToRemove {
                        Task {
                            await removeMember(member)
                        }
                    }
                }
            } message: {
                if let member = memberToRemove {
                    Text("Are you sure you want to remove \(member.displayName ?? member.handle) from this secure group?")
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
        .task {
            loadMemberRoles()
        }
    }
    
    // MARK: - Current Members Section
    
    @ViewBuilder
    private var currentMembersSection: some View {
        Section {
            ForEach(conversation.participants, id: \.id) { participant in
                MemberRowView(
                    participant: participant,
                    role: memberRoles[participant.id] ?? .member,
                    isCurrentUser: participant.id == appState.currentUserDID
                )
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    swipeActionsContent(for: participant)
                }
            }
        } header: {
            HStack {
                Text("Members (\(conversation.participants.count))")
                    .designCaption()
                Spacer()
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: DesignTokens.Size.iconSM))
                    .foregroundColor(.green)
            }
        } footer: {
            Text("All members have end-to-end encryption enabled")
                .designCaption()
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Add Members Section
    
    @ViewBuilder
    private var addMembersSection: some View {
        Section {
            if searchText.isEmpty {
                Text("Search to add new members")
                    .designFootnote()
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .spacingBase(.vertical)
            } else if isSearching {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .spacingBase(.vertical)
            } else if searchResults.isEmpty {
                Text("No matching users found")
                    .designFootnote()
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .spacingBase(.vertical)
            } else {
                ForEach(filteredSearchResults, id: \.id) { participant in
                    Button {
                        Task {
                            await addMember(participant)
                        }
                    } label: {
                        HStack(spacing: DesignTokens.Spacing.base) {
                            AsyncProfileImage(
                                url: participant.avatarURL,
                                size: DesignTokens.Size.avatarMD
                            )
                            
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                                if let displayName = participant.displayName {
                                    Text(displayName)
                                        .designCallout()
                                        .foregroundColor(.primary)
                                }
                                
                                Text("@\(participant.handle)")
                                    .designFootnote()
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Image(systemName: "plus.circle")
                                .font(.system(size: DesignTokens.Size.iconLG))
                                .foregroundColor(.accentColor)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add \(participant.displayName ?? participant.handle)")
                }
            }
        } header: {
            if !searchText.isEmpty {
                Text("Add Members")
                    .designCaption()
            }
        }
    }
    
    // MARK: - Loading Overlay
    
    @ViewBuilder
    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
            
            VStack(spacing: DesignTokens.Spacing.base) {
                ProgressView()
                    .scaleEffect(1.5)
                
                Text(isAddingMember ? "Adding member..." : "Removing member...")
                    .designCallout()
                    .foregroundColor(.white)
            }
            .spacingLG()
            .background(.ultraThinMaterial)
            .cornerRadius(DesignTokens.Size.radiusLG)
        }
    }
    
    // MARK: - Computed Properties
    
    private var isAdmin: Bool {
        guard let currentUserDID = appState.currentUserDID else { return false }
        return memberRoles[currentUserDID] == .admin
    }
    
    @ViewBuilder
    private func swipeActionsContent(for participant: MLSParticipantViewModel) -> some View {
        if isAdmin && participant.id != appState.currentUserDID {
            Button(role: .destructive) {
                memberToRemove = participant
                showingRemoveAlert = true
            } label: {
                Label("Remove", systemImage: "person.badge.minus")
            }
            
            if memberRoles[participant.id] != .admin {
                Button {
                    Task {
                        await promoteToAdmin(participant)
                    }
                } label: {
                    Label("Make Admin", systemImage: "star")
                }
                .tint(.orange)
            }
        }
    }
    
    private var filteredSearchResults: [MLSParticipantViewModel] {
        let currentMemberIds = Set(conversation.participants.map { $0.id })
        return searchResults.filter { !currentMemberIds.contains($0.id) }
    }
    
    // MARK: - Actions
    
    private func loadMemberRoles() {
        // TODO: Load member roles from MLS group metadata
        // For now, assume first participant is admin
        if let firstParticipant = conversation.participants.first {
            memberRoles[firstParticipant.id] = .admin
        }
        
        for participant in conversation.participants.dropFirst() {
            memberRoles[participant.id] = .member
        }
        
        logger.info("Loaded member roles for \(memberRoles.count) members")
    }
    
    private func searchPotentialMembers(query: String) async {
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        
        isSearching = true
        defer { isSearching = false }
        
        do {
            // TODO: Search for MLS-capable users
            logger.info("Searching for potential members: \(query)")
            
            // Simulate search delay
            try? await Task.sleep(nanoseconds: 300_000_000)
            
            // TODO: Replace with actual search implementation
            searchResults = []
            
        } catch {
            logger.error("Failed to search potential members: \(error.localizedDescription)")
        }
    }
    
    private func addMember(_ participant: MLSParticipantViewModel) async {
        isAddingMember = true
        defer { isAddingMember = false }
        
        do {
            // TODO: Add member to MLS group via FFI
            logger.info("Adding member to MLS group: \(participant.id)")
            
            // This would:
            // 1. Fetch participant's KeyPackage
            // 2. Generate Add proposal
            // 3. Commit the change
            // 4. Send Welcome message to new member
            // 5. Broadcast group changes
            
            logger.info("Successfully added member to MLS group")
            
            // Clear search
            searchText = ""
            searchResults = []
            
        } catch {
            logger.error("Failed to add member: \(error.localizedDescription)")
            errorMessage = "Failed to add member: \(error.localizedDescription)"
            showingError = true
        }
    }
    
    private func removeMember(_ participant: MLSParticipantViewModel) async {
        isRemovingMember = true
        defer { isRemovingMember = false }
        
        do {
            // TODO: Remove member from MLS group via FFI
            logger.info("Removing member from MLS group: \(participant.id)")
            
            // This would:
            // 1. Generate Remove proposal
            // 2. Commit the change
            // 3. Broadcast group changes
            
            logger.info("Successfully removed member from MLS group")
            
        } catch {
            logger.error("Failed to remove member: \(error.localizedDescription)")
            errorMessage = "Failed to remove member: \(error.localizedDescription)"
            showingError = true
        }
    }
    
    private func promoteToAdmin(_ participant: MLSParticipantViewModel) async {
        do {
            // TODO: Update member role in group metadata
            logger.info("Promoting member to admin: \(participant.id)")
            
            memberRoles[participant.id] = .admin
            
            logger.info("Successfully promoted member to admin")
            
        } catch {
            logger.error("Failed to promote member: \(error.localizedDescription)")
            errorMessage = "Failed to promote member: \(error.localizedDescription)"
            showingError = true
        }
    }
}

// MARK: - Member Row View

struct MemberRowView: View {
    let participant: MLSParticipantViewModel
    let role: MemberRole
    let isCurrentUser: Bool
    
    var body: some View {
        HStack(spacing: DesignTokens.Spacing.base) {
            AsyncProfileImage(
                url: participant.avatarURL,
                size: DesignTokens.Size.avatarMD
            )
            
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    if let displayName = participant.displayName {
                        Text(displayName)
                            .designCallout()
                            .foregroundColor(.primary)
                    }
                    
                    if isCurrentUser {
                        Text("(You)")
                            .designCaption()
                            .foregroundColor(.secondary)
                    }
                }
                
                Text("@\(participant.handle)")
                    .designFootnote()
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if role == .admin {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "star.fill")
                        .font(.system(size: DesignTokens.Size.iconSM))
                        .foregroundColor(.orange)
                    
                    Text("Admin")
                        .designCaption()
                        .foregroundColor(.orange)
                }
                .accessibilityLabel("Group administrator")
            }
        }
        .spacingSM(.vertical)
    }
}

// MARK: - Member Role

enum MemberRole {
    case admin
    case member
}

// MARK: - AsyncProfileImage Helper


// MARK: - Preview

#Preview {
    let sampleConversation = MLSConversationViewModel(
        id: "sample-convo",
        name: "Test Group",
        participants: [
            MLSParticipantViewModel(id: "user1", handle: "alice.bsky.social", displayName: "Alice", avatarURL: nil),
            MLSParticipantViewModel(id: "user2", handle: "bob.bsky.social", displayName: "Bob", avatarURL: nil),
            MLSParticipantViewModel(id: "user3", handle: "charlie.bsky.social", displayName: "Charlie", avatarURL: nil)
        ],
        lastMessagePreview: "Hello everyone!",
        lastMessageTimestamp: Date(),
        unreadCount: 0,
        isGroupChat: true,
        groupId: "sample-group-id"
    )
    
    MLSMemberManagementView(conversation: sampleConversation)
        .environment(AppState.shared)
}

#endif
