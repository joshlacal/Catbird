import SwiftUI
import Petrel

/// View for configuring verification badge visibility in Moderation Settings
struct VerificationSettingsView: View {
    @Environment(AppState.self) private var appState
    
    @State private var showBadges: Bool = true
    @State private var isLoading: Bool = true
    @State private var isSaving: Bool = false
    @State private var loadFailed: Bool = false
    @State private var errorMessage: String? = nil
    @State private var showingErrorAlert: Bool = false
    
    private var preferencesManager: PreferencesManager {
        appState.preferencesManager
    }
    
    var body: some View {
        SettingsFocusedForm(initialFocus: nil, isReady: !isLoading) {
            SettingsScopeSection()
            if isLoading {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else if loadFailed {
                Section {
                    Text("Couldn’t load your badge setting.")
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        Task { await loadPreference() }
                    }
                }
            } else {
                Section(header: Text("Verification Badges"), footer: Text("When enabled, verification badges appear on profiles, posts, search, and conversations to verify trusted identities. Turning this off hides all verification badges.")) {
                    Toggle("Show Verification Badges", isOn: Binding(
                        get: { showBadges },
                        set: { newValue in
                            guard newValue != showBadges else { return }
                            showBadges = newValue
                            Task {
                                await updateBadgeVisibility(show: newValue)
                            }
                        }
                    ))
                    .disabled(isSaving)
                }
                
                if isSaving {
                    Section {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Saving…")
                                .appFont(AppTextRole.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Verification Badges")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .alert("Couldn’t Save Setting", isPresented: $showingErrorAlert) {
            Button("OK") { showingErrorAlert = false }
        } message: {
            if let error = errorMessage {
                Text(error)
            }
        }
        .task {
            await loadPreference()
        }
    }
    
    private func loadPreference() async {
        isLoading = true
        do {
            let pref = try await preferencesManager.getVerificationPrefs()
            // nil or false means badges are shown, true means hideBadges
            showBadges = !(pref?.hideBadges ?? false)
            loadFailed = false
        } catch {
            loadFailed = true
        }
        isLoading = false
    }
    
    private func updateBadgeVisibility(show: Bool) async {
        isSaving = true
        errorMessage = nil
        
        let newPref = AppBskyActorDefs.VerificationPrefs(hideBadges: !show)
        
        do {
            try await preferencesManager.setVerificationPrefs(newPref)
        } catch {
            errorMessage = UserFacingError.message(for: error, action: "save your badge setting")
            showingErrorAlert = errorMessage != nil
            // Revert local toggle state on error
            showBadges = !show
        }
        
        isSaving = false
    }
}
