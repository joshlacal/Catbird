//
//  SearchModels.swift
//  Catbird
//
//  Created on 3/9/25.
//

import Foundation
import Petrel

/// Models and extensions related to search functionality

// MARK: - Extension methods for common search operations

extension AppBskyActorDefs.ProfileView {
    /// Check if this profile is following the current user
    func isFollowingUser(did: String) -> Bool {
        return viewer?.followedBy != nil
    }
    
    /// Check if the current user is following this profile
    func isFollowedByUser() -> Bool {
        return viewer?.following != nil
    }
    
    /// Check if this profile is blocked by the current user
    func isBlocked() -> Bool {
        return viewer?.blocking != nil
    }
    
    /// Check if this profile is muted by the current user
    func isMuted() -> Bool {
        return viewer?.muted ?? false
    }
}

// MARK: - Search Status Models

/// Model for tracking search execution performance and analytics
struct SearchMetadata {
    let query: String
    let executionTimeMs: Double
    let resultCounts: ResultCounts
    let filters: SearchFilters
    let timestamp: Date
    
    struct ResultCounts {
        let profiles: Int
        let posts: Int
        let feeds: Int
        let starterPacks: Int
        
        var total: Int {
            return profiles + posts + feeds + starterPacks
        }
    }
    
    struct SearchFilters {
        let date: FilterDate
        let contentTypes: [ContentType]
        let languages: [String]
        let advancedFilters: [String: Any]
    }
}

// MARK: - Search History Models

/// Model for search history persistence
struct SearchHistoryItem: Codable, Identifiable {
    let id: UUID
    let query: String
    let timestamp: Date
    let resultCount: Int
    
    init(query: String, resultCount: Int) {
        self.id = UUID()
        self.query = query
        self.timestamp = Date()
        self.resultCount = resultCount
    }
}

// MARK: - Search Ranking and Relevance

/// Advanced search result ranking system
enum SearchRanking {
    /// Calculate relevance score for a search result
    static func calculateRelevanceScore(
        query: String,
        content: String,
        engagement: EngagementMetrics,
        userMetrics: UserMetrics,
        recency: TimeInterval,
        boost: AdvancedSearchParams.RelevanceBoost = .balanced
    ) -> Double {
        let textScore = calculateTextRelevance(query: query, content: content)
        let engagementScore = calculateEngagementScore(engagement)
        let userScore = calculateUserScore(userMetrics)
        let recencyScore = calculateRecencyScore(recency)
        
        // Apply weighting based on boost level
        let weights = getWeights(for: boost)
        
        return (textScore * weights.text) +
               (engagementScore * weights.engagement) +
               (userScore * weights.user) +
               (recencyScore * weights.recency)
    }
    
    private static func calculateTextRelevance(query: String, content: String) -> Double {
        let queryTerms = query.lowercased().components(separatedBy: .whitespacesAndNewlines)
        let contentWords = content.lowercased().components(separatedBy: .whitespacesAndNewlines)
        
        var score: Double = 0
        
        for term in queryTerms {
            // Exact matches score higher
            if contentWords.contains(term) {
                score += 1.0
            }
            // Partial matches
            else {
                for word in contentWords {
                    if word.contains(term) || term.contains(word) {
                        score += 0.5
                    }
                }
            }
        }
        
        // Normalize by query length
        return min(score / Double(queryTerms.count), 1.0)
    }
    
    private static func calculateEngagementScore(_ engagement: EngagementMetrics) -> Double {
        let totalEngagement = engagement.likes + engagement.reposts + engagement.replies
        // Logarithmic scale to prevent outliers from dominating
        return min(log10(Double(totalEngagement + 1)) / 4.0, 1.0)
    }
    
    private static func calculateUserScore(_ userMetrics: UserMetrics) -> Double {
        var score: Double = 0
        
        // Verified users get a boost
        if userMetrics.isVerified {
            score += 0.3
        }
        
        // Follower count (logarithmic)
        score += min(log10(Double(userMetrics.followerCount + 1)) / 6.0, 0.5)
        
        // Following relationship boost
        if userMetrics.isFollowing {
            score += 0.2
        }
        
        return min(score, 1.0)
    }
    
    private static func calculateRecencyScore(_ recency: TimeInterval) -> Double {
        let hoursAgo = recency / 3600
        
        // Recent content scores higher, with exponential decay
        if hoursAgo < 1 {
            return 1.0
        } else if hoursAgo < 24 {
            return 0.8
        } else if hoursAgo < 168 { // 1 week
            return 0.6
        } else if hoursAgo < 720 { // 1 month
            return 0.4
        } else {
            return 0.2
        }
    }
    
    private static func getWeights(for boost: AdvancedSearchParams.RelevanceBoost) -> (text: Double, engagement: Double, user: Double, recency: Double) {
        switch boost {
        case .minimal:
            return (text: 0.7, engagement: 0.1, user: 0.1, recency: 0.1)
        case .balanced:
            return (text: 0.4, engagement: 0.3, user: 0.2, recency: 0.1)
        case .aggressive:
            return (text: 0.3, engagement: 0.4, user: 0.2, recency: 0.1)
        }
    }
}

/// Metrics for engagement calculation
struct EngagementMetrics {
    let likes: Int
    let reposts: Int
    let replies: Int
}

/// Metrics for user scoring
struct UserMetrics {
    let followerCount: Int
    let isVerified: Bool
    let isFollowing: Bool
}

// MARK: - Search Suggestions

/// Advanced search suggestion system
enum SearchSuggestion {
    /// Generate intelligent search suggestions based on query
    static func generateSuggestions(for query: String, history: [String] = [], trending: [String] = []) -> [String] {
        var suggestions: [String] = []
        let lowercaseQuery = query.lowercased()
        
        // Add history-based suggestions
        let historySuggestions = history
            .filter { $0.lowercased().contains(lowercaseQuery) && $0.lowercased() != lowercaseQuery }
            .prefix(3)
        suggestions.append(contentsOf: historySuggestions)
        
        // Add trending suggestions that match
        let trendingSuggestions = trending
            .filter { $0.lowercased().contains(lowercaseQuery) && !suggestions.contains($0) }
            .prefix(2)
        suggestions.append(contentsOf: trendingSuggestions)
        
        // Add smart completions
        let smartSuggestions = generateSmartCompletions(for: query)
            .filter { !suggestions.contains($0) }
            .prefix(3)
        suggestions.append(contentsOf: smartSuggestions)
        
        return Array(suggestions.prefix(8))
    }
    
    private static func generateSmartCompletions(for query: String) -> [String] {
        var completions: [String] = []
        
        // Handle hashtag completions
        if query.starts(with: "#") {
            let tag = String(query.dropFirst())
            completions.append(contentsOf: [
                "#\(tag)art",
                "#\(tag)news",
                "#\(tag)today",
                "#\(tag)tech"
            ].filter { $0.count > query.count })
        }
        
        // Handle handle completions
        else if query.starts(with: "@") {
            // Would typically connect to user suggestion API
            completions.append(contentsOf: [
                "\(query).bsky.social"
            ])
        }
        
        // Handle general query expansions
        else if !query.isEmpty {
            completions.append(contentsOf: [
                "\(query) news",
                "\(query) today",
                "\(query) discussion",
                "latest \(query)"
            ])
        }
        
        return completions
    }
}

// MARK: - Search Utilities

/// Utility methods for search functionality
enum SearchUtilities {
    /// Determine if a string is a handle (@username)
    static func isHandle(_ query: String) -> Bool {
        return query.starts(with: "@") && !query.contains(" ")
    }
    
    /// Determine if a string is a hashtag (#topic)
    static func isHashtag(_ query: String) -> Bool {
        return query.starts(with: "#") && !query.contains(" ")
    }
    
    /// Determine if a string looks like a URL
    static func isURL(_ query: String) -> Bool {
        return query.contains("://") || query.starts(with: "www.")
    }
    
    /// Extract hashtags from text
    static func extractHashtags(from text: String) -> [String] {
        let pattern = #"#(\w+)"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(text.startIndex..., in: text)
        
        return regex?.matches(in: text, options: [], range: range)
            .compactMap { match in
                guard let range = Range(match.range(at: 1), in: text) else { return nil }
                return String(text[range])
            } ?? []
    }
    
    /// Extract mentions from text
    static func extractMentions(from text: String) -> [String] {
        let pattern = #"@(\w+(?:\.\w+)*)"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(text.startIndex..., in: text)
        
        return regex?.matches(in: text, options: [], range: range)
            .compactMap { match in
                guard let range = Range(match.range(at: 1), in: text) else { return nil }
                return String(text[range])
            } ?? []
    }
    
    /// Format a query for appropriate search endpoints
    static func formatQuery(_ query: String) -> String {
        var formatted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove @ for handle searches
        if isHandle(formatted) {
            formatted = String(formatted.dropFirst())
        }
        
        return formatted
    }
    
    /// Sanitize query for safe API usage
    static func sanitizeQuery(_ query: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "@#._-"))
        
        return query.components(separatedBy: allowedCharacters.inverted)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// Tagged suggestion category
struct SuggestionCategory: Identifiable {
    var id: String { tag }
    let tag: String
    let items: [TaggedSuggestionItem]
    
    init(tag: String, items: [AppBskyUnspeccedGetTaggedSuggestions.Suggestion]) {
        self.tag = tag
        self.items = items.map { TaggedSuggestionItem(from: $0) }
    }
}

// Individual tagged suggestion item
struct TaggedSuggestionItem: Identifiable {
    var id: String { subject }
    let subjectType: String
    let subject: String
    
    init(from suggestion: AppBskyUnspeccedGetTaggedSuggestions.Suggestion) {
        self.subjectType = suggestion.subjectType
        self.subject = suggestion.subject.uriString()
    }
}
