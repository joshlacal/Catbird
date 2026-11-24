import Petrel
import SwiftUI

/// Enum representing date filter options retained for existing search metadata.
public enum FilterDate: String, CaseIterable, Sendable {
  case anytime
  case today
  case week
  case month
  case year

  public var localizedDisplayName: LocalizedStringResource {
    switch self {
    case .anytime:
      return LocalizedStringResource("Anytime", comment: "Search date filter option for all dates")
    case .today:
      return LocalizedStringResource("Today", comment: "Search date filter option for posts from today")
    case .week:
      return LocalizedStringResource("This week", comment: "Search date filter option for posts from the past week")
    case .month:
      return LocalizedStringResource("This month", comment: "Search date filter option for posts from the past month")
    case .year:
      return LocalizedStringResource("This year", comment: "Search date filter option for posts from the past year")
    }
  }

  public var displayName: String {
    String(localized: localizedDisplayName)
  }

  public var icon: String {
    switch self {
    case .anytime: return "clock"
    case .today: return "calendar.day.timeline.leading"
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

  public var localizedTitle: LocalizedStringResource {
    switch self {
    case .top:
      return LocalizedStringResource("Top", comment: "Search results scope tab for top posts")
    case .latest:
      return LocalizedStringResource("Latest", comment: "Search results scope tab for latest posts")
    case .people:
      return LocalizedStringResource("People", comment: "Search results scope tab for user profiles")
    case .feeds:
      return LocalizedStringResource("Feeds", comment: "Search results scope tab for custom feeds")
    case .starterPacks:
      return LocalizedStringResource("Starter Packs", comment: "Search results scope tab for starter packs")
    }
  }

  public var title: String {
    String(localized: localizedTitle)
  }

  /// Label for the native scope bar. Five scopes share one iPhone-width bar, so
  /// "Starter Packs" is shortened there; results and filters keep `title`.
  public var localizedScopeTitle: LocalizedStringResource {
    switch self {
    case .starterPacks:
      return LocalizedStringResource("Packs", comment: "Search scope for starter packs")
    default:
      return localizedTitle
    }
  }

  public var scopeTitle: String {
    String(localized: localizedScopeTitle)
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

/// UI sort modes for post search results.
public enum SearchSort: String, CaseIterable, Codable, Sendable {
  case top
  case latest

  /// Sort value accepted by `app.bsky.feed.searchPostsV2`.
  public var searchPostsV2Value: String {
    switch self {
    case .top: return "top"
    case .latest: return "recent"
    }
  }

  public var localizedDisplayName: LocalizedStringResource {
    switch self {
    case .top:
      return LocalizedStringResource("Top", comment: "Sort order for most relevant search results")
    case .latest:
      return LocalizedStringResource("Latest", comment: "Sort order for most recent search results")
    }
  }

  public var displayName: String {
    String(localized: localizedDisplayName)
  }

  public var icon: String {
    switch self {
    case .top: return "star.fill"
    case .latest: return "clock.fill"
    }
  }

  public var localizedDescription: LocalizedStringResource {
    switch self {
    case .top:
      return LocalizedStringResource(
        "Most relevant and popular results",
        comment: "Description of the Top search sort mode"
      )
    case .latest:
      return LocalizedStringResource(
        "Most recent results first",
        comment: "Description of the Latest search sort mode"
      )
    }
  }

  public var description: String {
    String(localized: localizedDescription)
  }
}

/// Model for language selection options.
public struct LanguageOption: Identifiable, Hashable, Sendable {
  public let id = UUID()
  public let code: String
  public let name: String
  public let isPreferred: Bool

  public var displayName: String {
    localizedName(in: .current)
  }

  public func localizedName(in locale: Locale) -> String {
    locale.localizedString(forLanguageCode: code) ?? name
  }

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
