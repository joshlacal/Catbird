//
//  RefinedSearchViewModel.swift
//  Catbird
//
//  Created on 3/9/25.
//  Updated for WS-A Search Parity (G01–G06).
//

import OSLog
import Observation
import Petrel
import SwiftUI

/// Enum representing the search state
public enum SearchState: Sendable {
  case idle       // Discovery view (initial state)
  case searching  // Typeahead view (search in progress)
  case results    // Results view (search completed)
  case loading    // Loading view (intermediate state)
}

/// Response classification for search HTTP responses.
public enum SearchHTTPResponseClassification: Equatable, Sendable {
  case success
  case invalidResponse(statusCode: Int)

  public static func classify<T>(statusCode: Int, payload: T?) -> SearchHTTPResponseClassification {
    if (200...299).contains(statusCode) && payload != nil {
      return .success
    }
    return .invalidResponse(statusCode: statusCode)
  }
}
/// ViewModel for the refined search experience
@MainActor
@Observable final class RefinedSearchViewModel: StateInvalidationSubscriber {
  // MARK: - Search State
  public var searchState: SearchState = .idle
  public var searchQuery: String = ""
  public var isCommittedSearch: Bool = false
  public var isLoadingMoreResults: Bool = false

  // MARK: - Filtering & Scope (G01 & G02)
  public var selectedContentType: ContentType = .top
  /// Single source of truth for applied post-search filters.
  public var filterState = SearchFilterState()

  // MARK: - Results (G01)
  public var postResults: [AppBskyFeedDefs.PostView] = []
  public var profileResults: [AppBskyActorDefs.ProfileView] = []
  public var feedResults: [AppBskyFeedDefs.GeneratorView] = []
  public var starterPackResults: [AppBskyGraphDefs.StarterPackViewBasic] = []

  // MARK: - Error State
  public var searchError: Error?
  public var loadMoreError: Error?
  // MARK: - Discovery Content (G03, G04, G05, G06)
  public var recentSearchEntries: [RecentSearchEntry] = []
  var recentProfileSearches: [RecentProfileSearch] = []
  public var trendingTopics: [AppBskyUnspeccedDefs.TrendView] = []
  public var suggestedProfiles: [AppBskyActorDefs.ProfileView] = []
  public var selectedSuggestedCategory: String? = nil
  public var isSuggestedProfilesLoading: Bool = false
  public var userInterests: [String] = []
  public var showExploreInterestsCard: Bool = false
  public var trendingVideos: [AppBskyFeedDefs.FeedViewPost] = []
  public var isTrendingVideosLoading: Bool = false

  // MARK: - Detected Languages (G08)
  public var detectedQueryLanguages: [String] = []

  // MARK: - Typeahead Results
  public var typeaheadProfiles: [AppBskyActorDefs.ProfileViewBasic] = []
  public var typeaheadSuggestions: [String] = []

  // MARK: - Pagination Cursors
  public var postCursor: String?
  public var profileCursor: String?
  public var feedCursor: String?
  public var starterPackCursor: String?

  // MARK: - Saved Searches
  public var savedSearches: [SavedSearch] = []

  // MARK: - Dependencies
  private let appState: AppState
  private let searchHistoryManager = SearchHistoryManager()
  private let logger = Logger(subsystem: "blue.catbird", category: "RefinedSearchViewModel")
  private let contentFilterService = ContentFilterService()

  // MARK: - Debouncing & Concurrency
  private var searchTask: Task<Void, Never>?
  private var searchExecutionTask: Task<Void, Never>?
  private var requestGeneration = SearchRequestGeneration()
  private var activeSearchRequest: SearchRequestSnapshot?
  private var suggestedUsersGeneration: UInt64 = 0
  private let searchDebounceTime: TimeInterval = 0.15
  private var isSubscribed = false

  // MARK: - Computed Properties

  /// Whether there are any search results for the active scope
  public var hasNoResults: Bool {
    switch selectedContentType {
    case .top, .latest:
      return postResults.isEmpty
    case .people:
      return profileResults.isEmpty
    case .feeds:
      return feedResults.isEmpty
    case .starterPacks:
      return starterPackResults.isEmpty
    }
  }

  /// All typeahead results count combined
  public var typeaheadResultsCount: Int {
    typeaheadProfiles.count + typeaheadSuggestions.count
  }

  // MARK: - Initialization

  init(appState: AppState) {
    self.appState = appState
    if let prefs = try? appState.preferencesManager.getLocalPreferences() {
      self.userInterests = prefs.interests
      let nuxCompleted = prefs.nuxStates.first(where: { $0.id == "ExploreInterestsCard" })?.completed ?? false
      self.showExploreInterestsCard = !nuxCompleted
    }
    loadRecentSearches()
    loadRecentProfileSearches()
    loadSavedSearches()
  }

  public func subscribeToEvents() {
    guard !isSubscribed else { return }
    appState.stateInvalidationBus.subscribe(self)
    isSubscribed = true
    logger.debug("RefinedSearchViewModel subscribed to state invalidation bus")
  }

  public func unsubscribeFromEvents() {
    guard isSubscribed else { return }
    appState.stateInvalidationBus.unsubscribe(self)
    isSubscribed = false
    logger.debug("RefinedSearchViewModel unsubscribed from state invalidation bus")
  }

  // MARK: - Discovery Lifecycle (G03, G04, G06)

  public func initialize(client: ATProtoClient) {
    Task {
      await refreshDiscoveryContent(client: client)
    }
  }

  public func refreshDiscoveryContent(client: ATProtoClient) async {
    async let trendsTask: Void = fetchTrendingTopics(client: client)
    async let suggestedTask: Void = fetchSuggestedUsers(category: selectedSuggestedCategory, client: client)
    async let videosTask: Void = fetchTrendingVideos(client: client)
    async let interestsTask: Void = loadUserInterests()

    _ = await (trendsTask, suggestedTask, videosTask, interestsTask)
  }

  public func loadUserInterests() async {
    if let prefs = try? await appState.preferencesManager.getPreferences() {
      userInterests = prefs.interests
      let nuxCompleted = prefs.nuxStates.first(where: { $0.id == "ExploreInterestsCard" })?.completed ?? false
      showExploreInterestsCard = !nuxCompleted
    }
  }

  public func dismissExploreInterestsCard() async {
    do {
      try await appState.preferencesManager.setNuxCompleted("ExploreInterestsCard", completed: true)
      showExploreInterestsCard = false
    } catch {
      logger.error("Error setting ExploreInterestsCard NUX completed: \(error.localizedDescription)")
    }
  }

  public func updateInterests(_ newInterests: [String]) async {
    do {
      try await appState.preferencesManager.updateInterests(newInterests)
      userInterests = newInterests
    } catch {
      logger.error("Error updating user interests: \(error.localizedDescription)")
    }
  }

  public func fetchTrendingTopics(client: ATProtoClient) async {
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

  public func fetchSuggestedUsers(category: String?, client: ATProtoClient) async {
    selectedSuggestedCategory = category
    suggestedProfiles = []
    isSuggestedProfilesLoading = true
    suggestedUsersGeneration &+= 1
    let generation = suggestedUsersGeneration

    do {
      let catParam = category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let input = AppBskyUnspeccedGetSuggestedUsers.Parameters(
        category: catParam?.isEmpty == false ? catParam : nil,
        limit: 25
      )
      let (statusCode, response) = try await client.app.bsky.unspecced.getSuggestedUsers(input: input)
      guard generation == self.suggestedUsersGeneration else { return }
      if statusCode == 200, let actorsResponse = response {
        suggestedProfiles = actorsResponse.actors
      } else {
        suggestedProfiles = []
      }
    } catch {
      guard generation == self.suggestedUsersGeneration else { return }
      logger.error("Error fetching suggested users: \(error.localizedDescription)")
      suggestedProfiles = []
    }
    if generation == self.suggestedUsersGeneration {
      isSuggestedProfilesLoading = false
    }
  }

  public func refreshSuggestedProfiles(client: ATProtoClient) async {
    await fetchSuggestedUsers(category: selectedSuggestedCategory, client: client)
  }

  public func fetchTrendingVideos(client: ATProtoClient) async {
    guard appState.appSettings.showTrendingVideos else {
      trendingVideos = []
      return
    }

    isTrendingVideosLoading = true
    defer { isTrendingVideosLoading = false }
    do {
      let feedUri = try ATProtocolURI(uriString: TrendingVideosSection.thevidsURI)
      let feedManager = FeedManager(client: client, fetchType: .feed(feedUri))
      let (posts, _) = try await feedManager.fetchFeed(fetchType: .feed(feedUri), cursor: nil)
      trendingVideos = posts
    } catch {
      logger.error("Error fetching trending videos: \(error.localizedDescription)")
      trendingVideos = []
    }
  }

  // MARK: - Query Updates & Typeahead

  public func updateSearch(query: String, client: ATProtoClient) {
    guard SearchQueryUpdateGate.shouldProcess(
      incoming: query,
      current: searchQuery,
      isCommitted: isCommittedSearch
    ) else {
      return
    }

    if query != searchQuery {
      invalidateSearchRequests(resetCursors: true)
    }
    searchQuery = query

    searchTask?.cancel()

    if query.isEmpty {
      searchState = .idle
      typeaheadProfiles = []
      typeaheadSuggestions = []
      isCommittedSearch = false
      return
    }

    if searchState == .idle || searchState == .results {
      searchState = .searching
    }

    isCommittedSearch = false

    let trendingTerms = trendingTopics.compactMap { $0.topic }.filter { !$0.isEmpty }
    let recentTerms = recentSearchEntries.map { $0.query }
    typeaheadSuggestions = SearchSuggestion.generateSuggestions(
      for: query,
      history: recentTerms,
      trending: trendingTerms
    )

    searchTask = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(nanoseconds: UInt64(self.searchDebounceTime * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await self.fetchTypeahead(query: query, client: client)
    }
  }

  // MARK: - Search Execution (G01 & G02)

  public func commitSearch(client: ATProtoClient) {
    logger.debug("commitSearch called with query: '\(self.searchQuery)', scope: \(self.selectedContentType.title)")

    guard !searchQuery.isEmpty else {
      resetSearch()
      return
    }

    searchTask?.cancel()

    syncSortWithScope()

    // Save recent search with complete filter state (G05)
    saveRecentSearch(searchQuery, filters: filterState)

    isCommittedSearch = true
    searchState = .results

    scheduleSearch(client: client)
  }

  public func setScope(_ scope: ContentType, client: ATProtoClient) {
    guard selectedContentType != scope else { return }
    selectedContentType = scope
    syncSortWithScope()

    if isCommittedSearch && !searchQuery.isEmpty {
      scheduleSearch(client: client)
    }
  }

  public func applyFilterState(_ state: SearchFilterState, client: ATProtoClient) {
    filterState = state

    // Enforce post-filter scope restriction
    if filterState.hasPostOnlyFilters && selectedContentType != .top && selectedContentType != .latest {
      selectedContentType = .top
      syncSortWithScope()
    }

    if isCommittedSearch {
      scheduleSearch(client: client)
    }
  }

  public func selectDetectedLanguage(_ languageCode: String, client: ATProtoClient) {
    var updated = filterState
    updated.language = languageCode
    applyFilterState(updated, client: client)
  }

  public func resetSearch() {
    invalidateSearchRequests(resetCursors: true)
    searchState = .idle
    searchQuery = ""
    isCommittedSearch = false
    searchError = nil
    loadMoreError = nil

    profileResults = []
    postResults = []
    feedResults = []
    starterPackResults = []
    detectedQueryLanguages = []

    typeaheadProfiles = []
    typeaheadSuggestions = []
  }

  public func refreshSearch(client: ATProtoClient) async {
    guard isCommittedSearch, !searchQuery.isEmpty else {
      if searchState == .idle {
        await refreshDiscoveryContent(client: client)
      }
      return
    }

    let request = beginSearchRequest()
    await executeSearchForCurrentScope(client: client, request: request, isRefresh: true)
  }

  // MARK: - Pagination

  public func loadMoreResults(client: ATProtoClient) async {
    guard !isLoadingMoreResults, isCommittedSearch else { return }
    isLoadingMoreResults = true
    loadMoreError = nil
    defer { isLoadingMoreResults = false }

    switch selectedContentType {
    case .top, .latest:
      await loadMorePosts(client: client)
    case .people:
      await loadMoreProfiles(client: client)
    case .feeds:
      await loadMoreFeeds(client: client)
    case .starterPacks:
      await loadMoreStarterPacks(client: client)
    }
  }

  private func scheduleSearch(client: ATProtoClient) {
    let request = beginSearchRequest()
    searchExecutionTask = Task { [weak self] in
      guard let self else { return }
      await self.executeSearchForCurrentScope(client: client, request: request, isRefresh: false)
    }
  }

  private func executeSearchForCurrentScope(
    client: ATProtoClient,
    request: SearchRequestSnapshot,
    isRefresh: Bool
  ) async {
    guard !request.query.isEmpty else {
      if requestGeneration.accepts(request) { searchState = .idle }
      return
    }

    guard requestGeneration.accepts(request), !Task.isCancelled else { return }

    searchError = nil
    loadMoreError = nil
    switch selectedContentType {
    case .top, .latest:
      await searchPosts(client: client, request: request, cursor: nil)
    case .people:
      await searchProfiles(client: client, request: request, cursor: nil)
    case .feeds:
      await searchFeeds(client: client, request: request)
    case .starterPacks:
      await searchStarterPacks(client: client, request: request, cursor: nil)
    }

    guard requestGeneration.accepts(request), !Task.isCancelled else { return }
    searchState = .results
  }

  // MARK: - Post Search V2 (G01 & G02 & G08)

  private func searchPosts(
    client: ATProtoClient,
    request: SearchRequestSnapshot,
    cursor: String?
  ) async {
    do {
      let input = request.filters.toSearchPostsV2Parameters(
        query: request.query,
        cursor: cursor,
        limit: 25
      )
      let (responseCode, response) = try await client.app.bsky.feed.searchPostsV2(input: input)

      guard requestGeneration.accepts(request), !Task.isCancelled else { return }

      guard case .success = SearchHTTPResponseClassification.classify(statusCode: responseCode, payload: response),
            let postsResponse = response
      else {
        let failureError = NetworkError.serverError(responseCode)
        logger.error("Search posts V2 failed with status \(responseCode)")
        searchError = failureError
        postResults = []
        postCursor = nil
        detectedQueryLanguages = []
        return
      }

      var results = postsResponse.posts

      if request.filters.language == nil
        && appState.appSettings.hideNonPreferredLanguages
        && !appState.appSettings.contentLanguages.isEmpty
      {
        results = applyLanguageFiltering(to: results)
      }

      let filterSettings = await appState.buildFilterSettings()
      results = await contentFilterService.filterPostViews(results, settings: filterSettings)

      guard requestGeneration.accepts(request), !Task.isCancelled else { return }
      postResults = results
      postCursor = postsResponse.cursor
      detectedQueryLanguages = postsResponse.detectedQueryLanguages ?? []
    } catch {
      guard requestGeneration.accepts(request), !Task.isCancelled else { return }
      logger.error("Error searching posts V2: \(error.localizedDescription)")
      searchError = error
      postResults = []
      postCursor = nil
      detectedQueryLanguages = []
    }
  }

  private func loadMorePosts(client: ATProtoClient) async {
    guard let request = activeSearchRequest,
          requestGeneration.accepts(request),
          request.query == searchQuery,
          request.filters == filterState,
          let cursor = postCursor
    else { return }

    do {
      let input = request.filters.toSearchPostsV2Parameters(
        query: request.query,
        cursor: cursor,
        limit: 25
      )
      let (responseCode, response) = try await client.app.bsky.feed.searchPostsV2(input: input)

      guard requestGeneration.accepts(request), !Task.isCancelled else { return }
      guard case .success = SearchHTTPResponseClassification.classify(statusCode: responseCode, payload: response),
            let postsResponse = response
      else {
        let failureError = NetworkError.serverError(responseCode)
        logger.error("Error loading more posts: HTTP \(responseCode)")
        loadMoreError = failureError
        return
      }

      var newOnes = postsResponse.posts
      let filterSettings = await appState.buildFilterSettings()
      newOnes = await contentFilterService.filterPostViews(newOnes, settings: filterSettings)

      let existing = Set(postResults.map { $0.uri.uriString() })
      let deduplicated = newOnes.filter { !existing.contains($0.uri.uriString()) }
      postResults.append(contentsOf: deduplicated)
      postCursor = postsResponse.cursor
    } catch {
      guard requestGeneration.accepts(request), !Task.isCancelled else { return }
      logger.error("Error loading more posts: \(error.localizedDescription)")
      loadMoreError = error
    }
  }

  // MARK: - Profile Search

  private func searchProfiles(
    client: ATProtoClient,
    request: SearchRequestSnapshot,
    cursor: String?
  ) async {
    do {
      let input = AppBskyActorSearchActors.Parameters(
        term: request.query,
        limit: 25,
        cursor: cursor
      )
      let (responseCode, response) = try await client.app.bsky.actor.searchActors(input: input)

      guard requestGeneration.accepts(request), !Task.isCancelled else { return }
      guard case .success = SearchHTTPResponseClassification.classify(statusCode: responseCode, payload: response),
            let actorsResponse = response
      else {
        let failureError = NetworkError.serverError(responseCode)
        logger.error("Search profiles failed with status \(responseCode)")
        searchError = failureError
        profileResults = []
        profileCursor = nil
        return
      }

      profileResults = actorsResponse.actors
      profileCursor = actorsResponse.cursor
    } catch {
      guard requestGeneration.accepts(request), !Task.isCancelled else { return }
      logger.error("Error searching profiles: \(error.localizedDescription)")
      searchError = error
      profileResults = []
      profileCursor = nil
    }
  }

  private func loadMoreProfiles(client: ATProtoClient) async {
    guard let request = activeSearchRequest,
          requestGeneration.accepts(request),
          request.query == searchQuery,
          request.filters == filterState,
          let cursor = profileCursor
    else { return }

    do {
      let input = AppBskyActorSearchActors.Parameters(
        term: request.query,
        limit: 25,
        cursor: cursor
      )
      let (responseCode, response) = try await client.app.bsky.actor.searchActors(input: input)

      guard requestGeneration.accepts(request), !Task.isCancelled else { return }
      guard case .success = SearchHTTPResponseClassification.classify(statusCode: responseCode, payload: response),
            let actorsResponse = response
      else {
        let failureError = NetworkError.serverError(responseCode)
        logger.error("Error loading more profiles: HTTP \(responseCode)")
        loadMoreError = failureError
        return
      }

      let existing = Set(profileResults.map { $0.did.didString() })
      let newOnes = actorsResponse.actors.filter { !existing.contains($0.did.didString()) }
      profileResults.append(contentsOf: newOnes)
      profileCursor = actorsResponse.cursor
    } catch {
      guard requestGeneration.accepts(request), !Task.isCancelled else { return }
      logger.error("Error loading more profiles: \(error.localizedDescription)")
      loadMoreError = error
    }
  }

  // MARK: - Feed Search

  private func searchFeeds(client: ATProtoClient, request: SearchRequestSnapshot) async {
    do {
      let input = AppBskyUnspeccedGetPopularFeedGenerators.Parameters(
        limit: 25,
        query: request.query
      )
      let (responseCode, response) = try await client.app.bsky.unspecced.getPopularFeedGenerators(input: input)

      guard requestGeneration.accepts(request), !Task.isCancelled else { return }
      guard case .success = SearchHTTPResponseClassification.classify(statusCode: responseCode, payload: response),
            let feedsResponse = response
      else {
        let failureError = NetworkError.serverError(responseCode)
        logger.error("Search feeds failed with status \(responseCode)")
        searchError = failureError
        feedResults = []
        feedCursor = nil
        return
      }

      feedResults = feedsResponse.feeds
      feedCursor = feedsResponse.cursor
    } catch {
      guard requestGeneration.accepts(request), !Task.isCancelled else { return }
      logger.error("Error searching feeds: \(error.localizedDescription)")
      searchError = error
      feedResults = []
      feedCursor = nil
    }
  }

  private func loadMoreFeeds(client: ATProtoClient) async {
    // Feed search API does not currently paginate with a cursor.
  }

  // MARK: - Starter Pack Search (G01)

  private func searchStarterPacks(
    client: ATProtoClient,
    request: SearchRequestSnapshot,
    cursor: String?
  ) async {
    do {
      let input = AppBskyGraphSearchStarterPacks.Parameters(
        q: request.query,
        limit: 25,
        cursor: cursor
      )
      let (responseCode, response) = try await client.app.bsky.graph.searchStarterPacks(input: input)

      guard requestGeneration.accepts(request), !Task.isCancelled else { return }
      guard case .success = SearchHTTPResponseClassification.classify(statusCode: responseCode, payload: response),
            let packsResponse = response
      else {
        let failureError = NetworkError.serverError(responseCode)
        logger.error("Search starter packs failed with status \(responseCode)")
        searchError = failureError
        starterPackResults = []
        starterPackCursor = nil
        return
      }

      starterPackResults = packsResponse.starterPacks
      starterPackCursor = packsResponse.cursor
    } catch {
      guard requestGeneration.accepts(request), !Task.isCancelled else { return }
      logger.error("Error searching starter packs: \(error.localizedDescription)")
      searchError = error
      starterPackResults = []
      starterPackCursor = nil
    }
  }

  private func loadMoreStarterPacks(client: ATProtoClient) async {
    guard let request = activeSearchRequest,
          requestGeneration.accepts(request),
          request.query == searchQuery,
          request.filters == filterState,
          let cursor = starterPackCursor
    else { return }

    do {
      let input = AppBskyGraphSearchStarterPacks.Parameters(
        q: request.query,
        limit: 25,
        cursor: cursor
      )
      let (responseCode, response) = try await client.app.bsky.graph.searchStarterPacks(input: input)

      guard requestGeneration.accepts(request), !Task.isCancelled else { return }
      guard case .success = SearchHTTPResponseClassification.classify(statusCode: responseCode, payload: response),
            let packsResponse = response
      else {
        let failureError = NetworkError.serverError(responseCode)
        logger.error("Error loading more starter packs: HTTP \(responseCode)")
        loadMoreError = failureError
        return
      }

      let existing = Set(starterPackResults.map { $0.uri.uriString() })
      let newOnes = packsResponse.starterPacks.filter { !existing.contains($0.uri.uriString()) }
      starterPackResults.append(contentsOf: newOnes)
      starterPackCursor = packsResponse.cursor
    } catch {
      guard requestGeneration.accepts(request), !Task.isCancelled else { return }
      logger.error("Error loading more starter packs: \(error.localizedDescription)")
      loadMoreError = error
    }
  }

  // MARK: - Recent Searches Management (G05)

  public func saveRecentSearch(_ search: String, filters: SearchFilterState = SearchFilterState()) {
    let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let userDID = appState.userDID
    searchHistoryManager.saveRecentSearch(query: trimmed, filters: filters, userDID: userDID)
    loadRecentSearches()
  }

  public func clearRecentSearches() {
    searchHistoryManager.clearRecentSearches(for: appState.userDID)
    loadRecentSearches()
  }

  public func deleteRecentSearch(_ entry: RecentSearchEntry) {
    searchHistoryManager.deleteRecentSearch(entry.id, userDID: appState.userDID)
    loadRecentSearches()
  }

  public func loadRecentSearches() {
    recentSearchEntries = searchHistoryManager.loadRecentSearches(for: appState.userDID)
  }

  public func applyRecentSearchEntry(
    _ entry: RecentSearchEntry,
    client: ATProtoClient,
    onQueryLoaded: (String) -> Void
  ) {
    searchQuery = entry.query
    filterState = entry.filters
    selectedContentType = (entry.filters.sort == .latest ? .latest : .top)
    onQueryLoaded(entry.query)
    commitSearch(client: client)
  }

  // MARK: - Recent Profiles Management

  public func addRecentProfileSearch(profile: AppBskyActorDefs.ProfileView) {
    insertRecentProfileSearch(RecentProfileSearch(from: profile), did: profile.did.didString())
  }

  public func addRecentProfileSearchBasic(profile: AppBskyActorDefs.ProfileViewBasic) {
    insertRecentProfileSearch(
      RecentProfileSearch(
        did: profile.did,
        handle: profile.handle,
        displayName: profile.displayName,
        avatarURL: profile.avatar?.uriString()
      ),
      did: profile.did.didString()
    )
  }

  public func clearRecentProfileSearches() {
    recentProfileSearches = []
    let key = recentProfileSearchesKey()
    UserDefaults(suiteName: "group.blue.catbird.shared")?.removeObject(forKey: key)
  }

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

  private func recentProfileSearchesKey() -> String {
    let userDID = appState.userDID
    if !userDID.isEmpty {
      return "recentProfileSearches_\(userDID)"
    }
    return "recentProfileSearches_default"
  }

  // MARK: - Saved Searches Management

  public func saveCurrentSearch(name: String) {
    let savedSearch = SavedSearch(
      name: name,
      query: searchQuery,
      filters: filterState
    )
    let userDID = appState.userDID
    searchHistoryManager.saveSearch(savedSearch, userDID: userDID)
    loadSavedSearches()
  }

  public func saveSearch(_ savedSearch: SavedSearch) {
    let userDID = appState.userDID
    searchHistoryManager.saveSearch(savedSearch, userDID: userDID)
    loadSavedSearches()
  }

  public func deleteSavedSearch(_ id: UUID) {
    let userDID = appState.userDID
    searchHistoryManager.deleteSavedSearch(id, userDID: userDID)
    loadSavedSearches()
  }

  public func loadSavedSearches() {
    let userDID = appState.userDID
    savedSearches = searchHistoryManager.loadSavedSearches(for: userDID)
  }

  public func loadAndApplySavedSearch(
    _ savedSearch: SavedSearch,
    client: ATProtoClient,
    onQueryLoaded: (String) -> Void
  ) {
    searchQuery = savedSearch.query
    filterState = savedSearch.filters
    selectedContentType = (savedSearch.filters.sort == .latest ? .latest : .top)
    onQueryLoaded(savedSearch.query)
    searchHistoryManager.updateLastUsed(savedSearch.id, userDID: appState.userDID)
    commitSearch(client: client)
  }

  // MARK: - Private Helpers

  private func fetchTypeahead(query: String, client: ATProtoClient) async {
    do {
      let input = AppBskyActorSearchActorsTypeahead.Parameters(
        term: query,
        limit: 3
      )
      let (_, profileResponse) = try await client.app.bsky.actor.searchActorsTypeahead(input: input)
      if let profiles = profileResponse?.actors {
        typeaheadProfiles = profiles
      }
    } catch {
      logger.error("Error fetching typeahead: \(error.localizedDescription)")
    }
  }

  private func resetPaginationCursors() {
    postCursor = nil
    profileCursor = nil
    feedCursor = nil
    starterPackCursor = nil
  }
  private func syncSortWithScope() {
    switch selectedContentType {
    case .top:
      filterState.sort = .top
    case .latest:
      filterState.sort = .latest
    case .people, .feeds, .starterPacks:
      break
    }
  }

  private func insertRecentProfileSearch(_ entry: RecentProfileSearch, did: String) {
    if let index = recentProfileSearches.firstIndex(where: { $0.did.didString() == did }) {
      recentProfileSearches.remove(at: index)
    }
    recentProfileSearches.insert(entry, at: 0)
    if recentProfileSearches.count > 10 {
      recentProfileSearches = Array(recentProfileSearches.prefix(10))
    }
    let key = recentProfileSearchesKey()
    if let encoded = try? JSONEncoder().encode(recentProfileSearches) {
      UserDefaults(suiteName: "group.blue.catbird.shared")?.set(encoded, forKey: key)
    }
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
    syncSortWithScope()
    let request = requestGeneration.begin(query: searchQuery, filters: filterState)
    activeSearchRequest = request
    resetPaginationCursors()
    return request
  }

  private func applyLanguageFiltering(to posts: [AppBskyFeedDefs.PostView]) -> [AppBskyFeedDefs.PostView] {
    let preferredLanguages = appState.appSettings.contentLanguages
    var filteredPosts: [AppBskyFeedDefs.PostView] = []

    for post in posts {
      guard case .knownType(let record) = post.record,
            let feedPost = record as? AppBskyFeedPost
      else {
        filteredPosts.append(post)
        continue
      }

      guard let postLanguages = feedPost.langs, !postLanguages.isEmpty else {
        filteredPosts.append(post)
        continue
      }

      let hasPreferredLanguage = postLanguages.contains { postLangContainer in
        preferredLanguages.contains { prefLang in
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

  func isInterestedIn(_ event: StateInvalidationEvent) -> Bool {
    switch event {
    case .accountSwitched:
      return true
    default:
      return false
    }
  }

  func handleStateInvalidation(_ event: StateInvalidationEvent) async {
    switch event {
    case .accountSwitched:
      await MainActor.run {
        loadRecentSearches()
        loadRecentProfileSearches()
        loadSavedSearches()
      }
    default:
      break
    }
  }
}
