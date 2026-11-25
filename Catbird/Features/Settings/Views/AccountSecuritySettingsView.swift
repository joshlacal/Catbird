import CatbirdMLSCore
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
    @State private var accountDeletionTarget: AccountDeletionTarget?
    @State private var signOutApproval: DeviceApprovalState?
    @State private var approvingBeforeSignOut = false
    @State private var showingDevicesBeforeSignOut = false
    init(initialFocus: SettingsControlID? = nil) { self.initialFocus = initialFocus }

    var body: some View {
        SettingsFocusedForm(initialFocus: initialFocus) {
            SettingsScopeSection()
            SettingsPersistenceStatusSection(settings: appState.appSettings)
            Section("Account") {
                SettingsLink(screen: .accountDetails, summary: "Handle, automation label, public data export", systemImage: "person.crop.circle", family: .account)
                SettingsLink(screen: .accountDetails, title: "Manage Hosted Account", summary: "Open your provider’s website for account settings", systemImage: "arrow.up.right.square", family: .account, control: .init(rawValue: "account.management"))
                Button("Delete Account", role: .destructive) {
                    showDeleteAccountSheet()
                }
                .disabled(signingOut)
                .settingsControl(.init(rawValue: "account.delete"))
            }
            if #available(iOS 18.0, macOS 13.0, *) {
                Section {
                    let localDeviceId = appState.resolvedMLSDeviceID()
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(AppState.localMLSDeviceDisplayName(shortDeviceId: localDeviceId))
                                    .font(.subheadline.weight(.medium))
                                Text("This Device")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.18))
                                    .foregroundStyle(.blue)
                                    .clipShape(Capsule())
                                let isActive = appState.mlsCoordinator != nil
                                if signOutApproval?.isPending == true {
                                    Text("Waiting for Approval")
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.16))
                                        .foregroundStyle(.orange)
                                        .clipShape(Capsule())
                                } else {
                                    Text(isActive ? "Active" : "Standby")
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background((isActive ? Color.green : Color.secondary).opacity(0.16))
                                        .foregroundStyle(isActive ? .green : .secondary)
                                        .clipShape(Capsule())
                                }
                            }
                            Text(verbatim: "Device ID: \(localDeviceId.prefix(8))…")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    NavigationLink(destination: DeviceManagementView()) {
                        Label("Authorized Devices", systemImage: "ipad.landscape.and.iphone")
                    }
                    .settingsControl(.init(rawValue: "account.mlsDevices"))

                    NavigationLink(
                        destination: LabyrinthSettingsAndRestoreView(
                            coordinator: appState.mlsCoordinator,
                            currentDeviceId: localDeviceId
                        )
                        .id(appState.mlsCoordinator?.accountDidHash)
                    ) {
                        Label("Labyrinth Backup & Device Pairing", systemImage: "key.icloud.fill")
                    }
                    .settingsControl(.init(rawValue: "account.labyrinthBackup"))
                } header: {
                    Text("Encrypted Chat Devices")
                } footer: {
                    Text("Pair another device with a 6-digit post-quantum code, inspect active or dormant devices, or revoke lost devices. Sign out below to remove this device.")
                }
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
                } header: { Text("On This Device") } footer: {
                    Text("Use your device’s biometric authentication to unlock Catbird. This preference applies to the app on this device.")
                }
            }
            Section {
                Button("Sign Out", role: .destructive) {
                    signOutDID = appState.userDID
                    signOutRevision = AppStateManager.shared.settingsAccountContextRevision
                    confirmingSignOut = true
                    Task { @MainActor in signOutApproval = await appState.loadDeviceApprovalState() }
                }
                    .disabled(signingOut || approvingBeforeSignOut)
                    .settingsControl(.init(rawValue: "account.signOut"))
                if approvingBeforeSignOut { ProgressView("Approving…") }
                if signingOut { ProgressView("Signing out…") }
            }
        }
        .navigationTitle("Account & Security")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $accountDeletionTarget) { target in
            AccountDeletionSheet(target: target)
        }
        .task(id: appState.userDID) {
            signOutApproval = await appState.loadDeviceApprovalState()
        }
        .confirmationDialog("Sign Out of This Account?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            if let approval = signOutApproval, approval.signOutStrandsWaitingDevices,
               case .approved(let waiting, _) = approval
            {
                if waiting.count == 1, let device = waiting.first {
                    Button("Approve \(device.displayName), Then Sign Out") { approveThenSignOut(device) }
                } else {
                    Button("Review Waiting Devices") { showingDevicesBeforeSignOut = true }
                }
                Button("Sign Out Without Approving", role: .destructive) { confirmSignOut() }
            } else {
                Button("Sign Out", role: .destructive) { confirmSignOut() }
            }
            Button("Stay", role: .cancel) { }
        } message: {
            Text(Self.signOutMessage(for: signOutApproval))
        }
        .sheet(isPresented: $showingDevicesBeforeSignOut, onDismiss: {
            Task { @MainActor in signOutApproval = await appState.loadDeviceApprovalState() }
        }) {
            NavigationStack { DeviceManagementView() }
                .environment(appState)
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

    /// What signing out does to encrypted chat on this account, from this device's approval.
    nonisolated static func signOutMessage(for approval: DeviceApprovalState?) -> String {
        guard let approval else {
            return "Signing out removes this device from encrypted chat. You can sign back in later."
        }
        switch approval {
        case .approved(let waiting, let otherApprovedCount) where otherApprovedCount == 0 && !waiting.isEmpty:
            let names = ListFormatter.localizedString(byJoining: waiting.map(\.displayName))
            let verb = waiting.count == 1 ? "is" : "are"
            return "\(names) \(verb) waiting for approval, and this is your only approved device. If you sign out first, you’ll need your backup passkey or recovery code to get back into encrypted chat."
        case .approved(_, let otherApprovedCount) where otherApprovedCount == 0:
            return "This is your only approved device. When you sign back in, you’ll restore your backup with your passkey or recovery code to use encrypted chat again."
        case .askApprover, .approversQuiet, .noApprover:
            return "This device isn’t approved for encrypted chat yet. Signing out cancels its approval, and signing back in starts it over."
        case .approved, .revoked:
            return "Signing out removes this device from encrypted chat. You can sign back in later."
        }
    }

    private func confirmSignOut() {
        guard let did = signOutDID, SettingsAccountBoundary.isCurrent(did, revision: signOutRevision) else { return }
        if let pending = appState.appSettings.pendingChangesSummary { pendingSignOutDID = pending.accountDID; showingPendingSignOut = true }
        else { signOut(expectedDID: did) }
    }

    private func approveThenSignOut(_ device: DeviceApprovalPeer) {
        guard !approvingBeforeSignOut else { return }
        approvingBeforeSignOut = true
        Task { @MainActor in
            defer { approvingBeforeSignOut = false }
            guard let coordinator = await appState.getOrOpenMLSCoordinator() else {
                lockError = "Encrypted chat isn’t ready on this device, so \(device.displayName) wasn’t approved. You’re still signed in."
                return
            }
            do {
                try await coordinator.approveDevice(targetDeviceId: device.deviceId)
            } catch {
                lockError = "Couldn’t approve \(device.displayName), so you’re still signed in. \(error.localizedDescription)"
                return
            }
            confirmSignOut()
        }
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

    private func showDeleteAccountSheet() {
        let did = appState.userDID
        guard !did.isEmpty else { return }
        let revision = AppStateManager.shared.settingsAccountContextRevision
        let handle = AppStateManager.shared.authentication.getCachedProfileData(for: did)?.handle
        accountDeletionTarget = AccountDeletionTarget(
            did: did,
            handle: handle,
            accountRevision: revision,
            purpose: .deletionOptions
        )
    }
}
