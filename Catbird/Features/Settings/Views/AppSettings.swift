import Foundation
import SwiftUI
import SwiftData
import Observation
import OSLog

/// AppSettings manages all app-specific settings that aren't synced with the Bluesky server
@Observable final class AppSettings {
    // MARK: - Properties
    private let logger = Logger(subsystem: "blue.catbird", category: "AppSettings")
    private var modelContext: ModelContext?
    private var settingsModel: AppSettingsModel?
    
    // Default values used until SwiftData is initialized
    private var defaults = AppSettingsModel()
    
    // Flag to prevent notification loops during initialization
    private var isInitializing = true
    
    // Debouncing to prevent notification loops
    private var pendingChanges = false
    private var notificationDebounceTimer: Timer?
    
    // MARK: - Initialization
    
    init() {
        // Use default values until we can load from SwiftData
    }
    
    // Initialize with ModelContext
    func initialize(with modelContext: ModelContext) {
        self.modelContext = modelContext
        
        // Try to fetch existing settings with timeout protection
        do {
            let descriptor = FetchDescriptor<AppSettingsModel>(
                predicate: #Predicate { $0.id == "app_settings" }
            )
            
            // Fetch with error handling
            let existingSettings = try modelContext.fetch(descriptor)
            
            if let settings = existingSettings.first {
                // Found existing settings
                self.settingsModel = settings
                logger.debug("Loaded existing app settings from SwiftData")
            } else {
                // Create new settings with defaults
                let newSettings = AppSettingsModel()
                
                // Migrate from UserDefaults
                newSettings.migrateFromUserDefaults()
                
                modelContext.insert(newSettings)
                self.settingsModel = newSettings
                
                // Save the context with error handling
                try modelContext.save()
                logger.debug("Created new app settings in SwiftData")
            }
        } catch {
            logger.error("Error initializing app settings: \(error.localizedDescription)")
            // Continue with defaults if SwiftData fails - don't block the app
            logger.info("Continuing with UserDefaults fallback for app settings")
        }
        
        // IMPORTANT: Set isInitializing to false after initialization completes
        isInitializing = false
        logger.debug("AppSettings initialization complete, isInitializing set to false")
    }
    
    // MARK: - Helper Methods
    
    private func saveChanges() {
        // Skip notifications during initialization to prevent loops
        guard !isInitializing else {
            logger.debug("Skipping notification during initialization")
            return
        }
        
        // Debounce notifications to prevent loops
        notificationDebounceTimer?.invalidate()
        notificationDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            
            // Only notify if there are actual pending changes
            if self.pendingChanges {
                self.pendingChanges = false
                
                // Save to storage
                if let modelContext = self.modelContext {
                    do {
                        try modelContext.save()
                        self.logger.debug("AppSettings saved to SwiftData")
                    } catch {
                        self.logger.error("Error saving to SwiftData: \(error.localizedDescription)")
                    }
                } else {
                    self.logger.debug("No modelContext available, using UserDefaults fallback")
                }
                
                // Always save to UserDefaults as backup
                self.saveThemeSettingsToUserDefaults()
                
                // Post notification after successful save
                NotificationCenter.default.post(name: NSNotification.Name("AppSettingsChanged"), object: nil)
                self.logger.debug("Posted debounced AppSettingsChanged notification")
            }
        }
        
        pendingChanges = true
    }
    
    /// Save critical settings to UserDefaults as backup
    private func saveThemeSettingsToUserDefaults() {
        let defaults = UserDefaults.standard
        
        // Save theme settings
        defaults.set(theme, forKey: "theme")
        defaults.set(darkThemeMode, forKey: "darkThemeMode")
        
        // Save font settings for reliability
        defaults.set(fontStyle, forKey: "fontStyle")
        defaults.set(fontSize, forKey: "fontSize")
        defaults.set(lineSpacing, forKey: "lineSpacing")
        defaults.set(letterSpacing, forKey: "letterSpacing")
        defaults.set(dynamicTypeEnabled, forKey: "dynamicTypeEnabled")
        defaults.set(maxDynamicTypeSize, forKey: "maxDynamicTypeSize")
        
        // Save webview settings for persistence
        defaults.set(useWebViewEmbeds, forKey: "useWebViewEmbeds")
        defaults.set(enablePictureInPicture, forKey: "enablePictureInPicture")
        defaults.set(allowYouTube, forKey: "allowYouTube")
        defaults.set(allowYouTubeShorts, forKey: "allowYouTubeShorts")
        defaults.set(allowVimeo, forKey: "allowVimeo")
        defaults.set(allowTwitch, forKey: "allowTwitch")
        defaults.set(allowGiphy, forKey: "allowGiphy")
        defaults.set(allowTenor, forKey: "allowTenor")
        defaults.set(allowSpotify, forKey: "allowSpotify")
        defaults.set(allowAppleMusic, forKey: "allowAppleMusic")
        defaults.set(allowSoundCloud, forKey: "allowSoundCloud")
        defaults.set(allowFlickr, forKey: "allowFlickr")
        
        // Also save to app group for widgets
        let groupDefaults = UserDefaults(suiteName: "group.blue.catbird.shared")
        groupDefaults?.set(theme, forKey: "theme")
        groupDefaults?.set(darkThemeMode, forKey: "darkThemeMode")
        
        logger.debug("Settings saved to UserDefaults: theme=\(self.theme), darkMode=\(self.darkThemeMode), webViewEmbeds=\(self.useWebViewEmbeds), allowYouTube=\(self.allowYouTube)")
    }
    
    /// Load theme settings from UserDefaults if SwiftData is not available
    private func loadThemeSettingsFromUserDefaults() -> (theme: String, darkThemeMode: String) {
        let defaults = UserDefaults.standard
        
        let savedTheme = defaults.string(forKey: "theme") ?? "system"
        let savedDarkMode = defaults.string(forKey: "darkThemeMode") ?? "dim"
        
        return (theme: savedTheme, darkThemeMode: savedDarkMode)
    }
    
    /// Load font settings from UserDefaults if SwiftData is not available
    private func loadFontSettingsFromUserDefaults() -> (fontStyle: String, fontSize: String, lineSpacing: String, letterSpacing: String, dynamicTypeEnabled: Bool, maxDynamicTypeSize: String) {
        let defaults = UserDefaults.standard
        
        let savedFontStyle = defaults.string(forKey: "fontStyle") ?? "system"
        let savedFontSize = defaults.string(forKey: "fontSize") ?? "default"
        let savedLineSpacing = defaults.string(forKey: "lineSpacing") ?? "normal"
        let savedLetterSpacing = defaults.string(forKey: "letterSpacing") ?? "normal"
        let savedDynamicTypeEnabled = defaults.object(forKey: "dynamicTypeEnabled") != nil ? defaults.bool(forKey: "dynamicTypeEnabled") : true
        let savedMaxDynamicTypeSize = defaults.string(forKey: "maxDynamicTypeSize") ?? "accessibility1"
        
        return (
            fontStyle: savedFontStyle,
            fontSize: savedFontSize,
            lineSpacing: savedLineSpacing,
            letterSpacing: savedLetterSpacing,
            dynamicTypeEnabled: savedDynamicTypeEnabled,
            maxDynamicTypeSize: savedMaxDynamicTypeSize
        )
    }
    
    /// Load webview settings from UserDefaults if SwiftData is not available
    private func loadWebViewSettingsFromUserDefaults() -> (useWebViewEmbeds: Bool, enablePictureInPicture: Bool, allowYouTube: Bool, allowYouTubeShorts: Bool, allowVimeo: Bool, allowTwitch: Bool, allowGiphy: Bool, allowTenor: Bool, allowSpotify: Bool, allowAppleMusic: Bool, allowSoundCloud: Bool, allowFlickr: Bool) {
        let defaults = UserDefaults.standard
        
        let savedUseWebViewEmbeds = defaults.object(forKey: "useWebViewEmbeds") != nil ? defaults.bool(forKey: "useWebViewEmbeds") : true
        let savedEnablePictureInPicture = defaults.object(forKey: "enablePictureInPicture") != nil ? defaults.bool(forKey: "enablePictureInPicture") : true
        let savedAllowYouTube = defaults.object(forKey: "allowYouTube") != nil ? defaults.bool(forKey: "allowYouTube") : true
        let savedAllowYouTubeShorts = defaults.object(forKey: "allowYouTubeShorts") != nil ? defaults.bool(forKey: "allowYouTubeShorts") : true
        let savedAllowVimeo = defaults.object(forKey: "allowVimeo") != nil ? defaults.bool(forKey: "allowVimeo") : true
        let savedAllowTwitch = defaults.object(forKey: "allowTwitch") != nil ? defaults.bool(forKey: "allowTwitch") : true
        let savedAllowGiphy = defaults.object(forKey: "allowGiphy") != nil ? defaults.bool(forKey: "allowGiphy") : true
        let savedAllowTenor = defaults.object(forKey: "allowTenor") != nil ? defaults.bool(forKey: "allowTenor") : true
        let savedAllowSpotify = defaults.object(forKey: "allowSpotify") != nil ? defaults.bool(forKey: "allowSpotify") : true
        let savedAllowAppleMusic = defaults.object(forKey: "allowAppleMusic") != nil ? defaults.bool(forKey: "allowAppleMusic") : true
        let savedAllowSoundCloud = defaults.object(forKey: "allowSoundCloud") != nil ? defaults.bool(forKey: "allowSoundCloud") : true
        let savedAllowFlickr = defaults.object(forKey: "allowFlickr") != nil ? defaults.bool(forKey: "allowFlickr") : true
        
        return (
            useWebViewEmbeds: savedUseWebViewEmbeds,
            enablePictureInPicture: savedEnablePictureInPicture,
            allowYouTube: savedAllowYouTube,
            allowYouTubeShorts: savedAllowYouTubeShorts,
            allowVimeo: savedAllowVimeo,
            allowTwitch: savedAllowTwitch,
            allowGiphy: savedAllowGiphy,
            allowTenor: savedAllowTenor,
            allowSpotify: savedAllowSpotify,
            allowAppleMusic: savedAllowAppleMusic,
            allowSoundCloud: savedAllowSoundCloud,
            allowFlickr: savedAllowFlickr
        )
    }
    
    // MARK: - Computed Properties
    
    // Appearance
    var theme: String {
        get { 
            // Try SwiftData first, then UserDefaults fallback
            if let theme = settingsModel?.theme {
                return theme
            }
            return loadThemeSettingsFromUserDefaults().theme
        }
        set {
            settingsModel?.theme = newValue
            saveChanges()
        }
    }
    
    var darkThemeMode: String {
        get { 
            // Try SwiftData first, then UserDefaults fallback
            if let darkMode = settingsModel?.darkThemeMode {
                return darkMode
            }
            return loadThemeSettingsFromUserDefaults().darkThemeMode
        }
        set {
            settingsModel?.darkThemeMode = newValue
            saveChanges()
        }
    }
    
    var fontStyle: String {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.fontStyle
            }
            return loadFontSettingsFromUserDefaults().fontStyle
        }
        set {
            if let settingsModel = settingsModel {
                settingsModel.fontStyle = newValue
            }
            saveChanges()
        }
    }
    
    var fontSize: String {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.fontSize
            }
            return loadFontSettingsFromUserDefaults().fontSize
        }
        set {
            if let settingsModel = settingsModel {
                settingsModel.fontSize = newValue
            }
            saveChanges()
        }
    }
    
    var lineSpacing: String {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.lineSpacing
            }
            return loadFontSettingsFromUserDefaults().lineSpacing
        }
        set {
            if let settingsModel = settingsModel {
                settingsModel.lineSpacing = newValue
            }
            saveChanges()
        }
    }
    
    var letterSpacing: String {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.letterSpacing
            }
            return loadFontSettingsFromUserDefaults().letterSpacing
        }
        set {
            if let settingsModel = settingsModel {
                settingsModel.letterSpacing = newValue
            }
            saveChanges()
        }
    }
    
    var dynamicTypeEnabled: Bool {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.dynamicTypeEnabled
            }
            return loadFontSettingsFromUserDefaults().dynamicTypeEnabled
        }
        set {
            if let settingsModel = settingsModel {
                settingsModel.dynamicTypeEnabled = newValue
            }
            saveChanges()
        }
    }
    
    var maxDynamicTypeSize: String {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.maxDynamicTypeSize
            }
            return loadFontSettingsFromUserDefaults().maxDynamicTypeSize
        }
        set {
            if let settingsModel = settingsModel {
                settingsModel.maxDynamicTypeSize = newValue
            }
            saveChanges()
        }
    }
    
    // Accessibility
    var requireAltText: Bool {
        get { settingsModel?.requireAltText ?? defaults.requireAltText }
        set {
            settingsModel?.requireAltText = newValue
            saveChanges()
        }
    }
    
    var largerAltTextBadges: Bool {
        get { settingsModel?.largerAltTextBadges ?? defaults.largerAltTextBadges }
        set {
            settingsModel?.largerAltTextBadges = newValue
            saveChanges()
        }
    }
    
    var disableHaptics: Bool {
        get { settingsModel?.disableHaptics ?? defaults.disableHaptics }
        set {
            settingsModel?.disableHaptics = newValue
            saveChanges()
        }
    }
    
    // Motion Settings
    var reduceMotion: Bool {
        get { settingsModel?.reduceMotion ?? defaults.reduceMotion }
        set {
            settingsModel?.reduceMotion = newValue
            saveChanges()
        }
    }
    
    var prefersCrossfade: Bool {
        get { settingsModel?.prefersCrossfade ?? defaults.prefersCrossfade }
        set {
            settingsModel?.prefersCrossfade = newValue
            saveChanges()
        }
    }
    
    // Display Settings
    var increaseContrast: Bool {
        get { settingsModel?.increaseContrast ?? defaults.increaseContrast }
        set {
            settingsModel?.increaseContrast = newValue
            saveChanges()
        }
    }
    
    var boldText: Bool {
        get { settingsModel?.boldText ?? defaults.boldText }
        set {
            settingsModel?.boldText = newValue
            saveChanges()
        }
    }
    
    var displayScale: Double {
        get { settingsModel?.displayScale ?? defaults.displayScale }
        set {
            settingsModel?.displayScale = newValue
            saveChanges()
        }
    }
    
    // Reading Settings
    var showReadingTimeEstimates: Bool {
        get { settingsModel?.showReadingTimeEstimates ?? defaults.showReadingTimeEstimates }
        set {
            settingsModel?.showReadingTimeEstimates = newValue
            saveChanges()
        }
    }
    
    var highlightLinks: Bool {
        get { settingsModel?.highlightLinks ?? defaults.highlightLinks }
        set {
            settingsModel?.highlightLinks = newValue
            saveChanges()
        }
    }
    
    var linkStyle: String {
        get { settingsModel?.linkStyle ?? defaults.linkStyle }
        set {
            settingsModel?.linkStyle = newValue
            saveChanges()
        }
    }
    
    // Interaction Settings
    var confirmBeforeActions: Bool {
        get { settingsModel?.confirmBeforeActions ?? defaults.confirmBeforeActions }
        set {
            settingsModel?.confirmBeforeActions = newValue
            saveChanges()
        }
    }
    
    var longPressDuration: Double {
        get { settingsModel?.longPressDuration ?? defaults.longPressDuration }
        set {
            settingsModel?.longPressDuration = newValue
            saveChanges()
        }
    }
    
    var shakeToUndo: Bool {
        get { settingsModel?.shakeToUndo ?? defaults.shakeToUndo }
        set {
            settingsModel?.shakeToUndo = newValue
            saveChanges()
        }
    }
    
    // Attribution Settings
    var enableViaAttribution: Bool {
        get { settingsModel?.enableViaAttribution ?? defaults.enableViaAttribution }
        set {
            settingsModel?.enableViaAttribution = newValue
            saveChanges()
        }
    }
    
    // Content and Media
    var autoplayVideos: Bool {
        get { settingsModel?.autoplayVideos ?? defaults.autoplayVideos }
        set {
            settingsModel?.autoplayVideos = newValue
            saveChanges()
        }
    }
    
    var useInAppBrowser: Bool {
        get { settingsModel?.useInAppBrowser ?? defaults.useInAppBrowser }
        set {
            settingsModel?.useInAppBrowser = newValue
            saveChanges()
        }
    }
    
    var showTrendingTopics: Bool {
        get { settingsModel?.showTrendingTopics ?? defaults.showTrendingTopics }
        set {
            settingsModel?.showTrendingTopics = newValue
            saveChanges()
        }
    }
    
    var showTrendingVideos: Bool {
        get { settingsModel?.showTrendingVideos ?? defaults.showTrendingVideos }
        set {
            settingsModel?.showTrendingVideos = newValue
            saveChanges()
        }
    }
    
    // Thread Preferences
    var threadSortOrder: String {
        get { settingsModel?.threadSortOrder ?? defaults.threadSortOrder }
        set {
            settingsModel?.threadSortOrder = newValue
            saveChanges()
        }
    }
    
    var prioritizeFollowedUsers: Bool {
        get { settingsModel?.prioritizeFollowedUsers ?? defaults.prioritizeFollowedUsers }
        set {
            settingsModel?.prioritizeFollowedUsers = newValue
            saveChanges()
        }
    }
    
    var threadedReplies: Bool {
        get { settingsModel?.threadedReplies ?? defaults.threadedReplies }
        set {
            settingsModel?.threadedReplies = newValue
            saveChanges()
        }
    }
    
    // Feed Preferences
    var showSavedFeedSamples: Bool {
        get { settingsModel?.showSavedFeedSamples ?? defaults.showSavedFeedSamples }
        set {
            settingsModel?.showSavedFeedSamples = newValue
            saveChanges()
        }
    }
    
    // External Media Preferences
    var allowYouTube: Bool {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.allowYouTube
            }
            return loadWebViewSettingsFromUserDefaults().allowYouTube
        }
        set {
            settingsModel?.allowYouTube = newValue
            saveChanges()
        }
    }
    
    var allowYouTubeShorts: Bool {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.allowYouTubeShorts
            }
            return loadWebViewSettingsFromUserDefaults().allowYouTubeShorts
        }
        set {
            settingsModel?.allowYouTubeShorts = newValue
            saveChanges()
        }
    }
    
    var allowVimeo: Bool {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.allowVimeo
            }
            return loadWebViewSettingsFromUserDefaults().allowVimeo
        }
        set {
            settingsModel?.allowVimeo = newValue
            saveChanges()
        }
    }
    
    var allowTwitch: Bool {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.allowTwitch
            }
            return loadWebViewSettingsFromUserDefaults().allowTwitch
        }
        set {
            settingsModel?.allowTwitch = newValue
            saveChanges()
        }
    }
    
    var allowGiphy: Bool {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.allowGiphy
            }
            return loadWebViewSettingsFromUserDefaults().allowGiphy
        }
        set {
            settingsModel?.allowGiphy = newValue
            saveChanges()
        }
    }
    
    var allowSpotify: Bool {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.allowSpotify
            }
            return loadWebViewSettingsFromUserDefaults().allowSpotify
        }
        set {
            settingsModel?.allowSpotify = newValue
            saveChanges()
        }
    }
    
    var allowAppleMusic: Bool {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.allowAppleMusic
            }
            return loadWebViewSettingsFromUserDefaults().allowAppleMusic
        }
        set {
            settingsModel?.allowAppleMusic = newValue
            saveChanges()
        }
    }
    
    var allowSoundCloud: Bool {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.allowSoundCloud
            }
            return loadWebViewSettingsFromUserDefaults().allowSoundCloud
        }
        set {
            settingsModel?.allowSoundCloud = newValue
            saveChanges()
        }
    }
    
    var allowFlickr: Bool {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.allowFlickr
            }
            return loadWebViewSettingsFromUserDefaults().allowFlickr
        }
        set {
            settingsModel?.allowFlickr = newValue
            saveChanges()
        }
    }

    var allowTenor: Bool {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.allowTenor
            }
            return loadWebViewSettingsFromUserDefaults().allowTenor
        }
        set {
            settingsModel?.allowTenor = newValue
            saveChanges()
        }
    }
    
    // WebView Embeds
    var useWebViewEmbeds: Bool {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.useWebViewEmbeds
            }
            return loadWebViewSettingsFromUserDefaults().useWebViewEmbeds
        }
        set {
            settingsModel?.useWebViewEmbeds = newValue
            saveChanges()
        }
    }
    
    var enablePictureInPicture: Bool {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.enablePictureInPicture
            }
            return loadWebViewSettingsFromUserDefaults().enablePictureInPicture
        }
        set {
            settingsModel?.enablePictureInPicture = newValue
            saveChanges()
        }
    }

    // Languages
    var appLanguage: String {
        get { settingsModel?.appLanguage ?? defaults.appLanguage }
        set {
            settingsModel?.appLanguage = newValue
            saveChanges()
        }
    }
    
    var primaryLanguage: String {
        get { settingsModel?.primaryLanguage ?? defaults.primaryLanguage }
        set {
            settingsModel?.primaryLanguage = newValue
            saveChanges()
        }
    }
    
    var contentLanguages: [String] {
        get { settingsModel?.contentLanguages ?? defaults.contentLanguages }
        set {
            settingsModel?.contentLanguages = newValue
            saveChanges()
        }
    }
    
    var hideNonPreferredLanguages: Bool {
        get { settingsModel?.hideNonPreferredLanguages ?? defaults.hideNonPreferredLanguages }
        set {
            settingsModel?.hideNonPreferredLanguages = newValue
            saveChanges()
        }
    }
    
    var showLanguageIndicators: Bool {
        get { settingsModel?.showLanguageIndicators ?? defaults.showLanguageIndicators }
        set {
            settingsModel?.showLanguageIndicators = newValue
            saveChanges()
        }
    }
    
    // Privacy
    var loggedOutVisibility: Bool {
        get { settingsModel?.loggedOutVisibility ?? defaults.loggedOutVisibility }
        set {
            settingsModel?.loggedOutVisibility = newValue
            saveChanges()
        }
    }
    
    // MARK: - Public Methods
    
    /// Reset all settings to defaults
    func resetToDefaults() {
        settingsModel?.resetToDefaults()
        saveChanges()
    }
    
    /// Apply initial theme settings even before SwiftData is fully initialized
    /// This ensures theme is applied immediately on app startup
    func applyInitialThemeSettings(to themeManager: ThemeManager) {
        // Temporarily set isInitializing to true to prevent notification loops
        let wasInitializing = isInitializing
        isInitializing = true
        defer { isInitializing = wasInitializing }
        
        let themeSettings = loadThemeSettingsFromUserDefaults()
        
        logger.info("Applying initial theme settings from UserDefaults: theme=\(themeSettings.theme), darkMode=\(themeSettings.darkThemeMode)")
        
        themeManager.applyTheme(
            theme: themeSettings.theme,
            darkThemeMode: themeSettings.darkThemeMode
        )
    }
    
    /// Apply initial font settings immediately from UserDefaults if SwiftData is not available
    /// This ensures fonts are applied immediately on app startup
    func applyInitialFontSettings(to fontManager: FontManager) {
        // Temporarily set isInitializing to true to prevent notification loops
        let wasInitializing = isInitializing
        isInitializing = true
        defer { isInitializing = wasInitializing }
        
        // Create a temporary AppSettingsModel to get all current settings
        let currentSettings = AppSettingsModel()
        
        // Load settings from UserDefaults if SwiftData isn't available yet
        if settingsModel == nil {
            currentSettings.migrateFromUserDefaults()
        } else {
            // Copy from existing settings model
            if let model = settingsModel {
                currentSettings.fontStyle = model.fontStyle
                currentSettings.fontSize = model.fontSize
                currentSettings.lineSpacing = model.lineSpacing
                currentSettings.letterSpacing = model.letterSpacing
                currentSettings.dynamicTypeEnabled = model.dynamicTypeEnabled
                currentSettings.maxDynamicTypeSize = model.maxDynamicTypeSize
                currentSettings.boldText = model.boldText
                currentSettings.increaseContrast = model.increaseContrast
                currentSettings.displayScale = model.displayScale
            }
        }
        
        logger.info("Applying initial font and accessibility settings: style=\(currentSettings.fontStyle), size=\(currentSettings.fontSize), spacing=\(currentSettings.lineSpacing), bold=\(currentSettings.boldText), contrast=\(currentSettings.increaseContrast), scale=\(currentSettings.displayScale)")
        
        fontManager.applyAllFontSettings(from: currentSettings)
    }
}

// MARK: - AppState Extension
extension AppState {
    struct AppSettingsKey: EnvironmentKey {
        static let defaultValue = AppSettings()
    }
}

extension EnvironmentValues {
    var appSettings: AppSettings {
        get { self[AppState.AppSettingsKey.self] }
        set { self[AppState.AppSettingsKey.self] = newValue }
    }
}
