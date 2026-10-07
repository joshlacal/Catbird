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
///
/// Thread items and profiles are several KB inline, and Debug builds reserve a
/// stack slot for every view temporary a body builds. So the row keeps them in
/// `EquatableBox`es and renders posts and tombstones through small child views,
/// which keeps every value this body handles to a few hundred bytes.
struct ThreadRowView: View {
  let row: ThreadRow
  /// The thread item behind tombstone rows. Post items never become tombstones
  /// (`ThreadRowBuilder`), so for them only `itemPost` is kept.
  private let threadItem: EquatableBox<AppBskyUnspeccedGetPostThreadV2.ThreadItem>?
  /// The item's post, extracted once so the post row borrows it instead of
  /// copying it out of the item's union on every render.
  private let itemPost: EquatableBox<AppBskyUnspeccedDefs.ThreadItemPost>?
  /// Author of the row's parent, shown as "in reply to" when the parent is not
  /// the row directly above.
  private let parentAuthor: EquatableBox<AppBskyActorDefs.ProfileViewBasic>?
  @Binding var path: NavigationPath
  let appState: AppState
  let visibilityContext: PostVisibilityContext
  let maxContentWidth: CGFloat
  /// Loading state of the action behind `.readMoreUp` / `.showOtherReplies`.
  let isActionLoading: Bool
  let onAction: (() -> Void)?

  init(
    row: ThreadRow,
    threadItem: AppBskyUnspeccedGetPostThreadV2.ThreadItem?,
    parentAuthor: AppBskyActorDefs.ProfileViewBasic?,
    path: Binding<NavigationPath>,
    appState: AppState,
    visibilityContext: PostVisibilityContext = .public,
    maxContentWidth: CGFloat = .infinity,
    isActionLoading: Bool = false,
    onAction: (() -> Void)? = nil
  ) {
    self.row = row
    if let threadItem {
      if case .appBskyUnspeccedDefsThreadItemPost(let itemPost) = threadItem.value {
        self.itemPost = EquatableBox(itemPost)
        self.threadItem = nil
      } else {
        self.itemPost = nil
        self.threadItem = EquatableBox(threadItem)
      }
    } else {
      self.threadItem = nil
      self.itemPost = nil
    }
    self.parentAuthor = parentAuthor.map { EquatableBox($0) }
    self._path = path
    self.appState = appState
    self.visibilityContext = visibilityContext
    self.maxContentWidth = maxContentWidth
    self.isActionLoading = isActionLoading
    self.onAction = onAction
  }

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
      if let itemPost {
        ThreadReplyPostRow(
          itemPost: itemPost,
          parentAuthor: parentAuthor,
          // A connected parent is visible right above; otherwise name it.
          showsReplyTarget: !(row.lineIn || row.depth <= 1),
          isReply: row.kind == .reply,
          usesTreeGeometry: row.usesTreeGeometry,
          indentLevel: row.indentLevel,
          path: $path,
          appState: appState,
          visibilityContext: visibilityContext
        )
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
          Text(count == 1 ? "Show 1 More Reply" : "Show \(count) More Replies")
            .appFont(AppTextRole.subheadline)
          Image(systemName: "chevron.right")
            .appFont(AppTextRole.caption)
        }
        .foregroundStyle(Color("AccentTextColor"))
        .frame(minHeight: ThreadReplyGeometry.readMoreHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Extend the hit area into the row's padding to reach 44pt without
        // changing the row's height or its connector geometry.
        .contentShape(Rectangle().inset(by: -Self.hitAreaOutset))
      }
      .buttonStyle(.plain)
      .accessibilityHint("Opens this conversation to show more replies")

    case .readMoreUp:
      actionButton(title: "Show Earlier Posts", loadingTitle: "Loading earlier posts…", alignment: .leading)

    case .showOtherReplies:
      actionButton(title: "Show More Replies", loadingTitle: "Loading replies…", alignment: .center)
        .frame(maxWidth: .infinity)

    case .anchor:
      EmptyView()
    }
  }

  private var tombstoneContent: ThreadTombstoneRow {
    ThreadTombstoneRow(threadItem: threadItem, path: $path, appState: appState)
  }

  /// Extra hit area around compact text controls so they reach the 44pt minimum.
  private static let hitAreaOutset: CGFloat = max(0, (44 - ThreadReplyGeometry.readMoreHeight) / 2)

  private func actionButton(title: String, loadingTitle: String, alignment: Alignment) -> some View {
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
      .foregroundStyle(Color("AccentTextColor"))
      .frame(minHeight: ThreadReplyGeometry.readMoreHeight)
      .frame(maxWidth: .infinity, alignment: alignment)
      .contentShape(Rectangle().inset(by: -Self.hitAreaOutset))
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

// MARK: - Row content

/// A post row's `PostView`. Its own view, so the row's body only holds these
/// few fields; the post view and its modifiers are built in this body alone.
private struct ThreadReplyPostRow: View {
  let itemPost: EquatableBox<AppBskyUnspeccedDefs.ThreadItemPost>
  let parentAuthor: EquatableBox<AppBskyActorDefs.ProfileViewBasic>?
  /// Names the parent as "in reply to" because it is not the row directly above.
  let showsReplyTarget: Bool
  let isReply: Bool
  let usesTreeGeometry: Bool
  let indentLevel: Int
  @Binding var path: NavigationPath
  let appState: AppState
  let visibilityContext: PostVisibilityContext

  var body: some View {
    let rootURI = threadRootURI(for: itemPost.value.post)
    return PostView(
      post: itemPost.value.post,
      grandparentAuthor: showsReplyTarget ? parentAuthor?.value : nil,
      isParentPost: false,
      isSelectable: false,
      path: $path,
      appState: appState,
      hasVisibleThreadContext: true,
      avatarScale: usesTreeGeometry ? .tree : .regular,
      visibilityContext: visibilityContext,
      rootPostURI: rootURI,
      rootAuthorDID: rootURI?.authority,
      isReplyHiddenByThreadgate: itemPost.value.hiddenByThreadgate,
      opThreadPostIndex: itemPost.value.opThreadPostIndex,
      opThreadPostCount: itemPost.value.opThreadPostCount
    )
    .contentShape(Rectangle())
    .onTapGesture {
      path.append(NavigationDestination.post(itemPost.value.post.uri))
    }
    .accessibilityCustomContent(AccessibilityCustomContentKey("Replying to"), replyingTo, importance: .high)
    .accessibilityCustomContent(AccessibilityCustomContentKey("Reply level"), replyLevel)
  }

  /// Nesting is only drawn with rails, so describe it for VoiceOver.
  private var replyingTo: Text? {
    isReply ? parentAuthor.map { Text(verbatim: "@\($0.value.handle.description)") } : nil
  }

  private var replyLevel: Text? {
    usesTreeGeometry ? Text("\(indentLevel + 1)") : nil
  }
}

/// A blocked, missing or unreadable thread item in place of a post.
private struct ThreadTombstoneRow: View {
  let threadItem: EquatableBox<AppBskyUnspeccedGetPostThreadV2.ThreadItem>?
  @Binding var path: NavigationPath
  let appState: AppState

  var body: some View {
    if let threadItem {
      switch Self.tombstone(for: threadItem) {
      case .blocked(let relationship, let authorDID):
        ThreadBlockedTombstone(
          relationship: relationship,
          authorDID: authorDID,
          threadItem: threadItem,
          path: $path,
          appState: appState
        )

      case .notFound:
        ThreadNotFoundTombstone(threadItem: threadItem, path: $path, appState: appState)

      case .noUnauthenticated:
        Text("Only visible to signed-in users")
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(.secondary)

      case .unexpected:
        Text("This post can’t be displayed")
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

  private enum Tombstone {
    case blocked(BlockRelationship, authorDID: String)
    case notFound
    case noUnauthenticated
    case unexpected
  }

  /// Reads the item's union in a plain function, so the builder above only
  /// switches over these small values.
  private static func tombstone(
    for threadItem: EquatableBox<AppBskyUnspeccedGetPostThreadV2.ThreadItem>
  ) -> Tombstone {
    switch threadItem.value.value {
    case .appBskyUnspeccedDefsThreadItemBlocked(let blocked):
      return .blocked(BlockRelationship(threadItemBlocked: blocked), authorDID: blocked.author.did.didString())
    case .appBskyUnspeccedDefsThreadItemNotFound, .appBskyUnspeccedDefsThreadItemPost:
      return .notFound
    case .appBskyUnspeccedDefsThreadItemNoUnauthenticated:
      return .noUnauthenticated
    case .unexpected:
      return .unexpected
    }
  }
}

/// The blocked-post card, in its own view so the tombstone's branches stay small.
private struct ThreadBlockedTombstone: View {
  let relationship: BlockRelationship
  let authorDID: String
  let threadItem: EquatableBox<AppBskyUnspeccedGetPostThreadV2.ThreadItem>
  @Binding var path: NavigationPath
  let appState: AppState

  var body: some View {
    BlockedContentCard(
      relationship: relationship,
      authorDid: authorDID,
      postUri: threadItem.value.uri,
      variant: .thread,
      path: $path
    )
    .applyAppStateEnvironment(appState)
  }
}

/// The not-found tombstone, in its own view so the tombstone's branches stay small.
private struct ThreadNotFoundTombstone: View {
  let threadItem: EquatableBox<AppBskyUnspeccedGetPostThreadV2.ThreadItem>
  @Binding var path: NavigationPath
  let appState: AppState

  var body: some View {
    PostNotFoundView(uri: threadItem.value.uri, reason: .notFound, path: $path)
      .applyAppStateEnvironment(appState)
  }
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
          Color.secondary.opacity(0.4),
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
  /// Boxed: the post is about 3 KB inline, and this view and its body would
  /// otherwise carry a copy of it.
  private let post: EquatableBox<AppBskyFeedDefs.PostView>
  let showsLineFromParent: Bool
  @Binding var path: NavigationPath
  let appState: AppState
  let visibilityContext: PostVisibilityContext
  let opThreadPostIndex: Int?
  let opThreadPostCount: Int?

  init(
    post: AppBskyFeedDefs.PostView,
    showsLineFromParent: Bool,
    path: Binding<NavigationPath>,
    appState: AppState,
    visibilityContext: PostVisibilityContext = .public,
    opThreadPostIndex: Int? = nil,
    opThreadPostCount: Int? = nil
  ) {
    self.post = EquatableBox(post)
    self.showsLineFromParent = showsLineFromParent
    self._path = path
    self.appState = appState
    self.visibilityContext = visibilityContext
    self.opThreadPostIndex = opThreadPostIndex
    self.opThreadPostCount = opThreadPostCount
  }

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
      .stroke(Color.secondary.opacity(0.4), lineWidth: ThreadReplyGeometry.lineWidth)
      .frame(height: ThreadReplyGeometry.anchorAvatarTop, alignment: .top)
      .flipsForRightToLeftLayoutDirection(true)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }
}
