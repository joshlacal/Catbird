//
//  FeedPostRow.swift
//  Catbird
//
//  Created by Josh LaCalamito on 1/31/25.
//

import Petrel
import SwiftUI

/// A row in the feed displaying a post with consistent layout
struct FeedPostRow: View, Equatable {
    static func == (lhs: FeedPostRow, rhs: FeedPostRow) -> Bool {
        lhs.post == rhs.post && lhs.index == rhs.index        
    }
    
  // MARK: - Properties
  let post: CachedFeedViewPost
  let index: Int
  @Binding var path: NavigationPath
  @Environment(AppState.self) private var appState
  
  // Base unit for spacing (using multiples of 3pt)
  static let baseUnit: CGFloat = 3

  // MARK: - Body
  var body: some View {
    Group {
      if shouldShowPost() {
        // Temporarily disable recycling due to crash
        createPostView()
      } else {
        // Post is filtered out - show nothing (but maintain list row structure)
        EmptyView()
      }
    }
  }
  
  // MARK: - View Creation
  
  @ViewBuilder
  private func createPostView() -> some View {
    let postView = EnhancedFeedPost(
      cachedPost: post,
      path: $path
    )
    .equatable()
    // This is critical for allowing interactions to reach video controls
    .allowsHitTesting(true)
    // The key to consistent sizing and avoiding layout jumps:
    .fixedSize(horizontal: false, vertical: true)
    // Apply background to the entire row
    .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
    // Apply modifiers for list appearance
    .applyListRowModifiers(id: post.feedViewPost.id)
    // Prefetch data for better performance
    .task {
      let postToProcess = post.feedViewPost
      if let client = appState.atProtoClient {
          Task.detached(priority: .medium) {
          await FeedPrefetchingManager.shared.prefetchPostData(
            post: postToProcess, client: client)
        }
      }
    }
    // Removed onDisappear recycling to prevent memory corruption
    
    postView
  }
  
  // MARK: - Content Filtering
  
  /// Check if this post should be displayed based on user settings
  private func shouldShowPost() -> Bool {
    // Extract content labels from the post
    let labels = post.feedViewPost.post.labels
    
    // If there are no labels, show the post
    guard let labels = labels, !labels.isEmpty else {
      return true
    }
    
    // Check content preferences for each label
    for label in labels {
      let labelValue = label.val.lowercased()
      
      // Check if adult content is disabled and this is NSFW content
      if !appState.isAdultContentEnabled && 
         ["nsfw", "porn", "sexual", "nudity"].contains(labelValue) {
        return false
      }
      
      // Check user's specific content label preferences
      // For now, apply basic filtering - this will be enhanced with server preferences
      let sensitiveLabels = ["nsfw", "porn", "sexual", "gore", "violence", "graphic"]
      if sensitiveLabels.contains(labelValue) {
        // If adult content is disabled, hide NSFW content completely
        if !appState.isAdultContentEnabled && ["nsfw", "porn", "sexual"].contains(labelValue) {
          return false
        }
        // Otherwise, show but blur (handled by ContentLabelManager in the post view)
      }
    }
    
    return true
  }
}

// MARK: - View Modifiers

// Helper extension to apply consistent list row modifiers
extension View {
  /// Apply consistent list row modifiers for feed posts
  func applyListRowModifiers(id: String) -> some View {
//      Section {
          self
//      }
      .id(id) // Stable ID for consistent rendering
//      .listRowSeparator(.hidden) // Hide default separators
      // Use modest insets to allow better interaction with video controls
      .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
      .listRowBackground(Color.clear)
      .listRowSeparator(.visible)
      .alignmentGuide(.listRowSeparatorLeading) { _ in
          0
      }
      // Add subtle divider at the bottom of each post
//      .overlay(alignment: .bottom) {
//          Divider()
//              .foregroundStyle(.primary)
////              .opacity(0.7)
//      }
  }
}
