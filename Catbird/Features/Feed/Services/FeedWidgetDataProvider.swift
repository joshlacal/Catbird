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

/// Manages feed data sharing with the widget extension
@MainActor
final class FeedWidgetDataProvider {
  private let logger = Logger(subsystem: "blue.catbird", category: "FeedWidgetDataProvider")
  private let sharedDefaults = UserDefaults(suiteName: "group.blue.catbird.shared")
  
  static let shared = FeedWidgetDataProvider()
  
  private init() {}
  
  /// Updates widget data from a feed's posts
  func updateWidgetData(from posts: [CachedFeedViewPost], feedType: FetchType) {
    guard let sharedDefaults = sharedDefaults else {
      logger.error("Failed to access shared defaults")
      return
    }
    
    // Convert posts to widget format
    let widgetPosts = posts.prefix(10).compactMap { cachedPost -> WidgetPost? in
      let post = cachedPost.feedViewPost
      
      guard case .knownType(let record) = post.post.record,
            let feedPost = record as? AppBskyFeedPost else {
        return nil
      }
      
      // Extract text content
      let text = feedPost.text
      
      // Extract image URLs from embed
      var imageURLs: [String] = []
      if let embed = post.post.embed {
        switch embed {
        case .appBskyEmbedImagesView(let imagesView):
          imageURLs = imagesView.images.map { $0.thumb.uriString() }
        case .appBskyEmbedExternalView:
          // External embeds might have images too
          break
        case .appBskyEmbedRecordView:
          // Quote posts
          break
        case .appBskyEmbedRecordWithMediaView(let recordWithMediaView):
          // Combined embeds - check for images in media
          if case .appBskyEmbedImagesView(let imagesView) = recordWithMediaView.media {
            imageURLs = imagesView.images.map { $0.thumb.uriString() }
          }
        case .appBskyEmbedVideoView:
          // Video embeds
          break
        case .unexpected:
          break
        }
      }
      
      // Check if it's a repost
      let isRepost = post.reason != nil
      var repostAuthorName: String?
      if case .appBskyFeedDefsReasonRepost(let repostReason) = post.reason {
          repostAuthorName = repostReason.by.displayName ?? repostReason.by.handle.description
      }
      
      return WidgetPost(
        id: post.post.cid.string,
        authorName: post.post.author.displayName ?? post.post.author.handle.description,
        authorHandle: "@\(post.post.author.handle)",
        authorAvatarURL: post.post.author.avatar?.uriString(),
        text: text,
        timestamp: post.post.indexedAt.date,
        likeCount: post.post.likeCount ?? 0,
        repostCount: post.post.repostCount ?? 0,
        replyCount: post.post.replyCount ?? 0,
        imageURLs: imageURLs,
        isRepost: isRepost,
        repostAuthorName: repostAuthorName
      )
    }
    
    // Create feed widget data
    let feedWidgetData = FeedWidgetData(
      posts: widgetPosts,
      feedType: mapFeedType(feedType),
      lastUpdated: Date()
    )
    
    // Save to shared defaults
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(feedWidgetData)
      sharedDefaults.set(data, forKey: FeedWidgetConstants.feedDataKey)
      
      logger.info("Updated widget data with \(widgetPosts.count) posts for feed type: \(feedType.displayName)")
      
      // Reload widget timelines
      WidgetCenter.shared.reloadTimelines(ofKind: "CatbirdFeedWidget")
    } catch {
      logger.error("Failed to encode widget data: \(error.localizedDescription)")
    }
  }
  
  /// Maps internal FetchType to widget's FeedTypeOption
  private func mapFeedType(_ fetchType: FetchType) -> String {
    switch fetchType {
    case .timeline:
      return "timeline"
    case .feed(let uri):
      // Check for known feed types
      let uriString = uri.uriString()
      if uriString.contains("discover") {
        return "discover"
      } else if uriString.contains("popular") || uriString.contains("hot") {
        return "popular"
      } else {
        return "custom"
      }
    default:
      return "timeline"
    }
  }
  
  /// Clears widget data
  func clearWidgetData() {
    guard let sharedDefaults = sharedDefaults else {
      logger.error("Failed to access shared defaults")
      return
    }
    
    sharedDefaults.removeObject(forKey: FeedWidgetConstants.feedDataKey)
    WidgetCenter.shared.reloadTimelines(ofKind: "CatbirdFeedWidget")
    
    logger.info("Cleared widget data")
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

struct FeedWidgetConstants {
  static let sharedSuiteName = "group.blue.catbird.shared"
  static let feedDataKey = "feedWidgetData"
  static let updateInterval: TimeInterval = 15 * 60 // 15 minutes
}
