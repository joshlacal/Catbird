//
//  SocialConnectionAnalyzer.swift
//  Catbird
//
//  Created on 6/2/25.
//

import Foundation
import OSLog
import Petrel

/// Analyzes social connections to provide "Because you follow X" explanations
actor SocialConnectionAnalyzer {
    // MARK: - Properties
    private let appState: AppState
    private let logger = Logger(subsystem: "blue.catbird", category: "SocialConnectionAnalyzer")
    
    // Cache for follow relationships
    private var followingCache: [String: FollowingInfo] = [:]
    private var feedCreatorCache: [String: CreatorInfo] = [:]
    private var lastCacheUpdate: Date?
    private let cacheExpiration: TimeInterval = 1800 // 30 minutes
    
    // MARK: - Types
    
    struct FollowingInfo {
        let userDID: DID
        let handle: String
        let displayName: String?
        let avatarURL: URL?
        let fetchedAt: Date
        
        var isExpired: Bool {
            Date().timeIntervalSince(fetchedAt) > 1800
        }
    }
    
    struct CreatorInfo {
        let did: DID
        let handle: String
        let displayName: String?
        let avatarURL: URL?
        let feedURIs: [String]
    }
    
    struct ConnectionExplanation {
        let type: ConnectionType
        let users: [FollowingInfo]
        let displayText: String
    }
    
    enum ConnectionType {
        case directFollow // You follow the feed creator
        case followsLiked // People you follow have liked this feed
        case followsSubscribed // People you follow subscribe to this feed
        case mutualInterests // Similar interests to people you follow
    }
    
    // MARK: - Initialization
    
    init(appState: AppState) {
        self.appState = appState
    }
    
    // MARK: - Public Methods
    
    /// Analyze social connections for a feed and provide explanation
    func analyzeConnection(for feed: AppBskyFeedDefs.GeneratorView) async throws -> ConnectionExplanation? {
        // Ensure we have fresh following data
        try await refreshFollowingCacheIfNeeded()
        
        let feedCreatorDID = feed.creator.did
        
        // Check for direct follow relationship
        if let directConnection = followingCache[feedCreatorDID.didString()] {
            return ConnectionExplanation(
                type: .directFollow,
                users: [directConnection],
                displayText: "Because you follow @\(directConnection.handle.description)"
            )
        }
        
        // Check for indirect connections through likes or subscriptions
        let indirectConnections = await findIndirectConnections(for: feed)
        
        if !indirectConnections.isEmpty {
            let primaryUser = indirectConnections[0]
            let additionalCount = indirectConnections.count - 1
            
            var displayText = "Because @\(primaryUser.handle) liked this"
            if additionalCount > 0 {
                displayText += " and \(additionalCount) other\(additionalCount == 1 ? "" : "s") you follow"
            }
            
            return ConnectionExplanation(
                type: .followsLiked,
                users: indirectConnections,
                displayText: displayText
            )
        }
        
        return nil
    }
    
    /// Get list of all users the current user follows
    func getFollowingList() async throws -> [FollowingInfo] {
        try await refreshFollowingCacheIfNeeded()
        return Array(followingCache.values).sorted { $0.handle < $1.handle }
    }
    
    /// Check if user follows a specific account
    func isFollowing(_ userDID: DID) async -> Bool {
        return followingCache[userDID.didString()] != nil
    }
    
    /// Get explanation for why a feed appears in recommendations
    func getRecommendationExplanation(for feed: AppBskyFeedDefs.GeneratorView, basedOnInterests interests: [String]) async -> String {
        // Try to find social connection first
        if let connection = try? await analyzeConnection(for: feed) {
            return connection.displayText
        }
        
        // Fall back to interest-based explanation
        let matchingInterests = findMatchingInterests(in: feed, userInterests: interests)
        if !matchingInterests.isEmpty {
            let interestList = matchingInterests.prefix(2).joined(separator: ", ")
            return "Matches your interests: \(interestList)"
        }
        
        // Default explanation
        return "Recommended for you"
    }
    
    /// Clear all cached data
    func clearCache() {
        followingCache.removeAll()
        feedCreatorCache.removeAll()
        lastCacheUpdate = nil
    }
    
    // MARK: - Private Methods
    
    private func refreshFollowingCacheIfNeeded() async throws {
        // Check if cache is still valid
        if let lastUpdate = lastCacheUpdate,
           Date().timeIntervalSince(lastUpdate) < cacheExpiration,
           !followingCache.isEmpty {
            return
        }
        
        logger.info("Refreshing following cache")
        
         let client = appState.atProtoClient
        
        // Fetch follows using AT Protocol  
        var allFollows: [AppBskyActorDefs.ProfileView] = []
        var cursor: String?
        
        repeat {
            let params = AppBskyGraphGetFollows.Parameters(
                actor: try ATIdentifier(string: appState.userDID),
                limit: 100,
                cursor: cursor
            )

            guard let client = client else {
                throw SocialAnalysisError.fetchFailed
            }

            let (responseCode, response) = try await client.app.bsky.graph.getFollows(input: params)
            
            guard responseCode == 200, let followsResponse = response else {
                throw SocialAnalysisError.fetchFailed
            }
            
            allFollows.append(contentsOf: followsResponse.follows)
            cursor = followsResponse.cursor
            
        } while cursor != nil && allFollows.count < 1000 // Reasonable limit
        
        // Update cache
        followingCache.removeAll()
        
        for follow in allFollows {
            let followingInfo = FollowingInfo(
                userDID: follow.did,
                handle: follow.handle.description,
                displayName: follow.displayName,
                avatarURL: follow.finalAvatarURL(),
                fetchedAt: Date()
            )
            
            self.followingCache[follow.did.didString()] = followingInfo
        }
        
        lastCacheUpdate = Date()
        logger.info("Updated following cache with \(self.followingCache.count) follows")
    }
    
    private func findIndirectConnections(for feed: AppBskyFeedDefs.GeneratorView) async -> [FollowingInfo] {
        // This is a simplified implementation
        // In a full implementation, you would:
        // 1. Query who has liked this feed
        // 2. Query who subscribes to this feed
        // 3. Cross-reference with your following list
        
        // For now, we'll return an empty array as this requires additional API calls
        // that aren't readily available in the current AT Protocol APIs
        
        return []
    }
    
    private func findMatchingInterests(in feed: AppBskyFeedDefs.GeneratorView, userInterests: [String]) -> [String] {
        let feedText = "\(feed.displayName) \(feed.description ?? "")".lowercased()
        
        return userInterests.filter { interest in
            feedText.contains(interest.lowercased())
        }
    }
}

// MARK: - Errors

enum SocialAnalysisError: LocalizedError {
    case clientNotAvailable
    case fetchFailed
    case invalidData
    
    var errorDescription: String? {
        switch self {
        case .clientNotAvailable:
            return "Network client not available"
        case .fetchFailed:
            return "Failed to fetch social connections"
        case .invalidData:
            return "Invalid social connection data"
        }
    }
}
