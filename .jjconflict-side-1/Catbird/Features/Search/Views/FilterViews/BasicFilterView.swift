import Petrel
import SwiftUI

/// Enum representing date filter options retained for existing search metadata.
public enum FilterDate: String, CaseIterable, Sendable {
  case anytime
  case today
  case week
  case month
  case year

  public var displayName: String {
    switch self {
    case .anytime: return "Anytime"
    case .today: return "Today"
    case .week: return "This week"
    case .month: return "This month"
    case .year: return "This year"
    }
  }

  public var icon: String {
    switch self {
    case .anytime: return "clock"
    case .today: return "calendar.day.timeline.left"
    case .week: return "calendar.badge.clock"
    case .month: return "calendar"
    case .year: return "calendar.circle"
    }
  }
}

/// Enum representing content type filter options (G01 segmentation).
public enum ContentType: String, CaseIterable, Codable, Sendable {
  case top
  case latest
  case people
  case feeds
  case starterPacks

  public var title: String {
    switch self {
    case .top: return "Top"
    case .latest: return "Latest"
    case .people: return "People"
    case .feeds: return "Feeds"
    case .starterPacks: return "Starter Packs"
    }
  }

  public var icon: String {
    switch self {
    case .top: return "sparkles"
    case .latest: return "clock"
    case .people: return "person.2"
    case .feeds: return "number"
    case .starterPacks: return "rectangle.stack.badge.person.crop"
    }
  }

  public var emptyIcon: String {
    switch self {
    case .top: return "text.bubble.slash"
    case .latest: return "text.bubble.slash"
    case .people: return "person.slash"
    case .feeds: return "rectangle.slash"
    case .starterPacks: return "rectangle.stack.badge.person.crop"
    }
  }
}

/// Enum for API-supported search result sorting options.
public enum SearchSort: String, CaseIterable, Codable, Sendable {
  case top
  case latest

  public var displayName: String {
    switch self {
    case .top: return "Top"
    case .latest: return "Latest"
    }
  }

  public var icon: String {
    switch self {
    case .top: return "star.fill"
    case .latest: return "clock.fill"
    }
  }

  public var description: String {
    switch self {
    case .top: return "Most relevant and popular results"
    case .latest: return "Most recent results first"
    }
  }
}

/// Model for language selection options.
public struct LanguageOption: Identifiable, Hashable, Sendable {
  public let id = UUID()
  public let code: String
  public let name: String
  public let isPreferred: Bool

  public var displayName: String { name }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(code)
  }

  public static func == (lhs: LanguageOption, rhs: LanguageOption) -> Bool {
    lhs.code == rhs.code
  }

  public static let supportedLanguages: [LanguageOption] = [
    LanguageOption(code: "en", name: "English", isPreferred: true),
    LanguageOption(code: "es", name: "Spanish", isPreferred: false),
    LanguageOption(code: "ja", name: "Japanese", isPreferred: false),
    LanguageOption(code: "de", name: "German", isPreferred: false),
    LanguageOption(code: "fr", name: "French", isPreferred: false),
    LanguageOption(code: "pt", name: "Portuguese", isPreferred: false),
    LanguageOption(code: "ru", name: "Russian", isPreferred: false),
    LanguageOption(code: "zh", name: "Chinese", isPreferred: false),
    LanguageOption(code: "ko", name: "Korean", isPreferred: false),
    LanguageOption(code: "ar", name: "Arabic", isPreferred: false),
    LanguageOption(code: "hi", name: "Hindi", isPreferred: false),
    LanguageOption(code: "it", name: "Italian", isPreferred: false),
  ]
}
