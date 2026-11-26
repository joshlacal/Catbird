import SwiftUI
import Petrel
import NukeUI

/// Sheet for confirming blocking an account, with mutual group chat inspection, member removal, and leave actions.
struct BlockAccountView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    
    let profile: AppBskyActorDefs.ProfileViewBasic
    let mlsAffectedConvoCount: Int
    /// Performs the block; returns whether it was saved.
    let onConfirmBlock: () async -> Bool
    
    @State private var mutualGroups: [ChatBskyConvoDefs.ConvoView] = []
    @State private var isLoading: Bool = true
    @State private var isLoadingMore: Bool = false
    @State private var nextCursor: String? = nil
    @State private var errorMessage: String? = nil
    @State private var mutualGroupsLoadError: String? = nil
    @State private var isFeatureUnavailable: Bool = false
    @State private var actionInProgressConvoId: String? = nil
    @State private var isBlocking: Bool = false
    
    private var viewerDID: String {
        appState.userDID ?? ""
    }
    
    var body: some View {
        NavigationStack {
            List {
                profileHeaderSection
                
                if mlsAffectedConvoCount > 0 {
                    mlsWarningSection
                }
                
                mutualGroupsSection
                
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.red)
                    }
                }
                
                blockActionSection
            }
            .scrollContentBackground(.hidden)
            .themedGroupedBackground(appState.themeManager, appSettings: appState.appSettings)
            .navigationTitle("Block Account")
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isBlocking)
                }
            }
            .task {
                await loadMutualGroups()
            }
        }
    }
    
    // MARK: - Sections
    
    private var profileHeaderSection: some View {
        Section {
            HStack(spacing: 12) {
                if let avatarURL = profile.avatar?.url {
                    LazyImage(url: avatarURL) { state in
                        if let image = state.image {
                            image
                                .resizable()
                                .scaledToFill()
                        } else {
                            Circle().fill(Color.secondary.opacity(0.2))
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
                } else {
                    Circle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 48, height: 48)
                        .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName ?? "@\(profile.handle.description)")
                        .appFont(AppTextRole.headline)
                    Text(verbatim: "@\(profile.handle.description)")
                        .appFont(AppTextRole.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            
            Text("Blocking this user will prevent them from seeing your posts, following you, or mentioning you. They will not be notified that you blocked them.")
                .appFont(AppTextRole.footnote)
                .foregroundStyle(.secondary)
        }
    }
    
    private var mlsWarningSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .appFont(AppTextRole.title3)
                    .foregroundStyle(.orange)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Encrypted Chat Notice")
                        .appFont(AppTextRole.subheadline)
                        .fontWeight(.semibold)
                    Text("You share \(mlsAffectedConvoCount) end-to-end encrypted conversations with this user. Blocking them will cause you to leave those conversations.", comment: "Warning when blocking a user with shared E2EE chats — variable is the number of conversations.")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
    
    private var mutualGroupsSection: some View {
        Section(header: Text("Mutual Group Chats"), footer: Text("If you share group chats, you can remove them from groups you own or leave the group before blocking.")) {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 8)
            } else if let loadError = mutualGroupsLoadError, mutualGroups.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: isFeatureUnavailable ? "info.circle" : "exclamationmark.triangle.fill")
                            .foregroundStyle(isFeatureUnavailable ? Color.secondary : Color.orange)
                        Text(loadError)
                            .appFont(AppTextRole.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    
                    if !isFeatureUnavailable {
                        Button("Retry") {
                            Task { await loadMutualGroups() }
                        }
                        .buttonStyle(.catbird(.tonal, size: .sm))
                    }
                }
                .padding(.vertical, 4)
            } else if mutualGroups.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text("No shared group chats")
                        .appFont(AppTextRole.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(mutualGroups, id: \.id) { convo in
                    mutualGroupRow(convo: convo)
                }
                
                if let loadError = mutualGroupsLoadError {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(loadError)
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        if !isFeatureUnavailable {
                            Button("Retry") {
                                Task { await loadMutualGroups() }
                            }
                            .buttonStyle(.catbird(.tonal, size: .sm))
                        }
                    }
                    .padding(.vertical, 2)
                }
                
                if let cursor = nextCursor, !cursor.isEmpty {
                    Button {
                        Task { await loadMoreMutualGroups() }
                    } label: {
                        if isLoadingMore {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                        } else {
                            Text("Load More Groups")
                                .appFont(AppTextRole.subheadline)
                        }
                    }
                }
            }
        }
    }
    
    private func mutualGroupRow(convo: ChatBskyConvoDefs.ConvoView) -> some View {
        let isOwner = isViewerOwner(of: convo)
        let isActioning = actionInProgressConvoId == convo.id
        
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(convoName(convo))
                        .appFont(AppTextRole.body)
                        .fontWeight(.medium)
                    
                    let memberCount = convo.members.count
                    Group {
                        if isOwner {
                            Text("\(memberCount) members • You own this group", comment: "Group chat member count and ownership status — variable is member count.")
                        } else {
                            Text("\(memberCount) members • Member", comment: "Group chat member count and membership status — variable is member count.")
                        }
                    }
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(isOwner ? Color.accentColor : Color.secondary)
                }
                
                Spacer()
                
                if isActioning {
                    ProgressView()
                } else if isOwner {
                    Button("Remove Member") {
                        Task { await removeMember(from: convo) }
                    }
                    .buttonStyle(.catbird(.destructive, size: .sm))
                } else {
                    Button("Leave Group") {
                        Task { await leaveGroup(convo: convo) }
                    }
                    .buttonStyle(.catbird(.tonal, size: .sm))
                    .tint(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private var blockActionSection: some View {
        Section {
            Button(role: .destructive) {
                Task {
                    isBlocking = true
                    errorMessage = nil
                    let blocked = await onConfirmBlock()
                    isBlocking = false
                    if blocked {
                        dismiss()
                    } else {
                        errorMessage = String(localized: "Couldn’t block @\(profile.handle.description). Check your connection and try again.", comment: "Error when blocking an account fails — variable is the user's handle.")
                    }
                }
            } label: {
                if isBlocking {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else {
                    Text("Block @\(profile.handle.description)", comment: "Destructive button to block an account — variable is the user's handle.")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(isBlocking)
        }
    }
    
    // MARK: - Helpers & Data Loading
    
    private func isViewerOwner(of convo: ChatBskyConvoDefs.ConvoView) -> Bool {
        guard !viewerDID.isEmpty,
              let viewerMember = convo.members.first(where: { $0.did.didString() == viewerDID }) else {
            return false
        }
        if case .chatBskyActorDefsGroupConvoMember(let groupMember) = viewerMember.kind {
            return groupMember.role.rawValue == ChatBskyActorDefs.MemberRole.owner.rawValue
        }
        return false
    }
    
    private func convoName(_ convo: ChatBskyConvoDefs.ConvoView) -> String {
        if case .chatBskyConvoDefsGroupConvo(let group) = convo.kind, !group.name.isEmpty {
            return group.name
        }
        let otherMembers = convo.members.filter { $0.did.didString() != viewerDID }
        let names = otherMembers.prefix(3).map { $0.displayName ?? "@\($0.handle.description)" }
        let combined = names.joined(separator: ", ")
        return combined.isEmpty ? String(localized: "Group Chat", comment: "Fallback title for an unnamed group chat.") : combined
    }
    
    private func loadMutualGroups() async {
        isLoading = true
        mutualGroupsLoadError = nil
        isFeatureUnavailable = false
        
        let loadFailureMessage = String(localized: "Couldn’t check for shared group chats.", comment: "Error when checking mutual group chats before blocking fails.")
        guard let client = appState.atProtoClient else {
            isLoading = false
            mutualGroupsLoadError = loadFailureMessage
            return
        }
        
        do {
            let input = ChatBskyGroupListMutualGroups.Parameters(subject: profile.did)
            let (code, data) = try await client.chat.bsky.group.listMutualGroups(input: input)
            
            if code >= 200 && code < 300, let data = data {
                self.mutualGroups = data.convos
                self.nextCursor = data.cursor
                self.mutualGroupsLoadError = nil
            } else if code == 401 || code == 403 || code == 501 {
                self.isFeatureUnavailable = true
                self.mutualGroupsLoadError = loadFailureMessage
            } else {
                self.mutualGroupsLoadError = loadFailureMessage
            }
        } catch {
            let desc = error.localizedDescription
            if desc.localizedCaseInsensitiveContains("unsupported") ||
               desc.localizedCaseInsensitiveContains("unauthorized") ||
               desc.localizedCaseInsensitiveContains("forbidden") ||
               desc.localizedCaseInsensitiveContains("scope") {
                self.isFeatureUnavailable = true
                self.mutualGroupsLoadError = loadFailureMessage
            } else {
                self.mutualGroupsLoadError = loadFailureMessage
            }
        }
        
        isLoading = false
    }
    
    private func loadMoreMutualGroups() async {
        guard let cursor = nextCursor, !cursor.isEmpty, !isLoadingMore else { return }
        isLoadingMore = true
        
        guard let client = appState.atProtoClient else {
            isLoadingMore = false
            return
        }
        
        do {
            let input = ChatBskyGroupListMutualGroups.Parameters(subject: profile.did, cursor: cursor)
            let (code, data) = try await client.chat.bsky.group.listMutualGroups(input: input)
            
            if code >= 200 && code < 300, let data = data {
                let existingIDs = Set(self.mutualGroups.map { $0.id })
                let newConvos = data.convos.filter { !existingIDs.contains($0.id) }
                self.mutualGroups.append(contentsOf: newConvos)
                self.nextCursor = data.cursor
            } else {
                errorMessage = String(localized: "Couldn’t load more group chats. Try again.", comment: "Error when paginating mutual group chats fails.")
            }
        } catch {
            errorMessage = UserFacingError.message(for: error, action: "load more group chats")
        }
        
        isLoadingMore = false
    }
    
    private func removeMember(from convo: ChatBskyConvoDefs.ConvoView) async {
        actionInProgressConvoId = convo.id
        errorMessage = nil
        
        // Optimistic removal
        let originalGroups = mutualGroups
        mutualGroups.removeAll { $0.id == convo.id }
        
        do {
            try await appState.chatManager.removeGroupMember(convoId: convo.id, memberDID: profile.did.didString())
        } catch {
            // Restore on error
            mutualGroups = originalGroups
            errorMessage = UserFacingError.message(for: error, action: "remove this member")
        }
        
        actionInProgressConvoId = nil
    }
    
    private func leaveGroup(convo: ChatBskyConvoDefs.ConvoView) async {
        actionInProgressConvoId = convo.id
        errorMessage = nil
        
        // Optimistic removal
        let originalGroups = mutualGroups
        mutualGroups.removeAll { $0.id == convo.id }
        
        let result = await appState.chatManager.leaveConversation(convoId: convo.id)
        switch result {
        case .success:
            break
        case .ownerMustLockFirst:
            mutualGroups = originalGroups
            errorMessage = String(localized: "You must lock this group before leaving because you are the owner.", comment: "Error when group owner attempts to leave without locking the group.")
        case .failure:
            mutualGroups = originalGroups
            errorMessage = String(localized: "Couldn’t leave this group. Try again.", comment: "Error when leaving a mutual group chat fails.")
        }
        
        actionInProgressConvoId = nil
    }
}
