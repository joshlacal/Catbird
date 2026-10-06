import SwiftUI

struct PrivacyInteractionsSettingsView: View {
    let initialFocus: SettingsControlID?
    init(initialFocus: SettingsControlID? = nil) { self.initialFocus = initialFocus }
    var body: some View {
        SettingsFocusedForm(initialFocus: initialFocus) {
            SettingsScopeSection()
            Section("Interactions") {
                SettingsLink(screen: .defaultPostInteractions, summary: "Who can reply to or quote new posts", systemImage: "bubble.left.and.bubble.right", family: .privacy)
                    .settingsControl(.init(rawValue: "privacy.defaultPostInteractions"))
                SettingsLink(screen: .messages, summary: "Who can message you or invite you to groups", systemImage: "message", family: .privacy)
                    .settingsControl(.init(rawValue: "privacy.messages"))
                SettingsLink(screen: .activityPrivacy, summary: "Who may receive notifications about your posts", systemImage: "person.badge.clock", family: .privacy)
                    .settingsControl(.init(rawValue: "privacy.activitySubscriptions"))
            }
            Section("Visibility") {
                SettingsLink(screen: .visibility, summary: "Signed-out visitors, recommendation requests, repost credit", systemImage: "eye", family: .privacy)
            }
            Section("Connected Content") {
                SettingsLink(screen: .externalMedia, summary: "The same provider permissions used in Media & Links", systemImage: "play.rectangle", family: .media)
            }
            Section("People") {
                SettingsLink(screen: .mutedAccounts, systemImage: "speaker.slash", family: .moderation)
                SettingsLink(screen: .blockedAccounts, systemImage: "person.crop.circle.badge.xmark", family: .moderation)
            }
        }
        .navigationTitle("Privacy & Interactions")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
    }
}
