import SwiftUI

struct HelpSettingsView: View {
    var initialFocus: SettingsControlID? = nil
    var body: some View {
        SettingsFocusedForm(initialFocus: initialFocus) {
            Section("Catbird support") {
                if let contactURL = LegalConfig.supportURL {
                    Link(destination: contactURL) {
                        SettingsNavigationRow(title: "Contact Catbird Support", systemImage: "envelope.fill", family: .support)
                    }
                } else if let email = LegalConfig.supportEmail, let mailURL = URL(string: "mailto:" + email) {
                    Link(destination: mailURL) {
                        SettingsNavigationRow(title: "Contact Catbird Support", systemImage: "envelope.fill", family: .support)
                    }
                } else {
                    Text("Find ways to reach Catbird support in About & Support.").foregroundStyle(.secondary)
                }
            }
            Section("Bluesky resources") {
                Link(destination: URL(string: "https://bsky.social/about/support")!) {
                    SettingsNavigationRow(title: "Bluesky Help Center", summary: "Answers about using Bluesky", systemImage: "questionmark.bubble", family: .support)
                }
                .settingsControl(.init(rawValue: "support.blueskyHelpCenter"))
                Link(destination: URL(string: "https://blueskyweb.zendesk.com/hc/en-us")!) {
                    SettingsNavigationRow(title: "Contact Bluesky Support", summary: "Opens Bluesky’s support site", systemImage: "arrow.up.right.square", family: .support)
                }
            }
        }
        .navigationTitle("Get Help")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
    }
}

#Preview {
  AsyncPreviewContent { appState in
    NavigationStack {
            HelpSettingsView()
        }
  }
}

