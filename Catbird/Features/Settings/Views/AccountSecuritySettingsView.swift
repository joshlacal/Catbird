import SwiftUI

struct AccountSecuritySettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let initialFocus: SettingsControlID?
    @State private var changingAppLock = false
    @State private var lockError: String?
    @State private var confirmingSignOut = false
    @State private var signOutDID: String?
    @State private var signOutRevision: UInt64 = 0
    @State private var showingPendingSignOut = false
    @State private var pendingSignOutDID: String?
    @State private var signingOut = false
    init(initialFocus: SettingsControlID? = nil) { self.initialFocus = initialFocus }

    var body: some View {
        SettingsFocusedForm(initialFocus: initialFocus) {
            SettingsScopeSection()
            SettingsPersistenceStatusSection(settings: appState.appSettings)
            Section("Account") {
                SettingsLink(screen: .accountDetails, summary: "Handle, email, automation label, public data export", systemImage: "person.crop.circle", family: .account)
                SettingsLink(screen: .accountDetails, title: "Email & Sign-In Codes", summary: "Manage email and verification codes for sign-in", systemImage: "envelope.badge.shield.half.filled", family: .account, control: .init(rawValue: "account.email"))
                SettingsLink(screen: .accountDetails, title: "Delete Account", summary: "Permanently delete this account", systemImage: "person.crop.circle.badge.xmark", family: .account, control: .init(rawValue: "account.delete"))
            }
            if AppStateManager.shared.authentication.biometricType != .none {
                Section {
                    Toggle("Require App Unlock", isOn: Binding(
                        get: { AppStateManager.shared.authentication.biometricAuthEnabled },
                        set: { requested in changeAppLock(requested) }
                    ))
                    .disabled(changingAppLock)
                    .settingsControl(.init(rawValue: "account.appLock"))
                    if changingAppLock { ProgressView("Updating app lock…") }
                } header: { Text("This Device") } footer: {
                    Text("Use your device’s biometric authentication to unlock Catbird. This preference applies to the app on this device.")
                }
            }
            Section {
                Button("Sign Out", role: .destructive) { signOutDID = appState.userDID; signOutRevision = AppStateManager.shared.settingsAccountContextRevision; confirmingSignOut = true }
                    .disabled(signingOut)
                    .settingsControl(.init(rawValue: "account.signOut"))
                if signingOut { ProgressView("Signing out…") }
            }
        }
        .navigationTitle("Account & Security")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog("Sign out of this account?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                guard let did = signOutDID, SettingsAccountBoundary.isCurrent(did, revision: signOutRevision) else { return }
                if let pending = appState.appSettings.pendingChangesSummary { pendingSignOutDID = pending.accountDID; showingPendingSignOut = true }
                else { signOut(expectedDID: did) }
            }
            Button("Stay", role: .cancel) { }
        }
        .confirmationDialog("Unsaved Settings", isPresented: $showingPendingSignOut, titleVisibility: .visible) {
            Button("Save & Sign Out") { resolveSignOut(save: true) }
            Button("Discard & Sign Out", role: .destructive) { resolveSignOut(save: false) }
            Button("Stay", role: .cancel) { pendingSignOutDID = nil }
        } message: { Text("Save or discard this account’s pending changes before signing out.") }
        .alert("Account Security", isPresented: Binding(get: { lockError != nil }, set: { if !$0 { lockError = nil } })) {
            Button("OK", role: .cancel) { lockError = nil }
        } message: { Text(lockError ?? "") }
        .interactiveDismissDisabled(signingOut || changingAppLock)
    }

    private func changeAppLock(_ enabled: Bool) {
        guard !changingAppLock else { return }
        changingAppLock = true
        Task { @MainActor in
            let auth = AppStateManager.shared.authentication
            await auth.setBiometricAuthEnabled(enabled)
            changingAppLock = false
            if auth.biometricAuthEnabled != enabled { lockError = auth.lastBiometricError?.localizedDescription ?? "App lock couldn’t be updated. Try again." }
        }
    }
    private func resolveSignOut(save: Bool) {
        guard let did = pendingSignOutDID, SettingsAccountBoundary.isCurrent(did, revision: signOutRevision) else { return }
        let revision = signOutRevision
        pendingSignOutDID = nil
        Task { @MainActor in
            let result = await appState.appSettings.resolvePendingChanges(for: did, decision: save ? .save : .discard)
            if case .resolved = result, SettingsAccountBoundary.isCurrent(did, revision: revision) { signOut(expectedDID: did) }
            else { lockError = "Your settings are still pending. Stay in this account and try again." }
        }
    }
    private func signOut(expectedDID: String) {
        guard appState.userDID == expectedDID, SettingsAccountBoundary.isCurrent(expectedDID, revision: signOutRevision), !signingOut else { return }
        signingOut = true
        Task { @MainActor in
            await AppStateManager.shared.logout()
            signingOut = false
            dismiss()
        }
    }
}
