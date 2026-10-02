//
//  LightweightFeedStateCache.swift
//  Catbird
//
//  Lightweight state cache that works WITH SwiftData, not against it
//

import Foundation
import SwiftUI
import os

/// Lightweight feed state cache for UI restoration
/// Only stores references and scroll positions, not actual post data
@MainActor
final class LightweightFeedStateCache {
    static let shared = LightweightFeedStateCache()
    
    private let logger = Logger(subsystem: "blue.catbird", category: "FeedStateCache")
    
    /// Lightweight scroll state - just IDs and positions
    struct ScrollState: Codable {
        let postID: String
        let offsetFromTop: CGFloat
        let timestamp: Date
        let feedIdentifier: String
    }
    
    /// Lightweight feed state - just metadata
    struct FeedMetadata: Codable {
        let feedIdentifier: String
        let lastRefreshTime: Date
        let postCount: Int
        let firstPostID: String?
        let lastPostID: String?
    }
    
    private init() {}
    
    // MARK: - Scroll State (can be saved to UserDefaults)
    
    func saveScrollState(feedIdentifier: String, postID: String, offset: CGFloat) {
        let state = ScrollState(
            postID: postID,
            offsetFromTop: offset,
            timestamp: Date(),
            feedIdentifier: feedIdentifier
        )
        
        let key = "scroll_state_\(feedIdentifier)"
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: key)
            logger.debug("Saved scroll state for \(feedIdentifier): post \(postID)")
        }
    }
    
    func loadScrollState(feedIdentifier: String) -> ScrollState? {
        let key = "scroll_state_\(feedIdentifier)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(ScrollState.self, from: data) else {
            return nil
        }
        
        // Don't restore if too old (> 1 hour)
        if Date().timeIntervalSince(state.timestamp) > 3600 {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        
        return state
    }
    
    // MARK: - Feed Metadata (lightweight info only)
    
    func saveFeedMetadata(feedIdentifier: String, postCount: Int, firstPostID: String?, lastPostID: String?) {
        let metadata = FeedMetadata(
            feedIdentifier: feedIdentifier,
            lastRefreshTime: Date(),
            postCount: postCount,
            firstPostID: firstPostID,
            lastPostID: lastPostID
        )
        
        let key = "feed_meta_\(feedIdentifier)"
        if let data = try? JSONEncoder().encode(metadata) {
            UserDefaults.standard.set(data, forKey: key)
            logger.debug("Saved metadata for \(feedIdentifier): \(postCount) posts")
        }
    }
    
    func loadFeedMetadata(feedIdentifier: String) -> FeedMetadata? {
        let key = "feed_meta_\(feedIdentifier)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let metadata = try? JSONDecoder().decode(FeedMetadata.self, from: data) else {
            return nil
        }
        
        // Don't use if too old
        if Date().timeIntervalSince(metadata.lastRefreshTime) > 3600 {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        
        return metadata
    }
    
    // MARK: - Intelligent Refresh Decision
    
    func shouldRefreshFeed(feedIdentifier: String, backgroundDuration: TimeInterval) -> Bool {
        guard let metadata = loadFeedMetadata(feedIdentifier: feedIdentifier) else {
            // No metadata = should refresh
            return true
        }
        
        let timeSinceRefresh = Date().timeIntervalSince(metadata.lastRefreshTime)
        
        // Refresh logic based on background duration
        if backgroundDuration < 60 { // Less than 1 minute
            // Don't refresh for very short backgrounds
            return false
        } else if backgroundDuration < 600 { // Less than 10 minutes
            // Only refresh if data is stale (> 5 minutes old)
            return timeSinceRefresh > 300
        } else if backgroundDuration < 1800 { // Less than 30 minutes
            // Refresh if data is > 10 minutes old
            return timeSinceRefresh > 600
        } else {
            // Long background - always refresh
            return true
        }
    }
    
    // MARK: - Cleanup
    
    func clearFeedState(feedIdentifier: String) {
        UserDefaults.standard.removeObject(forKey: "scroll_state_\(feedIdentifier)")
        UserDefaults.standard.removeObject(forKey: "feed_meta_\(feedIdentifier)")
        logger.debug("Cleared state for \(feedIdentifier)")
    }
    
    func clearAllStates() {
        let keys = UserDefaults.standard.dictionaryRepresentation().keys
        for key in keys where key.hasPrefix("scroll_state_") || key.hasPrefix("feed_meta_") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        logger.debug("Cleared all feed states")
    }
}