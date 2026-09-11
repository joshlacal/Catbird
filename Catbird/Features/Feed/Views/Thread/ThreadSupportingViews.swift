#if os(iOS)
import Petrel
import SwiftUI

// MARK: - Supporting SwiftUI Views
/// Centers its content and constrains it to a maximum width while allowing the
/// surrounding container (e.g., collection view cell) to be full-width.
struct WidthLimitedContainer<Content: View>: View {
  @Environment(\.horizontalSizeClass) private var hSizeClass
  let maxWidth: CGFloat
  @ViewBuilder var content: Content

  private var effectiveMaxWidth: CGFloat {
    hSizeClass == .compact ? .infinity : maxWidth
  }

  init(maxWidth: CGFloat = 600, @ViewBuilder content: () -> Content) {
    self.maxWidth = maxWidth
    self.content = content()
  }

  var body: some View {
    HStack(spacing: 0) {
      Spacer(minLength: 0)
      content
        .frame(maxWidth: effectiveMaxWidth, alignment: .center)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity)
  }
}

/// Root post URI for a thread item: the record's reply root, falling back to the post itself.
private func threadRootURI(for post: AppBskyFeedDefs.PostView) -> ATProtocolURI? {
  if case let .knownType(record) = post.record,
     let feedPost = record as? AppBskyFeedPost,
     let root = feedPost.reply?.root.uri {
    return root
  }
  return post.uri
}

struct ParentPostView: View {
  let parentPost: ParentPost
  @Binding var path: NavigationPath
  var appState: AppState
  var visibilityContext: PostVisibilityContext = .public
  /// The ancestor above this one is visible, so the connector continues upward.
  var showsConnectorAbove = false
  var body: some View {
    switch parentPost.threadItem.value {
    case .appBskyUnspeccedDefsThreadItemPost(let threadItemPost):
      let parentRootURI = threadRootURI(for: threadItemPost.post)

      PostView(
        post: threadItemPost.post,
        grandparentAuthor: nil,
        isParentPost: true,
        isSelectable: false,
        path: $path,
        appState: appState,
        hasVisibleThreadContext: true,
        visibilityContext: visibilityContext,
        rootPostURI: parentRootURI,
        rootAuthorDID: parentRootURI?.authority,
        isReplyHiddenByThreadgate: threadItemPost.hiddenByThreadgate,
        opThreadPostIndex: threadItemPost.opThreadPostIndex,
        opThreadPostCount: threadItemPost.opThreadPostCount,
        hasThreadLineAbove: showsConnectorAbove
      )
      .onTapGesture {
        path.append(NavigationDestination.post(threadItemPost.post.uri))
      }
    case .appBskyUnspeccedDefsThreadItemNotFound:
      PostNotFoundView(
        uri: parentPost.threadItem.uri,
        reason: .notFound,
        path: $path
      )
      .applyAppStateEnvironment(appState)

    case .appBskyUnspeccedDefsThreadItemBlocked(let blocked):
      BlockedContentCard(
        relationship: BlockRelationship(threadItemBlocked: blocked),
        authorDid: blocked.author.did.didString(),
        postUri: parentPost.threadItem.uri,
        variant: .thread,
        path: $path
      )
      .applyAppStateEnvironment(appState)

    case .appBskyUnspeccedDefsThreadItemNoUnauthenticated:
      Text("Post not available (authentication required)")
        .appFont(AppTextRole.subheadline)
        .foregroundColor(.gray)

    case .unexpected(let unexpected):
      Text("Unexpected parent post type: \(unexpected.textRepresentation)")
        .appFont(AppTextRole.subheadline)
        .foregroundColor(.orange)
    }
  }
}

struct ReplyView: View {
  let replyWrapper: ReplyWrapper
  let opAuthorID: String
  let nestedReplies: [ReplyWrapper]  // Nested replies for this post
  @Binding var path: NavigationPath
  var appState: AppState
  var visibilityContext: PostVisibilityContext = .public
  private var isThreadedRepliesMode: Bool {
    appState.appSettings.threadedReplies
  }
  private var maxDepth: Int {
    ThreadReplyPresentationMetrics.maximumDepth(isEnabled: isThreadedRepliesMode)
  }

  /// Flat mode follows one continuation chain; nested mode shows the tree.
  private var nestedLayout: ThreadReplyLayout {
    ThreadReplyLayoutBuilder.build(
      rootID: replyWrapper.id,
      nestedItems: nestedReplies.map {
        ThreadReplyLayoutInput(
          id: $0.id,
          parentID: $0.parentURI,
          hasUnloadedReplies: $0.hasReplies,
          unloadedReplyCount: $0.moreReplies,
          depth: $0.depth
        )
      },
      maximumDepth: maxDepth,
      rootHasUnloadedReplies: replyWrapper.hasReplies,
      rootUnloadedReplyCount: replyWrapper.moreReplies,
      selection: isThreadedRepliesMode ? .tree : .chain
    )
  }

  private func parentAuthor(
    for reply: ReplyWrapper
  ) -> AppBskyActorDefs.ProfileViewBasic? {
    guard let parentURI = reply.parentURI else { return nil }

    if parentURI == replyWrapper.id {
      return replyWrapper.post?.author
    }

    return nestedReplies.first(where: { $0.id == parentURI })?.post?.author
  }

  var body: some View {
    let layout = nestedLayout
    // Every root arm — post or tombstone — renders the nested rows so the
    // subtree stays visible even when the chain root is blocked / not-found /
    // no-auth. Dropping the subtree with the root would defeat the whole
    // "keep replies under a blocked post reachable" goal.
    VStack(alignment: .leading, spacing: 0) {
      switch replyWrapper.threadItem.value {
      case .appBskyUnspeccedDefsThreadItemPost(let threadItemPost):
        let replyRootURI = threadRootURI(for: threadItemPost.post)

        PostView(
          post: threadItemPost.post,
          grandparentAuthor: nil,
          isParentPost: false,
          isSelectable: false,
          path: $path,
          appState: appState,
          hasVisibleThreadContext: true,
          avatarScale: .regular,
          visibilityContext: visibilityContext,
          rootPostURI: replyRootURI,
          rootAuthorDID: replyRootURI?.authority,
          isReplyHiddenByThreadgate: threadItemPost.hiddenByThreadgate,
          opThreadPostIndex: threadItemPost.opThreadPostIndex,
          opThreadPostCount: threadItemPost.opThreadPostCount
        )
        .environment(\.threadAvatarID, replyWrapper.id)
        .onTapGesture {
          path.append(NavigationDestination.post(threadItemPost.post.uri))
        }
        .padding(.vertical, ThreadReplyGeometry.connectorGap)
        .frame(maxWidth: 550, alignment: .leading)
      case .appBskyUnspeccedDefsThreadItemNotFound:
        PostNotFoundView(
          uri: replyWrapper.threadItem.uri,
          reason: .notFound,
          path: $path
        )
        .applyAppStateEnvironment(appState)

      case .appBskyUnspeccedDefsThreadItemBlocked(let blocked):
        BlockedContentCard(
          relationship: BlockRelationship(threadItemBlocked: blocked),
          authorDid: blocked.author.did.didString(),
          postUri: replyWrapper.threadItem.uri,
          variant: .thread,
          path: $path
        )
        .applyAppStateEnvironment(appState)

      case .appBskyUnspeccedDefsThreadItemNoUnauthenticated:
        Text("Reply not available (authentication required)")
          .appFont(AppTextRole.subheadline)
          .foregroundColor(.gray)

      case .unexpected(let unexpected):
        Text("Unexpected reply type: \(unexpected.textRepresentation)")
          .foregroundColor(.orange)
      }

      ForEach(layout.items) { item in
        if let nestedWrapper = nestedReplies.first(where: { $0.id == item.id }) {
          nestedReplyRow(item: item, nestedWrapper: nestedWrapper)
        }
      }

      // Branches the block does not show collapse into one row at its end.
      if layout.rootHasAdditionalReplies {
        continuationButton(
          for: replyWrapper.uri,
          count: layout.rootAdditionalReplyCount,
          depth: 1
        )
      }
    }
    // Connectors are drawn from the avatars' measured bounds so they start at
    // one avatar's bottom and end at the next avatar in the same chain.
    .overlayPreferenceValue(ThreadAvatarAnchorKey.self) { anchors in
      GeometryReader { geometry in
        Path { path in
          let ids = [replyWrapper.id] + layout.items.map(\.id)
          let connections = [layout.connectsRootToFirst] + layout.items.map(\.connectsToNext)
          for index in 0..<max(0, ids.count - 1) where connections[index] {
            guard let source = anchors[ids[index]], let destination = anchors[ids[index + 1]] else {
              continue
            }
            ThreadReplyGeometry.appendConnector(
              to: &path,
              parentAvatar: geometry[source],
              childAvatar: geometry[destination]
            )
          }
        }
        .stroke(
          ThreadReplyGeometry.connectorColor,
          style: StrokeStyle(lineWidth: ThreadReplyGeometry.lineWidth, lineCap: .round)
        )
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private func nestedReplyRow(item: ThreadReplyLayoutItem, nestedWrapper: ReplyWrapper) -> some View {
    let indent = ThreadReplyPresentationMetrics.leadingIndent(
      forDepth: item.depth,
      isEnabled: isThreadedRepliesMode
    )
    switch nestedWrapper.threadItem.value {
    case .appBskyUnspeccedDefsThreadItemPost(let nestedPost):
      let nestedRootURI = threadRootURI(for: nestedPost.post)

      PostView(
        post: nestedPost.post,
        grandparentAuthor: parentAuthor(for: nestedWrapper),
        isParentPost: false,
        isSelectable: false,
        path: $path,
        appState: appState,
        hasVisibleThreadContext: true,
        avatarScale: ThreadReplyPresentationMetrics.avatarScale(
          forDepth: item.depth,
          isEnabled: isThreadedRepliesMode
        ),
        visibilityContext: visibilityContext,
        rootPostURI: nestedRootURI,
        rootAuthorDID: nestedRootURI?.authority,
        isReplyHiddenByThreadgate: nestedPost.hiddenByThreadgate,
        opThreadPostIndex: nestedPost.opThreadPostIndex,
        opThreadPostCount: nestedPost.opThreadPostCount
      )
      .environment(\.threadAvatarID, nestedWrapper.id)
      .contentShape(Rectangle())
      .onTapGesture { path.append(NavigationDestination.post(nestedPost.post.uri)) }
      .padding(.vertical, ThreadReplyGeometry.connectorGap)
      .padding(.leading, indent)
      .frame(maxWidth: 550, alignment: .leading)

    case .appBskyUnspeccedDefsThreadItemNotFound:
      PostNotFoundView(
        uri: nestedWrapper.threadItem.uri,
        reason: .notFound,
        path: $path
      )
      .applyAppStateEnvironment(appState)
      .padding(.leading, indent)

    case .appBskyUnspeccedDefsThreadItemBlocked(let blocked):
      BlockedContentCard(
        relationship: BlockRelationship(threadItemBlocked: blocked),
        authorDid: blocked.author.did.didString(),
        postUri: nestedWrapper.threadItem.uri,
        variant: .thread,
        path: $path
      )
      .applyAppStateEnvironment(appState)
      .padding(.leading, indent)

    case .appBskyUnspeccedDefsThreadItemNoUnauthenticated:
      Text("Reply not available (authentication required)")
        .appFont(AppTextRole.subheadline)
        .foregroundColor(.gray)
        .padding(.leading, indent)

    case .unexpected(let unexpected):
      Text("Unexpected reply type: \(unexpected.textRepresentation)")
        .foregroundColor(.orange)
        .padding(.leading, indent)
    }
    if item.hasAdditionalReplies {
      continuationButton(for: nestedWrapper.uri, count: item.additionalReplyCount, depth: item.depth)
    }
  }

  /// Opens the reply's focused thread. Flat mode labels it with the number of
  /// collapsed replies; nested mode uses it past the depth cap.
  private func continuationButton(for uri: ATProtocolURI, count: Int, depth: Int) -> some View {
    Button {
      path.append(NavigationDestination.post(uri))
    } label: {
      HStack {
        Text(continuationTitle(count: count)).appFont(AppTextRole.subheadline)
        Image(systemName: "chevron.right").appFont(AppTextRole.subheadline)
      }
      .foregroundColor(.accentColor)
      .padding(.vertical, 8)
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .padding(
      .leading,
      ThreadReplyPresentationMetrics.leadingIndent(forDepth: depth, isEnabled: isThreadedRepliesMode)
    )
    .accessibilityHint("Opens this post to show more replies")
  }

  private func continuationTitle(count: Int) -> String {
    guard !isThreadedRepliesMode, count > 0 else { return "Continue thread" }
    return count == 1 ? "Show 1 more reply" : "Show \(count) more replies"
  }
}
#endif
