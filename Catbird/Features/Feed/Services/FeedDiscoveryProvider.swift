import Foundation
import Petrel

struct FeedDiscoveryPage {
  let feeds: [AppBskyFeedDefs.GeneratorView]
  let cursor: String?
}

struct FollowLikedFeed: Identifiable, Hashable {
  let feed: AppBskyFeedDefs.GeneratorView
  let likedByHandles: [String]
  let isPersonalizedSuggestion: Bool

  var id: String { feed.uri.uriString() }

  var socialProofSubtitle: String? {
    guard !likedByHandles.isEmpty else {
      return isPersonalizedSuggestion
        ? String(localized: "Suggested for you", comment: "Subtitle for a personalized feed recommendation")
        : nil
    }
    let first = "@\(likedByHandles[0])"
    if likedByHandles.count == 1 {
      return String(
        localized: "Liked by \(first)",
        comment: "Social proof subtitle when one followed user liked a feed — variable is their @handle."
      )
    } else if likedByHandles.count == 2 {
      let second = "@\(likedByHandles[1])"
      return String(
        localized: "Liked by \(first) & \(second)",
        comment: "Social proof subtitle when two followed users liked a feed — first and second variables are their @handles."
      )
    } else {
      let remaining = likedByHandles.count - 1
      return String(
        localized: "Liked by \(first) & \(remaining) others",
        comment: "Social proof subtitle when multiple followed users liked a feed — first variable is an @handle, second is the remaining count."
      )
    }
  }

  static func == (lhs: FollowLikedFeed, rhs: FollowLikedFeed) -> Bool {
    lhs.id == rhs.id
      && lhs.likedByHandles == rhs.likedByHandles
      && lhs.isPersonalizedSuggestion == rhs.isPersonalizedSuggestion
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(likedByHandles)
    hasher.combine(isPersonalizedSuggestion)
  }
}

@MainActor
protocol FeedDiscoveryProviding {
  func page(query: String?, cursor: String?) async throws -> FeedDiscoveryPage
}

@MainActor
protocol FeedStorefrontProviding {
  func fetchPopularFeeds(cursor: String?, limit: Int) async throws -> FeedDiscoveryPage
  func fetchCatbirdFeeds() async -> [AppBskyFeedDefs.GeneratorView]
  func fetchFollowLikedFeeds(candidates: [AppBskyFeedDefs.GeneratorView]) async -> [FollowLikedFeed]
  func fetchCategoryFeeds(category: FeedDiscoveryCategory, cursor: String?) async throws -> FeedDiscoveryPage
}

@MainActor
struct FeedDiscoveryProvider: FeedDiscoveryProviding, FeedStorefrontProviding {
  static let catbirdFeedURIs: [String] = [
    "at://did:plc:xg4h4n7w5mh3m4uoi27me4hh/app.bsky.feed.generator/discover",
    "at://did:plc:xg4h4n7w5mh3m4uoi27me4hh/app.bsky.feed.generator/for-you",
    "at://did:plc:xg4h4n7w5mh3m4uoi27me4hh/app.bsky.feed.generator/deep-cuts",
    "at://did:plc:xg4h4n7w5mh3m4uoi27me4hh/app.bsky.feed.generator/familiar",
    "at://did:plc:xg4h4n7w5mh3m4uoi27me4hh/app.bsky.feed.generator/fresh"
  ]

  let client: ATProtoClient

  func page(query: String?, cursor: String?) async throws -> FeedDiscoveryPage {
    let parameters = AppBskyUnspeccedGetPopularFeedGenerators.Parameters(
      limit: 24, cursor: cursor, query: query
    )

    if cursor == nil {
      async let popularResult = client.app.bsky.unspecced.getPopularFeedGenerators(input: parameters)
      async let firstPartyResult = fetchCatbirdFeeds()

      let (status, output) = try await popularResult
      guard status == 200, let output else {
        throw NSError(
          domain: "FeedDiscovery", code: status,
          userInfo: [NSLocalizedDescriptionKey: String(localized: "Feeds could not be loaded. Please try again.", comment: "Error when loading discoverable feeds fails")]
        )
      }
      let firstParty = await firstPartyResult
      return FeedDiscoveryPage(
        feeds: Self.mergeFirstPartyFeeds(firstParty, with: output.feeds, query: query),
        cursor: output.cursor
      )
    }

    let (status, output) = try await client.app.bsky.unspecced.getPopularFeedGenerators(input: parameters)
    guard status == 200, let output else {
      throw NSError(
        domain: "FeedDiscovery", code: status,
        userInfo: [NSLocalizedDescriptionKey: String(localized: "Feeds could not be loaded. Please try again.", comment: "Error when loading discoverable feeds fails")]
      )
    }
    return FeedDiscoveryPage(feeds: output.feeds, cursor: output.cursor)
  }

  func fetchPopularFeeds(cursor: String?, limit: Int = 36) async throws -> FeedDiscoveryPage {
    let parameters = AppBskyUnspeccedGetPopularFeedGenerators.Parameters(
      limit: limit, cursor: cursor, query: nil
    )
    let (status, output) = try await client.app.bsky.unspecced.getPopularFeedGenerators(input: parameters)
    guard status == 200, let output else {
      throw NSError(
        domain: "FeedDiscovery", code: status,
        userInfo: [NSLocalizedDescriptionKey: String(localized: "Feeds could not be loaded. Please try again.", comment: "Error when loading discoverable feeds fails")]
      )
    }
    return FeedDiscoveryPage(feeds: output.feeds, cursor: output.cursor)
  }

  func fetchCatbirdFeeds() async -> [AppBskyFeedDefs.GeneratorView] {
    let uris = Self.catbirdFeedURIs.compactMap { try? ATProtocolURI(uriString: $0) }
    guard !uris.isEmpty else { return [] }
    let params = AppBskyFeedGetFeedGenerators.Parameters(feeds: uris)
    guard let (status, output) = try? await client.app.bsky.feed.getFeedGenerators(input: params),
          status == 200, let output
    else {
      return []
    }
    let byURI = Dictionary(uniqueKeysWithValues: output.feeds.map { ($0.uri.uriString(), $0) })
    return Self.catbirdFeedURIs.compactMap { byURI[$0] }
  }

  func fetchFollowLikedFeeds(candidates: [AppBskyFeedDefs.GeneratorView]) async -> [FollowLikedFeed] {
    let suggested = await fetchSuggestedFeeds()
    guard !Task.isCancelled else { return [] }

    let pool = Self.deduplicatedCandidatePool(primary: suggested, secondary: candidates, limit: 14)
    let client = self.client

    let followMatches: [FollowLikedFeed] = await withTaskGroup(of: FollowLikedFeed?.self) { group in
      for feed in pool {
        group.addTask {
          await Self.fetchFollowLikes(for: feed, client: client)
        }
      }
      var collected: [FollowLikedFeed] = []
      for await match in group {
        if let match { collected.append(match) }
      }
      return collected
    }

    return Self.rankFollowLikedFeeds(matches: followMatches, suggestedFallback: suggested)
  }

  private func fetchSuggestedFeeds() async -> [AppBskyFeedDefs.GeneratorView] {
    let params = AppBskyFeedGetSuggestedFeeds.Parameters(limit: 24)
    guard let (status, output) = try? await client.app.bsky.feed.getSuggestedFeeds(input: params),
          status == 200, let output
    else {
      return []
    }
    return output.feeds
  }

  private nonisolated static func deduplicatedCandidatePool(
    primary: [AppBskyFeedDefs.GeneratorView],
    secondary: [AppBskyFeedDefs.GeneratorView],
    limit: Int
  ) -> [AppBskyFeedDefs.GeneratorView] {
    var seen = Set<String>()
    var pool: [AppBskyFeedDefs.GeneratorView] = []
    for feed in primary + secondary where seen.insert(feed.uri.uriString()).inserted {
      pool.append(feed)
      if pool.count >= limit { break }
    }
    return pool
  }

  private nonisolated static func fetchFollowLikes(
    for feed: AppBskyFeedDefs.GeneratorView,
    client: ATProtoClient
  ) async -> FollowLikedFeed? {
    guard !Task.isCancelled else { return nil }
    let params = AppBskyFeedGetLikes.Parameters(uri: feed.uri, limit: 40)
    guard let (status, output) = try? await client.app.bsky.feed.getLikes(input: params),
          status == 200, let likes = output?.likes
    else {
      return nil
    }
    var seenHandles = Set<String>()
    var handles: [String] = []
    for like in likes where like.actor.viewer?.following != nil {
      let handle = like.actor.handle.description
      if seenHandles.insert(handle).inserted {
        handles.append(handle)
      }
    }
    guard !handles.isEmpty else { return nil }
    return FollowLikedFeed(feed: feed, likedByHandles: handles, isPersonalizedSuggestion: false)
  }

  func fetchCategoryFeeds(
    category: FeedDiscoveryCategory,
    cursor: String?
  ) async throws -> FeedDiscoveryPage {
    let parameters = AppBskyUnspeccedGetPopularFeedGenerators.Parameters(
      limit: 24, cursor: cursor, query: category.searchQuery
    )
    let (status, output) = try await client.app.bsky.unspecced.getPopularFeedGenerators(input: parameters)
    guard status == 200, let output else {
      throw NSError(
        domain: "FeedDiscovery", code: status,
        userInfo: [NSLocalizedDescriptionKey: String(localized: "Couldn’t load \(category.title) feeds. Try again.", comment: "Error when loading feeds for a specific discovery category fails — variable is the category name.")]
      )
    }
    return FeedDiscoveryPage(feeds: output.feeds, cursor: output.cursor)
  }

  nonisolated static func rankFollowLikedFeeds(
    matches: [FollowLikedFeed],
    suggestedFallback: [AppBskyFeedDefs.GeneratorView]
  ) -> [FollowLikedFeed] {
    let sortedMatches = matches.sorted { lhs, rhs in
      if lhs.likedByHandles.count != rhs.likedByHandles.count {
        return lhs.likedByHandles.count > rhs.likedByHandles.count
      }
      return (lhs.feed.likeCount ?? 0) > (rhs.feed.likeCount ?? 0)
    }

    var seen = Set(sortedMatches.map(\.id))
    var combined = sortedMatches
    for feed in suggestedFallback where seen.insert(feed.uri.uriString()).inserted {
      combined.append(
        FollowLikedFeed(feed: feed, likedByHandles: [], isPersonalizedSuggestion: true)
      )
    }
    return combined
  }

  nonisolated static func mergeFirstPartyFeeds(
    _ firstParty: [AppBskyFeedDefs.GeneratorView],
    with popular: [AppBskyFeedDefs.GeneratorView],
    query: String?
  ) -> [AppBskyFeedDefs.GeneratorView] {
    let byURI = Dictionary(uniqueKeysWithValues: firstParty.map { ($0.uri.uriString(), $0) })
    let orderedFirstParty = catbirdFeedURIs.compactMap { byURI[$0] }
    let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

    let matchingFirstParty: [AppBskyFeedDefs.GeneratorView]
    if trimmed.isEmpty {
      matchingFirstParty = orderedFirstParty
    } else {
      matchingFirstParty = orderedFirstParty.filter { feed in
        feed.displayName.lowercased().contains(trimmed)
          || (feed.description?.lowercased().contains(trimmed) ?? false)
          || "catbird".contains(trimmed)
      }
    }

    var seen = Set(matchingFirstParty.map { $0.uri.uriString() })
    var combined = matchingFirstParty
    for item in popular where seen.insert(item.uri.uriString()).inserted {
      combined.append(item)
    }
    return combined
  }
}
