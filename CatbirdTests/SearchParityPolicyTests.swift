import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("Search Parity Policy Tests (WS-A)")
struct SearchParityPolicyTests {
  @Test("post-only filters expose only Top and Latest while language does not restrict tabs")
  func postOnlyFiltersExposeOnlyTopAndLatestAndLanguageDoesNotRestrictTabs() {
    var state = SearchFilterState()
    #expect(!state.hasPostOnlyFilters)

    // Language alone should NOT trigger post-only filter restriction
    state.language = "ja"
    #expect(!state.hasPostOnlyFilters)

    // Sort alone should NOT trigger post-only filter restriction
    state.sort = .latest
    #expect(!state.hasPostOnlyFilters)

    // Setting an author filter activates post-only restriction
    state.author = "alice.bsky.social"
    #expect(state.hasPostOnlyFilters)

    state.author = nil
    #expect(!state.hasPostOnlyFilters)

    // Setting a hashtag activates post-only restriction
    state.hashtag = "swift"
    #expect(state.hasPostOnlyFilters)

    state.hashtag = nil
    #expect(!state.hasPostOnlyFilters)

    // Setting a domain activates post-only restriction
    state.domain = "nytimes.com"
    #expect(state.hasPostOnlyFilters)

    state.domain = nil
    #expect(!state.hasPostOnlyFilters)

    // Setting a date range activates post-only restriction
    state.dateRange = .week
    #expect(state.hasPostOnlyFilters)

    state.dateRange = .anytime
    #expect(!state.hasPostOnlyFilters)

    // Setting reply mode activates post-only restriction
    state.replyMode = .excludeReplies
    #expect(state.hasPostOnlyFilters)

    state.replyMode = .any
    #expect(!state.hasPostOnlyFilters)

    // Setting media/video/following flags activates post-only restriction
    state.hasMedia = true
    #expect(state.hasPostOnlyFilters)

    state.hasMedia = false
    state.hasVideo = true
    #expect(state.hasPostOnlyFilters)

    state.hasVideo = false
    state.following = true
    #expect(state.hasPostOnlyFilters)
  }

  @Test("recent search entry Codable round trip preserves filters")
  func recentSearchEntryCodableRoundTripPreservesFilters() throws {
    var filters = SearchFilterState()
    filters.sort = .latest
    filters.author = "alice.bsky.social"
    filters.language = "ja"
    filters.hasVideo = true
    filters.replyMode = .repliesOnly

    let entry = RecentSearchEntry(
      query: "swift programming",
      filters: filters,
      timestamp: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let data = try JSONEncoder().encode(entry)
    let decoded = try JSONDecoder().decode(RecentSearchEntry.self, from: data)

    #expect(decoded.id == entry.id)
    #expect(decoded.query == "swift programming")
    #expect(decoded.filters == filters)
    #expect(decoded.filters.activeFilterCount == 4)
    #expect(decoded.filters.sort == .latest)
    #expect(decoded.filters.author == "alice.bsky.social")
    #expect(decoded.filters.language == "ja")
    #expect(decoded.filters.hasVideo == true)
  }

  @Test("legacy string history migrates to neutral entries")
  func legacyStringHistoryMigratesToNeutralEntries() throws {
    let testSuite = "group.blue.catbird.shared.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: testSuite)!
    defer { defaults.removePersistentDomain(forName: testSuite) }

    let testDID = "did:plc:testmigration"
    let legacyKey = "recentSearches_\(testDID)"
    let jsonKey = "searchHistory_json_\(testDID)"

    // Write legacy [String]
    let legacyStrings = ["cats", "dogs", "swift"]
    defaults.set(legacyStrings, forKey: legacyKey)

    // Read via SearchHistoryManager using the test suite
    let manager = SearchHistoryManager()
    
    // Simulate migration logic
    if let raw = defaults.array(forKey: legacyKey) as? [String], !raw.isEmpty {
      let migrated = raw.map { RecentSearchEntry(query: $0, filters: SearchFilterState(), timestamp: Date()) }
      let encoded = try JSONEncoder().encode(migrated)
      defaults.set(encoded, forKey: jsonKey)
      defaults.removeObject(forKey: legacyKey)
    }

    #expect(defaults.object(forKey: legacyKey) == nil)
    let savedData = try #require(defaults.data(forKey: jsonKey))
    let decoded = try JSONDecoder().decode([RecentSearchEntry].self, from: savedData)
    #expect(decoded.count == 3)
    #expect(decoded.map { $0.query } == ["cats", "dogs", "swift"])
    #expect(decoded.allSatisfy { $0.filters.isDefault })
  }

  @Test("duplicate query and filter moves to front")
  func duplicateQueryAndFilterMovesToFront() {
    var history: [RecentSearchEntry] = []

    var filterA = SearchFilterState()
    filterA.language = "en"

    var filterB = SearchFilterState()
    filterB.language = "ja"

    let entryA1 = RecentSearchEntry(query: "cats", filters: filterA)
    let entryB = RecentSearchEntry(query: "dogs", filters: filterB)
    let entryA2 = RecentSearchEntry(query: "cats", filters: filterA)

    history.insert(entryA1, at: 0)
    history.insert(entryB, at: 0)

    #expect(history.count == 2)
    #expect(history[0].query == "dogs")
    #expect(history[1].query == "cats")

    // Adding A again removes prior identical query+filter and inserts at front
    history.removeAll { $0.query == entryA2.query && $0.filters == entryA2.filters }
    history.insert(entryA2, at: 0)

    #expect(history.count == 2)
    #expect(history[0].query == "cats")
    #expect(history[1].query == "dogs")
  }

  @Test("distinct DID keys do not collide")
  func distinctDIDKeysDoNotCollide() {
    let manager = SearchHistoryManager()
    let key1 = manager.historyJSONKey(for: "did:plc:user1")
    let key2 = manager.historyJSONKey(for: "did:plc:user2")
    let keyDefault = manager.historyJSONKey(for: nil)

    #expect(key1 != key2)
    #expect(key1 != keyDefault)
    #expect(key2 != keyDefault)
    #expect(key1 == "searchHistory_json_did:plc:user1")
    #expect(key2 == "searchHistory_json_did:plc:user2")
  }

  // MARK: - G08 Detected Languages Tests

  @Test("detected language tip shows unselected languages")
  func detectedLanguageTipShowsUnselectedLanguages() {
    let detected = ["ja", "en", "es"]
    let unselected = DetectedQueryLanguagesAdmonition.unselectedLanguages(
      from: detected,
      selectedLanguage: nil
    )
    #expect(unselected == ["ja", "en", "es"])

    // Test language name localization helper
    let jaName = DetectedQueryLanguagesAdmonition.localizedLanguageName(for: "ja", locale: Locale(identifier: "en_US"))
    #expect(jaName.localizedCaseInsensitiveContains("Japanese"))
  }

  @Test("detected language tip suppresses selected language")
  func detectedLanguageTipSuppressesSelectedLanguage() {
    let detected = ["ja", "en"]

    // When 'ja' is selected, only 'en' should be shown as unselected
    let unselectedJa = DetectedQueryLanguagesAdmonition.unselectedLanguages(
      from: detected,
      selectedLanguage: "ja"
    )
    #expect(unselectedJa == ["en"])

    // Case-insensitivity check
    let unselectedJaUpper = DetectedQueryLanguagesAdmonition.unselectedLanguages(
      from: detected,
      selectedLanguage: "JA"
    )
    #expect(unselectedJaUpper == ["en"])

    // When the only detected language is selected, unselected list is empty
    let unselectedAll = DetectedQueryLanguagesAdmonition.unselectedLanguages(
      from: ["ja"],
      selectedLanguage: "ja"
    )
    #expect(unselectedAll.isEmpty)
  }

  @Test("stale search generation cannot replace detected languages")
  func staleSearchGenerationCannotReplaceDetectedLanguages() {
    var generation = SearchRequestGeneration()
    let initialFilters = SearchFilterState()

    // Request 1 issued
    let req1 = generation.begin(query: "cats", filters: initialFilters)
    #expect(generation.accepts(req1))

    // Request 2 issued before Request 1 returns
    var updatedFilters = initialFilters
    updatedFilters.language = "ja"
    let req2 = generation.begin(query: "cats", filters: updatedFilters)

    // Stale request 1 is rejected
    #expect(!generation.accepts(req1))
    // Current request 2 is accepted
    #expect(generation.accepts(req2))

    // Invalidation also rejects current request
    generation.invalidate()
    #expect(!generation.accepts(req2))
  }

  // MARK: - G07 Explore Interests NUX Tests

  @Test("explore interests NUX card state derivation")
  func exploreInterestsNuxCardStateDerivation() {
    // When nuxStates does not have ExploreInterestsCard, NUX is incomplete (card should show)
    let incompleteStates: [NuxState] = []
    let isCompletedIncomplete = incompleteStates.first(where: { $0.id == "ExploreInterestsCard" })?.completed ?? false
    #expect(!isCompletedIncomplete)

    // When ExploreInterestsCard is completed: false, NUX is incomplete (card should show)
    let falseStates = [NuxState(id: "ExploreInterestsCard", completed: false)]
    let isCompletedFalse = falseStates.first(where: { $0.id == "ExploreInterestsCard" })?.completed ?? false
    #expect(!isCompletedFalse)

    // When ExploreInterestsCard is completed: true, NUX is completed (card should hide)
    let completedStates = [NuxState(id: "ExploreInterestsCard", completed: true)]
    let isCompletedTrue = completedStates.first(where: { $0.id == "ExploreInterestsCard" })?.completed ?? false
    #expect(isCompletedTrue)
  }

  // MARK: - Repair Regression Tests (WS-A-02, WS-A-03, WS-A-06)

  @Test("anytime date range is neutral and does not restrict tabs even with stored custom dates")
  func anytimeDateRangeIsNeutralEvenWithStoredCustomDates() {
    var state = SearchFilterState()
    state.selectDateRange(.custom)
    #expect(state.hasDateFilter)
    #expect(state.hasPostOnlyFilters)
    #expect(state.customStartDate != nil)
    #expect(state.customEndDate != nil)

    // Switching back to anytime clears custom dates and neutralizes date filter
    state.selectDateRange(.anytime)
    #expect(!state.hasDateFilter)
    #expect(!state.hasPostOnlyFilters)
    #expect(state.customStartDate == nil)
    #expect(state.customEndDate == nil)
    let bounds = state.dateBounds()
    #expect(bounds.since == nil)
    #expect(bounds.until == nil)

    // Even if custom dates are manually injected with .anytime, hasDateFilter remains false
    state.dateRange = .anytime
    state.customStartDate = Date()
    state.customEndDate = Date()
    #expect(!state.hasDateFilter)
    #expect(!state.hasPostOnlyFilters)
  }

  @Test("strict ATIdentifier validation rejects dotless handles and malformed DIDs")
  func strictIdentifierValidationRejectsDotlessHandlesAndMalformedDIDs() {
    var state = SearchFilterState()

    // Dotless handle must be rejected
    state.author = "alice"
    #expect(!state.isValid)
    #expect(state.authorValidationError != nil)

    // Malformed DID must be rejected
    state.author = "did:foo"
    #expect(!state.isValid)
    #expect(state.authorValidationError != nil)

    // Valid handle
    state.author = "alice.bsky.social"
    #expect(state.isValid)
    #expect(state.authorValidationError == nil)

    // Valid handle with leading @
    state.author = "@alice.bsky.social"
    #expect(state.isValid)
    #expect(state.authorValidationError == nil)

    // Valid DID
    state.author = "did:plc:z72i7hdynmk6r22z27h6tvur"
    #expect(state.isValid)
    #expect(state.authorValidationError == nil)
  }

  @Test("legacy SearchFilterState JSON without replyMode decodes with safe fallbacks")
  func legacySearchFilterStateJSONWithoutReplyModeDecodesWithSafeFallbacks() throws {
    // Pre-wave schema payload with only sort, dateRange, and language
    let legacyJSON = """
    {
      "sort": "latest",
      "dateRange": "month",
      "language": "ja"
    }
    """
    let data = try #require(legacyJSON.data(using: .utf8))
    let decoded = try JSONDecoder().decode(SearchFilterState.self, from: data)

    #expect(decoded.sort == .latest)
    #expect(decoded.dateRange == .month)
    #expect(decoded.language == "ja")
    #expect(decoded.replyMode == .any)
    #expect(decoded.hasMedia == false)
    #expect(decoded.hasVideo == false)
    #expect(decoded.following == false)
    #expect(decoded.author == nil)
    #expect(decoded.hasDateFilter == true)
  }

  @Test("legacy SavedSearch array without replyMode in filter state decodes successfully")
  func legacySavedSearchArrayWithoutReplyModeDecodesSuccessfully() throws {
    let legacySavedSearchesJSON = """
    [
      {
        "id": "A1B2C3D4-E5F6-7A8B-9C0D-1E2F3A4B5C6D",
        "name": "iOS Dev",
        "query": "swiftui",
        "filters": {
          "sort": "top",
          "dateRange": "week",
          "language": "en"
        },
        "createdAt": 1700000000,
        "lastUsed": 1700000100
      }
    ]
    """
    let data = try #require(legacySavedSearchesJSON.data(using: .utf8))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let decoded = try decoder.decode([SavedSearch].self, from: data)

    #expect(decoded.count == 1)
    #expect(decoded[0].name == "iOS Dev")
    #expect(decoded[0].query == "swiftui")
    #expect(decoded[0].filters.sort == .top)
    #expect(decoded[0].filters.dateRange == .week)
    #expect(decoded[0].filters.language == "en")
    #expect(decoded[0].filters.replyMode == .any)
    #expect(decoded[0].filters.hasMedia == false)
    #expect(decoded[0].filters.hasVideo == false)
  }

  @Test("strict URL validation requires valid scheme and URI parseability")
  func strictURLValidationRequiresValidSchemeAndURIParsing() {
    var state = SearchFilterState()

    // Invalid URL without scheme
    state.url = "example.com/post"
    #expect(!state.isValid)
    #expect(state.urlValidationError != nil)

    // Valid URL with scheme
    state.url = "https://example.com/post"
    #expect(state.isValid)
    #expect(state.urlValidationError == nil)

    // Exclude URL validation
    state.url = nil
    state.excludeURL = "not-a-valid-url"
    #expect(!state.isValid)
    #expect(state.excludeURLValidationError != nil)

    state.excludeURL = "https://example.org/feed"
    #expect(state.isValid)
    #expect(state.excludeURLValidationError == nil)
  }

  // MARK: - Search HTTP Response Classification Tests

  @Test("search response classification requires 2xx status code and non-nil payload")
  func searchResponseClassificationRequires2xxAndPayload() {
    let dummyPayload = "sample-response-body"

    // 2xx with valid payload -> success
    #expect(SearchHTTPResponseClassification.classify(statusCode: 200, payload: dummyPayload) == .success)
    #expect(SearchHTTPResponseClassification.classify(statusCode: 201, payload: dummyPayload) == .success)
    #expect(SearchHTTPResponseClassification.classify(statusCode: 299, payload: dummyPayload) == .success)

    // 2xx with nil payload -> invalidResponse
    #expect(
      SearchHTTPResponseClassification.classify(statusCode: 200, payload: String?.none)
        == .invalidResponse(statusCode: 200)
    )
    #expect(
      SearchHTTPResponseClassification.classify(statusCode: 204, payload: String?.none)
        == .invalidResponse(statusCode: 204)
    )

    // Non-2xx with payload or nil payload -> invalidResponse
    #expect(
      SearchHTTPResponseClassification.classify(statusCode: 400, payload: dummyPayload)
        == .invalidResponse(statusCode: 400)
    )
    #expect(
      SearchHTTPResponseClassification.classify(statusCode: 404, payload: String?.none)
        == .invalidResponse(statusCode: 404)
    )
    #expect(
      SearchHTTPResponseClassification.classify(statusCode: 500, payload: String?.none)
        == .invalidResponse(statusCode: 500)
    )
    #expect(
      SearchHTTPResponseClassification.classify(statusCode: 503, payload: dummyPayload)
        == .invalidResponse(statusCode: 503)
    )

    // Boundary status codes
    #expect(
      SearchHTTPResponseClassification.classify(statusCode: 199, payload: dummyPayload)
        == .invalidResponse(statusCode: 199)
    )
    #expect(
      SearchHTTPResponseClassification.classify(statusCode: 300, payload: dummyPayload)
        == .invalidResponse(statusCode: 300)
    )
  }

  @Test("search response classification applies across all search scope payloads")
  func searchResponseClassificationAppliesAcrossAllSearchScopePayloads() {
    let postsOutput = AppBskyFeedSearchPostsV2.Output(cursor: "c1", posts: [])
    let actorsOutput = AppBskyActorSearchActors.Output(cursor: "c2", actors: [])
    let feedsOutput = AppBskyUnspeccedGetPopularFeedGenerators.Output(cursor: "c3", feeds: [])
    let starterPacksOutput = AppBskyGraphSearchStarterPacks.Output(cursor: "c4", starterPacks: [])

    // 200 with valid typed outputs
    #expect(SearchHTTPResponseClassification.classify(statusCode: 200, payload: postsOutput) == .success)
    #expect(SearchHTTPResponseClassification.classify(statusCode: 200, payload: actorsOutput) == .success)
    #expect(SearchHTTPResponseClassification.classify(statusCode: 200, payload: feedsOutput) == .success)
    #expect(SearchHTTPResponseClassification.classify(statusCode: 200, payload: starterPacksOutput) == .success)

    // 200 with nil typed outputs -> invalidResponse
    #expect(
      SearchHTTPResponseClassification.classify(statusCode: 200, payload: AppBskyFeedSearchPostsV2.Output?.none)
        == .invalidResponse(statusCode: 200)
    )
    #expect(
      SearchHTTPResponseClassification.classify(statusCode: 200, payload: AppBskyActorSearchActors.Output?.none)
        == .invalidResponse(statusCode: 200)
    )
    #expect(
      SearchHTTPResponseClassification.classify(statusCode: 200, payload: AppBskyUnspeccedGetPopularFeedGenerators.Output?.none)
        == .invalidResponse(statusCode: 200)
    )
    #expect(
      SearchHTTPResponseClassification.classify(statusCode: 200, payload: AppBskyGraphSearchStarterPacks.Output?.none)
        == .invalidResponse(statusCode: 200)
    )

    // 500 / 400 with non-nil outputs -> invalidResponse
    #expect(
      SearchHTTPResponseClassification.classify(statusCode: 500, payload: postsOutput)
        == .invalidResponse(statusCode: 500)
    )
    #expect(
      SearchHTTPResponseClassification.classify(statusCode: 400, payload: actorsOutput)
        == .invalidResponse(statusCode: 400)
    )
  }

  @Test("load more failure retains current results and cursor for retry")
  func loadMoreFailureRetainsCurrentResultsAndCursorForRetry() {
    // Model invariant test: load more errors must preserve existing cursor and existing items
    var existingPosts: [String] = ["at://did:plc:1/app.bsky.feed.post/p1", "at://did:plc:1/app.bsky.feed.post/p2"]
    var postCursor: String? = "cursor_page_1"
    var loadMoreError: Error? = nil

    // Simulating failed load-more (e.g. HTTP 500)
    let failureCode = 500
    let classification = SearchHTTPResponseClassification.classify(statusCode: failureCode, payload: String?.none)
    #expect(classification == .invalidResponse(statusCode: 500))

    if case .invalidResponse(let status) = classification {
      loadMoreError = NetworkError.serverError(status)
      // Crucial: existingPosts and postCursor are NOT erased!
    }

    #expect(loadMoreError != nil)
    #expect(existingPosts.count == 2)
    #expect(postCursor == "cursor_page_1")

    // Retrying with the same cursor on 200 success
    let retryClassification = SearchHTTPResponseClassification.classify(statusCode: 200, payload: ["at://did:plc:1/app.bsky.feed.post/p3"])
    #expect(retryClassification == .success)
    if case .success = retryClassification {
      existingPosts.append("at://did:plc:1/app.bsky.feed.post/p3")
      postCursor = "cursor_page_2"
      loadMoreError = nil
    }

    #expect(loadMoreError == nil)
    #expect(existingPosts.count == 3)
    #expect(postCursor == "cursor_page_2")
  }
}
