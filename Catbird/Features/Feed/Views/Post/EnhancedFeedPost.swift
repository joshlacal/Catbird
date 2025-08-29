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
          .fixedSize(horizontal: false, vertical: true)
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
    // Debug log to understand what's happening
    
      Group {
          switch mode {
          case .standard:
              standardThreadContent
              
          case .expanded(let postCount):
              expandedThreadContent(postCount: postCount)
              
          case .collapsed(let hiddenCount):
              collapsedThreadContent(hiddenCount: hiddenCount)
          }
      }
          .onAppear {
              // Initialize post appearance
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
      // Parent post if needed (for replies) - always show like FeedPost does
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
        .appFont(AppTextRole.subheadline)
      
      Text("Pinned")
                        .appFont(AppTextRole.body)
        .textScale(.secondary)
        .foregroundColor(.secondary)
        .lineLimit(1)
        .allowsTightening(true)
        .offset(y: -2)
        .fixedSize(horizontal: false, vertical: true)
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
        .appFont(AppTextRole.caption)
        .foregroundColor(.secondary)
        .padding(.vertical, EnhancedFeedPost.baseUnit * 2)
    case .appBskyFeedDefsBlockedPost(let blocked):
      BlockedPostView(blockedPost: blocked, path: $path)
    case .unexpected:
      Text("Unexpected post type")
        .appFont(AppTextRole.caption)
        .foregroundColor(.secondary)
        .padding(.vertical, EnhancedFeedPost.baseUnit * 2)
    }
  }
  
  /// Renders the main post content
  @ViewBuilder
  private func mainPostContent(_ post: AppBskyFeedDefs.FeedViewPost) -> some View {
    // Determine grandparent author for reposts of replies
    let grandparentAuthor: AppBskyActorDefs.ProfileViewBasic? = {
      // Debug: Check if this is a repost
      let isRepost = { () -> Bool in
        if case .appBskyFeedDefsReasonRepost = post.reason { return true }
        return false
      }()
      
      // Debug: Check if there's reply context
      let hasReplyContext = post.reply != nil
      
      // Debug logging
      print("DEBUG EnhancedFeedPost - Post ID: \(post.id)")
      print("DEBUG EnhancedFeedPost - Is repost: \(isRepost)")
      print("DEBUG EnhancedFeedPost - Has reply context: \(hasReplyContext)")
      if let reply = post.reply {
        print("DEBUG EnhancedFeedPost - Reply parent type: \(reply.parent)")
      }
      
      // If this is a repost, check the original post for reply context
      if case .appBskyFeedDefsReasonRepost = post.reason {
        // For reposts, the reply context is on the original post (post.post), not the repost wrapper
        if case .knownType(let originalPostRecord) = post.post.record,
           let originalPost = originalPostRecord as? AppBskyFeedPost,
           let originalReply = originalPost.reply
            {
            let parentRef = originalReply.parent
          // We need to find the parent post to get the author
          // The parentRef only has URI and CID, we need the actual parent post data
          // This should come from the feed data if available
          print("DEBUG EnhancedFeedPost - Found original post reply context, parent URI: \(parentRef.uri)")
          
          // Check if we have parent post data in the feed reply context
          if let replyContext = post.reply,
             case let .appBskyFeedDefsPostView(parentPost) = replyContext.parent {
            print("DEBUG EnhancedFeedPost - Found grandparent author from feed context: \(parentPost.author.handle)")
            return parentPost.author
          }
        }
      }
      print("DEBUG EnhancedFeedPost - No grandparent author found")
      return nil
    }()
    
    PostView(
      post: post.post,
      grandparentAuthor: grandparentAuthor,
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
