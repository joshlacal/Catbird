//
//  SearchFilterState.swift
//  Catbird
//
//  The single source of truth for applied post-search filters.
//  Only fields the app.bsky.feed.searchPosts API actually honors.
//

import Foundation
import Petrel

/// Date-range options for post search, mapped to `since`/`until`.
enum SearchDateRange: String, Codable, CaseIterable, Identifiable, Sendable {
  case anytime
  case today
  case week
  case month
  case year
  case custom

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .anytime: return "Any time"
    case .today: return "Past 24 hours"
    case .week: return "Past week"
    case .month: return "Past month"
    case .year: return "Past year"
    case .custom: return "Custom range"
    }
  }
}

/// Applied search filters that map directly onto real searchPosts parameters.
struct SearchFilterState: Codable, Equatable, Sendable {
  var sort: SearchSort = .top
  var dateRange: SearchDateRange = .anytime
  var customStartDate: Date?
  var customEndDate: Date?
  /// BCP-47 language code (single). `nil` == any language.
  var language: String?

  /// Number of active *filters* (sort is a mode, not a filter).
  var activeFilterCount: Int {
    var count = 0
    if dateRange != .anytime { count += 1 }
    if language != nil { count += 1 }
    return count
  }

  /// True when nothing deviates from the neutral default (top + no filters).
  var isDefault: Bool {
    activeFilterCount == 0 && sort == .top
  }

  /// API `sort` string ("top" | "latest").
  var sortValue: String { sort.rawValue }

  /// API `lang` container, or nil for any language.
  var languageContainer: LanguageCodeContainer? {
    language.map { LanguageCodeContainer(languageCode: $0) }
  }

  /// Selects a range and ensures a custom range owns concrete editable dates.
  mutating func selectDateRange(
    _ range: SearchDateRange,
    now: Date = Date(),
    calendar: Calendar = .current
  ) {
    dateRange = range
    guard range == .custom else { return }
    let today = calendar.startOfDay(for: now)
    if customStartDate == nil { customStartDate = today }
    if customEndDate == nil { customEndDate = today }
  }

  /// Maps `dateRange` (+ custom dates) to API `since`/`until` ISO8601 strings.
  /// The API's `until` bound is exclusive, while the UI's end date is inclusive.
  func dateBounds(
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> (since: String?, until: String?) {
    switch dateRange {
    case .anytime:
      return (nil, nil)
    case .today:
      return (Self.iso(Self.daysAgo(1, from: now, calendar: calendar)), nil)
    case .week:
      return (Self.iso(Self.daysAgo(7, from: now, calendar: calendar)), nil)
    case .month:
      return (Self.iso(Self.daysAgo(30, from: now, calendar: calendar)), nil)
    case .year:
      return (Self.iso(Self.daysAgo(365, from: now, calendar: calendar)), nil)
    case .custom:
      var start = customStartDate.map(calendar.startOfDay(for:))
      var end = customEndDate.map(calendar.startOfDay(for:))
      if let resolvedStart = start, let resolvedEnd = end, resolvedStart > resolvedEnd {
        swap(&start, &end)
      }
      let exclusiveEnd = end.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
      return (start.map(Self.iso), exclusiveEnd.map(Self.iso))
    }
  }

  private static func daysAgo(_ days: Int, from date: Date, calendar: Calendar) -> Date {
    calendar.date(byAdding: .day, value: -days, to: date) ?? date
  }

  private static func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }
}
