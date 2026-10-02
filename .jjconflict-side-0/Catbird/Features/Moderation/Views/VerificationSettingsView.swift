import SwiftUI
import Petrel

/// View for configuring verification badge visibility in Moderation Settings
struct VerificationSettingsView: View {
    @Environment(AppState.self) private var appState
    
    @State private var showBadges: Bool = true
    @State private var isLoading: Bool = true
    @State private var isSaving: Bool = false
    @State private var errorMessage: String? = nil
    @State private var showingErrorAlert: Bool = false
    
    private var preferencesManager: PreferencesManager {
        appState.preferencesManager
    }
    
    var body: some View {
        Form {
            if isLoading {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                Section(header: Text("Verification Badges"), footer: Text("When enabled, verification badges appear on profiles, posts, search, and conversations to verify trusted identities. Turning this off hides all verification badges.")) {
                    Toggle("Show verification badges", isOn: Binding(
                        get: { showBadges },
                        set: { newValue in
                            guard newValue != showBadges else { return }
                            showBadges = newValue
                            Task {
                                await updateBadgeVisibility(show: newValue)
                            }
                        }
                    ))
                    .tint(.blue)
                    .disabled(isSaving)
                }
                
                if isSaving {
                    Section {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Saving preference...")
                                .font(.subheadline)
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
        .alert("Error Updating Setting", isPresented: $showingErrorAlert) {
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
        } catch {
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
            showingErrorAlert = true
            // Revert local toggle state on error
            showBadges = !show
        }
        
        isSaving = false
    }
}
