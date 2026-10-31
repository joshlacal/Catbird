import Foundation
import Petrel
import OSLog

/// Manages hiding and unhiding posts, persisted to the account's Bluesky preferences
/// (the same hidden-posts list the official app uses).
@Observable
@MainActor
class PostHidingManager {
    private let logger = Logger(subsystem: "blue.catbird.app", category: "PostHidingManager")
    private var preferencesManager: PreferencesManager?
    private var accountDID: String?
    
    // MARK: - State
    
    private(set) var hiddenPosts: Set<String> = []
    private(set) var isSyncing = false
    private(set) var lastSyncError: Error?
    
    // MARK: - Initialization
    
    nonisolated init() {}
    
    // MARK: - Public API
    
    /// Check if a post is hidden
    func isHidden(_ postURI: String) -> Bool {
        hiddenPosts.contains(postURI)
    }
    
    /// Hide a post and save it to the account's preferences.
    /// Returns false (and restores the previous state) when the change couldn't be saved.
    @discardableResult
    func hidePost(_ postURI: String) async -> Bool {
        guard !hiddenPosts.contains(postURI) else { return true }
        guard let preferencesManager else {
            logger.error("Cannot hide post: preferences are not available")
            return false
        }
        
        hiddenPosts.insert(postURI)
        isSyncing = true
        defer { isSyncing = false }
        
        do {
            try await preferencesManager.hidePost(postURI, expectedAccountDID: accountDID)
            lastSyncError = nil
            logger.info("Hidden post: \(postURI)")
            return true
        } catch {
            hiddenPosts.remove(postURI)
            lastSyncError = error
            logger.error("Failed to hide post: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Unhide a post and save the change to the account's preferences.
    /// Returns false (and restores the previous state) when the change couldn't be saved.
    @discardableResult
    func unhidePost(_ postURI: String) async -> Bool {
        guard hiddenPosts.contains(postURI) else { return true }
        guard let preferencesManager else {
            logger.error("Cannot unhide post: preferences are not available")
            return false
        }
        
        hiddenPosts.remove(postURI)
        isSyncing = true
        defer { isSyncing = false }
        
        do {
            try await preferencesManager.unhidePost(postURI, expectedAccountDID: accountDID)
            lastSyncError = nil
            logger.info("Unhidden post: \(postURI)")
            return true
        } catch {
            hiddenPosts.insert(postURI)
            lastSyncError = error
            logger.error("Failed to unhide post: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Load hidden posts from the account's preferences
    func loadFromPreferences() async {
        guard let preferencesManager = preferencesManager else {
            logger.warning("PreferencesManager not available")
            return
        }
        
        do {
            let preferences = try await preferencesManager.getPreferences()
            hiddenPosts = Set(preferences.hiddenPosts)
            logger.info("Loaded \(self.hiddenPosts.count) hidden posts from preferences")
        } catch {
            lastSyncError = error
            logger.error("Failed to load hidden posts from preferences: \(error.localizedDescription)")
        }
    }
    
    /// Get count of hidden posts
    var count: Int {
        hiddenPosts.count
    }
    
    /// Connect the preferences manager for the account this manager belongs to.
    /// Hidden posts are loaded with `loadFromPreferences()` once preferences have been fetched.
    func updatePreferencesManager(_ manager: PreferencesManager?, accountDID: String?) {
        self.preferencesManager = manager
        self.accountDID = accountDID
    }
}
