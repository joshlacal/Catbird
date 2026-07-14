import Foundation
import Testing

@Suite("Search filter wiring")
struct SearchFilterWiringTests {
  @Test("all post search paths use the supported parameter builder")
  func postSearchPathsUseSupportedParameters() throws {
    let source = try sourceFile("Catbird/Features/Search/ViewModels/RefinedSearchViewModel.swift")
    let builder = try #require(functionBody("private func buildPostSearchParameters", in: source))

    #expect(builder.contains("sort: filterState.sortValue"))
    #expect(builder.contains("since: bounds.since"))
    #expect(builder.contains("until: bounds.until"))
    #expect(builder.contains("lang: filterState.languageContainer"))
    #expect(builder.contains("cursor: cursor"))

    let initialSearch = try #require(functionBody("private func searchPosts", in: source))
    #expect(initialSearch.contains("buildPostSearchParameters(cursor: postCursor)"))

    let pagination = try #require(functionBody("private func loadMorePosts", in: source))
    #expect(pagination.contains("buildPostSearchParameters(cursor: cursor)"))
  }

  @Test("filter changes and full searches reset pagination")
  func filterChangesResetPagination() throws {
    let source = try sourceFile("Catbird/Features/Search/ViewModels/RefinedSearchViewModel.swift")
    let executeSearch = try #require(functionBody("private func executeSearch", in: source))
    let taskGroup = try #require(executeSearch.range(of: "withTaskGroup"))

    for cursor in ["profileCursor", "postCursor", "feedCursor", "starterPackCursor"] {
      let reset = try #require(executeSearch.range(of: "\(cursor) = nil"))
      #expect(reset.lowerBound < taskGroup.lowerBound)
    }

    let applyFilters = try #require(functionBody("func applyFilterState", in: source))
    #expect(applyFilters.contains("filterState = state"))
    #expect(applyFilters.contains("executeSearch(client: client)"))

    let setSort = try #require(functionBody("func setSort", in: source))
    #expect(setSort.contains("filterState.sort = sort"))
    #expect(setSort.contains("executeSearch(client: client)"))
  }

  @Test("saved search state is loaded before the committed search")
  func savedSearchLoadsStateBeforeSearching() throws {
    let source = try sourceFile("Catbird/Features/Search/ViewModels/RefinedSearchViewModel.swift")
    let load = try #require(functionBody("func loadAndApplySavedSearch", in: source))
    let query = try #require(load.range(of: "searchQuery = savedSearch.query"))
    let filters = try #require(load.range(of: "filterState = savedSearch.filters"))
    let search = try #require(load.range(of: "commitSearch(client: client)"))

    #expect(query.lowerBound < search.lowerBound)
    #expect(filters.lowerBound < search.lowerBound)
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
