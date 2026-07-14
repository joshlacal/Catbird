import Foundation
import Testing
@testable import Catbird

@Suite("SearchFilterState")
struct SearchFilterStateTests {
  @Test("default state is the neutral default")
  func defaultState() {
    let s = SearchFilterState()
    #expect(s.sort == .top)
    #expect(s.dateRange == .anytime)
    #expect(s.language == nil)
    #expect(s.activeFilterCount == 0)
    #expect(s.isDefault)
    #expect(s.sortValue == "top")
  }

  @Test("active filter count counts date range and language, not sort")
  func activeCount() {
    var s = SearchFilterState()
    s.sort = .latest
    #expect(s.activeFilterCount == 0)
    #expect(!s.isDefault)
    s.dateRange = .week
    #expect(s.activeFilterCount == 1)
    s.language = "en"
    #expect(s.activeFilterCount == 2)
  }

  @Test("sortValue maps to the API string")
  func sortValue() {
    var s = SearchFilterState()
    #expect(s.sortValue == "top")
    s.sort = .latest
    #expect(s.sortValue == "latest")
  }

  @Test("anytime produces no date bounds")
  func anytimeBounds() {
    let b = SearchFilterState().dateBounds()
    #expect(b.since == nil)
    #expect(b.until == nil)
  }

  @Test("week sets since ~7 days before now and no until")
  func weekBounds() throws {
    let now = Date(timeIntervalSince1970: 1_600_000_000)
    var s = SearchFilterState()
    s.dateRange = .week
    let b = s.dateBounds(now: now)
    #expect(b.until == nil)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let sinceString = try #require(b.since)
    let since = try #require(formatter.date(from: sinceString))
    let expected = Calendar.current.date(byAdding: .day, value: -7, to: now)!
    #expect(abs(since.timeIntervalSince(expected)) < 1.0)
  }

  @Test("custom range emits both bounds from provided dates")
  func customBounds() {
    var s = SearchFilterState()
    s.dateRange = .custom
    s.customStartDate = Date(timeIntervalSince1970: 1_000_000)
    s.customEndDate = Date(timeIntervalSince1970: 2_000_000)
    let b = s.dateBounds()
    #expect(b.since != nil)
    #expect(b.until != nil)
  }

  @Test("custom range with no dates emits no bounds")
  func customBoundsEmpty() {
    var s = SearchFilterState()
    s.dateRange = .custom
    let b = s.dateBounds()
    #expect(b.since == nil)
    #expect(b.until == nil)
  }

  @Test("custom range includes the selected end day")
  func customRangeIncludesEndDay() throws {
    let calendar = Calendar(identifier: .gregorian)
    let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 10)))
    let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 12)))
    var s = SearchFilterState()
    s.dateRange = .custom
    s.customStartDate = start
    s.customEndDate = end

    let bounds = s.dateBounds(calendar: calendar)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let until = try #require(bounds.until.flatMap(formatter.date(from:)))
    #expect(until == calendar.date(byAdding: .day, value: 1, to: end))
  }

  @Test("reversed custom range is normalized before request")
  func reversedCustomRangeIsNormalized() throws {
    let calendar = Calendar(identifier: .gregorian)
    let earlier = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 10)))
    let later = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 12)))
    var s = SearchFilterState()
    s.dateRange = .custom
    s.customStartDate = later
    s.customEndDate = earlier

    let bounds = s.dateBounds(calendar: calendar)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    #expect(bounds.since.flatMap(formatter.date(from:)) == earlier)
    #expect(bounds.until.flatMap(formatter.date(from:)) == calendar.date(byAdding: .day, value: 1, to: later))
  }

  @Test("selecting custom initializes stored dates")
  func selectingCustomInitializesDates() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var s = SearchFilterState()
    s.selectDateRange(.custom, now: now)
    #expect(s.dateRange == .custom)
    #expect(s.customStartDate != nil)
    #expect(s.customEndDate != nil)
  }

  @Test("language container is built from the code")
  func languageContainer() {
    var s = SearchFilterState()
    #expect(s.languageContainer == nil)
    s.language = "ja"
    #expect(s.languageContainer != nil)
  }

  @Test("codable round trips")
  func codableRoundTrip() throws {
    var s = SearchFilterState()
    s.sort = .latest
    s.dateRange = .month
    s.language = "es"
    let data = try JSONEncoder().encode(s)
    let back = try JSONDecoder().decode(SearchFilterState.self, from: data)
    #expect(back == s)
  }

  @Test("legacy AdvancedSearchParams JSON no longer decodes into SavedSearch (reset, not migrated)")
  func legacySavedSearchResets() {
    let legacy = """
    [{"id":"00000000-0000-0000-0000-000000000000","name":"AI",\
    "query":"ai","filters":{"excludeReplies":false,"sortBy":"latest",\
    "dateRange":"week","relevanceBoost":"balanced"},\
    "createdAt":0,"lastUsed":0}]
    """.data(using: .utf8)!
    #expect((try? JSONDecoder().decode([SavedSearch].self, from: legacy)) == nil)
  }
}
