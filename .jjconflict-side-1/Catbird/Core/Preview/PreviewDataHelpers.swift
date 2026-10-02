import Foundation
import Petrel
import SwiftUI

// MARK: - Preview Data Helpers

/// Fetches and caches real AT Protocol data for use in previews.
/// All methods require an authenticated AppState from PreviewContainer.
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
  static func timelinePosts(from appState: AppState) async -> [AppBskyFeedDefs.FeedViewPost] {
    if let cached = cachedTimelinePosts { return cached }
    guard let client = appState.atProtoClient else { return [] }
    do {
      let (_, output) = try await client.app.bsky.feed.getTimeline(
        input: .init(limit: 10)
      )
      guard let output else { return [] }
      cachedTimelinePosts = output.feed
      return output.feed
    } catch {
      return []
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
  static func myProfile(from appState: AppState) async -> AppBskyActorDefs.ProfileViewDetailed? {
    if let cached = cachedProfile { return cached }
    guard let client = appState.atProtoClient else { return nil }
    do {
      let (_, output) = try await client.app.bsky.actor.getProfile(
        input: .init(actor: try ATIdentifier(string: appState.userDID))
      )
      cachedProfile = output
      return output
    } catch {
      return nil
    }
  }

  // MARK: - Suggested Profiles

  /// Fetches suggested profiles for search/discovery previews.
  static func suggestedProfiles(from appState: AppState) async -> [AppBskyActorDefs.ProfileView] {
    if let cached = cachedSuggestedProfiles { return cached }
    guard let client = appState.atProtoClient else { return [] }
    do {
      let (_, output) = try await client.app.bsky.actor.getSuggestions(
        input: .init(limit: 10)
      )
      guard let output else { return [] }
      cachedSuggestedProfiles = output.actors
      return output.actors
    } catch {
      return []
    }
  }

  // MARK: - Popular Feeds

  /// Fetches popular/suggested feeds for discovery previews.
  static func popularFeeds(from appState: AppState) async -> [AppBskyFeedDefs.GeneratorView] {
    if let cached = cachedPopularFeeds { return cached }
    guard let client = appState.atProtoClient else { return [] }
    do {
      let (_, output) = try await client.app.bsky.feed.getSuggestedFeeds(
        input: .init(limit: 10)
      )
      guard let output else { return [] }
      cachedPopularFeeds = output.feeds
      return output.feeds
    } catch {
      return []
    }
  }

  // MARK: - Notifications

  /// Fetches recent notifications.
  static func notifications(from appState: AppState) async -> [AppBskyNotificationListNotifications.Notification] {
    if let cached = cachedNotifications { return cached }
    guard let client = appState.atProtoClient else { return [] }
    do {
      let (_, output) = try await client.app.bsky.notification.listNotifications(
        input: .init(limit: 10)
      )
      guard let output else { return [] }
      cachedNotifications = output.notifications
      return output.notifications
    } catch {
      return []
    }
  }

  // MARK: - Derived Data

  /// Returns the first post that has an image embed.
  static func firstPostWithImages(from appState: AppState) async -> (post: AppBskyFeedDefs.PostView, images: [AppBskyEmbedImages.ViewImage])? {
    let posts = await timelinePosts(from: appState)
    for feedPost in posts {
      if case .appBskyEmbedImagesView(let imagesView) = feedPost.post.embed {
        return (feedPost.post, imagesView.images)
      }
    }
    return nil
  }

  /// Returns the first post that has an external embed.
  static func firstPostWithExternalEmbed(from appState: AppState) async -> (post: AppBskyFeedDefs.PostView, external: AppBskyEmbedExternal.ViewExternal)? {
    let posts = await timelinePosts(from: appState)
    for feedPost in posts {
      if case .appBskyEmbedExternalView(let externalView) = feedPost.post.embed {
        return (feedPost.post, externalView.external)
      }
    }
    return nil
  }

  /// Returns the first post that has any embed.
  static func firstPostWithEmbed(from appState: AppState) async -> (post: AppBskyFeedDefs.PostView, embed: AppBskyFeedDefs.PostViewEmbedUnion)? {
    let posts = await timelinePosts(from: appState)
    for feedPost in posts where feedPost.post.embed != nil {
      return (feedPost.post, feedPost.post.embed!)
    }
    return nil
  }

  /// Returns the first post with a repost (by someone).
  static func firstRepost(from appState: AppState) async -> AppBskyFeedDefs.FeedViewPost? {
    let posts = await timelinePosts(from: appState)
    return posts.first { $0.reason != nil }
  }
}
