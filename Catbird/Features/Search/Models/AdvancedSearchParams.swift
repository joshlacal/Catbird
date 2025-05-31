import Foundation

/// Advanced search parameters for comprehensive filtering and ranking
struct AdvancedSearchParams: Equatable, Codable {
    // Content Filtering
    var excludeReplies: Bool = false
    var excludeReposts: Bool = false
    var excludeMentions: Bool = false
    var excludedWords: [String] = []
    var includeQuotes: Bool = true
    var mustHaveMedia: Bool = false
    var hasLinks: Bool = false
    var minLikes: Int = 0
    var minReposts: Int = 0
    var minReplies: Int = 0
    
    // User Filtering
    var onlyFromFollowing: Bool = false
    var onlyVerified: Bool = false
    var includeNSFW: Bool = false
    var includeFollowers: Bool = false
    var minFollowerCount: Int = 0
    var excludeBlockedUsers: Bool = true
    var excludeMutedUsers: Bool = true
    
    // Date Filtering
    var dateRange: DateRange = .anytime
    var customStartDate: Date?
    var customEndDate: Date?
    
    // Language Filtering
    var languages: Set<String> = []
    var autoDetectLanguage: Bool = true
    
    // Ranking and Sorting
    var sortBy: SortOption = .latest
    var relevanceBoost: RelevanceBoost = .balanced
    var prioritizeRecent: Bool = false
    
    // Geographic Filtering
    var nearLocation: String?
    var radiusKm: Double = 50.0
    
    enum DateRange: String, CaseIterable, Identifiable, Codable {
        case anytime = "anytime"
        case today = "today"
        case week = "week"
        case month = "month"
        case year = "year"
        case custom = "custom"
        
        var id: String { rawValue }
        
        var displayName: String {
            switch self {
            case .anytime: return "Any time"
            case .today: return "Past 24 hours"
            case .week: return "Past week"
            case .month: return "Past month"
            case .year: return "Past year"
            case .custom: return "Custom range"
            }
        }
    }
    
    enum SortOption: String, CaseIterable, Identifiable, Codable {
        case latest = "latest"
        case relevance = "relevance"
        case popular = "popular"
        case engagement = "engagement"
        
        var id: String { rawValue }
        
        var displayName: String {
            switch self {
            case .latest: return "Latest"
            case .relevance: return "Most Relevant"
            case .popular: return "Most Popular"
            case .engagement: return "Most Engagement"
            }
        }
    }
    
    enum RelevanceBoost: String, CaseIterable, Identifiable, Codable {
        case minimal = "minimal"
        case balanced = "balanced"
        case aggressive = "aggressive"
        
        var id: String { rawValue }
        
        var displayName: String {
            switch self {
            case .minimal: return "Minimal Boost"
            case .balanced: return "Balanced"
            case .aggressive: return "Aggressive Boost"
            }
        }
    }
    
    // Legacy compatibility
    var sortByLatest: Bool {
        get { sortBy == .latest }
        set { sortBy = newValue ? .latest : .relevance }
    }
    
    func toQueryParameters() -> [String: String] {
        var params: [String: String] = [:]
        
        // Content filters
        if excludeReplies {
            params["filter.replies"] = "false"
        }
        
        if excludeReposts {
            params["filter.reposts"] = "false"
        }
        
        if !includeQuotes {
            params["quotes"] = "false"
        }
        
        if excludeReplies && excludeReposts {
            params["filter.type"] = "posts_with_media"
        }
        
        // Media filters
        if mustHaveMedia {
            params["has:media"] = "true"
        }
        
        if hasLinks {
            params["has:links"] = "true"
        }
        
        // Engagement filters
        if minLikes > 0 {
            params["min_likes"] = String(minLikes)
        }
        
        if minReposts > 0 {
            params["min_reposts"] = String(minReposts)
        }
        
        if minReplies > 0 {
            params["min_replies"] = String(minReplies)
        }
        
        // User filters
        if onlyFromFollowing {
            params["filter.following"] = "true"
        }
        
        if onlyVerified {
            params["filter.verified"] = "true"
        }
        
        if minFollowerCount > 0 {
            params["min_followers"] = String(minFollowerCount)
        }
        
        if excludeBlockedUsers {
            params["exclude.blocked"] = "true"
        }
        
        if excludeMutedUsers {
            params["exclude.muted"] = "true"
        }
        
        // Language filters
        if !languages.isEmpty {
            params["lang"] = languages.joined(separator: ",")
        }
        
        // Date filtering
        switch dateRange {
        case .today:
            params["since"] = formatDateFilter(daysAgo: 1)
        case .week:
            params["since"] = formatDateFilter(daysAgo: 7)
        case .month:
            params["since"] = formatDateFilter(daysAgo: 30)
        case .year:
            params["since"] = formatDateFilter(daysAgo: 365)
        case .custom:
            if let startDate = customStartDate {
                params["since"] = formatDate(startDate)
            }
            if let endDate = customEndDate {
                params["until"] = formatDate(endDate)
            }
        case .anytime:
            break
        }
        
        // Sort options
        switch sortBy {
        case .latest:
            params["sort"] = "latest"
        case .relevance:
            params["sort"] = "relevance"
        case .popular:
            params["sort"] = "popular"
        case .engagement:
            params["sort"] = "engagement"
        }
        
        // Relevance boost
        if relevanceBoost != .balanced {
            params["relevance_boost"] = relevanceBoost.rawValue
        }
        
        if prioritizeRecent {
            params["prioritize_recent"] = "true"
        }
        
        // Geographic filters
        if let location = nearLocation, !location.isEmpty {
            params["near"] = location
            params["radius_km"] = String(radiusKm)
        }
        
        // Excluded words
        if !excludedWords.isEmpty {
            params["exclude_words"] = excludedWords.joined(separator: ",")
        }
        
        return params
    }
    
    /// Format date filter for API queries
    private func formatDateFilter(daysAgo: Int) -> String {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: Date())!
        return formatDate(date)
    }
    
    /// Format date for ISO 8601 format
    private func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
