//
//  SearchFilterState.swift
//  Catbird
//
//  The single source of truth for applied post-search filters.
//  Maps directly onto the app.bsky.feed.searchPostsV2 API schema.
//

import Foundation
import Petrel

/// Reply filtering options for post search.
public enum SearchReplyMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case any
  case excludeReplies
  case repliesOnly

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .any: return "Any replies"
    case .excludeReplies: return "Exclude replies"
    case .repliesOnly: return "Replies only"
    }
  }
}

/// Date-range options for post search, mapped to `since`/`until`.
public enum SearchDateRange: String, Codable, CaseIterable, Identifiable, Sendable {
  case anytime
  case today
  case week
  case month
  case year
  case custom

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .anytime: return "Anytime"
    case .today: return "Today"
    case .week: return "This week"
    case .month: return "This month"
    case .year: return "This year"
    case .custom: return "Custom range"
    }
  }
}

/// Applied search filters that map directly onto real searchPostsV2 parameters.
public struct SearchFilterState: Codable, Equatable, Sendable {
  public var sort: SearchSort = .top
  public var author: String?
  public var mentions: String?
  public var domain: String?
  public var url: String?
  public var hashtag: String?

  public var excludeAuthor: String?
  public var excludeMentions: String?
  public var excludeDomain: String?
  public var excludeURL: String?
  public var excludeHashtag: String?

  public var dateRange: SearchDateRange = .anytime
  public var customStartDate: Date?
  public var customEndDate: Date?

  /// BCP-47 language code (single). `nil` == any language.
  public var language: String?

  public var replyMode: SearchReplyMode = .any
  public var hasMedia: Bool = false
  public var hasVideo: Bool = false
  public var following: Bool = false

  public init(
    sort: SearchSort = .top,
    author: String? = nil,
    mentions: String? = nil,
    domain: String? = nil,
    url: String? = nil,
    hashtag: String? = nil,
    excludeAuthor: String? = nil,
    excludeMentions: String? = nil,
    excludeDomain: String? = nil,
    excludeURL: String? = nil,
    excludeHashtag: String? = nil,
    dateRange: SearchDateRange = .anytime,
    customStartDate: Date? = nil,
    customEndDate: Date? = nil,
    language: String? = nil,
    replyMode: SearchReplyMode = .any,
    hasMedia: Bool = false,
    hasVideo: Bool = false,
    following: Bool = false
  ) {
    self.sort = sort
    self.author = author
    self.mentions = mentions
    self.domain = domain
    self.url = url
    self.hashtag = hashtag
    self.excludeAuthor = excludeAuthor
    self.excludeMentions = excludeMentions
    self.excludeDomain = excludeDomain
    self.excludeURL = excludeURL
    self.excludeHashtag = excludeHashtag
    self.dateRange = dateRange
    self.customStartDate = customStartDate
    self.customEndDate = customEndDate
    self.language = language
    self.replyMode = replyMode
    self.hasMedia = hasMedia
    self.hasVideo = hasVideo
    self.following = following
  }

  // MARK: - Active Filter Counting & Categories

  /// Number of active filter categories (sort is a mode/tab, not a filter category).
  public var activeFilterCount: Int {
    var count = 0
    if hasAuthorFilter { count += 1 }
    if hasMentionsFilter { count += 1 }
    if hasDomainFilter { count += 1 }
    if hasURLFilter { count += 1 }
    if hasHashtagFilter { count += 1 }
    if hasDateFilter { count += 1 }
    if hasLanguageFilter { count += 1 }
    if replyMode != .any { count += 1 }
    if hasMedia { count += 1 }
    if hasVideo { count += 1 }
    if following { count += 1 }
    return count
  }

  public var hasAuthorFilter: Bool {
    isNonEmpty(author) || isNonEmpty(excludeAuthor)
  }

  public var hasMentionsFilter: Bool {
    isNonEmpty(mentions) || isNonEmpty(excludeMentions)
  }

  public var hasDomainFilter: Bool {
    isNonEmpty(domain) || isNonEmpty(excludeDomain)
  }

  public var hasURLFilter: Bool {
    isNonEmpty(url) || isNonEmpty(excludeURL)
  }

  public var hasHashtagFilter: Bool {
    isNonEmpty(hashtag) || isNonEmpty(excludeHashtag)
  }

  public var hasDateFilter: Bool {
    switch dateRange {
    case .anytime:
      return false
    case .today, .week, .month, .year:
      return true
    case .custom:
      return customStartDate != nil || customEndDate != nil
    }
  }

  public var hasLanguageFilter: Bool {
    isNonEmpty(language)
  }

  /// Returns true when post-specific filters are active.
  /// Note: Language is general and does not restrict result scopes, matching social-app's POST_ONLY_FILTER_KEYS.
  public var hasPostOnlyFilters: Bool {
    hasAuthorFilter ||
      hasMentionsFilter ||
      hasDomainFilter ||
      hasURLFilter ||
      hasHashtagFilter ||
      hasDateFilter ||
      replyMode != .any ||
      hasMedia ||
      hasVideo ||
      following
  }

  /// True when nothing deviates from the neutral default (top + no filters).
  public var isDefault: Bool {
    activeFilterCount == 0 && sort == .top
  }

  /// API `sort` string ("top" | "latest").
  public var sortValue: String { sort.rawValue }

  /// API `lang` container, or nil for any language.
  public var languageContainer: LanguageCodeContainer? {
    language.flatMap { l in
      let trimmed = l.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : LanguageCodeContainer(languageCode: trimmed)
    }
  }

  // MARK: - Validation

  public var isValid: Bool {
    authorValidationError == nil &&
      mentionsValidationError == nil &&
      domainValidationError == nil &&
      urlValidationError == nil &&
      excludeAuthorValidationError == nil &&
      excludeMentionsValidationError == nil &&
      excludeDomainValidationError == nil &&
      excludeURLValidationError == nil
  }

  public var authorValidationError: String? {
    Self.validateIdentifier(author, fieldName: "Author")
  }

  public var mentionsValidationError: String? {
    Self.validateIdentifier(mentions, fieldName: "Mentions")
  }

  public var excludeAuthorValidationError: String? {
    Self.validateIdentifier(excludeAuthor, fieldName: "Exclude Author")
  }

  public var excludeMentionsValidationError: String? {
    Self.validateIdentifier(excludeMentions, fieldName: "Exclude Mentions")
  }

  public var domainValidationError: String? {
    Self.validateDomain(domain, fieldName: "Domain")
  }

  public var excludeDomainValidationError: String? {
    Self.validateDomain(excludeDomain, fieldName: "Exclude Domain")
  }

  public var urlValidationError: String? {
    Self.validateURL(url, fieldName: "URL")
  }

  public var excludeURLValidationError: String? {
    Self.validateURL(excludeURL, fieldName: "Exclude URL")
  }

  private static func validateIdentifier(_ value: String?, fieldName: String) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    let sanitized = value.hasPrefix("@") ? String(value.dropFirst()) : value
    if sanitized.isEmpty {
      return "\(fieldName) cannot be empty"
    }
    do {
      _ = try ATIdentifier(string: sanitized)
      return nil
    } catch {
      return "\(fieldName) must be a valid handle or DID (e.g. alice.bsky.social or did:plc:...)"
    }
  }

  private static func validateDomain(_ value: String?, fieldName: String) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    if value.contains(" ") || value.contains("/") || value.contains(":") {
      return "\(fieldName) must be a valid domain (e.g. nytimes.com)"
    }
    return nil
  }

  private static func validateURL(_ value: String?, fieldName: String) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    guard let url = URL(string: value), url.scheme != nil, (try? URI(uriString: value)) != nil else {
      return "\(fieldName) must be a valid URL with scheme (e.g. https://...)"
    }
    return nil
  }

  // MARK: - Mutating Helpers

  public mutating func reset() {
    self = SearchFilterState()
  }

  /// Selects a range and ensures a custom range owns concrete editable dates.
  public mutating func selectDateRange(
    _ range: SearchDateRange,
    now: Date = Date(),
    calendar: Calendar = .current
  ) {
    dateRange = range
    if range == .custom {
      if customStartDate == nil && customEndDate == nil {
        customStartDate = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        customEndDate = now
      }
    } else {
      customStartDate = nil
      customEndDate = nil
    }
  }

  /// Maps `dateRange` (+ custom dates) to API `since`/`until` ISO8601 strings.
  /// The API's `until` bound is exclusive, while the UI's end date is inclusive.
  public func dateBounds(
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
      guard let start = customStartDate, let end = customEndDate else {
        return (nil, nil)
      }
      let (earlier, later) = start <= end ? (start, end) : (end, start)
      let inclusiveEnd = calendar.date(byAdding: .day, value: 1, to: later) ?? later
      return (Self.iso(earlier), Self.iso(inclusiveEnd))
    }
  }

  // MARK: - SearchPostsV2 Parameters Mapping

  public func toSearchPostsV2Parameters(
    query: String,
    cursor: String? = nil,
    limit: Int = 25
  ) -> AppBskyFeedSearchPostsV2.Parameters {
    let bounds = dateBounds()

    let languagesList: [LanguageCodeContainer]? = language.flatMap { l in
      let clean = l.trimmingCharacters(in: .whitespacesAndNewlines)
      return clean.isEmpty ? nil : [LanguageCodeContainer(languageCode: clean)]
    }

    let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

    return AppBskyFeedSearchPostsV2.Parameters(
      cursor: cursor,
      limit: limit,
      query: cleanQuery.isEmpty ? nil : cleanQuery,
      sort: sort.rawValue,
      authors: Self.identifierList(author),
      mentions: Self.identifierList(mentions),
      domains: Self.trimmedList(domain),
      urls: Self.uriList(url),
      hashtags: Self.hashtagList(hashtag),
      excludeAuthors: Self.identifierList(excludeAuthor),
      excludeMentions: Self.identifierList(excludeMentions),
      excludeDomains: Self.trimmedList(excludeDomain),
      excludeUrls: Self.uriList(excludeURL),
      excludeHashtags: Self.hashtagList(excludeHashtag),
      since: bounds.since,
      until: bounds.until,
      languages: languagesList,
      hasMedia: hasMedia ? true : nil,
      hasVideo: hasVideo ? true : nil,
      excludeReplies: replyMode == .excludeReplies ? true : nil,
      repliesOnly: replyMode == .repliesOnly ? true : nil,
      following: following ? true : nil
    )
  }

  // MARK: - Private Helpers

  private func isNonEmpty(_ string: String?) -> Bool {
    guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines) else {
      return false
    }
    return !string.isEmpty
  }
  private static func identifierList(_ value: String?) -> [ATIdentifier]? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    let sanitized = value.hasPrefix("@") ? String(value.dropFirst()) : value
    guard !sanitized.isEmpty, let id = try? ATIdentifier(string: sanitized) else { return nil }
    return [id]
  }

  private static func trimmedList(_ value: String?) -> [String]? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return [value]
  }

  private static func uriList(_ value: String?) -> [URI]? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
          let uri = try? URI(uriString: value) else { return nil }
    return [uri]
  }

  private static func hashtagList(_ value: String?) -> [String]? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    let sanitized = value.hasPrefix("#") ? String(value.dropFirst()) : value
    return sanitized.isEmpty ? nil : [sanitized]
  }

  private static func daysAgo(_ days: Int, from date: Date, calendar: Calendar) -> Date {
    calendar.date(byAdding: .day, value: -days, to: date) ?? date
  }

  private static func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  // MARK: - Codable Decoding with Fallbacks

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sort = try container.decodeIfPresent(SearchSort.self, forKey: .sort) ?? .top
    author = try container.decodeIfPresent(String.self, forKey: .author)
    mentions = try container.decodeIfPresent(String.self, forKey: .mentions)
    domain = try container.decodeIfPresent(String.self, forKey: .domain)
    url = try container.decodeIfPresent(String.self, forKey: .url)
    hashtag = try container.decodeIfPresent(String.self, forKey: .hashtag)
    excludeAuthor = try container.decodeIfPresent(String.self, forKey: .excludeAuthor)
    excludeMentions = try container.decodeIfPresent(String.self, forKey: .excludeMentions)
    excludeDomain = try container.decodeIfPresent(String.self, forKey: .excludeDomain)
    excludeURL = try container.decodeIfPresent(String.self, forKey: .excludeURL)
    excludeHashtag = try container.decodeIfPresent(String.self, forKey: .excludeHashtag)
    dateRange = try container.decodeIfPresent(SearchDateRange.self, forKey: .dateRange) ?? .anytime
    customStartDate = try container.decodeIfPresent(Date.self, forKey: .customStartDate)
    customEndDate = try container.decodeIfPresent(Date.self, forKey: .customEndDate)
    language = try container.decodeIfPresent(String.self, forKey: .language)
    replyMode = try container.decodeIfPresent(SearchReplyMode.self, forKey: .replyMode) ?? .any
    hasMedia = try container.decodeIfPresent(Bool.self, forKey: .hasMedia) ?? false
    hasVideo = try container.decodeIfPresent(Bool.self, forKey: .hasVideo) ?? false
    following = try container.decodeIfPresent(Bool.self, forKey: .following) ?? false
  }
}
