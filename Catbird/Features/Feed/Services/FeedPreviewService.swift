//
//  FeedPreviewService.swift
//  Catbird
//
//  Created on 6/2/25.
//

import Foundation
import OSLog
import Petrel

/// Service for fetching and caching feed previews
actor FeedPreviewService {
    // MARK: - Properties
    private let appState: AppState
    private var previewCache: [String: CachedPreview] = [:]
    private let cacheExpiration: TimeInterval = 300 // 5 minutes
    private let logger = Logger(subsystem: "blue.catbird", category: "FeedPreviewService")
    
    // MARK: - Types
    private struct CachedPreview {
        let posts: [AppBskyFeedDefs.FeedViewPost]
        let fetchedAt: Date
        
        var isExpired: Bool {
            Date().timeIntervalSince(fetchedAt) > 300
        }
    }
    
    // MARK: - Initialization
    init(appState: AppState) {
        self.appState = appState
    }
    
    // MARK: - Public Methods
    
    /// Fetch preview posts for a feed
    func fetchPreview(for feedURI: ATProtocolURI) async throws -> [AppBskyFeedDefs.FeedViewPost] {
        let cacheKey = feedURI.uriString()
        
        // Check cache first
        if let cached = previewCache[cacheKey], !cached.isExpired {
            logger.debug("Returning cached preview for feed: \(cacheKey)")
            return cached.posts
        }
        
        // Fetch from server
        logger.info("Fetching preview for feed: \(cacheKey)")
        
        guard let client = appState.atProtoClient else {
            throw FeedPreviewError.clientNotAvailable
        }
        
        let params = AppBskyFeedGetFeed.Parameters(
            feed: feedURI,
            limit: 5 // Reduced for faster initial load
        )
        
        let (responseCode, response) = try await client.app.bsky.feed.getFeed(input: params)
        
        guard responseCode == 200, let feedResponse = response else {
            logger.error("Failed to fetch feed preview. Response code: \(responseCode)")
            throw FeedPreviewError.fetchFailed(responseCode)
        }
        
        // Cache the results
        let posts = feedResponse.feed
        previewCache[cacheKey] = CachedPreview(posts: posts, fetchedAt: Date())
        
        // Clean old cache entries
        await cleanExpiredCache()
        
        return posts
    }
    
    /// Invalidate cache for a specific feed
    func invalidateCache(for feedURI: ATProtocolURI) {
        previewCache.removeValue(forKey: feedURI.uriString())
    }
    
    /// Clear all cached previews
    func clearAllCache() {
        previewCache.removeAll()
    }
    
    // MARK: - Private Methods
    
    private func cleanExpiredCache() {
        let now = Date()
        previewCache = previewCache.filter { _, cached in
            now.timeIntervalSince(cached.fetchedAt) <= cacheExpiration
        }
    }
}

// MARK: - Errors

enum FeedPreviewError: LocalizedError {
    case clientNotAvailable
    case fetchFailed(Int)
    case invalidFeedURI
    
    var errorDescription: String? {
        switch self {
        case .clientNotAvailable:
            return "Network client not available"
        case .fetchFailed(let code):
            return "Failed to fetch feed preview (code: \(code))"
        case .invalidFeedURI:
            return "Invalid feed URI"
        }
    }
}