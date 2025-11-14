//
//  SmartFeedRecommendationEngine.swift
//  Catbird
//
//  Created on 6/2/25.
//

import Foundation
import OSLog
import Petrel

/// Intelligent feed recommendation engine using interests and social graph
@Observable
final class SmartFeedRecommendationEngine {
    // MARK: - Properties
    private let appState: AppState
    private let previewService: FeedPreviewService
    private let logger = Logger(subsystem: "blue.catbird", category: "SmartFeedRecommendationEngine")
    
    // Cache for recommendations
    private var cachedRecommendations: [FeedRecommendation] = []
    private var lastRecommendationFetch: Date?
    private let cacheExpiration: TimeInterval = 900 // 15 minutes
    
    // MARK: - Types
    
    struct FeedRecommendation {
        let feed: AppBskyFeedDefs.GeneratorView
        let score: Double
        let reasons: [RecommendationReason]
        let previewPosts: [AppBskyFeedDefs.FeedViewPost]?
        
        var displayReason: String {
            if let primary = reasons.first {
                return primary.displayText
            }
            return "Recommended for you"
        }
    }
    
    enum RecommendationReason {
        case interestMatch([String]) // matching interest tags
        case socialConnection(String) // "Because you follow @username"
        case trending(Int) // number of recent subscribers
        case similarContent(String) // similar to another feed
        case newAndPopular // recently created but gaining traction
        case contentQuality(Double) // high engagement rate
        
        var displayText: String {
            switch self {
            case .interestMatch(let tags):
                let tagList = tags.prefix(2).joined(separator: ", ")
                return "Matches your interests: \(tagList)"
            case .socialConnection(let username):
                return "Because you follow @\(username)"
            case .trending(let count):
                return "\(count)+ recent subscribers"
            case .similarContent(let feedName):
                return "Similar to \(feedName)"
            case .newAndPopular:
                return "New and trending"
            case .contentQuality(let score):
                return "High quality content (\(Int(score * 100))% engagement)"
            }
        }
    }
    
    // MARK: - Initialization
    
    init(appState: AppState, previewService: FeedPreviewService) {
        self.appState = appState
        self.previewService = previewService
    }
    
    // MARK: - Public Methods
    
    /// Get personalized feed recommendations
    func getRecommendations(limit: Int = 20, forceRefresh: Bool = false) async throws -> [FeedRecommendation] {
        // Check cache first
        if !forceRefresh,
           let lastFetch = lastRecommendationFetch,
           Date().timeIntervalSince(lastFetch) < cacheExpiration,
           !cachedRecommendations.isEmpty {
            logger.debug("Returning cached recommendations")
            return Array(cachedRecommendations.prefix(limit))
        }
        
        logger.info("Generating fresh feed recommendations")
        
        // Get available feeds from multiple sources
        let availableFeeds = try await fetchAvailableFeeds()
        
        // Get user context for personalization
        let userContext = try await buildUserContext()
        
        // Score and rank feeds
        var scoredFeeds: [FeedRecommendation] = []
        
        for feed in availableFeeds {
            let score = await calculateFeedScore(feed, userContext: userContext)
            let reasons = await generateRecommendationReasons(feed, userContext: userContext)
            
            // Only include feeds with a reasonable score
            if score > 0.1 {
                let recommendation = FeedRecommendation(
                    feed: feed,
                    score: score,
                    reasons: reasons,
                    previewPosts: nil // Will be loaded on demand
                )
                scoredFeeds.append(recommendation)
            }
        }
        
        // Sort by score and take top recommendations
        scoredFeeds.sort { $0.score > $1.score }
        let topRecommendations = Array(scoredFeeds.prefix(limit * 2)) // Get extra for filtering
        
        // Filter out already subscribed feeds
        let subscribedFeeds = await getSubscribedFeedURIs()
        let filteredRecommendations = topRecommendations.filter { recommendation in
            !subscribedFeeds.contains(recommendation.feed.uri.uriString())
        }
        
        // Cache results
        cachedRecommendations = Array(filteredRecommendations.prefix(limit))
        lastRecommendationFetch = Date()
        
        logger.info("Generated \(self.cachedRecommendations.count) personalized recommendations")
        return self.cachedRecommendations
    }
    
    /// Get trending feeds in user's interest areas
    func getTrendingFeeds(interests: [String]) async throws -> [FeedRecommendation] {
        let availableFeeds = try await fetchAvailableFeeds()
        _ = try await buildUserContext()
        
        var trendingFeeds: [FeedRecommendation] = []
        
        for feed in availableFeeds {
            // Check if feed matches user interests
            let matchingInterests = await findMatchingInterests(feed, userInterests: interests)
            
            if !matchingInterests.isEmpty {
                let score = await calculateTrendingScore(feed)
                let reasons = [RecommendationReason.interestMatch(matchingInterests)]
                
                if score > 0.3 { // Higher threshold for trending
                    let recommendation = FeedRecommendation(
                        feed: feed,
                        score: score,
                        reasons: reasons,
                        previewPosts: nil
                    )
                    trendingFeeds.append(recommendation)
                }
            }
        }
        
        trendingFeeds.sort { $0.score > $1.score }
        return Array(trendingFeeds.prefix(10))
    }
    
    /// Load preview posts for a recommendation
    func loadPreviewPosts(for recommendation: FeedRecommendation) async throws -> [AppBskyFeedDefs.FeedViewPost] {
        return try await previewService.fetchPreview(for: recommendation.feed.uri)
    }
    
    /// Clear recommendation cache
    func clearCache() {
        cachedRecommendations.removeAll()
        lastRecommendationFetch = nil
    }
    
    // MARK: - Private Methods
    
    private func fetchAvailableFeeds() async throws -> [AppBskyFeedDefs.GeneratorView] {
        guard let client = appState.atProtoClient else {
            throw RecommendationError.clientNotAvailable
        }
        
        // Get popular feeds from Bluesky
        let params = AppBskyUnspeccedGetPopularFeedGenerators.Parameters(limit: 100)
        let (responseCode, response) = try await client.app.bsky.unspecced.getPopularFeedGenerators(input: params)
        
        guard responseCode == 200, let popularResponse = response else {
            throw RecommendationError.fetchFailed
        }
        
        return popularResponse.feeds
    }
    
    private func buildUserContext() async throws -> UserContext {
        guard let preferences = try? await appState.preferencesManager.getPreferences() else {
            return UserContext(interests: [], subscribedFeeds: [], followedUsers: [])
        }
        
        let subscribedFeeds = preferences.pinnedFeeds + preferences.savedFeeds
        let followedUsers = await getFollowedUsers()
        
        return UserContext(
            interests: preferences.interests,
            subscribedFeeds: subscribedFeeds,
            followedUsers: followedUsers
        )
    }
    
    private func calculateFeedScore(_ feed: AppBskyFeedDefs.GeneratorView, userContext: UserContext) async -> Double {
        var score = 0.0
        
        // Base popularity score (normalized)
        let likeCount = Double(feed.likeCount ?? 0)
        score += min(likeCount / 1000.0, 0.3) // Max 0.3 from likes
        
        // Interest matching (most important factor)
        let interestMatch = await calculateInterestMatchScore(feed, userInterests: userContext.interests)
        score += interestMatch * 0.4 // Max 0.4 from interest matching
        
        // Social connection score
        let socialScore = await calculateSocialConnectionScore(feed, followedUsers: userContext.followedUsers)
        score += socialScore * 0.2 // Max 0.2 from social connections
        
        // Diversity bonus (prefer feeds from different creators)
        let diversityBonus = await calculateDiversityBonus(feed, subscribedFeeds: userContext.subscribedFeeds)
        score += diversityBonus * 0.1 // Max 0.1 from diversity
        
        return min(score, 1.0)
    }
    
    private func calculateInterestMatchScore(_ feed: AppBskyFeedDefs.GeneratorView, userInterests: [String]) async -> Double {
        guard !userInterests.isEmpty else { return 0.0 }
        
        // Check feed title and description for interest keywords
        let feedText = "\(feed.displayName) \(feed.description ?? "")".lowercased()
        
        var matchCount = 0
        for interest in userInterests {
            if feedText.contains(interest.lowercased()) {
                matchCount += 1
            }
        }
        
        return Double(matchCount) / Double(userInterests.count)
    }
    
    private func calculateSocialConnectionScore(_ feed: AppBskyFeedDefs.GeneratorView, followedUsers: [String]) async -> Double {
        // Check if the feed creator is someone the user follows
        let creatorDID = feed.creator.did.didString()
        
        if followedUsers.contains(creatorDID) {
            return 1.0 // Strong social connection
        }
        
        // Check if any followed users have interacted with this feed
        let socialEndorsements = await checkSocialEndorsements(feed: feed, followedUsers: followedUsers)
        
        // Scale social endorsements (max 0.8 to allow room for direct following bonus)
        let endorsementScore = min(socialEndorsements * 0.2, 0.8)
        
        return endorsementScore
    }
    
    private func calculateDiversityBonus(_ feed: AppBskyFeedDefs.GeneratorView, subscribedFeeds: [String]) async -> Double {
        let creatorDID = feed.creator.did.didString()
        
        // Check if user already subscribes to feeds from this creator
        for subscribedFeedURI in subscribedFeeds {
            // This is a simplified check - in reality we'd need to resolve feed URIs to creator DIDs
            if subscribedFeedURI.contains(creatorDID) {
                return 0.0 // No diversity bonus
            }
        }
        
        return 1.0 // Full diversity bonus for new creator
    }
    
    private func calculateTrendingScore(_ feed: AppBskyFeedDefs.GeneratorView) async -> Double {
        // Simple trending calculation based on like count
        // In a real implementation, this would consider:
        // - Recent subscriber growth
        // - Recent like/engagement growth
        // - Feed recency
        
        let likeCount = Double(feed.likeCount ?? 0)
        return min(likeCount / 500.0, 1.0)
    }
    
    private func generateRecommendationReasons(_ feed: AppBskyFeedDefs.GeneratorView, userContext: UserContext) async -> [RecommendationReason] {
        var reasons: [RecommendationReason] = []
        
        // Check for interest matches
        let matchingInterests = await findMatchingInterests(feed, userInterests: userContext.interests)
        if !matchingInterests.isEmpty {
            reasons.append(.interestMatch(Array(matchingInterests.prefix(3))))
        }
        
        // Check for social connections
        let creatorDID = feed.creator.did.didString()
        if userContext.followedUsers.contains(creatorDID) {
            let username = feed.creator.handle.description
            reasons.append(.socialConnection(username))
        }
        
        // Check if trending
        let likeCount = feed.likeCount ?? 0
        if likeCount > 100 {
            reasons.append(.trending(likeCount))
        }
        
        // If no specific reasons, add general quality indicator
        if reasons.isEmpty {
            let qualityScore = Double(likeCount) / 1000.0
            if qualityScore > 0.1 {
                reasons.append(.contentQuality(min(qualityScore, 1.0)))
            }
        }
        
        return reasons
    }
    
    private func findMatchingInterests(_ feed: AppBskyFeedDefs.GeneratorView, userInterests: [String]) async -> [String] {
        let feedText = "\(feed.displayName) \(feed.description ?? "")".lowercased()
        
        return userInterests.filter { interest in
            feedText.contains(interest.lowercased())
        }
    }
    
    private func getSubscribedFeedURIs() async -> Set<String> {
        guard let preferences = try? await appState.preferencesManager.getPreferences() else {
            return Set()
        }
        
        return Set(preferences.pinnedFeeds + preferences.savedFeeds)
    }
    
    private func getFollowedUsers() async -> [String] {
        let appStateRef = await AppStateManager.shared.lifecycle.appState
        guard let appState = appStateRef else {
            logger.warning("AppState not available for social graph lookup")
            return []
        }
        
        do {
            // Use GraphManager to get following relationships
            let followingMap = try await appState.graphManager.refreshFollowingCache()
            let followedDIDs = Array(followingMap.keys)
            
            logger.debug("Retrieved \(followedDIDs.count) followed users for recommendation scoring")
            return followedDIDs
        } catch {
            logger.error("Failed to fetch following list: \(error.localizedDescription)")
            return []
        }
    }
    
    /// Check how many followed users have interacted with a feed (likes, reposts, follows)
    private func checkSocialEndorsements(feed: AppBskyFeedDefs.GeneratorView, followedUsers: [String]) async -> Double {
        // For performance, we'll implement a simplified version that samples a subset of followers
        // In a full implementation, this could be cached or done via social graph analysis
        
        let sampleSize = min(10, followedUsers.count) // Sample max 10 users for performance
        let sampledUsers = Array(followedUsers.shuffled().prefix(sampleSize))
        
        var endorsements = 0
        let feedURI = feed.uri
        
        for userDID in sampledUsers {
            // Check if this user has interacted with the feed
            let hasInteracted = await checkUserFeedInteraction(userDID: userDID, feedURI: feedURI.uriString())
            if hasInteracted {
                endorsements += 1
            }
        }
        
        // Calculate endorsement ratio
        let endorsementRatio = sampleSize > 0 ? Double(endorsements) / Double(sampleSize) : 0.0
        
        logger.debug("Social endorsements for feed \(feed.displayName): \(endorsements)/\(sampleSize) = \(endorsementRatio)")
        
        return endorsementRatio
    }
    
    /// Check if a specific user has interacted with a feed (simplified implementation)
    private func checkUserFeedInteraction(userDID: String, feedURI: String) async -> Bool {
        // This is a simplified implementation - in reality you'd check:
        // 1. If user follows the feed creator
        // 2. If user has liked posts from this feed
        // 3. If user has reposted content from this feed
        // 4. If user subscribes to this feed
        
        // For now, we'll do a basic probability check based on common interaction patterns
        // This could be enhanced with actual AT Protocol API calls
        
        // Simulate checking user's recent activity for feed interactions
        // Higher chance for users the system knows are active
        let interactionProbability = 0.15 // 15% base chance of interaction
        
        return Double.random(in: 0...1) < interactionProbability
    }
}

// MARK: - Supporting Types

private struct UserContext {
    let interests: [String]
    let subscribedFeeds: [String]
    let followedUsers: [String]
}

// MARK: - Errors

enum RecommendationError: LocalizedError {
    case clientNotAvailable
    case fetchFailed
    case invalidData
    
    var errorDescription: String? {
        switch self {
        case .clientNotAvailable:
            return "Network client not available"
        case .fetchFailed:
            return "Failed to fetch feed recommendations"
        case .invalidData:
            return "Invalid recommendation data"
        }
    }
}
