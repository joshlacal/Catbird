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

    let conversationId: String

    @State private var viewModel: MLSMemberManagementViewModel?
    @State private var conversation: MLSConversationViewModel?
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
    @State private var showingMemberActions = false
    @State private var selectedMemberForActions: BlueCatbirdMlsDefs.MemberView?
    @State private var enrichedProfiles: [String: MLSProfileEnricher.ProfileData] = [:]
    @State private var showMemberHistory = false

    private let logger = Logger(subsystem: "blue.catbird", category: "MLSMemberManagement")
    
    var body: some View {
        NavigationStack {
            memberListContent
                .overlay {
                    if isAddingMember || isRemovingMember {
                        loadingOverlay
                    }
                }
        }
        .alert("Remove Member", isPresented: $showingRemoveAlert) {
            removeMemberAlertButtons
        } message: {
            removeMemberAlertMessage
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}

            // Show retry button if MLS service failed and retries available
            if case .failed = appState.mlsServiceState.status,
               appState.mlsServiceState.retryCount < appState.mlsServiceState.maxRetries {
                Button("Retry") {
                    Task {
                        await appState.retryMLSInitialization()
                        // Try to initialize view again after retry
                        await initializeViewModel()
                    }
                }
            }
        } message: {
            errorAlertMessage
        }
        .sheet(item: $selectedMemberForActions) { member in
            memberActionsSheet(for: member)
        }
        .sheet(isPresented: $showMemberHistory) {
            NavigationStack {
                if let database = appState.mlsDatabase {
                    MLSMemberHistoryView(conversationID: conversationId, currentUserDID: appState.userDID, database: database)
                }
            }
        }
        .task {
            await initializeViewModel()
            logger.info("👥 MLSMemberManagementView task start for convo \(conversationId)")
            if let viewModel = viewModel {
                await viewModel.loadMembers()
                if viewModel.members.isEmpty {
                    logger.warning("⚠️ No members from server/cache, attempting local fallback")
                    await viewModel.loadMembersFromLocal()
                }
                conversation = viewModel.conversation?.toViewModel()
                updateMemberRoles(from: viewModel.members)
                
                // Enrich member profiles with handle/display name/avatar
                await enrichMemberProfiles(viewModel.members)
            } else {
                updateMemberRoles(from: nil)
            }
        }
        .onChange(of: viewModel?.members.count ?? 0) { _, _ in
            if let viewModel = viewModel {
                conversation = viewModel.conversation?.toViewModel()
                updateMemberRoles(from: viewModel.members)
                
                // Re-enrich profiles when members change
                Task {
                    await enrichMemberProfiles(viewModel.members)
                }
            }
        }
    }
    // MARK: - View Components

    @ViewBuilder
    private var memberListContent: some View {
        List {
            currentMembersSection
            addMembersSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Group Members")
        .navigationBarTitleDisplayMode(.inline)
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
    }

    @ViewBuilder
    private var removeMemberAlertButtons: some View {
        Button("Cancel", role: .cancel) {}
        Button("Remove", role: .destructive) {
            if let member = memberToRemove {
                Task {
                    await removeMember(member)
                }
            }
        }
    }

    @ViewBuilder
    private var removeMemberAlertMessage: some View {
        if let member = memberToRemove {
            Text("Are you sure you want to remove \(member.displayName ?? member.handle) from this secure group?")
        }
    }

    @ViewBuilder
    private var errorAlertMessage: some View {
        if let errorMessage = errorMessage {
            Text(errorMessage)
        }
    }

    @ViewBuilder
    private func memberActionsSheet(for member: BlueCatbirdMlsDefs.MemberView) -> some View {
        MLSMemberActionsSheetWrapper(
            conversationId: conversationId,
            member: member,
            currentUserDid: appState.userDID,
            isCurrentUserAdmin: isAdmin,
            isCurrentUserCreator: appState.userDID == conversationCreatorDID,
            appState: appState
        )
    }

    @MainActor
    private func initializeViewModel() async {
        if viewModel == nil {
            guard let database = appState.mlsDatabase,
                  let apiClient = await appState.getMLSAPIClient(),
                  let conversationManager = await appState.getMLSConversationManager() else {
                logger.error("Cannot initialize view: dependencies not available")

                // Check MLS service state and provide appropriate error message
                switch appState.mlsServiceState.status {
                case .failed(let message):
                    errorMessage = message
                case .notStarted, .initializing:
                    errorMessage = "MLS service is still initializing. Please wait..."
                default:
                    errorMessage = "MLS service not available"
                }

                showingError = true
                return
            }

            viewModel = MLSMemberManagementViewModel(
                conversationId: conversationId,
                currentUserDid: appState.userDID,
                database: database,
                apiClient: apiClient,
                conversationManager: conversationManager
            )
        }
    }
    
    // MARK: - Current Members Section
    
    @ViewBuilder
    private var currentMembersSection: some View {
        Section {
            if let viewModel = viewModel {
                ForEach(viewModel.groupedMembers) { groupedMember in
                    MemberRowEnhanced(
                        member: groupedMember.primaryDevice ?? groupedMember.devices[0],
                        isCurrentUser: groupedMember.userDid == appState.userDID,
                        isCreator: groupedMember.isCreator,
                        enrichedProfile: enrichedProfiles[groupedMember.userDid],
                        deviceCount: groupedMember.deviceCount
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedMemberForActions = groupedMember.primaryDevice ?? groupedMember.devices[0]
                    }
                    .accessibilityHint("Double tap to view member actions")
                }
            } else if let participants = conversation?.participants {
                ForEach(participants, id: \.id) { participant in
                    MemberRowView(
                        participant: participant,
                        role: memberRoles[participant.id] ?? .member,
                        isCurrentUser: participant.id == appState.userDID
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        swipeActionsContent(for: participant)
                    }
                }
            } else {
                ProgressView("Loading members...")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }
        } header: {
            HStack {
                Text("Members (\(viewModel?.groupedMembers.count ?? conversation?.participants.count ?? 0))")
                    .designCaption()
                Spacer()

                // History button
                Button(action: { showMemberHistory = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 12))
                        Text("History")
                            .designCaption()
                    }
                    .foregroundColor(.blue)
                }

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
            } else if viewModel?.isSearching == true {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .spacingBase(.vertical)
            } else if filteredSearchResults.isEmpty {
                Text("No matching users found")
                    .designFootnote()
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .spacingBase(.vertical)
            } else {
                ForEach(filteredSearchResults, id: \.id) { participant in
                    let isOptedIn = viewModel?.participantOptInStatus[participant.id] ?? false
                    Button {
                        if isOptedIn {
                            Task {
                                await addMember(participant)
                            }
                        }
                    } label: {
                        HStack(spacing: DesignTokens.Spacing.base) {
                            ZStack(alignment: .bottomTrailing) {
                                AsyncProfileImage(
                                    url: participant.avatarURL,
                                    size: DesignTokens.Size.avatarMD
                                )
                                
                                // MLS availability indicator
                                if isOptedIn {
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
                            
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                                if let displayName = participant.displayName {
                                    Text(displayName)
                                        .designCallout()
                                        .foregroundColor(.primary)
                                }
                                
                                HStack(spacing: 4) {
                                    Text("@\(participant.handle)")
                                        .designFootnote()
                                        .foregroundColor(.secondary)
                                    
                                    if !isOptedIn {
                                        Text("• Not available")
                                            .designFootnote()
                                            .foregroundColor(.orange)
                                    }
                                }
                            }
                            
                            Spacer()
                            
                            if isOptedIn {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: DesignTokens.Size.iconLG))
                                    .foregroundColor(.accentColor)
                            } else {
                                Image(systemName: "xmark.circle")
                                    .font(.system(size: DesignTokens.Size.iconLG))
                                    .foregroundColor(.secondary.opacity(0.3))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isOptedIn)
                    .opacity(isOptedIn ? 1.0 : 0.6)
                    .accessibilityLabel("Add \(participant.displayName ?? participant.handle)")
                }
            }
        } header: {
            if !searchText.isEmpty {
                Text("Add Members")
                    .designCaption()
            }
        } footer: {
            if !filteredSearchResults.isEmpty && filteredSearchResults.contains(where: { viewModel?.participantOptInStatus[$0.id] == false }) {
                Text("Users without the lock icon haven't enabled Catbird Groups yet.")
                    .designCaption()
                    .foregroundColor(.secondary)
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
        let currentUserDID = appState.userDID
        return memberRoles[currentUserDID] == .admin
    }
    
    private var conversationCreatorDID: String? {
        viewModel?.conversation?.creator.description
            ?? viewModel?.members.first?.did.description
            ?? conversation?.participants.first?.id
    }
    
    @ViewBuilder
    private func swipeActionsContent(for participant: MLSParticipantViewModel) -> some View {
        if isAdmin && participant.id != appState.userDID {
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
        guard let viewModel = viewModel else { return [] }
        return viewModel.searchResults
    }
    
    // MARK: - Actions
    
    private func updateMemberRoles(from members: [BlueCatbirdMlsDefs.MemberView]?) {
        if let members {
            var roles: [String: MemberRole] = [:]
            for member in members {
                roles[member.did.description] = member.isAdmin ? .admin : .member
            }
            memberRoles = roles
            logger.info("Loaded member roles for \(members.count) members")
            return
        }

        guard let participants = conversation?.participants else {
            logger.warning("Cannot load member roles: conversation not loaded")
            return
        }

        var roles: [String: MemberRole] = [:]
        if let firstParticipant = participants.first {
            roles[firstParticipant.id] = .admin
        }

        for participant in participants.dropFirst() {
            roles[participant.id] = .member
        }

        memberRoles = roles
        logger.info("Loaded member roles for \(roles.count) members (fallback)")
    }

    /// Enrich member profiles with handle, display name, and avatar from Bluesky
    private func enrichMemberProfiles(_ members: [BlueCatbirdMlsDefs.MemberView]) async {
        guard let client = appState.atProtoClient else {
            logger.warning("Cannot enrich member profiles: no AT Proto client")
            return
        }

        let dids = members.map { $0.did.description }
        logger.info("🔍 Enriching profiles for \(dids.count) members")

        let profiles = await appState.mlsProfileEnricher.ensureProfiles(for: dids, using: client)

        await MainActor.run {
            enrichedProfiles = profiles
            logger.info("✅ Enriched \(profiles.count) member profiles")
        }
    }

    private func searchPotentialMembers(query: String) async {
        viewModel?.memberSearchQuery = query
    }
    
    private func addMember(_ participant: MLSParticipantViewModel) async {
        isAddingMember = true
        defer { isAddingMember = false }
        
        await viewModel?.addMembers([participant.id])
        
        if let error = viewModel?.error {
            logger.error("Failed to add member: \(error.localizedDescription)")
            errorMessage = "Failed to add member: \(error.localizedDescription)"
            showingError = true
        } else {
            logger.info("Successfully added member to MLS group")
            searchText = ""
            updateMemberRoles(from: viewModel?.members)
        }
    }
    
    private func removeMember(_ participant: MLSParticipantViewModel) async {
        isRemovingMember = true
        defer { isRemovingMember = false }
        
        await viewModel?.removeMember(participant.id)
        
        if let error = viewModel?.error {
            logger.error("Failed to remove member: \(error.localizedDescription)")
            errorMessage = "Failed to remove member: \(error.localizedDescription)"
            showingError = true
        } else {
            logger.info("Successfully removed member from MLS group")
            updateMemberRoles(from: viewModel?.members)
        }
    }
    
    private func promoteToAdmin(_ participant: MLSParticipantViewModel) async {
        await viewModel?.promoteMember(participant.id)
        
        if let error = viewModel?.error {
            logger.error("Failed to promote member: \(error.localizedDescription)")
            errorMessage = "Failed to promote member: \(error.localizedDescription)"
            showingError = true
        } else {
            logger.info("Successfully promoted member to admin")
            updateMemberRoles(from: viewModel?.members)
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

// MARK: - Enhanced Member Row with Admin Badges

struct MemberRowEnhanced: View {
    let member: BlueCatbirdMlsDefs.MemberView
    let isCurrentUser: Bool
    let isCreator: Bool
    let enrichedProfile: MLSProfileEnricher.ProfileData?
    let deviceCount: Int?

    init(
        member: BlueCatbirdMlsDefs.MemberView,
        isCurrentUser: Bool,
        isCreator: Bool,
        enrichedProfile: MLSProfileEnricher.ProfileData?,
        deviceCount: Int? = nil
    ) {
        self.member = member
        self.isCurrentUser = isCurrentUser
        self.isCreator = isCreator
        self.enrichedProfile = enrichedProfile
        self.deviceCount = deviceCount
    }

    private var displayName: String {
        enrichedProfile?.displayName ?? enrichedProfile?.handle ?? member.did.description
    }

    private var handle: String {
        if let handle = enrichedProfile?.handle {
            return "@\(handle)"
        }
        return member.did.description
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.base) {
            // Avatar placeholder
            Circle()
                .fill(Color.blue.gradient)
                .frame(width: DesignTokens.Size.avatarMD, height: DesignTokens.Size.avatarMD)
                .overlay {
                    Text(String(displayName.prefix(1)))
                        .font(.headline)
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(displayName)
                        .designCallout()
                        .foregroundColor(.primary)

                    if isCurrentUser {
                        Text("(You)")
                            .designCaption()
                            .foregroundColor(.secondary)
                    }
                }

                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(handle)
                        .designFootnote()
                        .foregroundColor(.secondary)

                    // Recent join indicator
                    if member.joinedAt.date > Date().addingTimeInterval(-3600 * 24 * 7) {
                        Text("•")
                            .designFootnote()
                            .foregroundColor(.secondary)
                        Text(timeSinceJoined)
                            .designFootnote()
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Badges
            HStack(spacing: DesignTokens.Spacing.xs) {
                // "New" badge for recently joined members
                if member.joinedAt.date > Date().addingTimeInterval(-3600 * 24 * 7)  {
                    HStack(spacing: 2) {
                        Image(systemName: "clock.badge.checkmark")
                            .font(.system(size: 10))
                        Text("New")
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                    }
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.2))
                    .foregroundColor(.green)
                    .cornerRadius(4)
                }
                if let deviceCount = deviceCount, deviceCount > 1 {
                    HStack(spacing: 4) {
                        Image(systemName: "iphone.gen2.circle.fill")
                            .font(.system(size: DesignTokens.Size.iconSM))
                            .foregroundColor(.blue)

                        Text("\(deviceCount)")
                            .designCaption()
                            .foregroundColor(.blue)
                            .lineLimit(1)
                    }
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.2))
                    .clipShape(Capsule())
                    .accessibilityLabel("\(deviceCount) devices")
                }

                if isCreator {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.system(size: DesignTokens.Size.iconSM))
                            .foregroundColor(.yellow)

                        Text("Creator")
                            .designCaption()
                            .foregroundColor(.yellow)
                            .lineLimit(1)
                    }
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.yellow.opacity(0.2))
                    .clipShape(Capsule())
                    .accessibilityLabel("Conversation creator")
                }

                if member.isAdmin {
                    HStack(spacing: 4) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: DesignTokens.Size.iconSM))
                            .foregroundColor(.orange)

                        Text("Admin")
                            .designCaption()
                            .foregroundColor(.orange)
                            .lineLimit(1)
                    }
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.2))
                    .clipShape(Capsule())
                    .accessibilityLabel("Group administrator")
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .spacingSM(.vertical)
    }

    private var formattedJoinDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: member.joinedAt.date)
    }

    private var timeSinceJoined: String {
        let interval = Date().timeIntervalSince(member.joinedAt.date)
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            return ""
        }
    }
}

// MARK: - AsyncProfileImage Helper


// MARK: - Preview

#Preview {
    @Previewable @Environment(AppState.self) var appState
    MLSMemberManagementView(conversationId: "sample-convo-id")
        .environment(AppStateManager.shared)
}

#endif

// MARK: - Wrapper for async manager access

private struct MLSMemberActionsSheetWrapper: View {
    let conversationId: String
    let member: BlueCatbirdMlsDefs.MemberView
    let currentUserDid: String
    let isCurrentUserAdmin: Bool
    let isCurrentUserCreator: Bool
    let appState: AppState

    @State private var conversationManager: MLSConversationManager?

    var body: some View {
        Group {
            if let conversationManager = conversationManager {
                MLSMemberActionsSheet(
                    conversationId: conversationId,
                    member: member,
                    currentUserDid: currentUserDid,
                    isCurrentUserAdmin: isCurrentUserAdmin,
                    isCurrentUserCreator: isCurrentUserCreator,
                    conversationManager: conversationManager
                )
            } else {
                ProgressView("Loading...")
            }
        }
        .task {
            conversationManager = await appState.getMLSConversationManager()
        }
    }
}

extension BlueCatbirdMlsDefs.MemberView: Identifiable {
    public var id: String {
        did.description
    }
}
