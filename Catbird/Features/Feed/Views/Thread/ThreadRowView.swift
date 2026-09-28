//
//  ThreadRowView.swift
//  Catbird
//

import Petrel
import SwiftUI

// MARK: - Row

/// Renders one `ThreadRow` (everything except the anchor post) together with
/// the connector pieces that row owns. Shared by the iOS collection view cells
/// and the macOS SwiftUI thread.
struct ThreadRowView: View {
  let row: ThreadRow
  /// The thread item behind post and tombstone rows.
  let threadItem: AppBskyUnspeccedGetPostThreadV2.ThreadItem?
  /// Author of the row's parent, shown as "in reply to" when the parent is not
  /// the row directly above.
  let parentAuthor: AppBskyActorDefs.ProfileViewBasic?
  @Binding var path: NavigationPath
  let appState: AppState
  var visibilityContext: PostVisibilityContext = .public
  var maxContentWidth: CGFloat = .infinity
  /// Loading state of the action behind `.readMoreUp` / `.showOtherReplies`.
  var isActionLoading: Bool = false
  var onAction: (() -> Void)?

  private var metrics: ThreadRowMetrics { ThreadRowMetrics(row: row) }

  var body: some View {
    VStack(spacing: 0) {
      if row.startsBranch {
        Divider()
      }
      rowContent
        .frame(maxWidth: maxContentWidth)
        .frame(maxWidth: .infinity)
    }
  }

  private var rowContent: some View {
    let metrics = metrics
    return content
      .padding(.leading, metrics.contentLeading)
      .padding(
        .trailing,
        row.isPost
          ? ThreadReplyGeometry.rowInset - ThreadReplyGeometry.postAvatarLeadingInset
          : ThreadReplyGeometry.rowInset
      )
      .padding(.top, metrics.topPadding)
      .padding(.bottom, metrics.bottomPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(alignment: .topLeading) {
        ThreadRowConnectors(metrics: metrics)
      }
  }

  @ViewBuilder
  private var content: some View {
    switch row.kind {
    case .ancestor, .reply:
      if let threadItem, case .appBskyUnspeccedDefsThreadItemPost(let itemPost) = threadItem.value {
        postContent(itemPost)
      } else {
        tombstoneContent
      }

    case .tombstone:
      tombstoneContent

    case .readMore(let count, let target):
      Button {
        path.append(NavigationDestination.post(target))
      } label: {
        HStack(spacing: 6) {
          Text(count == 1 ? "Show 1 more reply" : "Show \(count) more replies")
            .appFont(AppTextRole.subheadline)
          Image(systemName: "chevron.right")
            .appFont(AppTextRole.caption)
        }
        .foregroundStyle(Color.accentColor)
        .frame(minHeight: ThreadReplyGeometry.readMoreHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHint("Opens this conversation to show more replies")

    case .readMoreUp:
      actionButton(title: "Show earlier posts", loadingTitle: "Loading earlier posts")

    case .showOtherReplies:
      actionButton(title: "Show more replies", loadingTitle: "Loading replies")
        .frame(maxWidth: .infinity)

    case .anchor:
      EmptyView()
    }
  }

  private func postContent(_ itemPost: AppBskyUnspeccedDefs.ThreadItemPost) -> some View {
    let rootURI = threadRootURI(for: itemPost.post)
    // A connected parent is visible right above; otherwise name it.
    let replyTarget = row.lineIn || row.depth <= 1 ? nil : parentAuthor
    return PostView(
      post: itemPost.post,
      grandparentAuthor: replyTarget,
      isParentPost: false,
      isSelectable: false,
      path: $path,
      appState: appState,
      hasVisibleThreadContext: true,
      avatarScale: row.usesTreeGeometry ? .tree : .regular,
      visibilityContext: visibilityContext,
      rootPostURI: rootURI,
      rootAuthorDID: rootURI?.authority,
      isReplyHiddenByThreadgate: itemPost.hiddenByThreadgate,
      opThreadPostIndex: itemPost.opThreadPostIndex,
      opThreadPostCount: itemPost.opThreadPostCount
    )
    .contentShape(Rectangle())
    .onTapGesture {
      path.append(NavigationDestination.post(itemPost.post.uri))
    }
  }

  @ViewBuilder
  private var tombstoneContent: some View {
    if let threadItem {
      switch threadItem.value {
      case .appBskyUnspeccedDefsThreadItemBlocked(let blocked):
        BlockedContentCard(
          relationship: BlockRelationship(threadItemBlocked: blocked),
          authorDid: blocked.author.did.didString(),
          postUri: threadItem.uri,
          variant: .thread,
          path: $path
        )
        .applyAppStateEnvironment(appState)

      case .appBskyUnspeccedDefsThreadItemNotFound, .appBskyUnspeccedDefsThreadItemPost:
        PostNotFoundView(uri: threadItem.uri, reason: .notFound, path: $path)
          .applyAppStateEnvironment(appState)

      case .appBskyUnspeccedDefsThreadItemNoUnauthenticated:
        Text("Post not available (authentication required)")
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(.secondary)

      case .unexpected(let unexpected):
        Text("Unsupported post type: \(unexpected.textRepresentation)")
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func actionButton(title: String, loadingTitle: String) -> some View {
    Button {
      onAction?()
    } label: {
      HStack(spacing: 8) {
        Text(isActionLoading ? loadingTitle : title)
          .appFont(AppTextRole.subheadline)
          .fontWeight(.medium)
        if isActionLoading {
          ProgressView()
            .controlSize(.small)
        }
      }
      .foregroundStyle(Color.accentColor)
      .frame(minHeight: ThreadReplyGeometry.readMoreHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isActionLoading || onAction == nil)
  }
}

/// Root post URI for a thread item: the record's reply root, else the post itself.
private func threadRootURI(for post: AppBskyFeedDefs.PostView) -> ATProtocolURI? {
  if case .knownType(let record) = post.record,
    let feedPost = record as? AppBskyFeedPost,
    let root = feedPost.reply?.root.uri {
    return root
  }
  return post.uri
}

// MARK: - Connectors

/// The connector pieces one row owns: rails of ancestors that continue past
/// it, the line or elbow entering it, and the line leaving it. Every x is a
/// fixed geometry value, so neighbouring rows meet without measuring each other.
struct ThreadRowConnectors: View {
  let metrics: ThreadRowMetrics

  var body: some View {
    GeometryReader { geometry in
      connectorPath(height: geometry.size.height)
        .stroke(
          Color.systemGray4,
          style: StrokeStyle(lineWidth: ThreadReplyGeometry.lineWidth, lineCap: .butt, lineJoin: .round)
        )
    }
    .flipsForRightToLeftLayoutDirection(true)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func connectorPath(height: CGFloat) -> Path {
    let row = metrics.row
    var path = Path()

    for (level, continues) in row.continuingRails.enumerated() where continues {
      let railX = ThreadReplyGeometry.railX(level: level)
      path.move(to: CGPoint(x: railX, y: 0))
      path.addLine(to: CGPoint(x: railX, y: height))
    }

    if row.lineIn {
      let lineX = metrics.incomingLineX
      if metrics.incomingLineBends {
        let elbowY = metrics.markerCenterY
        let endX = metrics.markerLeading - ThreadReplyGeometry.lineGap
        let radius = min(ThreadReplyGeometry.elbowRadius, max(0, endX - lineX), elbowY)
        path.move(to: CGPoint(x: lineX, y: 0))
        path.addLine(to: CGPoint(x: lineX, y: elbowY - radius))
        path.addQuadCurve(to: CGPoint(x: lineX + radius, y: elbowY), control: CGPoint(x: lineX, y: elbowY))
        path.addLine(to: CGPoint(x: endX, y: elbowY))
      } else {
        path.move(to: CGPoint(x: lineX, y: 0))
        path.addLine(to: CGPoint(x: lineX, y: max(0, metrics.markerTop - ThreadReplyGeometry.lineGap)))
      }
    }

    if row.lineOut {
      let lineX = metrics.outgoingLineX
      let startY = metrics.outgoingLineStartY(rowHeight: height)
      if startY < height {
        path.move(to: CGPoint(x: lineX, y: startY))
        path.addLine(to: CGPoint(x: lineX, y: height))
      }
    }

    return path
  }
}

// MARK: - Anchor

/// The anchor post with the line entering its avatar from the ancestor above.
///
/// The main post view pins its avatar to its top edge, 6pt in from its leading
/// edge, so this padding puts the avatar on the linear line x and at
/// `ThreadReplyGeometry.anchorAvatarTop`. Replies below draw their own branch
/// divider, so the anchor has none.
struct ThreadAnchorPostView: View {
  let post: AppBskyFeedDefs.PostView
  let showsLineFromParent: Bool
  @Binding var path: NavigationPath
  let appState: AppState
  var visibilityContext: PostVisibilityContext = .public
  var opThreadPostIndex: Int?
  var opThreadPostCount: Int?

  var body: some View {
    ThreadViewMainPostView(
      post: post,
      showLine: false,
      path: $path,
      appState: appState,
      visibilityContext: visibilityContext,
      opThreadPostIndex: opThreadPostIndex,
      opThreadPostCount: opThreadPostCount
    )
    .padding(.horizontal, ThreadReplyGeometry.rowInset - ThreadReplyGeometry.postAvatarLeadingInset)
    .padding(.top, ThreadReplyGeometry.anchorAvatarTop)
    .padding(.bottom, ThreadReplyGeometry.postAvatarLeadingInset)
    .background(alignment: .topLeading) {
      ThreadAnchorLineIn(isVisible: showsLineFromParent)
    }
  }
}

/// The line that enters the anchor post's avatar from the ancestor above.
struct ThreadAnchorLineIn: View {
  let isVisible: Bool

  var body: some View {
    if isVisible {
      Path { path in
        let lineX = ThreadReplyGeometry.linearLineX
        path.move(to: CGPoint(x: lineX, y: 0))
        path.addLine(
          to: CGPoint(x: lineX, y: ThreadReplyGeometry.anchorAvatarTop - ThreadReplyGeometry.lineGap))
      }
      .stroke(Color.systemGray4, lineWidth: ThreadReplyGeometry.lineWidth)
      .frame(height: ThreadReplyGeometry.anchorAvatarTop, alignment: .top)
      .flipsForRightToLeftLayoutDirection(true)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }
}
