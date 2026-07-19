import Foundation
import OSLog
import Petrel

#if DEBUG

/// Loads static JSON fixtures harvested from the live Bluesky network into Petrel types,
/// so SwiftUI previews render real, varied data with zero credentials.
///
/// Fixtures live at `Catbird/Resources/Preview Content/Fixtures/*.json` and are indexed by
/// `Fixtures/FixtureManifest.json` (`fixtures`: file stem → endpoint/output type, `postShapes`:
/// shape key → index into `posts-shapes.json`'s `posts[]`). See `scripts/preview-fixtures/README.md`
/// (workspace-root repo) for how the corpus is generated.
enum PreviewFixtures {

  private static let logger = Logger(subsystem: "blue.catbird", category: "PreviewFixtures")

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
    #if targetEnvironment(simulator)
    // Last-resort fallback for the unit-test bundle, which doesn't always inherit the app's
    // dev-asset-flattened Fixtures folder. Derived from this source file's own path so it never
    // hardcodes a machine-specific location.
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
    guard let data = loadData(stem) else { return nil }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      logger.error("PreviewFixtures: failed to decode \(stem, privacy: .public) as \(String(describing: T.self), privacy: .public): \(String(describing: error), privacy: .public)")
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
  static var notifications: AppBskyNotificationListNotifications.Output? { load("notifications", as: AppBskyNotificationListNotifications.Output.self) }
  static var feedGenerators: AppBskyFeedGetFeedGenerators.Output? { load("feed-generators", as: AppBskyFeedGetFeedGenerators.Output.self) }
  static var discoverFeed: AppBskyFeedGetFeed.Output? { load("feed-discover", as: AppBskyFeedGetFeed.Output.self) }
  static var list: AppBskyGraphGetList.Output? { load("list", as: AppBskyGraphGetList.Output.self) }
  static var starterPack: AppBskyGraphGetStarterPack.Output? { load("starter-pack", as: AppBskyGraphGetStarterPack.Output.self) }
  static var labelerServices: AppBskyLabelerGetServices.Output? { load("labeler-services", as: AppBskyLabelerGetServices.Output.self) }
  static var searchPosts: AppBskyFeedSearchPosts.Output? { load("search-posts", as: AppBskyFeedSearchPosts.Output.self) }
  static var searchActors: AppBskyActorSearchActors.Output? { load("search-actors", as: AppBskyActorSearchActors.Output.self) }
  static var trends: AppBskyUnspeccedGetTrends.Output? { load("trends", as: AppBskyUnspeccedGetTrends.Output.self) }
  static var chatConvos: ChatBskyConvoListConvos.Output? { load("chat-convos", as: ChatBskyConvoListConvos.Output.self) }
  static var chatMessages: ChatBskyConvoGetMessages.Output? { load("chat-messages", as: ChatBskyConvoGetMessages.Output.self) }

  // MARK: - Post Shapes

  enum PostShape: String, CaseIterable {
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
    case selfLabels = "self_labels"
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
