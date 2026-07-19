import Foundation
import Petrel
import SwiftUI

// MARK: - Preview Data Helpers

/// Fetches and caches real AT Protocol data for use in previews.
///
/// Live-first: every fetcher below tries `appState.atProtoClient` first. When there's no
/// client (unauthenticated preview) or the live fetch fails, it falls back to the static
/// `PreviewFixtures` corpus instead of returning nil/empty — so previews render varied,
/// schema-correct data with zero credentials. Fixture fallback is DEBUG-only, matching
/// `PreviewFixtures` itself.
@MainActor
enum PreviewData {

  // MARK: - Cache

  private static var cachedTimelinePosts: [AppBskyFeedDefs.FeedViewPost]?
  private static var cachedProfile: AppBskyActorDefs.ProfileViewDetailed?
  private static var cachedSuggestedProfiles: [AppBskyActorDefs.ProfileView]?
  private static var cachedPopularFeeds: [AppBskyFeedDefs.GeneratorView]?
  private static var cachedNotifications: [AppBskyNotificationListNotifications.Notification]?

  // MARK: - Timeline Posts

  /// Fetches a page of timeline posts. Returns cached results on subsequent calls.
  /// Falls back to the fixture timeline when unauthenticated or on fetch failure.
  static func timelinePosts(from appState: AppState) async -> [AppBskyFeedDefs.FeedViewPost] {
    if let cached = cachedTimelinePosts { return cached }
    guard let client = appState.atProtoClient else { return fallbackTimeline() }
    do {
      let (_, output) = try await client.app.bsky.feed.getTimeline(
        input: .init(limit: 10)
      )
      guard let output, !output.feed.isEmpty else { return fallbackTimeline() }
      cachedTimelinePosts = output.feed
      return output.feed
    } catch {
      return fallbackTimeline()
    }
  }

  /// Returns the first post from the timeline, or nil.
  static func firstPost(from appState: AppState) async -> AppBskyFeedDefs.FeedViewPost? {
    await timelinePosts(from: appState).first
  }

  /// Returns the first post's PostView (the inner view model), or nil.
  static func firstPostView(from appState: AppState) async -> AppBskyFeedDefs.PostView? {
    await firstPost(from: appState)?.post
  }

  // MARK: - Profile

  /// Fetches the authenticated user's profile.
  /// Falls back to the fixture bot's profile when unauthenticated or on fetch failure.
  static func myProfile(from appState: AppState) async -> AppBskyActorDefs.ProfileViewDetailed? {
    if let cached = cachedProfile { return cached }
    guard let client = appState.atProtoClient else { return fallbackProfileBot() }
    do {
      let (_, output) = try await client.app.bsky.actor.getProfile(
        input: .init(actor: try ATIdentifier(string: appState.userDID))
      )
      cachedProfile = output
      return output
    } catch {
      return fallbackProfileBot()
    }
  }

  // MARK: - Suggested Profiles

  /// Fetches suggested profiles for search/discovery previews.
  /// Falls back to the fixture search-actors results when unauthenticated or on fetch failure.
  static func suggestedProfiles(from appState: AppState) async -> [AppBskyActorDefs.ProfileView] {
    if let cached = cachedSuggestedProfiles { return cached }
    guard let client = appState.atProtoClient else { return fallbackSearchActors() }
    do {
      let (_, output) = try await client.app.bsky.actor.getSuggestions(
        input: .init(limit: 10)
      )
      guard let output, !output.actors.isEmpty else { return fallbackSearchActors() }
      cachedSuggestedProfiles = output.actors
      return output.actors
    } catch {
      return fallbackSearchActors()
    }
  }

  // MARK: - Popular Feeds

  /// Fetches popular/suggested feeds for discovery previews.
  /// Falls back to the fixture feed generators when unauthenticated or on fetch failure.
  static func popularFeeds(from appState: AppState) async -> [AppBskyFeedDefs.GeneratorView] {
    if let cached = cachedPopularFeeds { return cached }
    guard let client = appState.atProtoClient else { return fallbackFeedGenerators() }
    do {
      let (_, output) = try await client.app.bsky.feed.getSuggestedFeeds(
        input: .init(limit: 10)
      )
      guard let output, !output.feeds.isEmpty else { return fallbackFeedGenerators() }
      cachedPopularFeeds = output.feeds
      return output.feeds
    } catch {
      return fallbackFeedGenerators()
    }
  }

  // MARK: - Notifications

  /// Fetches recent notifications.
  /// Falls back to the fixture notifications (all reason kinds represented) when
  /// unauthenticated or on fetch failure.
  static func notifications(from appState: AppState) async -> [AppBskyNotificationListNotifications.Notification] {
    if let cached = cachedNotifications { return cached }
    guard let client = appState.atProtoClient else { return fallbackNotifications() }
    do {
      let (_, output) = try await client.app.bsky.notification.listNotifications(
        input: .init(limit: 10)
      )
      guard let output, !output.notifications.isEmpty else { return fallbackNotifications() }
      cachedNotifications = output.notifications
      return output.notifications
    } catch {
      return fallbackNotifications()
    }
  }

  // MARK: - Derived Data

  /// Returns the first post that has an image embed.
  /// Falls back to the fixture `images_4` shape if none of the live/fixture timeline posts have one.
  static func firstPostWithImages(from appState: AppState) async -> (post: AppBskyFeedDefs.PostView, images: [AppBskyEmbedImages.ViewImage])? {
    let posts = await timelinePosts(from: appState)
    for feedPost in posts {
      if case .appBskyEmbedImagesView(let imagesView) = feedPost.post.embed {
        return (feedPost.post, imagesView.images)
      }
    }
    #if DEBUG
    if let post = PreviewFixtures.post(.images4), case .appBskyEmbedImagesView(let imagesView) = post.embed {
      return (post, imagesView.images)
    }
    #endif
    return nil
  }

  /// Returns the first post that has an external embed.
  /// Falls back to the fixture `external` shape if none of the live/fixture timeline posts have one.
  static func firstPostWithExternalEmbed(from appState: AppState) async -> (post: AppBskyFeedDefs.PostView, external: AppBskyEmbedExternal.ViewExternal)? {
    let posts = await timelinePosts(from: appState)
    for feedPost in posts {
      if case .appBskyEmbedExternalView(let externalView) = feedPost.post.embed {
        return (feedPost.post, externalView.external)
      }
    }
    #if DEBUG
    if let post = PreviewFixtures.post(.external), case .appBskyEmbedExternalView(let externalView) = post.embed {
      return (post, externalView.external)
    }
    #endif
    return nil
  }

  /// Returns the first post that has any embed.
  /// Falls back to the fixture `images_1` shape if none of the live/fixture timeline posts have one.
  static func firstPostWithEmbed(from appState: AppState) async -> (post: AppBskyFeedDefs.PostView, embed: AppBskyFeedDefs.PostViewEmbedUnion)? {
    let posts = await timelinePosts(from: appState)
    for feedPost in posts where feedPost.post.embed != nil {
      return (feedPost.post, feedPost.post.embed!)
    }
    #if DEBUG
    if let post = PreviewFixtures.post(.images1), let embed = post.embed {
      return (post, embed)
    }
    #endif
    return nil
  }

  /// Returns the first post with a repost (by someone).
  /// Falls back to the fixture repost entry if none of the live/fixture timeline posts have one.
  static func firstRepost(from appState: AppState) async -> AppBskyFeedDefs.FeedViewPost? {
    let posts = await timelinePosts(from: appState)
    if let repost = posts.first(where: { $0.reason != nil }) { return repost }
    #if DEBUG
    return PreviewFixtures.repostFeedViewPost
    #else
    return nil
    #endif
  }

  // MARK: - Fixture-only Synchronous Helpers

  #if DEBUG
  /// Synchronous, always-available fixture post lookup by shape — no network, no auth.
  /// Used by `.mock`-mode and fixture-first `#Preview` blocks.
  static func fixturePost(_ shape: PreviewFixtures.PostShape) -> AppBskyFeedDefs.PostView? {
    PreviewFixtures.post(shape)
  }

  /// Synchronous, always-available fixture timeline feed.
  static func fixtureTimeline() -> [AppBskyFeedDefs.FeedViewPost] {
    PreviewFixtures.timeline?.feed ?? []
  }
  #endif

  // MARK: - Private Fixture Fallbacks
  //
  // Distinct names from the public `fixturePost`/`fixtureTimeline` API above: these are
  // unconditionally declared (so live fetchers above can call them outside `#if DEBUG`),
  // whereas the public API mirrors `PreviewFixtures`' own DEBUG-only availability.

  private static func fallbackTimeline() -> [AppBskyFeedDefs.FeedViewPost] {
    #if DEBUG
    PreviewFixtures.timeline?.feed ?? []
    #else
    []
    #endif
  }

  private static func fallbackProfileBot() -> AppBskyActorDefs.ProfileViewDetailed? {
    #if DEBUG
    PreviewFixtures.profileBot
    #else
    nil
    #endif
  }

  private static func fallbackSearchActors() -> [AppBskyActorDefs.ProfileView] {
    #if DEBUG
    PreviewFixtures.searchActors?.actors ?? []
    #else
    []
    #endif
  }

  private static func fallbackFeedGenerators() -> [AppBskyFeedDefs.GeneratorView] {
    #if DEBUG
    PreviewFixtures.feedGenerators?.feeds ?? []
    #else
    []
    #endif
  }

  private static func fallbackNotifications() -> [AppBskyNotificationListNotifications.Notification] {
    #if DEBUG
    PreviewFixtures.notifications?.notifications ?? []
    #else
    []
    #endif
  }
}
