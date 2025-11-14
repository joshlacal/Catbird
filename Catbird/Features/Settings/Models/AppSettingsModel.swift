import Foundation
import SwiftData
import Observation

/// SwiftData model for app settings that aren't synced with the Bluesky server
@Model
final class AppSettingsModel {
    // Shared ID constant for singleton instance
    static let sharedId = "app_settings"
    
    // Unique identifier for single instance
    var id: String = "app_settings"
    
    // MARK: - Stored Properties
    
    // Appearance
    var theme: String = "system"
    var darkThemeMode: String = "dim"
    
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
    var autoplayVideos: Bool = true
    var useInAppBrowser: Bool = true
    var showTrendingTopics: Bool = true
    var showTrendingVideos: Bool = true
    
    // Thread Preferences (local-only overrides)
    var threadSortOrder: String = "hot"
    var prioritizeFollowedUsers: Bool = true
    var threadedReplies: Bool = false
    
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
    
    /// Migrate from existing UserDefaults settings
    func migrateFromUserDefaults() {
        let defaults = UserDefaults.standard
        
        // Appearance
        if let value = defaults.string(forKey: "theme") { theme = value }
        if let value = defaults.string(forKey: "darkThemeMode") { darkThemeMode = value }
        
        // Ensure theme settings are also saved to app group for widgets
        let groupDefaults = UserDefaults(suiteName: "group.blue.catbird.shared")
        groupDefaults?.set(theme, forKey: "theme")
        groupDefaults?.set(darkThemeMode, forKey: "darkThemeMode")
        if let value = defaults.string(forKey: "fontStyle") { fontStyle = value }
        if let value = defaults.string(forKey: "fontSize") { fontSize = value }
        if let value = defaults.string(forKey: "lineSpacing") { lineSpacing = value }
        dynamicTypeEnabled = defaults.bool(forKey: "dynamicTypeEnabled")
        if dynamicTypeEnabled == false && defaults.object(forKey: "dynamicTypeEnabled") == nil {
            dynamicTypeEnabled = true // Default to true if not set
        }
        if let value = defaults.string(forKey: "maxDynamicTypeSize") { maxDynamicTypeSize = value }
        
        // Accessibility
        requireAltText = defaults.bool(forKey: "requireAltText")
        largerAltTextBadges = defaults.bool(forKey: "largerAltTextBadges")
        disableHaptics = defaults.bool(forKey: "disableHaptics")
        
        // Motion Settings
        reduceMotion = defaults.bool(forKey: "reduceMotion")
        prefersCrossfade = defaults.bool(forKey: "prefersCrossfade")
        
        // Display Settings
        increaseContrast = defaults.bool(forKey: "increaseContrast")
        boldText = defaults.bool(forKey: "boldText")
        displayScale = defaults.double(forKey: "displayScale")
        if displayScale == 0 { displayScale = 1.0 }
        
        // Reading Settings
        showReadingTimeEstimates = defaults.bool(forKey: "showReadingTimeEstimates")
        highlightLinks = defaults.bool(forKey: "highlightLinks")
        if let value = defaults.string(forKey: "linkStyle") { linkStyle = value }
        
        // Interaction Settings
        confirmBeforeActions = defaults.bool(forKey: "confirmBeforeActions")
        longPressDuration = defaults.double(forKey: "longPressDuration")
        if longPressDuration == 0 { longPressDuration = 0.5 }
        shakeToUndo = defaults.bool(forKey: "shakeToUndo")
        
        // Attribution Settings
        enableViaAttribution = defaults.bool(forKey: "enableViaAttribution")
        if enableViaAttribution == false && defaults.object(forKey: "enableViaAttribution") == nil {
            enableViaAttribution = true // Default to true if not set
        }
        
        // Content and Media
        if defaults.object(forKey: "autoplayVideos") != nil {
            autoplayVideos = defaults.bool(forKey: "autoplayVideos")
        }
        if defaults.object(forKey: "useInAppBrowser") != nil {
            useInAppBrowser = defaults.bool(forKey: "useInAppBrowser")
        }
        if defaults.object(forKey: "showTrendingTopics") != nil {
            showTrendingTopics = defaults.bool(forKey: "showTrendingTopics")
        }
        if defaults.object(forKey: "showTrendingVideos") != nil {
            showTrendingVideos = defaults.bool(forKey: "showTrendingVideos")
        }
        
        // Thread Preferences
        if let value = defaults.string(forKey: "threadSortOrder") { threadSortOrder = value }
        prioritizeFollowedUsers = defaults.bool(forKey: "prioritizeFollowedUsers")
        threadedReplies = defaults.bool(forKey: "threadedReplies")
        
        // Feed Preferences
        showSavedFeedSamples = defaults.bool(forKey: "showSavedFeedSamples")
        
        // External Media
        allowYouTube = defaults.object(forKey: "allowYouTube") != nil ? defaults.bool(forKey: "allowYouTube") : true
        allowYouTubeShorts = defaults.object(forKey: "allowYouTubeShorts") != nil ? defaults.bool(forKey: "allowYouTubeShorts") : true
        allowVimeo = defaults.object(forKey: "allowVimeo") != nil ? defaults.bool(forKey: "allowVimeo") : true
        allowTwitch = defaults.object(forKey: "allowTwitch") != nil ? defaults.bool(forKey: "allowTwitch") : true
        allowGiphy = defaults.object(forKey: "allowGiphy") != nil ? defaults.bool(forKey: "allowGiphy") : true
        allowTenor = defaults.object(forKey: "allowTenor") != nil ? defaults.bool(forKey: "allowTenor") : true
        allowSpotify = defaults.object(forKey: "allowSpotify") != nil ? defaults.bool(forKey: "allowSpotify") : true
        allowAppleMusic = defaults.object(forKey: "allowAppleMusic") != nil ? defaults.bool(forKey: "allowAppleMusic") : true
        allowSoundCloud = defaults.object(forKey: "allowSoundCloud") != nil ? defaults.bool(forKey: "allowSoundCloud") : true
        allowFlickr = defaults.object(forKey: "allowFlickr") != nil ? defaults.bool(forKey: "allowFlickr") : true
        
        // WebView Embeds
        useWebViewEmbeds = defaults.bool(forKey: "useWebViewEmbeds")
        if useWebViewEmbeds == false && defaults.object(forKey: "useWebViewEmbeds") == nil {
            useWebViewEmbeds = true // Default to true if not set
        }
        
        // Languages
        if let value = defaults.string(forKey: "appLanguage") { appLanguage = value }
        if let value = defaults.string(forKey: "primaryLanguage") { primaryLanguage = value }
        if let value = defaults.stringArray(forKey: "contentLanguages") {
            contentLanguages = value
        }
        
        // Language Filtering Options
        hideNonPreferredLanguages = defaults.bool(forKey: "hideNonPreferredLanguages")
        showLanguageIndicators = defaults.bool(forKey: "showLanguageIndicators")
        if showLanguageIndicators == false && defaults.object(forKey: "showLanguageIndicators") == nil {
            showLanguageIndicators = true // Default to true if not set
        }
        
        // Privacy
        loggedOutVisibility = defaults.bool(forKey: "loggedOutVisibility")

        // MLS Chat Settings
        if defaults.object(forKey: "mlsMessageRetentionDays") != nil {
            mlsMessageRetentionDays = defaults.integer(forKey: "mlsMessageRetentionDays")
        }
        if mlsMessageRetentionDays == 0 { mlsMessageRetentionDays = 30 }  // Ensure valid default

        // Developer Settings
        
    }
    
    /// Reset all settings to defaults
    func resetToDefaults() {
        // Appearance
        theme = "system"
        darkThemeMode = "dim"
        
        // Also update UserDefaults
        let defaults = UserDefaults.standard
        defaults.set(theme, forKey: "theme")
        defaults.set(darkThemeMode, forKey: "darkThemeMode")
        
        // Also update app group
        let groupDefaults = UserDefaults(suiteName: "group.blue.catbird.shared")
        groupDefaults?.set(theme, forKey: "theme")
        groupDefaults?.set(darkThemeMode, forKey: "darkThemeMode")
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
