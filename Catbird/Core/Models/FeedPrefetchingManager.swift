//
//  FeedPrefetchingManager.swift
//  Catbird
//
//  Created by Josh LaCalamito on 1/31/25.
//

import Foundation
import Petrel

/// Manages prefetching of feed data for smoother user experience
actor FeedPrefetchingManager {
  // MARK: - Properties

  /// Shared singleton instance
  static let shared = FeedPrefetchingManager()

  /// Cache of prefetched feeds indexed by feed type
  private var prefetchedFeeds:
    [String: (posts: [AppBskyFeedDefs.FeedViewPost], cursor: String?, timestamp: Date)] = [:]

  /// Cache of prefetched post embeds for faster display
  private var prefetchedEmbeds: [String: Any] = [:]

  /// Cache expiration time (5 minutes)
  private let cacheExpirationTime: TimeInterval = 300

  // Initialize as private for singleton pattern
  private init() {}

  // MARK: - Public Methods

  /// Prefetch feed data for a specific fetch type
  /// - Parameters:
  ///   - fetchType: The type of feed to prefetch
  ///   - client: The ATProto client for making requests
  func prefetch(fetchType: FetchType, client: ATProtoClient) async {
    // Create a feed manager for this operation
    let feedManager = FeedManager(client: client, fetchType: fetchType)

    do {
      // Fetch first page of results
      let (posts, cursor) = try await feedManager.fetchFeed(fetchType: fetchType, cursor: nil)

      // Store in cache with current timestamp
      prefetchedFeeds[fetchType.identifier] = (posts, cursor, Date())

      // Prefetch avatar images and other assets
      await prefetchAssets(for: posts)
    } catch {
      print("Error prefetching feed: \(error)")
    }
  }

  /// Get a prefetched feed if available and not expired
  /// - Parameter fetchType: The type of feed to retrieve
  /// - Returns: Tuple with posts and cursor if available
  func getPrefetchedFeed(for fetchType: FetchType) -> (
    posts: [AppBskyFeedDefs.FeedViewPost], cursor: String?
  )? {
    guard let cachedFeed = prefetchedFeeds[fetchType.identifier] else {
      return nil
    }

    // Check if cache is expired
    if Date().timeIntervalSince(cachedFeed.timestamp) > cacheExpirationTime {
      prefetchedFeeds.removeValue(forKey: fetchType.identifier)
      return nil
    }

    return (cachedFeed.posts, cachedFeed.cursor)
  }

  /// Prefetch additional data for a specific post
  /// - Parameters:
  ///   - post: The post to prefetch data for
  ///   - client: The ATProto client for making requests
  func prefetchPostData(post: AppBskyFeedDefs.FeedViewPost, client: ATProtoClient) async {
    // Prefetch avatar image
    await prefetchAvatarImage(for: post.post.author)

    // Prefetch embedded content if present
    if let embed = post.post.embed {
      await prefetchEmbedContent(embed: embed)
    }

    // For replies, prefetch parent post data
    if let reply = post.reply {
      switch reply.parent {
      case .appBskyFeedDefsPostView(let parentPost):
        await prefetchAvatarImage(for: parentPost.author)
      default:
        break
      }
    }
  }

  // MARK: - Private Helper Methods

  /// Prefetch assets for a collection of posts
  private func prefetchAssets(for posts: [AppBskyFeedDefs.FeedViewPost]) async {
    // Create task group for concurrent prefetching
    await withTaskGroup(of: Void.self) { group in
      for post in posts {
        group.addTask {
          // Prefetch avatar image
          await self.prefetchAvatarImage(for: post.post.author)

          // Prefetch embedded content if present
          if let embed = post.post.embed {
            await self.prefetchEmbedContent(embed: embed)
          }
        }
      }
    }
  }

  /// Prefetch avatar image for a user profile
  private func prefetchAvatarImage(for profile: AppBskyActorDefs.ProfileViewBasic) async {
    guard let avatarURL = profile.finalAvatarURL() else { return }

    // Remove try-catch since no errors are thrown
    let manager = ImageLoadingManager.shared
    await manager.startPrefetching(urls: [avatarURL])
  }

  /// Prefetch content for post embeds
  private func prefetchEmbedContent(embed: AppBskyFeedDefs.PostViewEmbedUnion) async {
    switch embed {
    case .appBskyEmbedImagesView(let imagesView):
      // Prefetch all images in the embed
      let imageURLs = imagesView.images.compactMap {
        URL(string: $0.thumb.uriString())
      }

      if !imageURLs.isEmpty {
        let manager = ImageLoadingManager.shared
        await manager.startPrefetching(urls: imageURLs)
      }

    case .appBskyEmbedExternalView(let externalView):
      // Prefetch external thumbnail if available
      if let thumbURL = externalView.external.thumb.flatMap({ URL(string: $0.uriString()) }) {
        let manager = ImageLoadingManager.shared
        await manager.startPrefetching(urls: [thumbURL])
      }

    case .appBskyEmbedRecordView(let recordView):
      // For record embeds, prefetch the author's avatar
      switch recordView.record {
      case .appBskyEmbedRecordViewRecord(let record):
        await prefetchAvatarImage(for: record.author)
      default:
        break
      }

    case .appBskyEmbedRecordWithMediaView(let recordWithMediaView):
      // Prefetch media in record with media embeds
      switch recordWithMediaView.media {
      case .appBskyEmbedImagesView(let imagesView):
        let imageURLs = imagesView.images.compactMap {
          URL(string: $0.thumb.uriString())
        }

        if !imageURLs.isEmpty {
          let manager = ImageLoadingManager.shared
          await manager.startPrefetching(urls: imageURLs)
        }
      default:
        break
      }

    case .appBskyEmbedVideoView(_):
      // Remove unused variable declaration
      // For video embeds, we could potentially prefetch video thumbnails
      // but actual video prefetching would likely use too much data
      break

    case .unexpected:
      break
    }
  }
}
