//
//  FeedPrefetchingManager.swift
//  Catbird
//
//  Created by Josh LaCalamito on 1/31/25.
//

import Foundation
import Petrel
import OSLog
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Manages prefetching of feed data for smoother user experience
actor FeedPrefetchingManager {
    
    private let logger = Logger(subsystem: "blue.catbird", category: "FeedPrefetchingManager")
    
  // MARK: - Properties

  /// Shared singleton instance
  static let shared = FeedPrefetchingManager()

  /// Cache of prefetched feeds indexed by feed type
  private var prefetchedFeeds:
    [String: (posts: [AppBskyFeedDefs.FeedViewPost], cursor: String?, timestamp: Date)] = [:]

  /// Cache of prefetched post embeds for faster display
  private var prefetchedEmbeds: [String: Any] = [:]

  /// Priority queue for prefetching based on viewport visibility
  private var prefetchPriorities: [String: Int] = [:]

  /// Cache expiration time (5 minutes)
  private let cacheExpirationTime: TimeInterval = 300
  
  /// Avatar size used by feed rows (48pt, DesignTokens.Size.avatarLG)
  private static let feedRowAvatarSize: CGFloat = 48.0

  /// Cached display scale for image request building
  private var cachedDisplayScale: CGFloat?

  private func currentDisplayScale() async -> CGFloat {
    if let scale = cachedDisplayScale { return scale }
    let scale = await MainActor.run {
      #if os(iOS)
      return UIScreen.main.scale
      #elseif os(macOS)
      return NSScreen.main?.backingScaleFactor ?? 2.0
      #else
      return 2.0
      #endif
    }
    cachedDisplayScale = scale
    return scale
  }

  private func shouldConcealAvatar(did: String?, labels: [ComAtprotoLabelDefs.Label]?) async -> Bool {
    await MainActor.run {
      AppStateManager.shared.lifecycle.appState?.moderationPolicy.concealsAvatar(did: did, labels: labels) ?? false
    }
  }

  private func isMediaFilteredOrBlurred(post: AppBskyFeedDefs.PostView) async -> Bool {
    await MainActor.run {
      guard let policy = AppStateManager.shared.lifecycle.appState?.moderationPolicy else { return false }
      let media = policy.decide(post: post).ui(.contentMedia)
      return media.filter || media.blur
    }
  }
  // Initialize as private for singleton pattern
  private init() {}

  // MARK: - Public Methods

  /// Prefetch feed data for a specific fetch type with intelligent prioritization
  /// - Parameters:
  ///   - fetchType: The type of feed to prefetch
  ///   - client: The ATProto client for making requests
  ///   - priority: Priority level for prefetching (higher = more important)
  func prefetch(fetchType: FetchType, client: ATProtoClient, priority: Int = 1) async {
    // Create a feed manager for this operation
    let feedManager = FeedManager(client: client, fetchType: fetchType)

    do {
      // Fetch first page of results
      let (posts, cursor) = try await feedManager.fetchFeed(fetchType: fetchType, cursor: nil)

      // Store in cache with current timestamp
      prefetchedFeeds[fetchType.identifier] = (posts, cursor, Date())
      prefetchPriorities[fetchType.identifier] = priority

      // Prefetch assets with priority-based scheduling
      await prefetchAssetsWithPriority(for: posts, priority: priority)
    } catch {
        logger.error("Error prefetching feed: \(error)")
    }
  }
  
  /// Prefetch assets for posts that are about to come into viewport
  /// - Parameters:
  ///   - posts: The posts to prefetch assets for
  ///   - viewportRange: Range of posts currently visible/about to be visible
  func prefetchForViewport(posts: [AppBskyFeedDefs.FeedViewPost], viewportRange: Range<Int>) async {
    // Prefetch assets for posts in and around the viewport
    let prefetchRange = max(0, viewportRange.lowerBound - 5)..<min(posts.count, viewportRange.upperBound + 10)
    let postsToPreload = Array(posts[prefetchRange])
    
    await prefetchAssetsWithPriority(for: postsToPreload, priority: 3)
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

  /// Prefetch assets for cached feed view posts (used by collection view prefetching)
  /// - Parameter posts: Array of cached posts to prefetch assets for
  func prefetchAssets(for posts: [CachedFeedViewPost]) async {
    for post in posts {
      guard let feedViewPost = try? post.feedViewPost else { continue }
      
      // Prefetch avatar the row actually displays (ImageRequestFactory.avatar at 48pt)
      await prefetchAvatarImageOptimized(for: feedViewPost.post.author)
      
      // Skip embed images if media is blurred or filtered by moderation
      if await isMediaFilteredOrBlurred(post: feedViewPost.post) {
        continue
      }
      
      // Prefetch embed images
      if let embed = feedViewPost.post.embed {
        await prefetchEmbedContentOptimized(embed: embed)
      }
    }
  }

  /// Prefetch additional data for a specific post
  /// - Parameters:
  ///   - post: The post to prefetch data for
  ///   - client: The ATProto client for making requests
  func prefetchPostData(post: AppBskyFeedDefs.FeedViewPost, client: ATProtoClient) async {
    await prefetchAvatarImageOptimized(for: post.post.author)

    if let embed = post.post.embed {
      await prefetchEmbedContentOptimized(embed: embed)
    }

    if let reply = post.reply {
      switch reply.parent {
      case .appBskyFeedDefsPostView(let parentPost):
        await prefetchAvatarImageOptimized(for: parentPost.author)
      default:
        break
      }
    }
  }

  func prefetchPostData(post: AppBskyFeedDefs.PostView, client: ATProtoClient) async {
    await prefetchAvatarImageOptimized(for: post.author)
    
    if let embed = post.embed {
      await prefetchEmbedContentOptimized(embed: embed)
    }
  }

  func prefetchPostData(post: AppBskyEmbedRecord.ViewRecord, client: ATProtoClient) async {
    await prefetchAvatarImageOptimized(for: post.author)
    
    if let embeds = post.embeds {
      for embed in embeds {
        await prefetchRecordEmbed(embed)
      }
    }
  }

    
  // MARK: - Private Helper Methods

  /// Prefetch assets for a collection of posts
  private func prefetchAssets(for posts: [AppBskyFeedDefs.FeedViewPost]) async {
    await prefetchAssetsWithPriority(for: posts, priority: 1)
  }
  
  /// Prefetch assets with priority-based scheduling
  private func prefetchAssetsWithPriority(for posts: [AppBskyFeedDefs.FeedViewPost], priority: Int) async {
    // Limit concurrent tasks based on priority
    let maxConcurrentTasks = min(priority * 3, 10) // Higher priority = more concurrent tasks
    
    await withTaskGroup(of: Void.self) { group in
      var activeTasks = 0
      
      for post in posts {
        // Rate limiting: don't overwhelm the system
        if activeTasks >= maxConcurrentTasks {
          await group.next() // Wait for a task to complete
          activeTasks -= 1
        }
        
        group.addTask {
          // Prefetch avatar image if not already cached
          await self.prefetchAvatarImageOptimized(for: post.post.author)

          // Prefetch embedded content if present
          if let embed = post.post.embed {
            await self.prefetchEmbedContentOptimized(embed: embed)
          }
        }
        activeTasks += 1
      }
    }
  }

  /// Prefetch avatar image for a user profile
  private func prefetchAvatarImage(for profile: AppBskyActorDefs.ProfileViewBasic) async {
    await prefetchAvatarImageOptimized(for: profile)
  }
  
  /// Optimized avatar image prefetching with display-size request and moderation gating
  private func prefetchAvatarImageOptimized(for profile: AppBskyActorDefs.ProfileViewBasic) async {
    // P224: Gate on moderation policy so blurred avatars are not downloaded
    if await shouldConcealAvatar(did: profile.did.didString(), labels: profile.labels) {
      return
    }

    let rawURL = profile.finalAvatarURL() ?? profile.avatar.flatMap { URL(string: $0.uriString()) }
    guard let rawURL else { return }

    let scale = await currentDisplayScale()
    guard let request = ImageRequestFactory.avatar(rawURL, pointSize: Self.feedRowAvatarSize, scale: scale) else {
      return
    }

    // Skip if already decoded in memory cache
    if ImageLoadingManager.shared.pipeline.cache[request] != nil {
      return
    }

    await ImageLoadingManager.shared.startPrefetching(requests: [request])
  }

  /// Extract gallery URLs, capping at prefix(3) for 5+ items since only 2-3 fit on screen
  private func extractGalleryURLs(from galleryView: AppBskyEmbedGallery.View) -> [URL] {
    let items = galleryView.items
    let itemsToPrefetch = items.count <= 4 ? items : Array(items.prefix(3))
    return itemsToPrefetch.compactMap { item -> URL? in
      guard case .appBskyEmbedGalleryViewImage(let image) = item else { return nil }
      return URL(string: image.thumbnail.uriString())
    }
  }

  private func prefetchRecordEmbed(_ embed: AppBskyEmbedRecord.ViewRecordEmbedsUnion) async {
    switch embed {
    case .appBskyEmbedImagesView(let imagesView):
      let imageURLs = imagesView.images.compactMap { URL(string: $0.thumb.uriString()) }
      if !imageURLs.isEmpty {
        await ImageLoadingManager.shared.startPrefetching(urls: imageURLs)
      }
    case .appBskyEmbedGalleryView(let galleryView):
      let imageURLs = extractGalleryURLs(from: galleryView)
      if !imageURLs.isEmpty {
        await ImageLoadingManager.shared.startPrefetching(urls: imageURLs)
      }
    case .appBskyEmbedExternalView(let externalView):
      if let thumbURL = externalView.external.thumb.flatMap({ URL(string: $0.uriString()) }) {
        await ImageLoadingManager.shared.startPrefetching(urls: [thumbURL])
      }
    case .appBskyEmbedRecordView(let recordView):
      switch recordView.record {
      case .appBskyEmbedRecordViewRecord(let record):
        await prefetchAvatarImageOptimized(for: record.author)
      default:
        break
      }
    case .appBskyEmbedRecordWithMediaView(let recordWithMediaView):
      switch recordWithMediaView.media {
      case .appBskyEmbedImagesView(let imagesView):
        let imageURLs = imagesView.images.compactMap { URL(string: $0.thumb.uriString()) }
        if !imageURLs.isEmpty {
          await ImageLoadingManager.shared.startPrefetching(urls: imageURLs)
        }
      case .appBskyEmbedGalleryView(let galleryView):
        let imageURLs = extractGalleryURLs(from: galleryView)
        if !imageURLs.isEmpty {
          await ImageLoadingManager.shared.startPrefetching(urls: imageURLs)
        }
      default:
        break
      }
    case .appBskyEmbedVideoView(let videoView):
      if let thumbURL = videoView.thumbnail?.url {
        await ImageLoadingManager.shared.startPrefetching(urls: [thumbURL])
      }
    case .unexpected:
      break
    }
  }
  /// Prefetch content for post embeds
  private func prefetchEmbedContent(embed: AppBskyFeedDefs.PostViewEmbedUnion) async {
    await prefetchEmbedContentOptimized(embed: embed)
  }
  
  
  /// Optimized embed content prefetching with deduplication
  private func prefetchEmbedContentOptimized(embed: AppBskyFeedDefs.PostViewEmbedUnion) async {
    switch embed {
    case .appBskyEmbedImagesView(let imagesView):
      let imageURLs = imagesView.images.compactMap { URL(string: $0.thumb.uriString()) }
      if !imageURLs.isEmpty {
        await ImageLoadingManager.shared.startPrefetching(urls: imageURLs)
      }

    case .appBskyEmbedGalleryView(let galleryView):
      let imageURLs = extractGalleryURLs(from: galleryView)
      if !imageURLs.isEmpty {
        await ImageLoadingManager.shared.startPrefetching(urls: imageURLs)
      }

    case .appBskyEmbedExternalView(let externalView):
      if let thumbURL = externalView.external.thumb.flatMap({ URL(string: $0.uriString()) }) {
        await ImageLoadingManager.shared.startPrefetching(urls: [thumbURL])
      }

    case .appBskyEmbedRecordView(let recordView):
      switch recordView.record {
      case .appBskyEmbedRecordViewRecord(let record):
        await prefetchAvatarImageOptimized(for: record.author)
      default:
        break
      }

    case .appBskyEmbedRecordWithMediaView(let recordWithMediaView):
      switch recordWithMediaView.media {
      case .appBskyEmbedImagesView(let imagesView):
        let imageURLs = imagesView.images.compactMap { URL(string: $0.thumb.uriString()) }
        if !imageURLs.isEmpty {
          await ImageLoadingManager.shared.startPrefetching(urls: imageURLs)
        }
      case .appBskyEmbedGalleryView(let galleryView):
        let imageURLs = extractGalleryURLs(from: galleryView)
        if !imageURLs.isEmpty {
          await ImageLoadingManager.shared.startPrefetching(urls: imageURLs)
        }
      default:
        break
      }

    case .appBskyEmbedVideoView(let videoView):
      if let thumbURL = videoView.thumbnail?.url {
        await ImageLoadingManager.shared.startPrefetching(urls: [thumbURL])
      }

    case .unexpected:
      break
    }
  }
}
