import SwiftUI
import Petrel

struct ModerationSettingsView: View {
    @Environment(AppState.self) private var appState
    let initialFocus: SettingsControlID?
    @State private var isLoading = true
    /// The account this screen last confirmed its preferences for with the server.
    @State private var confirmedAccountDID: String?
    @State private var isSavingPreferences = false
    @State private var pendingChoice: PendingLabelChoice?
    @State private var loadRequest = UUID()
    @State private var errorMessage: String?

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

    /// The moderation engine's preferences for this account, once this screen has confirmed them with
    /// the server. The screen shows and edits exactly what posts and feeds are moderated with.
    private var confirmedPrefs: ModerationPrefs? {
        let policy = appState.moderationPolicy
        guard confirmedAccountDID == appState.userDID, policy.isConfirmed,
              policy.accountDID == appState.userDID else { return nil }
        return policy.prefs
    }

    var body: some View {
        let prefs = confirmedPrefs
        SettingsFocusedForm(initialFocus: prefs != nil ? initialFocus
          : initialFocus.map { _ in SettingsControlID(rawValue: "moderation.retryLoad") }, isReady: prefs != nil || !isLoading) {
            if let prefs {
                loadedContent(prefs)
            } else if isLoading {
                Section {
                    ProgressView("Loading moderation settings…")
                }
            } else {
                Section {
                    Text(errorMessage ?? "Your moderation settings couldn’t be loaded.")
                        .foregroundStyle(.secondary)
                    Button("Try Again") { Task { await loadPreferences() } }
                        .settingsControl(.init(rawValue: "moderation.retryLoad"))
                }
            }
        }
        .navigationTitle("Moderation")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
        .appDisplayScale(appState: appState)
        .contrastAwareBackground(appState: appState, defaultColor: Color.systemBackground)
        .task(id: appState.userDID) { await loadPreferences() }
        .refreshable { await loadPreferences() }
    }

    @ViewBuilder
    private func loadedContent(_ prefs: ModerationPrefs) -> some View {
        if isSavingPreferences {
            Section { ProgressView("Saving moderation preferences…") }
        }
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

        contentFiltersSection(prefs)
        contentPreviewSection(prefs)

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

    // MARK: - Content filters

    private func contentFiltersSection(_ prefs: ModerationPrefs) -> some View {
        Section("Content Filters") {
            Toggle("Enable Adult Content", isOn: adultContentBinding(prefs))
                // Only turning it off is offered here; it can be turned on at bsky.app.
                .disabled(!prefs.adultContentEnabled || isSavingPreferences)
                .settingsControl(.init(rawValue: "moderation.adultContent"))
            if !prefs.adultContentEnabled {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.orange)
                        .appFont(AppTextRole.caption)
                    Text("Adult content can only be turned on at bsky.app in a web browser. You can turn it off here at any time.")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(ContentFilterSettings.rows(for: prefs)) { row in
                contentFilterRow(row)
                    .settingsControl(row.controlID)
            }
        }
    }

    @ViewBuilder
    private func contentFilterRow(_ row: ContentFilterRow) -> some View {
        switch row.control {
        case .selectable(let preference):
            LabelPreferenceSelector(
                title: row.name,
                description: row.description,
                selection: Binding(
                    get: { pendingChoice?.preference(for: row.identifier) ?? preference },
                    set: { saveContentFilter(row.identifier, $0) }))
                .disabled(isSavingPreferences)
        case .hiddenWhileAdultContentOff:
            LabelPreferenceStatusRow(
                title: row.name, description: row.description, value: .hide,
                note: "Hidden while adult content is off.", systemImage: "lock.fill")
        }
    }

    // MARK: - Content preview

    /// Each outcome is the moderation engine's decision for a sample post with that label.
    private func contentPreviewSection(_ prefs: ModerationPrefs) -> some View {
        Section {
            ForEach(ContentFilterSettings.rows(for: prefs)) { row in
                if let outcome = ContentFilterPreview.outcome(for: row.identifier, prefs: prefs) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                                .appFont(AppTextRole.subheadline)
                                .fontWeight(.medium)
                            Text(outcome.summary)
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: outcome.systemImage)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            Text("Content Preview")
        } footer: {
            Text("How a post with each label from Bluesky’s moderation service appears with your current settings.")
        }
    }

    // MARK: - Loading and saving

    private func loadPreferences() async {
        let request = UUID()
        let account = appState.userDID
        let manager = appState.preferencesManager
        loadRequest = request
        if confirmedAccountDID != account { confirmedAccountDID = nil }
        isLoading = true
        isSavingPreferences = false
        pendingChoice = nil
        errorMessage = nil
        defer { if loadRequest == request { isLoading = false } }
        do {
            // A confirmed fetch rebuilds `appState.moderationPolicy` before it returns.
            _ = try await manager.refreshSettingsPreferences(expectedAccountDID: account)
            guard loadRequest == request, manager.accountDID == account, appState.userDID == account else { return }
            confirmedAccountDID = account
        } catch {
            guard loadRequest == request, manager.accountDID == account else { return }
            let action = confirmedAccountDID == account ? "refresh your moderation settings" : "load your moderation settings"
            errorMessage = UserFacingError.message(for: error, action: action)
        }
    }

    private func adultContentBinding(_ prefs: ModerationPrefs) -> Binding<Bool> {
        Binding(get: { prefs.adultContentEnabled }, set: { enabled in
            guard prefs.adultContentEnabled, !enabled else { return }
            edit(action: "update the adult content setting") { manager, account in
                try await manager.updateAdultContentEnabled(false, expectedAccountDID: account)
            }
        })
    }

    private func saveContentFilter(_ identifier: String, _ preference: LabelPreference) {
        let writes = ContentFilterSettings.globalWrites(identifier: identifier, preference: preference)
        edit(pending: PendingLabelChoice(identifier: identifier, preference: preference),
             action: "save this content setting") { manager, account in
            try await manager.updateContentLabelPreferences(writes, expectedAccountDID: account)
        }
    }

    /// Runs one confirmed preference write. A confirmed write rebuilds `appState.moderationPolicy`
    /// before it returns, so the screen needs no local copy of the result.
    private func edit(
        pending: PendingLabelChoice? = nil,
        action: String,
        _ operation: @escaping @MainActor (PreferencesManager, String) async throws -> Void
    ) {
        guard confirmedPrefs != nil, !isLoading, !isSavingPreferences else { return }
        let account = appState.userDID
        let manager = appState.preferencesManager
        let request = loadRequest
        isSavingPreferences = true
        pendingChoice = pending
        errorMessage = nil
        Task { @MainActor in
            defer {
                if loadRequest == request, manager.accountDID == account, appState.userDID == account {
                    isSavingPreferences = false
                    pendingChoice = nil
                }
            }
            do {
                try await operation(manager, account)
            } catch {
                guard loadRequest == request, manager.accountDID == account, appState.userDID == account else { return }
                confirmedAccountDID = nil
                errorMessage = UserFacingError.message(for: error, action: action)
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


// MARK: - Label preference components

/// A choice being saved for one label, shown until the confirmed preferences arrive.
struct PendingLabelChoice: Equatable {
    let identifier: String
    let preference: LabelPreference

    func preference(for identifier: String) -> LabelPreference? {
        identifier == self.identifier ? preference : nil
    }
}

/// A segmented Show / Warn / Hide choice for one label.
struct LabelPreferenceSelector: View {
    let title: String
    let description: String
    /// `false` for labels with nothing to warn with; only Show and Hide are offered.
    var canWarn = true
    @Binding var selection: LabelPreference

    private var options: [LabelPreference] { canWarn ? [.ignore, .warn, .hide] : [.ignore, .hide] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .appFont(AppTextRole.headline)

            if !description.isEmpty {
                Text(description)
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
            }

            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(option.settingsOptionTitle).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.top, 4)
        }
        .padding(.vertical, 8)
    }
}

/// A label that can't be changed here, with the value in effect and the reason.
struct LabelPreferenceStatusRow: View {
    let title: String
    let description: String
    let value: LabelPreference?
    let note: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .appFont(AppTextRole.headline)
                Spacer()
                if let value {
                    Text(value.settingsOptionTitle)
                        .appFont(AppTextRole.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
            if !description.isEmpty {
                Text(description)
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
            }
            Label(note, systemImage: systemImage)
                .appFont(AppTextRole.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
  AsyncPreviewContent { appState in
    NavigationStack {
            ModerationSettingsView()
        }
  }
}
