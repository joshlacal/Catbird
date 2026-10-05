import SwiftUI
import Petrel

struct ModerationSettingsView: View {
    @Environment(AppState.self) private var appState
    let initialFocus: SettingsControlID?
    @State private var isLoading = true
    @State private var hasConfirmedPreferences = false
    @State private var isSavingPreferences = false
    @State private var loadRequest = UUID()
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
    @State private var unavailableLabelers: [String] = []
    @State private var isCleaningUpLabelers = false
    @State private var showingCleanupConfirmation = false
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
    
    init(initialFocus: SettingsControlID? = nil) {
        self.initialFocus = initialFocus
    }

    var body: some View {
        SettingsFocusedForm(initialFocus: hasConfirmedPreferences ? initialFocus
          : initialFocus.map { _ in SettingsControlID(rawValue: "moderation.retryLoad") }, isReady: hasConfirmedPreferences || !isLoading) {
            if isLoading && !hasConfirmedPreferences {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            } else if !hasConfirmedPreferences {
                Section {
                    Text(errorMessage ?? "Your moderation settings couldn’t be loaded.")
                        .foregroundStyle(.secondary)
                    Button("Try Again") { Task { await loadPreferences() } }
                        .settingsControl(.init(rawValue: "moderation.retryLoad"))
                }
            } else {
                if isSavingPreferences {
                    Section { ProgressView("Saving moderation preferences…") }
                }
                // Moderation Tools Section
                Section {
                    SettingsLink(screen: .defaultPostInteractions, summary: "Who can reply to or quote new posts", systemImage: "bubble.left.and.bubble.right", family: .privacy)

                    SettingsLink(screen: .verification, summary: "Badge visibility across the app", systemImage: "checkmark.seal", family: .feeds)

                    NavigationLink {
                        MuteWordsSettingsView()
                    } label: {
                        SettingsNavigationRow(title: "Muted Words & Tags", systemImage: "text.badge.minus", family: .moderation)
                    }
                    .settingsControl(.init(rawValue: "moderation.mutedWords"))

                    SettingsLink(screen: .mutedAccounts, systemImage: "speaker.slash", family: .moderation)
                        .settingsControl(.init(rawValue: "moderation.mutedAccounts"))

                    SettingsLink(screen: .blockedAccounts, systemImage: "person.crop.circle.badge.xmark", family: .moderation)
                        .settingsControl(.init(rawValue: "moderation.blockedAccounts"))
                } header: {
                    Text("Moderation Tools")
                } footer: {
                    Text("To manage your moderation lists, open My Lists from the menu.")
                        .settingsControl(.init(rawValue: "moderation.lists"))
                }
                
                
                // Content Filters Section
                Section("Content Filters") {
                        Toggle("Adult Content", isOn: adultContentBinding)
                            // Only allow turning it off here. Enabling must be done in Bluesky.
                            .disabled(!adultContentEnabled || isSavingPreferences)
                            .settingsControl(.init(rawValue: "moderation.adultContent"))
                        if !adultContentEnabled {
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(.orange)
                                    .appFont(AppTextRole.caption)
                                Text("Adult content can only be turned on at bsky.app in a web browser. You can turn it off here at any time.")
                                    .appFont(AppTextRole.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    
                    if !adultContentEnabled {
                        ForEach([ContentCategory.adult, .suggestive, .nudity]) { category in
                            Label(category.name, systemImage: "lock.fill")
                                .foregroundStyle(.secondary)
                                .settingsControl(.init(rawValue: "moderation.\(category.visibilityKey)"))
                        }
                    }
                    if adultContentEnabled {
                        ContentVisibilitySelector(
                            title: "Adult Content",
                            description: "Explicit sexual images, videos, text, or audio",
                            selection: visibilityBinding(label: "nsfw", value: $adultContentVisibility)
                        )
                        .disabled(isSavingPreferences)
                        .settingsControl(.init(rawValue: "moderation.nsfw"))
                        
                        ContentVisibilitySelector(
                            title: "Sexually Suggestive",
                            description: "Sexualized content that doesn’t show explicit sexual activity",
                            selection: visibilityBinding(label: "suggestive", value: $suggestiveContentVisibility)
                        )
                        .disabled(isSavingPreferences)
                        .settingsControl(.init(rawValue: "moderation.suggestive"))
                        
                        ContentVisibilitySelector(
                            title: "Non-Sexual Nudity",
                            description: "Artistic, educational, or non-sexualized images of nudity",
                            selection: visibilityBinding(label: "nudity", value: $nudityContentVisibility)
                        )
                        .disabled(isSavingPreferences)
                        .settingsControl(.init(rawValue: "moderation.nudity"))
                    }
                }
                
                Section("Graphic Content") {
                        ContentVisibilitySelector(
                            title: "Graphic Content",
                            description: "Images, videos, or text describing violence, blood, or injury",
                            selection: visibilityBinding(label: "graphic", value: $violentContentVisibility)
                        )
                        .disabled(isSavingPreferences)
                        .settingsControl(.init(rawValue: "moderation.graphic"))
                        
                }

                // Content Preview Section
                ContentPreviewSection(
                    adultContentEnabled: adultContentEnabled,
                    adultContentVisibility: adultContentVisibility,
                    suggestiveContentVisibility: suggestiveContentVisibility,
                    violentContentVisibility: violentContentVisibility,
                    nudityContentVisibility: nudityContentVisibility
                )
                
                Section("Moderation Services") {
                    SettingsLink(screen: .labelers, summary: "Services that label posts and accounts", systemImage: "checklist", family: .moderation)
                        .settingsControl(.init(rawValue: "moderation.labelers"))
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
                        
                        Text("Bluesky uses moderation services to help manage content. These preferences control what you’ll see in your feeds.")
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
        .alert("Remove Unavailable Services", isPresented: $showingCleanupConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                Task {
                    await removeUnavailableLabelers()
                }
            }
        } message: {
            Text(unavailableLabelers.count == 1 ? "Remove 1 unavailable moderation service from your subscriptions?" : "Remove \(unavailableLabelers.count) unavailable moderation services from your subscriptions?")
        }
        .task(id: appState.userDID) { await loadPreferences() }
        .refreshable { await loadPreferences() }
    }
    
    private func loadPreferences() async {
        let request = UUID()
        let account = appState.userDID
        let manager = appState.preferencesManager
        loadRequest = request
        isLoading = true
        isSavingPreferences = false
        errorMessage = nil
        defer { if loadRequest == request { isLoading = false } }
        do {
            let preferences = try await manager.refreshSettingsPreferences(expectedAccountDID: account)
            guard loadRequest == request, manager.accountDID == account, appState.userDID == account else { return }
            adultContentEnabled = preferences.adultContentEnabled
            appState.isAdultContentEnabled = adultContentEnabled
            let labels = preferences.contentLabelPrefs
            adultContentVisibility = ContentFilterManager.getVisibilityForLabel(label: "nsfw", preferences: labels)
            suggestiveContentVisibility = ContentFilterManager.getVisibilityForLabel(label: "suggestive", preferences: labels)
            violentContentVisibility = ContentFilterManager.getVisibilityForLabel(label: "graphic", preferences: labels)
            nudityContentVisibility = ContentFilterManager.getVisibilityForLabel(label: "nudity", preferences: labels)
            hasConfirmedPreferences = true
        } catch {
            guard loadRequest == request, manager.accountDID == account else { return }
            if hasConfirmedPreferences {
                errorMessage = UserFacingError.message(for: error, action: "refresh your moderation settings")
            } else {
                errorMessage = UserFacingError.message(for: error, action: "load your moderation settings")
            }
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
            // Get user preferences to find exact subscribed labeler DIDs
            let preferences = try await appState.preferencesManager.getPreferences()
            let subscribedDIDs = preferences.labelers.map { $0.did }
            guard !subscribedDIDs.isEmpty else {
                self.labelers = []
                self.unavailableLabelers = []
                return
            }
            // Get labelers from server
            let (code, data) = try await client.app.bsky.labeler.getServices(
                input: .init(dids: subscribedDIDs, detailed: true)
            )
            
            if code != 200 || data == nil {
                errorMessage = "Failed to load labelers"
                return
            }
            
            let returnedViews = data!.views
            var returnedDIDs = Set<String>()
            var labelerList: [LabelerInfo] = []
            
            for service in returnedViews {
                switch service {
                case .appBskyLabelerDefsLabelerView(let view):
                    let didStr = view.creator.did.didString()
                    returnedDIDs.insert(didStr)
                    labelerList.append(LabelerInfo(
                        id: didStr,
                        name: view.creator.displayName ?? view.creator.handle.description,
                        description: nil,
                        isEnabled: true
                    ))
                case .appBskyLabelerDefsLabelerViewDetailed(let view):
                    let didStr = view.creator.did.didString()
                    returnedDIDs.insert(didStr)
                    labelerList.append(LabelerInfo(
                        id: didStr,
                        name: view.creator.displayName ?? view.creator.handle.description,
                        description: view.creator.description,
                        isEnabled: true
                    ))
                case .unexpected:
                    continue
                }
            }
            
            self.labelers = labelerList
            
            // Identify subscribed DIDs absent from server response
            let missingDIDs = subscribedDIDs.map { $0.didString() }.filter { !returnedDIDs.contains($0) }
            self.unavailableLabelers = missingDIDs
            
        } catch {
            errorMessage = "Failed to load labelers: \(error.localizedDescription)"
        }
    }
    
    private func removeUnavailableLabelers() async {
        guard !unavailableLabelers.isEmpty else { return }
        isCleaningUpLabelers = true
        defer { isCleaningUpLabelers = false }
        
        do {
            let account = appState.userDID
            let manager = appState.preferencesManager
            let unavailableSet = Set(unavailableLabelers)
            try await manager.removeLabelers(unavailableSet, expectedAccountDID: account)
            guard manager.accountDID == account else { return }
            unavailableLabelers = []
            // Refresh hub

        } catch {
            errorMessage = "Error cleaning up labelers: \(error.localizedDescription)"
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
                    avatar: mute.finalAvatarURL()
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
                    avatar: block.finalAvatarURL()
                ))
            }
            
            blockedAccounts = accounts
            
        } catch {
            errorMessage = "Failed to load blocked accounts: \(error.localizedDescription)"
        }
    }
    
    private var adultContentBinding: Binding<Bool> {
        Binding(get: { adultContentEnabled }, set: { enabled in
            guard hasConfirmedPreferences, !isLoading, !isSavingPreferences,
                  adultContentEnabled, !enabled else { return }
            let account = appState.userDID
            let manager = appState.preferencesManager
            let request = loadRequest
            isSavingPreferences = true
            errorMessage = nil
            Task { @MainActor in
                defer { if loadRequest == request, manager.accountDID == account, appState.userDID == account { isSavingPreferences = false } }
                do {
                    try await manager.updateAdultContentEnabled(enabled, expectedAccountDID: account)
                    guard loadRequest == request, manager.accountDID == account, appState.userDID == account else { return }
                    adultContentEnabled = enabled
                    appState.isAdultContentEnabled = enabled
                } catch {
                    guard loadRequest == request, manager.accountDID == account, appState.userDID == account else { return }
                    hasConfirmedPreferences = false
                    errorMessage = UserFacingError.message(for: error, action: "update the adult content setting")
                }
            }
        })
    }

    private func visibilityBinding(label: String, value: Binding<ContentVisibility>) -> Binding<ContentVisibility> {
        Binding(get: { value.wrappedValue }, set: { selected in
            guard hasConfirmedPreferences, !isLoading, !isSavingPreferences,
                  selected != value.wrappedValue else { return }
            let account = appState.userDID
            let manager = appState.preferencesManager
            let request = loadRequest
            isSavingPreferences = true
            errorMessage = nil
            Task { @MainActor in
                defer { if loadRequest == request, manager.accountDID == account, appState.userDID == account { isSavingPreferences = false } }
                do {
                    try await manager.setContentLabelVisibility(label: label, visibility: selected.preferenceValue,
                                                                 expectedAccountDID: account)
                    guard loadRequest == request, manager.accountDID == account, appState.userDID == account else { return }
                    value.wrappedValue = selected
                } catch {
                    guard loadRequest == request, manager.accountDID == account, appState.userDID == account else { return }
                    hasConfirmedPreferences = false
                    errorMessage = UserFacingError.message(for: error, action: "save this content setting")
                }
            }
        })
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
                    errorMessage = "Couldn’t unblock this account. Try again."
                    return
                }
            } else {
                // Unmute account
                let input = AppBskyGraphUnmuteActor.Input(actor: try ATIdentifier(string: id))
                let code = try await client.app.bsky.graph.unmuteActor(input: input)
                
                if code != 200 {
                    errorMessage = "Couldn’t unmute this account. Try again."
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
            errorMessage = UserFacingError.message(for: error, action: isBlocked ? "unblock this account" : "unmute this account")
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
    @State private var serviceInput = ""
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        Form {
            Section {
                TextField("Handle (e.g. moderation.example.com)", text: $serviceInput)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled(true)
            } header: {
                Text("Moderation Service")
            } footer: {
                Text("Enter the moderation service’s handle. You can also subscribe from its profile.")
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
                            Text("Adding…")
                            Spacer()
                            ProgressView()
                        }
                    } else {
                        Text("Add Moderation Service")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .disabled(isAdding || serviceInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("Add Moderation Service")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    }
    
    private func addLabeler() {
        isAdding = true
        errorMessage = nil
        successMessage = nil
        
        let account = appState.userDID
        let manager = appState.preferencesManager
        let requested = serviceInput.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            defer { isAdding = false }
            guard let client = appState.atProtoClient else {
                errorMessage = "You’re signed out. Sign in and try again."
                return
            }
            
            let did: DID
            if requested.lowercased().hasPrefix("did:") {
                guard let parsed = try? DID(didString: requested) else {
                    errorMessage = "Couldn’t find a moderation service with that handle."
                    return
                }
                did = parsed
            } else {
                let handleString = (requested.hasPrefix("@") ? String(requested.dropFirst()) : requested).lowercased()
                guard let handle = try? Handle(handleString: handleString) else {
                    errorMessage = "Enter a handle like moderation.example.com."
                    return
                }
                do {
                    let (code, output) = try await client.com.atproto.identity.resolveHandle(input: .init(handle: handle))
                    guard code == 200, let output else {
                        errorMessage = "Couldn’t find a moderation service with that handle."
                        return
                    }
                    did = output.did
                } catch {
                    guard manager.accountDID == account, appState.userDID == account else { return }
                    if UserFacingError.kind(of: error) == .other || UserFacingError.kind(of: error) == .notFound {
                        errorMessage = "Couldn’t find a moderation service with that handle."
                    } else {
                        errorMessage = UserFacingError.message(for: error, action: "add this moderation service")
                    }
                    return
                }
            }
            
            do {
                let (code, output) = try await client.app.bsky.labeler.getServices(input: .init(dids: [did], detailed: false))
                guard manager.accountDID == account, appState.userDID == account else { return }
                guard code == 200, let output, !output.views.isEmpty else {
                    errorMessage = "This account isn’t a moderation service."
                    return
                }
                
                try await manager.addLabeler(did, expectedAccountDID: account)
                guard manager.accountDID == account, appState.userDID == account else { return }
                
                successMessage = "Moderation service added."
                
                // Clear the input field
                serviceInput = ""
                
                // Dismiss after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if appState.userDID == account, manager.accountDID == account { dismiss() }
                }
            } catch {
                guard manager.accountDID == account, appState.userDID == account else { return }
                errorMessage = UserFacingError.message(for: error, action: "add this moderation service")
            }
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
                Toggle("Use This Service", isOn: $isEnabled)
                    .onChange(of: isEnabled) {
                        updateLabelerStatus()
                    }
                    .disabled(isUpdating)
            }
            
            Section("About This Service") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Name")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                    
                    Text(labeler.name)
                                        .appFont(AppTextRole.body)

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
                            Text("Removing…")
                            Spacer()
                            ProgressView()
                        }
                    } else {
                        Text("Remove Service")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .foregroundStyle(.red)
                    }
                }
                .disabled(isUpdating)
            }
        }
        .navigationTitle("Moderation Service")
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
                errorMessage = UserFacingError.message(for: error, action: "update this moderation service")
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
                errorMessage = UserFacingError.message(for: error, action: "remove this moderation service")
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
                Text("See how your settings change the way posts appear.")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                ContentPreviewView(
                    label: "Graphic Content",
                    icon: "exclamationmark.triangle.fill",
                    iconColor: .red,
                    contentVisibility: violentContentVisibility,
                    sampleText: "This post contains graphic violence",
                    showImage: true
                )
                
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
                    Text("Turn on adult content at bsky.app to preview adult content settings.")
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
                Text(contentVisibility.displayName)
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
                    
                    Button("Show Content") {
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
  AsyncPreviewContent { appState in
    NavigationStack {
            ModerationSettingsView()
        }
  }
}
