import SwiftUI

struct ExternalMediaPreferencesView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        Form {
            SettingsPersistenceStatusSection(settings: appState.appSettings)

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.raised.shield.fill")
                            .foregroundStyle(.blue)
                            .imageScale(.large)
                        Text("Privacy Notice")
                            .font(.headline)
                    }
                    
                    Text("Playing external media connects directly to third-party servers. These providers may collect your IP address, device information, and browsing activity in accordance with their privacy policies.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            
            Section("Quick Actions") {
                Button("Allow All Providers") {
                    appState.appSettings.setExternalMediaConsentForAllProviders(.allow)
                }
                .foregroundStyle(.blue)
                
                Button("Ask Before Playing (Reset All)") {
                    appState.appSettings.setExternalMediaConsentForAllProviders(.undecided)
                }
                .foregroundStyle(.primary)
                
                Button("Block All Providers") {
                    appState.appSettings.setExternalMediaConsentForAllProviders(.hide)
                }
                .foregroundStyle(.red)
            }
            .disabled(!appState.appSettings.canEditPersistedSettings)
            
            Section("Providers") {
                ForEach(ExternalMediaProvider.allCases) { provider in
                    providerRow(for: provider)
                }
            }
            .disabled(!appState.appSettings.canEditPersistedSettings)
        }
        .navigationTitle("External Media")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
    
    @ViewBuilder
    private func providerRow(for provider: ExternalMediaProvider) -> some View {
        let currentConsent = appState.appSettings.externalMediaConsent(for: provider)
        
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.body)
                Text(provider.hostDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Picker("\(provider.displayName) playback", selection: Binding(
                get: { currentConsent },
                set: { appState.appSettings.setExternalMediaConsent($0, for: provider) }
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
