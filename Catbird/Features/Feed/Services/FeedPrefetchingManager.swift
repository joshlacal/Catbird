//
//  FeedPrefetchingManager.swift
//  Catbird
//
//  Created by Josh LaCalamito on 1/31/25.
//

import Foundation
import Petrel
import OSLog

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
  
  /// Cache of prefetched assets to avoid redundant requests
  private var prefetchedAssets: Set<String> = []
  
  /// Priority queue for prefetching based on viewport visibility
  private var prefetchPriorities: [String: Int] = [:]

  /// Cache expiration time (5 minutes)
  private let cacheExpirationTime: TimeInterval = 300
  
  /// Asset cache expiration time (10 minutes)
  private let assetCacheExpirationTime: TimeInterval = 600

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

    func prefetchPostData(post: AppBskyFeedDefs.PostView, client: ATProtoClient) async {
        // Prefetch avatar image
        await prefetchAvatarImage(for: post.author)
        
        // Prefetch embedded content if present
        if let embed = post.embed {
            await prefetchEmbedContent(embed: embed)
        }

    }
    
    
    
    func prefetchPostData(post: AppBskyEmbedRecord.ViewRecord, client: ATProtoClient) async {
        // Prefetch avatar image
        await prefetchAvatarImage(for: post.author)
        
        // Prefetch embedded content if present
        if let embeds = post.embeds {
            await prefetchEmbedContent(embeds: embeds)
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
  
  /// Optimized avatar image prefetching with deduplication
  private func prefetchAvatarImageOptimized(for profile: AppBskyActorDefs.ProfileViewBasic) async {
    guard let avatarURL = profile.finalAvatarURL() else { return }
    
    let urlString = avatarURL.absoluteString
    
    // Skip if already prefetched recently
    guard !prefetchedAssets.contains(urlString) else { return }
    
    // Mark as prefetched to avoid duplicates
    prefetchedAssets.insert(urlString)
    
    let manager = ImageLoadingManager.shared
    await manager.startPrefetching(urls: [avatarURL])
    
    // Clean up old assets periodically (simple LRU)
    if prefetchedAssets.count > 1000 {
      cleanupOldAssets()
    }
  }
  
  /// Clean up old prefetched assets to prevent memory growth
  private func cleanupOldAssets() {
    // Remove random 20% of cached assets to implement simple cache eviction
    let assetsToRemove = prefetchedAssets.prefix(prefetchedAssets.count / 5)
    prefetchedAssets.subtract(assetsToRemove)
  }

  /// Prefetch content for post embeds
  private func prefetchEmbedContent(embed: AppBskyFeedDefs.PostViewEmbedUnion) async {
    await prefetchEmbedContentOptimized(embed: embed)
  }
  
  private func prefetchEmbedContent(embeds: [AppBskyEmbedRecord.ViewRecordEmbedsUnion]) async {
      for embed in embeds {
          switch embed {
          case .appBskyEmbedImagesView(let imagesView):
            // Prefetch all images in the embed with deduplication
            let imageURLs = imagesView.images.compactMap {
              URL(string: $0.thumb.uriString())
            }.filter { url in
              !prefetchedAssets.contains(url.absoluteString)
            }

            if !imageURLs.isEmpty {
              // Mark as prefetched
              for url in imageURLs {
                prefetchedAssets.insert(url.absoluteString)
              }
              
              let manager = ImageLoadingManager.shared
              await manager.startPrefetching(urls: imageURLs)
            }

          case .appBskyEmbedExternalView(let externalView):
            // Prefetch external thumbnail if available
            if let thumbURL = externalView.external.thumb.flatMap({ URL(string: $0.uriString()) }),
               !prefetchedAssets.contains(thumbURL.absoluteString) {
              prefetchedAssets.insert(thumbURL.absoluteString)
              
              let manager = ImageLoadingManager.shared
              await manager.startPrefetching(urls: [thumbURL])
            }

          case .appBskyEmbedRecordView(let recordView):
            // For record embeds, prefetch the author's avatar
            switch recordView.record {
            case .appBskyEmbedRecordViewRecord(let record):
              await prefetchAvatarImageOptimized(for: record.author)
            default:
              break
            }

          case .appBskyEmbedRecordWithMediaView(let recordWithMediaView):
            // Prefetch media in record with media embeds
            switch recordWithMediaView.media {
            case .appBskyEmbedImagesView(let imagesView):
              let imageURLs = imagesView.images.compactMap {
                URL(string: $0.thumb.uriString())
              }.filter { url in
                !prefetchedAssets.contains(url.absoluteString)
              }

              if !imageURLs.isEmpty {
                // Mark as prefetched
                for url in imageURLs {
                  prefetchedAssets.insert(url.absoluteString)
                }
                
                let manager = ImageLoadingManager.shared
                await manager.startPrefetching(urls: imageURLs)
              }
            default:
              break
            }

          case .appBskyEmbedVideoView:
            // For video embeds, we could potentially prefetch video thumbnails
            // but actual video prefetching would likely use too much data
            break

          case .unexpected:
            break
          }

      }

  }
  
  /// Optimized embed content prefetching with deduplication
  private func prefetchEmbedContentOptimized(embed: AppBskyFeedDefs.PostViewEmbedUnion) async {
    switch embed {
    case .appBskyEmbedImagesView(let imagesView):
      // Prefetch all images in the embed with deduplication
      let imageURLs = imagesView.images.compactMap {
        URL(string: $0.thumb.uriString())
      }.filter { url in
        !prefetchedAssets.contains(url.absoluteString)
      }

      if !imageURLs.isEmpty {
        // Mark as prefetched
        for url in imageURLs {
          prefetchedAssets.insert(url.absoluteString)
        }
        
        let manager = ImageLoadingManager.shared
        await manager.startPrefetching(urls: imageURLs)
      }

    case .appBskyEmbedExternalView(let externalView):
      // Prefetch external thumbnail if available
      if let thumbURL = externalView.external.thumb.flatMap({ URL(string: $0.uriString()) }),
         !prefetchedAssets.contains(thumbURL.absoluteString) {
        prefetchedAssets.insert(thumbURL.absoluteString)
        
        let manager = ImageLoadingManager.shared
        await manager.startPrefetching(urls: [thumbURL])
      }

    case .appBskyEmbedRecordView(let recordView):
      // For record embeds, prefetch the author's avatar
      switch recordView.record {
      case .appBskyEmbedRecordViewRecord(let record):
        await prefetchAvatarImageOptimized(for: record.author)
      default:
        break
      }

    case .appBskyEmbedRecordWithMediaView(let recordWithMediaView):
      // Prefetch media in record with media embeds
      switch recordWithMediaView.media {
      case .appBskyEmbedImagesView(let imagesView):
        let imageURLs = imagesView.images.compactMap {
          URL(string: $0.thumb.uriString())
        }.filter { url in
          !prefetchedAssets.contains(url.absoluteString)
        }

        if !imageURLs.isEmpty {
          // Mark as prefetched
          for url in imageURLs {
            prefetchedAssets.insert(url.absoluteString)
          }
          
          let manager = ImageLoadingManager.shared
          await manager.startPrefetching(urls: imageURLs)
        }
      default:
        break
      }

    case .appBskyEmbedVideoView:
      // For video embeds, we could potentially prefetch video thumbnails
      // but actual video prefetching would likely use too much data
      break

    case .unexpected:
      break
}
  }
}
