import Foundation
import Petrel
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
    #expect(s.isValid)
    #expect(!s.hasPostOnlyFilters)
  }

  @Test("advanced filter count covers every category")
  func advancedFilterCountCoversEveryCategory() {
    var s = SearchFilterState()
    #expect(s.activeFilterCount == 0)

    s.author = "alice.bsky.social"
    #expect(s.activeFilterCount == 1)

    s.mentions = "bob.bsky.social"
    #expect(s.activeFilterCount == 2)

    s.domain = "nytimes.com"
    #expect(s.activeFilterCount == 3)

    s.url = "https://example.com/article"
    #expect(s.activeFilterCount == 4)

    s.hashtag = "swift"
    #expect(s.activeFilterCount == 5)

    s.dateRange = .week
    #expect(s.activeFilterCount == 6)

    s.language = "ja"
    #expect(s.activeFilterCount == 7)

    s.replyMode = .excludeReplies
    #expect(s.activeFilterCount == 8)

    s.hasMedia = true
    #expect(s.activeFilterCount == 9)

    s.hasVideo = true
    #expect(s.activeFilterCount == 10)

    s.following = true
    #expect(s.activeFilterCount == 11)
  }

  @Test("reply modes are mutually exclusive")
  func replyModesAreMutuallyExclusive() {
    var s = SearchFilterState()
    #expect(s.replyMode == .any)

    s.replyMode = .excludeReplies
    let excludeParams = s.toSearchPostsV2Parameters(query: "test")
    #expect(excludeParams.excludeReplies == true)
    #expect(excludeParams.repliesOnly == nil)

    s.replyMode = .repliesOnly
    let onlyParams = s.toSearchPostsV2Parameters(query: "test")
    #expect(onlyParams.excludeReplies == nil)
    #expect(onlyParams.repliesOnly == true)

    s.replyMode = .any
    let anyParams = s.toSearchPostsV2Parameters(query: "test")
    #expect(anyParams.excludeReplies == nil)
    #expect(anyParams.repliesOnly == nil)
  }

  @Test("invalid identifiers and URLs are rejected")
  func invalidIdentifiersAndURLsAreRejected() {
    var s = SearchFilterState()
    #expect(s.isValid)

    s.author = "invalid handle with spaces"
    #expect(!s.isValid)
    #expect(s.authorValidationError != nil)

    s.author = "alice.bsky.social"
    #expect(s.isValid)
    #expect(s.authorValidationError == nil)

    s.url = "not-a-valid-url"
    #expect(!s.isValid)
    #expect(s.urlValidationError != nil)

    s.url = "https://bsky.app"
    #expect(s.isValid)
    #expect(s.urlValidationError == nil)

    s.domain = "domain with space"
    #expect(!s.isValid)
    #expect(s.domainValidationError != nil)
  }

  @Test("reset produces neutral state")
  func resetProducesNeutralState() {
    var s = SearchFilterState()
    s.sort = .latest
    s.author = "alice.bsky.social"
    s.mentions = "bob.bsky.social"
    s.domain = "nytimes.com"
    s.url = "https://example.com"
    s.hashtag = "news"
    s.dateRange = .month
    s.language = "es"
    s.replyMode = .repliesOnly
    s.hasMedia = true
    s.hasVideo = true
    s.following = true

    #expect(s.activeFilterCount > 0)
    #expect(!s.isDefault)

    s.reset()

    #expect(s.sort == .top)
    #expect(s.author == nil)
    #expect(s.mentions == nil)
    #expect(s.domain == nil)
    #expect(s.url == nil)
    #expect(s.hashtag == nil)
    #expect(s.dateRange == .anytime)
    #expect(s.customStartDate == nil)
    #expect(s.customEndDate == nil)
    #expect(s.language == nil)
    #expect(s.replyMode == .any)
    #expect(s.hasMedia == false)
    #expect(s.hasVideo == false)
    #expect(s.following == false)
    #expect(s.activeFilterCount == 0)
    #expect(s.isDefault)
  }

  @Test("codable round trip preserves advanced filters")
  func codableRoundTripPreservesAdvancedFilters() throws {
    var s = SearchFilterState()
    s.sort = .latest
    s.author = "alice.bsky.social"
    s.mentions = "bob.bsky.social"
    s.domain = "github.com"
    s.url = "https://github.com/swiftlang/swift"
    s.hashtag = "swift"
    s.excludeAuthor = "spammer.bsky.social"
    s.excludeDomain = "spam.com"
    s.dateRange = .month
    s.language = "en"
    s.replyMode = .excludeReplies
    s.hasMedia = true
    s.hasVideo = false
    s.following = true

    let data = try JSONEncoder().encode(s)
    let decoded = try JSONDecoder().decode(SearchFilterState.self, from: data)

    #expect(decoded == s)
    #expect(decoded.author == "alice.bsky.social")
    #expect(decoded.mentions == "bob.bsky.social")
    #expect(decoded.domain == "github.com")
    #expect(decoded.url == "https://github.com/swiftlang/swift")
    #expect(decoded.hashtag == "swift")
    #expect(decoded.excludeAuthor == "spammer.bsky.social")
    #expect(decoded.excludeDomain == "spam.com")
    #expect(decoded.dateRange == .month)
    #expect(decoded.language == "en")
    #expect(decoded.replyMode == .excludeReplies)
    #expect(decoded.hasMedia == true)
    #expect(decoded.following == true)
    #expect(decoded.activeFilterCount == s.activeFilterCount)
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
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
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
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
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
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
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

  @Test("legacy AdvancedSearchParams JSON decodes into SavedSearch with backward-compatible defaults")
  func legacySavedSearchDecodesWithDefaults() throws {
    let legacy = """
    [{"id":"00000000-0000-0000-0000-000000000000","name":"AI",\
    "query":"ai","filters":{"excludeReplies":false,"sortBy":"latest",\
    "dateRange":"week","relevanceBoost":"balanced"},\
    "createdAt":0,"lastUsed":0}]
    """.data(using: .utf8)!
    let saved = try JSONDecoder().decode([SavedSearch].self, from: legacy)
    #expect(saved.count == 1)
    let first = try #require(saved.first)
    #expect(first.id == UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    #expect(first.name == "AI")
    #expect(first.query == "ai")
    #expect(first.filters.dateRange == .week)
    #expect(first.filters.replyMode == .any)
    #expect(first.filters.hasMedia == false)
    #expect(first.filters.hasVideo == false)
    #expect(first.filters.following == false)
    #expect(first.filters.author == nil)
  }
}
