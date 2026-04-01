import Foundation
import SwiftData
import Observation

/// SwiftData model for app settings that aren't synced with the Bluesky server
@Model
final class AppSettingsModel {
    // Legacy singleton ID (used for migration from shared row)
    static let legacySharedId = "app_settings"

    private static let appGroupSuiteName = "group.blue.catbird.shared"
    private static let activeSettingsAccountDIDKey = "lastActiveSettingsAccountDID"

    /// Per-account settings ID
    static func settingsId(for accountDID: String) -> String {
        "app_settings_\(accountDID)"
    }

    static func sharedDefaults() -> UserDefaults {
        UserDefaults(suiteName: appGroupSuiteName) ?? .standard
    }

    static func scopedKey(_ baseKey: String, accountDID: String?) -> String {
        guard let accountDID, !accountDID.isEmpty else { return baseKey }
        return "\(baseKey).\(accountDID)"
    }

    static func stringValue(
        for baseKey: String,
        accountDID: String?,
        defaults: UserDefaults = .standard,
        includeLegacyFallback: Bool = true
    )
        -> String?
    {
        if let accountDID, !accountDID.isEmpty,
            let value = defaults.string(forKey: scopedKey(baseKey, accountDID: accountDID))
        {
            return value
        }

        guard includeLegacyFallback else { return nil }
        return defaults.string(forKey: baseKey)
    }

    static func stringArrayValue(
        for baseKey: String,
        accountDID: String?,
        defaults: UserDefaults = .standard,
        includeLegacyFallback: Bool = true
    ) -> [String]? {
        if let accountDID, !accountDID.isEmpty,
            let value = defaults.stringArray(forKey: scopedKey(baseKey, accountDID: accountDID))
        {
            return value
        }

        guard includeLegacyFallback else { return nil }
        return defaults.stringArray(forKey: baseKey)
    }

    static func boolValue(
        for baseKey: String,
        accountDID: String?,
        defaults: UserDefaults = .standard,
        includeLegacyFallback: Bool = true
    )
        -> Bool?
    {
        if let accountDID, !accountDID.isEmpty {
            let scopedKey = scopedKey(baseKey, accountDID: accountDID)
            if defaults.object(forKey: scopedKey) != nil {
                return defaults.bool(forKey: scopedKey)
            }
        }

        guard includeLegacyFallback else { return nil }
        guard defaults.object(forKey: baseKey) != nil else { return nil }
        return defaults.bool(forKey: baseKey)
    }

    static func doubleValue(
        for baseKey: String,
        accountDID: String?,
        defaults: UserDefaults = .standard,
        includeLegacyFallback: Bool = true
    ) -> Double? {
        if let accountDID, !accountDID.isEmpty {
            let scopedKey = scopedKey(baseKey, accountDID: accountDID)
            if defaults.object(forKey: scopedKey) != nil {
                return defaults.double(forKey: scopedKey)
            }
        }

        guard includeLegacyFallback else { return nil }
        guard defaults.object(forKey: baseKey) != nil else { return nil }
        return defaults.double(forKey: baseKey)
    }

    static func intValue(
        for baseKey: String,
        accountDID: String?,
        defaults: UserDefaults = .standard,
        includeLegacyFallback: Bool = true
    )
        -> Int?
    {
        if let accountDID, !accountDID.isEmpty {
            let scopedKey = scopedKey(baseKey, accountDID: accountDID)
            if defaults.object(forKey: scopedKey) != nil {
                return defaults.integer(forKey: scopedKey)
            }
        }

        guard includeLegacyFallback else { return nil }
        guard defaults.object(forKey: baseKey) != nil else { return nil }
        return defaults.integer(forKey: baseKey)
    }

    static func hasPerAccountSettings(in modelContext: ModelContext) throws -> Bool {
        let legacyId = legacySharedId
        let descriptor = FetchDescriptor<AppSettingsModel>(
            predicate: #Predicate { $0.id != legacyId }
        )
        return try !modelContext.fetch(descriptor).isEmpty
    }

    static func shouldUseLegacyFallback(for accountDID: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let accountDID, !accountDID.isEmpty else { return true }
        guard let activeAccountDID = defaults.string(forKey: activeSettingsAccountDIDKey) else {
            return true
        }
        return activeAccountDID == accountDID
    }

    static func markActiveSettingsAccount(_ accountDID: String?, defaults: UserDefaults = .standard) {
        guard let accountDID, !accountDID.isEmpty else {
            defaults.removeObject(forKey: activeSettingsAccountDIDKey)
            return
        }
        defaults.set(accountDID, forKey: activeSettingsAccountDIDKey)
    }

    static func legacySettingsForMigration(in modelContext: ModelContext) throws -> AppSettingsModel? {
        let legacyId = legacySharedId
        let legacyDescriptor = FetchDescriptor<AppSettingsModel>(
            predicate: #Predicate { $0.id == legacyId }
        )
        guard let legacy = try modelContext.fetch(legacyDescriptor).first else {
            return nil
        }

        let perAccountDescriptor = FetchDescriptor<AppSettingsModel>(
            predicate: #Predicate { $0.id != legacyId }
        )
        let existingPerAccountSettings = try modelContext.fetch(perAccountDescriptor)
        return existingPerAccountSettings.isEmpty ? legacy : nil
    }

    static func copySettings(from source: AppSettingsModel, to target: AppSettingsModel) {
        // Appearance
        target.theme = source.theme
        target.darkThemeMode = source.darkThemeMode
        target.accentColor = source.accentColor

        // Typography
        target.fontStyle = source.fontStyle
        target.fontSize = source.fontSize
        target.lineSpacing = source.lineSpacing
        target.letterSpacing = source.letterSpacing
        target.dynamicTypeEnabled = source.dynamicTypeEnabled
        target.maxDynamicTypeSize = source.maxDynamicTypeSize

        // Accessibility
        target.requireAltText = source.requireAltText
        target.largerAltTextBadges = source.largerAltTextBadges
        target.disableHaptics = source.disableHaptics

        // Motion
        target.reduceMotion = source.reduceMotion
        target.prefersCrossfade = source.prefersCrossfade

        // Display
        target.increaseContrast = source.increaseContrast
        target.boldText = source.boldText
        target.displayScale = source.displayScale

        // Reading
        target.showReadingTimeEstimates = source.showReadingTimeEstimates
        target.highlightLinks = source.highlightLinks
        target.linkStyle = source.linkStyle

        // Interaction
        target.confirmBeforeActions = source.confirmBeforeActions
        target.longPressDuration = source.longPressDuration
        target.shakeToUndo = source.shakeToUndo

        // Attribution
        target.enableViaAttribution = source.enableViaAttribution

        // Content and Media
        target.sensitiveContentScanningEnabled = source.sensitiveContentScanningEnabled
        target.autoplayVideos = source.autoplayVideos
        target.useInAppBrowser = source.useInAppBrowser
        target.showTrendingTopics = source.showTrendingTopics
        target.showTrendingVideos = source.showTrendingVideos

        // Thread Preferences
        target.threadSortOrder = source.threadSortOrder
        target.prioritizeFollowedUsers = source.prioritizeFollowedUsers
        target.threadedReplies = source.threadedReplies
        target.showHiddenPosts = source.showHiddenPosts

        // Feed Preferences
        target.showSavedFeedSamples = source.showSavedFeedSamples

        // External Media
        target.allowYouTube = source.allowYouTube
        target.allowYouTubeShorts = source.allowYouTubeShorts
        target.allowVimeo = source.allowVimeo
        target.allowTwitch = source.allowTwitch
        target.allowGiphy = source.allowGiphy
        target.allowTenor = source.allowTenor
        target.allowSpotify = source.allowSpotify
        target.allowAppleMusic = source.allowAppleMusic
        target.allowSoundCloud = source.allowSoundCloud
        target.allowFlickr = source.allowFlickr

        // WebView Embeds
        target.useWebViewEmbeds = source.useWebViewEmbeds

        // Languages
        target.appLanguage = source.appLanguage
        target.primaryLanguage = source.primaryLanguage
        target.contentLanguages = source.contentLanguages
        target.hideNonPreferredLanguages = source.hideNonPreferredLanguages
        target.showLanguageIndicators = source.showLanguageIndicators

        // Privacy
        target.loggedOutVisibility = source.loggedOutVisibility

        // MLS Chat
        target.mlsMessageRetentionDays = source.mlsMessageRetentionDays
    }

    // Unique identifier — per-account, set via init(accountDID:)
    @Attribute(.unique) var id: String = ""
    
    // MARK: - Stored Properties
    
    // Appearance
    var theme: String = "system"
    var darkThemeMode: String = "dim"
    var accentColor: String = "default"  // default, twilight, lavender, sunrise, aurora, dusk, midnight
    
    // Typography Settings
    var fontStyle: String = "system"  // system, serif, rounded, monospaced
    var fontSize: String = "default"  // small, default, large, extraLarge
    var lineSpacing: String = "normal"  // tight, normal, relaxed
    var letterSpacing: String = "normal"  // tight, normal, loose
    var dynamicTypeEnabled: Bool = true
    var maxDynamicTypeSize: String = "accessibility1"  // xxLarge, xxxLarge, accessibility1, accessibility2, accessibility3, accessibility4, accessibility5
    
    // Accessibility
    var requireAltText: Bool = false
    var largerAltTextBadges: Bool = false
    var disableHaptics: Bool = false
    
    // Motion Settings
    var reduceMotion: Bool = false
    var prefersCrossfade: Bool = false
    
    // Display Settings
    var increaseContrast: Bool = false
    var boldText: Bool = false
    var displayScale: Double = 1.0
    
    // Reading Settings
    var showReadingTimeEstimates: Bool = false
    var highlightLinks: Bool = true
    var linkStyle: String = "color" // "underline", "color", "both"
    
    // Interaction Settings
    var confirmBeforeActions: Bool = false
    var longPressDuration: Double = 0.5
    var shakeToUndo: Bool = true
    
    // Attribution Settings
    var enableViaAttribution: Bool = true
    
    // Content and Media
    var sensitiveContentScanningEnabled: Bool = true
    var autoplayVideos: Bool = true
    var useInAppBrowser: Bool = true
    var showTrendingTopics: Bool = true
    var showTrendingVideos: Bool = true
    
    // Thread Preferences (local-only overrides)
    var threadSortOrder: String = "hot"
    var prioritizeFollowedUsers: Bool = true
    var threadedReplies: Bool = false
    var showHiddenPosts: Bool = false  // Auto-load posts hidden by threadgate (otherwise shows button)
    
    // Local Feed Preferences (used in addition to server preferences)
    var showSavedFeedSamples: Bool = false
    
    // External Media Preferences
    var allowYouTube: Bool = true
    var allowYouTubeShorts: Bool = true
    var allowVimeo: Bool = true
    var allowTwitch: Bool = true
    var allowGiphy: Bool = true
    var allowTenor: Bool = true
    var allowSpotify: Bool = true
    var allowAppleMusic: Bool = true
    var allowSoundCloud: Bool = true
    var allowFlickr: Bool = true
    
    // WebView Embeds
    var useWebViewEmbeds: Bool = true
    
    // Languages
    var appLanguage: String = "system"
    var primaryLanguage: String = "en"
    
    // We need a special case for array in SwiftData
    private var _contentLanguagesString: String = "en"
    var contentLanguages: [String] {
        get {
            _contentLanguagesString.split(separator: ",").map(String.init)
        }
        set {
            _contentLanguagesString = newValue.joined(separator: ",")
        }
    }
    
    // Language Filtering Options
    var hideNonPreferredLanguages: Bool = false
    var showLanguageIndicators: Bool = true
    
    // Privacy
    var loggedOutVisibility: Bool = true

    // MLS Chat Settings
    var mlsMessageRetentionDays: Int = 30  // Default: 30 days (balanced policy)

    // Developer Settings
    
    
    // MARK: - Initializers

    init() {}

    /// Create settings scoped to a specific account DID
    init(accountDID: String) {
        self.id = Self.settingsId(for: accountDID)
    }
    
    /// Migrate from existing UserDefaults settings
    func migrateFromUserDefaults(accountDID: String? = nil, includeLegacyFallback: Bool = true) {
        let defaults = UserDefaults.standard
        
        // Appearance
        if let value = Self.stringValue(for: "theme", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { theme = value }
        if let value = Self.stringValue(for: "darkThemeMode", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { darkThemeMode = value }
        if let value = Self.stringValue(for: "accentColor", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { accentColor = value }
        
        // Ensure theme settings are also saved to app group for widgets
        let groupDefaults = Self.sharedDefaults()
        groupDefaults.set(theme, forKey: "theme")
        groupDefaults.set(darkThemeMode, forKey: "darkThemeMode")
        if let value = Self.stringValue(for: "fontStyle", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { fontStyle = value }
        if let value = Self.stringValue(for: "fontSize", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { fontSize = value }
        if let value = Self.stringValue(for: "lineSpacing", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { lineSpacing = value }
        if let value = Self.boolValue(for: "dynamicTypeEnabled", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) {
            dynamicTypeEnabled = value
        }
        if let value = Self.stringValue(for: "maxDynamicTypeSize", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { maxDynamicTypeSize = value }
        
        // Accessibility
        if let value = Self.boolValue(for: "requireAltText", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { requireAltText = value }
        if let value = Self.boolValue(for: "largerAltTextBadges", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { largerAltTextBadges = value }
        if let value = Self.boolValue(for: "disableHaptics", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { disableHaptics = value }
        
        // Motion Settings
        if let value = Self.boolValue(for: "reduceMotion", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { reduceMotion = value }
        if let value = Self.boolValue(for: "prefersCrossfade", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { prefersCrossfade = value }
        
        // Display Settings
        if let value = Self.boolValue(for: "increaseContrast", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { increaseContrast = value }
        if let value = Self.boolValue(for: "boldText", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { boldText = value }
        if let value = Self.doubleValue(for: "displayScale", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { displayScale = value }
        
        // Reading Settings
        if let value = Self.boolValue(for: "showReadingTimeEstimates", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { showReadingTimeEstimates = value }
        if let value = Self.boolValue(for: "highlightLinks", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { highlightLinks = value }
        if let value = Self.stringValue(for: "linkStyle", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { linkStyle = value }
        
        // Interaction Settings
        if let value = Self.boolValue(for: "confirmBeforeActions", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { confirmBeforeActions = value }
        if let value = Self.doubleValue(for: "longPressDuration", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { longPressDuration = value }
        if let value = Self.boolValue(for: "shakeToUndo", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { shakeToUndo = value }
        
        // Attribution Settings
        if let value = Self.boolValue(for: "enableViaAttribution", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { enableViaAttribution = value }
        
        // Content and Media
        if let value = Self.boolValue(for: "autoplayVideos", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { autoplayVideos = value }
        if let value = Self.boolValue(for: "useInAppBrowser", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { useInAppBrowser = value }
        if let value = Self.boolValue(for: "showTrendingTopics", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { showTrendingTopics = value }
        if let value = Self.boolValue(for: "showTrendingVideos", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { showTrendingVideos = value }
        
        // Thread Preferences
        if let value = Self.stringValue(for: "threadSortOrder", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { threadSortOrder = value }
        if let value = Self.boolValue(for: "prioritizeFollowedUsers", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { prioritizeFollowedUsers = value }
        if let value = Self.boolValue(for: "threadedReplies", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { threadedReplies = value }
        if let value = Self.boolValue(for: "showHiddenPosts", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { showHiddenPosts = value }
        
        // Feed Preferences
        if let value = Self.boolValue(for: "showSavedFeedSamples", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { showSavedFeedSamples = value }
        
        // External Media
        if let value = Self.boolValue(for: "allowYouTube", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { allowYouTube = value }
        if let value = Self.boolValue(for: "allowYouTubeShorts", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { allowYouTubeShorts = value }
        if let value = Self.boolValue(for: "allowVimeo", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { allowVimeo = value }
        if let value = Self.boolValue(for: "allowTwitch", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { allowTwitch = value }
        if let value = Self.boolValue(for: "allowGiphy", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { allowGiphy = value }
        if let value = Self.boolValue(for: "allowTenor", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { allowTenor = value }
        if let value = Self.boolValue(for: "allowSpotify", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { allowSpotify = value }
        if let value = Self.boolValue(for: "allowAppleMusic", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { allowAppleMusic = value }
        if let value = Self.boolValue(for: "allowSoundCloud", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { allowSoundCloud = value }
        if let value = Self.boolValue(for: "allowFlickr", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { allowFlickr = value }
        
        // WebView Embeds
        if let value = Self.boolValue(for: "useWebViewEmbeds", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { useWebViewEmbeds = value }
        
        // Languages
        if let value = defaults.string(forKey: "appLanguage") { appLanguage = value }
        if let value = Self.stringValue(for: "primaryLanguage", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { primaryLanguage = value }
        if let value = Self.stringArrayValue(for: "contentLanguages", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) {
            contentLanguages = value
        }
        
        // Language Filtering Options
        if let value = Self.boolValue(for: "hideNonPreferredLanguages", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { hideNonPreferredLanguages = value }
        if let value = Self.boolValue(for: "showLanguageIndicators", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { showLanguageIndicators = value }
        
        // Privacy
        if let value = Self.boolValue(for: "loggedOutVisibility", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) { loggedOutVisibility = value }

        // MLS Chat Settings
        if let value = Self.intValue(for: "mlsMessageRetentionDays", accountDID: accountDID, defaults: defaults, includeLegacyFallback: includeLegacyFallback) {
            mlsMessageRetentionDays = value
        }

        // Developer Settings
        
    }
    
    /// Reset all settings to defaults
    func resetToDefaults() {
        // Appearance
        theme = "system"
        darkThemeMode = "dim"
        accentColor = "default"
        
        // Also update UserDefaults
        let defaults = UserDefaults.standard
        defaults.set(theme, forKey: "theme")
        defaults.set(darkThemeMode, forKey: "darkThemeMode")
        
        // Also update app group
        let groupDefaults = Self.sharedDefaults()
        groupDefaults.set(theme, forKey: "theme")
        groupDefaults.set(darkThemeMode, forKey: "darkThemeMode")
        fontStyle = "system"
        fontSize = "default"
        lineSpacing = "normal"
        dynamicTypeEnabled = true
        maxDynamicTypeSize = "accessibility1"
        
        // Accessibility
        requireAltText = false
        largerAltTextBadges = false
        disableHaptics = false
        
        // Motion Settings
        reduceMotion = false
        prefersCrossfade = false
        
        // Display Settings
        increaseContrast = false
        boldText = false
        displayScale = 1.0
        
        // Reading Settings
        showReadingTimeEstimates = false
        highlightLinks = true
        linkStyle = "color"
        
        // Interaction Settings
        confirmBeforeActions = false
        longPressDuration = 0.5
        shakeToUndo = true
        
        // Attribution Settings
        enableViaAttribution = true
        
        // Content and Media
        autoplayVideos = true
        useInAppBrowser = true
        showTrendingTopics = true
        showTrendingVideos = true
        
        // Thread Preferences
        threadSortOrder = "hot"
        prioritizeFollowedUsers = true
        threadedReplies = false
        showHiddenPosts = false
        
        // Feed Preferences
        showSavedFeedSamples = false
        
        // External Media
        allowYouTube = true
        allowYouTubeShorts = true
        allowVimeo = true
        allowTwitch = true
        allowGiphy = true
        allowTenor = true
        allowSpotify = true
        allowAppleMusic = true
        allowSoundCloud = true
        allowFlickr = true
        
        // WebView Embeds
        useWebViewEmbeds = true
        
        // Languages
        appLanguage = "system"
        primaryLanguage = "en"
        contentLanguages = ["en"]
        
        // Language Filtering Options
        hideNonPreferredLanguages = false
        showLanguageIndicators = true
        
        // Privacy
        loggedOutVisibility = true

        // MLS Chat Settings
        mlsMessageRetentionDays = 30

        // Developer Settings
        
    }
}
