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

  // MARK: - Computed Properties
  private var id: String {
    guard
      let feedViewPost,
      case .appBskyFeedDefsReasonRepost(let reasonRepost) = feedViewPost.reason
    else {
      return cachedPost.id
    }

    return "\(cachedPost.id)-repost-\(reasonRepost.indexedAt)"
  }

  private var feedViewPost: AppBskyFeedDefs.FeedViewPost? {
    try? cachedPost.feedViewPost
  }

  // MARK: - Body
  var body: some View {
    Group {
      if let feedViewPost {
        content(for: feedViewPost)
              .id(appState.feedFeedbackManager.currentFeedType?.identifier ?? "unknown-feed-\(id)")
      } else {
        EmptyView()
      }
    }
  }

  // MARK: - Content Builders
  @ViewBuilder
  private func content(for feedViewPost: AppBskyFeedDefs.FeedViewPost) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if case .appBskyFeedDefsReasonRepost(let reasonRepost) = feedViewPost.reason {
        RepostHeaderView(reposter: reasonRepost.by, path: $path)
          .frame(height: Self.baseUnit * 8)
          .padding(.horizontal, Self.baseUnit * 2)
          .padding(.bottom, Self.baseUnit * 2)
          .fixedSize(horizontal: false, vertical: true)
      }

      if shouldShowPinnedBadge(feedViewPost) {
        pinnedPostBadge
          .frame(height: Self.baseUnit * 8)
          .padding(.horizontal, Self.baseUnit * 2)
          .padding(.bottom, Self.baseUnit * 2)
      }

      threadContent(for: feedViewPost)
    }
    .padding(.top, Self.baseUnit * 3)
    .padding(.horizontal, Self.baseUnit * 1.5)
    .fixedSize(horizontal: false, vertical: true)
    .contentShape(Rectangle())
    .allowsHitTesting(true)
    .frame(maxWidth: 600, alignment: .center)
    .frame(maxWidth: .infinity, alignment: .center)
  }

  private func shouldShowPinnedBadge(_ feedViewPost: AppBskyFeedDefs.FeedViewPost) -> Bool {
    if case .appBskyFeedDefsReasonPin = feedViewPost.reason {
      return true
    }

    return feedViewPost.post.viewer?.pinned == true
  }

  // MARK: - Thread Content
  @ViewBuilder
  private func threadContent(for feedViewPost: AppBskyFeedDefs.FeedViewPost) -> some View {
    switch threadDisplayMode {
    case .standard:
      standardThreadContent(feedViewPost)

    case .expanded(let postCount):
      expandedThreadContent(feedViewPost, postCount: postCount)

    case .collapsed(let hiddenCount):
      collapsedThreadContent(feedViewPost, hiddenCount: hiddenCount)
    }
  }

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

  // MARK: - Standard Thread Content
  @ViewBuilder
  private func standardThreadContent(_ feedViewPost: AppBskyFeedDefs.FeedViewPost) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if let parentPost = feedViewPost.reply?.parent, feedViewPost.reason == nil {
        parentPostContent(parentPost, feedViewPost: feedViewPost)
          .padding(.bottom, Self.baseUnit * 2)
      }

      mainPostContent(feedViewPost)
    }
  }

  // MARK: - Expanded Thread Content
  @ViewBuilder
  private func expandedThreadContent(
    _ feedViewPost: AppBskyFeedDefs.FeedViewPost,
    postCount: Int
  ) -> some View {

    VStack(alignment: .leading, spacing: 0) {
      if let sliceItems = cachedPost.sliceItems, !sliceItems.isEmpty {
        ForEach(Array(sliceItems.enumerated()), id: \.element.id) { index, item in
          let isLast = index == sliceItems.count - 1

          PostView(
            post: item.post,
            grandparentAuthor: nil,
            isParentPost: !isLast,
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
              .frame(height: Self.baseUnit * 2)
          }
        }
      } else {
        standardThreadContent(feedViewPost)
      }
    }
  }

  // MARK: - Collapsed Thread Content
  @ViewBuilder
  private func collapsedThreadContent(
    _ feedViewPost: AppBskyFeedDefs.FeedViewPost,
    hiddenCount: Int
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if let sliceItems = cachedPost.sliceItems, sliceItems.count >= 3 {
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

        ThreadSeparatorView(hiddenPostCount: hiddenCount) {
          if case let .appBskyFeedDefsPostView(parentReply)? = feedViewPost.reply?.root {
            path.append(NavigationDestination.post(parentReply.uri))
          }
        }

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
              .frame(height: Self.baseUnit * 2)
          }
        }
      } else {
        standardThreadContent(feedViewPost)
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

  @ViewBuilder
  private func parentPostContent(
    _ parentPost: AppBskyFeedDefs.ReplyRefParentUnion,
    feedViewPost: AppBskyFeedDefs.FeedViewPost
  ) -> some View {
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
    case .appBskyFeedDefsNotFoundPost(let notFound):
      HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
        AuthorAvatarColumn(
          author: createPlaceholderAuthor(for: notFound.uri),
          isParentPost: true,
          isAvatarLoaded: .constant(false),
          path: $path
        )

        VStack(alignment: .leading, spacing: 0) {
          PostNotFoundView(uri: notFound.uri, reason: .notFound, path: $path)
            .padding(.top, Self.baseUnit)
        }
      }
      .id("\(feedViewPost.id)-parent-notfound-\(notFound.uri.uriString())")

    case .appBskyFeedDefsBlockedPost(let blocked):
      HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
        AuthorAvatarColumn(
          author: createPlaceholderAuthor(from: blocked.author),
          isParentPost: true,
          isAvatarLoaded: .constant(false),
          path: $path
        )

        VStack(alignment: .leading, spacing: 0) {
          BlockedPostView(blockedPost: blocked, path: $path)
            .padding(.top, Self.baseUnit)
        }
      }
      .id("\(feedViewPost.id)-parent-blocked-\(blocked.uri.uriString())")

    case .unexpected:
      Text("Unexpected post type")
        .appFont(AppTextRole.caption)
        .foregroundColor(.secondary)
        .padding(.vertical, Self.baseUnit * 2)
    }
  }

  @ViewBuilder
  private func mainPostContent(_ feedViewPost: AppBskyFeedDefs.FeedViewPost) -> some View {
    let grandparentAuthor: AppBskyActorDefs.ProfileViewBasic? = {
      // If this is a repost and the reposted post is a reply, get the parent author
      if case .appBskyFeedDefsReasonRepost = feedViewPost.reason,
         case let .appBskyFeedDefsPostView(parentPost) = feedViewPost.reply?.parent {
        return parentPost.author
      }
      return nil
    }()

    PostView(
      post: feedViewPost.post,
      grandparentAuthor: grandparentAuthor,
      isParentPost: false,
      isSelectable: false,
      path: $path,
      appState: appState
    )
    .environment(\.feedPostID, feedViewPost.id)
    .id("\(feedViewPost.id)-main-\(feedViewPost.post.uri.uriString())")
    .contentShape(Rectangle())
    .allowsHitTesting(true)
    .onTapGesture {
      path.append(NavigationDestination.post(feedViewPost.post.uri))
    }
  }

  // MARK: - Placeholder Author Helpers
  private func createPlaceholderAuthor(
    from blockedAuthor: AppBskyFeedDefs.BlockedAuthor
  ) -> AppBskyActorDefs.ProfileViewBasic {
    let placeholderHandle = try! Handle(handleString: "blocked.user")
    return AppBskyActorDefs.ProfileViewBasic(
      did: blockedAuthor.did,
      handle: placeholderHandle,
      displayName: nil,
      pronouns: nil, avatar: nil,
      associated: nil,
      viewer: blockedAuthor.viewer,
      labels: nil,
      createdAt: nil,
      verification: nil,
      status: nil
    )
  }

  private func createPlaceholderAuthor(
    for uri: ATProtocolURI
  ) -> AppBskyActorDefs.ProfileViewBasic {
    let placeholderDID = try! DID(didString: "did:plc:unknown")
    let placeholderHandle = try! Handle(handleString: "deleted.user")
    return AppBskyActorDefs.ProfileViewBasic(
      did: placeholderDID,
      handle: placeholderHandle,
      displayName: nil,
      pronouns: nil, avatar: nil,
      associated: nil,
      viewer: nil,
      labels: nil,
      createdAt: nil,
      verification: nil,
      status: nil
    )
  }
}
