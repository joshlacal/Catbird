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
                    
                    NavigationLink(destination: ListsManagerView()) {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Moderation Lists")
                                Text("Manage blocking and muting lists")
                                    .appFont(AppTextRole.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "list.bullet.clipboard")
                                .foregroundStyle(.purple)
                        }
                    }
                    
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
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Adult Content", isOn: $adultContentEnabled)
                            .tint(.blue)
                            // Only allow turning it off here. Enabling must be done in Bluesky.
                            .disabled(!adultContentEnabled)
                            .onChange(of: adultContentEnabled) {
                                updateAdultContentSetting()
                            }
                        if !adultContentEnabled {
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                                Text("To enable adult content, turn it on in the official Bluesky app. You can turn it off here at any time.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
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
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
        .appDisplayScale(appState: appState)
        .contrastAwareBackground(appState: appState, defaultColor: Color.systemBackground)
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
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
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
                        .background(Color.systemGray5)
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

// Moderation lists now use the main ListsManagerView for full functionality

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
                    #if os(iOS)
                    .autocapitalization(.none)
                    #endif
                    .autocorrectionDisabled(true)
                
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
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
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
                        .background(Color.systemGray6)
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
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
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
                .background(Color.systemGray6)
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
                        .fill(Color.systemBackground.opacity(0.9))
                        .shadow(radius: 4)
                )
            }
            .transition(.opacity)
            
        case .hide:
            // Hidden overlay
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.systemGray5)
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
