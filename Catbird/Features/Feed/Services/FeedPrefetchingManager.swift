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

  private func currentPrefetchContext() async -> (policy: ModerationPolicy?, scale: CGFloat) {
    let cachedScale = cachedDisplayScale
    let (policy, scale) = await MainActor.run { () -> (ModerationPolicy?, CGFloat) in
      let policy = AppStateManager.shared.lifecycle.appState?.moderationPolicy
      if let cachedScale {
        return (policy, cachedScale)
      }
      #if os(iOS)
      let resolvedScale = UIScreen.main.scale
      #elseif os(macOS)
      let resolvedScale = NSScreen.main?.backingScaleFactor ?? 2.0
      #else
      let resolvedScale = 2.0
      #endif
      return (policy, resolvedScale)
    }
    if cachedDisplayScale == nil {
      cachedDisplayScale = scale
    }
    return (policy, scale)
  }

  nonisolated private func shouldConcealAvatar(
    did: String?,
    labels: [ComAtprotoLabelDefs.Label]?,
    policy: ModerationPolicy?
  ) -> Bool {
    policy?.concealsAvatar(did: did, labels: labels) ?? false
  }

  nonisolated private func isMediaFilteredOrBlurred(
    post: AppBskyFeedDefs.PostView,
    policy: ModerationPolicy?
  ) -> Bool {
    guard let policy else { return false }
    let media = policy.decide(post: post).ui(.contentMedia)
    return media.filter || media.blur
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
    guard !posts.isEmpty, !Task.isCancelled else { return }
    let (decodedPosts, policy, scale) = await MainActor.run { () -> ([AppBskyFeedDefs.FeedViewPost], ModerationPolicy?, CGFloat) in
      let decoded = posts.compactMap { try? $0.feedViewPost }
      let policy = AppStateManager.shared.lifecycle.appState?.moderationPolicy
      #if os(iOS)
      let scale = UIScreen.main.scale
      #elseif os(macOS)
      let scale = NSScreen.main?.backingScaleFactor ?? 2.0
      #else
      let scale = 2.0
      #endif
      return (decoded, policy, scale)
    }
    if cachedDisplayScale == nil {
      cachedDisplayScale = scale
    }

    for feedViewPost in decodedPosts {
      guard !Task.isCancelled else { return }

      // Prefetch avatar the row actually displays (ImageRequestFactory.avatar at 48pt)
      await prefetchAvatarImageOptimized(
        for: feedViewPost.post.author,
        policy: policy,
        scale: scale
      )

      // Skip embed images if media is blurred or filtered by moderation
      if isMediaFilteredOrBlurred(post: feedViewPost.post, policy: policy) {
        continue
      }

      // Prefetch embed images
      if let embed = feedViewPost.post.embed {
        await prefetchEmbedContentOptimized(embed: embed, policy: policy, scale: scale)
      }
    }
  }

  /// Prefetch additional data for a specific post
  /// - Parameters:
  ///   - post: The post to prefetch data for
  ///   - client: The ATProto client for making requests
  func prefetchPostData(post: AppBskyFeedDefs.FeedViewPost, client: ATProtoClient) async {
    guard !Task.isCancelled else { return }
    let (policy, scale) = await currentPrefetchContext()
    await prefetchAvatarImageOptimized(for: post.post.author, policy: policy, scale: scale)

    if !isMediaFilteredOrBlurred(post: post.post, policy: policy),
       let embed = post.post.embed {
      await prefetchEmbedContentOptimized(embed: embed, policy: policy, scale: scale)
    }

    if let reply = post.reply {
      switch reply.parent {
      case .appBskyFeedDefsPostView(let parentPost):
        await prefetchAvatarImageOptimized(for: parentPost.author, policy: policy, scale: scale)
      default:
        break
      }
    }
  }

  func prefetchPostData(post: AppBskyFeedDefs.PostView, client: ATProtoClient) async {
    guard !Task.isCancelled else { return }
    let (policy, scale) = await currentPrefetchContext()
    await prefetchAvatarImageOptimized(for: post.author, policy: policy, scale: scale)
    
    if !isMediaFilteredOrBlurred(post: post, policy: policy),
       let embed = post.embed {
      await prefetchEmbedContentOptimized(embed: embed, policy: policy, scale: scale)
    }
  }

  func prefetchPostData(post: AppBskyEmbedRecord.ViewRecord, client: ATProtoClient) async {
    guard !Task.isCancelled else { return }
    let (policy, scale) = await currentPrefetchContext()
    await prefetchAvatarImageOptimized(for: post.author, policy: policy, scale: scale)
    
    if let embeds = post.embeds {
      for embed in embeds {
        guard !Task.isCancelled else { return }
        await prefetchRecordEmbed(embed, policy: policy, scale: scale)
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
    guard !posts.isEmpty, !Task.isCancelled else { return }
    let (policy, scale) = await currentPrefetchContext()
    // Limit concurrent tasks based on priority
    let maxConcurrentTasks = min(priority * 3, 10) // Higher priority = more concurrent tasks
    
    await withTaskGroup(of: Void.self) { group in
      var activeTasks = 0
      
      for post in posts {
        guard !Task.isCancelled else { break }
        // Rate limiting: don't overwhelm the system
        if activeTasks >= maxConcurrentTasks {
          await group.next() // Wait for a task to complete
          activeTasks -= 1
        }
        
        group.addTask {
          guard !Task.isCancelled else { return }
          // Prefetch avatar image if not already cached
          await self.prefetchAvatarImageOptimized(for: post.post.author, policy: policy, scale: scale)

          // Prefetch embedded content if present
          if !self.isMediaFilteredOrBlurred(post: post.post, policy: policy),
             let embed = post.post.embed {
            await self.prefetchEmbedContentOptimized(embed: embed, policy: policy, scale: scale)
          }
        }
        activeTasks += 1
      }
    }
  }

  /// Prefetch avatar image for a user profile
  private func prefetchAvatarImage(for profile: AppBskyActorDefs.ProfileViewBasic) async {
    let (policy, scale) = await currentPrefetchContext()
    await prefetchAvatarImageOptimized(for: profile, policy: policy, scale: scale)
  }
  
  /// Optimized avatar image prefetching with display-size request and moderation gating
  private func prefetchAvatarImageOptimized(
    for profile: AppBskyActorDefs.ProfileViewBasic,
    policy: ModerationPolicy?,
    scale: CGFloat
  ) async {
    guard !Task.isCancelled else { return }
    // P224: Gate on moderation policy so blurred avatars are not downloaded
    if shouldConcealAvatar(did: profile.did.didString(), labels: profile.labels, policy: policy) {
      return
    }

    let rawURL = profile.finalAvatarURL() ?? profile.avatar.flatMap { URL(string: $0.uriString()) }
    guard let rawURL else { return }

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

  private func prefetchRecordEmbed(
    _ embed: AppBskyEmbedRecord.ViewRecordEmbedsUnion,
    policy: ModerationPolicy?,
    scale: CGFloat
  ) async {
    guard !Task.isCancelled else { return }
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
        await prefetchAvatarImageOptimized(for: record.author, policy: policy, scale: scale)
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
    let (policy, scale) = await currentPrefetchContext()
    await prefetchEmbedContentOptimized(embed: embed, policy: policy, scale: scale)
  }
  
  
  /// Optimized embed content prefetching with deduplication
  private func prefetchEmbedContentOptimized(
    embed: AppBskyFeedDefs.PostViewEmbedUnion,
    policy: ModerationPolicy?,
    scale: CGFloat
  ) async {
    guard !Task.isCancelled else { return }
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
        await prefetchAvatarImageOptimized(for: record.author, policy: policy, scale: scale)
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
