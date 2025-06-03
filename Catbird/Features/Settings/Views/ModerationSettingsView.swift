import SwiftUI
import Petrel

struct ModerationSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    // Adult content toggle
    @State private var adultContentEnabled = false
    
    // Content label preferences
    @State private var adultContentVisibility = ContentVisibility.warn
    @State private var suggestiveContentVisibility = ContentVisibility.warn
    @State private var violentContentVisibility = ContentVisibility.warn
    @State private var nudityContentVisibility = ContentVisibility.warn
    
    // Labeler preferences
    @State private var labelers: [LabelerInfo] = []
    @State private var isLoadingLabelers = false
    
    // Muted accounts
    @State private var showMutedAccounts = false
    @State private var mutedAccounts: [MutedAccount] = []
    @State private var isLoadingMutedAccounts = false
    
    // Blocked accounts
    @State private var showBlockedAccounts = false
    @State private var blockedAccounts: [BlockedAccount] = []
    @State private var isLoadingBlockedAccounts = false
    
    struct MutedAccount: Identifiable {
        let id: String
        let did: String
        let handle: String
        let displayName: String?
        let avatar: URL?
    }
    
    struct BlockedAccount: Identifiable {
        let id: String
        let did: String
        let handle: String
        let displayName: String?
        let avatar: URL?
    }
    
    struct LabelerInfo: Identifiable {
        let id: String
        let name: String
        let description: String?
        let isEnabled: Bool
    }
    
    var body: some View {
        Form {
            if isLoading {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            } else {
                // Moderation Tools Section
                Section("Moderation Tools") {
                    NavigationLink(destination: MuteWordsSettingsView()) {
                        Label {
                            Text("Muted Words & Tags")
                        } icon: {
                            Image(systemName: "speaker.slash.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    
                    // NavigationLink(destination: ModerationListsView()) {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Moderation Lists")
                                Text("Coming soon - shared blocking and muting lists")
                                    .appFont(AppTextRole.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "list.bullet.clipboard")
                                .foregroundStyle(.purple)
                        }
                    // }
                    
                    NavigationLink(destination: ModerationListView(accounts: $mutedAccounts, isLoading: $isLoadingMutedAccounts, title: "Muted Accounts", isBlocked: false)) {
                        Label {
                            Text("Muted Accounts")
                        } icon: {
                            Image(systemName: "speaker.slash.circle")
                                .foregroundStyle(.gray)
                        }
                    }
                    .task {
                        if showMutedAccounts {
                            await loadMutedAccounts()
                        } else {
                            showMutedAccounts = true
                        }
                    }
                    
                    NavigationLink(destination: ModerationListView(accounts: $blockedAccounts, isLoading: $isLoadingBlockedAccounts, title: "Blocked Accounts", isBlocked: true)) {
                        Label {
                            Text("Blocked Accounts")
                        } icon: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.red)
                        }
                    }
                    .task {
                        if showBlockedAccounts {
                            await loadBlockedAccounts()
                        } else {
                            showBlockedAccounts = true
                        }
                    }
                }
                
                // Content Filters Section
                Section("Content Filters") {
                    Toggle("Adult Content", isOn: $adultContentEnabled)
                        .tint(.blue)
                        .onChange(of: adultContentEnabled) { 
                            updateAdultContentSetting()
                        }
                    
                    if adultContentEnabled {
                        ContentVisibilitySelector(
                            title: "Adult Content",
                            description: "Explicit sexual images, videos, text, or audio",
                            selection: $adultContentVisibility
                        )
                        .onChange(of: adultContentVisibility) {
                            updateContentLabelPreference()
                        }
                        
                        ContentVisibilitySelector(
                            title: "Sexually Suggestive",
                            description: "Sexualized content that doesn't show explicit sexual activity",
                            selection: $suggestiveContentVisibility
                        )
                        .onChange(of: suggestiveContentVisibility) {
                            updateContentLabelPreference()
                        }
                        
                        ContentVisibilitySelector(
                            title: "Graphic Content",
                            description: "Images, videos, or text describing violence, blood, or injury",
                            selection: $violentContentVisibility
                        )
                        .onChange(of: violentContentVisibility) {
                            updateContentLabelPreference()
                        }
                        
                        ContentVisibilitySelector(
                            title: "Non-Sexual Nudity",
                            description: "Artistic, educational, or non-sexualized images of nudity",
                            selection: $nudityContentVisibility
                        )
                        .onChange(of: nudityContentVisibility) {
                            updateContentLabelPreference()
                        }
                    }
                }
                
                // Content Preview Section
                ContentPreviewSection(
                    adultContentEnabled: adultContentEnabled,
                    adultContentVisibility: adultContentVisibility,
                    suggestiveContentVisibility: suggestiveContentVisibility,
                    violentContentVisibility: violentContentVisibility,
                    nudityContentVisibility: nudityContentVisibility
                )
                
                // Content Labelers Section
                Section("Content Labelers") {
                    if isLoadingLabelers {
                        ProgressView()
                    } else if labelers.isEmpty {
                        Text("No labelers available")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(labelers) { labeler in
                            NavigationLink {
                                LabelerDetailView(labeler: labeler)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(labeler.name)
                                        
                                        if let description = labeler.description {
                                            Text(description)
                                                .appFont(AppTextRole.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    
                                    Spacer()
                                    
                                    if labeler.isEnabled {
                                        Text("Enabled")
                                            .appFont(AppTextRole.caption)
                                            .fontWeight(.medium)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.green.opacity(0.2))
                                            .foregroundStyle(.green)
                                            .cornerRadius(4)
                                    }
                                }
                            }
                        }
                        
                        NavigationLink("Add Labeler", destination: AddLabelerView())
                    }
                }
                
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .appFont(AppTextRole.caption)
                    }
                }
                
                Section("About Moderation") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Content filters help you customize your experience. Changes take effect immediately.")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                        
                        Text("Bluesky uses moderation services to help manage content. These preferences control what you'll see in your feeds.")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Moderation")
        .navigationBarTitleDisplayMode(.inline)
        .appDisplayScale(appState: appState)
        .contrastAwareBackground(appState: appState, defaultColor: Color(.systemBackground))
        .task {
            await loadPreferences()
            await loadLabelers()
        }
        .refreshable {
            await loadPreferences()
            await loadLabelers()
            
            if showMutedAccounts {
                await loadMutedAccounts()
            }
            
            if showBlockedAccounts {
                await loadBlockedAccounts()
            }
        }
    }
    
    private func loadPreferences() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let preferences = try await appState.preferencesManager.getPreferences()
            
            // Get adult content setting
            adultContentEnabled = preferences.adultContentEnabled
            appState.isAdultContentEnabled = adultContentEnabled
            
            // Get content label preferences
            let contentLabelPrefs = preferences.contentLabelPrefs
            
            // Map content label preferences to our UI state
            adultContentVisibility = ContentFilterManager.getVisibilityForLabel(
                label: "nsfw", preferences: contentLabelPrefs)
            
            suggestiveContentVisibility = ContentFilterManager.getVisibilityForLabel(
                label: "suggestive", preferences: contentLabelPrefs)
            
            violentContentVisibility = ContentFilterManager.getVisibilityForLabel(
                label: "graphic", preferences: contentLabelPrefs)
            
            nudityContentVisibility = ContentFilterManager.getVisibilityForLabel(
                label: "nudity", preferences: contentLabelPrefs)
            
        } catch {
            errorMessage = "Failed to load content preferences: \(error.localizedDescription)"
        }
    }
    
    private func loadLabelers() async {
        isLoadingLabelers = true
        defer { isLoadingLabelers = false }
        
        guard let client = appState.atProtoClient else {
            errorMessage = "Client not available"
            return
        }
        
        do {
            // Get labelers from server
            let (code, data) = try await client.app.bsky.labeler.getServices(
                input: .init(dids: [])
            )
            
            if code != 200 || data == nil {
                errorMessage = "Failed to load labelers"
                return
            }
            
            // Get enabled labelers from preferences
            let preferences = try await appState.preferencesManager.getPreferences()
            let enabledLabelerDIDs = Set(preferences.labelers.map { $0.did })
            
            // Transform to our model
            var labelerList: [LabelerInfo] = []
            
            for service in data!.views {
                // Handle different view types in the union
                switch service {
                case .appBskyLabelerDefsLabelerView(let view):
                    labelerList.append(LabelerInfo(
                        id: view.creator.did.didString(),
                        name: view.creator.displayName ?? view.creator.handle.description,
                        description: nil,
                        isEnabled: enabledLabelerDIDs.contains(try DID(didString: view.creator.did.didString()))
                    ))
                case .appBskyLabelerDefsLabelerViewDetailed(let view):
                    labelerList.append(LabelerInfo(
                        id: view.creator.did.didString(),
                        name: view.creator.displayName ?? view.creator.handle.description,
                        description: view.creator.description,
                        isEnabled: enabledLabelerDIDs.contains(try DID(didString: view.creator.did.didString()))
                    ))
                case .unexpected:
                    continue
                }
            }
            
            self.labelers = labelerList
            
        } catch {
            errorMessage = "Failed to load labelers: \(error.localizedDescription)"
        }
    }
    
    private func loadMutedAccounts() async {
        isLoadingMutedAccounts = true
        defer { isLoadingMutedAccounts = false }
        
        guard let client = appState.atProtoClient else {
            errorMessage = "Client not available"
            return
        }
        
        do {
            let (code, data) = try await client.app.bsky.graph.getMutes(
                input: .init(limit: 100)
            )
            
            if code != 200 || data == nil {
                errorMessage = "Failed to load muted accounts"
                return
            }
            
            var accounts: [MutedAccount] = []
            
            for mute in data!.mutes {
                let didString = mute.did.didString()
                accounts.append(MutedAccount(
                    id: didString,
                    did: didString,
                    handle: mute.handle.description,
                    displayName: mute.displayName,
                    avatar: mute.avatar?.url
                ))
            }
            
            mutedAccounts = accounts
            
        } catch {
            errorMessage = "Failed to load muted accounts: \(error.localizedDescription)"
        }
    }
    
    private func loadBlockedAccounts() async {
        isLoadingBlockedAccounts = true
        defer { isLoadingBlockedAccounts = false }
        
        guard let client = appState.atProtoClient else {
            errorMessage = "Client not available"
            return
        }
        
        do {
            let (code, data) = try await client.app.bsky.graph.getBlocks(
                input: .init(limit: 100)
            )
            
            if code != 200 || data == nil {
                errorMessage = "Failed to load blocked accounts"
                return
            }
            
            var accounts: [BlockedAccount] = []
            
            for block in data!.blocks {
                let didString = block.did.didString()
                accounts.append(BlockedAccount(
                    id: didString,
                    did: didString,
                    handle: block.handle.description,
                    displayName: block.displayName,
                    avatar: block.avatar?.url
                ))
            }
            
            blockedAccounts = accounts
            
        } catch {
            errorMessage = "Failed to load blocked accounts: \(error.localizedDescription)"
        }
    }
    
    private func updateAdultContentSetting() {
        Task {
            do {
                // Update both local app state and app settings
                appState.isAdultContentEnabled = adultContentEnabled
                
                // Store in UserDefaults for consistency with AppSettings
                UserDefaults(suiteName: "group.blue.catbird.shared")?.set(adultContentEnabled, forKey: "isAdultContentEnabled")
                
                // Update preferences on server
                try await appState.preferencesManager.updateAdultContentEnabled(adultContentEnabled)
            } catch {
                errorMessage = "Failed to update adult content setting: \(error.localizedDescription)"
            }
        }
    }
    
    private func updateContentLabelPreference() {
        Task {
            do {
                // Create content label preferences array
                var contentLabelPrefs: [ContentLabelPreference] = []
                
                // Add preferences for each content type
                contentLabelPrefs.append(ContentFilterManager.createPreferenceForLabel(
                    label: "nsfw", visibility: adultContentVisibility))
                
                contentLabelPrefs.append(ContentFilterManager.createPreferenceForLabel(
                    label: "suggestive", visibility: suggestiveContentVisibility))
                
                contentLabelPrefs.append(ContentFilterManager.createPreferenceForLabel(
                    label: "graphic", visibility: violentContentVisibility))
                
                contentLabelPrefs.append(ContentFilterManager.createPreferenceForLabel(
                    label: "nudity", visibility: nudityContentVisibility))
                
                // Update preferences on server
                try await appState.preferencesManager.updateContentLabelPreferences(contentLabelPrefs)
            } catch {
                errorMessage = "Failed to save content label preferences: \(error.localizedDescription)"
            }
        }
    }
}

// Note: ProfileBasicInfo protocol is defined in PrivacySecuritySettingsView.swift
// Since it's in the same module, we can use it here

// Extend MutedAccount to conform to ProfileBasicInfo  
extension ModerationSettingsView.MutedAccount: ProfileBasicInfo {}

// Extend BlockedAccount to conform to ProfileBasicInfo
extension ModerationSettingsView.BlockedAccount: ProfileBasicInfo {}

struct ModerationListView<T: Identifiable>: View {
    @Binding var accounts: [T]
    @Binding var isLoading: Bool
    let title: String
    let isBlocked: Bool
    @State private var errorMessage: String?
    @Environment(AppState.self) private var appState
    
    var body: some View {
        List {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            } else if accounts.isEmpty {
                Text("No \(isBlocked ? "blocked" : "muted") accounts")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(accounts) { account in
                    if let accountInfo = account as? (any ProfileBasicInfo) {
                        ModerationAccountRow(
                            id: accountInfo.id,
                            handle: accountInfo.handle,
                            displayName: accountInfo.displayName,
                            avatar: accountInfo.avatar,
                            isBlocked: isBlocked,
                            onRemove: { await removeModerationAction(forId: accountInfo.id) }
                        )
                    }
                }
            }
            
            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .appFont(AppTextRole.caption)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func removeModerationAction(forId id: String) async {
        guard let client = appState.atProtoClient else {
            errorMessage = "Client not available"
            return
        }
        
        // Set loading state
        isLoading = true
        
        do {
            if isBlocked {
                let did = try await client.getDid()
                let input = ComAtprotoRepoDeleteRecord.Input(
                    repo: try ATIdentifier(string: did),
                    collection: try NSID(nsidString: "app.bsky.graph.block"),
                    rkey: try RecordKey(keyString: id)
                )
                                                                
                let response = try await client.com.atproto.repo.deleteRecord(input: input)
                
                if response.responseCode != 200 {
                    errorMessage = "Failed to unblock account"
                    return
                }
            } else {
                // Unmute account
                let input = AppBskyGraphUnmuteActor.Input(actor: try ATIdentifier(string: id))
                let code = try await client.app.bsky.graph.unmuteActor(input: input)
                
                if code != 200 {
                    errorMessage = "Failed to unmute account"
                    return
                }
            }
            
            // Remove from local list using a single approach for both types
            accounts.removeAll { (account: T) -> Bool in
                if let profileInfo = account as? (any ProfileBasicInfo) {
                    return profileInfo.id == id
                }
                return false
            }
            
        } catch {
            errorMessage = "Failed to \(isBlocked ? "unblock" : "unmute") account: \(error.localizedDescription)"
        }
        
        // End loading state
        isLoading = false
    }
}

struct ModerationAccountRow: View {
    let id: String
    let handle: String
    let displayName: String?
    let avatar: URL?
    let isBlocked: Bool
    let onRemove: () async -> Void
    @State private var isPerformingAction = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            ProfileAvatarView(
                url: avatar,
                fallbackText: String(handle.prefix(1).uppercased()),
                size: 40
            )
            
            // Account info
            VStack(alignment: .leading, spacing: 2) {
                if let displayName = displayName {
                    Text(displayName)
                        .fontWeight(.medium)
                }
                
                Text("@\(handle)")
                    .appFont(AppTextRole.callout)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Remove button
            Button {
                isPerformingAction = true
                
                Task {
                    await onRemove()
                    isPerformingAction = false
                }
            } label: {
                if isPerformingAction {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(isBlocked ? "Unblock" : "Unmute")
                        .appFont(AppTextRole.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(.systemGray5))
                        .foregroundStyle(.primary)
                        .cornerRadius(6)
                }
            }
            .disabled(isPerformingAction)
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

/* Temporarily disabled due to AT Protocol compatibility issues
struct ModerationListsView: View {
    @Environment(AppState.self) private var appState
    @State private var moderationLists: [AppBskyGraphDefs.ListView] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingCreateList = false
    
    var body: some View {
        List {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            } else if moderationLists.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "list.bullet.clipboard")
                        .appFont(AppTextRole.largeTitle)
                        .foregroundStyle(.secondary)
                    
                    Text("No Moderation Lists")
                        .appFont(AppTextRole.headline)
                        .fontWeight(.medium)
                    
                    Text("Create moderation lists to block or mute multiple accounts at once. Lists can be shared with others.")
                        .appFont(AppTextRole.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Button("Create List") {
                        showingCreateList = true
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowBackground(Color.clear)
                .padding(.vertical, 40)
            } else {
                ForEach(moderationLists, id: \.uri) { list in
                    NavigationLink(destination: ModerationListDetailView(list: list)) {
                        ModerationListRow(list: list)
                    }
                }
            }
            
            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .appFont(AppTextRole.caption)
                }
            }
        }
        .navigationTitle("Moderation Lists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingCreateList = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task {
            await loadModerationLists()
        }
        .refreshable {
            await loadModerationLists()
        }
        .sheet(isPresented: $showingCreateList) {
            CreateModerationListView { newList in
                moderationLists.append(newList)
            }
        }
    }
    
    private func loadModerationLists() async {
        isLoading = true
        errorMessage = nil
        
        guard let client = appState.atProtoClient else {
            errorMessage = "Client not available"
            isLoading = false
            return
        }
        
        do {
            guard let currentUserDID = appState.authManager.userDID else {
                errorMessage = "User not authenticated"
                isLoading = false
                return
            }
            
            let params = AppBskyGraphGetLists.Parameters(
                actor: try ATIdentifier(string: currentUserDID),
                limit: 50,
                cursor: nil
            )
            
            let (responseCode, response) = try await client.app.bsky.graph.getLists(input: params)
            
            if responseCode == 200, let lists = response?.lists {
                let filteredLists = lists.filter { list in
                    list.purpose == .appBskyGraphDefsModlist ||
                    list.purpose == .appBskyGraphDefsCuratelist
                }
                moderationLists = filteredLists
            } else {
                errorMessage = "Failed to load moderation lists"
            }
        } catch {
            errorMessage = "Failed to load moderation lists: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
}

struct ModerationListRow: View {
    let list: AppBskyGraphDefs.ListView
    
    var body: some View {
        HStack(spacing: 12) {
            // List icon
            Image(systemName: listIcon)
                .foregroundStyle(listIconColor)
                .appFont(AppTextRole.title2)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(list.name)
                    .appFont(AppTextRole.headline)
                    .fontWeight(.medium)
                
                if let description = list.description, !description.isEmpty {
                    Text(description)
                        .appFont(AppTextRole.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                
                HStack(spacing: 16) {
                    if let itemCount = list.listItemCount {
                        Label("\(itemCount)", systemImage: "person.2")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Label(listPurposeText, systemImage: "shield")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .appFont(AppTextRole.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
    
    private var listIcon: String {
        switch list.purpose {
        case .appBskyGraphDefsModlist:
            return "shield.fill"
        case .appBskyGraphDefsCuratelist:
            return "eye.slash.fill"
        default:
            return "list.bullet"
        }
    }
    
    private var listIconColor: Color {
        switch list.purpose {
        case .appBskyGraphDefsModlist:
            return .red
        case .appBskyGraphDefsCuratelist:
            return .orange
        default:
            return .blue
        }
    }
    
    private var listPurposeText: String {
        switch list.purpose {
        case .appBskyGraphDefsModlist:
            return "Block List"
        case .appBskyGraphDefsCuratelist:
            return "Mute List"
        default:
            return "List"
        }
    }
}

struct ModerationListDetailView: View {
    let list: AppBskyGraphDefs.ListView
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var listItems: [AppBskyGraphDefs.ListItemView] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingDeleteAlert = false
    @State private var isDeleting = false
    @State private var cursor: String?
    
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: listIcon)
                            .foregroundStyle(listIconColor)
                            .appFont(AppTextRole.title)
                            .frame(width: 32)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(list.name)
                                .appFont(AppTextRole.title2)
                                .fontWeight(.bold)
                            
                            Text(listPurposeText)
                                .appFont(AppTextRole.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    if let description = list.description, !description.isEmpty {
                        Text(description)
                            .appFont(AppTextRole.body)
                            .padding(.top, 4)
                    }
                    
                    if let itemCount = list.listItemCount {
                        Text("\(itemCount) accounts")
                            .appFont(AppTextRole.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }
            
            if isLoading {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            } else if listItems.isEmpty {
                Section {
                    Text("No accounts in this list")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section("Accounts") {
                    ForEach(listItems, id: \.uri) { item in
                        ModerationListItemRow(item: item) {
                            await removeItemFromList(item)
                        }
                    }
                }
            }
            
            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .appFont(AppTextRole.caption)
                }
            }
            
            Section {
                Button(role: .destructive) {
                    showingDeleteAlert = true
                } label: {
                    if isDeleting {
                        HStack {
                            Text("Deleting List...")
                            Spacer()
                            ProgressView()
                        }
                    } else {
                        Text("Delete List")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .disabled(isDeleting)
            }
        }
        .navigationTitle("List Details")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadListItems()
        }
        .refreshable {
            await loadListItems()
        }
        .alert("Delete List", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task { await deleteList() }
            }
        } message: {
            Text("Are you sure you want to delete this moderation list? This action cannot be undone.")
        }
    }
    
    private var listIcon: String {
        switch list.purpose {
        case .appBskyGraphDefsModlist:
            return "shield.fill"
        case .appBskyGraphDefsCuratelist:
            return "eye.slash.fill"
        default:
            return "list.bullet"
        }
    }
    
    private var listIconColor: Color {
        switch list.purpose {
        case .appBskyGraphDefsModlist:
            return .red
        case .appBskyGraphDefsCuratelist:
            return .orange
        default:
            return .blue
        }
    }
    
    private var listPurposeText: String {
        switch list.purpose {
        case .appBskyGraphDefsModlist:
            return "Block List"
        case .appBskyGraphDefsCuratelist:
            return "Mute List"
        default:
            return "List"
        }
    }
    
    private func loadListItems() async {
        isLoading = true
        errorMessage = nil
        
        guard let client = appState.atProtoClient else {
            errorMessage = "Client not available"
            isLoading = false
            return
        }
        
        do {
            let params = AppBskyGraphGetList.Parameters(
                list: list.uri,
                limit: 50,
                cursor: cursor
            )
            
            let (responseCode, response) = try await client.app.bsky.graph.getList(input: params)
            
            if responseCode == 200, let items = response?.items {
                if cursor == nil {
                    listItems = items
                } else {
                    listItems.append(contentsOf: items)
                }
                cursor = response?.cursor
            } else {
                errorMessage = "Failed to load list items"
            }
        } catch {
            errorMessage = "Failed to load list items: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
    
    private func removeItemFromList(_ item: AppBskyGraphDefs.ListItemView) async {
        guard let client = appState.atProtoClient else {
            errorMessage = "Client not available"
            return
        }
        
        do {
            let input = ComAtprotoRepoDeleteRecord.Input(
                repo: try ATIdentifier(string: list.creator.did.didString()),
                collection: try NSID(nsidString: "app.bsky.graph.listitem"),
                rkey: try RecordKey(keyString: item.uri.rkey ?? "")
            )
            
            let response = try await client.com.atproto.repo.deleteRecord(input: input)
            
            if response.responseCode == 200 {
                listItems.removeAll { $0.uri == item.uri }
            } else {
                errorMessage = "Failed to remove account from list"
            }
        } catch {
            errorMessage = "Failed to remove account: \(error.localizedDescription)"
        }
    }
    
    private func deleteList() async {
        isDeleting = true
        errorMessage = nil
        
        guard let client = appState.atProtoClient else {
            errorMessage = "Client not available"
            isDeleting = false
            return
        }
        
        do {
            let input = ComAtprotoRepoDeleteRecord.Input(
                repo: try ATIdentifier(string: list.creator.did.didString()),
                collection: try NSID(nsidString: "app.bsky.graph.list"),
                rkey: try RecordKey(keyString: list.uri.rkey ?? "")
            )
            
            let response = try await client.com.atproto.repo.deleteRecord(input: input)
            
            if response.responseCode == 200 {
                dismiss()
            } else {
                errorMessage = "Failed to delete list"
            }
        } catch {
            errorMessage = "Failed to delete list: \(error.localizedDescription)"
        }
        
        isDeleting = false
    }
}

struct ModerationListItemRow: View {
    let item: AppBskyGraphDefs.ListItemView
    let onRemove: () async -> Void
    @State private var isRemoving = false
    
    var body: some View {
        HStack(spacing: 12) {
            ProfileAvatarView(
                url: item.subject.avatar?.url,
                fallbackText: String(item.subject.handle.description.prefix(1).uppercased()),
                size: 40
            )
            
            VStack(alignment: .leading, spacing: 2) {
                if let displayName = item.subject.displayName {
                    Text(displayName)
                        .appFont(AppTextRole.headline)
                        .fontWeight(.medium)
                }
                
                Text("@\(item.subject.handle)")
                    .appFont(AppTextRole.callout)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button {
                isRemoving = true
                Task {
                    await onRemove()
                    isRemoving = false
                }
            } label: {
                if isRemoving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Remove")
                        .appFont(AppTextRole.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(.systemGray5))
                        .foregroundStyle(.primary)
                        .cornerRadius(6)
                }
            }
            .disabled(isRemoving)
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

struct CreateModerationListView: View {
    let onListCreated: (AppBskyGraphDefs.ListView) -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    
    @State private var listName = ""
    @State private var listDescription = ""
    @State private var selectedPurpose: ListPurpose = .block
    @State private var isCreating = false
    @State private var errorMessage: String?
    
    enum ListPurpose: String, CaseIterable {
        case block = "app.bsky.graph.defs#modlist"
        case mute = "app.bsky.graph.defs#curatelist"
        
        var displayName: String {
            switch self {
            case .block:
                return "Block List"
            case .mute:
                return "Mute List"
            }
        }
        
        var description: String {
            switch self {
            case .block:
                return "Accounts on this list will be blocked"
            case .mute:
                return "Accounts on this list will be muted"
            }
        }
        
        var icon: String {
            switch self {
            case .block:
                return "shield.fill"
            case .mute:
                return "eye.slash.fill"
            }
        }
        
        var color: Color {
            switch self {
            case .block:
                return .red
            case .mute:
                return .orange
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("List Information") {
                    TextField("List Name", text: $listName)
                        .autocorrectionDisabled()
                    
                    TextField("Description (optional)", text: $listDescription, axis: .vertical)
                        .lineLimit(3...6)
                        .autocorrectionDisabled()
                }
                
                Section("List Type") {
                    ForEach(ListPurpose.allCases, id: \.self) { purpose in
                        Button {
                            selectedPurpose = purpose
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: purpose.icon)
                                    .foregroundStyle(purpose.color)
                                    .frame(width: 24)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(purpose.displayName)
                                        .appFont(AppTextRole.headline)
                                        .foregroundStyle(.primary)
                                    
                                    Text(purpose.description)
                                        .appFont(AppTextRole.callout)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                                
                                if selectedPurpose == purpose {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .appFont(AppTextRole.caption)
                    }
                }
            }
            .navigationTitle("Create List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await createList() }
                    } label: {
                        if isCreating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Create")
                        }
                    }
                    .disabled(listName.isEmpty || isCreating)
                }
            }
        }
    }
    
    private func createList() async {
        isCreating = true
        errorMessage = nil
        
        guard let client = appState.atProtoClient else {
            errorMessage = "Client not available"
            isCreating = false
            return
        }
        
        do {
            guard let currentUserDID = appState.authManager.userDID else {
                errorMessage = "User not authenticated"
                isCreating = false
                return
            }
            
            let listRecord = AppBskyGraphList(
                purpose: selectedPurpose.rawValue,
                name: listName,
                description: listDescription.isEmpty ? nil : listDescription,
                avatar: nil,
                labels: nil,
                createdAt: Date()
            )
            
            let input = ComAtprotoRepoPutRecord.Input(
                repo: try ATIdentifier(string: currentUserDID),
                collection: try NSID(nsidString: "app.bsky.graph.list"),
                rkey: nil,
                validate: true,
                record: .appBskyGraphList(listRecord),
                swapCommit: nil,
                swapRecord: nil
            )
            
            let (responseCode, response) = try await client.com.atproto.repo.putRecord(input: input)
            
            if responseCode == 200, let response = response {
                // Create a ListView object for the UI
                let newList = AppBskyGraphDefs.ListView(
                    uri: response.uri,
                    cid: response.cid,
                    name: listName,
                    purpose: selectedPurpose == .block ? .appBskyGraphDefsModlist : .appBskyGraphDefsCuratelist,
                    description: listDescription.isEmpty ? nil : listDescription,
                    descriptionFacets: nil,
                    avatar: nil,
                    listItemCount: 0,
                    labels: nil,
                    viewer: nil,
                    indexedAt: Date(),
                    creator: AppBskyActorDefs.ProfileView(
                        did: try DID(didString: currentUserDID),
                        handle: Handle(handle: ""), // Will be filled by the parent view
                        displayName: nil,
                        description: nil,
                        avatar: nil,
                        associated: nil,
                        indexedAt: Date(),
                        createdAt: Date(),
                        labels: nil,
                        viewer: nil
                    )
                )
                
                onListCreated(newList)
                dismiss()
            } else {
                errorMessage = "Failed to create list"
            }
        } catch {
            errorMessage = "Failed to create list: \(error.localizedDescription)"
        }
        
        isCreating = false
    }
}
*/ // End of temporarily disabled moderation lists

struct AddLabelerView: View {
    @State private var labelerDID = ""
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        Form {
            Section("Add Labeler") {
                TextField("Labeler DID", text: $labelerDID)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                
                Text("Enter the DID of the content labeler you want to add to your moderation settings.")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
            }
            
            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .appFont(AppTextRole.caption)
                }
            }
            
            if let success = successMessage {
                Section {
                    Text(success)
                        .foregroundStyle(.green)
                        .appFont(AppTextRole.caption)
                }
            }
            
            Section {
                Button {
                    addLabeler()
                } label: {
                    if isAdding {
                        HStack {
                            Text("Adding...")
                            Spacer()
                            ProgressView()
                        }
                    } else {
                        Text("Add Labeler")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .disabled(isAdding || labelerDID.isEmpty)
            }
        }
        .navigationTitle("Add Labeler")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func addLabeler() {
        isAdding = true
        errorMessage = nil
        successMessage = nil
        
        Task {
            do {
                let did = try DID(didString: labelerDID)
                let labelerPreference = LabelerPreference(did: did)
                try await appState.preferencesManager.addLabeler(did)
                
                successMessage = "Labeler added successfully"
                
                // Clear the input field
                labelerDID = ""
                
                // Dismiss after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    dismiss()
                }
            } catch {
                errorMessage = "Failed to add labeler: \(error.localizedDescription)"
            }
            
            isAdding = false
        }
    }
}

struct LabelerDetailView: View {
    let labeler: ModerationSettingsView.LabelerInfo
    @State private var isEnabled: Bool
    @State private var isUpdating = false
    @State private var errorMessage: String?
    @Environment(AppState.self) private var appState
    
    init(labeler: ModerationSettingsView.LabelerInfo) {
        self.labeler = labeler
        self._isEnabled = State(initialValue: labeler.isEnabled)
    }
    
    var body: some View {
        Form {
            Section {
                Toggle("Enable Labeler", isOn: $isEnabled)
                    .onChange(of: isEnabled) {
                        updateLabelerStatus()
                    }
                    .disabled(isUpdating)
            }
            
            Section("Labeler Information") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Name")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                    
                    Text(labeler.name)
                                        .appFont(AppTextRole.body)
                    
                    Divider()
                        .padding(.vertical, 4)
                    
                    Text("DID")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                    
                    Text(labeler.id)
                        .appFont(AppTextRole.caption)
                        .fontWeight(.medium)
                        .padding(8)
                        .background(Color(.systemGray6))
                        .cornerRadius(6)
                        .textSelection(.enabled)
                    
                    if let description = labeler.description {
                        Divider()
                            .padding(.vertical, 4)
                        
                        Text("Description")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                        
                        Text(description)
                                            .appFont(AppTextRole.body)
                    }
                }
                .padding(.vertical, 4)
            }
            
            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .appFont(AppTextRole.caption)
                }
            }
            
            Section {
                Button(role: .destructive) {
                    removeLabeler()
                } label: {
                    if isUpdating {
                        HStack {
                            Text("Removing...")
                            Spacer()
                            ProgressView()
                        }
                    } else {
                        Text("Remove Labeler")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .foregroundStyle(.red)
                    }
                }
                .disabled(isUpdating)
            }
        }
        .navigationTitle("Labeler Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func updateLabelerStatus() {
        isUpdating = true
        errorMessage = nil
        
        Task {
            do {
                if isEnabled {
                    try await appState.preferencesManager.addLabeler(DID(didString: labeler.id))
                } else {
                    try await appState.preferencesManager.removeLabeler(DID(didString: labeler.id))
                }
            } catch {
                // Revert toggle if there's an error
                isEnabled = !isEnabled
                errorMessage = "Failed to update labeler status: \(error.localizedDescription)"
            }
            
            isUpdating = false
        }
    }
    
    private func removeLabeler() {
        isUpdating = true
        errorMessage = nil
        
        Task {
            do {
                try await appState.preferencesManager.removeLabeler(try DID(didString: labeler.id))
                isEnabled = false
            } catch {
                errorMessage = "Failed to remove labeler: \(error.localizedDescription)"
            }
            
            isUpdating = false
        }
    }
}

// MARK: - Content Preview Components

struct ContentPreviewSection: View {
    let adultContentEnabled: Bool
    let adultContentVisibility: ContentVisibility
    let suggestiveContentVisibility: ContentVisibility
    let violentContentVisibility: ContentVisibility
    let nudityContentVisibility: ContentVisibility
    
    var body: some View {
        Section("Content Preview") {
            VStack(spacing: 12) {
                Text("See how your moderation settings affect content display")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                if adultContentEnabled {
                    // Adult Content Preview
                    ContentPreviewView(
                        label: "Adult Content",
                        icon: "flame.fill",
                        iconColor: .red,
                        contentVisibility: adultContentVisibility,
                        sampleText: "This post contains adult content",
                        showImage: true
                    )
                    
                    // Suggestive Content Preview
                    ContentPreviewView(
                        label: "Sexually Suggestive",
                        icon: "eye.trianglebadge.exclamationmark",
                        iconColor: .orange,
                        contentVisibility: suggestiveContentVisibility,
                        sampleText: "This post contains suggestive content",
                        showImage: true
                    )
                    
                    // Violent Content Preview
                    ContentPreviewView(
                        label: "Graphic Content",
                        icon: "exclamationmark.triangle.fill",
                        iconColor: .red,
                        contentVisibility: violentContentVisibility,
                        sampleText: "This post contains graphic violence",
                        showImage: true
                    )
                    
                    // Nudity Content Preview
                    ContentPreviewView(
                        label: "Non-Sexual Nudity",
                        icon: "figure.stand",
                        iconColor: .yellow,
                        contentVisibility: nudityContentVisibility,
                        sampleText: "This post contains artistic nudity",
                        showImage: true
                    )
                } else {
                    Text("Enable adult content to see preview examples")
                        .appFont(AppTextRole.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

struct ContentPreviewView: View {
    let label: String
    let icon: String
    let iconColor: Color
    let contentVisibility: ContentVisibility
    let sampleText: String
    let showImage: Bool
    
    @State private var isRevealed = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Label
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .appFont(AppTextRole.caption)
                
                Text(label)
                    .appFont(AppTextRole.caption)
                    .fontWeight(.medium)
                
                Spacer()
                
                // Visibility Badge
                Text(contentVisibility.rawValue.capitalized)
                    .appFont(AppTextRole.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(visibilityBadgeColor)
                    .foregroundStyle(visibilityBadgeTextColor)
                    .cornerRadius(4)
            }
            
            // Content Preview
            ZStack {
                // Base content
                HStack(spacing: 12) {
                    // Mock image
                    if showImage {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 60, height: 60)
                            .overlay(
                                Image(systemName: "photo")
                                    .foregroundStyle(.gray)
                            )
                    }
                    
                    // Mock text
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Example User")
                            .appFont(AppTextRole.callout)
                            .fontWeight(.medium)
                        
                        Text(sampleText)
                            .appFont(AppTextRole.callout)
                            .foregroundStyle(.primary)
                        
                        Text("2 hours ago")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                }
                .padding(12)
                .background(Color(.systemGray6))
                .cornerRadius(10)
                
                // Moderation overlay
                if contentVisibility != .show && !isRevealed {
                    moderationOverlay
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private var moderationOverlay: some View {
        switch contentVisibility {
        case .warn:
            // Warning overlay with blur effect
            ZStack {
                // Blur background
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
                
                // Warning content
                VStack(spacing: 8) {
                    Image(systemName: icon)
                        .appFont(AppTextRole.title2)
                        .foregroundStyle(iconColor)
                    
                    Text("Content Warning")
                        .appFont(AppTextRole.caption)
                        .fontWeight(.semibold)
                    
                    Text(label)
                        .appFont(AppTextRole.caption2)
                        .foregroundStyle(.secondary)
                    
                    Button("Show content") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isRevealed = true
                        }
                    }
                    .appFont(AppTextRole.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .cornerRadius(6)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemBackground).opacity(0.9))
                        .shadow(radius: 4)
                )
            }
            .transition(.opacity)
            
        case .hide:
            // Hidden overlay
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.systemGray5))
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "eye.slash.fill")
                            .appFont(AppTextRole.title2)
                            .foregroundStyle(.secondary)
                        
                        Text("Content hidden: \(label)")
                            .appFont(AppTextRole.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        
                        Text("This content is hidden based on your preferences")
                            .appFont(AppTextRole.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                )
            
        case .show:
            EmptyView()
        }
    }
    
    private var visibilityBadgeColor: Color {
        switch contentVisibility {
        case .show:
            return Color.green.opacity(0.2)
        case .warn:
            return Color.orange.opacity(0.2)
        case .hide:
            return Color.red.opacity(0.2)
        }
    }
    
    private var visibilityBadgeTextColor: Color {
        switch contentVisibility {
        case .show:
            return .green
        case .warn:
            return .orange
        case .hide:
            return .red
        }
    }
}

#Preview {
    NavigationStack {
        ModerationSettingsView()
            .environment(AppState.shared)
    }
}
