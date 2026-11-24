import Foundation

/// Bluesky's canonical interest tags, as stored in the account's `interestsPref`.
/// Matches the official app's list so interests chosen in either app round-trip.
enum BlueskyInterest: String, CaseIterable, Identifiable, Sendable {
  case animals, art, books, comedy, comics, culture, dev, education, finance, food, gaming, journalism
  case movies, music, nature, news, pets, photography, politics, science, sports, tech, tv, writers

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .animals: String(localized: "Animals", comment: "Bluesky discovery interest topic.")
    case .art: String(localized: "Art", comment: "Bluesky discovery interest topic.")
    case .books: String(localized: "Books", comment: "Bluesky discovery interest topic.")
    case .comedy: String(localized: "Comedy", comment: "Bluesky discovery interest topic.")
    case .comics: String(localized: "Comics", comment: "Bluesky discovery interest topic.")
    case .culture: String(localized: "Culture", comment: "Bluesky discovery interest topic.")
    case .dev: String(localized: "Software Dev", comment: "Bluesky discovery interest topic.")
    case .education: String(localized: "Education", comment: "Bluesky discovery interest topic.")
    case .finance: String(localized: "Finance", comment: "Bluesky discovery interest topic.")
    case .food: String(localized: "Food", comment: "Bluesky discovery interest topic.")
    case .gaming: String(localized: "Video Games", comment: "Bluesky discovery interest topic.")
    case .journalism: String(localized: "Journalism", comment: "Bluesky discovery interest topic.")
    case .movies: String(localized: "Movies", comment: "Bluesky discovery interest topic.")
    case .music: String(localized: "Music", comment: "Bluesky discovery interest topic.")
    case .nature: String(localized: "Nature", comment: "Bluesky discovery interest topic.")
    case .news: String(localized: "News", comment: "Bluesky discovery interest topic.")
    case .pets: String(localized: "Pets", comment: "Bluesky discovery interest topic.")
    case .photography: String(localized: "Photography", comment: "Bluesky discovery interest topic.")
    case .politics: String(localized: "Politics", comment: "Bluesky discovery interest topic.")
    case .science: String(localized: "Science", comment: "Bluesky discovery interest topic.")
    case .sports: String(localized: "Sports", comment: "Bluesky discovery interest topic.")
    case .tech: String(localized: "Tech", comment: "Bluesky discovery interest topic.")
    case .tv: String(localized: "TV", comment: "Bluesky discovery interest topic.")
    case .writers: String(localized: "Writers", comment: "Bluesky discovery interest topic.")
    }
  }

  /// Maps a stored value, including the capitalized words older Catbird builds saved, to its canonical tag.
  /// Returns `nil` for values Bluesky doesn't recognize.
  static func normalize(_ raw: String) -> BlueskyInterest? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let interest = BlueskyInterest(rawValue: value) { return interest }
    switch value {
    case "technology": return .tech
    case "programming", "software dev", "software development": return .dev
    case "video games": return .gaming
    default: return nil
    }
  }

  /// A friendly name for any stored value; unknown values are shown as saved.
  static func displayName(for raw: String) -> String {
    normalize(raw)?.displayName ?? raw
  }
}
