import SwiftUI

struct ExternalMediaPreferencesView: View {
    @Environment(AppState.self) private var appState
    var initialFocus: SettingsControlID? = nil
    @State private var bulkConsent: ExternalMediaConsent?
    
    var body: some View {
        SettingsFocusedForm(initialFocus: initialFocus) {
            SettingsScopeSection(scope: "Current account on this device")
            SettingsPersistenceStatusSection(settings: appState.appSettings)

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        SettingsCategoryIcon(systemImage: "hand.raised.shield", family: .media)
                        Text("Privacy Notice")
                            .appFont(AppTextRole.headline)
                    }
                    
                    Text("Playing external media connects directly to third-party servers. These providers may collect your IP address, device information, and browsing activity in accordance with their privacy policies.")
                        .appFont(AppTextRole.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            
            Section("Quick Actions") {
                Button("Allow All Providers") {
                    bulkConsent = .allow
                }

                Button("Ask Before Playing for All") {
                    bulkConsent = .undecided
                }

                Button("Block All Providers", role: .destructive) {
                    bulkConsent = .hide
                }
            }
            .disabled(!appState.appSettings.canEditPersistedSettings)
            
            Section("Providers") {
                ForEach(ExternalMediaProvider.allCases) { provider in
                    providerRow(for: provider)
                        .settingsControl(.init(rawValue: "media.provider.\(provider.rawValue)"))
                }
            }
            .settingsControl(.init(rawValue: "media.providerPermissions"))
            .disabled(!appState.appSettings.canEditPersistedSettings)
        }
        .navigationTitle("External Media Permissions")
        .confirmationDialog("Change All Provider Permissions?", isPresented: Binding(
            get: { bulkConsent != nil },
            set: { if !$0 { bulkConsent = nil } }
        ), titleVisibility: .visible) {
            if let bulkConsent {
                Button(bulkConsent.title, role: bulkConsent == .hide ? .destructive : nil) {
                    _ = appState.appSettings.applyExternalMediaConsent(
                        bulkConsent, providers: ExternalMediaProvider.allCases
                    )
                    self.bulkConsent = nil
                }
            }
            Button("Cancel", role: .cancel) { bulkConsent = nil }
        } message: {
            Text("This changes all \(ExternalMediaProvider.allCases.count) providers for this account on this device. Individual permissions remain available below.")
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
    
    @ViewBuilder
    private func providerRow(for provider: ExternalMediaProvider) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .appFont(AppTextRole.body)
                Text(provider.hostDescription)
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Picker("\(provider.displayName) Playback Permission", selection: Binding(
                get: { appState.appSettings.externalMediaConsent(for: provider) },
                set: { _ = appState.appSettings.applyExternalMediaConsent($0, providers: [provider]) }
            )) {
                ForEach(ExternalMediaConsent.allCases, id: \.self) { consent in
                    Text(consent.title).tag(consent)
                }
            }
            .labelsHidden()
            #if os(iOS)
            .pickerStyle(.menu)
            #endif
        }
        .padding(.vertical, 2)
    }
}
