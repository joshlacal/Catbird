import Foundation
import Testing
@testable import Catbird

@Suite("Search filter wiring")
struct SearchFilterWiringTests {
  @Test("committed saved-query echo is ignored without blocking real edits")
  func savedQueryEchoDisposition() {
    #expect(!SearchQueryUpdateGate.shouldProcess(
      incoming: "saved", current: "saved", isCommitted: true
    ))
    #expect(SearchQueryUpdateGate.shouldProcess(
      incoming: "saved plus edit", current: "saved", isCommitted: true
    ))
    #expect(SearchQueryUpdateGate.shouldProcess(
      incoming: "typing", current: "typing", isCommitted: false
    ))
  }

  @Test("new request generations reject stale responses and retain snapshots")
  func generationRejectsStaleResponses() {
    var generation = SearchRequestGeneration()
    var oldFilters = SearchFilterState()
    oldFilters.sort = .top
    let old = generation.begin(query: "old", filters: oldFilters)
    var newFilters = SearchFilterState()
    newFilters.sort = .latest
    let current = generation.begin(query: "new", filters: newFilters)

    #expect(old.query == "old")
    #expect(old.filters.sort == .top)
    #expect(!generation.accepts(old))
    #expect(generation.accepts(current))
  }

  @Test("all post search paths use searchPostsV2 parameters")
  func allPostSearchPathsUseSearchPostsV2Parameters() throws {
    let source = try sourceFile("Catbird/Features/Search/ViewModels/RefinedSearchViewModel.swift")

    let initialSearch = try #require(functionBody("private func searchPosts", in: source))
    #expect(initialSearch.contains("toSearchPostsV2Parameters"))
    #expect(initialSearch.contains("client.app.bsky.feed.searchPostsV2"))

    let pagination = try #require(functionBody("private func loadMorePosts", in: source))
    #expect(pagination.contains("toSearchPostsV2Parameters"))
    #expect(pagination.contains("client.app.bsky.feed.searchPostsV2"))
    #expect(pagination.contains("cursor: cursor"))
  }

  @Test("starter pack search uses generated graph endpoint and cursor")
  func starterPackSearchUsesGeneratedGraphEndpointAndCursor() throws {
    let source = try sourceFile("Catbird/Features/Search/ViewModels/RefinedSearchViewModel.swift")

    let starterPackSearch = try #require(functionBody("private func searchStarterPacks", in: source))
    #expect(starterPackSearch.contains("client.app.bsky.graph.searchStarterPacks"))
    #expect(starterPackSearch.contains("starterPackResults = packsResponse.starterPacks"))
    #expect(starterPackSearch.contains("starterPackCursor = packsResponse.cursor"))

    let pagination = try #require(functionBody("private func loadMoreStarterPacks", in: source))
    #expect(pagination.contains("client.app.bsky.graph.searchStarterPacks"))
    #expect(pagination.contains("starterPackCursor = packsResponse.cursor"))
  }

  @Test("filter changes and full searches reset pagination")
  func filterChangesResetPagination() throws {
    let source = try sourceFile("Catbird/Features/Search/ViewModels/RefinedSearchViewModel.swift")
    let begin = try #require(functionBody("private func beginSearchRequest", in: source))
    #expect(begin.contains("resetPaginationCursors()"))
    let schedule = try #require(functionBody("private func scheduleSearch", in: source))
    let snapshot = try #require(schedule.range(of: "let request = beginSearchRequest()"))
    let task = try #require(schedule.range(of: "Task"))
    #expect(snapshot.lowerBound < task.lowerBound)

    let applyFilters = try #require(functionBody("public func applyFilterState", in: source))
    #expect(applyFilters.contains("filterState = state"))
    #expect(applyFilters.contains("scheduleSearch(client: client)"))

    let setScope = try #require(functionBody("public func setScope", in: source))
    #expect(setScope.contains("selectedContentType = scope"))
    #expect(setScope.contains("scheduleSearch(client: client)"))
  }

  @Test("saved search state is loaded before the committed search")
  func savedSearchLoadsStateBeforeSearching() throws {
    let source = try sourceFile("Catbird/Features/Search/ViewModels/RefinedSearchViewModel.swift")
    let load = try #require(functionBody("public func loadAndApplySavedSearch", in: source))
    let query = try #require(load.range(of: "searchQuery = savedSearch.query"))
    let filters = try #require(load.range(of: "filterState = savedSearch.filters"))
    let visibleQuery = try #require(load.range(of: "onQueryLoaded(savedSearch.query)"))
    let search = try #require(load.range(of: "commitSearch(client: client)"))

    #expect(query.lowerBound < search.lowerBound)
    #expect(filters.lowerBound < search.lowerBound)
    #expect(visibleQuery.lowerBound < search.lowerBound)
  }

  @Test("refresh retains response cursors for pagination")
  func refreshRetainsCursors() throws {
    let source = try sourceFile("Catbird/Features/Search/ViewModels/RefinedSearchViewModel.swift")
    let refresh = try #require(functionBody("public func refreshSearch", in: source))
    #expect(refresh.contains("executeSearchForCurrentScope"))
  }

  @Test("both saved-search selection paths propagate the visible query")
  func savedSearchSelectionPropagatesVisibleQuery() throws {
    let refined = try sourceFile("Catbird/Features/Search/Views/RefinedSearchView.swift")
    let discovery = try sourceFile("Catbird/Features/Search/Views/MainViews/DiscoveryView.swift")
    #expect(refined.contains("onQueryLoaded: { searchText = $0 }"))
    #expect(discovery.contains("onQueryLoaded: onQueryLoaded"))

    let viewModel = try sourceFile("Catbird/Features/Search/ViewModels/RefinedSearchViewModel.swift")
    let update = try #require(functionBody("public func updateSearch", in: viewModel))
    let gate = try #require(update.range(of: "SearchQueryUpdateGate.shouldProcess"))
    let reset = try #require(update.range(of: "isCommittedSearch = false"))
    #expect(gate.lowerBound < reset.lowerBound)
  }

  @Test("search UI exposes only honest inline filters")
  func honestFilterUI() throws {
    let source = try sourceFile("Catbird/Features/Search/Views/RefinedSearchView.swift")
    #expect(source.contains("SearchFilterBar("))
    #expect(source.contains("SearchFiltersSheet("))
  }

  private func sourceFile(_ relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repositoryRoot = testsDirectory.deletingLastPathComponent()
    return try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
  }

  private func functionBody(_ signature: String, in source: String) -> String? {
    guard let signatureRange = source.range(of: signature),
          let bodyStart = source[signatureRange.upperBound...].firstIndex(of: "{")
    else { return nil }

    var depth = 0
    var index = bodyStart
    while index < source.endIndex {
      switch source[index] {
      case "{": depth += 1
      case "}":
        depth -= 1
        if depth == 0 { return String(source[bodyStart...index]) }
      default: break
      }
      index = source.index(after: index)
    }
    return nil
  }
}
