import Foundation
import Petrel

/// Lightweight client-side category taxonomy for Bluesky feeds until ATProto lexicons
/// expose native feed categories.
enum FeedDiscoveryCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
  case art
  case science
  case news
  case sports
  case dev
  case games
  case books

  var id: String { rawValue }

  var title: String {
    switch self {
    case .art: "Art & Photo"
    case .science: "Science & Nature"
    case .news: "News & Politics"
    case .sports: "Sports"
    case .dev: "Tech & Dev"
    case .games: "Games"
    case .books: "Books & Culture"
    }
  }

  var shortTitle: String {
    switch self {
    case .art: "Art"
    case .science: "Science"
    case .news: "News"
    case .sports: "Sports"
    case .dev: "Dev"
    case .games: "Games"
    case .books: "Books"
    }
  }

  var symbolName: String {
    switch self {
    case .art: "paintbrush.pointed.fill"
    case .science: "atom"
    case .news: "newspaper.fill"
    case .sports: "sportscourt.fill"
    case .dev: "chevron.left.forwardslash.chevron.right"
    case .games: "gamecontroller.fill"
    case .books: "book.pages.fill"
    }
  }

  var searchQuery: String {
    switch self {
    case .art: "art"
    case .science: "science"
    case .news: "news"
    case .sports: "sports"
    case .dev: "programming"
    case .games: "gaming"
    case .books: "books"
    }
  }

  /// Single-token keywords matched on word boundaries (prevents false positives like "art" in "earth").
  var tokenKeywords: Set<String> {
    switch self {
    case .art:
      ["art", "artist", "artists", "artwork", "illustration", "illustrator", "drawing", "sketch",
       "painting", "comics", "comic", "manga", "photography", "photo", "photos", "photographer",
       "portrait", "anime", "pixelart", "design", "ceramic", "ceramics", "sculpture", "printmaking",
       "watercolor", "collage", "furry", "oc", "ocs", "fanart"]
    case .science:
      ["science", "scientist", "scientists", "astronomy", "astrophysics", "space", "nasa", "physics",
       "biology", "biologist", "chemistry", "climate", "bird", "birds", "birding", "nature",
       "wildlife", "geology", "medicine", "medical", "neuroscience", "ecology", "math", "mathematics",
       "academic", "academia", "research", "researchers", "paleontology", "botany", "ocean", "weather",
       "earth", "planetary", "planet", "planets", "orbit", "cosmos", "galaxy", "telescope", "fossils"]
    case .news:
      ["news", "journalism", "journalist", "journalists", "breaking", "politics", "political",
       "world", "economy", "economics", "headlines", "press", "reporter", "reporters", "policy",
       "law", "legal", "elections", "dispatch", "civics", "government", "uspol", "ukpol"]
    case .sports:
      ["sports", "sport", "nfl", "nba", "mlb", "nhl", "wnba", "mls", "soccer", "football",
       "baseball", "basketball", "hockey", "f1", "motorsport", "nascar", "tennis", "golf",
       "cycling", "wrestling", "mma", "ufc", "cricket", "rugby", "olympics", "racing", "cfb", "cbb"]
    case .dev:
      ["dev", "devs", "developer", "developers", "software", "coding", "code", "programming",
       "programmer", "swift", "swiftui", "rust", "python", "typescript", "javascript", "golang",
       "linux", "webdev", "opensource", "gamedev", "infosec", "cybersecurity", "security",
       "engineering", "atproto", "bluesky", "tech", "ai", "ml", "ios", "macos", "android", "css"]
    case .games:
      ["game", "games", "gaming", "gamer", "gamers", "indiegame", "indiegames", "nintendo",
       "playstation", "xbox", "steam", "rpg", "jrpg", "mmorpg", "tabletop", "ttrpg", "dnd",
       "boardgames", "boardgame", "esports", "retro", "retrogaming", "speedrun", "pokemon", "zelda"]
    case .books:
      ["book", "books", "booksky", "reading", "reader", "readers", "literature", "writing",
       "writer", "writers", "author", "authors", "poetry", "poet", "novels", "scifi", "fantasy",
       "film", "films", "movies", "cinema", "music", "albums", "history", "philosophy", "cooking", "food"]
    }
  }

  /// Multi-word phrases checked as substring matches against lowercased text.
  var phraseKeywords: [String] {
    switch self {
    case .art: ["digital art", "street photography", "film photography", "graphic design", "pixel art"]
    case .science: ["earth science", "marine biology", "machine learning research", "climate science"]
    case .news: ["breaking news", "world news", "tech news", "local news", "us politics"]
    case .sports: ["formula 1", "premier league", "champions league", "college football", "pro wrestling"]
    case .dev: ["open source", "web development", "software engineering", "game dev", "machine learning"]
    case .games: ["indie games", "video games", "board games", "tabletop rpg", "retro gaming"]
    case .books: ["book club", "creative writing", "sci-fi", "science fiction", "film twitter"]
    }
  }
}

/// Deterministic keyword-based feed classifier with word-boundary matching.
enum FeedDiscoveryCategoryClassifier {
  static func primaryCategory(for feed: AppBskyFeedDefs.GeneratorView) -> FeedDiscoveryCategory? {
    primaryCategory(
      displayName: feed.displayName,
      description: feed.description,
      recordKey: feed.uri.recordKey,
      creatorHandle: feed.creator.handle.description
    )
  }

  static func primaryCategory(
    displayName: String,
    description: String?,
    recordKey: String? = nil,
    creatorHandle: String? = nil
  ) -> FeedDiscoveryCategory? {
    let titleText = [displayName, recordKey ?? ""].joined(separator: " ").lowercased()
    let bodyText = [description ?? "", creatorHandle ?? ""].joined(separator: " ").lowercased()
    let titleTokens = tokenize(titleText)
    let bodyTokens = tokenize(bodyText)

    var bestCategory: FeedDiscoveryCategory?
    var bestScore = 0

    for category in FeedDiscoveryCategory.allCases {
      var score = 0
      for token in titleTokens where category.tokenKeywords.contains(token) {
        score += 3
      }
      for phrase in category.phraseKeywords where titleText.contains(phrase) {
        score += 4
      }
      for token in bodyTokens where category.tokenKeywords.contains(token) {
        score += 1
      }
      for phrase in category.phraseKeywords where bodyText.contains(phrase) {
        score += 2
      }
      if score > bestScore {
        bestScore = score
        bestCategory = category
      }
    }

    return bestScore > 0 ? bestCategory : nil
  }

  static func bucket(
    _ feeds: [AppBskyFeedDefs.GeneratorView]
  ) -> [FeedDiscoveryCategory: [AppBskyFeedDefs.GeneratorView]] {
    var buckets: [FeedDiscoveryCategory: [AppBskyFeedDefs.GeneratorView]] = [:]
    var seenByCategory: [FeedDiscoveryCategory: Set<String>] = [:]
    for feed in feeds {
      guard let category = primaryCategory(for: feed) else { continue }
      let uri = feed.uri.uriString()
      if seenByCategory[category, default: []].insert(uri).inserted {
        buckets[category, default: []].append(feed)
      }
    }
    return buckets
  }

  static func tokenize(_ text: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    for scalar in text.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        current.unicodeScalars.append(scalar)
      } else if !current.isEmpty {
        tokens.append(current)
        current.removeAll(keepingCapacity: true)
      }
    }
    if !current.isEmpty {
      tokens.append(current)
    }
    return tokens
  }
}
