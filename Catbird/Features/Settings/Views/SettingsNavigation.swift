import SwiftUI

struct SettingsDestinationView: View {
    let target: SettingsTarget
    var body: some View {
        destination
            #if os(iOS)
            // Every Settings screen uses an inline title, matching the Settings home.
            .toolbarTitleDisplayMode(.inline)
            #endif
    }

    @ViewBuilder private var destination: some View {
        switch target.screen {
        case .home: SettingsView(isEmbedded: true)
        case .accountSecurity: AccountSecuritySettingsView(initialFocus: target.control)
        case .accountDetails: AccountSettingsView(initialFocus: target.control)
        case .automationLabel: AutomationLabelSettingsView()
        case .privacyInteractions: PrivacyInteractionsSettingsView(initialFocus: target.control)
        case .visibility: PrivacySecuritySettingsView(initialFocus: target.control)
        case .notifications: NotificationSettingsView(initialFocus: target.control)
        case .activitySubscriptions: ActivitySubscriptionsView()
        case .activityPrivacy: ActivityPrivacySettingsView(initialFocus: target.control)
        case .messages: ChatSettingsView(initialFocus: target.control, presentation: .navigation)
        case .defaultPostInteractions: DefaultPostInteractionSettingsView(initialFocus: target.control)
        case .feedsDiscovery: FeedsDiscoverySettingsView(initialFocus: target.control)
        case .feedFiltering: FeedFilterSettingsView(initialFocus: target.control)
        case .threads: ThreadSettingsView(initialFocus: target.control)
        case .discovery: DiscoverySettingsView(initialFocus: target.control)
        case .interests: InterestsSettingsView()
        case .feedLibrary: FeedLibrarySettingsView()
        case .verification: VerificationSettingsView()
        case .moderation: ModerationSettingsView(initialFocus: target.control)
        case .labelers: LabelerSettingsView(initialFocus: target.control)
        case .mutedAccounts: ModeratedAccountsSettingsView(kind: .muted)
        case .blockedAccounts: ModeratedAccountsSettingsView(kind: .blocked)
        case .mediaLinks: MediaLinksSettingsView(initialFocus: target.control)
        case .externalMedia: ExternalMediaPreferencesView(initialFocus: target.control)
        case .language: LanguageSettingsView(initialFocus: target.control)
        case .appearance: AppearanceSettingsView(initialFocus: target.control)
        case .appIcon: AppIconSettingsView()
        case .accessibility: AccessibilitySettingsView(initialFocus: target.control)
        case .textReadability: TextReadabilitySettingsView(initialFocus: target.control)
        case .helpAbout: HelpAboutSettingsView(initialFocus: target.control)
        case .help: HelpSettingsView(initialFocus: target.control)
        case .blueskyHelpCenter: HelpSettingsView(initialFocus: .init(rawValue: "support.blueskyHelpCenter"))
        case .about: AboutSettingsView()
        case .licenses: OpenSourceLicensesView()
        case .advanced: AdvancedSettingsHubView(initialFocus: target.control)
        case .providers: AdvancedSettingsView(initialFocus: target.control)
        case .systemLogs:
            #if DEBUG
            SystemLogView()
            #else
            AdvancedSettingsHubView()
            #endif
        case .cache: SettingsCacheView(initialFocus: target.control)
        }
    }
}

struct SettingsLink: View {
    let screen: SettingsScreenID
    var title: String? = nil
    var summary: String? = nil
    let systemImage: String
    let family: SettingsIconFamily
    var control: SettingsControlID? = nil
    var body: some View {
        NavigationLink(value: SettingsTarget(screen: screen, control: control)) {
            SettingsNavigationRow(title: title ?? screen.title, summary: summary, systemImage: systemImage, family: family)
        }
    }
}
