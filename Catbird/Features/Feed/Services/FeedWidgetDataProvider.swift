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
  
  private init() {}
  
  /// Updates widget data from a feed's posts
  func updateWidgetData(from posts: [CachedFeedViewPost], feedType: FetchType) {
    // Use the enhanced version by default for better functionality
    updateWidgetDataEnhanced(from: posts, feedType: feedType)
  }
  
  /// Helper method to convert a cached post to widget format
  private func convertToWidgetPost(_ cachedPost: CachedFeedViewPost) -> WidgetPost? {
    let post = cachedPost.feedViewPost
    
    guard case .knownType(let record) = post.post.record,
          let feedPost = record as? AppBskyFeedPost else {
      return nil
    }
    
    // Extract text content
    let text = feedPost.text
    
    // Extract image URLs from embed
    let imageURLs = extractImageURLs(from: post.post.embed)
    
    // Check if it's a repost
    let isRepost = post.reason != nil
    let repostAuthorName = extractRepostAuthorName(from: post.reason)
    
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
  
  /// Helper method to extract image URLs from embed
  private func extractImageURLs(from embed: AppBskyFeedDefs.PostViewEmbedUnion?) -> [String] {
    guard let embed = embed else { return [] }
    
    switch embed {
    case .appBskyEmbedImagesView(let imagesView):
      return imagesView.images.map { $0.thumb.uriString() }
    case .appBskyEmbedRecordWithMediaView(let recordWithMediaView):
      if case .appBskyEmbedImagesView(let imagesView) = recordWithMediaView.media {
        return imagesView.images.map { $0.thumb.uriString() }
      }
      return []
    default:
      return []
    }
  }
  
  /// Helper method to extract repost author name
  private func extractRepostAuthorName(from reason: AppBskyFeedDefs.FeedViewPostReasonUnion?) -> String? {
    guard let reason = reason,
          case .appBskyFeedDefsReasonRepost(let repostReason) = reason else {
      return nil
    }
    return repostReason.by.displayName ?? repostReason.by.handle.description
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
  
  /// Updates widget data for a specific profile
  func updateWidgetDataForProfile(handle: String, posts: [CachedFeedViewPost]) {
    // Use the enhanced version with profile handle
    updateWidgetDataEnhanced(from: posts, feedType: .timeline, profileHandle: handle)
  }
  
  /// Updates shared preferences for widget theme and font settings
  private func updateSharedPreferences() {
    guard let sharedDefaults = sharedDefaults else { return }
    
    // Theme settings (these should be read from actual app state)
    sharedDefaults.set("system", forKey: "selectedTheme")
    sharedDefaults.set("dim", forKey: "darkThemeMode")
    
    // Font settings (these should be read from actual app state)
    sharedDefaults.set(1.0, forKey: "fontSizeScale")
    sharedDefaults.set("system", forKey: "fontFamily")
    sharedDefaults.set("normal", forKey: "lineSpacing")
    
    logger.debug("Updated shared preferences for widget access")
  }
  
  /// Updates user's pinned and saved feeds for widget access
  func updateSharedFeedPreferences(pinnedFeeds: [String], savedFeeds: [String], feedGenerators: [String: String] = [:]) {
    guard let sharedDefaults = sharedDefaults else {
      logger.error("Failed to access shared defaults for feed preferences")
      return
    }
    
    do {
      let encoder = JSONEncoder()
      
      // Store pinned feeds
      let pinnedData = try encoder.encode(pinnedFeeds)
      sharedDefaults.set(pinnedData, forKey: "pinnedFeeds")
      
      // Store saved feeds
      let savedData = try encoder.encode(savedFeeds)
      sharedDefaults.set(savedData, forKey: "savedFeeds")
      
      // Store feed generator info (URI -> display name mapping)
      let generatorData = try encoder.encode(feedGenerators)
      sharedDefaults.set(generatorData, forKey: "feedGenerators")
      
      logger.info("Updated shared feed preferences: \(pinnedFeeds.count) pinned, \(savedFeeds.count) saved")
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
    
    // Load pinned feeds
    let pinnedFeeds: [String] = {
      guard let data = sharedDefaults.data(forKey: "pinnedFeeds") else { return [] }
      return (try? decoder.decode([String].self, from: data)) ?? []
    }()
    
    // Load saved feeds
    let savedFeeds: [String] = {
      guard let data = sharedDefaults.data(forKey: "savedFeeds") else { return [] }
      return (try? decoder.decode([String].self, from: data)) ?? []
    }()
    
    // Load feed generators
    let feedGenerators: [String: String] = {
      guard let data = sharedDefaults.data(forKey: "feedGenerators") else { return [:] }
      return (try? decoder.decode([String: String].self, from: data)) ?? [:]
    }()
    
    return (pinnedFeeds, savedFeeds, feedGenerators)
  }
  

  /// Updates widget data with enhanced metadata and configuration support
  func updateWidgetDataEnhanced(from posts: [CachedFeedViewPost], feedType: FetchType, profileHandle: String? = nil) {
    guard let sharedDefaults = sharedDefaults else {
      logger.error("Failed to access shared defaults")
      return
    }
    
    // Convert posts to widget format with enhanced data
    let limitedPosts = Array(posts.prefix(15)) // Increase limit for better variety
    let widgetPosts = limitedPosts.compactMap { cachedPost in
      convertToWidgetPostEnhanced(cachedPost)
    }
    
    // Create enhanced feed widget data
    let feedWidgetData = FeedWidgetDataEnhanced(
      posts: widgetPosts,
      feedType: mapFeedType(feedType),
      lastUpdated: Date(),
      profileHandle: profileHandle,
      totalPostCount: posts.count
    )
    
    // Save to shared defaults with both general and configuration-specific keys
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(feedWidgetData)
      
      // Save to general key for fallback
      sharedDefaults.set(data, forKey: FeedWidgetConstants.feedDataKey)
      
      // Save to configuration-specific key for targeted widgets
      let configKey = createConfigurationKey(feedType: feedType, profileHandle: profileHandle)
      sharedDefaults.set(data, forKey: configKey)
      
      logger.info("Updated enhanced widget data with \(widgetPosts.count) posts for feed type: \(feedType.displayName) (keys: general + \(configKey))")
      
      // Update shared preferences
      updateSharedPreferences()
      
      // Reload widget timelines
      WidgetCenter.shared.reloadTimelines(ofKind: "CatbirdFeedWidget")
    } catch {
      logger.error("Failed to encode enhanced widget data: \(error.localizedDescription)")
    }
  }
  
  /// Enhanced post conversion with better metadata
  private func convertToWidgetPostEnhanced(_ cachedPost: CachedFeedViewPost) -> WidgetPost? {
    let post = cachedPost.feedViewPost
    
    guard case .knownType(let record) = post.post.record,
          let feedPost = record as? AppBskyFeedPost else {
      return nil
    }
    
    // Extract text content with better handling
    let text = feedPost.text.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Extract image URLs from embed with better handling
    let imageURLs = extractImageURLsEnhanced(from: post.post.embed)
    
    // Check if it's a repost with better detection
    let isRepost = post.reason != nil
    let repostAuthorName = extractRepostAuthorName(from: post.reason)
    
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
  
  /// Enhanced image URL extraction
  private func extractImageURLsEnhanced(from embed: AppBskyFeedDefs.PostViewEmbedUnion?) -> [String] {
    guard let embed = embed else { return [] }
    
    switch embed {
    case .appBskyEmbedImagesView(let imagesView):
      // Prefer full size for better quality in widgets
      return imagesView.images.compactMap { image in
        // Use fullsize if available, fallback to thumb
          return image.fullsize.uriString()
      }
    case .appBskyEmbedRecordWithMediaView(let recordWithMediaView):
      if case .appBskyEmbedImagesView(let imagesView) = recordWithMediaView.media {
        return imagesView.images.compactMap { image in
            return image.fullsize.uriString()
        }
      }
      return []
    case .appBskyEmbedVideoView(let videoView):
      // Handle video thumbnails
      return [videoView.thumbnail?.uriString()].compactMap { $0 }
    default:
      return []
    }
  }
  
  /// Creates a configuration key that matches the widget's key generation logic
  private func createConfigurationKey(feedType: FetchType, profileHandle: String? = nil) -> String {
    var keyComponents = ["widgetData"]
    
    switch feedType {
    case .timeline:
      keyComponents.append("timeline")
    case .feed(let uri):
      let uriString = uri.uriString()
      if uriString.contains("discover") {
        keyComponents.append("discover")
      } else if uriString.contains("popular") || uriString.contains("hot") {
        keyComponents.append("popular")
      } else {
        keyComponents.append("custom")
        keyComponents.append(uriString.replacingOccurrences(of: "at://", with: "").replacingOccurrences(of: "/", with: "_"))
      }
    default:
      keyComponents.append("timeline")
    }
    
    if let handle = profileHandle {
      keyComponents.append(handle.replacingOccurrences(of: "@", with: ""))
    }
    
    return keyComponents.joined(separator: "_")
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

/// Enhanced widget data with additional metadata
struct FeedWidgetDataEnhanced: Codable {
  let posts: [WidgetPost]
  let feedType: String
  let lastUpdated: Date
  let profileHandle: String?
  let totalPostCount: Int
  
  init(posts: [WidgetPost], feedType: String, lastUpdated: Date, profileHandle: String? = nil, totalPostCount: Int = 0) {
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
  static let updateInterval: TimeInterval = 15 * 60 // 15 minutes
}
