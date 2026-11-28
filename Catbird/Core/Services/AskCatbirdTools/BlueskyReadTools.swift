#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Petrel

// MARK: - Identifier parsing

/// Read tools accept identifiers the model copied from context or earlier results.
enum AskCatbirdIdentifiers {
  /// A handle, DID, `@handle` or bsky.app profile link.
  static func actor(_ input: String) throws -> ATIdentifier {
    var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if let link = URLComponents(string: value), link.scheme?.lowercased() == "https",
       link.host?.lowercased() == "bsky.app" {
      let parts = link.path.split(separator: "/")
      guard parts.count >= 2, parts[0] == "profile" else { throw BlueskyAgentError.invalidThreadURI(input) }
      value = String(parts[1])
    } else if value.hasPrefix("at://") {
      value = String(value.dropFirst(5).prefix { $0 != "/" })
    }
    if value.hasPrefix("@") { value.removeFirst() }
    guard !value.isEmpty, let identifier = try? ATIdentifier(string: value) else {
      throw BlueskyAgentError.invalidThreadURI(input)
    }
    return identifier
  }

  /// An `at://` feed generator URI or bsky.app feed link.
  static func feed(_ input: String) throws -> ATProtocolURI {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    var candidate = trimmed
    if let link = URLComponents(string: trimmed), link.scheme?.lowercased() == "https",
       link.host?.lowercased() == "bsky.app" {
      let parts = link.path.split(separator: "/")
      guard parts.count == 4, parts[0] == "profile", parts[2] == "feed" else {
        throw BlueskyAgentError.invalidThreadURI(input)
      }
      candidate = "at://\(parts[1])/app.bsky.feed.generator/\(parts[3])"
    }
    guard candidate.range(of: #"^at://[^/\s?#]+/app\.bsky\.feed\.generator/[^/\s?#]+$"#, options: .regularExpression) != nil,
          let uri = try? ATProtocolURI(uriString: candidate) else {
      throw BlueskyAgentError.invalidThreadURI(input)
    }
    return uri
  }
}

@available(iOS 26.0, macOS 26.0, *)
private extension ToolContext {
  /// Larger result budgets (Private Cloud Compute) can carry more items per read.
  func itemLimit(_ requested: Int?, compact: Int = 5, extended: Int = 10) -> Int {
    let ceiling = maximumResultTokens >= 1024 ? extended : compact
    return min(max(requested ?? ceiling, 1), ceiling)
  }

  func postResult(_ posts: [AppBskyFeedDefs.PostView], header: String? = nil) async -> String {
    for post in posts {
      await recordSource(label: ToolFormatter.sourceLabel(post: post), uri: post.uri.uriString())
    }
    let body = AskCatbirdToolPostFormatter.list(posts, refs: postRefs)
    return header.map { "\($0)\n\(body)" } ?? body
  }
}

// MARK: - Profiles

@available(iOS 26.0, macOS 26.0, *)
struct ProfileFetchTool: Tool {
  typealias Output = String

  let name = "get_profile"
  let description = "Loads a Bluesky profile: bio, counts, join date, website, pinned post and your relationship to the account."
  private let context: ToolContext

  init(context: ToolContext) { self.context = context }

  @available(iOS 26.0, macOS 26.0, *)
  @Generable
  struct Arguments {
    @Guide(description: "A handle such as alice.bsky.social, a DID, or a bsky.app profile link from context or results.")
    let actor: String
  }

  func call(arguments: Arguments) async throws -> String {
    try await context.read(name) { try await self.fetch(arguments: arguments) }
  }

  func fetch(arguments: Arguments) async throws -> String {
    let actor = try AskCatbirdIdentifiers.actor(arguments.actor)
    let (code, output) = try await context.client.app.bsky.actor.getProfile(input: .init(actor: actor))
    guard (200...299).contains(code), let profile = output else {
      throw BlueskyAgentError.emptyResult("profile")
    }
    let handle = profile.handle.description
    await context.recordSource(label: "Profile: @\(handle)", uri: profile.did.description)

    var lines = ["Profile @\(handle)"]
    if let name = profile.displayName, !name.isEmpty { lines.append("Display name: \(ToolFormatter.sanitize(name, limit: 80))") }
    if let pronouns = profile.pronouns, !pronouns.isEmpty { lines.append("Pronouns: \(ToolFormatter.sanitize(pronouns, limit: 40))") }
    if let bio = profile.description, !bio.isEmpty { lines.append("Bio: \(ToolFormatter.sanitize(bio, limit: 600))") }
    if let website = profile.website { lines.append("Website: \(website.description)") }
    let counts = [
      profile.followersCount.map { "\($0) followers" },
      profile.followsCount.map { "following \($0)" },
      profile.postsCount.map { "\($0) posts" }
    ].compactMap { $0 }
    if !counts.isEmpty { lines.append("Counts: " + counts.joined(separator: ", ")) }
    if let associated = profile.associated {
      let extras = [
        associated.feedgens.flatMap { $0 > 0 ? "\($0) feeds" : nil },
        associated.lists.flatMap { $0 > 0 ? "\($0) lists" : nil },
        associated.starterPacks.flatMap { $0 > 0 ? "\($0) starter packs" : nil },
        associated.labeler == true ? "operates a labeler" : nil
      ].compactMap { $0 }
      if !extras.isEmpty { lines.append("Also: " + extras.joined(separator: ", ")) }
    }
    if let created = profile.createdAt?.date {
      lines.append("Joined: \(created.formatted(date: .abbreviated, time: .omitted))")
    }
    if let verification = profile.verification, verification.verifiedStatus == "valid" {
      lines.append("Verification: verified by \(verification.verifications.count) trusted verifier(s)")
    }
    if let labels = profile.labels?.map(\.val).filter({ !$0.hasPrefix("!") }), !labels.isEmpty {
      lines.append("Labels: " + labels.prefix(8).joined(separator: ", "))
    }
    if let viewer = profile.viewer {
      let relationship = [
        viewer.following != nil ? "you follow them" : nil,
        viewer.followedBy != nil ? "they follow you" : nil,
        viewer.muted == true ? "you muted them" : nil,
        viewer.blocking != nil ? "you block them" : nil,
        viewer.blockedBy == true ? "they block you" : nil
      ].compactMap { $0 }
      lines.append("Relationship: " + (relationship.isEmpty ? "none" : relationship.joined(separator: ", ")))
    }
    if let pinned = profile.pinnedPost {
      let pinnedID = context.postRefs?.ref(for: pinned.uri.uriString()) ?? pinned.uri.uriString()
      lines.append("Pinned post id (tool arguments only): \(pinnedID)")
    }
    lines.append("Navigation identifier (tool arguments only): \(profile.did.description)")
    return lines.joined(separator: "\n")
  }
}

@available(iOS 26.0, macOS 26.0, *)
struct AuthorFeedTool: Tool {
  typealias Output = String

  let name = "get_author_posts"
  let description = "Loads an account's recent posts, newest first, to understand what they post about."
  private let context: ToolContext

  init(context: ToolContext) { self.context = context }

  @available(iOS 26.0, macOS 26.0, *)
  @Generable
  struct Arguments {
    @Guide(description: "A handle, DID, or bsky.app profile link from context or results.")
    let actor: String

    @Guide(description: "Which posts to include.", .anyOf(["posts", "posts_and_replies", "media", "threads"]))
    let include: String?

    @Guide(description: "Maximum posts to return.", .range(1...10))
    let limit: Int?
  }

  func call(arguments: Arguments) async throws -> String {
    try await context.read(name) { try await self.fetch(arguments: arguments) }
  }

  func fetch(arguments: Arguments) async throws -> String {
    let actor = try AskCatbirdIdentifiers.actor(arguments.actor)
    let filter = switch arguments.include {
    case "posts_and_replies": "posts_with_replies"
    case "media": "posts_with_media"
    case "threads": "posts_and_author_threads"
    default: "posts_no_replies"
    }
    let limit = context.itemLimit(arguments.limit)
    let params = AppBskyFeedGetAuthorFeed.Parameters(actor: actor, limit: limit, filter: filter, includePins: false)
    let (code, output) = try await context.client.app.bsky.feed.getAuthorFeed(input: params)
    guard (200...299).contains(code), let feed = output?.feed, !feed.isEmpty else {
      throw BlueskyAgentError.emptyResult("author posts")
    }
    let reposts = feed.prefix(limit).filter { $0.reason != nil }.count
    let header = reposts > 0 ? "\(reposts) of these are reposts of other accounts' posts." : nil
    return await context.postResult(Array(feed.prefix(limit).map(\.post)), header: header)
  }
}

@available(iOS 26.0, macOS 26.0, *)
struct SimilarAccountsTool: Tool {
  typealias Output = String

  let name = "get_similar_accounts"
  let description = "Lists accounts Bluesky suggests to people who follow the given account."
  private let context: ToolContext

  init(context: ToolContext) { self.context = context }

  @available(iOS 26.0, macOS 26.0, *)
  @Generable
  struct Arguments {
    @Guide(description: "A handle, DID, or bsky.app profile link from context or results.")
    let actor: String
  }

  func call(arguments: Arguments) async throws -> String {
    try await context.read(name) { try await self.fetch(arguments: arguments) }
  }

  func fetch(arguments: Arguments) async throws -> String {
    let actor = try AskCatbirdIdentifiers.actor(arguments.actor)
    let (code, output) = try await context.client.app.bsky.graph.getSuggestedFollowsByActor(input: .init(actor: actor))
    guard (200...299).contains(code), let suggestions = output?.suggestions, !suggestions.isEmpty else {
      throw BlueskyAgentError.emptyResult("similar accounts")
    }
    let limit = context.itemLimit(nil, compact: 5, extended: 8)
    var lines = ["Accounts suggested alongside \(arguments.actor):"]
    for profile in suggestions.prefix(limit) {
      await context.recordSource(label: "Profile: @\(profile.handle.description)", uri: profile.did.description)
      lines.append(ToolFormatter.summarize(profile: profile, limit: 140))
      lines.append("Navigation identifier (tool arguments only): \(profile.did.description)")
    }
    return lines.joined(separator: "\n")
  }
}

// MARK: - Posts

@available(iOS 26.0, macOS 26.0, *)
struct PostsFetchTool: Tool {
  typealias Output = String

  let name = "get_posts"
  let description = "Loads specific Bluesky posts by identifier, for example a pinned post or posts mentioned in results."
  private let context: ToolContext

  init(context: ToolContext) { self.context = context }

  @available(iOS 26.0, macOS 26.0, *)
  @Generable
  struct Arguments {
    @Guide(description: "Post ids such as p3, at:// post URIs or bsky.app post links copied from context or results.", .maximumCount(10))
    let uris: [String]
  }

  func call(arguments: Arguments) async throws -> String {
    try await context.read(name) { try await self.fetch(arguments: arguments) }
  }

  func fetch(arguments: Arguments) async throws -> String {
    let limit = context.itemLimit(arguments.uris.count)
    let uris = try arguments.uris.prefix(limit).map(context.postURI)
    guard !uris.isEmpty else { throw BlueskyAgentError.emptyResult("posts") }
    let (code, output) = try await context.client.app.bsky.feed.getPosts(input: .init(uris: uris))
    guard (200...299).contains(code), let posts = output?.posts, !posts.isEmpty else {
      throw BlueskyAgentError.emptyResult("posts (they may be deleted or unavailable)")
    }
    let missing = uris.count - posts.count
    return await context.postResult(posts, header: missing > 0 ? "\(missing) requested post(s) are unavailable." : nil)
  }
}

@available(iOS 26.0, macOS 26.0, *)
struct QuotesFetchTool: Tool {
  typealias Output = String

  let name = "get_quotes"
  let description = "Loads posts that quote a given post, to see how people are reacting to it beyond replies."
  private let context: ToolContext

  init(context: ToolContext) { self.context = context }

  @available(iOS 26.0, macOS 26.0, *)
  @Generable
  struct Arguments {
    @Guide(description: "A post id such as p3, an at:// post URI or a bsky.app post link from context or results.")
    let uri: String

    @Guide(description: "Maximum quote posts to return.", .range(1...10))
    let limit: Int?
  }

  func call(arguments: Arguments) async throws -> String {
    try await context.read(name) { try await self.fetch(arguments: arguments) }
  }

  func fetch(arguments: Arguments) async throws -> String {
    let uri = try context.postURI(arguments.uri)
    let limit = context.itemLimit(arguments.limit)
    let (code, output) = try await context.client.app.bsky.feed.getQuotes(input: .init(uri: uri, limit: limit))
    guard (200...299).contains(code), let posts = output?.posts else {
      throw BlueskyAgentError.emptyResult("quote posts")
    }
    guard !posts.isEmpty else { return "No one has quoted this post." }
    return await context.postResult(Array(posts.prefix(limit)))
  }
}

// MARK: - Feeds and topics

@available(iOS 26.0, macOS 26.0, *)
struct FeedPostsTool: Tool {
  typealias Output = String

  let name = "get_feed_posts"
  let description = "Loads the current top posts of a custom feed, to describe what the feed shows."
  private let context: ToolContext

  init(context: ToolContext) { self.context = context }

  @available(iOS 26.0, macOS 26.0, *)
  @Generable
  struct Arguments {
    @Guide(description: "The at:// feed generator URI or bsky.app feed link from context or results.")
    let feed: String

    @Guide(description: "Maximum posts to return.", .range(1...10))
    let limit: Int?
  }

  func call(arguments: Arguments) async throws -> String {
    try await context.read(name) { try await self.fetch(arguments: arguments) }
  }

  func fetch(arguments: Arguments) async throws -> String {
    let uri = try AskCatbirdIdentifiers.feed(arguments.feed)
    let limit = context.itemLimit(arguments.limit)
    let (code, output) = try await context.client.app.bsky.feed.getFeed(input: .init(feed: uri, limit: limit))
    guard (200...299).contains(code), let feed = output?.feed, !feed.isEmpty else {
      throw BlueskyAgentError.emptyResult("feed posts")
    }
    return await context.postResult(Array(feed.prefix(limit).map(\.post)))
  }
}

@available(iOS 26.0, macOS 26.0, *)
struct TrendingTopicsTool: Tool {
  typealias Output = String

  let name = "get_trending_topics"
  let description = "Lists topics trending on Bluesky right now, with post counts and when each started."
  private let context: ToolContext

  init(context: ToolContext) { self.context = context }

  @available(iOS 26.0, macOS 26.0, *)
  @Generable
  struct Arguments {
    @Guide(description: "Maximum topics to return.", .range(1...10))
    let limit: Int?
  }

  func call(arguments: Arguments) async throws -> String {
    try await context.read(name) { try await self.fetch(arguments: arguments) }
  }

  func fetch(arguments: Arguments) async throws -> String {
    let limit = context.itemLimit(arguments.limit, compact: 8, extended: 10)
    let (code, output) = try await context.client.app.bsky.unspecced.getTrends(input: .init(limit: limit))
    guard (200...299).contains(code), let trends = output?.trends, !trends.isEmpty else {
      throw BlueskyAgentError.emptyResult("trending topics")
    }
    var lines = ["Trending on Bluesky (search these topics with search_posts to learn why):"]
    for trend in trends.prefix(limit) {
      var line = "• \(ToolFormatter.sanitize(trend.displayName, limit: 80)) — \(trend.postCount) posts, started \(ToolFormatter.formatTimestamp(trend.startedAt.date))"
      if let status = trend.status, !status.isEmpty { line += ", \(status)" }
      if let category = trend.category, !category.isEmpty { line += ", category: \(category)" }
      if let summary = trend.description, !summary.isEmpty { line += "\n  \(ToolFormatter.sanitize(summary, limit: 200))" }
      lines.append(line)
    }
    return lines.joined(separator: "\n")
  }
}
#endif
