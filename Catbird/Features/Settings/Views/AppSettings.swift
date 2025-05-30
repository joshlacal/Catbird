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
    
    // MARK: - Initialization
    
    init() {
        // Use default values until we can load from SwiftData
    }
    
    // Initialize with ModelContext
    func initialize(with modelContext: ModelContext) {
        self.modelContext = modelContext
        
        // Try to fetch existing settings
        do {
            let descriptor = FetchDescriptor<AppSettingsModel>(
                predicate: #Predicate { $0.id == "app_settings" }
            )
            let existingSettings = try modelContext.fetch(descriptor)
            
            if let settings = existingSettings.first {
                // Found existing settings
                self.settingsModel = settings
            } else {
                // Create new settings with defaults
                let newSettings = AppSettingsModel()
                
                // Migrate from UserDefaults
                newSettings.migrateFromUserDefaults()
                
                modelContext.insert(newSettings)
                self.settingsModel = newSettings
                
                // Save the context
                try modelContext.save()
            }
        } catch {
            logger.debug("Error initializing app settings: \(error)")
        }
    }
    
    // MARK: - Helper Methods
    
    private func saveChanges() {
        guard let modelContext = modelContext else { return }
        
        do {
            try modelContext.save()
            
            // Post notification that settings have changed
            NotificationCenter.default.post(name: NSNotification.Name("AppSettingsChanged"), object: nil)
        } catch {
            logger.debug("Error saving app settings: \(error)")
        }
    }
    
    // MARK: - Computed Properties
    
    // Appearance
    var theme: String {
        get { settingsModel?.theme ?? defaults.theme }
        set {
            settingsModel?.theme = newValue
            saveChanges()
        }
    }
    
    var darkThemeMode: String {
        get { settingsModel?.darkThemeMode ?? defaults.darkThemeMode }
        set {
            settingsModel?.darkThemeMode = newValue
            saveChanges()
        }
    }
    
    var fontStyle: String {
        get { settingsModel?.fontStyle ?? defaults.fontStyle }
        set {
            settingsModel?.fontStyle = newValue
            saveChanges()
        }
    }
    
    var fontSize: String {
        get { settingsModel?.fontSize ?? defaults.fontSize }
        set {
            settingsModel?.fontSize = newValue
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
        get { settingsModel?.allowYouTube ?? defaults.allowYouTube }
        set {
            settingsModel?.allowYouTube = newValue
            saveChanges()
        }
    }
    
    var allowYouTubeShorts: Bool {
        get { settingsModel?.allowYouTubeShorts ?? defaults.allowYouTubeShorts }
        set {
            settingsModel?.allowYouTubeShorts = newValue
            saveChanges()
        }
    }
    
    var allowVimeo: Bool {
        get { settingsModel?.allowVimeo ?? defaults.allowVimeo }
        set {
            settingsModel?.allowVimeo = newValue
            saveChanges()
        }
    }
    
    var allowTwitch: Bool {
        get { settingsModel?.allowTwitch ?? defaults.allowTwitch }
        set {
            settingsModel?.allowTwitch = newValue
            saveChanges()
        }
    }
    
    var allowGiphy: Bool {
        get { settingsModel?.allowGiphy ?? defaults.allowGiphy }
        set {
            settingsModel?.allowGiphy = newValue
            saveChanges()
        }
    }
    
    var allowSpotify: Bool {
        get { settingsModel?.allowSpotify ?? defaults.allowSpotify }
        set {
            settingsModel?.allowSpotify = newValue
            saveChanges()
        }
    }
    
    var allowAppleMusic: Bool {
        get { settingsModel?.allowAppleMusic ?? defaults.allowAppleMusic }
        set {
            settingsModel?.allowAppleMusic = newValue
            saveChanges()
        }
    }
    
    var allowSoundCloud: Bool {
        get { settingsModel?.allowSoundCloud ?? defaults.allowSoundCloud }
        set {
            settingsModel?.allowSoundCloud = newValue
            saveChanges()
        }
    }
    
    var allowFlickr: Bool {
        get { settingsModel?.allowFlickr ?? defaults.allowFlickr }
        set {
            settingsModel?.allowFlickr = newValue
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
