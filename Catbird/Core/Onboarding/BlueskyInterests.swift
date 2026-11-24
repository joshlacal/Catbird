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

  private static let knownIDs: Set<String> = Set(ids)

  /// Older Catbird builds saved title-case labels; map the ones that have a Bluesky equivalent.
  private static let legacyLabels: [String: String] = [
    "technology": "tech", "programming": "dev", "software dev": "dev",
    "video games": "gaming", "writing": "writers",
  ]

  static func displayName(for id: String) -> String {
    switch id {
    case "animals": return String(localized: "Animals", comment: "Bluesky interest topic chip label.")
    case "art": return String(localized: "Art", comment: "Bluesky interest topic chip label.")
    case "books": return String(localized: "Books", comment: "Bluesky interest topic chip label.")
    case "comedy": return String(localized: "Comedy", comment: "Bluesky interest topic chip label.")
    case "comics": return String(localized: "Comics", comment: "Bluesky interest topic chip label.")
    case "culture": return String(localized: "Culture", comment: "Bluesky interest topic chip label.")
    case "dev": return String(localized: "Software Dev", comment: "Bluesky interest topic chip label for software development.")
    case "education": return String(localized: "Education", comment: "Bluesky interest topic chip label.")
    case "finance": return String(localized: "Finance", comment: "Bluesky interest topic chip label.")
    case "food": return String(localized: "Food", comment: "Bluesky interest topic chip label.")
    case "gaming": return String(localized: "Video Games", comment: "Bluesky interest topic chip label.")
    case "journalism": return String(localized: "Journalism", comment: "Bluesky interest topic chip label.")
    case "movies": return String(localized: "Movies", comment: "Bluesky interest topic chip label.")
    case "music": return String(localized: "Music", comment: "Bluesky interest topic chip label.")
    case "nature": return String(localized: "Nature", comment: "Bluesky interest topic chip label.")
    case "news": return String(localized: "News", comment: "Bluesky interest topic chip label.")
    case "pets": return String(localized: "Pets", comment: "Bluesky interest topic chip label.")
    case "photography": return String(localized: "Photography", comment: "Bluesky interest topic chip label.")
    case "politics": return String(localized: "Politics", comment: "Bluesky interest topic chip label.")
    case "science": return String(localized: "Science", comment: "Bluesky interest topic chip label.")
    case "sports": return String(localized: "Sports", comment: "Bluesky interest topic chip label.")
    case "tech": return String(localized: "Tech", comment: "Bluesky interest topic chip label.")
    case "tv": return String(localized: "TV", comment: "Bluesky interest topic chip label for television.")
    case "writers": return String(localized: "Writers", comment: "Bluesky interest topic chip label.")
    default: return id.localizedCapitalized
    }
  }

  /// Returns the Bluesky id for a stored interest, or nil when it has no Bluesky equivalent.
  static func normalizedID(_ stored: String) -> String? {
    let key = stored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if knownIDs.contains(key) { return key }
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
