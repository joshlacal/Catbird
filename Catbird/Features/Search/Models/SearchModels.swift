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
    
    /// Format a query for appropriate search endpoints
    static func formatQuery(_ query: String) -> String {
        var formatted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove @ for handle searches
        if isHandle(formatted) {
            formatted = String(formatted.dropFirst())
        }
        
        return formatted
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

