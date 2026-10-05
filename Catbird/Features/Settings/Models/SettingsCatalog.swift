import Foundation

/// Stable, non-localized identity for a retained setting, never a preference value.
public struct SettingsControlID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum SettingsScreenID: String, CaseIterable, Sendable {
    case home, accountSecurity, accountDetails, automationLabel, privacyInteractions, visibility
    case notifications, activitySubscriptions, activityPrivacy, messages, defaultPostInteractions
    case feedsDiscovery, feedFiltering, threads, discovery, interests, feedLibrary, verification
    case moderation, labelers, mutedAccounts, blockedAccounts
    case mediaLinks, externalMedia, language, appearance, appIcon, accessibility, textReadability
    case helpAbout, help, blueskyHelpCenter, about, licenses, advanced, providers, systemLogs, cache

    var title: String {
        switch self {
        case .home: "Settings"
        case .accountSecurity: "Account & Security"
        case .accountDetails: "Account Details"
        case .automationLabel: "Automation Label"
        case .privacyInteractions: "Privacy & Interactions"
        case .visibility: "Visibility & Attribution"
        case .notifications: "Notifications"
        case .activitySubscriptions: "People I Subscribe To"
        case .activityPrivacy: "Who Can Subscribe to My Posts"
        case .messages: "Direct Messages & Group Invitations"
        case .defaultPostInteractions: "Default Replies & Quotes"
        case .feedsDiscovery: "Feeds & Discovery"
        case .feedFiltering: "Feed Filtering"
        case .threads: "Threads"
        case .discovery: "Discovery"
        case .interests: "Interests"
        case .feedLibrary: "Feed Library"
        case .verification: "Verification Badges"
        case .moderation: "Moderation"
        case .labelers: "Moderation Services"
        case .mutedAccounts: "Muted Accounts"
        case .blockedAccounts: "Blocked Accounts"
        case .mediaLinks: "Media & Links"
        case .externalMedia: "External Media Permissions"
        case .language: "Language"
        case .appearance: "Appearance"
        case .appIcon: "App Icon"
        case .accessibility: "Accessibility"
        case .textReadability: "Text & Readability"
        case .helpAbout: "Help & About"
        case .help: "Get Help"
        case .blueskyHelpCenter: "Bluesky Help Center"
        case .about: "About & Support"
        case .licenses: "Open Source Licenses"
        case .advanced: "Advanced"
        case .providers: "Service Providers"
        case .systemLogs: "System Logs"
        case .cache: "Image & Web Cache"
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
    static let homeGroups: [(String, [SettingsScreenID])] = [
        ("Your account", [.accountSecurity, .privacyInteractions, .notifications]),
        ("Your experience", [.feedsDiscovery, .moderation, .mediaLinks, .language, .appearance, .accessibility]),
        ("Support", [.helpAbout, .advanced])
    ]

    static let entries: [SettingsSearchEntry] = {
        var rows: [SettingsSearchEntry] = []
        func add(_ title: String, _ screen: SettingsScreenID, _ control: String?, _ breadcrumb: String, _ scope: String = "Current account", _ aliases: [String] = []) {
            rows.append(SettingsSearchEntry(title: title, breadcrumb: breadcrumb, scope: scope, aliases: aliases,
                target: SettingsTarget(screen: screen, control: control.map { SettingsControlID(rawValue: $0) })))
        }
        for (_, screens) in homeGroups {
            for screen in screens {
                let scope: String
                switch screen {
                case .helpAbout: scope = "App"
                case .accountSecurity, .advanced: scope = "Account and this device"
                case .notifications: scope = "Account and device permission"
                case .language: scope = InterfaceLanguagePreferences.availableLanguages().count > 1 ? "Interface on this device; reading for current account" : "Current account"
                case .appearance: scope = "Account preferences; app icon on this device"
                case .accessibility: scope = "Account preferences and system accommodations"
                default: scope = "Current account"
                }
                let aliases: [String]
                switch screen {
                case .notifications: aliases = ["push", "badge", "alerts"]
                case .helpAbout: aliases = ["support", "contact", "about"]
                case .advanced: aliases = ["servers", "cache"]
                default: aliases = []
                }
                add(screen.title, screen, nil, "Settings", scope, aliases)
            }
        }
        add("Handle", .accountDetails, "account.handle", "Account & Security › Account Details", "Current account", ["username"])
        add("Email & Email Two-Factor Authentication", .accountDetails, "account.email", "Account & Security › Account Details", "Current account", ["2FA", "verification", "security code"])
        add("App Lock", .accountSecurity, "account.appLock", "Account & Security", "This device", ["Face ID", "Touch ID", "biometrics"])
        add("Automation Label", .automationLabel, nil, "Account & Security › Account Details", "Current account", ["bot"])
        add("Export Public Account Data", .accountDetails, "account.export", "Account & Security › Account Details", "Current account", ["CAR", "backup"])
        add("Deactivate Account", .accountDetails, "account.deactivate", "Account & Security › Account Details")
        add("Delete Account", .accountDetails, "account.delete", "Account & Security › Account Details", "Current account", ["delete", "remove account", "close account", "erase"])
        add("Sign Out", .accountSecurity, "account.signOut", "Account & Security", "Current account", ["log out", "logout", "sign off"])
        add("Default Replies & Quotes", .defaultPostInteractions, nil, "Privacy & Interactions", "New posts", ["reply permissions", "quote permissions"])
        add("Direct Messages & Group Invitations", .messages, "privacy.messages", "Privacy & Interactions", "Current account", ["DM", "chat", "invites"])
        add("Who Can Subscribe to My Posts", .activityPrivacy, "privacy.activitySubscriptions", "Privacy & Interactions", "Current account", ["post notifications", "activity privacy", "subscribers", "who may subscribe"])
        add("Visible to Signed-Out Visitors", .visibility, "privacy.loggedOutVisibility", "Privacy & Interactions › Visibility & Attribution", "Current account", ["logged out", "public profile"])
        add("Algorithmic Recommendations Request", .visibility, "privacy.algorithmicVisibility", "Privacy & Interactions › Visibility & Attribution", "Current account", ["hide posts", "discovery"])
        add("Credit Repost Discovery", .visibility, "privacy.attribution", "Privacy & Interactions › Visibility & Attribution")
        for (title, id, aliases) in [
            ("Adult Content", "adultContent", ["NSFW"]), ("Sexually Explicit Content", "nsfw", ["NSFW", "porn"]),
            ("Sexually Suggestive Content", "suggestive", ["sexual"]), ("Graphic Media", "graphic", ["gore", "violence"]),
            ("Non-Sexual Nudity", "nudity", ["nudity"]), ("Muted Words & Tags", "mutedWords", ["mute", "hashtags", "muted words"])] {
            add(title, .moderation, "moderation.\(id)", "Moderation", "Current account", aliases)
        }
        add("Moderation Services", .labelers, "moderation.labelers", "Moderation", "Current account", ["labelers", "labels"])
        add("Moderation Lists", .moderation, "moderation.lists", "Moderation", "Current account", ["lists", "block list", "mute list"])
        add("Muted Accounts", .mutedAccounts, nil, "Moderation", "Current account", ["mute people"])
        add("Blocked Accounts", .blockedAccounts, nil, "Moderation", "Current account", ["block people"])
        let feedFilterRows: [(String, String, [String])] = [("Hide Replies", "replies", ["replies"]), ("Hide Replies to People You Don’t Follow", "unfollowedReplies", ["unfollowed replies"]), ("Minimum Likes for Replies", "replyLikeThreshold", ["reply like threshold"]), ("Hide Reposts", "reposts", ["reposts"]), ("Hide Quote Posts", "quotes", ["quotes"]), ("Post Types", "contentType", ["content type", "text only", "media only"]), ("Hide Link Posts", "hideLinkPosts", ["links"]), ("Hide Repeated Parent Posts", "duplicates", ["duplicate posts"])]
        for (title, id, aliases) in feedFilterRows {
            add(title, .feedFiltering, "feed.\(id)", "Feeds & Discovery › Feed Filtering", "Current account", aliases)
        }
        let threadRows: [(String, String, [String])] = [("Reply Order", "threadSort", ["thread sort"]), ("Threaded Reply Layout", "threadLayout", ["thread layout"]), ("Load Author-Hidden Replies Automatically", "hiddenReplies", ["hidden replies"])]
        for (title, id, aliases) in threadRows { add(title, .threads, "feed.\(id)", "Feeds & Discovery › Threads", "Current account", aliases) }
        add("Show Trending Topics", .discovery, "feed.trendingTopics", "Feeds & Discovery › Discovery", "Current account", ["trending"])
        add("Show Trending Videos", .discovery, "feed.trendingVideos", "Feeds & Discovery › Discovery", "Current account", ["trending"])
        add("Your Interests", .interests, nil, "Feeds & Discovery › Discovery", "Current account", ["topics"])
        add("Feed Library", .feedLibrary, nil, "Feeds & Discovery", "Current account", ["saved feeds", "pin", "reorder"])
        add("Verification Badges", .verification, nil, "Feeds & Discovery")
        for (title, id, aliases) in [("Autoplay Videos", "autoplayVideos", ["playback"]), ("Open Links In-App", "openLinks", ["browser", "Safari"]), ("Enable Embedded Players", "embeddedPlayers", ["YouTube", "Spotify"])] { add(title, .mediaLinks, "media.\(id)", "Media & Links", "Current account", aliases) }
        add("External Media Permissions", .externalMedia, "media.providerPermissions", "Media & Links", "Current account", ["YouTube", "Spotify", "consent", "providers"])
        for (title, id) in [("YouTube", "youtube"), ("YouTube Shorts", "youtubeShorts"), ("Vimeo", "vimeo"), ("Twitch", "twitch"), ("Spotify", "spotify"), ("Apple Music", "appleMusic"), ("SoundCloud", "soundcloud"), ("GIPHY", "giphy"), ("Tenor", "tenor"), ("Klipy", "klipy"), ("Flickr", "flickr"), ("Bandcamp", "bandcamp")] {
            add(title + " Playback Permission", .externalMedia, "media.provider.\(id)", "Media & Links › External Media Permissions", "Current account", [title, "consent", "allow", "block"])
        }
        let notificationRows: [(String, String, [String])] = [("Push Alerts on This Device", "push", ["push notifications"]), ("Open System Notification Settings", "systemPermission", ["system permission"]), ("Message Notifications", "messages", ["direct messages", "DM"]), ("Mentions", "mention", []), ("Replies", "reply", []), ("Likes", "like", []), ("New Followers", "follow", ["follows"]), ("Reposts", "repost", []), ("Quotes", "quote", []), ("Likes of Your Reposts", "likeViaRepost", ["likes via repost"]), ("Reposts of Your Reposts", "repostViaRepost", ["reposts via repost"]), ("Posts from Your Subscriptions", "subscribedPost", ["subscribed posts"]), ("Starter Pack Signups", "starterpackJoined", ["starter pack joins"]), ("Account Verified", "verified", ["verified activity"]), ("Verification Removed", "unverified", ["unverified activity"])]
        for (title, id, aliases) in notificationRows {
            add(title, .notifications, "notifications.\(id)", "Notifications", id == "systemPermission" ? "This device" : "Current account", ["push", "alerts"] + aliases)
        }
        add("People I Subscribe To", .activitySubscriptions, nil, "Notifications", "Current account", ["post notification subscriptions", "people you subscribe to", "activity alerts"])
        for (title, id) in [("Theme", "theme"), ("Dark Mode", "darkMode"), ("Accent Color", "accent"), ("Reset Appearance", "reset")] {
            add(title, .appearance, "appearance.\(id)", "Appearance")
        }
        for (title, id) in [("Font Style", "fontStyle"), ("App Text Size", "fontSize"), ("Line Spacing", "lineSpacing"), ("Letter Spacing", "letterSpacing"), ("Use System Text Size", "dynamicType"), ("Maximum Text Size", "maxSize"), ("Show Reading Time Estimates", "readingTime"), ("Highlight Links", "highlightLinks"), ("Link Style", "linkStyle")] {
            let aliases: [String]
            switch id {
            case "fontStyle": aliases = ["font", "typeface"]
            case "fontSize": aliases = ["font size", "larger text", "text size"]
            case "maxSize": aliases = ["font", "larger text", "text size"]
            case "dynamicType": aliases = ["Dynamic Type", "system text size"]
            case "readingTime": aliases = ["reading time"]
            case "lineSpacing": aliases = ["paragraph spacing"]
            case "letterSpacing": aliases = ["tracking"]
            default: aliases = []
            }
            add(title, .textReadability, "text.\(id)", "Accessibility › Text & Readability", "Current account", aliases)
        }
        let accessibilityRows: [(String, String, [String])] = [("Require Alt Text Before Posting", "altText", ["image descriptions", "alt text"]), ("Display Larger Alt Text Badges", "altBadges", ["image description badges", "alt text badges"]), ("Reduce Motion in Catbird", "reduceMotion", ["animation"]), ("Prefer Crossfade Transitions", "crossfade", []), ("Increase Contrast in Catbird", "increaseContrast", []), ("Bold Text in Catbird", "boldText", []), ("Confirm Social Actions", "confirmActions", ["confirm actions"]), ("Disable Haptic Feedback", "haptics", ["haptics", "vibration"])]
        for (title, id, aliases) in accessibilityRows {
            add(title, .accessibility, "accessibility.\(id)", "Accessibility", "Current account", aliases)
        }
        let showsInterfaceLanguage = InterfaceLanguagePreferences.availableLanguages().count > 1
        for (title, id) in [("Interface Language", "interface"), ("Primary Reading Language", "primary"), ("Preferred Reading Languages", "content"), ("Hide Posts in Other Languages", "hideOtherLanguages"), ("Show Language Indicators", "indicators")] where id != "interface" || showsInterfaceLanguage {
            let aliases: [String]
            switch id {
            case "primary": aliases = ["primary language"]
            case "content": aliases = ["content languages", "reading languages"]
            case "hideOtherLanguages": aliases = ["feed language filter", "filter by language", "hide other languages"]
            case "indicators": aliases = ["language indicators"]
            default: aliases = []
            }
            add(title, .language, "languages.\(id)", "Language", id == "interface" ? "This device" : "Current account", aliases)
        }
        add("Default Reply Permissions", .defaultPostInteractions, "privacy.defaultPostInteractions", "Privacy & Interactions › Default Replies & Quotes", "New posts")
        add("Default Quote Permissions", .defaultPostInteractions, "privacy.defaultQuotes", "Privacy & Interactions › Default Replies & Quotes", "New posts")
        add("AppView Provider", .providers, "advanced.appView", "Advanced › Service Providers", "Current account", ["server", "Blacksky", "content provider"])
        add("Chat Provider", .providers, "advanced.chatProvider", "Advanced › Service Providers", "Current account", ["server", "messages"])
        add("App Icon", .appIcon, nil, "Appearance", "This device")
        add("Text & Readability", .textReadability, nil, "Accessibility", "Current account", ["font", "larger text", "Dynamic Type"])
        add("Get Help", .help, nil, "Help & About", "App")
        add("Bluesky Help Center", .help, "support.blueskyHelpCenter", "Help & About › Get Help", "App", ["FAQ", "Bluesky support"])
        add("About & Support", .about, nil, "Help & About", "App", ["version", "legal", "tip", "privacy policy", "terms", "support", "contact"])
        add("Open Source Licenses", .licenses, nil, "Help & About", "App")
        add("Replay Tips", .helpAbout, "support.replayTips", "Help & About", "Current account and this device", ["onboarding"])
        add("Service Providers", .providers, nil, "Advanced", "Current account", ["server", "AppView", "Blacksky", "chat"])
        #if DEBUG
        add("System Logs", .systemLogs, nil, "Advanced", "This device", ["diagnostics"])
        #endif
        add("Clear Image & Web Cache", .cache, "advanced.cache", "Advanced", "This device", ["storage", "Nuke", "WKWebView"])
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
