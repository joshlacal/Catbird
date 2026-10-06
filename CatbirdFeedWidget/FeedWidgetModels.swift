//
//  FeedWidgetModels.swift
//  CatbirdFeedWidget
//
//  Created on 6/7/25.
//

#if os(iOS)
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
  /// When Catbird last saved these posts; nil when nothing has been saved.
  let lastUpdated: Date?
  /// False when no account is signed in for this widget.
  let isSignedIn: Bool

  init(
    date: Date,
    posts: [WidgetPost],
    configuration: ConfigurationAppIntent,
    isPlaceholder: Bool = false,
    lastUpdated: Date? = nil,
    isSignedIn: Bool = true
  ) {
    self.date = date
    self.posts = posts
    self.configuration = configuration
    self.isPlaceholder = isPlaceholder
    self.lastUpdated = lastUpdated
    self.isSignedIn = isSignedIn
  }
}

/// Posts saved by the app for one widget configuration, with the time they were saved.
struct WidgetFeedSnapshot {
  let posts: [WidgetPost]
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

/// Account info shared with widget extension via App Group
struct WidgetAccount: Codable {
  let did: String
  let handle: String
  let displayName: String
  let avatarURL: String?
}

// Shared constants
struct FeedWidgetConstants {
  static let sharedSuiteName = "group.blue.catbird.shared"
  static let feedDataKey = "feedWidgetData"
  static let updateInterval: TimeInterval = 15 * 60 // 15 minutes

  /// Storage key for the Following timeline's posts. Must match the app's
  /// FeedWidgetConstants in FeedWidgetDataProvider.swift.
  static let timelineConfigKey = "widgetData_timeline"

  /// Storage key for one feed generator's posts. Must match the app's
  /// FeedWidgetConstants.configKey(forFeedURI:) in FeedWidgetDataProvider.swift.
  static func configKey(forFeedURI uri: String) -> String {
    let sanitized = uri
      .replacingOccurrences(of: "at://", with: "")
      .replacingOccurrences(of: "/", with: "_")
    return "widgetData_feed_\(sanitized)"
  }
}
#endif
