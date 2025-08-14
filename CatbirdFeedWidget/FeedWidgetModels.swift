//
//  FeedWidgetModels.swift
//  CatbirdFeedWidget
//
//  Created on 6/7/25.
//

import Foundation
import SwiftUI
import WidgetKit

// Simplified post model for widget display
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

// Widget feed data structure for sharing between app and widget
struct FeedWidgetData: Codable {
  let posts: [WidgetPost]
  let feedType: String
  let lastUpdated: Date
}

// Widget entry for timeline
struct FeedWidgetEntry: TimelineEntry {
  let date: Date
  let posts: [WidgetPost]
  let configuration: ConfigurationAppIntent
  let isPlaceholder: Bool
  
  init(date: Date, posts: [WidgetPost], configuration: ConfigurationAppIntent, isPlaceholder: Bool = false) {
    self.date = date
    self.posts = posts
    self.configuration = configuration
    self.isPlaceholder = isPlaceholder
  }
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

// Shared constants
struct FeedWidgetConstants {
  static let sharedSuiteName = "group.blue.catbird.shared"
  static let feedDataKey = "feedWidgetData"
  static let updateInterval: TimeInterval = 15 * 60 // 15 minutes
}
