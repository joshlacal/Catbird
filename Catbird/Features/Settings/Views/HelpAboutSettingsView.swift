import SwiftUI

struct HelpAboutSettingsView: View {
    @Environment(AppState.self) private var appState
    let initialFocus: SettingsControlID?
    @State private var confirmingReplay = false
    init(initialFocus: SettingsControlID? = nil) { self.initialFocus = initialFocus }
    var body: some View {
        SettingsFocusedForm(initialFocus: initialFocus) {
            Section("Help") {
                SettingsLink(screen: .help, summary: "Catbird support and Bluesky help resources", systemImage: "questionmark.circle", family: .support)
                Button { confirmingReplay = true } label: {
                    SettingsNavigationRow(title: "Replay Tips", summary: "Reset onboarding for this account and tips on this device", systemImage: "lightbulb", family: .support)
                }
                .settingsControl(.init(rawValue: "support.replayTips"))
            }
            Section("Catbird") {
                SettingsLink(screen: .about, summary: "Optional tips, version, legal and support links", systemImage: "info.circle", family: .support)
                SettingsLink(screen: .licenses, systemImage: "doc.text", family: .support)
            }
        }
        .navigationTitle("Help & About")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog("Replay Tips?", isPresented: $confirmingReplay, titleVisibility: .visible) {
            Button("Replay Tips") {
                appState.onboardingManager.resetAllOnboarding(for: appState.userDID)
                appState.toastManager.show(ToastItem(
                    message: "Tips will appear again the next time you open Catbird.",
                    icon: "lightbulb.fill"
                ))
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Onboarding for this account and Catbird tips on this device will appear again the next time you open Catbird.") }
    }
}
