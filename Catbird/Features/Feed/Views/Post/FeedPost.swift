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
struct FeedPost: View, Equatable {

    static func == (lhs: FeedPost, rhs: FeedPost) -> Bool {
        lhs.id == rhs.id
    }
    
  // MARK: - Properties
  let post: AppBskyFeedDefs.FeedViewPost
  @Binding var path: NavigationPath
  @Environment(AppState.self) private var appState

  // MARK: - Layout Constants
  private static let baseUnit: CGFloat = 3
  private static let avatarSize: CGFloat = 48

  // MARK: - Computed Properties
  private var id: String {
    "\(post.id)-\(post.post.uri.uriString())"
  }

  // MARK: - Body
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Repost header if needed (above glass card)
      if case .appBskyFeedDefsReasonRepost(let reasonRepost) = post.reason {
        RepostHeaderView(reposter: reasonRepost.by, path: $path)
          .frame(height: FeedPost.baseUnit * 8)
          .padding(.horizontal, FeedPost.baseUnit * 4)
          .padding(.bottom, FeedPost.baseUnit * 1)
      }
      
      // Pinned badge if needed (above glass card)
      let shouldShowBadge: Bool = {
          if case .appBskyFeedDefsReasonPin = post.reason {
              return true
          }
          if let pinned = post.post.viewer?.pinned, pinned {
              return true
          }
          return false
      }()

      if shouldShowBadge {
          pinnedPostBadge
              .padding(.horizontal, FeedPost.baseUnit * 4)
              .padding(.bottom, FeedPost.baseUnit * 1)
      }

      // Main glass card container
      VStack(alignment: .leading, spacing: 0) {
        // Parent post if needed (for replies)
        if let parentPost = post.reply?.parent, post.reason == nil {
          parentPostContent(parentPost)
            .padding(.bottom, FeedPost.baseUnit * 2)
        }

        // Main post content
        mainPostContent
      }
      .padding(.vertical, FeedPost.baseUnit * 4)
      .padding(.horizontal, FeedPost.baseUnit * 4)
      .contentShape(Rectangle())
      .allowsHitTesting(true)
    }
    .padding(.horizontal, FeedPost.baseUnit * 2)
    .padding(.vertical, FeedPost.baseUnit * 1)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: 600, alignment: .center)
    .frame(maxWidth: .infinity, alignment: .center)
  }

  // MARK: - Content Views

    @ViewBuilder
    private var pinnedPostBadge: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "pin")
                .foregroundColor(.secondary)
                .appFont(AppTextRole.subheadline)

            Text("Pinned")
                                .appFont(AppTextRole.body)
                .textScale(.secondary)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .allowsTightening(true)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }
    
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
        .appFont(AppTextRole.caption)
        .foregroundColor(.secondary)
        .padding(.vertical, FeedPost.baseUnit * 2)
    case .appBskyFeedDefsBlockedPost(let blocked):
      BlockedPostView(blockedPost: blocked, path: $path)
    case .unexpected:
      Text("Unexpected post type")
        .appFont(AppTextRole.caption)
        .foregroundColor(.secondary)
        .padding(.vertical, FeedPost.baseUnit * 2)
    }
  }

  /// Renders the main post content
  @ViewBuilder
  private var mainPostContent: some View {
    if case .appBskyFeedDefsReasonRepost = post.reason,
      case let .appBskyFeedDefsPostView(parentReply) = post.reply?.parent {
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
