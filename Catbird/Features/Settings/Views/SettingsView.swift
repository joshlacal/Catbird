import SwiftUI
import Petrel

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(SceneNavigationContext.self) private var sceneContext
    @Environment(\.dismiss) private var dismiss
    @State private var draftGuard = SettingsDraftGuard()
    @State private var path: [SettingsTarget] = []
    @State private var searchQuery = ""
    @State private var profile: AppBskyActorDefs.ProfileViewDetailed?
    @State private var profileError: String?
    @State private var isLoadingProfile = false
    @State private var showingAccounts = false
    @State private var showingDeparture = false
    @State private var departure: Departure?
    @State private var pendingAccountRevision: UInt64?
    @State private var pendingAccountDID: String?
    @State private var resolvingDeparture = false
    @State private var departureError: String?
    /// The account whose settings were last loaded; a change of account resets navigation.
    @State private var loadedDID: String?
    private enum Departure { case close, accounts }
    /// True when pushed onto an existing navigation stack (a settings link opened in a tab) rather than presented as its own sheet.
    let isEmbedded: Bool

    /// Opens Settings at `initialTarget` (used by bsky.app/settings links); `nil` opens the home list.
    init(initialTarget: SettingsTarget? = nil, isEmbedded: Bool = false) {
        self.isEmbedded = isEmbedded
        _path = State(initialValue: initialTarget.map { $0.screen == .home ? [] : [$0] } ?? [])
    }

    var body: some View {
        if isEmbedded {
            home
        } else {
            NavigationStack(path: $path) { home }
                .environment(\.settingsDraftGuard, draftGuard)
                // Some Settings rows open app content (a feed, a list). That lands on the tab behind this sheet, so close Settings to show it.
                .onChange(of: appNavigationDepth) { oldDepth, newDepth in
                    if newDepth > oldDepth { requestDeparture(.close) }
                }
                .interactiveDismissDisabled(appState.appSettings.hasPendingChanges || draftGuard.hasChanges || resolvingDeparture)
        }
    }

    private var home: some View {
        ResponsiveContentView {
            Form {
                SettingsPersistenceStatusSection(settings: appState.appSettings)
                Section { accountHeader }
                if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ForEach(SettingsCatalog.homeGroups, id: \.0) { group in
                        Section(group.0) {
                            ForEach(group.1, id: \.self) { screen in
                                SettingsLink(screen: screen, summary: summary(for: screen), systemImage: symbol(for: screen), family: family(for: screen))
                                    .accessibilityIdentifier("settings.category." + screen.rawValue)
                            }
                        }
                    }
                } else {
                    Section("Search Results") {
                        let results = SettingsCatalog.search(searchQuery).filter { $0.target.control?.rawValue != "account.appLock" || AppStateManager.shared.authentication.biometricType != .none }
                        if results.isEmpty {
                            Text("No settings found. Try a setting name, such as autoplay, muted words, or text size.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(results) { entry in
                            NavigationLink(value: entry.target) {
                                SettingsNavigationRow(title: entry.title, summary: resultSummary(entry), systemImage: symbol(for: entry.target.screen), family: family(for: entry.target.screen))
                            }
                            .accessibilityIdentifier("settings.result." + (entry.target.control?.rawValue ?? entry.target.screen.rawValue))
                        }
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .searchable(text: $searchQuery, prompt: "Search settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .modifier(SettingsTargetDestinations(isEnabled: !isEmbedded))
        .toolbar {
            if !isEmbedded {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close Settings", systemImage: "xmark") { requestDeparture(.close) }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("settings.close")
                        .disabled(resolvingDeparture)
                }
            }
        }
        .sheet(isPresented: $showingAccounts) {
            AccountSwitcherView().environment(AppStateManager.shared)
        }
        .confirmationDialog("Unsaved Settings", isPresented: $showingDeparture, titleVisibility: .visible) {
            Button("Save") { resolveDeparture(save: true) }
            Button("Discard Changes", role: .destructive) { resolveDeparture(save: false) }
            Button("Stay", role: .cancel) { departure = nil; pendingAccountDID = nil }
        } message: { Text("Save or discard changes for this account before leaving Settings or choosing another account.") }
        .alert("Settings Couldn’t Be Saved", isPresented: Binding(get: { departureError != nil }, set: { if !$0 { departureError = nil } })) {
            Button("OK", role: .cancel) { departureError = nil }
        } message: { Text(departureError ?? "") }
        .task(id: appState.userDID) {
            // Keep a deep-linked starting screen on first load; reset only when the account changes.
            if loadedDID != nil, loadedDID != appState.userDID { path = [] }
            loadedDID = appState.userDID
            profile = nil
            profileError = nil
            await loadProfile(for: appState.userDID)
        }
    }

    private var appNavigationDepth: Int {
        sceneContext.navigationManager.tabPaths.values.reduce(0) { $0 + $1.count }
    }

    private var accountHeader: some View {
        let cached = AppStateManager.shared.authentication.getCachedProfileData(for: appState.userDID)
        let handle = profile?.handle.description ?? cached?.handle
        let name = profile?.displayName ?? cached?.displayName ?? handle.map { "@" + $0 } ?? "Current account"
        return Button { requestDeparture(.accounts) } label: {
            HStack(spacing: DesignTokens.Spacing.base) {
                ProfileAvatarView(url: profile?.finalAvatarURL() ?? cached?.avatarURL, fallbackText: String((handle ?? "?").prefix(1)).uppercased(), size: 44)
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text(name).appFont(AppTextRole.headline).foregroundStyle(Color.primary)
                    if let handle { Text("@" + handle).appFont(AppTextRole.subheadline).foregroundStyle(Color.secondary) }
                    Text("Switch or add an account").appFont(AppTextRole.caption).foregroundStyle(Color.secondary)
                    if isLoadingProfile && handle == nil { Text("Loading account…").appFont(AppTextRole.caption).foregroundStyle(Color.secondary) }
                    if let profileError { Text(profileError).appFont(AppTextRole.caption).foregroundStyle(Color.secondary) }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(Color(platformColor: PlatformColor.platformTertiaryLabel)).accessibilityHidden(true)
            }
        }
        .accessibilityIdentifier("settings.accountSwitcher")
        .accessibilityElement(children: .combine)
    }

    @MainActor private func loadProfile(for did: String) async {
        let revision = AppStateManager.shared.settingsAccountContextRevision
        guard SettingsAccountBoundary.isCurrent(did, revision: revision),
              let client = appState.atProtoClient else { return }
        isLoadingProfile = true
        defer { if SettingsAccountBoundary.isCurrent(did, revision: revision) { isLoadingProfile = false } }
        do {
            let originatingAppState = appState
            try await originatingAppState.performSettingsAccountOperation {
                try Task.checkCancellation()
                let parameters = try AppBskyActorGetProfile.Parameters(actor: ATIdentifier(string: did))
                let (_, fetched) = try await client.app.bsky.actor.getProfile(input: parameters)
                try Task.checkCancellation()
                guard appState.userDID == did, SettingsAccountBoundary.isCurrent(did, revision: revision) else { return }
                profile = fetched
                if let fetched {
                    AppStateManager.shared.authentication.cacheProfileData(for: did, handle: fetched.handle.description, displayName: fetched.displayName, avatarURL: fetched.finalAvatarURL())
                }
            }
        } catch is CancellationError { }
        catch {
            guard appState.userDID == did, SettingsAccountBoundary.isCurrent(did, revision: revision) else { return }
            profileError = "Couldn’t refresh account details."
        }
    }

    private func requestDeparture(_ action: Departure) {
        pendingAccountRevision = AppStateManager.shared.settingsAccountContextRevision
        if draftGuard.hasChanges, let did = draftGuard.accountDID {
            pendingAccountDID = did
            departure = action
            showingDeparture = true
        } else if let pending = appState.appSettings.pendingChangesSummary {
            pendingAccountDID = pending.accountDID
            departure = action
            showingDeparture = true
        } else { completeDeparture(action) }
    }
    private func resolveDeparture(save: Bool) {
        guard let did = pendingAccountDID, let revision = pendingAccountRevision, let action = departure, SettingsAccountBoundary.isCurrent(did, revision: revision) else { return }
        departure = nil
        showingDeparture = false
        resolvingDeparture = true
        Task { @MainActor in
            if draftGuard.hasChanges {
                guard draftGuard.accountDID == did, let resolve = draftGuard.resolve, await resolve(save) else {
                    resolvingDeparture = false
                    departureError = "The staged changes could not be saved. Stay in Settings and review them."
                    return
                }
            }
            guard appState.userDID == did, SettingsAccountBoundary.isCurrent(did, revision: revision) else {
                resolvingDeparture = false
                departureError = "The originating account has changed. Review the current account before leaving."
                return
            }
            guard appState.appSettings.hasPendingChanges else {
                resolvingDeparture = false
                pendingAccountDID = nil
                completeDeparture(action)
                return
            }
            let result = await appState.appSettings.resolvePendingChanges(for: did, decision: save ? .save : .discard)
            resolvingDeparture = false
            pendingAccountDID = nil
            switch result {
            case .resolved: completeDeparture(action)
            case .saveFailed: departureError = "Your changes are still pending. Try saving again or discard them to continue."
            case .accountChanged, .unavailable: departureError = "The originating account is no longer available. Stay in Settings and review the current account."
            }
        }
    }
    private func completeDeparture(_ action: Departure) {
        switch action { case .close: dismiss(); case .accounts: showingAccounts = true }
    }
    private func resultSummary(_ entry: SettingsSearchEntry) -> String {
        let location = entry.breadcrumb + " · " + entry.scope
        guard let value = confirmedValue(for: entry.target) else { return location }
        return location + " · " + value
    }
    private func confirmedValue(for target: SettingsTarget) -> String? {
        guard let id = target.control?.rawValue else { return target.screen == .notifications ? appState.notificationManager.settingsSummary : nil }
        if id == "account.appLock" { return AppStateManager.shared.authentication.biometricAuthEnabled ? "On" : "Off" }
        guard appState.appSettings.persistenceState == .ready else { return nil }
        let settings = appState.appSettings
        switch id {
        case "media.autoplayVideos": return settings.autoplayVideos ? "On" : "Off"
        case "appearance.theme": return settings.theme.capitalized
        case "text.fontSize":
            let sizes = ["small": "Small", "default": "Default", "large": "Large", "extraLarge": "Extra Large"]
            return sizes[settings.fontSize] ?? settings.fontSize.capitalized
        case "accessibility.altText": return settings.requireAltText ? "On" : "Off"
        case "accessibility.reduceMotion": return settings.effectiveReduceMotion ? "On" : "Off"
        case "accessibility.increaseContrast": return settings.effectiveIncreaseContrast ? "On" : "Off"
        case "accessibility.boldText": return settings.effectiveBoldText ? "On" : "Off"
        case "languages.hideOtherLanguages": return (settings.hideNonPreferredLanguages || appState.feedFilterSettings.isFilterEnabled(name: "Filter by Language")) ? "On" : "Off"
        case "privacy.attribution": return settings.enableViaAttribution ? "On" : "Off"
        default: return nil
        }
    }
    private func summary(for screen: SettingsScreenID) -> String {
        switch screen {
        case .accountSecurity: "Handle, email, account protection"
        case .privacyInteractions: "Visibility, replies, messages"
        case .notifications: appState.notificationManager.settingsSummary
        case .feedsDiscovery: "Feed preferences, threads, interests"
        case .moderation: "Warnings, mutes, blocks"
        case .mediaLinks: "Playback, external media, browser"
        case .language: InterfaceLanguagePreferences.availableLanguages().count > 1 ? "Interface and reading languages" : "Reading languages and language filter"
        case .appearance: "Theme and app icon"
        case .accessibility: "Text, motion, image descriptions"
        case .helpAbout: "Get help, support Catbird, app info"
        case .advanced: "Service providers and cache"
        default: ""
        }
    }
    private func symbol(for screen: SettingsScreenID) -> String {
        switch family(for: screen) {
        case .account: "person.fill"
        case .privacy: "hand.raised.fill"
        case .notifications: "bell.fill"
        case .feeds: "rectangle.stack.fill"
        case .moderation: "shield.fill"
        case .media: "play.rectangle.fill"
        case .language: "character.bubble.fill"
        case .appearance: "paintbrush.fill"
        case .accessibility: "accessibility"
        case .support: "questionmark.circle.fill"
        case .advanced: "gearshape.2.fill"
        }
    }
    private func family(for screen: SettingsScreenID) -> SettingsIconFamily {
        switch screen {
        case .accountSecurity, .accountDetails, .automationLabel: .account
        case .privacyInteractions, .visibility, .activityPrivacy, .messages, .defaultPostInteractions: .privacy
        case .notifications, .activitySubscriptions: .notifications
        case .feedsDiscovery, .feedFiltering, .threads, .discovery, .interests, .feedLibrary, .verification: .feeds
        case .moderation, .labelers, .mutedAccounts, .blockedAccounts: .moderation
        case .mediaLinks, .externalMedia: .media
        case .language: .language
        case .appearance, .appIcon: .appearance
        case .accessibility, .textReadability: .accessibility
        case .helpAbout, .help, .blueskyHelpCenter, .about, .licenses, .home: .support
        case .advanced, .providers, .systemLogs, .cache: .advanced
        }
    }
}

/// Registers Settings destinations on the Settings sheet's own stack; an embedded home relies on its host stack's registration.
private struct SettingsTargetDestinations: ViewModifier {
    let isEnabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if isEnabled {
            content.navigationDestination(for: SettingsTarget.self) { target in
                SettingsDestinationView(target: target)
            }
        } else {
            content
        }
    }
}

// MARK: - Bundle Extension

extension Bundle {
  var appVersionString: String {
    let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
    return "\(version) (\(build))"
  }
}

// MARK: - Previews

#Preview {
  AsyncPreviewContent { appState in
    SettingsView()
  }
}
