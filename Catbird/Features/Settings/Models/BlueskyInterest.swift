import Foundation

/// Bluesky's canonical interest tags, as stored in the account's `interestsPref`.
/// Matches the official app's list so interests chosen in either app round-trip.
enum BlueskyInterest: String, CaseIterable, Identifiable, Sendable {
  case animals, art, books, comedy, comics, culture, dev, education, finance, food, gaming, journalism
  case movies, music, nature, news, pets, photography, politics, science, sports, tech, tv, writers

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .animals: "Animals"
    case .art: "Art"
    case .books: "Books"
    case .comedy: "Comedy"
    case .comics: "Comics"
    case .culture: "Culture"
    case .dev: "Software Dev"
    case .education: "Education"
    case .finance: "Finance"
    case .food: "Food"
    case .gaming: "Video Games"
    case .journalism: "Journalism"
    case .movies: "Movies"
    case .music: "Music"
    case .nature: "Nature"
    case .news: "News"
    case .pets: "Pets"
    case .photography: "Photography"
    case .politics: "Politics"
    case .science: "Science"
    case .sports: "Sports"
    case .tech: "Tech"
    case .tv: "TV"
    case .writers: "Writers"
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
