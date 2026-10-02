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

/// Model for structured search history persistence with filter state (G05).
public struct RecentSearchEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let query: String
    public let filters: SearchFilterState
    public let timestamp: Date
    
    public init(
        id: UUID = UUID(),
        query: String,
        filters: SearchFilterState = SearchFilterState(),
        timestamp: Date = Date()
    ) {
        self.id = id
        self.query = query
        self.filters = filters
        self.timestamp = timestamp
    }
}

/// Model for saved searches
public struct SavedSearch: Codable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let query: String
    public let filters: SearchFilterState
    public let createdAt: Date
    public var lastUsed: Date
    
    public init(name: String, query: String, filters: SearchFilterState) {
        self.id = UUID()
        self.name = name
        self.query = query
        self.filters = filters
        self.createdAt = Date()
        self.lastUsed = Date()
    }
    
    public func withUpdatedLastUsed() -> SavedSearch {
        var copy = self
        copy.lastUsed = Date()
        return copy
    }
    
    private init(id: UUID, name: String, query: String, filters: SearchFilterState, createdAt: Date, lastUsed: Date) {
        self.id = id
        self.name = name
        self.query = query
        self.filters = filters
        self.createdAt = createdAt
        self.lastUsed = lastUsed
    }
}

/// Enhanced search history manager supporting JSON-serialized entries with filter state and legacy migration (G05).
public final class SearchHistoryManager: @unchecked Sendable {
    private let userDefaults = UserDefaults(suiteName: "group.blue.catbird.shared")
    private let maxHistoryItems = 20
    private let maxSavedSearches = 20
    
    public init() {}
    
    /// Save a search query with its complete filter state to history.
    public func saveRecentSearch(query: String, filters: SearchFilterState, userDID: String?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        var history = loadRecentSearches(for: userDID)
        
        // Remove duplicate query + filter combination
        history.removeAll { $0.query == trimmed && $0.filters == filters }
        
        // Add to beginning
        let entry = RecentSearchEntry(query: trimmed, filters: filters, timestamp: Date())
        history.insert(entry, at: 0)
        
        if history.count > maxHistoryItems {
            history = Array(history.prefix(maxHistoryItems))
        }
        
        saveHistoryList(history, for: userDID)
    }
    
    /// Load recent search entries with filter state, migrating legacy [String] entries if present.
    public func loadRecentSearches(for userDID: String?) -> [RecentSearchEntry] {
        let jsonKey = historyJSONKey(for: userDID)
        
        // 1. Try decoding JSON entries
        if let data = userDefaults?.data(forKey: jsonKey),
           let history = try? JSONDecoder().decode([RecentSearchEntry].self, from: data) {
            return history
        }
        
        // 2. One-time migration from legacy [String] recentSearches_<DID>
        let legacyKey = legacyRecentSearchesKey(for: userDID)
        if let legacyStrings = userDefaults?.array(forKey: legacyKey) as? [String], !legacyStrings.isEmpty {
            let migrated = legacyStrings.map {
                RecentSearchEntry(query: $0, filters: SearchFilterState(), timestamp: Date())
            }
            if let encoded = try? JSONEncoder().encode(migrated) {
                userDefaults?.set(encoded, forKey: jsonKey)
                // Remove obsolete legacy key only after successful encode/save
                userDefaults?.removeObject(forKey: legacyKey)
            }
            return migrated
        }
        
        return []
    }
    
    /// Delete a specific recent search entry.
    public func deleteRecentSearch(_ id: UUID, userDID: String?) {
        var history = loadRecentSearches(for: userDID)
        history.removeAll { $0.id == id }
        saveHistoryList(history, for: userDID)
    }
    
    /// Clear all recent searches.
    public func clearRecentSearches(for userDID: String?) {
        let jsonKey = historyJSONKey(for: userDID)
        let legacyKey = legacyRecentSearchesKey(for: userDID)
        userDefaults?.removeObject(forKey: jsonKey)
        userDefaults?.removeObject(forKey: legacyKey)
    }
    
    private func saveHistoryList(_ history: [RecentSearchEntry], for userDID: String?) {
        let jsonKey = historyJSONKey(for: userDID)
        if let encoded = try? JSONEncoder().encode(history) {
            userDefaults?.set(encoded, forKey: jsonKey)
        }
    }
    
    public func historyJSONKey(for userDID: String?) -> String {
        if let userDID = userDID, !userDID.isEmpty {
            return "searchHistory_json_\(userDID)"
        }
        return "searchHistory_json_default"
    }
    
    public func legacyRecentSearchesKey(for userDID: String?) -> String {
        if let userDID = userDID, !userDID.isEmpty {
            return "recentSearches_\(userDID)"
        }
        return "recentSearches_default"
    }
    
    // MARK: - Saved Searches
    
    /// Save a search for later use
    public func saveSearch(_ savedSearch: SavedSearch, userDID: String?) {
        let key = savedSearchesKey(for: userDID)
        var savedSearches = loadSavedSearches(for: userDID)
        
        // Remove existing with same name
        savedSearches.removeAll { $0.name == savedSearch.name }
        
        // Add new search
        savedSearches.insert(savedSearch, at: 0)
        
        // Limit size
        if savedSearches.count > maxSavedSearches {
            savedSearches = Array(savedSearches.prefix(maxSavedSearches))
        }
        
        // Save to UserDefaults
        if let encoded = try? JSONEncoder().encode(savedSearches) {
            userDefaults?.set(encoded, forKey: key)
        }
    }
    
    /// Load saved searches
    public func loadSavedSearches(for userDID: String?) -> [SavedSearch] {
        let key = savedSearchesKey(for: userDID)
        guard let data = userDefaults?.data(forKey: key),
              let savedSearches = try? JSONDecoder().decode([SavedSearch].self, from: data) else {
            return []
        }
        return savedSearches.sorted { $0.lastUsed > $1.lastUsed }
    }
    
    /// Delete a saved search
    public func deleteSavedSearch(_ id: UUID, userDID: String?) {
        let key = savedSearchesKey(for: userDID)
        var savedSearches = loadSavedSearches(for: userDID)
        savedSearches.removeAll { $0.id == id }
        
        if let encoded = try? JSONEncoder().encode(savedSearches) {
            userDefaults?.set(encoded, forKey: key)
        }
    }
    
    /// Update last used time for a saved search
    public func updateLastUsed(_ id: UUID, userDID: String?) {
        let key = savedSearchesKey(for: userDID)
        var savedSearches = loadSavedSearches(for: userDID)
        
        if let index = savedSearches.firstIndex(where: { $0.id == id }) {
            savedSearches[index] = savedSearches[index].withUpdatedLastUsed()
            
            if let encoded = try? JSONEncoder().encode(savedSearches) {
                userDefaults?.set(encoded, forKey: key)
            }
        }
    }
    
    private func savedSearchesKey(for userDID: String?) -> String {
        if let userDID = userDID, !userDID.isEmpty {
            return "savedSearches_v2_\(userDID)"
        }
        return "savedSearches_v2_default"
    }
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
        
        return Array(suggestions.prefix(5))
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
