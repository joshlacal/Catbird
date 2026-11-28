//
//  PreviewFixtures.swift
//  Catbird
//
//  Loads static verbatim wire-JSON fixtures harvested from the Bluesky network
//  into Petrel types so SwiftUI previews, `-CatbirdCatalog`, and offline snapshot
//  tests render deterministic, varied data with zero credentials or network calls.
//

import Foundation
import OSLog
import Petrel
import PetrelCatbird

#if DEBUG

/// Loads static JSON fixtures harvested from the live Bluesky network into Petrel types.
///
/// Fixtures live at `Catbird/Resources/Preview Content/Fixtures/*.json` and are indexed by
/// `Fixtures/FixtureManifest.json`. See `scripts/preview-fixtures/README.md` (workspace root)
/// for how the corpus is generated.
enum PreviewFixtures {

  private static let logger = Logger(subsystem: "blue.catbird", category: "PreviewFixtures")
  private static let lexiconLock = NSLock()
  nonisolated(unsafe) private static var lexiconsRegistered = false

  private static let xrpcFixtureMap: [String: String] = [
    "app.bsky.feed.getTimeline": "timeline",
    "app.bsky.unspecced.getPostThreadV2": "thread-v2",
    "app.bsky.feed.getPostThread": "thread-classic",
    "app.bsky.feed.getPosts": "posts-shapes",
    "app.bsky.actor.getProfiles": "profiles",
    "app.bsky.graph.getFollowers": "followers",
    "app.bsky.graph.getFollows": "follows",
    "app.bsky.graph.getList": "list",
    "app.bsky.graph.getLists": "lists",
    "app.bsky.graph.getStarterPack": "starter-pack",
    "app.bsky.feed.getFeedGenerators": "feed-generators",
    "app.bsky.feed.getFeed": "feed-discover",
    "app.bsky.unspecced.getPopularFeedGenerators": "popular-feed-generators",
    "app.bsky.notification.listNotifications": "notifications",
    "app.bsky.feed.getLikes": "likes",
    "app.bsky.feed.getRepostedBy": "reposted-by",
    "app.bsky.feed.getQuotes": "quotes",
    "app.bsky.feed.searchPosts": "search-posts",
    "app.bsky.feed.searchPostsV2": "search-posts",
    "app.bsky.actor.searchActors": "search-actors",
    "app.bsky.actor.searchActorsTypeahead": "search-actors",
    "app.bsky.unspecced.getTrends": "trends",
    "app.bsky.unspecced.getTrendingTopics": "trending-topics",
    "app.bsky.unspecced.getTaggedSuggestions": "tagged-suggestions",
    "app.bsky.actor.getSuggestions": "suggestions",
    "app.bsky.labeler.getServices": "labeler-services",
    "app.bsky.actor.getPreferences": "preferences",
    "chat.bsky.convo.listConvos": "chat-convos",
    "chat.bsky.convo.getMessages": "chat-messages",
    "app.bsky.bookmark.getBookmarks": "bookmarks",
    "app.bsky.feed.getSuggestedFeeds": "feed-generators"
  ]

  /// Ensures custom `blue.catbird.*` / `place.stream.*` lexicon decoders are registered even
  /// when presentation fixtures short-circuit `CatbirdApp.init()`.
  private static func ensureLexiconsRegistered() {
    lexiconLock.withLock {
      guard !lexiconsRegistered else { return }
      PetrelCatbirdLexicons.register()
      lexiconsRegistered = true
    }
  }

  // MARK: - Raw Loading

  /// Loads the raw bytes of `<stem>.json` from the Fixtures folder, trying every plausible
  /// bundle location (dev-asset flattening means the exact resource path varies by build).
  static func loadData(_ stem: String) -> Data? {
    if let url = Bundle.main.url(forResource: stem, withExtension: "json") {
      return try? Data(contentsOf: url)
    }
    if let url = Bundle.main.url(forResource: stem, withExtension: "json", subdirectory: "Fixtures") {
      return try? Data(contentsOf: url)
    }
    let testBundle = Bundle(for: FixtureBundleAnchor.self)
    if let url = testBundle.url(forResource: stem, withExtension: "json") {
      return try? Data(contentsOf: url)
    }
    if let url = testBundle.url(forResource: stem, withExtension: "json", subdirectory: "Fixtures") {
      return try? Data(contentsOf: url)
    }
    #if targetEnvironment(simulator) || os(macOS)
    // Fallback for hosted/unit test bundles that do not copy DEVELOPMENT_ASSET_PATHS.
    let sourceFileURL = URL(fileURLWithPath: #filePath)
    let fixturesDir = sourceFileURL
      .deletingLastPathComponent() // Preview/
      .deletingLastPathComponent() // Core/
      .deletingLastPathComponent() // Catbird/
      .appendingPathComponent("Resources/Preview Content/Fixtures")
    let fileURL = fixturesDir.appendingPathComponent("\(stem).json")
    if let data = try? Data(contentsOf: fileURL) {
      return data
    }
    #endif
    logger.debug("PreviewFixtures: could not locate fixture \"\(stem, privacy: .public)\"")
    return nil
  }

  /// Decodes `<stem>.json` as `T` with a plain `JSONDecoder()`. Returns `nil` on missing file
  /// or decode failure (logged in DEBUG so preview/test failures are diagnosable).
  static func load<T: Decodable>(_ stem: String, as type: T.Type) -> T? {
    ensureLexiconsRegistered()
    guard let data = loadData(stem) else { return nil }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      logger.error(
        "PreviewFixtures: failed to decode \(stem, privacy: .public) as \(String(describing: T.self), privacy: .public): \(String(describing: error), privacy: .public)"
      )
      return nil
    }
  }

  // MARK: - XRPC Endpoint Lookup (for OfflineFixtureURLProtocol)

  /// Resolves harvested verbatim JSON for an XRPC method name (e.g. `app.bsky.feed.getTimeline`).
  static func rawData(forXRPCMethod method: String, queryItems: [URLQueryItem] = []) -> Data? {
    if let stem = xrpcFixtureMap[method] {
      return loadData(stem)
    }

    let queryMap = Dictionary(
      queryItems.compactMap { item -> (String, String)? in
        guard let value = item.value else { return nil }
        return (item.name, value)
      },
      uniquingKeysWith: { first, _ in first }
    )

    switch method {
    case "app.bsky.feed.getAuthorFeed":
      if queryMap["filter"] == "posts_with_video" { return loadData("author-feed-videos") }
      if let actor = queryMap["actor"], actor.contains("appstore") { return loadData("author-feed-appstore") }
      return loadData("author-feed-bot")
    case "app.bsky.actor.getProfile":
      if let actor = queryMap["actor"], actor != PreviewContainer.fixtureUserDID, !actor.contains("catbirdbot") {
        return loadData("profile-real") ?? loadData("profile-bot")
      }
      return loadData("profile-bot")
    case "app.bsky.notification.getUnreadCount":
      return Data(#"{"count":3}"#.utf8)
    default:
      return nil
    }
  }

  // MARK: - Typed Accessors

  static var timeline: AppBskyFeedGetTimeline.Output? { load("timeline", as: AppBskyFeedGetTimeline.Output.self) }
  static var authorFeedBot: AppBskyFeedGetAuthorFeed.Output? { load("author-feed-bot", as: AppBskyFeedGetAuthorFeed.Output.self) }
  static var authorFeedWithReposts: AppBskyFeedGetAuthorFeed.Output? { load("author-feed-appstore", as: AppBskyFeedGetAuthorFeed.Output.self) }
  static var authorFeedVideos: AppBskyFeedGetAuthorFeed.Output? { load("author-feed-videos", as: AppBskyFeedGetAuthorFeed.Output.self) }
  static var threadV2: AppBskyUnspeccedGetPostThreadV2.Output? { load("thread-v2", as: AppBskyUnspeccedGetPostThreadV2.Output.self) }
  static var threadClassic: AppBskyFeedGetPostThread.Output? { load("thread-classic", as: AppBskyFeedGetPostThread.Output.self) }
  static var postShapes: AppBskyFeedGetPosts.Output? { load("posts-shapes", as: AppBskyFeedGetPosts.Output.self) }
  static var videoPost: AppBskyFeedDefs.PostView? {
    load("post-video-real", as: AppBskyFeedGetPosts.Output.self)?.posts.first
  }
  static var profileBot: AppBskyActorDefs.ProfileViewDetailed? { load("profile-bot", as: AppBskyActorDefs.ProfileViewDetailed.self) }
  static var profileReal: AppBskyActorDefs.ProfileViewDetailed? { load("profile-real", as: AppBskyActorDefs.ProfileViewDetailed.self) }
  static var profiles: AppBskyActorGetProfiles.Output? { load("profiles", as: AppBskyActorGetProfiles.Output.self) }
  static var followers: AppBskyGraphGetFollowers.Output? { load("followers", as: AppBskyGraphGetFollowers.Output.self) }
  static var follows: AppBskyGraphGetFollows.Output? { load("follows", as: AppBskyGraphGetFollows.Output.self) }
  static var list: AppBskyGraphGetList.Output? { load("list", as: AppBskyGraphGetList.Output.self) }
  static var lists: AppBskyGraphGetLists.Output? { load("lists", as: AppBskyGraphGetLists.Output.self) }
  static var starterPack: AppBskyGraphGetStarterPack.Output? { load("starter-pack", as: AppBskyGraphGetStarterPack.Output.self) }
  static var feedGenerators: AppBskyFeedGetFeedGenerators.Output? { load("feed-generators", as: AppBskyFeedGetFeedGenerators.Output.self) }
  static var discoverFeed: AppBskyFeedGetFeed.Output? { load("feed-discover", as: AppBskyFeedGetFeed.Output.self) }
  static var popularFeedGenerators: AppBskyUnspeccedGetPopularFeedGenerators.Output? {
    load("popular-feed-generators", as: AppBskyUnspeccedGetPopularFeedGenerators.Output.self)
  }
  static var notifications: AppBskyNotificationListNotifications.Output? { load("notifications", as: AppBskyNotificationListNotifications.Output.self) }
  static var likes: AppBskyFeedGetLikes.Output? { load("likes", as: AppBskyFeedGetLikes.Output.self) }
  static var repostedBy: AppBskyFeedGetRepostedBy.Output? { load("reposted-by", as: AppBskyFeedGetRepostedBy.Output.self) }
  static var quotes: AppBskyFeedGetQuotes.Output? { load("quotes", as: AppBskyFeedGetQuotes.Output.self) }
  static var searchPosts: AppBskyFeedSearchPosts.Output? { load("search-posts", as: AppBskyFeedSearchPosts.Output.self) }
  static var searchPostsMedia: AppBskyFeedSearchPosts.Output? { load("search-posts-media", as: AppBskyFeedSearchPosts.Output.self) }
  static var searchActors: AppBskyActorSearchActors.Output? { load("search-actors", as: AppBskyActorSearchActors.Output.self) }
  static var trends: AppBskyUnspeccedGetTrends.Output? { load("trends", as: AppBskyUnspeccedGetTrends.Output.self) }
  static var trendingTopics: AppBskyUnspeccedGetTrendingTopics.Output? { load("trending-topics", as: AppBskyUnspeccedGetTrendingTopics.Output.self) }
  static var taggedSuggestions: AppBskyUnspeccedGetTaggedSuggestions.Output? {
    load("tagged-suggestions", as: AppBskyUnspeccedGetTaggedSuggestions.Output.self)
  }
  static var suggestions: AppBskyActorGetSuggestions.Output? { load("suggestions", as: AppBskyActorGetSuggestions.Output.self) }
  static var labelerServices: AppBskyLabelerGetServices.Output? { load("labeler-services", as: AppBskyLabelerGetServices.Output.self) }
  static var preferences: AppBskyActorGetPreferences.Output? { load("preferences", as: AppBskyActorGetPreferences.Output.self) }
  static var chatConvos: ChatBskyConvoListConvos.Output? { load("chat-convos", as: ChatBskyConvoListConvos.Output.self) }
  static var chatMessages: ChatBskyConvoGetMessages.Output? { load("chat-messages", as: ChatBskyConvoGetMessages.Output.self) }
  static var bookmarks: AppBskyBookmarkGetBookmarks.Output? { load("bookmarks", as: AppBskyBookmarkGetBookmarks.Output.self) }

  // MARK: - Post Shapes

  enum PostShape: String, CaseIterable, Sendable {
    case textShort = "text_short"
    case textLong = "text_long"
    case facets
    case images1 = "images_1"
    case images4 = "images_4"
    case gallery6 = "gallery_6"
    case external
    case externalThumb = "external_thumb"
    case quotePost = "quote_post"
    case quoteList = "quote_list"
    case quoteFeedgen = "quote_feedgen"
    case quoteStarterpack = "quote_starterpack"
    case quoteBlocked = "quote_blocked"
    case quoteDetached = "quote_detached"
    case quoteNotfound = "quote_notfound"
    case recordWithMedia = "record_with_media"
    case threadgateRoot = "threadgate_root"
    case postgateRoot = "postgate_root"
    case selfLabels = "self_labels"
    case replyRoot = "reply_root"
    case replyL1 = "reply_l1"
    case replyL2Appstore = "reply_l2_appstore"
    case replyL3 = "reply_l3"
    case mentionByAppstore = "mention_by_appstore"
    case quoteByAppstore = "quote_by_appstore"
  }

  /// Looks up a post by shape key via `FixtureManifest.json`'s `postShapes` index into
  /// `posts-shapes.json`'s `posts[]`.
  static func post(_ shape: PostShape) -> AppBskyFeedDefs.PostView? {
    guard
      let manifestData = loadData("FixtureManifest"),
      let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
      let postShapesIndex = manifest["postShapes"] as? [String: Any],
      let index = postShapesIndex[shape.rawValue] as? Int,
      let posts = postShapes?.posts,
      posts.indices.contains(index)
    else { return nil }
    return posts[index]
  }

  // MARK: - Derived

  static var firstFeedViewPost: AppBskyFeedDefs.FeedViewPost? { timeline?.feed.first }

  static var repostFeedViewPost: AppBskyFeedDefs.FeedViewPost? {
    authorFeedWithReposts?.feed.first { $0.reason != nil }
  }
}

/// Anchor class purely for `Bundle(for:)` lookup of the test/preview bundle containing fixtures.
private final class FixtureBundleAnchor {}

#endif
