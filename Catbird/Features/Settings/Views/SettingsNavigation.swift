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
        case .intelligenceOnboarding: IntelligenceOnboardingHubView(initialFocus: target.control)
        case .originalsOnlyAccounts: OriginalsOnlyAccountsView()
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
    private let customTitleText: LocalizedStringKey?
    private let customTitleString: String?
    private let summaryKey: LocalizedStringKey?
    private let summaryString: String?
    let systemImage: String
    let family: SettingsIconFamily
    var control: SettingsControlID? = nil

    init(
        screen: SettingsScreenID,
        summary: LocalizedStringKey? = nil,
        systemImage: String,
        family: SettingsIconFamily,
        control: SettingsControlID? = nil
    ) {
        self.screen = screen
        self.customTitleText = nil
        self.customTitleString = nil
        self.summaryKey = summary
        self.summaryString = nil
        self.systemImage = systemImage
        self.family = family
        self.control = control
    }

    @_disfavoredOverload
    init(
        screen: SettingsScreenID,
        title: String? = nil,
        summary: String? = nil,
        systemImage: String,
        family: SettingsIconFamily,
        control: SettingsControlID? = nil
    ) {
        self.screen = screen
        self.customTitleText = nil
        self.customTitleString = title
        self.summaryKey = nil
        self.summaryString = summary
        self.systemImage = systemImage
        self.family = family
        self.control = control
    }

    var body: some View {
        NavigationLink(value: SettingsTarget(screen: screen, control: control)) {
            if let customTitleText {
                SettingsNavigationRow(title: customTitleText, summary: summaryKey, systemImage: systemImage, family: family)
            } else if let summaryKey, customTitleString == nil {
                SettingsNavigationRow(title: screen.title, summary: summaryKey, systemImage: systemImage, family: family)
            } else {
                SettingsNavigationRow(title: customTitleString ?? screen.title, summary: summaryString, systemImage: systemImage, family: family)
            }
        }
    }
}
