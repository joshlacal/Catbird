//
//  RefinedSearchViewModel.swift
//  Catbird
//
//  Created on 3/9/25.
//

import OSLog
import Observation
import Petrel
import SwiftUI

/// Enum representing the search state
enum SearchState {
  case idle  // Discovery view (initial state)
  case searching  // Typeahead view (search in progress)
  case results  // Results view (search completed)
  case loading  // Loading view (intermediate state)
}

/// ViewModel for the refined search experience
@MainActor
@Observable class RefinedSearchViewModel: StateInvalidationSubscriber {
  // MARK: - Search State
  var searchState: SearchState = .idle
  var searchQuery: String = ""
  var isCommittedSearch: Bool = false
  var isLoadingMoreResults: Bool = false

  // MARK: - Filtering
  var selectedContentType: ContentType = .all
  /// Single source of truth for applied post-search filters (sort/date/language).
  var filterState = SearchFilterState()

  // MARK: - Results
  var profileResults: [AppBskyActorDefs.ProfileView] = []
  var postResults: [AppBskyFeedDefs.PostView] = []
  var feedResults: [AppBskyFeedDefs.GeneratorView] = []
  var starterPackResults: [AppBskyGraphDefs.StarterPackViewBasic] = []

  // MARK: - Error State
  var searchError: Error?

  // MARK: - Discovery Content
  var recentSearches: [String] = []
  var recentProfileSearches: [RecentProfileSearch] = []
  var trendingTopics: [AppBskyUnspeccedDefs.TrendView] = []
  var suggestedProfiles: [AppBskyActorDefs.ProfileView] = []
  var taggedSuggestions: [TaggedSuggestion] = []

  // MARK: - Typeahead Results
  var typeaheadProfiles: [AppBskyActorDefs.ProfileViewBasic] = []
  var typeaheadSuggestions: [String] = []

  // MARK: - Pagination
  var profileCursor: String?
  var postCursor: String?
  var feedCursor: String?
  var starterPackCursor: String?

  // MARK: - Saved Searches
  var savedSearches: [SavedSearch] = []

  // MARK: - Dependencies
  private let appState: AppState
  private let searchHistoryManager = SearchHistoryManager()
  private let logger = Logger(subsystem: "blue.catbird", category: "RefinedSearchViewModel")

  // Content filtering service for search results
  private let contentFilterService = ContentFilterService()

  // MARK: - Debouncing
  private var searchTask: Task<Void, Never>?
  private var searchExecutionTask: Task<Void, Never>?
  private var requestGeneration = SearchRequestGeneration()
  private var activeSearchRequest: SearchRequestSnapshot?
  private let searchDebounceTime: TimeInterval = 0.15  // SRCH-006: Reduced from 300ms to 150ms for better responsiveness

  // MARK: - Computed Properties

  /// Whether there are any search results
  var hasNoResults: Bool {
    return profileResults.isEmpty && postResults.isEmpty && feedResults.isEmpty
      && starterPackResults.isEmpty
  }

  /// Whether there are multiple types of results
  var hasMultipleResultTypes: Bool {
    let count = [
      !profileResults.isEmpty,
      !postResults.isEmpty,
      !feedResults.isEmpty,
      !starterPackResults.isEmpty,
    ].filter { $0 }.count

    return count > 1
  }

  /// All typeahead results count combined
  var typeaheadResultsCount: Int {
    return typeaheadProfiles.count + typeaheadSuggestions.count
  }

  // MARK: - Initialization

  init(appState: AppState) {
    self.appState = appState

    // Load recent searches from UserDefaults
    loadRecentSearches()
    loadRecentProfileSearches()
    loadSavedSearches()

    // Don't subscribe immediately - wait until view appears
  }

  /// Track subscription state to avoid double subscription
  private var isSubscribed = false

  /// Subscribe to state invalidation events when view becomes active
  func subscribeToEvents() {
    guard !isSubscribed else { return }
    appState.stateInvalidationBus.subscribe(self)
    isSubscribed = true
    logger.debug("RefinedSearchViewModel subscribed to state invalidation bus")
  }

  /// Unsubscribe from state invalidation events when view becomes inactive
  func unsubscribeFromEvents() {
    guard isSubscribed else { return }
    appState.stateInvalidationBus.unsubscribe(self)
    isSubscribed = false
    logger.debug("RefinedSearchViewModel unsubscribed from state invalidation bus")
  }

  // Note: We intentionally avoid doing work in deinit due to actor isolation.

  // MARK: - Public Methods

  /// Initialize data for discovery view
  func initialize(client: ATProtoClient) {
    Task {
      await refreshDiscoveryContent(client: client)
    }
  }

  /// Update search based on query
  func updateSearch(query: String, client: ATProtoClient) {
    if query != searchQuery {
      invalidateSearchRequests(resetCursors: true)
    }
    searchQuery = query

    // Cancel previous search task
    searchTask?.cancel()

    if query.isEmpty {
      // Reset to idle state when query is empty
      searchState = .idle
      typeaheadProfiles = []
      typeaheadSuggestions = []
      isCommittedSearch = false
      return
    }

    // Update search state immediately for UI responsiveness
    if searchState == .idle || searchState == .results {
      searchState = .searching
    }

    isCommittedSearch = false

    // Generate enhanced suggestions with history and trending (immediate)
    let trendingTerms = trendingTopics.map { $0.topic ?? "" }.filter { !$0.isEmpty }
    typeaheadSuggestions = SearchSuggestion.generateSuggestions(
      for: query,
      history: recentSearches,
      trending: trendingTerms
    )

    // Debounced network search
    searchTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(searchDebounceTime))

      // Check if task was cancelled during sleep
      guard !Task.isCancelled else { return }

      await fetchTypeahead(query: query, client: client)
    }
  }

  /// Commit search with current query
  func commitSearch(client: ATProtoClient) {
    logger.debug(
      "commitSearch called with query: '\(self.searchQuery)', selectedContentType: \(self.selectedContentType.title)"
    )

    guard !searchQuery.isEmpty else {
      logger.warning("commitSearch aborted - empty search query")
      return
    }

    logger.debug("commitSearch proceeding - setting state to loading")

    // Save to recent searches
    saveRecentSearch(searchQuery)

    // Update state
    searchState = .loading
    isCommittedSearch = true

    logger.debug(
      "Search state updated to: \(String(describing: self.searchState)), isCommittedSearch: \(self.isCommittedSearch)"
    )

    // Clear existing results
    profileResults = []
    postResults = []
    feedResults = []
    starterPackResults = []

    logger.debug(
      "Results cleared, executing search task for content type: \(self.selectedContentType.title)")

    scheduleSearch(client: client)
  }

  /// Reset search to initial state
  func resetSearch() {
    invalidateSearchRequests(resetCursors: true)
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
    typeaheadSuggestions = []

  }

  /// Refresh current search with latest data
  /// Refresh current search with latest data
  /// Refresh current search with latest data
  func refreshSearch(client: ATProtoClient) async {
    if isCommittedSearch {
      let request = beginSearchRequest()
      // Important: Don't clear results until we have new ones

      // Reset cursors for pagination
      var newProfileCursor: String?
      var newPostCursor: String?
      var newFeedCursor: String?
      let newStarterPackCursor: String? = nil

      // Create temporary arrays to store new results
      var newProfileResults: [AppBskyActorDefs.ProfileView] = []
      var newPostResults: [AppBskyFeedDefs.PostView] = []
      var newFeedResults: [AppBskyFeedDefs.GeneratorView] = []

      // Execute search to get new results
      do {
        // Create a task group with a manual task cancelation check
        try await withThrowingTaskGroup(of: Void.self) { group in
          // Search profiles
          group.addTask {
            do {
              let input = AppBskyActorSearchActors.Parameters(
                term: request.query, limit: 25
              )

              let (_, response) = try await client.app.bsky.actor.searchActors(input: input)

              if let actorsResponse = response {
                newProfileResults = actorsResponse.actors
                newProfileCursor = actorsResponse.cursor
              }
            } catch {
              // Log but don't rethrow so other tasks can continue
              Task { @MainActor in
                self.logger.error("Profile search error: \(error.localizedDescription)")
              }
            }
          }

          // Search posts (similar pattern for other searches)
          group.addTask {
            do {
              let input = await self.buildPostSearchParameters(request: request, cursor: nil)

              let (_, response) = try await client.app.bsky.feed.searchPosts(input: input)

              if let postsResponse = response {
                newPostResults = postsResponse.posts
                newPostCursor = postsResponse.cursor
              }
            } catch {
              Task { @MainActor in
                self.logger.error("Post search error: \(error.localizedDescription)")
              }
            }
          }

          // Search feeds
          group.addTask {
            do {
              let input = AppBskyUnspeccedGetPopularFeedGenerators.Parameters(
                limit: 25,
                query: request.query
              )

              let (_, response) = try await client.app.bsky.unspecced.getPopularFeedGenerators(
                input: input)

              if let feedsResponse = response {
                newFeedResults = feedsResponse.feeds
                newFeedCursor = feedsResponse.cursor
              }
            } catch {
              Task { @MainActor in
                self.logger.error("Feed search error: \(error.localizedDescription)")
              }
            }
          }

          // Wait for all tasks
          for try await _ in group {}
        }

        guard requestGeneration.accepts(request), !Task.isCancelled else { return }

        // Only update UI with new results if any were successfully fetched
        let hasNewResults =
          !newProfileResults.isEmpty || !newPostResults.isEmpty || !newFeedResults.isEmpty

        if hasNewResults {
          // Apply content filtering to post results
          var filteredPostResults = newPostResults
          if !newPostResults.isEmpty {
            let filterSettings = await appState.buildFilterSettings()
            filteredPostResults = await contentFilterService.filterPostViews(
              newPostResults, settings: filterSettings)
            logger.debug(
              "Applied content filtering to initial search results: \(filteredPostResults.count) posts after filtering"
            )
          }

          // Update the results and cursors
          let profileResults = newProfileResults.isEmpty ? self.profileResults : newProfileResults
          let postResults =
            filteredPostResults.isEmpty && self.postResults.isEmpty
            ? [] : (filteredPostResults.isEmpty ? self.postResults : filteredPostResults)
          let feedResults = newFeedResults.isEmpty ? self.feedResults : newFeedResults

          guard requestGeneration.accepts(request), !Task.isCancelled else { return }
          self.profileResults = profileResults
          self.postResults = postResults
          self.feedResults = feedResults

          self.profileCursor = newProfileCursor
          self.postCursor = newPostCursor
          self.feedCursor = newFeedCursor
          self.starterPackCursor = newStarterPackCursor

          self.searchState = .results
        }
      } catch {
        // Keep existing results on error
        logger.error("Error refreshing search: \(error.localizedDescription)")
      }
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
    await fetchTaggedSuggestions(client: client)
  }

  /// Apply a new filter state (date/language) and re-run the committed search.
  func applyFilterState(_ state: SearchFilterState, client: ATProtoClient) {
    filterState = state
    if isCommittedSearch {
      scheduleSearch(client: client)
    }
  }

  /// Change the sort mode and re-run the committed search.
  func setSort(_ sort: SearchSort, client: ATProtoClient) {
    filterState.sort = sort
    if isCommittedSearch {
      scheduleSearch(client: client)
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

    // Save to UserDefaults with account-specific key
    let key = recentSearchesKey()
    UserDefaults(suiteName: "group.blue.catbird.shared")?.set(recentSearches, forKey: key)
  }

  /// Clear all recent searches for current account
  func clearRecentSearches() {
    recentSearches = []
    let key = recentSearchesKey()
    UserDefaults(suiteName: "group.blue.catbird.shared")?.removeObject(forKey: key)
  }

  /// SRCH-008: Delete a specific recent search
  func deleteRecentSearch(_ search: String) {
    recentSearches.removeAll { $0 == search }
    saveRecentSearches()
  }

  /// Save recent searches to UserDefaults
  private func saveRecentSearches() {
    let key = recentSearchesKey()
    UserDefaults(suiteName: "group.blue.catbird.shared")?.set(recentSearches, forKey: key)
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

    // Save to UserDefaults with account-specific key
    let key = recentProfileSearchesKey()
    if let encoded = try? JSONEncoder().encode(recentProfileSearches) {
      UserDefaults(suiteName: "group.blue.catbird.shared")?.set(encoded, forKey: key)
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

    // Save to UserDefaults with account-specific key
    let key = recentProfileSearchesKey()
    if let encoded = try? JSONEncoder().encode(recentProfileSearches) {
      UserDefaults(suiteName: "group.blue.catbird.shared")?.set(encoded, forKey: key)
    }
  }

  /// Clear all recent profile searches for current account
  func clearRecentProfileSearches() {
    recentProfileSearches = []
    let key = recentProfileSearchesKey()
    UserDefaults(suiteName: "group.blue.catbird.shared")?.removeObject(forKey: key)
  }

  // MARK: - Saved Searches Management

  /// Save current search with filters for later use
  func saveCurrentSearch(name: String) {
    let savedSearch = SavedSearch(
      name: name,
      query: searchQuery,
      filters: filterState
    )

    let userDID = AppStateManager.shared.authentication.state.userDID
    searchHistoryManager.saveSearch(savedSearch, userDID: userDID)
    loadSavedSearches()
  }

  /// Delete a saved search
  func deleteSavedSearch(_ id: UUID) {
    let userDID = AppStateManager.shared.authentication.state.userDID
    searchHistoryManager.deleteSavedSearch(id, userDID: userDID)
    loadSavedSearches()
  }

  /// Load saved searches for current user
  private func loadSavedSearches() {
    let userDID = AppStateManager.shared.authentication.state.userDID
    savedSearches = searchHistoryManager.loadSavedSearches(for: userDID)
  }

  // MARK: - Private Methods

  /// Load recent searches from UserDefaults for current account
  private func loadRecentSearches() {
    let key = recentSearchesKey()
    if let searches = UserDefaults(suiteName: "group.blue.catbird.shared")?.array(forKey: key) as? [String]
    {
      recentSearches = searches
    } else {
      recentSearches = []
    }
  }

  /// Load recent profile searches from UserDefaults for current account
  private func loadRecentProfileSearches() {
    let key = recentProfileSearchesKey()
    if let data = UserDefaults(suiteName: "group.blue.catbird.shared")?.data(forKey: key),
      let decoded = try? JSONDecoder().decode([RecentProfileSearch].self, from: data)
    {
      recentProfileSearches = decoded
    } else {
      recentProfileSearches = []
    }
  }

  /// Generate account-specific key for recent searches
  private func recentSearchesKey() -> String {
    if let userDID = AppStateManager.shared.authentication.state.userDID {
      return "recentSearches_\(userDID)"
    }
    return "recentSearches_default"
  }

  /// Generate account-specific key for recent profile searches
  private func recentProfileSearchesKey() -> String {
    if let userDID = AppStateManager.shared.authentication.state.userDID {
      return "recentProfileSearches_\(userDID)"
    }
    return "recentProfileSearches_default"
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

      // No feed typeahead; keep profiles-only

    } catch {
      logger.error("Error fetching typeahead: \(error.localizedDescription)")
    }
  }

  private func resetPaginationCursors() {
    profileCursor = nil
    postCursor = nil
    feedCursor = nil
    starterPackCursor = nil
  }

  private func invalidateSearchRequests(resetCursors: Bool) {
    searchExecutionTask?.cancel()
    searchExecutionTask = nil
    requestGeneration.invalidate()
    activeSearchRequest = nil
    if resetCursors { resetPaginationCursors() }
  }

  private func beginSearchRequest() -> SearchRequestSnapshot {
    searchExecutionTask?.cancel()
    let request = requestGeneration.begin(query: searchQuery, filters: filterState)
    activeSearchRequest = request
    resetPaginationCursors()
    return request
  }

  private func scheduleSearch(client: ATProtoClient) {
    let request = beginSearchRequest()
    searchExecutionTask = Task { [weak self] in
      guard let self else { return }
      await self.executeSearch(client: client, request: request)
    }
  }

  /// Execute search with an immutable query/filter snapshot.
  private func executeSearch(client: ATProtoClient, request: SearchRequestSnapshot) async {
    logger.debug(
      "executeSearch started with query: '\(request.query)', selectedContentType: \(self.selectedContentType.title)"
    )

    // If query is empty, reset to idle state
    guard !request.query.isEmpty else {
      logger.warning("executeSearch aborted - empty search query")
      if requestGeneration.accepts(request) { searchState = .idle }
      return
    }

    guard requestGeneration.accepts(request), !Task.isCancelled else { return }

    // Clear previous error
    searchError = nil

    logger.debug("executeSearch proceeding with parallel task group")

    do {
      // Create task group to run searches in parallel
      await withTaskGroup(of: Void.self) { group in
        // Search profiles
        group.addTask {
          await self.searchProfiles(client: client, request: request, cursor: nil)
        }

        // Search posts
        group.addTask {
          await self.searchPosts(client: client, request: request, cursor: nil)
        }

        // Search feeds
        group.addTask {
          await self.searchFeeds(client: client, request: request)
        }

        // Search starter packs
        //                group.addTask {
        //                    await self.searchStarterPacks(client: client)
        //                }

        // Wait for all searches to complete
        for await _ in group {}
      }

      guard requestGeneration.accepts(request), !Task.isCancelled else { return }
      // Update state
      logger.debug("executeSearch completed successfully, setting state to results")
      searchState = .results

    } catch {
      guard requestGeneration.accepts(request), !Task.isCancelled else { return }
      logger.error("Error executing search: \(error.localizedDescription)")
      searchError = error
      searchState = .results  // Still move to results state to show error
    }

    logger.debug("executeSearch finished with state: \(String(describing: self.searchState))")
  }

  /// Search for profiles matching the query
  private func searchProfiles(
    client: ATProtoClient,
    request: SearchRequestSnapshot,
    cursor: String?
  ) async {
    do {
      let input = AppBskyActorSearchActors.Parameters(
        term: request.query, limit: 25,
        cursor: cursor
      )

      let (_, response) = try await client.app.bsky.actor.searchActors(input: input)

      guard requestGeneration.accepts(request), !Task.isCancelled else { return }
      if let actorsResponse = response {
        profileResults = actorsResponse.actors
        profileCursor = actorsResponse.cursor
      }
    } catch {
      guard requestGeneration.accepts(request), !Task.isCancelled else { return }
      logger.error("Error searching profiles: \(error.localizedDescription)")
      profileResults = []
    }
  }

  /// Build real searchPosts parameters from the applied filter state.
  private func buildPostSearchParameters(
    request: SearchRequestSnapshot,
    cursor: String?
  ) -> AppBskyFeedSearchPosts.Parameters {
    let enhancedQuery = enhanceQueryForSpecialTypes(request.query)
    let bounds = request.filters.dateBounds()
    return AppBskyFeedSearchPosts.Parameters(
      q: enhancedQuery,
      sort: request.filters.sortValue,
      since: bounds.since,
      until: bounds.until,
      lang: request.filters.languageContainer,
      limit: 25,
      cursor: cursor
    )
  }

  /// Search for posts matching the query with current filters applied.
  private func searchPosts(
    client: ATProtoClient,
    request: SearchRequestSnapshot,
    cursor: String?
  ) async {
    do {
      let input = buildPostSearchParameters(request: request, cursor: cursor)
      let (_, response) = try await client.app.bsky.feed.searchPosts(input: input)

      if let postsResponse = response {
        var results = postsResponse.posts

        // Trust server ordering (top/latest). An explicit per-search language
        // bypasses the global preferred-language filter so the requested
        // language is not stripped client-side.
        if request.filters.language == nil
          && appState.appSettings.hideNonPreferredLanguages
          && !appState.appSettings.contentLanguages.isEmpty
        {
          results = applyLanguageFiltering(to: results)
        }

        // Apply content filtering (blocked/muted users, content labels, etc.)
        let filterSettings = await appState.buildFilterSettings()
        results = await contentFilterService.filterPostViews(results, settings: filterSettings)
        logger.debug(
          "Applied content filtering to search results: \(results.count) posts after filtering")

        guard requestGeneration.accepts(request), !Task.isCancelled else { return }
        postResults = results
        postCursor = postsResponse.cursor
      }
    } catch {
      guard requestGeneration.accepts(request), !Task.isCancelled else { return }
      logger.error("Error searching posts: \(error.localizedDescription)")
      postResults = []
    }
  }

  /// Enhance query for hashtags, mentions, and special search types
  private func enhanceQueryForSpecialTypes(_ query: String) -> String {
    var enhancedQuery = query

    // Handle hashtag searches
    if SearchUtilities.isHashtag(query) {
      // For hashtag searches, also search for the tag without #
      let tagWithoutHash = String(query.dropFirst())
      enhancedQuery = "\(query) OR #\(tagWithoutHash) OR \(tagWithoutHash)"
    }

    // Handle mention searches
    else if SearchUtilities.isHandle(query) {
      // For handle searches, search for both @handle and handle
      let handleWithoutAt = String(query.dropFirst())
      enhancedQuery = "\(query) OR @\(handleWithoutAt) OR \(handleWithoutAt)"
    }

    // Handle URL searches
    else if SearchUtilities.isURL(query) {
      enhancedQuery = "url:\(query)"
    }

    return enhancedQuery
  }

  /// Search for feeds matching the query
  private func searchFeeds(client: ATProtoClient, request: SearchRequestSnapshot) async {
    do {
      let input = AppBskyUnspeccedGetPopularFeedGenerators.Parameters(
        limit: 25,
        query: request.query
      )

      let (_, response) = try await client.app.bsky.unspecced.getPopularFeedGenerators(input: input)

      guard requestGeneration.accepts(request), !Task.isCancelled else { return }
      if let feedsResponse = response {
        feedResults = feedsResponse.feeds
      }
    } catch {
      guard requestGeneration.accepts(request), !Task.isCancelled else { return }
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
    guard let request = activeSearchRequest,
          requestGeneration.accepts(request),
          request.query == searchQuery,
          request.filters == filterState,
          let cursor = profileCursor
    else { return }

    do {
      let input = AppBskyActorSearchActors.Parameters(
        term: request.query, limit: 25,
        cursor: cursor
      )

      let (_, response) = try await client.app.bsky.actor.searchActors(input: input)

      guard requestGeneration.accepts(request), !Task.isCancelled else { return }
      if let actorsResponse = response {
        // Deduplicate by DID when appending
        let existing = Set(profileResults.map { $0.did.didString() })
        let newOnes = actorsResponse.actors.filter { !existing.contains($0.did.didString()) }
        profileResults.append(contentsOf: newOnes)
        profileCursor = actorsResponse.cursor
      }
    } catch {
      logger.error("Error loading more profiles: \(error.localizedDescription)")
    }
  }

  /// Load more posts for pagination
  private func loadMorePosts(client: ATProtoClient) async {
    guard let request = activeSearchRequest,
          requestGeneration.accepts(request),
          request.query == searchQuery,
          request.filters == filterState,
          let cursor = postCursor
    else { return }

    do {
      let input = buildPostSearchParameters(request: request, cursor: cursor)

      let (_, response) = try await client.app.bsky.feed.searchPosts(input: input)

      guard requestGeneration.accepts(request), !Task.isCancelled else { return }
      if let postsResponse = response {
        // Deduplicate by URI when appending
        let existing = Set(postResults.map { $0.uri.uriString() })
        let newOnes = postsResponse.posts.filter { !existing.contains($0.uri.uriString()) }
        postResults.append(contentsOf: newOnes)
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
      let input = AppBskyUnspeccedGetTrends.Parameters(limit: 10)

      let (_, response) = try await client.app.bsky.unspecced.getTrends(input: input)

      if let topicsResponse = response {
        trendingTopics = topicsResponse.trends
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
  func fetchTaggedSuggestions(client: ATProtoClient) async {
    do {
      taggedSuggestions = try await TaggedSuggestionsSection.fetchTaggedSuggestions(client: client)
    } catch {
      logger.error("Error fetching tagged suggestions: \(error.localizedDescription)")
    }
  }

  // MARK: - Helper Methods

  /// Apply language filtering to search results
  private func applyLanguageFiltering(to posts: [AppBskyFeedDefs.PostView]) -> [AppBskyFeedDefs
    .PostView]
  {
    let preferredLanguages = appState.appSettings.contentLanguages
    var filteredPosts: [AppBskyFeedDefs.PostView] = []

    for post in posts {
      // Extract post record to check languages
      guard case .knownType(let record) = post.record,
        let feedPost = record as? AppBskyFeedPost
      else {
        // If we can't decode the post, allow it through
        filteredPosts.append(post)
        continue
      }

      // If post has no language tags, allow it through
      guard let postLanguages = feedPost.langs, !postLanguages.isEmpty else {
        filteredPosts.append(post)
        continue
      }

      // Check if any of the post's languages match user's preferred languages
      let hasPreferredLanguage = postLanguages.contains { postLangContainer in
        preferredLanguages.contains { prefLang in
          // Compare language codes (e.g., "en" == "en")
          let postLangCode =
            postLangContainer.lang.languageCode?.identifier
            ?? postLangContainer.lang.minimalIdentifier
          return postLangCode == prefLang
        }
      }

      if hasPreferredLanguage {
        filteredPosts.append(post)
      }
    }

    return filteredPosts
  }

  // MARK: - StateInvalidationSubscriber

  /// Check if SearchViewModel is interested in a specific state invalidation event
  func isInterestedIn(_ event: StateInvalidationEvent) -> Bool {
    switch event {
    case .accountSwitched:
      return true
    default:
      return false  // SearchViewModel only cares about account switches
    }
  }

  /// Handle state invalidation events
  func handleStateInvalidation(_ event: StateInvalidationEvent) async {
    switch event {
    case .accountSwitched:
      // Reload search history for the new account
      await MainActor.run {
        loadRecentSearches()
        loadRecentProfileSearches()
      }
    default:
      break
    }
  }

  // MARK: - Saved Search Operations

  /// Save a search configuration for later use
  func saveSearch(_ savedSearch: SavedSearch) {
    let userDID = appState.userDID
    searchHistoryManager.saveSearch(savedSearch, userDID: userDID)
    loadSavedSearches()
  }

  /// Load and apply a saved search configuration
  func loadAndApplySavedSearch(
    _ savedSearch: SavedSearch,
    client: ATProtoClient,
    onQueryLoaded: (String) -> Void
  ) {
    // Apply the saved search parameters
    searchQuery = savedSearch.query
    filterState = savedSearch.filters
    onQueryLoaded(savedSearch.query)

    // Update the last used timestamp
    searchHistoryManager.updateLastUsed(savedSearch.id, userDID: appState.userDID)

    // Run the full committed search after all saved state is loaded.
    commitSearch(client: client)
  }
}
