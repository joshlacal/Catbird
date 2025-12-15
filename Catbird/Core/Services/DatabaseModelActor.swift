//
//  DatabaseModelActor.swift
//  Catbird
//
//  ModelActor for off-main-thread SwiftData operations.
//  Reduces main thread contention by performing database work on a dedicated executor.
//

import Foundation
import SwiftData
import OSLog
import Petrel

// MARK: - Database Model Actor

/// Centralized ModelActor for all SwiftData database operations.
/// All operations run on a background executor to avoid blocking the main thread.
@ModelActor
actor DatabaseModelActor {
    private let logger = Logger(subsystem: "blue.catbird", category: "DatabaseModelActor")
    
    // MARK: - Draft Operations
    
    /// Save a new draft
    func saveDraft(_ draft: PostComposerDraft, accountDID: String) throws -> UUID {
        logger.info("💾 Saving draft for account: \(accountDID)")
        
        let draftPost = try DraftPost.create(from: draft, accountDID: accountDID)
        modelContext.insert(draftPost)
        try modelContext.save()
        
        logger.info("✅ Saved draft \(draftPost.id.uuidString)")
        return draftPost.id
    }
    
    /// Update an existing draft
    func updateDraft(id: UUID, draft: PostComposerDraft, accountDID: String) throws {
        logger.info("♻️ Updating draft: \(id.uuidString)")
        
        let predicate = #Predicate<DraftPost> { $0.id == id }
        let descriptor = FetchDescriptor(predicate: predicate)
        
        guard let existingDraft = try modelContext.fetch(descriptor).first else {
            throw DraftError.draftNotFound
        }
        
        let encoder = JSONEncoder()
        existingDraft.draftData = try encoder.encode(draft)
        existingDraft.modifiedDate = Date()
        existingDraft.previewText = String(draft.postText.prefix(200))
        existingDraft.hasMedia = !draft.mediaItems.isEmpty || draft.videoItem != nil
        existingDraft.isReply = draft.threadEntries.first?.parentPostURI != nil
        existingDraft.isQuote = draft.threadEntries.first?.quotedPostURI != nil
        existingDraft.isThread = draft.isThreadMode
        
        try modelContext.save()
        logger.info("✅ Updated draft \(id.uuidString)")
    }
    
    /// Fetch all drafts for an account
    func fetchDrafts(for accountDID: String) throws -> [DraftPost] {
        logger.debug("📥 Fetching drafts for account: \(accountDID)")
        
        let predicate = #Predicate<DraftPost> { $0.accountDID == accountDID }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\.modifiedDate, order: .reverse)]
        
        let drafts = try modelContext.fetch(descriptor)
        logger.debug("📥 Fetched \(drafts.count) drafts")
        return drafts
    }
    
    /// Delete a draft by ID
    func deleteDraft(id: UUID) throws {
        logger.info("🗑️ Deleting draft: \(id.uuidString)")
        
        let predicate = #Predicate<DraftPost> { $0.id == id }
        let descriptor = FetchDescriptor(predicate: predicate)
        
        guard let draft = try modelContext.fetch(descriptor).first else {
            throw DraftError.draftNotFound
        }
        
        modelContext.delete(draft)
        try modelContext.save()
        logger.info("✅ Deleted draft \(id.uuidString)")
    }
    
    /// Count drafts for an account
    func countDrafts(for accountDID: String) throws -> Int {
        let predicate = #Predicate<DraftPost> { $0.accountDID == accountDID }
        let descriptor = FetchDescriptor(predicate: predicate)
        return try modelContext.fetchCount(descriptor)
    }
    
    /// Migrate a legacy draft
    func migrateLegacyDraft(
        id: UUID,
        draft: PostComposerDraft,
        accountDID: String,
        createdDate: Date,
        modifiedDate: Date
    ) throws {
        logger.info("🔄 Migrating legacy draft: \(id.uuidString)")
        
        let draftPost = try DraftPost.create(from: draft, accountDID: accountDID, id: id)
        draftPost.createdDate = createdDate
        draftPost.modifiedDate = modifiedDate
        
        modelContext.insert(draftPost)
        try modelContext.save()
        logger.info("✅ Migrated legacy draft \(id.uuidString)")
    }
    
    // MARK: - Feed State Operations
    
    /// Save scroll position for a feed
    func saveScrollPosition(postId: String, offsetFromPost: CGFloat, feedIdentifier: String) {
        do {
            // Remove existing scroll position for this feed
            let currentFeedId = feedIdentifier
            let descriptor = FetchDescriptor<PersistedScrollPosition>(
                predicate: #Predicate<PersistedScrollPosition> { position in
                    position.feedIdentifier == currentFeedId
                }
            )
            
            let existingPositions = try modelContext.fetch(descriptor)
            for position in existingPositions {
                modelContext.delete(position)
            }
            
            // Save new position
            let position = PersistedScrollPosition(
                postId: postId,
                offsetFromPost: offsetFromPost,
                feedIdentifier: feedIdentifier
            )
            modelContext.insert(position)
            try modelContext.save()
            
            logger.debug("Saved scroll position for feed \(feedIdentifier)")
        } catch {
            logger.error("Failed to save scroll position: \(error)")
        }
    }
    
    /// Load scroll position for a feed
    func loadScrollPosition(for feedIdentifier: String) -> PersistedScrollPosition? {
        do {
            let currentFeedId = feedIdentifier
            let descriptor = FetchDescriptor<PersistedScrollPosition>(
                predicate: #Predicate<PersistedScrollPosition> { position in
                    position.feedIdentifier == currentFeedId
                }
            )
            
            let positions = try modelContext.fetch(descriptor)
            guard let position = positions.first else { return nil }
            
            if position.isStale {
                logger.debug("Scroll position for \(feedIdentifier) is stale, removing")
                modelContext.delete(position)
                try? modelContext.save()
                return nil
            }
            
            return position
        } catch {
            logger.error("Failed to load scroll position: \(error)")
            return nil
        }
    }
    
    /// Save feed data with posts using upsert pattern to avoid unique constraint violations
    func saveFeedData(_ posts: [CachedFeedViewPost], for feedIdentifier: String, cursor: String? = nil) {
        do {
            let currentFeedId = feedIdentifier

            // Handle PersistedFeedState (no unique constraint conflict risk here)
            let stateDescriptor = FetchDescriptor<PersistedFeedState>(
                predicate: #Predicate<PersistedFeedState> { state in
                    state.feedIdentifier == currentFeedId
                }
            )

            let existingStates = try modelContext.fetch(stateDescriptor)
            let existingCursor = existingStates.first?.cursor
            for state in existingStates {
                modelContext.delete(state)
            }

            // Fetch existing posts for this feed to enable upsert
            let postsDescriptor = FetchDescriptor<CachedFeedViewPost>(
                predicate: #Predicate<CachedFeedViewPost> { post in
                    post.feedType == currentFeedId
                }
            )
            let existingPosts = try modelContext.fetch(postsDescriptor)

            // Collect IDs of new posts for cleanup
            let newPostIds = Set(posts.map { $0.id })

            // Delete posts that are NOT in the new set (safe - no ID conflict)
            for post in existingPosts where !newPostIds.contains(post.id) {
                modelContext.delete(post)
            }

            // Upsert new posts: update existing records in place, insert new ones
            // This avoids unique constraint violations by not deleting+inserting same ID
            let (updated, inserted) = modelContext.batchUpsert(
                posts,
                existingModels: existingPosts,
                uniqueKeyPath: \.id,
                update: { existing, new in existing.update(from: new) }
            )

            // Save new feed state
            let postIds = posts.map { $0.id }
            let feedState = PersistedFeedState(
                feedIdentifier: feedIdentifier,
                postIds: postIds,
                cursor: cursor ?? existingCursor
            )
            modelContext.insert(feedState)

            try modelContext.save()
            logger.debug("Saved \(posts.count) posts for feed \(feedIdentifier) (updated: \(updated), inserted: \(inserted))")
        } catch {
            logger.error("Failed to save feed data: \(error)")
        }
    }
    
    /// Load feed bundle (posts and cursor)
    func loadFeedBundle(for feedIdentifier: String) -> (posts: [CachedFeedViewPost], cursor: String?)? {
        do {
            let currentFeedId = feedIdentifier
            
            // Check feed state
            let stateDescriptor = FetchDescriptor<PersistedFeedState>(
                predicate: #Predicate<PersistedFeedState> { state in
                    state.feedIdentifier == currentFeedId
                }
            )
            
            let feedStates = try modelContext.fetch(stateDescriptor)
            guard let feedState = feedStates.first else {
                return nil
            }
            
            if feedState.isStale {
                // Clean up stale data
                modelContext.delete(feedState)
                
                let postsDescriptor = FetchDescriptor<CachedFeedViewPost>(
                    predicate: #Predicate<CachedFeedViewPost> { post in
                        post.feedType == currentFeedId
                    }
                )
                let stalePosts = try modelContext.fetch(postsDescriptor)
                for post in stalePosts {
                    modelContext.delete(post)
                }
                try? modelContext.save()
                return nil
            }
            
            // Only surface recently fresh caches to avoid showing stale content on launch
            guard feedState.isRecentlyFresh else {
                return nil
            }

            // Load cached posts
            let postsDescriptor = FetchDescriptor<CachedFeedViewPost>(
                predicate: #Predicate<CachedFeedViewPost> { post in
                    post.feedType == currentFeedId
                },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            
            let cachedPosts = try modelContext.fetch(postsDescriptor)
            return (cachedPosts, feedState.cursor)
        } catch {
            logger.error("Failed to load feed bundle: \(error)")
            return nil
        }
    }
    
    /// Check if a feed should be refreshed
    func shouldRefreshFeed(
        feedIdentifier: String,
        lastUserRefresh: Date?,
        appBecameActiveTime: Date?
    ) -> Bool {
        do {
            let currentFeedId = feedIdentifier
            let stateDescriptor = FetchDescriptor<PersistedFeedState>(
                predicate: #Predicate<PersistedFeedState> { state in
                    state.feedIdentifier == currentFeedId
                }
            )
            
            let feedStates = try modelContext.fetch(stateDescriptor)
            guard let feedState = feedStates.first else {
                return true // No cached data
            }
            
            if feedState.isRecentlyFresh {
                return false // Very fresh, no refresh needed
            }
            
            if feedState.isStale {
                return true // Stale, refresh needed
            }
            
            if let appActiveTime = appBecameActiveTime,
               Date().timeIntervalSince(appActiveTime) > 600 {
                return true // App was backgrounded long enough
            }
            
            if let lastRefresh = lastUserRefresh,
               Date().timeIntervalSince(lastRefresh) > 120 {
                return true // User refresh was >2 minutes ago
            }
            
            return false
        } catch {
            return true
        }
    }
    
    /// Save feed continuity info
    func saveFeedContinuityInfo(
        feedIdentifier: String,
        hasNewContent: Bool = false,
        lastKnownTopPostId: String? = nil,
        newPostCount: Int = 0,
        gapDetected: Bool = false
    ) {
        do {
            let currentFeedId = feedIdentifier
            let descriptor = FetchDescriptor<FeedContinuityInfo>(
                predicate: #Predicate<FeedContinuityInfo> { info in
                    info.feedIdentifier == currentFeedId
                }
            )
            
            let existingInfo = try modelContext.fetch(descriptor)
            for info in existingInfo {
                modelContext.delete(info)
            }
            
            let info = FeedContinuityInfo(
                feedIdentifier: feedIdentifier,
                hasNewContent: hasNewContent,
                lastKnownTopPostId: lastKnownTopPostId,
                newPostCount: newPostCount,
                gapDetected: gapDetected
            )
            modelContext.insert(info)
            try modelContext.save()
        } catch {
            logger.error("Failed to save continuity info: \(error)")
        }
    }
    
    /// Load feed continuity info
    func loadFeedContinuityInfo(for feedIdentifier: String) -> FeedContinuityInfo? {
        do {
            let currentFeedId = feedIdentifier
            let descriptor = FetchDescriptor<FeedContinuityInfo>(
                predicate: #Predicate<FeedContinuityInfo> { info in
                    info.feedIdentifier == currentFeedId
                }
            )
            return try modelContext.fetch(descriptor).first
        } catch {
            logger.error("Failed to load continuity info: \(error)")
            return nil
        }
    }
    
    /// Remove invalid posts from cache
    func removeInvalidPosts(withIds postIds: [String]) {
        do {
            for postId in postIds {
                let descriptor = FetchDescriptor<CachedFeedViewPost>(
                    predicate: #Predicate<CachedFeedViewPost> { post in
                        post.id == postId
                    }
                )
                let posts = try modelContext.fetch(descriptor)
                for post in posts {
                    modelContext.delete(post)
                }
            }
            try modelContext.save()
            logger.info("Removed \(postIds.count) invalid posts from cache")
        } catch {
            logger.error("Failed to remove invalid posts: \(error)")
        }
    }
    
    /// Clean up stale data
    func cleanupStaleData() {
        do {
            var cleanedPositions = 0
            var cleanedStates = 0
            
            // Clean up stale scroll positions
            let positionDescriptor = FetchDescriptor<PersistedScrollPosition>()
            let allPositions = try modelContext.fetch(positionDescriptor)
            
            for position in allPositions {
                if position.isStale {
                    modelContext.delete(position)
                    cleanedPositions += 1
                }
            }
            
            // Clean up stale feed states and associated posts
            let stateDescriptor = FetchDescriptor<PersistedFeedState>()
            let allStates = try modelContext.fetch(stateDescriptor)
            
            for state in allStates {
                if state.isStale {
                    modelContext.delete(state)
                    cleanedStates += 1
                    
                    let stateFeedId = state.feedIdentifier
                    let postsDescriptor = FetchDescriptor<CachedFeedViewPost>(
                        predicate: #Predicate<CachedFeedViewPost> { post in
                            post.feedType == stateFeedId
                        }
                    )
                    let stalePosts = try modelContext.fetch(postsDescriptor)
                    for post in stalePosts {
                        modelContext.delete(post)
                    }
                }
            }
            
            if cleanedPositions > 0 || cleanedStates > 0 {
                try modelContext.save()
                logger.debug("Cleaned up \(cleanedPositions) scroll positions and \(cleanedStates) feed states")
            }
        } catch {
            logger.error("Failed to cleanup stale data: \(error)")
        }
    }
    
    /// Clear all persisted feed data (for account switching)
    func clearAllFeedData() {
        do {
            let feedStates = try modelContext.fetch(FetchDescriptor<PersistedFeedState>())
            feedStates.forEach { modelContext.delete($0) }
            
            let cachedPosts = try modelContext.fetch(FetchDescriptor<CachedFeedViewPost>())
            cachedPosts.forEach { modelContext.delete($0) }
            
            let scrollPositions = try modelContext.fetch(FetchDescriptor<PersistedScrollPosition>())
            scrollPositions.forEach { modelContext.delete($0) }
            
            let continuityInfo = try modelContext.fetch(FetchDescriptor<FeedContinuityInfo>())
            continuityInfo.forEach { modelContext.delete($0) }
            
            try modelContext.save()
            logger.info("Cleared all persisted feed data")
        } catch {
            logger.error("Failed to clear persisted feed data: \(error)")
        }
    }
    
    // MARK: - App Settings Operations
    
    /// Load app settings
    func loadAppSettings() throws -> AppSettingsModel {
        let sharedId = AppSettingsModel.sharedId
        let descriptor = FetchDescriptor<AppSettingsModel>(
            predicate: #Predicate { $0.id == sharedId }
        )
        
        if let settings = try modelContext.fetch(descriptor).first {
            return settings
        }
        
        // Create default settings
        let settings = AppSettingsModel()
        settings.migrateFromUserDefaults()
        modelContext.insert(settings)
        try modelContext.save()
        logger.debug("Created default AppSettingsModel")
        return settings
    }
    
    /// Update app settings
    func updateAppSettings(_ apply: (AppSettingsModel) -> Void) throws {
        let settings = try loadAppSettings()
        apply(settings)
        try modelContext.save()
    }
}

// MARK: - Database Actor Provider

/// Provides access to the shared DatabaseModelActor instance
@MainActor
final class DatabaseActorProvider {
    static var shared: DatabaseActorProvider?
    
    let actor: DatabaseModelActor
    
    init(modelContainer: ModelContainer) {
        self.actor = DatabaseModelActor(modelContainer: modelContainer)
    }
    
    static func initialize(with container: ModelContainer) {
        guard shared == nil else { return }
        shared = DatabaseActorProvider(modelContainer: container)
    }
}
