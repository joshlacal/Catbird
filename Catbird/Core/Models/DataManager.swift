// import Foundation
// import SwiftData
// import OSLog

// /// A ModelActor to safely manage SwiftData operations across threads
// @ModelActor
// actor DataManager {
//     private let logger = Logger(subsystem: "blue.catbird", category: "DataManager")

//     // MARK: - Initialization Hooks

//     /// ModelActor's post-initialization hook to perform setup after the actor is initialized
//     nonisolated func didInit() {
//         // Perform any post-initialization setup that doesn't require actor isolation
//         Task { await logInitialization() }
//     }

//     /// Log initialization (isolated to the actor)
//     private func logInitialization() {
//         logger.debug("DataManager initialized with model container")
//     }

//     // MARK: - Preference Management

//     /// Load preferences from SwiftData
//     func loadPreferences() throws -> Preferences? {
//         let descriptor = FetchDescriptor<Preferences>()
//         let preferences = try modelContext.fetch(descriptor)
//         return preferences.first
//     }

//     /// Get preferences, creating a new instance if none exists
//     func getPreferences() throws -> Preferences {
//         if let preferences = try loadPreferences() {
//             return preferences
//         }

//         logger.debug("Creating new Preferences instance")
//         let newPreferences = Preferences()
//         modelContext.insert(newPreferences)
//         try modelContext.save()
//         return newPreferences
//     }

//     /// Save preferences to SwiftData
//     func savePreferences(_ preferences: Preferences) throws {
//         if let existingPreferences = try loadPreferences() {
//             logger.debug("Updating existing preferences")
//             existingPreferences.pinnedFeeds = preferences.pinnedFeeds
//             existingPreferences.savedFeeds = preferences.savedFeeds
//         } else {
//             logger.debug("Creating new preferences")
//             modelContext.insert(preferences)
//         }
//         try modelContext.save()
//     }

//     /// Update pinned and saved feeds
//     func updatePreferences(savedFeeds: [String], pinnedFeeds: [String]) throws {
//         let preferences = try getPreferences()
//         preferences.updateFeeds(pinned: pinnedFeeds, saved: savedFeeds)
//         try modelContext.save()
//         logger.debug("Updated preferences with \(pinnedFeeds.count) pinned feeds and \(savedFeeds.count) saved feeds")
//     }

//     // MARK: - Post Management

//     /// Fetch cached posts by feed type
//     func fetchCachedPosts(forFeed feedType: String, limit: Int = 50) throws -> [CachedPost] {
//         var descriptor = FetchDescriptor<CachedPost>(predicate: #Predicate { post in
//             post.feedType == feedType
//         })

//         // Sort by most recent
//         descriptor.sortBy = [SortDescriptor(\.indexedAt, order: .reverse)]

//         // Apply limit
//         descriptor.fetchLimit = limit

//         return try modelContext.fetch(descriptor)
//     }

//     /// Save posts to cache
//     func cachePosts(_ posts: [CachedPost]) throws {
//         for post in posts {
//             modelContext.insert(post)
//         }
//         try modelContext.save()
//         logger.debug("Cached \(posts.count) posts to SwiftData")
//     }

//     /// Clear cache for a specific feed type
//     func clearCache(forFeed feedType: String) throws {
//         let descriptor = FetchDescriptor<CachedPost>(predicate: #Predicate { post in
//             post.feedType == feedType
//         })

//         let postsToDelete = try modelContext.fetch(descriptor)
//         for post in postsToDelete {
//             modelContext.delete(post)
//         }

//         try modelContext.save()
//         logger.debug("Cleared cache for feed type: \(feedType), deleted \(postsToDelete.count) posts")
//     }

//     /// Prune old posts to prevent database bloat
//     func pruneOldPosts(olderThan interval: TimeInterval = 86400) throws {
//         let cutoffDate = Date().addingTimeInterval(-interval)

//         let descriptor = FetchDescriptor<CachedPost>(predicate: #Predicate { post in
//             post.indexedAt < cutoffDate
//         })

//         let postsToDelete = try modelContext.fetch(descriptor)
//         for post in postsToDelete {
//             modelContext.delete(post)
//         }

//         try modelContext.save()
//         logger.debug("Pruned \(postsToDelete.count) old posts older than \(interval) seconds")
//     }
// }
