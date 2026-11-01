#if os(iOS)
import AppIntents
import Petrel
import SwiftUI
import UIKit

// MARK: - Cell Types
/// Hosts one `ThreadRowView`: an ancestor, reply, tombstone or control row.
@available(iOS 18.0, *)
final class ThreadRowCell: UICollectionViewCell {
  override init(frame: CGRect) {
    super.init(frame: frame)
    // Disable implicit layer animations on this cell
    let noAnim: [String: CAAction] = [
      "bounds": NSNull(),
      "position": NSNull(),
      "frame": NSNull(),
      "contents": NSNull(),
      "onOrderIn": NSNull(),
      "onOrderOut": NSNull()
    ]
    layer.actions = noAnim
    contentView.layer.actions = noAnim
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func invalidateIntrinsicContentSize() {
    UIView.performWithoutAnimation {
      super.invalidateIntrinsicContentSize()
    }
  }

  func configure(
    row: ThreadRow,
    threadItem: AppBskyUnspeccedGetPostThreadV2.ThreadItem?,
    parentAuthor: AppBskyActorDefs.ProfileViewBasic?,
    appState: AppState,
    sceneContext: SceneNavigationContext,
    path: Binding<NavigationPath>,
    visibilityContext: PostVisibilityContext = .public,
    isActionLoading: Bool = false,
    onAction: (() -> Void)? = nil,
    onInvalidateHeight: (() -> Void)? = nil
  ) {
    // Responder-level onscreen-context annotation — SwiftUI modifiers inside
    // UIHostingConfiguration content aren't collected by the system.
    // Only annotate if the id is a real at-uri; synthetic ids (control rows,
    // .unexpected thread items) can't be resolved and would cause ATProtocolError.
#if compiler(>=6.4)
    if #available(anyAppleOS 26.0, *),
      row.isPost,
      let entityURI = AppEntityAnnotationIdentifiers.postURI(row.id) {
      appEntityIdentifier = EntityIdentifier(for: PostEntity.self, identifier: entityURI)
    } else if #available(anyAppleOS 26.0, *) {
      appEntityIdentifier = nil
    }
#endif

    contentView.backgroundColor = UIColor(
      Color.dynamicBackground(appState.themeManager, currentScheme: contentView.getCurrentColorScheme())
    )

    let maxContentWidth: CGFloat = traitCollection.horizontalSizeClass == .compact ? .infinity : 600
    let content = ThreadRowView(
      row: row,
      threadItem: threadItem,
      parentAuthor: parentAuthor,
      path: path,
      appState: appState,
      visibilityContext: visibilityContext,
      maxContentWidth: maxContentWidth,
      isActionLoading: isActionLoading,
      onAction: onAction
    )

    // The configuration closure runs once, here: the policy it injects is a
    // snapshot, so the row tracks the live policy itself.
    // A reused cell keeps its hosting view and updates it in place. The identity resets
    // the row's own state, such as PostView's view models, when the cell shows another
    // row or scene, and leaves the modifiers around it in place.
    let rowIdentity = Self.contentIdentity(row: row, sceneContext: sceneContext)
    contentConfiguration = UIHostingConfiguration {
      content
        .id(rowIdentity)
        .environment(\.invalidateFeedRowHeight, onInvalidateHeight)
        .trackingModerationPolicy(of: appState)
        .applyAppStateEnvironment(appState)
        .environment(sceneContext)
        .transaction { txn in txn.animation = nil }
        .fixedSize(horizontal: false, vertical: true)
    }
    .margins(.all, .zero)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
#if compiler(>=6.4)
    if #available(anyAppleOS 26.0, *) {
      appEntityIdentifier = nil
    }
#endif
  }

  /// The SwiftUI identity of a row's content: the row and the scene showing it, in the
  /// same form as MainPostCell's. Reconfiguring the same row keeps its state.
  static func contentIdentity(row: ThreadRow, sceneContext: SceneNavigationContext) -> String {
    "\(row.id)|\(ObjectIdentifier(sceneContext))"
  }
}

@available(iOS 18.0, *)
final class MainPostCell: UICollectionViewCell {
  private(set) var configuredIdentity: String?

  override init(frame: CGRect) {
    super.init(frame: frame)
    // Background color will be set in configure method
    
    // Make this an accessibility element container
    isAccessibilityElement = false
    contentView.isAccessibilityElement = false
    contentView.shouldGroupAccessibilityChildren = true

    // Disable implicit layer animations on this cell
    let noAnim: [String: CAAction] = [
      "bounds": NSNull(),
      "position": NSNull(),
      "frame": NSNull(),
      "contents": NSNull(),
      "onOrderIn": NSNull(),
      "onOrderOut": NSNull()
    ]
    layer.actions = noAnim
    contentView.layer.actions = noAnim
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func invalidateIntrinsicContentSize() {
    UIView.performWithoutAnimation {
      super.invalidateIntrinsicContentSize()
    }
  }

  func configure(
    post: AppBskyFeedDefs.PostView,
    appState: AppState,
    sceneContext: SceneNavigationContext,
    path: Binding<NavigationPath>,
    opThreadPostIndex: Int? = nil,
    opThreadPostCount: Int? = nil,
    visibilityContext: PostVisibilityContext = .public,
    showsLineFromParent: Bool = false,
    onInvalidateHeight: (() -> Void)? = nil
  ) {
    let postIdentity = post.uri.uriString()
    let configurationIdentity = Self.configurationIdentity(
      post: post,
      sceneContext: sceneContext,
      opThreadPostIndex: opThreadPostIndex,
      opThreadPostCount: opThreadPostCount,
      showsLineFromParent: showsLineFromParent
    )

#if compiler(>=6.4)
    if #available(anyAppleOS 26.0, *),
      let entityURI = AppEntityAnnotationIdentifiers.postURI(postIdentity) {
      appEntityIdentifier = EntityIdentifier(for: PostEntity.self, identifier: entityURI)
    } else if #available(anyAppleOS 26.0, *) {
      appEntityIdentifier = nil
    }
#endif

    // Set themed background color
      contentView.backgroundColor = UIColor(
        Color.dynamicBackground(appState.themeManager, currentScheme: contentView.getCurrentColorScheme())
      )
    
    let content =
      WidthLimitedContainer(maxWidth: 600) {
        ThreadAnchorPostView(
          post: post,
          showsLineFromParent: showsLineFromParent,
          path: path,
          appState: appState,
          visibilityContext: visibilityContext,
          opThreadPostIndex: opThreadPostIndex,
          opThreadPostCount: opThreadPostCount
        )
      }
      .id(postIdentity)

    // Only reconfigure when something shown changed. The content keeps `.id(postIdentity)`,
    // so a new copy of the same post (the thread's copy replacing the tapped feed post, or
    // fresh counts after a reload) updates the hosting view in place and keeps its state.
    if contentConfiguration == nil
      || configurationIdentity != configuredIdentity {

      configuredIdentity = configurationIdentity

      // Supply state at the UIKit hosting boundary for all main-post descendants.
      // The policy is tracked, not snapshotted, so a settings change re-gates
      // the anchor in place.
      contentConfiguration = UIHostingConfiguration {
        content
          .environment(\.invalidateFeedRowHeight, onInvalidateHeight)
          .trackingModerationPolicy(of: appState)
          .applyAppStateEnvironment(appState)
          .environment(sceneContext)
          .transaction { txn in txn.animation = nil }
          .fixedSize(horizontal: false, vertical: true)
      }
      .margins(.all, .zero)
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
#if compiler(>=6.4)
    if #available(anyAppleOS 26.0, *) {
      appEntityIdentifier = nil
    }
#endif
    contentConfiguration = nil
    configuredIdentity = nil
  }

  /// What the anchor shows: the post, its line from the parent, the scene, the OP post
  /// number and the parts of the post that change between copies of it (counts and the
  /// viewer's like, repost and bookmark).
  static func configurationIdentity(
    post: AppBskyFeedDefs.PostView,
    sceneContext: SceneNavigationContext,
    opThreadPostIndex: Int?,
    opThreadPostCount: Int?,
    showsLineFromParent: Bool
  ) -> String {
    let lineIn = showsLineFromParent ? "|line-in" : ""
    let number = "\(opThreadPostIndex.map(String.init) ?? "-")/\(opThreadPostCount.map(String.init) ?? "-")"
    let counts = [post.replyCount, post.repostCount, post.likeCount, post.quoteCount, post.bookmarkCount]
      .map { $0.map(String.init) ?? "-" }
      .joined(separator: ",")
    let viewer = [
      post.viewer?.like != nil, post.viewer?.repost != nil, post.viewer?.bookmarked == true
    ].map { $0 ? "1" : "0" }.joined()
    return post.uri.uriString() + lineIn + "|\(ObjectIdentifier(sceneContext))"
      + "|op:\(number)|\(post.cid.string)|\(counts)|\(viewer)"
  }
}

/// Hosts the `BlockedContentCard(.anchor)` in the main-post slot when the
/// thread's depth-0 post is blocked.
@available(iOS 18.0, *)
final class BlockedAnchorCell: UICollectionViewCell {
  private var configuredIdentity: String?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isAccessibilityElement = false
    contentView.isAccessibilityElement = false
    contentView.shouldGroupAccessibilityChildren = true

    let noAnim: [String: CAAction] = [
      "bounds": NSNull(),
      "position": NSNull(),
      "frame": NSNull(),
      "contents": NSNull(),
      "onOrderIn": NSNull(),
      "onOrderOut": NSNull()
    ]
    layer.actions = noAnim
    contentView.layer.actions = noAnim
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func invalidateIntrinsicContentSize() {
    UIView.performWithoutAnimation {
      super.invalidateIntrinsicContentSize()
    }
  }

  func configure(
    blocked: AppBskyUnspeccedDefs.ThreadItemBlocked,
    anchorURI: ATProtocolURI,
    appState: AppState,
    sceneContext: SceneNavigationContext,
    path: Binding<NavigationPath>,
    onInvalidateHeight: (() -> Void)? = nil
  ) {
    contentView.backgroundColor = UIColor(
      Color.dynamicBackground(appState.themeManager, currentScheme: contentView.getCurrentColorScheme())
    )

    let identity = anchorURI.uriString() + "|" + blocked.author.did.didString() + "|\(ObjectIdentifier(sceneContext))"
    guard contentConfiguration == nil || identity != configuredIdentity else { return }
    configuredIdentity = identity

    let content =
      WidthLimitedContainer(maxWidth: 600) {
        BlockedContentCard(
          relationship: BlockRelationship(threadItemBlocked: blocked),
          authorDid: blocked.author.did.didString(),
          postUri: anchorURI,
          variant: .anchor,
          path: path
        )
        .environment(\.invalidateFeedRowHeight, onInvalidateHeight)
        .trackingModerationPolicy(of: appState)
        .applyAppStateEnvironment(appState)
          .environment(sceneContext)
        .padding(.horizontal, ThreadReplyGeometry.rowInset)
        .padding(.vertical, ThreadReplyGeometry.connectedTopSpacing)
      }
      .id(identity)

    contentConfiguration = UIHostingConfiguration {
      content.transaction { txn in txn.animation = nil }.fixedSize(horizontal: false, vertical: true)
    }
    .margins(.all, .zero)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    contentConfiguration = nil
    configuredIdentity = nil
  }
}
#endif
