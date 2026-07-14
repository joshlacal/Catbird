import Petrel
import SwiftUI

/// Enum representing date filter options retained for existing search metadata.
enum FilterDate: String, CaseIterable {
  case anytime
  case today
  case week
  case month
  case year

  var displayName: String {
    switch self {
    case .anytime: return "Anytime"
    case .today: return "Today"
    case .week: return "This week"
    case .month: return "This month"
    case .year: return "This year"
    }
  }

  var icon: String {
    switch self {
    case .anytime: return "clock"
    case .today: return "calendar.day.timeline.left"
    case .week: return "calendar.badge.clock"
    case .month: return "calendar"
    case .year: return "calendar.circle"
    }
  }
}

/// Enum representing content type filter options.
enum ContentType: String, CaseIterable {
  case all
  case profiles
  case posts
  case feeds

  var title: String {
    switch self {
    case .all: return "All"
    case .profiles: return "Profiles"
    case .posts: return "Posts"
    case .feeds: return "Feeds"
    }
  }

  var icon: String {
    switch self {
    case .all: return "rectangle.grid.2x2"
    case .profiles: return "person"
    case .posts: return "text.bubble"
    case .feeds: return "rectangle.grid.1x2"
    }
  }

  var emptyIcon: String {
    switch self {
    case .all: return "magnifyingglass"
    case .profiles: return "person.slash"
    case .posts: return "text.bubble.slash"
    case .feeds: return "rectangle.slash"
    }
  }
}

/// Enum for API-supported search result sorting options.
enum SearchSort: String, CaseIterable, Codable {
  case top
  case latest

  var displayName: String {
    switch self {
    case .top: return "Top"
    case .latest: return "Latest"
    }
  }

  var icon: String {
    switch self {
    case .top: return "star.fill"
    case .latest: return "clock.fill"
    }
  }

  var description: String {
    switch self {
    case .top: return "Most relevant and popular results"
    case .latest: return "Most recent results first"
    }
  }
}

/// Model for language selection options.
struct LanguageOption: Identifiable, Hashable {
  let id = UUID()
  let code: String
  let name: String
  let isPreferred: Bool

  var displayName: String { name }

  func hash(into hasher: inout Hasher) {
    hasher.combine(code)
  }

  static func == (lhs: LanguageOption, rhs: LanguageOption) -> Bool {
    lhs.code == rhs.code
  }

  static let supportedLanguages: [LanguageOption] = [
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
