import Foundation
import SwiftData
import Observation

/// SwiftData model for app settings that aren't synced with the Bluesky server
@Model
final class AppSettingsModel {
    // Unique identifier for single instance
    var id: String = "app_settings"
    
    // MARK: - Stored Properties
    
    // Appearance
    var theme: String = "system"
    var darkThemeMode: String = "dim"
    var fontStyle: String = "system"
    var fontSize: String = "default"
    
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
    var allowSpotify: Bool = true
    var allowAppleMusic: Bool = true
    var allowSoundCloud: Bool = true
    var allowFlickr: Bool = true
    
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
    
    // Privacy
    var loggedOutVisibility: Bool = true
    
    // MARK: - Initializers
    
    init() {}
    
    /// Migrate from existing UserDefaults settings
    func migrateFromUserDefaults() {
        let defaults = UserDefaults.standard
        
        // Appearance
        if let value = defaults.string(forKey: "theme") { theme = value }
        if let value = defaults.string(forKey: "darkThemeMode") { darkThemeMode = value }
        if let value = defaults.string(forKey: "fontStyle") { fontStyle = value }
        if let value = defaults.string(forKey: "fontSize") { fontSize = value }
        
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
        
        // Content and Media
        autoplayVideos = defaults.bool(forKey: "autoplayVideos")
        useInAppBrowser = defaults.bool(forKey: "useInAppBrowser")
        showTrendingTopics = defaults.bool(forKey: "showTrendingTopics")
        showTrendingVideos = defaults.bool(forKey: "showTrendingVideos")
        
        // Thread Preferences
        if let value = defaults.string(forKey: "threadSortOrder") { threadSortOrder = value }
        prioritizeFollowedUsers = defaults.bool(forKey: "prioritizeFollowedUsers")
        threadedReplies = defaults.bool(forKey: "threadedReplies")
        
        // Feed Preferences
        showSavedFeedSamples = defaults.bool(forKey: "showSavedFeedSamples")
        
        // External Media
        allowYouTube = defaults.bool(forKey: "allowYouTube")
        allowYouTubeShorts = defaults.bool(forKey: "allowYouTubeShorts")
        allowVimeo = defaults.bool(forKey: "allowVimeo")
        allowTwitch = defaults.bool(forKey: "allowTwitch")
        allowGiphy = defaults.bool(forKey: "allowGiphy")
        allowSpotify = defaults.bool(forKey: "allowSpotify")
        allowAppleMusic = defaults.bool(forKey: "allowAppleMusic")
        allowSoundCloud = defaults.bool(forKey: "allowSoundCloud")
        allowFlickr = defaults.bool(forKey: "allowFlickr")
        
        // Languages
        if let value = defaults.string(forKey: "appLanguage") { appLanguage = value }
        if let value = defaults.string(forKey: "primaryLanguage") { primaryLanguage = value }
        if let value = defaults.stringArray(forKey: "contentLanguages") {
            contentLanguages = value
        }
        
        // Privacy
        loggedOutVisibility = defaults.bool(forKey: "loggedOutVisibility")
    }
    
    /// Reset all settings to defaults
    func resetToDefaults() {
        // Appearance
        theme = "system"
        darkThemeMode = "dim"
        fontStyle = "system"
        fontSize = "default"
        
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
        allowSpotify = true
        allowAppleMusic = true
        allowSoundCloud = true
        allowFlickr = true
        
        // Languages
        appLanguage = "system"
        primaryLanguage = "en"
        contentLanguages = ["en"]
        
        // Privacy
        loggedOutVisibility = true
    }
}
