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
}

// Shared constants
struct FeedWidgetConstants {
  static let sharedSuiteName = "group.blue.catbird.shared"
  static let feedDataKey = "feedWidgetData"
  static let updateInterval: TimeInterval = 15 * 60 // 15 minutes
}
