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

  @Test("all post search paths use the supported parameter builder")
  func postSearchPathsUseSupportedParameters() throws {
    let source = try sourceFile("Catbird/Features/Search/ViewModels/RefinedSearchViewModel.swift")
    let builder = try #require(functionBody("private func buildPostSearchParameters", in: source))

    #expect(builder.contains("sort: request.filters.sortValue"))
    #expect(builder.contains("since: bounds.since"))
    #expect(builder.contains("until: bounds.until"))
    #expect(builder.contains("lang: request.filters.languageContainer"))
    #expect(builder.contains("cursor: cursor"))

    let initialSearch = try #require(functionBody("private func searchPosts", in: source))
    #expect(initialSearch.contains("buildPostSearchParameters(request: request, cursor: cursor)"))

    let pagination = try #require(functionBody("private func loadMorePosts", in: source))
    #expect(pagination.contains("buildPostSearchParameters(request: request, cursor: cursor)"))
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

    let applyFilters = try #require(functionBody("func applyFilterState", in: source))
    #expect(applyFilters.contains("filterState = state"))
    #expect(applyFilters.contains("scheduleSearch(client: client)"))

    let setSort = try #require(functionBody("func setSort", in: source))
    #expect(setSort.contains("filterState.sort = sort"))
    #expect(setSort.contains("scheduleSearch(client: client)"))
  }

  @Test("saved search state is loaded before the committed search")
  func savedSearchLoadsStateBeforeSearching() throws {
    let source = try sourceFile("Catbird/Features/Search/ViewModels/RefinedSearchViewModel.swift")
    let load = try #require(functionBody("func loadAndApplySavedSearch", in: source))
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
    let refresh = try #require(functionBody("func refreshSearch", in: source))
    #expect(refresh.contains("newProfileCursor = actorsResponse.cursor"))
    #expect(refresh.contains("newPostCursor = postsResponse.cursor"))
    #expect(refresh.contains("newFeedCursor = feedsResponse.cursor"))
    #expect(refresh.contains("guard requestGeneration.accepts(request)"))
  }

  @Test("both saved-search selection paths propagate the visible query")
  func savedSearchSelectionPropagatesVisibleQuery() throws {
    let refined = try sourceFile("Catbird/Features/Search/Views/RefinedSearchView.swift")
    let discovery = try sourceFile("Catbird/Features/Search/Views/MainViews/DiscoveryView.swift")
    #expect(refined.contains("onQueryLoaded: { searchText = $0 }"))
    #expect(discovery.contains("onQueryLoaded: onQueryLoaded"))

    let viewModel = try sourceFile("Catbird/Features/Search/ViewModels/RefinedSearchViewModel.swift")
    let update = try #require(functionBody("func updateSearch", in: viewModel))
    let gate = try #require(update.range(of: "SearchQueryUpdateGate.shouldProcess"))
    let reset = try #require(update.range(of: "isCommittedSearch = false"))
    #expect(gate.lowerBound < reset.lowerBound)
  }

  @Test("search UI exposes only honest inline filters")
  func honestFilterUI() throws {
    let source = try sourceFile("Catbird/Features/Search/Views/RefinedSearchView.swift")
    #expect(source.contains("SearchFilterBar("))
    #expect(source.contains("SearchFiltersSheet("))
    #expect(!source.contains("AdvancedFilterView("))
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
