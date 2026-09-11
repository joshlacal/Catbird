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
        opThreadPostCount: threadItemPost.opThreadPostCount
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
  @Environment(\.layoutDirection) private var layoutDirection
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

  private var visibleNestedReplies: [ReplyWrapper] {
    nestedReplies.filter { $0.depth <= maxDepth }
  }

  private var nestedLayout: ThreadReplyLayout {
    ThreadReplyLayoutBuilder.build(
      rootID: replyWrapper.id,
      nestedItems: nestedReplies.map {
        ThreadReplyLayoutInput(
          id: $0.id,
          parentID: $0.parentURI,
          hasUnloadedReplies: $0.hasReplies,
          depth: $0.depth
        )
      },
      maximumDepth: maxDepth,
      rootHasUnloadedReplies: replyWrapper.hasReplies
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
    // Every root arm — post or tombstone — renders `nestedRepliesSection` so
    // the depth-2+ subtree stays visible even when the chain root is blocked /
    // not-found / no-auth. Dropping the subtree with the root would defeat the
    // whole "keep replies under a blocked post reachable" goal.
    VStack(alignment: .leading, spacing: 0) {
      switch replyWrapper.threadItem.value {
      case .appBskyUnspeccedDefsThreadItemPost(let threadItemPost):
        let replyRootURI = threadRootURI(for: threadItemPost.post)

        // Root post connects to the first nested reply when the layout says so.
        PostView(
          post: threadItemPost.post,
          grandparentAuthor: nil,
          isParentPost: !isThreadedRepliesMode && nestedLayout.connectsRootToFirst,
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
        .environment(\.threadAvatarID, isThreadedRepliesMode ? replyWrapper.id : nil)
        .onTapGesture {
          path.append(NavigationDestination.post(threadItemPost.post.uri))
        }
        .padding(.vertical, 3)
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

      // Nested subtree, shared across all root arms above.
      if nestedLayout.rootHasAdditionalReplies {
        continuationButton(for: replyWrapper.uri)
      }
      nestedRepliesSection
    }
    .overlayPreferenceValue(ThreadAvatarAnchorKey.self) { anchors in
      if isThreadedRepliesMode {
        GeometryReader { geometry in
          Path { path in
            let layout = nestedLayout
            let ids = [replyWrapper.id] + layout.items.map(\.id)
            let connections = [layout.connectsRootToFirst] + layout.items.map(\.connectsToNext)
            for index in 0..<max(0, ids.count - 1) where connections[index] {
              if let source = anchors[ids[index]], let destination = anchors[ids[index + 1]] {
                let parent = geometry[source]
                let child = geometry[destination]
                // Work in leading-to-trailing coordinates, then mirror for RTL.
                let direction: CGFloat = layoutDirection == .rightToLeft ? -1 : 1
                let childLeading = direction > 0 ? child.minX : -child.maxX
                let end = CGPoint(x: childLeading - 3, y: child.midY)
                let gutter = min(parent.midX * direction, end.x - 8)
                let start = CGPoint(x: parent.midX * direction, y: parent.maxY + 3)
                func point(_ value: CGPoint) -> CGPoint {
                  CGPoint(x: value.x * direction, y: value.y)
                }
                path.move(to: point(start))
                path.addQuadCurve(
                  to: point(CGPoint(x: gutter, y: start.y + 8)),
                  control: point(CGPoint(x: gutter, y: start.y))
                )
                path.addLine(to: point(CGPoint(x: gutter, y: end.y - 8)))
                path.addQuadCurve(
                  to: point(CGPoint(x: gutter + 8, y: end.y)),
                  control: point(CGPoint(x: gutter, y: end.y))
                )
                path.addLine(to: point(end))
              }
            }
          }
          .stroke(Color.systemGray4, style: StrokeStyle(lineWidth: 2, lineCap: .round))
          // Anchors are already in physical coordinates; do not mirror the Path again.
          .environment(\.layoutDirection, .leftToRight)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
    }
  }

  /// Renders the depth-2+ nested replies for this chain using their actual
  /// parent relationships. Invoked from every root arm so a blocked / not-found
  /// / no-auth root keeps its subtree. `parentAuthor(for:)` returns nil for a
  /// tombstone root (its `post` is nil), so nested rows degrade to no
  /// grandparent label rather than crashing or mislabeling.
  @ViewBuilder
  private var nestedRepliesSection: some View {
    let layout = nestedLayout
    let visibleReplies = visibleNestedReplies
    if !layout.items.isEmpty {
      ForEach(layout.items) { item in
        if let nestedWrapper = visibleReplies.first(where: { $0.id == item.id }) {
          nestedReplyRow(item: item, nestedWrapper: nestedWrapper)
        }
      }
    }
  }

  @ViewBuilder
  private func nestedReplyRow(item: ThreadReplyLayoutItem, nestedWrapper: ReplyWrapper) -> some View {
    switch nestedWrapper.threadItem.value {
    case .appBskyUnspeccedDefsThreadItemPost(let nestedPost):
      let nestedRootURI = threadRootURI(for: nestedPost.post)

      PostView(
        post: nestedPost.post,
        grandparentAuthor: parentAuthor(for: nestedWrapper),
        isParentPost: !isThreadedRepliesMode && item.connectsToNext,
        isSelectable: false,
        path: $path,
        appState: appState,
        hasVisibleThreadContext: true,
        avatarScale: ThreadReplyPresentationMetrics.avatarScale(
          forDepth: nestedWrapper.depth,
          isEnabled: isThreadedRepliesMode
        ),
        visibilityContext: visibilityContext,
        rootPostURI: nestedRootURI,
        rootAuthorDID: nestedRootURI?.authority,
        isReplyHiddenByThreadgate: nestedPost.hiddenByThreadgate,
        opThreadPostIndex: nestedPost.opThreadPostIndex,
        opThreadPostCount: nestedPost.opThreadPostCount
      )
      .environment(\.threadAvatarID, isThreadedRepliesMode ? nestedWrapper.id : nil)
      .contentShape(Rectangle())
      .onTapGesture { path.append(NavigationDestination.post(nestedPost.post.uri)) }
      .padding(.vertical, 3)
      .padding(
        .leading,
        ThreadReplyPresentationMetrics.leadingIndent(
          forDepth: nestedWrapper.depth,
          isEnabled: isThreadedRepliesMode
        )
      )
      .frame(maxWidth: 550, alignment: .leading)

    case .appBskyUnspeccedDefsThreadItemNotFound:
      PostNotFoundView(
        uri: nestedWrapper.threadItem.uri,
        reason: .notFound,
        path: $path
      )
      .applyAppStateEnvironment(appState)

    case .appBskyUnspeccedDefsThreadItemBlocked(let blocked):
      BlockedContentCard(
        relationship: BlockRelationship(threadItemBlocked: blocked),
        authorDid: blocked.author.did.didString(),
        postUri: nestedWrapper.threadItem.uri,
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
    if item.hasAdditionalReplies {
      continuationButton(for: nestedWrapper.uri)
    }
  }

  private func continuationButton(for uri: ATProtocolURI) -> some View {
    Button {
      path.append(NavigationDestination.post(uri))
    } label: {
      HStack {
        Text("Continue thread").appFont(AppTextRole.subheadline)
        Image(systemName: "chevron.right").appFont(AppTextRole.subheadline)
      }
      .foregroundColor(.accentColor)
      .padding(.vertical, 8)
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .accessibilityHint("Opens this post to show more replies")
  }
}
#endif
