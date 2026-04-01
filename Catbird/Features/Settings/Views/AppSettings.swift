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
    private var accountDID: String?
    
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

    func configure(accountDID: String) {
        self.accountDID = accountDID
    }
    
    // Initialize with ModelContext scoped to a specific account
    func initialize(with modelContext: ModelContext, accountDID: String) {
        self.modelContext = modelContext
        self.accountDID = accountDID

        let targetId = AppSettingsModel.settingsId(for: accountDID)

        // Try to fetch existing per-account settings with timeout protection
        do {
            let descriptor = FetchDescriptor<AppSettingsModel>(
                predicate: #Predicate { $0.id == targetId }
            )

            // Fetch with error handling
            let existingSettings = try modelContext.fetch(descriptor)

            if let settings = existingSettings.first {
                // Found existing per-account settings
                self.settingsModel = settings
                logger.debug("Loaded existing app settings for account \(accountDID)")
            } else {
                let newSettings = AppSettingsModel(accountDID: accountDID)

                if let legacy = try AppSettingsModel.legacySettingsForMigration(in: modelContext) {
                    AppSettingsModel.copySettings(from: legacy, to: newSettings)
                    modelContext.delete(legacy)
                    logger.debug("Migrated legacy app settings to account \(accountDID) and deleted legacy singleton")
                } else {
                    let allowLegacyFallback = try !AppSettingsModel.hasPerAccountSettings(in: modelContext)
                    newSettings.migrateFromUserDefaults(
                        accountDID: accountDID,
                        includeLegacyFallback: allowLegacyFallback
                    )
                }

                modelContext.insert(newSettings)
                self.settingsModel = newSettings

                // Save the context with error handling
                try modelContext.save()
                logger.debug("Created new app settings for account \(accountDID)")
            }

            saveThemeSettingsToUserDefaults()
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

    private var standardDefaults: UserDefaults {
        .standard
    }

    private var accountScopedDefaultsDID: String? {
        accountDID
    }

    private var shouldUseRuntimeLegacyFallback: Bool {
        AppSettingsModel.shouldUseLegacyFallback(for: accountScopedDefaultsDID, defaults: standardDefaults)
    }
    
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
        let defaults = standardDefaults
        AppSettingsModel.markActiveSettingsAccount(accountScopedDefaultsDID, defaults: defaults)
        
        // Save theme settings
        defaults.set(theme, forKey: "theme")
        defaults.set(darkThemeMode, forKey: "darkThemeMode")
        defaults.set(accentColor, forKey: "accentColor")
        
        // Save font settings for reliability
        defaults.set(fontStyle, forKey: "fontStyle")
        defaults.set(fontSize, forKey: "fontSize")
        defaults.set(lineSpacing, forKey: "lineSpacing")
        defaults.set(letterSpacing, forKey: "letterSpacing")
        defaults.set(dynamicTypeEnabled, forKey: "dynamicTypeEnabled")
        defaults.set(maxDynamicTypeSize, forKey: "maxDynamicTypeSize")
        
        // Save webview settings for persistence
        defaults.set(useWebViewEmbeds, forKey: "useWebViewEmbeds")
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

        if let accountDID = accountScopedDefaultsDID {
            let accountScopedThemeKeys = [
                ("theme", theme),
                ("darkThemeMode", darkThemeMode),
                ("accentColor", accentColor),
                ("fontStyle", fontStyle),
                ("fontSize", fontSize),
                ("lineSpacing", lineSpacing),
                ("letterSpacing", letterSpacing),
                ("maxDynamicTypeSize", maxDynamicTypeSize),
            ]

            for (key, value) in accountScopedThemeKeys {
                defaults.set(value, forKey: AppSettingsModel.scopedKey(key, accountDID: accountDID))
            }

            let accountScopedBoolKeys: [(String, Bool)] = [
                ("dynamicTypeEnabled", dynamicTypeEnabled),
                ("useWebViewEmbeds", useWebViewEmbeds),
                ("allowYouTube", allowYouTube),
                ("allowYouTubeShorts", allowYouTubeShorts),
                ("allowVimeo", allowVimeo),
                ("allowTwitch", allowTwitch),
                ("allowGiphy", allowGiphy),
                ("allowTenor", allowTenor),
                ("allowSpotify", allowSpotify),
                ("allowAppleMusic", allowAppleMusic),
                ("allowSoundCloud", allowSoundCloud),
                ("allowFlickr", allowFlickr),
            ]

            for (key, value) in accountScopedBoolKeys {
                defaults.set(value, forKey: AppSettingsModel.scopedKey(key, accountDID: accountDID))
            }
        }
        
        // Also save to app group for widgets
        let groupDefaults = AppSettingsModel.sharedDefaults()
        groupDefaults.set(theme, forKey: "theme")
        groupDefaults.set(darkThemeMode, forKey: "darkThemeMode")
        
        logger.debug("Settings saved to UserDefaults: theme=\(self.theme), darkMode=\(self.darkThemeMode), webViewEmbeds=\(self.useWebViewEmbeds), allowYouTube=\(self.allowYouTube)")
    }
    
    /// Load theme settings from UserDefaults if SwiftData is not available
    private func loadThemeSettingsFromUserDefaults() -> (theme: String, darkThemeMode: String) {
        let defaults = standardDefaults
        let savedTheme = AppSettingsModel.stringValue(
            for: "theme",
            accountDID: accountScopedDefaultsDID,
            defaults: defaults,
            includeLegacyFallback: shouldUseRuntimeLegacyFallback
        ) ?? "system"
        let savedDarkMode = AppSettingsModel.stringValue(
            for: "darkThemeMode",
            accountDID: accountScopedDefaultsDID,
            defaults: defaults,
            includeLegacyFallback: shouldUseRuntimeLegacyFallback
        ) ?? "dim"
        
        return (theme: savedTheme, darkThemeMode: savedDarkMode)
    }
    
    /// Load font settings from UserDefaults if SwiftData is not available
    private func loadFontSettingsFromUserDefaults() -> (fontStyle: String, fontSize: String, lineSpacing: String, letterSpacing: String, dynamicTypeEnabled: Bool, maxDynamicTypeSize: String) {
        let defaults = standardDefaults
        
        let savedFontStyle = AppSettingsModel.stringValue(for: "fontStyle", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? "system"
        let savedFontSize = AppSettingsModel.stringValue(for: "fontSize", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? "default"
        let savedLineSpacing = AppSettingsModel.stringValue(for: "lineSpacing", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? "normal"
        let savedLetterSpacing = AppSettingsModel.stringValue(for: "letterSpacing", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? "normal"
        let savedDynamicTypeEnabled = AppSettingsModel.boolValue(for: "dynamicTypeEnabled", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? true
        let savedMaxDynamicTypeSize = AppSettingsModel.stringValue(for: "maxDynamicTypeSize", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? "accessibility1"
        
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
    private func loadWebViewSettingsFromUserDefaults() -> (useWebViewEmbeds: Bool, allowYouTube: Bool, allowYouTubeShorts: Bool, allowVimeo: Bool, allowTwitch: Bool, allowGiphy: Bool, allowTenor: Bool, allowSpotify: Bool, allowAppleMusic: Bool, allowSoundCloud: Bool, allowFlickr: Bool) {
        let defaults = standardDefaults
        
        let savedUseWebViewEmbeds = AppSettingsModel.boolValue(for: "useWebViewEmbeds", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? true
        let savedAllowYouTube = AppSettingsModel.boolValue(for: "allowYouTube", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? true
        let savedAllowYouTubeShorts = AppSettingsModel.boolValue(for: "allowYouTubeShorts", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? true
        let savedAllowVimeo = AppSettingsModel.boolValue(for: "allowVimeo", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? true
        let savedAllowTwitch = AppSettingsModel.boolValue(for: "allowTwitch", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? true
        let savedAllowGiphy = AppSettingsModel.boolValue(for: "allowGiphy", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? true
        let savedAllowTenor = AppSettingsModel.boolValue(for: "allowTenor", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? true
        let savedAllowSpotify = AppSettingsModel.boolValue(for: "allowSpotify", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? true
        let savedAllowAppleMusic = AppSettingsModel.boolValue(for: "allowAppleMusic", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? true
        let savedAllowSoundCloud = AppSettingsModel.boolValue(for: "allowSoundCloud", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? true
        let savedAllowFlickr = AppSettingsModel.boolValue(for: "allowFlickr", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? true
        
        return (
            useWebViewEmbeds: savedUseWebViewEmbeds,
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

    var accentColor: String {
        get {
            if let settingsModel = settingsModel {
                return settingsModel.accentColor
            }
            return AppSettingsModel.stringValue(
                for: "accentColor",
                accountDID: accountScopedDefaultsDID,
                defaults: standardDefaults,
                includeLegacyFallback: shouldUseRuntimeLegacyFallback
            ) ?? "default"
        }
        set {
            settingsModel?.accentColor = newValue
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
    var sensitiveContentScanningEnabled: Bool {
        get { settingsModel?.sensitiveContentScanningEnabled ?? defaults.sensitiveContentScanningEnabled }
        set {
            settingsModel?.sensitiveContentScanningEnabled = newValue
            saveChanges()
        }
    }

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
    
    var showHiddenPosts: Bool {
        get { settingsModel?.showHiddenPosts ?? defaults.showHiddenPosts }
        set {
            settingsModel?.showHiddenPosts = newValue
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

    // MLS Chat Settings
    var mlsMessageRetentionDays: Int {
        get { settingsModel?.mlsMessageRetentionDays ?? defaults.mlsMessageRetentionDays }
        set {
            settingsModel?.mlsMessageRetentionDays = newValue
            saveChanges()
        }
    }

    // Developer Settings
    
    
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
        
        let savedAccentColor = AppSettingsModel.stringValue(
            for: "accentColor",
            accountDID: accountScopedDefaultsDID,
            defaults: standardDefaults
        ) ?? "default"
        themeManager.applyTheme(
            theme: themeSettings.theme,
            darkThemeMode: themeSettings.darkThemeMode,
            accentColor: savedAccentColor
        )

        // Keep the legacy global backup aligned with the active account so early launch
        // reads (such as navigation font bootstrap) use the most recently active profile.
        saveThemeSettingsToUserDefaults()
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
            currentSettings.migrateFromUserDefaults(
                accountDID: accountScopedDefaultsDID,
                includeLegacyFallback: shouldUseRuntimeLegacyFallback
            )
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
