import Foundation
import Petrel
import OSLog

/// Manages hiding and unhiding posts with server sync via PreferencesManager
@Observable
@MainActor
class PostHidingManager {
    private let logger = Logger(subsystem: "blue.catbird.app", category: "PostHidingManager")
    private var preferencesManager: PreferencesManager?
    
    // MARK: - State
    
    private(set) var hiddenPosts: Set<String> = []
    private(set) var isSyncing = false
    private(set) var lastSyncError: Error?
    
    // MARK: - Initialization
    
    nonisolated init(preferencesManager: PreferencesManager? = nil) {
        // Simple initialization - no async work
        // Property will be set via updatePreferencesManager after init
    }
    
    // MARK: - Public API
    
    /// Check if a post is hidden
    func isHidden(_ postURI: String) -> Bool {
        hiddenPosts.contains(postURI)
    }
    
    /// Hide a post and sync to server via PreferencesManager
    func hidePost(_ postURI: String) async {
        guard !hiddenPosts.contains(postURI) else { return }
        
        hiddenPosts.insert(postURI)
        logger.info("Hidden post: \(postURI)")
        
        await syncToPreferences()
    }
    
    /// Unhide a post and sync to server via PreferencesManager
    func unhidePost(_ postURI: String) async {
        guard hiddenPosts.contains(postURI) else { return }
        
        hiddenPosts.remove(postURI)
        logger.info("Unhidden post: \(postURI)")
        
        await syncToPreferences()
    }
    
    /// Load hidden posts from PreferencesManager
    func loadFromPreferences() async {
        guard let preferencesManager = preferencesManager else {
            logger.warning("PreferencesManager not available")
            return
        }
        
        isSyncing = true
        defer { isSyncing = false }
        
        do {
            let preferences = try await preferencesManager.getPreferences()
            hiddenPosts = Set(preferences.hiddenPosts)
            logger.info("Loaded \(self.hiddenPosts.count) hidden posts from preferences")
        } catch {
            lastSyncError = error
            logger.error("Failed to load hidden posts from preferences: \(error.localizedDescription)")
        }
    }
    
    /// Sync hidden posts to server via PreferencesManager
    private func syncToPreferences() async {
        guard let preferencesManager = preferencesManager else {
            logger.warning("PreferencesManager not available for sync")
            return
        }
        
        isSyncing = true
        defer { isSyncing = false }
        
        do {
            let preferences = try await preferencesManager.getPreferences()
            preferences.hiddenPosts = Array(hiddenPosts)
            try await preferencesManager.saveAndSyncPreferences(preferences)
            logger.info("Synced \(self.hiddenPosts.count) hidden posts to server via PreferencesManager")
        } catch {
            lastSyncError = error
            logger.error("Failed to sync hidden posts via PreferencesManager: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Bulk Operations
    
    /// Clear all hidden posts
    func clearAll() async {
        hiddenPosts.removeAll()
        await syncToPreferences()
        logger.info("Cleared all hidden posts")
    }
    
    /// Get count of hidden posts
    var count: Int {
        hiddenPosts.count
    }
    
    /// Update the preferences manager reference
    func updatePreferencesManager(_ manager: PreferencesManager?) {
        self.preferencesManager = manager
        if manager != nil {
            Task {
                await loadFromPreferences()
            }
        }
    }
}
