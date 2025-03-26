import Foundation

/// Additional search parameters for advanced filtering
struct AdvancedSearchParams: Equatable {
    // Original params from AdvancedFilterView
    var excludeReplies: Bool = false
    var excludeReposts: Bool = false
    var excludeMentions: Bool = false
    var excludedWords: [String] = []
    var onlyFromFollowing: Bool = false
    var onlyVerified: Bool = false
    var includeNSFW: Bool = false
    var includeFollowers: Bool = false
    var sortByLatest: Bool = true
    
    // Additional params from your new implementation
    var includeQuotes: Bool = true
    var mustHaveMedia: Bool = false
    var hasLinks: Bool = false
    
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
        
        // User filters
        if onlyFromFollowing {
            params["filter.following"] = "true"
        }
        
        // Sort options
        if !sortByLatest {
            params["sort"] = "relevance"
        }
        
        return params
    }
}
