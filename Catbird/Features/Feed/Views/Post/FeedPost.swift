//
//  FeedPost.swift
//  Catbird
//
//  Created by Josh LaCalamito on 6/29/24.
//

import Observation
import Petrel
import SwiftUI

/// A SwiftUI view that displays a post in the feed.
struct FeedPost: View {
  // MARK: - Properties
  let post: AppBskyFeedDefs.FeedViewPost
  @Binding var path: NavigationPath
  @Environment(AppState.self) private var appState

  // MARK: - Layout Constants
  private static let baseUnit: CGFloat = 3
  private static let avatarSize: CGFloat = 48

  // MARK: - Computed Properties
  private var uniqueID: String {
    "\(post.id)-\(post.post.uri.uriString())"
  }

  // MARK: - Body
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Repost header if needed
      if case .appBskyFeedDefsReasonRepost(let reasonRepost) = post.reason {
        RepostHeaderView(reposter: reasonRepost.by, path: $path)
          .frame(height: FeedPost.baseUnit * 8)
          .padding(.horizontal, FeedPost.baseUnit * 2)
          .padding(.bottom, FeedPost.baseUnit * 2)
      }

      // Main content area (parent post + main post)
      VStack(alignment: .leading, spacing: 0) {
        // Parent post if needed (for replies)
        if let parentPost = post.reply?.parent, post.reason == nil {
          parentPostContent(parentPost)
            .padding(.bottom, FeedPost.baseUnit * 2)
        }

        // Main post content
        mainPostContent
      }
    }
      // Add minimal vertical padding only
      .padding(.top, FeedPost.baseUnit * 3)
    .padding(.horizontal, FeedPost.baseUnit * 1.5)
    .fixedSize(horizontal: false, vertical: true)
    // Make sure interactions pass through correctly
    .contentShape(Rectangle())
    // Ensure this container doesn't block hit testing to child views
    .allowsHitTesting(true)
  }

  // MARK: - Content Views

  /// Renders the parent post if this is a reply
  @ViewBuilder
  private func parentPostContent(_ parentPost: AppBskyFeedDefs.ReplyRefParentUnion) -> some View {
    switch parentPost {
    case .appBskyFeedDefsPostView(let postView):
      PostView(
        post: postView,
        grandparentAuthor: post.reply?.grandparentAuthor,
        isParentPost: true,
        isSelectable: false,
        path: $path,
        appState: appState
      )
      .environment(\.feedPostID, post.id)
      .id("\(post.id)-parent-\(postView.uri.uriString())")
      .contentShape(Rectangle())
      .onTapGesture {
        path.append(NavigationDestination.post(postView.uri))
      }
    case .appBskyFeedDefsNotFoundPost:
      Text("Post not found")
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.vertical, FeedPost.baseUnit * 2)
    case .appBskyFeedDefsBlockedPost(let blocked):
      BlockedPostView(blockedPost: blocked, path: $path)
    case .unexpected:
      Text("Unexpected post type")
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.vertical, FeedPost.baseUnit * 2)
    }
  }

  /// Renders the main post content
  @ViewBuilder
  private var mainPostContent: some View {
    if case .appBskyFeedDefsReasonRepost(_) = post.reason,
      case let .appBskyFeedDefsPostView(parentReply) = post.reply?.parent
    {
      // This is a repost with a parent reply
      PostView(
        post: post.post,
        grandparentAuthor: parentReply.author,
        isParentPost: false,
        isSelectable: false,
        path: $path,
        appState: appState
      )
      .environment(\.feedPostID, post.id)
      .id("\(post.id)-main-\(post.post.uri.uriString())")
      .contentShape(Rectangle())
      // Make sure all interactions pass through properly
      .allowsHitTesting(true)
      .onTapGesture {
        path.append(NavigationDestination.post(post.post.uri))
      }
    } else {
      // Regular post or reply
      PostView(
        post: post.post,
        grandparentAuthor: nil,
        isParentPost: false,
        isSelectable: false,
        path: $path,
        appState: appState
      )
      .environment(\.feedPostID, post.id)
      .id("\(post.id)-main-\(post.post.uri.uriString())")
      .contentShape(Rectangle())
      // Make sure all interactions pass through properly
      .allowsHitTesting(true)
      .onTapGesture {
        path.append(NavigationDestination.post(post.post.uri))
      }
    }
  }
}

// MARK: - FeedPost Environment Value
struct FeedPostIDKey: EnvironmentKey {
  static let defaultValue: String? = nil
}

extension EnvironmentValues {
  var feedPostID: String? {
    get { self[FeedPostIDKey.self] }
    set { self[FeedPostIDKey.self] = newValue }
  }
}
