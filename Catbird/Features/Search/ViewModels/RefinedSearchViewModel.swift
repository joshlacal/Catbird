//
//  RefinedSearchViewModel.swift
//  Catbird
//
//  Created on 3/9/25.
//

import SwiftUI
import Petrel
import OSLog
import Observation

/// Enum representing the search state
enum SearchState {
    case idle        // Discovery view (initial state)
    case searching   // Typeahead view (search in progress)
    case results     // Results view (search completed)
    case loading     // Loading view (intermediate state)
}

/// ViewModel for the refined search experience
@Observable class RefinedSearchViewModel {
    // MARK: - Search State
    var searchState: SearchState = .idle
    var searchQuery: String = ""
    var isCommittedSearch: Bool = false
    var isLoadingMoreResults: Bool = false
    
    // MARK: - Filtering
    var selectedContentType: ContentType = .all
    var filterDate: FilterDate = .anytime
    var filterContentTypes: Set<ContentType> = []
    var filterLanguages: Set<String> = []
    var advancedParams = AdvancedSearchParams()
    
    // MARK: - Results
    var profileResults: [AppBskyActorDefs.ProfileView] = []
    var postResults: [AppBskyFeedDefs.PostView] = []
    var feedResults: [AppBskyFeedDefs.GeneratorView] = []
    var starterPackResults: [AppBskyGraphDefs.StarterPackViewBasic] = []
    
    // MARK: - Discovery Content
    var recentSearches: [String] = []
    var recentProfileSearches: [RecentProfileSearch] = []
    var trendingTopics: [AppBskyUnspeccedDefs.TrendingTopic] = []
    var suggestedProfiles: [AppBskyActorDefs.ProfileView] = []
//    var taggedSuggestions: [TaggedSuggestion] = []
    
    // MARK: - Typeahead Results
    var typeaheadProfiles: [AppBskyActorDefs.ProfileViewBasic] = []
    var typeaheadFeeds: [AppBskyFeedDefs.GeneratorView] = []
    var typeaheadSuggestions: [String] = []
    
    // MARK: - Pagination
    var profileCursor: String?
    var postCursor: String?
    var feedCursor: String?
    var starterPackCursor: String?
    
    // MARK: - Dependencies
    private let appState: AppState
    private let logger = Logger(subsystem: "blue.catbird", category: "RefinedSearchViewModel")
    
    // MARK: - Computed Properties
    
    /// Whether there are any search results
    var hasNoResults: Bool {
        return profileResults.isEmpty && 
               postResults.isEmpty && 
               feedResults.isEmpty && 
               starterPackResults.isEmpty
    }
    
    /// Whether there are multiple types of results
    var hasMultipleResultTypes: Bool {
        let count = [
            !profileResults.isEmpty,
            !postResults.isEmpty,
            !feedResults.isEmpty,
            !starterPackResults.isEmpty
        ].filter { $0 }.count
        
        return count > 1
    }
    
    /// All typeahead results count combined
    var typeaheadResultsCount: Int {
        return typeaheadProfiles.count + typeaheadFeeds.count + typeaheadSuggestions.count
    }
    
    // MARK: - Initialization
    
    init(appState: AppState) {
        self.appState = appState
        
        // Load recent searches from UserDefaults
        loadRecentSearches()
        loadRecentProfileSearches()
    }
    
    // MARK: - Public Methods
    
    /// Initialize data for discovery view
    func initialize(client: ATProtoClient) {
        Task {
            await refreshDiscoveryContent(client: client)
        }
    }
    
    /// Update search based on query
    func updateSearch(query: String, client: ATProtoClient) {
        searchQuery = query
        
        if query.isEmpty {
            // Reset to idle state when query is empty
            searchState = .idle
            typeaheadProfiles = []
            typeaheadFeeds = []
            typeaheadSuggestions = []
            isCommittedSearch = false
            return
        }
        
        // Update search state
        if searchState == .idle || searchState == .results {
            searchState = .searching
        }
        
        isCommittedSearch = false
        
        // Generate suggestions
        typeaheadSuggestions = SearchSuggestion.generateSuggestions(for: query)
        
        // Fetch typeahead results
        Task {
            await fetchTypeahead(query: query, client: client)
        }
    }
    
    /// Commit search with current query
    func commitSearch(client: ATProtoClient) {
        guard !searchQuery.isEmpty else { return }
        
        // Save to recent searches
        saveRecentSearch(searchQuery)
        
        // Update state
        searchState = .loading
        isCommittedSearch = true
        
        // Clear existing results
        profileResults = []
        postResults = []
        feedResults = []
        starterPackResults = []
        
        // Reset cursors
        profileCursor = nil
        postCursor = nil
        feedCursor = nil
        starterPackCursor = nil
        
        // Run search
        Task {
            await executeSearch(client: client)
        }
    }
    
    /// Reset search to initial state
    func resetSearch() {
        searchState = .idle
        searchQuery = ""
        isCommittedSearch = false
        
        // Clear results
        profileResults = []
        postResults = []
        feedResults = []
        starterPackResults = []
        
        // Reset typeahead
        typeaheadProfiles = []
        typeaheadFeeds = []
        typeaheadSuggestions = []
        
        // Reset cursors
        profileCursor = nil
        postCursor = nil
        feedCursor = nil
        starterPackCursor = nil
    }
    
    /// Refresh current search with latest data
    func refreshSearch(client: ATProtoClient) async {
        if isCommittedSearch {
            // Reset cursors
            profileCursor = nil
            postCursor = nil
            feedCursor = nil
            starterPackCursor = nil
            
            // Clear results
            profileResults = []
            postResults = []
            feedResults = []
            starterPackResults = []
            
            // Execute search again
            await executeSearch(client: client)
        } else if searchState == .idle {
            // Refresh discovery content
            await refreshDiscoveryContent(client: client)
        }
    }
    
    /// Refresh discovery content
    func refreshDiscoveryContent(client: ATProtoClient) async {
        // Fetch trending topics
        await fetchTrendingTopics(client: client)
        
        // Fetch suggested profiles
        await fetchSuggestedProfiles(client: client)
        
        // Fetch tagged suggestions
//        await fetchTaggedSuggestions(client: client)
    }
    
    /// Apply basic filters
    func applyFilters(
        date: FilterDate,
        contentTypes: Set<ContentType>,
        languages: Set<String>
    ) {
        filterDate = date
        filterContentTypes = contentTypes
        filterLanguages = languages
        
        // Re-run search with filters
        if isCommittedSearch {
            Task {
                if let client = appState.atProtoClient {
                    await executeSearch(client: client)
                }
            }
        }
    }
    
    /// Apply advanced filters
    func applyAdvancedFilters(_ params: AdvancedSearchParams) {
        advancedParams = params
        
        // Re-run search with filters
        if isCommittedSearch {
            Task {
                if let client = appState.atProtoClient {
                    await executeSearch(client: client)
                }
            }
        }
    }
    
    /// Load more results for the current content type
    func loadMoreResults(client: ATProtoClient) async {
        guard !isLoadingMoreResults else { return }
        
        isLoadingMoreResults = true
        defer { isLoadingMoreResults = false }
        
        switch selectedContentType {
        case .all:
            // Load more of all types
            await loadMoreProfiles(client: client)
            await loadMorePosts(client: client)
            await loadMoreFeeds(client: client)
//            await loadMoreStarterPacks(client: client)
            
        case .profiles:
            await loadMoreProfiles(client: client)
            
        case .posts:
            await loadMorePosts(client: client)
            
        case .feeds:
            await loadMoreFeeds(client: client)
            
//        case .starterPacks:
//            await loadMoreStarterPacks(client: client)
        }
    }
    
    /// Refresh suggested profiles
    func refreshSuggestedProfiles(client: ATProtoClient) async {
        await fetchSuggestedProfiles(client: client)
    }
    
    // MARK: - Recent Searches Management
    
    /// Save a search term to recent searches
    func saveRecentSearch(_ search: String) {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        // Remove if already exists
        if let index = recentSearches.firstIndex(of: trimmed) {
            recentSearches.remove(at: index)
        }
        
        // Add to beginning
        recentSearches.insert(trimmed, at: 0)
        
        // Limit to 10 items
        if recentSearches.count > 10 {
            recentSearches = Array(recentSearches.prefix(10))
        }
        
        // Save to UserDefaults
        UserDefaults.standard.set(recentSearches, forKey: "recentSearches")
    }
    
    /// Clear all recent searches
    func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: "recentSearches")
    }
    
    /// Add a profile to recent profile searches
    func addRecentProfileSearch(profile: AppBskyActorDefs.ProfileView) {
        let recentProfile = RecentProfileSearch(from: profile)
        
        // Remove if already exists
        if let index = recentProfileSearches.firstIndex(where: { $0.did == profile.did }) {
            recentProfileSearches.remove(at: index)
        }
        
        // Add to beginning
        recentProfileSearches.insert(recentProfile, at: 0)
        
        // Limit to 10 items
        if recentProfileSearches.count > 10 {
            recentProfileSearches = Array(recentProfileSearches.prefix(10))
        }
        
        // Save to UserDefaults
        if let encoded = try? JSONEncoder().encode(recentProfileSearches) {
            UserDefaults.standard.set(encoded, forKey: "recentProfileSearches")
        }
    }
    
    /// Add a ProfileViewBasic to recent profile searches
    func addRecentProfileSearchBasic(profile: AppBskyActorDefs.ProfileViewBasic) {
        // Create a simplified RecentProfileSearch directly from the basic profile
        let recentProfile = RecentProfileSearch(
            did: profile.did,
            handle: profile.handle,
            displayName: profile.displayName,
            avatarURL: profile.avatar?.uriString()
        )
        
        // Remove if already exists
        if let index = recentProfileSearches.firstIndex(where: { $0.did == profile.did }) {
            recentProfileSearches.remove(at: index)
        }
        
        // Add to beginning
        recentProfileSearches.insert(recentProfile, at: 0)
        
        // Limit to 10 items
        if recentProfileSearches.count > 10 {
            recentProfileSearches = Array(recentProfileSearches.prefix(10))
        }
        
        // Save to UserDefaults
        if let encoded = try? JSONEncoder().encode(recentProfileSearches) {
            UserDefaults.standard.set(encoded, forKey: "recentProfileSearches")
        }
    }
    
    /// Clear all recent profile searches
    func clearRecentProfileSearches() {
        recentProfileSearches = []
        UserDefaults.standard.removeObject(forKey: "recentProfileSearches")
    }
    
    // MARK: - Private Methods
    
    /// Load recent searches from UserDefaults
    private func loadRecentSearches() {
        if let searches = UserDefaults.standard.array(forKey: "recentSearches") as? [String] {
            recentSearches = searches
        }
    }
    
    /// Load recent profile searches from UserDefaults
    private func loadRecentProfileSearches() {
        if let data = UserDefaults.standard.data(forKey: "recentProfileSearches"),
           let decoded = try? JSONDecoder().decode([RecentProfileSearch].self, from: data) {
            recentProfileSearches = decoded
        }
    }
    
    /// Fetch typeahead search results
    private func fetchTypeahead(query: String, client: ATProtoClient) async {
        do {
            // Fetch profile typeahead
            let input = AppBskyActorSearchActorsTypeahead.Parameters(
                term: query,
                limit: 3
            )
            
            let (_, profileResponse) = try await client.app.bsky.actor.searchActorsTypeahead(input: input)
            
            if let profiles = profileResponse?.actors {
                typeaheadProfiles = profiles
            }
            
            // Generate feed suggestions later
            
        } catch {
            logger.error("Error fetching typeahead: \(error.localizedDescription)")
        }
    }
    
    /// Execute search with current query and filters
    private func executeSearch(client: ATProtoClient) async {
        // If query is empty, reset to idle state
        guard !searchQuery.isEmpty else {
            searchState = .idle
            return
        }
        
        do {
            // Create task group to run searches in parallel
            await withTaskGroup(of: Void.self) { group in
                // Search profiles
                group.addTask {
                    await self.searchProfiles(client: client)
                }
                
                // Search posts
                group.addTask {
                    await self.searchPosts(client: client)
                }
                
                // Search feeds
                group.addTask {
                    await self.searchFeeds(client: client)
                }
                
                // Search starter packs
//                group.addTask {
//                    await self.searchStarterPacks(client: client)
//                }
                
                // Wait for all searches to complete
                for await _ in group {}
            }
            
            // Update state
            searchState = .results
            
        } catch {
            logger.error("Error executing search: \(error.localizedDescription)")
            searchState = .results // Still move to results state to show empty results
        }
    }
    
    /// Search for profiles matching the query
    private func searchProfiles(client: ATProtoClient) async {
        do {
            let input = AppBskyActorSearchActors.Parameters(
                term: searchQuery, limit: 25,
                cursor: profileCursor
            )
            
            let (_, response) = try await client.app.bsky.actor.searchActors(input: input)
            
            if let actorsResponse = response {
                profileResults = actorsResponse.actors
                profileCursor = actorsResponse.cursor
            }
        } catch {
            logger.error("Error searching profiles: \(error.localizedDescription)")
            profileResults = []
        }
    }
    
    /// Search for posts matching the query
    private func searchPosts(client: ATProtoClient) async {
        do {
            // Prepare query parameters with filters
            var queryParams: [String: String] = [:]
            
            // Apply date filters
            switch filterDate {
            case .today:
                queryParams["since"] = formatDateFilter(daysAgo: 1)
            case .week:
                queryParams["since"] = formatDateFilter(daysAgo: 7)
            case .month:
                queryParams["since"] = formatDateFilter(daysAgo: 30)
            case .year:
                queryParams["since"] = formatDateFilter(daysAgo: 365)
            case .anytime:
                break // No date filter
            }
            
            // Add advanced filter parameters
            let advancedQueryParams = advancedParams.toQueryParameters()
            queryParams.merge(advancedQueryParams) { (_, new) in new }
            
            // Create input parameter
            let input = AppBskyFeedSearchPosts.Parameters(
                q: searchQuery,
                limit: 25,
                cursor: postCursor
            )
            
            // Execute search
            let (_, response) = try await client.app.bsky.feed.searchPosts(input: input)
            
            if let postsResponse = response {
                postResults = postsResponse.posts
                postCursor = postsResponse.cursor
            }
        } catch {
            logger.error("Error searching posts: \(error.localizedDescription)")
            postResults = []
        }
    }
    
    /// Search for feeds matching the query
    private func searchFeeds(client: ATProtoClient) async {
        do {
            let input = AppBskyUnspeccedGetPopularFeedGenerators.Parameters(
                limit: 25,
                query: searchQuery
            )
            
            let (_, response) = try await client.app.bsky.unspecced.getPopularFeedGenerators(input: input)
            
            if let feedsResponse = response {
                feedResults = feedsResponse.feeds
            }
        } catch {
            logger.error("Error searching feeds: \(error.localizedDescription)")
            feedResults = []
        }
    }
    
    /// Search for starter packs matching the query
//    private func searchStarterPacks(client: ATProtoClient) async {
//        do {
//            let input = AppBskyGraphSearchStarterPacks.Parameters(
//                q: searchQuery, limit: 25
//            )
//            
//            let (_, response) = try await client.app.bsky.graph.searchStarterPacks(input: input)
//            
//            if let packsResponse = response {
//                starterPackResults = packsResponse.starterPacks
//            }
//        } catch {
//            logger.error("Error searching starter packs: \(error.localizedDescription)")
//            starterPackResults = []
//        }
//    }
    
    /// Load more profiles for pagination
    private func loadMoreProfiles(client: ATProtoClient) async {
        guard let cursor = profileCursor else { return }
        
        do {
            let input = AppBskyActorSearchActors.Parameters(
                term: searchQuery, limit: 25,
                cursor: cursor
            )
            
            let (_, response) = try await client.app.bsky.actor.searchActors(input: input)
            
            if let actorsResponse = response {
                profileResults.append(contentsOf: actorsResponse.actors)
                profileCursor = actorsResponse.cursor
            }
        } catch {
            logger.error("Error loading more profiles: \(error.localizedDescription)")
        }
    }
    
    /// Load more posts for pagination
    private func loadMorePosts(client: ATProtoClient) async {
        guard let cursor = postCursor else { return }
        
        do {
            let input = AppBskyFeedSearchPosts.Parameters(
                q: searchQuery, limit: 25,
                cursor: cursor
            )
            
            let (_, response) = try await client.app.bsky.feed.searchPosts(input: input)
            
            if let postsResponse = response {
                postResults.append(contentsOf: postsResponse.posts)
                postCursor = postsResponse.cursor
            }
        } catch {
            logger.error("Error loading more posts: \(error.localizedDescription)")
        }
    }
    
    /// Load more feeds for pagination
    private func loadMoreFeeds(client: ATProtoClient) async {
        // Currently no pagination for feeds in the API
    }
    
    /// Load more starter packs for pagination
//    private func loadMoreStarterPacks(client: ATProtoClient) async {
//        // Currently no pagination for starter packs in the API
//    }
    
    /// Fetch trending topics for discovery view
    private func fetchTrendingTopics(client: ATProtoClient) async {
        do {
            let input = AppBskyUnspeccedGetTrendingTopics.Parameters()
            
            let (_, response) = try await client.app.bsky.unspecced.getTrendingTopics(input: input)
            
            if let topicsResponse = response {
                trendingTopics = topicsResponse.topics
            }
        } catch {
            logger.error("Error fetching trending topics: \(error.localizedDescription)")
        }
    }
    
    /// Fetch suggested profiles for discovery view
    private func fetchSuggestedProfiles(client: ATProtoClient) async {
        do {
            let input = AppBskyActorGetSuggestions.Parameters(limit: 10)
            
            let (_, response) = try await client.app.bsky.actor.getSuggestions(input: input)
            
            if let suggestionsResponse = response {
                suggestedProfiles = suggestionsResponse.actors
            }
        } catch {
            logger.error("Error fetching suggested profiles: \(error.localizedDescription)")
        }
    }
    
    /// Fetch tagged suggestions for discovery view
//    func fetchTaggedSuggestions(client: ATProtoClient) async {
//        do {
//            taggedSuggestions = try await TaggedSuggestionsSection.fetchTaggedSuggestions(client: client)
//        } catch {
//            logger.error("Error fetching tagged suggestions: \(error.localizedDescription)")
//        }
//    }
    
    // MARK: - Helper Methods
    
    /// Format date filter string for API
    private func formatDateFilter(daysAgo: Int) -> String {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: Date())!
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        
        return formatter.string(from: date)
    }
}
