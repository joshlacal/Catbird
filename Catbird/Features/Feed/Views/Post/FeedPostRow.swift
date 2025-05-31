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
        EnhancedFeedPost(
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
      } else {
        // Post is filtered out - show nothing (but maintain list row structure)
        EmptyView()
      }
    }
  }
  
  // MARK: - Content Filtering
  
  /// Check if this post should be displayed based on user settings
  private func shouldShowPost() -> Bool {
    // For now, show all posts - content filtering will be implemented in a future update
    // This ensures the feed continues to work while we build out the filtering system
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
