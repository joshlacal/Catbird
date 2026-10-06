import Foundation

/// Bluesky's interest identifiers (mirrors social-app `src/lib/interests.ts`).
///
/// Preferences and suggestion requests use the raw ids; only `displayName(for:)` is shown.
enum BlueskyInterests {
  static let ids: [String] = [
    "animals", "art", "books", "comedy", "comics", "culture", "dev", "education",
    "finance", "food", "gaming", "journalism", "movies", "music", "nature", "news",
    "pets", "photography", "politics", "science", "sports", "tech", "tv", "writers",
  ]

  private static let displayNames: [String: String] = [
    "animals": "Animals", "art": "Art", "books": "Books", "comedy": "Comedy",
    "comics": "Comics", "culture": "Culture", "dev": "Software Dev", "education": "Education",
    "finance": "Finance", "food": "Food", "gaming": "Video Games", "journalism": "Journalism",
    "movies": "Movies", "music": "Music", "nature": "Nature", "news": "News",
    "pets": "Pets", "photography": "Photography", "politics": "Politics", "science": "Science",
    "sports": "Sports", "tech": "Tech", "tv": "TV", "writers": "Writers",
  ]

  /// Older Catbird builds saved title-case labels; map the ones that have a Bluesky equivalent.
  private static let legacyLabels: [String: String] = [
    "technology": "tech", "programming": "dev", "software dev": "dev",
    "video games": "gaming", "writing": "writers",
  ]

  static func displayName(for id: String) -> String {
    displayNames[id] ?? id.capitalized
  }

  /// Returns the Bluesky id for a stored interest, or nil when it has no Bluesky equivalent.
  static func normalizedID(_ stored: String) -> String? {
    let key = stored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if displayNames[key] != nil { return key }
    return legacyLabels[key]
  }
}

/// Remembers that this device just started creating an account, so the welcome flow
/// (avatar, interests, suggested follows) is shown to new accounts only. Accounts that
/// already exist and sign in on this device skip it.
enum NewAccountOnboardingMarker {
  private static let key = "onboarding.pendingSignupStartedAt"
  /// Sign-up happens in a browser sheet; allow time for email verification and a relaunch.
  private static let validity: TimeInterval = 60 * 60

  static func markSignupStarted(defaults: UserDefaults = .standard) {
    defaults.set(Date().timeIntervalSince1970, forKey: key)
  }

  /// Returns whether a sign-up started recently on this device, and clears the marker.
  static func consumeRecentSignup(defaults: UserDefaults = .standard) -> Bool {
    let startedAt = defaults.double(forKey: key)
    defaults.removeObject(forKey: key)
    guard startedAt > 0 else { return false }
    return Date().timeIntervalSince1970 - startedAt < validity
  }
}
