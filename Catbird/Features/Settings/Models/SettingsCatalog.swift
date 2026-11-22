import Foundation

/// Stable, non-localized identity for a retained setting, never a preference value.
public struct SettingsControlID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum SettingsScreenID: String, CaseIterable, Sendable {
    case home, accountSecurity, accountDetails, automationLabel, privacyInteractions, visibility
    case notifications, activitySubscriptions, activityPrivacy, messages, defaultPostInteractions
    case feedsDiscovery, feedFiltering, threads, discovery, interests, intelligenceOnboarding, originalsOnlyAccounts, feedLibrary, verification
    case moderation, labelers, mutedAccounts, blockedAccounts
    case mediaLinks, externalMedia, language, appearance, appIcon, accessibility, textReadability
    case helpAbout, help, blueskyHelpCenter, about, licenses, advanced, providers, systemLogs, cache

    var title: String {
        switch self {
        case .home: String(localized: "Settings", comment: "Navigation title for the root Settings screen.")
        case .accountSecurity: String(localized: "Account & Security", comment: "Settings category title.")
        case .accountDetails: String(localized: "Account Details", comment: "Settings screen title.")
        case .automationLabel: String(localized: "Automation Label", comment: "Settings screen title for bot/automation account label.")
        case .privacyInteractions: String(localized: "Privacy & Interactions", comment: "Settings category title.")
        case .visibility: String(localized: "Visibility & Attribution", comment: "Settings screen title.")
        case .notifications: String(localized: "Notifications", comment: "Settings category title.")
        case .activitySubscriptions: String(localized: "People I Subscribe To", comment: "Settings screen title for post notification subscriptions.")
        case .activityPrivacy: String(localized: "Who Can Subscribe to My Posts", comment: "Settings screen title.")
        case .messages: String(localized: "Direct Messages & Group Invitations", comment: "Settings screen title.")
        case .defaultPostInteractions: String(localized: "Default Replies & Quotes", comment: "Settings screen title.")
        case .feedsDiscovery: String(localized: "Feeds & Discovery", comment: "Settings category title.")
        case .feedFiltering: String(localized: "Feed Filtering", comment: "Settings screen title.")
        case .threads: String(localized: "Threads", comment: "Settings screen title.")
        case .discovery: String(localized: "Discovery", comment: "Settings screen title.")
        case .interests: String(localized: "Your Interests", comment: "Settings screen title.")
        case .intelligenceOnboarding: String(localized: "Catbird Intelligence", comment: "Settings screen title.")
        case .originalsOnlyAccounts: String(localized: "Originals-Only Accounts", comment: "Settings screen title.")
        case .feedLibrary: String(localized: "Feed Library", comment: "Settings screen title.")
        case .verification: String(localized: "Verification Badges", comment: "Settings screen title.")
        case .moderation: String(localized: "Moderation", comment: "Settings category title.")
        case .labelers: String(localized: "Moderation Services", comment: "Settings screen title.")
        case .mutedAccounts: String(localized: "Muted Accounts", comment: "Settings screen title.")
        case .blockedAccounts: String(localized: "Blocked Accounts", comment: "Settings screen title.")
        case .mediaLinks: String(localized: "Media & Links", comment: "Settings category title.")
        case .externalMedia: String(localized: "External Media Permissions", comment: "Settings screen title.")
        case .language: String(localized: "Language", comment: "Settings category title.")
        case .appearance: String(localized: "Appearance", comment: "Settings category title.")
        case .appIcon: String(localized: "App Icon", comment: "Settings screen title.")
        case .accessibility: String(localized: "Accessibility", comment: "Settings category title.")
        case .textReadability: String(localized: "Text & Readability", comment: "Settings screen title.")
        case .helpAbout: String(localized: "Help & About", comment: "Settings category title.")
        case .help: String(localized: "Get Help", comment: "Settings screen title.")
        case .blueskyHelpCenter: String(localized: "Bluesky Help Center", comment: "Settings screen title.")
        case .about: String(localized: "About & Support", comment: "Settings screen title.")
        case .licenses: String(localized: "Open Source Licenses", comment: "Settings screen title.")
        case .advanced: String(localized: "Advanced", comment: "Settings category title.")
        case .providers: String(localized: "Service Providers", comment: "Settings screen title.")
        case .systemLogs: String(localized: "System Logs", comment: "Settings screen title.")
        case .cache: String(localized: "Image & Web Cache", comment: "Settings screen title.")
        }
    }
}

public struct SettingsTarget: Hashable, Sendable {
    public let screen: SettingsScreenID
    public let control: SettingsControlID?
    public init(screen: SettingsScreenID, control: SettingsControlID? = nil) {
        self.screen = screen
        self.control = control
    }
}

struct SettingsSearchEntry: Identifiable {
    let title: String
    let breadcrumb: String
    let scope: String
    let aliases: [String]
    let target: SettingsTarget
    var id: SettingsTarget { target }
}

/// Only retained controls are indexed. Account names, muted words and private list contents are excluded.
enum SettingsCatalog {
    static var homeGroups: [(String, [SettingsScreenID])] {
        [
            (String(localized: "Your Account", comment: "Settings home section header."), [.accountSecurity, .privacyInteractions, .notifications]),
            (String(localized: "Your Experience", comment: "Settings home section header."), [.feedsDiscovery, .moderation, .mediaLinks, .language, .appearance, .accessibility]),
            (String(localized: "Support", comment: "Settings home section header."), [.helpAbout, .advanced])
        ]
    }

    private static var hasAppLanguageControl: Bool {
        #if os(iOS)
        return true
        #else
        return InterfaceLanguagePreferences.availableLanguages().count > 1
        #endif
    }

    static let entries: [SettingsSearchEntry] = {
        let currentAccountScope = String(localized: "Current account", comment: "Settings search scope label.")
        let thisDeviceScope = String(localized: "This device", comment: "Settings search scope label.")
        let appScope = String(localized: "App", comment: "Settings search scope label.")
        let newPostsScope = String(localized: "New posts", comment: "Settings search scope label.")

        var rows: [SettingsSearchEntry] = []
        func add(_ title: String, _ screen: SettingsScreenID, _ control: String?, _ breadcrumb: String, _ scope: String = currentAccountScope, _ aliases: [String] = []) {
            rows.append(SettingsSearchEntry(title: title, breadcrumb: breadcrumb, scope: scope, aliases: aliases,
                target: SettingsTarget(screen: screen, control: control.map { SettingsControlID(rawValue: $0) })))
        }
        for (_, screens) in homeGroups {
            for screen in screens {
                let scope: String
                switch screen {
                case .helpAbout: scope = appScope
                case .accountSecurity, .advanced: scope = String(localized: "Account and this device", comment: "Settings search scope label.")
                case .notifications: scope = String(localized: "Account and device permission", comment: "Settings search scope label.")
                case .language: scope = hasAppLanguageControl ? String(localized: "App language on this device; reading for current account", comment: "Settings search scope label for Language.") : currentAccountScope
                case .appearance: scope = String(localized: "Account preferences; app icon on this device", comment: "Settings search scope label.")
                case .accessibility: scope = String(localized: "Account preferences and system accommodations", comment: "Settings search scope label.")
                default: scope = currentAccountScope
                }
                let aliases: [String]
                switch screen {
                case .notifications: aliases = ["push", "badge", "alerts"]
                case .helpAbout: aliases = ["support", "contact", "about"]
                case .advanced: aliases = ["servers", "cache"]
                case .language: aliases = ["app language", "interface language", "UI language", "reading languages"]
                default: aliases = []
                }
                add(screen.title, screen, nil, SettingsScreenID.home.title, scope, aliases)
            }
        }
        add(String(localized: "Handle", comment: "Settings search entry for Bluesky handle / username."), .accountDetails, "account.handle", "\(SettingsScreenID.accountSecurity.title) › \(SettingsScreenID.accountDetails.title)", currentAccountScope, ["Handle", "username"])
        add(String(localized: "Manage Hosted Account", comment: "Settings search entry."), .accountDetails, "account.management", "\(SettingsScreenID.accountSecurity.title) › \(SettingsScreenID.accountDetails.title)", String(localized: "Provider website", comment: "Settings search scope label."), ["Manage Hosted Account", "email", "sign-in codes", "2FA", "verification", "change handle"])
        add(String(localized: "Require App Unlock", comment: "Settings search entry."), .accountSecurity, "account.appLock", SettingsScreenID.accountSecurity.title, thisDeviceScope, ["Require App Unlock", "app lock", "Face ID", "Touch ID", "biometrics"])
        add(SettingsScreenID.automationLabel.title, .automationLabel, nil, "\(SettingsScreenID.accountSecurity.title) › \(SettingsScreenID.accountDetails.title)", currentAccountScope, ["Automation Label", "bot"])
        add(String(localized: "Export Public Account Data", comment: "Settings search entry."), .accountDetails, "account.export", "\(SettingsScreenID.accountSecurity.title) › \(SettingsScreenID.accountDetails.title)", currentAccountScope, ["Export Public Account Data", "CAR", "backup"])
        add(String(localized: "Delete Account", comment: "Settings search entry."), .accountDetails, "account.delete", "\(SettingsScreenID.accountSecurity.title) › \(SettingsScreenID.accountDetails.title)", currentAccountScope, ["Delete Account", "account deletion options", "remove account", "close account", "erase"])
        add(String(localized: "Sign Out", comment: "Settings search entry."), .accountSecurity, "account.signOut", SettingsScreenID.accountSecurity.title, currentAccountScope, ["Sign Out", "log out", "logout", "sign off"])
        add(SettingsScreenID.defaultPostInteractions.title, .defaultPostInteractions, nil, SettingsScreenID.privacyInteractions.title, newPostsScope, ["Default Replies & Quotes", "reply permissions", "quote permissions"])
        add(SettingsScreenID.messages.title, .messages, "privacy.messages", SettingsScreenID.privacyInteractions.title, currentAccountScope, ["Direct Messages & Group Invitations", "DM", "chat", "invites"])
        add(SettingsScreenID.activityPrivacy.title, .activityPrivacy, "privacy.activitySubscriptions", SettingsScreenID.privacyInteractions.title, currentAccountScope, ["Who Can Subscribe to My Posts", "post notifications", "activity privacy", "subscribers", "who may subscribe"])
        add(String(localized: "Visible to Signed-Out Visitors", comment: "Settings search entry."), .visibility, "privacy.loggedOutVisibility", "\(SettingsScreenID.privacyInteractions.title) › \(SettingsScreenID.visibility.title)", currentAccountScope, ["Visible to Signed-Out Visitors", "logged out", "public profile"])
        add(String(localized: "Ask Apps to Exclude My Posts from Recommendations", comment: "Settings search entry."), .visibility, "privacy.algorithmicVisibility", "\(SettingsScreenID.privacyInteractions.title) › \(SettingsScreenID.visibility.title)", currentAccountScope, ["Ask Apps to Exclude My Posts from Recommendations", "algorithmic recommendations", "hide posts", "discovery"])
        add(String(localized: "Credit Repost Discovery", comment: "Settings search entry."), .visibility, "privacy.attribution", "\(SettingsScreenID.privacyInteractions.title) › \(SettingsScreenID.visibility.title)", currentAccountScope, ["Credit Repost Discovery"])
        add(String(localized: "Enable Adult Content", comment: "Settings search entry."), .moderation, "moderation.adultContent", SettingsScreenID.moderation.title, currentAccountScope, ["Enable Adult Content", "NSFW", "adult content"])
        // Builtin content filters use the names and control ids the Moderation screen shows.
        let contentFilterAliases: [String: [String]] = [
            "porn": ["NSFW", "porn", "explicit", "sexual"], "sexual": ["suggestive", "sexual"],
            "graphic-media": ["gore", "violence", "graphic"], "nudity": ["nudity", "nude", "artistic"]]
        for identifier in ContentFilterSettings.builtinIdentifiers {
            guard let definition = ModerationLabelDefinition.builtin(forLabelValue: identifier) else { continue }
            add(ModerationPresentation.name(for: definition), .moderation, ContentFilterSettings.controlID(for: identifier).rawValue,
                SettingsScreenID.moderation.title, currentAccountScope, contentFilterAliases[identifier] ?? [])
        }
        add(String(localized: "Muted Words & Tags", comment: "Settings search entry."), .moderation, "moderation.mutedWords", SettingsScreenID.moderation.title, currentAccountScope, ["Muted Words & Tags", "mute", "hashtags", "muted words"])
        add(SettingsScreenID.labelers.title, .labelers, "moderation.labelers", SettingsScreenID.moderation.title, currentAccountScope, ["Moderation Services", "labelers", "labels"])
        add(String(localized: "Moderation Lists", comment: "Settings search entry."), .moderation, "moderation.lists", SettingsScreenID.moderation.title, currentAccountScope, ["Moderation Lists", "lists", "block list", "mute list"])
        add(SettingsScreenID.mutedAccounts.title, .mutedAccounts, nil, SettingsScreenID.moderation.title, currentAccountScope, ["Muted Accounts", "mute people"])
        add(SettingsScreenID.blockedAccounts.title, .blockedAccounts, nil, SettingsScreenID.moderation.title, currentAccountScope, ["Blocked Accounts", "block people"])
        let feedFilterRows: [(String, String, [String])] = [
            (String(localized: "Hide Replies", comment: "Settings search entry."), "replies", ["Hide Replies", "replies"]),
            (String(localized: "Hide Replies to People You Don’t Follow", comment: "Settings search entry."), "unfollowedReplies", ["Hide Replies to People You Don’t Follow", "unfollowed replies"]),
            (String(localized: "Minimum Likes for Replies", comment: "Settings search entry."), "replyLikeThreshold", ["Minimum Likes for Replies", "reply like threshold"]),
            (String(localized: "Hide Reposts", comment: "Settings search entry."), "reposts", ["Hide Reposts", "reposts"]),
            (String(localized: "Hide Quote Posts", comment: "Settings search entry."), "quotes", ["Hide Quote Posts", "quotes"]),
            (String(localized: "Post Types", comment: "Settings search entry."), "contentType", ["Post Types", "content type", "text only", "media only"]),
            (String(localized: "Hide Link Posts", comment: "Settings search entry."), "hideLinkPosts", ["Hide Link Posts", "links"]),
            (String(localized: "Hide Repeated Parent Posts", comment: "Settings search entry."), "duplicates", ["Hide Repeated Parent Posts", "duplicate posts"])
        ]
        for (title, id, aliases) in feedFilterRows {
            add(title, .feedFiltering, "feed.\(id)", "\(SettingsScreenID.feedsDiscovery.title) › \(SettingsScreenID.feedFiltering.title)", currentAccountScope, aliases)
        }
        let threadRows: [(String, String, [String])] = [
            (String(localized: "Reply Order", comment: "Settings search entry."), "threadSort", ["Reply Order", "thread sort"]),
            (String(localized: "Threaded Reply Layout", comment: "Settings search entry."), "threadLayout", ["Threaded Reply Layout", "thread layout"]),
            (String(localized: "Load Author-Hidden Replies Automatically", comment: "Settings search entry."), "hiddenReplies", ["Load Author-Hidden Replies Automatically", "hidden replies"])
        ]
        for (title, id, aliases) in threadRows { add(title, .threads, "feed.\(id)", "\(SettingsScreenID.feedsDiscovery.title) › \(SettingsScreenID.threads.title)", currentAccountScope, aliases) }
        add(String(localized: "Show Trending Topics", comment: "Settings search entry."), .discovery, "feed.trendingTopics", "\(SettingsScreenID.feedsDiscovery.title) › \(SettingsScreenID.discovery.title)", currentAccountScope, ["Show Trending Topics", "trending"])
        add(String(localized: "Show Trending Videos", comment: "Settings search entry."), .discovery, "feed.trendingVideos", "\(SettingsScreenID.feedsDiscovery.title) › \(SettingsScreenID.discovery.title)", currentAccountScope, ["Show Trending Videos", "trending"])
        add(SettingsScreenID.interests.title, .interests, nil, "\(SettingsScreenID.feedsDiscovery.title) › \(SettingsScreenID.discovery.title)", currentAccountScope, ["Your Interests", "topics"])
        add(SettingsScreenID.intelligenceOnboarding.title, .intelligenceOnboarding, nil, SettingsScreenID.feedsDiscovery.title, currentAccountScope, ["Catbird Intelligence", "scene explorer", "onboarding", "rerun", "tune feed", "intelligence", "taste duels", "starting lineup"])
        add(String(localized: "Explore Scenes & Build Lineup", comment: "Settings search entry."), .intelligenceOnboarding, "intel.sceneExplorer", "\(SettingsScreenID.feedsDiscovery.title) › \(SettingsScreenID.intelligenceOnboarding.title)", currentAccountScope, ["Explore Scenes & Build Lineup", "scenes", "communities", "onboarding"])
        add(String(localized: "Recalibrate Taste & Feed Pace", comment: "Settings search entry."), .intelligenceOnboarding, "intel.tasteCalibration", "\(SettingsScreenID.feedsDiscovery.title) › \(SettingsScreenID.intelligenceOnboarding.title)", currentAccountScope, ["Recalibrate Taste & Feed Pace", "taste duels", "pace", "repost tamer"])
        add(SettingsScreenID.originalsOnlyAccounts.title, .originalsOnlyAccounts, "intel.originalsOnly", "\(SettingsScreenID.feedsDiscovery.title) › \(SettingsScreenID.feedFiltering.title)", currentAccountScope, ["Originals-Only Accounts", "repost tamer", "originals only", "mute reposts"])
        add(String(localized: "Rerun Welcome Onboarding Now", comment: "Settings search entry."), .intelligenceOnboarding, "intel.rerunWelcome", "\(SettingsScreenID.feedsDiscovery.title) › \(SettingsScreenID.intelligenceOnboarding.title)", currentAccountScope, ["Rerun Welcome Onboarding Now", "replay onboarding", "welcome", "setup"])
        add(SettingsScreenID.feedLibrary.title, .feedLibrary, nil, SettingsScreenID.feedsDiscovery.title, currentAccountScope, ["Feed Library", "saved feeds", "pin", "reorder"])
        add(SettingsScreenID.verification.title, .verification, nil, SettingsScreenID.feedsDiscovery.title, currentAccountScope, ["Verification Badges"])
        for (title, id, aliases) in [
            (String(localized: "Autoplay Videos", comment: "Settings search entry."), "autoplayVideos", ["Autoplay Videos", "playback"]),
            (String(localized: "Open Links In-App", comment: "Settings search entry."), "openLinks", ["Open Links In-App", "browser", "Safari"]),
            (String(localized: "Enable Embedded Players", comment: "Settings search entry."), "embeddedPlayers", ["Enable Embedded Players", "YouTube", "Spotify"])
        ] { add(title, .mediaLinks, "media.\(id)", SettingsScreenID.mediaLinks.title, currentAccountScope, aliases) }
        add(SettingsScreenID.externalMedia.title, .externalMedia, "media.providerPermissions", SettingsScreenID.mediaLinks.title, currentAccountScope, ["External Media Permissions", "YouTube", "Spotify", "consent", "providers"])
        for (providerName, id) in [("YouTube", "youtube"), ("YouTube Shorts", "youtubeShorts"), ("Vimeo", "vimeo"), ("Twitch", "twitch"), ("Spotify", "spotify"), ("Apple Music", "appleMusic"), ("SoundCloud", "soundcloud"), ("GIPHY", "giphy"), ("Tenor", "tenor"), ("Klipy", "klipy"), ("Flickr", "flickr"), ("Bandcamp", "bandcamp")] {
            add(String(localized: "\(providerName) Playback Permission", comment: "Settings search entry for external media provider consent — variable is the provider brand name."), .externalMedia, "media.provider.\(id)", "\(SettingsScreenID.mediaLinks.title) › \(SettingsScreenID.externalMedia.title)", currentAccountScope, [providerName, "\(providerName) Playback Permission", "consent", "allow", "block"])
        }
        let notificationRows: [(String, String, [String])] = [
            (String(localized: "Push Alerts on This Device", comment: "Settings search entry."), "push", ["Push Alerts on This Device", "push notifications"]),
            (String(localized: "Open System Notification Settings", comment: "Settings search entry."), "systemPermission", ["Open System Notification Settings", "system permission"]),
            (String(localized: "Direct Message Push Alerts", comment: "Settings search entry."), "messages", ["Direct Message Push Alerts", "message notifications", "direct messages", "DM"]),
            (String(localized: "Mentions", comment: "Settings search entry."), "mention", ["Mentions"]),
            (String(localized: "Replies", comment: "Settings search entry."), "reply", ["Replies"]),
            (String(localized: "Likes", comment: "Settings search entry."), "like", ["Likes"]),
            (String(localized: "New Followers", comment: "Settings search entry."), "follow", ["New Followers", "follows"]),
            (String(localized: "Reposts", comment: "Settings search entry."), "repost", ["Reposts"]),
            (String(localized: "Quotes", comment: "Settings search entry."), "quote", ["Quotes"]),
            (String(localized: "Likes of Your Reposts", comment: "Settings search entry."), "likeViaRepost", ["Likes of Your Reposts", "likes via repost"]),
            (String(localized: "Reposts of Your Reposts", comment: "Settings search entry."), "repostViaRepost", ["Reposts of Your Reposts", "reposts via repost"]),
            (String(localized: "Posts from Your Subscriptions", comment: "Settings search entry."), "subscribedPost", ["Posts from Your Subscriptions", "subscribed posts"]),
            (String(localized: "Starter Pack Signups", comment: "Settings search entry."), "starterpackJoined", ["Starter Pack Signups", "starter pack joins"]),
            (String(localized: "Account Verified", comment: "Settings search entry."), "verified", ["Account Verified", "verified activity"]),
            (String(localized: "Verification Removed", comment: "Settings search entry."), "unverified", ["Verification Removed", "unverified activity"])
        ]
        for (title, id, aliases) in notificationRows {
            add(title, .notifications, "notifications.\(id)", SettingsScreenID.notifications.title, id == "systemPermission" ? thisDeviceScope : currentAccountScope, ["push", "alerts"] + aliases)
        }
        add(SettingsScreenID.activitySubscriptions.title, .activitySubscriptions, nil, SettingsScreenID.notifications.title, currentAccountScope, ["People I Subscribe To", "post notification subscriptions", "people you subscribe to", "activity alerts"])
        for (title, id, englishTitle) in [
            (String(localized: "App Theme", comment: "Settings search entry."), "theme", "App Theme"),
            (String(localized: "Dark Mode Style", comment: "Settings search entry."), "darkMode", "Dark Mode Style"),
            (String(localized: "Accent Color", comment: "Settings search entry."), "accent", "Accent Color"),
            (String(localized: "Reset Appearance", comment: "Settings search entry."), "reset", "Reset Appearance")
        ] {
            add(title, .appearance, "appearance.\(id)", SettingsScreenID.appearance.title, currentAccountScope, [englishTitle])
        }
        for (title, id, englishTitle) in [
            (String(localized: "Font Style", comment: "Settings search entry."), "fontStyle", "Font Style"),
            (String(localized: "App Text Size", comment: "Settings search entry."), "fontSize", "App Text Size"),
            (String(localized: "Line Spacing", comment: "Settings search entry."), "lineSpacing", "Line Spacing"),
            (String(localized: "Letter Spacing", comment: "Settings search entry."), "letterSpacing", "Letter Spacing"),
            (String(localized: "Use System Text Size", comment: "Settings search entry."), "dynamicType", "Use System Text Size"),
            (String(localized: "Maximum Text Size", comment: "Settings search entry."), "maxSize", "Maximum Text Size"),
            (String(localized: "Show Reading Time Estimates", comment: "Settings search entry."), "readingTime", "Show Reading Time Estimates"),
            (String(localized: "Highlight Links", comment: "Settings search entry."), "highlightLinks", "Highlight Links"),
            (String(localized: "Link Style", comment: "Settings search entry."), "linkStyle", "Link Style")
        ] {
            let aliases: [String]
            switch id {
            case "fontStyle": aliases = [englishTitle, "font", "typeface"]
            case "fontSize": aliases = [englishTitle, "font size", "larger text", "text size"]
            case "maxSize": aliases = [englishTitle, "font", "larger text", "text size"]
            case "dynamicType": aliases = [englishTitle, "Dynamic Type", "system text size"]
            case "readingTime": aliases = [englishTitle, "reading time"]
            case "lineSpacing": aliases = [englishTitle, "paragraph spacing"]
            case "letterSpacing": aliases = [englishTitle, "tracking"]
            default: aliases = [englishTitle]
            }
            add(title, .textReadability, "text.\(id)", "\(SettingsScreenID.accessibility.title) › \(SettingsScreenID.textReadability.title)", currentAccountScope, aliases)
        }
        let accessibilityRows: [(String, String, [String])] = [
            (String(localized: "Require Alt Text Before Posting", comment: "Settings search entry."), "altText", ["Require Alt Text Before Posting", "image descriptions", "alt text"]),
            (String(localized: "Display Larger Alt Text Badges", comment: "Settings search entry."), "altBadges", ["Display Larger Alt Text Badges", "image description badges", "alt text badges"]),
            (String(localized: "Reduce Motion in Catbird", comment: "Settings search entry."), "reduceMotion", ["Reduce Motion in Catbird", "animation"]),
            (String(localized: "Prefer Crossfade Transitions", comment: "Settings search entry."), "crossfade", ["Prefer Crossfade Transitions"]),
            (String(localized: "Increase Contrast in Catbird", comment: "Settings search entry."), "increaseContrast", ["Increase Contrast in Catbird"]),
            (String(localized: "Bold Text in Catbird", comment: "Settings search entry."), "boldText", ["Bold Text in Catbird"]),
            (String(localized: "Confirm Social Actions", comment: "Settings search entry."), "confirmActions", ["Confirm Social Actions", "confirm actions"]),
            (String(localized: "Disable Haptic Feedback", comment: "Settings search entry."), "haptics", ["Disable Haptic Feedback", "haptics", "vibration"])
        ]
        for (title, id, aliases) in accessibilityRows {
            add(title, .accessibility, "accessibility.\(id)", SettingsScreenID.accessibility.title, currentAccountScope, aliases)
        }
        let showsAppLanguage = hasAppLanguageControl
        for (title, id) in [
            (String(localized: "App Language", comment: "Settings search entry for Catbird's UI language."), "interface"),
            (String(localized: "Primary Reading Language", comment: "Settings search entry."), "primary"),
            (String(localized: "Preferred Reading Languages", comment: "Settings search entry."), "content"),
            (String(localized: "Hide Posts in Other Languages", comment: "Settings search entry."), "hideOtherLanguages"),
            (String(localized: "Show Language Indicators", comment: "Settings search entry."), "indicators")
        ] where id != "interface" || showsAppLanguage {
            let aliases: [String]
            switch id {
            case "interface": aliases = ["App Language", "Interface Language", "UI language", "per-app language", "system language"]
            case "primary": aliases = ["Primary Reading Language", "primary language"]
            case "content": aliases = ["Preferred Reading Languages", "content languages", "reading languages"]
            case "hideOtherLanguages": aliases = ["Hide Posts in Other Languages", "feed language filter", "filter by language", "hide other languages"]
            case "indicators": aliases = ["Show Language Indicators", "language indicators"]
            default: aliases = []
            }
            add(title, .language, "languages.\(id)", SettingsScreenID.language.title, id == "interface" ? thisDeviceScope : currentAccountScope, aliases)
        }
        add(String(localized: "Who Can Reply", comment: "Settings search entry."), .defaultPostInteractions, "privacy.defaultPostInteractions", "\(SettingsScreenID.privacyInteractions.title) › \(SettingsScreenID.defaultPostInteractions.title)", newPostsScope, ["Who Can Reply", "default reply permissions"])
        add(String(localized: "Allow Quote Posts", comment: "Settings search entry."), .defaultPostInteractions, "privacy.defaultQuotes", "\(SettingsScreenID.privacyInteractions.title) › \(SettingsScreenID.defaultPostInteractions.title)", newPostsScope, ["Allow Quote Posts", "default quote permissions"])
        add(String(localized: "AppView Provider", comment: "Settings search entry."), .providers, "advanced.appView", "\(SettingsScreenID.advanced.title) › \(SettingsScreenID.providers.title)", currentAccountScope, ["AppView Provider", "server", "Blacksky", "content provider"])
        add(String(localized: "Chat Provider", comment: "Settings search entry."), .providers, "advanced.chatProvider", "\(SettingsScreenID.advanced.title) › \(SettingsScreenID.providers.title)", currentAccountScope, ["Chat Provider", "server", "messages"])
        add(SettingsScreenID.appIcon.title, .appIcon, nil, SettingsScreenID.appearance.title, thisDeviceScope, ["App Icon"])
        add(SettingsScreenID.textReadability.title, .textReadability, nil, SettingsScreenID.accessibility.title, currentAccountScope, ["Text & Readability", "font", "larger text", "Dynamic Type"])
        add(SettingsScreenID.help.title, .help, nil, SettingsScreenID.helpAbout.title, appScope, ["Get Help"])
        add(SettingsScreenID.blueskyHelpCenter.title, .help, "support.blueskyHelpCenter", "\(SettingsScreenID.helpAbout.title) › \(SettingsScreenID.help.title)", appScope, ["Bluesky Help Center", "FAQ", "Bluesky support"])
        add(SettingsScreenID.about.title, .about, nil, SettingsScreenID.helpAbout.title, appScope, ["About & Support", "version", "legal", "tip", "privacy policy", "terms", "support", "contact"])
        add(SettingsScreenID.licenses.title, .licenses, nil, SettingsScreenID.helpAbout.title, appScope, ["Open Source Licenses"])
        add(String(localized: "Replay Tips", comment: "Settings search entry."), .helpAbout, "support.replayTips", SettingsScreenID.helpAbout.title, String(localized: "Current account and this device", comment: "Settings search scope label."), ["Replay Tips", "onboarding"])
        add(SettingsScreenID.providers.title, .providers, nil, SettingsScreenID.advanced.title, currentAccountScope, ["Service Providers", "server", "AppView", "Blacksky", "chat"])
        #if DEBUG
        add(SettingsScreenID.systemLogs.title, .systemLogs, nil, SettingsScreenID.advanced.title, thisDeviceScope, ["System Logs", "diagnostics"])
        #endif
        add(String(localized: "Clear Image & Web Cache", comment: "Settings search entry."), .cache, "advanced.cache", SettingsScreenID.advanced.title, thisDeviceScope, ["Clear Image & Web Cache", "storage", "Nuke", "WKWebView"])
        return rows
    }()

    static func search(_ query: String) -> [SettingsSearchEntry] {
        let terms = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return [] }
        return entries.filter { entry in
            let text = ([entry.title, entry.breadcrumb] + entry.aliases).joined(separator: " ").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            return terms.allSatisfy { text.contains($0) }
        }
    }
}
