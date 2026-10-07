//
//  FeedWidgetDataProvider.swift
//  Catbird
//
//  Created on 6/7/25.
//

import Foundation
import OSLog
import Petrel
import WidgetKit

@MainActor
final class FeedWidgetDataProvider {
  private let logger = Logger(subsystem: "blue.catbird", category: "FeedWidgetDataProvider")
  private let sharedDefaults = UserDefaults(suiteName: "group.blue.catbird.shared")

  static let shared = FeedWidgetDataProvider()

  /// The DID of the currently active account, used to scope widget data keys
  private var accountDID: String = ""

  /// The posts each widget feed was last built from, for the active account, keyed by
  /// configuration key. A moderation policy change rebuilds the stored widget posts from these
  /// without a network load.
  private var widgetSources: [String: WidgetFeedSource] = [:]
  private var moderationPolicyObserver: NSObjectProtocol?

  private init() {
    moderationPolicyObserver = NotificationCenter.default.addObserver(
      forName: .moderationPolicyDidChange, object: nil, queue: .main
    ) { [weak self] notification in
      let originDID = notification.userInfo?["accountDID"] as? String
      MainActor.assumeIsolated { self?.rebuildAfterModerationPolicyChange(originDID: originDID) }
    }
  }

  /// Configure the provider with the active account DID for key scoping
  func configure(accountDID: String) {
    if accountDID != self.accountDID {
      widgetSources.removeAll()
    }
    self.accountDID = accountDID
    // Write active DID so widget knows which account is current
    sharedDefaults?.set(accountDID, forKey: "activeAccountDID")
  }

  /// Updates widget data from a feed's posts
  func updateWidgetData(from posts: [CachedFeedViewPost], feedType: FetchType) {
    // Use the enhanced version by default for better functionality
    updateWidgetDataEnhanced(from: posts, feedType: feedType)
  }

  /// Maps internal FetchType to the feed type label stored with widget data
  private func mapFeedType(_ fetchType: FetchType) -> String {
    switch fetchType {
    case .feed:
      return "feed"
    default:
      return "timeline"
    }
  }

  /// Updates user's pinned and saved feeds for widget access
  func updateSharedFeedPreferences(
    pinnedFeeds: [String], savedFeeds: [String], feedGenerators: [String: String] = [:]
  ) {
    guard let sharedDefaults = sharedDefaults else {
      logger.error("Failed to access shared defaults for feed preferences")
      return
    }

    do {
      let encoder = JSONEncoder()

      let didSuffix = accountDID.isEmpty ? "" : ".\(accountDID)"

      // Store pinned feeds (DID-scoped)
      let pinnedData = try encoder.encode(pinnedFeeds)
      sharedDefaults.set(pinnedData, forKey: "pinnedFeeds\(didSuffix)")

      // Store saved feeds (DID-scoped)
      let savedData = try encoder.encode(savedFeeds)
      sharedDefaults.set(savedData, forKey: "savedFeeds\(didSuffix)")

      // Store feed generator info (URI -> display name mapping, DID-scoped)
      let generatorData = try encoder.encode(feedGenerators)
      sharedDefaults.set(generatorData, forKey: "feedGenerators\(didSuffix)")

      logger.info(
        "Updated shared feed preferences: \(pinnedFeeds.count) pinned, \(savedFeeds.count) saved")
    } catch {
      logger.error("Failed to encode feed preferences: \(error.localizedDescription)")
    }
  }

  /// Loads available pinned/saved feeds from shared preferences
  func getAvailableFeeds() -> (pinned: [String], saved: [String], generators: [String: String]) {
    guard let sharedDefaults = sharedDefaults else {
      logger.error("Failed to access shared defaults")
      return ([], [], [:])
    }

    let decoder = JSONDecoder()
    let didSuffix = accountDID.isEmpty ? "" : ".\(accountDID)"

    // Load pinned feeds (DID-scoped)
    let pinnedFeeds: [String] = {
      guard let data = sharedDefaults.data(forKey: "pinnedFeeds\(didSuffix)") else { return [] }
      return (try? decoder.decode([String].self, from: data)) ?? []
    }()

    // Load saved feeds (DID-scoped)
    let savedFeeds: [String] = {
      guard let data = sharedDefaults.data(forKey: "savedFeeds\(didSuffix)") else { return [] }
      return (try? decoder.decode([String].self, from: data)) ?? []
    }()

    // Load feed generators (DID-scoped)
    let feedGenerators: [String: String] = {
      guard let data = sharedDefaults.data(forKey: "feedGenerators\(didSuffix)") else { return [:] }
      return (try? decoder.decode([String: String].self, from: data)) ?? [:]
    }()

    return (pinnedFeeds, savedFeeds, feedGenerators)
  }

  /// Updates widget data with enhanced metadata and configuration support.
  /// Only the Following timeline and feed generators have widget configurations;
  /// lists, profiles and likes are ignored so they never overwrite a widget's posts.
  func updateWidgetDataEnhanced(from posts: [CachedFeedViewPost], feedType: FetchType) {
    guard let configKey = createConfigurationKey(feedType: feedType) else { return }
    guard !accountDID.isEmpty else { return }

    let source = WidgetFeedSource(
      posts: posts.prefix(FeedWidgetPosts.sourceLimit).compactMap { try? $0.feedViewPostBox },
      feedType: mapFeedType(feedType),
      totalPostCount: posts.count,
      loadedAt: Date())
    widgetSources[configKey] = source
    if writeWidgetData(source, configKey: configKey) {
      WidgetCenter.shared.reloadTimelines(ofKind: "CatbirdFeedWidget")
    }
  }

  /// Rewrites every widget feed built this session when the active account's moderation policy
  /// changes, so a stricter setting takes posts and media off the Home Screen right away.
  private func rebuildAfterModerationPolicyChange(originDID: String?) {
    guard !accountDID.isEmpty, originDID == accountDID, !widgetSources.isEmpty else { return }
    var wroteAny = false
    for (configKey, source) in widgetSources where writeWidgetData(source, configKey: configKey) {
      wroteAny = true
    }
    if wroteAny {
      WidgetCenter.shared.reloadTimelines(ofKind: "CatbirdFeedWidget")
    }
  }

  /// Writes the moderated widget posts for one configuration and reports whether it did.
  /// Nothing is written until the widget's account has a server-confirmed moderation policy.
  private func writeWidgetData(_ source: WidgetFeedSource, configKey: String) -> Bool {
    guard let policy = activeModerationPolicy() else {
      logger.info("Skipped widget update until the account's moderation policy is confirmed")
      return false
    }
    guard let sharedDefaults = sharedDefaults else {
      logger.error("Failed to access shared defaults")
      return false
    }

    let widgetPosts = FeedWidgetPosts.make(from: source.posts.map(\.value), policy: policy)
    let feedWidgetData = FeedWidgetDataEnhanced(
      posts: widgetPosts,
      feedType: source.feedType,
      lastUpdated: source.loadedAt,
      totalPostCount: source.totalPostCount
    )

    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(feedWidgetData)

      // Save to the configuration-specific key the widget reads (DID-scoped)
      sharedDefaults.set(data, forKey: "\(configKey).\(accountDID)")

      logger.info(
        "Updated enhanced widget data with \(widgetPosts.count) posts for feed type: \(source.feedType) (key: \(configKey))"
      )
      return true
    } catch {
      logger.error("Failed to encode enhanced widget data: \(error.localizedDescription)")
      return false
    }
  }

  /// The active account's moderation policy, when that account is the widget's account and its
  /// preferences have been confirmed with the server.
  private func activeModerationPolicy() -> ModerationPolicy? {
    guard let appState = AppStateManager.shared.lifecycle.appState,
      appState.userDID == accountDID
    else { return nil }
    let policy = appState.moderationPolicy
    guard policy.isConfirmed, policy.accountDID == accountDID else { return nil }
    return policy
  }

  /// The storage key the widget reads for this feed (same rule as the widget's
  /// FeedWidgetProvider). Nil for feed types no widget configuration can show.
  private func createConfigurationKey(feedType: FetchType) -> String? {
    switch feedType {
    case .timeline:
      return FeedWidgetConstants.timelineConfigKey
    case .feed(let uri):
      return FeedWidgetConstants.configKey(forFeedURI: uri.uriString())
    default:
      return nil
    }
  }

  /// Removes everything the widgets know about `did` (saved posts and feed
  /// preferences) and reloads every widget, so a signed-out or removed account's
  /// posts stop appearing on the Home Screen.
  func clearWidgetData(for did: String) {
    guard !did.isEmpty else { return }
    guard let sharedDefaults = sharedDefaults else {
      logger.error("Failed to access shared defaults")
      return
    }

    let accountPrefixes = [
      "widgetData_", FeedWidgetConstants.feedDataKey, "pinnedFeeds", "savedFeeds", "feedGenerators",
    ]
    let suffix = ".\(did)"
    for key in sharedDefaults.dictionaryRepresentation().keys
    where key.hasSuffix(suffix) && accountPrefixes.contains(where: { key.hasPrefix($0) }) {
      sharedDefaults.removeObject(forKey: key)
    }

    if accountDID == did {
      accountDID = ""
      widgetSources.removeAll()
    }
    WidgetCenter.shared.reloadAllTimelines()

    logger.info("Cleared widget data for a signed-out account")
  }
}

// MARK: - Widget moderation

/// The posts one widget feed was built from.
private struct WidgetFeedSource {
  let posts: [EquatableBox<AppBskyFeedDefs.FeedViewPost>]
  let feedType: String
  let totalPostCount: Int
  /// When the feed delivered these posts; a rebuild keeps it, since the posts are no newer.
  let loadedAt: Date
}

/// Builds the posts the feed widget stores in the shared App Group under the account's moderation
/// policy. The widget is a list surface with no warnings or reveal controls, so a post a list would
/// filter or put behind a warning is left out, and blurred media and avatars are omitted.
enum FeedWidgetPosts {
  /// How many of a feed's newest posts are kept to build widget posts from.
  static let sourceLimit = 30
  /// How many posts the widget data holds.
  static let postLimit = 15

  /// The widget posts for `posts`, in order, at most `postLimit`.
  static func make(from posts: [AppBskyFeedDefs.FeedViewPost], policy: ModerationPolicy) -> [WidgetPost] {
    var result: [WidgetPost] = []
    for post in posts {
      guard let widgetPost = widgetPost(from: post, policy: policy) else { continue }
      result.append(widgetPost)
      if result.count == postLimit { break }
    }
    return result
  }

  /// The widget post for `feedPost`, or `nil` when the widget must not show it: the list context
  /// filters or blurs it. Image and video thumbnails are omitted when the media is blurred, and
  /// the author avatar when the avatar is blurred.
  static func widgetPost(from feedPost: AppBskyFeedDefs.FeedViewPost, policy: ModerationPolicy) -> WidgetPost? {
    let post = feedPost.post
    guard case .knownType(let record) = post.record, let postRecord = record as? AppBskyFeedPost else {
      return nil
    }

    let decision = policy.decide(post: post)
    let list = decision.ui(.contentList)
    guard !list.filter, !list.blur else { return nil }
    let showsMedia = !decision.ui(.contentMedia).blur
    let showsAvatar = !decision.ui(.avatar).blur

    return WidgetPost(
      id: post.cid.string,
      authorName: post.author.displayName ?? post.author.handle.description,
      authorHandle: "@\(post.author.handle)",
      authorAvatarURL: showsAvatar ? post.author.avatar?.uriString() : nil,
      text: postRecord.text.trimmingCharacters(in: .whitespacesAndNewlines),
      timestamp: post.indexedAt.date,
      likeCount: post.likeCount ?? 0,
      repostCount: post.repostCount ?? 0,
      replyCount: post.replyCount ?? 0,
      imageURLs: showsMedia ? mediaURLs(in: post.embed) : [],
      isRepost: feedPost.reason != nil,
      repostAuthorName: repostAuthorName(from: feedPost.reason)
    )
  }

  /// Full-size image URLs, or the video thumbnail, of the post's own media.
  private static func mediaURLs(in embed: AppBskyFeedDefs.PostViewEmbedUnion?) -> [String] {
    switch embed {
    case .appBskyEmbedImagesView(let imagesView):
      return imagesView.images.map { $0.fullsize.uriString() }
    case .appBskyEmbedGalleryView(let galleryView):
      return galleryImageURLs(galleryView)
    case .appBskyEmbedRecordWithMediaView(let recordWithMediaView):
      if case .appBskyEmbedImagesView(let imagesView) = recordWithMediaView.media {
        return imagesView.images.map { $0.fullsize.uriString() }
      }
      if case .appBskyEmbedGalleryView(let galleryView) = recordWithMediaView.media {
        return galleryImageURLs(galleryView)
      }
      return []
    case .appBskyEmbedVideoView(let videoView):
      return [videoView.thumbnail?.uriString()].compactMap { $0 }
    default:
      return []
    }
  }

  private static func galleryImageURLs(_ galleryView: AppBskyEmbedGallery.View) -> [String] {
    galleryView.items.compactMap { item in
      guard case .appBskyEmbedGalleryViewImage(let image) = item else { return nil }
      return image.fullsize.uriString()
    }
  }

  private static func repostAuthorName(from reason: AppBskyFeedDefs.FeedViewPostReasonUnion?) -> String? {
    guard case .appBskyFeedDefsReasonRepost(let repostReason) = reason else { return nil }
    return repostReason.by.displayName ?? repostReason.by.handle.description
  }
}

// MARK: - Widget Models (shared with widget extension)

struct WidgetPost: Codable {
  let id: String
  let authorName: String
  let authorHandle: String
  let authorAvatarURL: String?
  let text: String
  let timestamp: Date
  let likeCount: Int
  let repostCount: Int
  let replyCount: Int
  let imageURLs: [String]
  let isRepost: Bool
  let repostAuthorName: String?
}

struct FeedWidgetData: Codable {
  let posts: [WidgetPost]
  let feedType: String
  let lastUpdated: Date
}

/// Enhanced widget data with additional metadata
struct FeedWidgetDataEnhanced: Codable {
  let posts: [WidgetPost]
  let feedType: String
  let lastUpdated: Date
  let profileHandle: String?
  let totalPostCount: Int

  init(
    posts: [WidgetPost], feedType: String, lastUpdated: Date, profileHandle: String? = nil,
    totalPostCount: Int = 0
  ) {
    self.posts = posts
    self.feedType = feedType
    self.lastUpdated = lastUpdated
    self.profileHandle = profileHandle
    self.totalPostCount = totalPostCount
  }
}

struct FeedWidgetConstants {
  static let sharedSuiteName = "group.blue.catbird.shared"
  static let feedDataKey = "feedWidgetData"
  static let updateInterval: TimeInterval = 15 * 60  // 15 minutes

  /// Storage key for the Following timeline's posts. Must match the widget's
  /// FeedWidgetConstants in CatbirdFeedWidget/FeedWidgetModels.swift.
  static let timelineConfigKey = "widgetData_timeline"

  /// Storage key for one feed generator's posts. Must match the widget's
  /// FeedWidgetConstants.configKey(forFeedURI:) in CatbirdFeedWidget/FeedWidgetModels.swift.
  static func configKey(forFeedURI uri: String) -> String {
    let sanitized = uri
      .replacingOccurrences(of: "at://", with: "")
      .replacingOccurrences(of: "/", with: "_")
    return "widgetData_feed_\(sanitized)"
  }
}
