//
//  EnhancedFeedPost.swift
//  Catbird
//
//  Enhanced FeedPost that supports thread consolidation and multiple display modes
//

import Observation
import Petrel
import SwiftUI

/// Enhanced version of FeedPost that supports thread consolidation
struct EnhancedFeedPost: View, Equatable {
  
  static func == (lhs: EnhancedFeedPost, rhs: EnhancedFeedPost) -> Bool {
    lhs.id == rhs.id
  }
  
  // MARK: - Properties
  let cachedPost: CachedFeedViewPost
  @Binding var path: NavigationPath
  @Environment(AppState.self) private var appState
  
  // MARK: - Layout Constants
  private static let baseUnit: CGFloat = 3
  private static let avatarSize: CGFloat = 48
  
  // MARK: - Computed Properties
  private var id: String {
    cachedPost.id
  }
  
  private var feedViewPost: AppBskyFeedDefs.FeedViewPost {
    cachedPost.feedViewPost
  }
  
  // MARK: - Body
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Repost header if needed
      if case .appBskyFeedDefsReasonRepost(let reasonRepost) = feedViewPost.reason {
        RepostHeaderView(reposter: reasonRepost.by, path: $path)
          .frame(height: EnhancedFeedPost.baseUnit * 8)
          .padding(.horizontal, EnhancedFeedPost.baseUnit * 2)
          .padding(.bottom, EnhancedFeedPost.baseUnit * 2)
      }
      
      // Pinned post badge if needed
      let shouldShowBadge: Bool = {
        if case .appBskyFeedDefsReasonPin = feedViewPost.reason {
          return true
        }
        if let pinned = feedViewPost.post.viewer?.pinned, pinned {
          return true
        }
        return false
      }()
      
      if shouldShowBadge {
        pinnedPostBadge
          .frame(height: EnhancedFeedPost.baseUnit * 8)
          .padding(.horizontal, EnhancedFeedPost.baseUnit * 2)
          .padding(.bottom, EnhancedFeedPost.baseUnit * 2)
      }
      
      // Main thread content based on display mode
      threadContent
    }
    .padding(.top, EnhancedFeedPost.baseUnit * 3)
    .padding(.horizontal, EnhancedFeedPost.baseUnit * 1.5)
    .fixedSize(horizontal: false, vertical: true)
    .contentShape(Rectangle())
    .allowsHitTesting(true)
    .frame(maxWidth: 600, alignment: .center)
    .frame(maxWidth: .infinity, alignment: .center)
  }
  
  // MARK: - Thread Content
  
  @ViewBuilder
  private var threadContent: some View {
    let mode = threadDisplayMode
//  logger.debug("🧵 EnhancedFeedPost: \(cachedPost.id) mode=\(mode), sliceItems=\(cachedPost.sliceItems?.count ?? 0)")
    
    switch mode {
    case .standard:
      standardThreadContent
      
    case .expanded(let postCount):
      expandedThreadContent(postCount: postCount)
      
    case .collapsed(let hiddenCount):
      collapsedThreadContent(hiddenCount: hiddenCount)
    }
  }
  
  // MARK: - Thread Display Mode
  
  private enum ThreadMode {
    case standard
    case expanded(postCount: Int)
    case collapsed(hiddenCount: Int)
  }
  
  private var threadDisplayMode: ThreadMode {
    guard let modeString = cachedPost.threadDisplayMode else {
      return .standard
    }
    
    switch modeString {
    case "expanded":
      let count = cachedPost.threadPostCount ?? 2
      return .expanded(postCount: count)
    case "collapsed":
      let hiddenCount = cachedPost.threadHiddenCount ?? 0
      return .collapsed(hiddenCount: hiddenCount)
    default:
      return .standard
    }
  }
  
  // MARK: - Standard Thread Content (Current Behavior)
  
  @ViewBuilder
  private var standardThreadContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Parent post if needed (for replies)
      if let parentPost = feedViewPost.reply?.parent, feedViewPost.reason == nil {
        parentPostContent(parentPost)
          .padding(.bottom, EnhancedFeedPost.baseUnit * 2)
      }
      
      // Main post content
      mainPostContent(feedViewPost)
    }
  }
  
  // MARK: - Expanded Thread Content (2-3 posts)
  
  @ViewBuilder
  private func expandedThreadContent(postCount: Int) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      // Show all posts in the slice for expanded threads
      if let sliceItems = cachedPost.sliceItems, !sliceItems.isEmpty {
        ForEach(Array(sliceItems.enumerated()), id: \.element.id) { index, item in
          let isLast = index == sliceItems.count - 1
          
          PostView(
            post: item.post,
            grandparentAuthor: nil,
            isParentPost: !isLast, // All but last are considered parent posts
            isSelectable: false,
            path: $path,
            appState: appState
          )
          .environment(\.feedPostID, cachedPost.id)
          .id("\(cachedPost.id)-slice-\(index)-\(item.post.uri.uriString())")
          .contentShape(Rectangle())
          .onTapGesture {
            path.append(NavigationDestination.post(item.post.uri))
          }
          
          if !isLast {
            Spacer()
              .frame(height: EnhancedFeedPost.baseUnit * 2)
          }
        }
      } else {
        // Fallback to standard behavior if slice items not available
        standardThreadContent
      }
    }
  }
  
  // MARK: - Collapsed Thread Content (Root + separator + bottom posts)
  
  @ViewBuilder
  private func collapsedThreadContent(hiddenCount: Int) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      // Show: ROOT + "View Full Thread" + LAST 2 POSTS (React Native pattern)
      if let sliceItems = cachedPost.sliceItems, sliceItems.count >= 3 {
        // Root post (first item)
        let rootItem = sliceItems[0]
        PostView(
          post: rootItem.post,
          grandparentAuthor: nil,
          isParentPost: true,
          isSelectable: false,
          path: $path,
          appState: appState
        )
        .environment(\.feedPostID, cachedPost.id)
        .id("\(cachedPost.id)-root-\(rootItem.post.uri.uriString())")
        .contentShape(Rectangle())
        .onTapGesture {
          path.append(NavigationDestination.post(rootItem.post.uri))
        }
        
        // Thread separator
        ThreadSeparatorView(hiddenPostCount: hiddenCount) {
          // Navigate to full thread view
            if case let .appBskyFeedDefsPostView(parentReply) = feedViewPost.reply?.root {
                path.append(NavigationDestination.post(parentReply.uri))
            }
        }
        
        // Last 2 posts
        let lastTwoItems = Array(sliceItems.suffix(2))
        ForEach(Array(lastTwoItems.enumerated()), id: \.element.id) { index, item in
          let isLast = index == lastTwoItems.count - 1
          
          PostView(
            post: item.post,
            grandparentAuthor: isLast ? nil : item.parentAuthor,
            isParentPost: !isLast,
            isSelectable: false,
            path: $path,
            appState: appState
          )
          .environment(\.feedPostID, cachedPost.id)
          .id("\(cachedPost.id)-bottom-\(index)-\(item.post.uri.uriString())")
          .contentShape(Rectangle())
          .onTapGesture {
            path.append(NavigationDestination.post(item.post.uri))
          }
          
          if !isLast {
            Spacer()
              .frame(height: EnhancedFeedPost.baseUnit * 2)
          }
        }
      } else {
        // Fallback to standard behavior if slice items not available
        standardThreadContent
      }
    }
  }
  
  // MARK: - Content Components
  
  @ViewBuilder
  private var pinnedPostBadge: some View {
    HStack(alignment: .center, spacing: 4) {
      Image(systemName: "pin")
        .foregroundColor(.secondary)
        .font(.subheadline)
      
      Text("Pinned")
        .font(.body)
        .textScale(.secondary)
        .foregroundColor(.secondary)
        .lineLimit(1)
        .allowsTightening(true)
        .offset(y: -2)
        .fixedSize(horizontal: true, vertical: false)
    }
    .foregroundColor(.secondary)
    .padding(.vertical, 6)
    .padding(.horizontal, 10)
  }
  
  /// Renders the parent post if this is a reply
  @ViewBuilder
  private func parentPostContent(_ parentPost: AppBskyFeedDefs.ReplyRefParentUnion) -> some View {
    switch parentPost {
    case .appBskyFeedDefsPostView(let postView):
      PostView(
        post: postView,
        grandparentAuthor: feedViewPost.reply?.grandparentAuthor,
        isParentPost: true,
        isSelectable: false,
        path: $path,
        appState: appState
      )
      .environment(\.feedPostID, feedViewPost.id)
      .id("\(feedViewPost.id)-parent-\(postView.uri.uriString())")
      .contentShape(Rectangle())
      .onTapGesture {
        path.append(NavigationDestination.post(postView.uri))
      }
    case .appBskyFeedDefsNotFoundPost:
      Text("Post not found")
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.vertical, EnhancedFeedPost.baseUnit * 2)
    case .appBskyFeedDefsBlockedPost(let blocked):
      BlockedPostView(blockedPost: blocked, path: $path)
    case .unexpected:
      Text("Unexpected post type")
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.vertical, EnhancedFeedPost.baseUnit * 2)
    }
  }
  
  /// Renders the main post content
  @ViewBuilder
  private func mainPostContent(_ post: AppBskyFeedDefs.FeedViewPost) -> some View {
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
      .allowsHitTesting(true)
      .onTapGesture {
        path.append(NavigationDestination.post(post.post.uri))
      }
    }
  }
}
