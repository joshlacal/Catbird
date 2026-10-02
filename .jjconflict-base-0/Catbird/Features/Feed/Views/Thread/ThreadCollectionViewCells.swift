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

  func configure(
    row: ThreadRow,
    threadItem: AppBskyUnspeccedGetPostThreadV2.ThreadItem?,
    parentAuthor: AppBskyActorDefs.ProfileViewBasic?,
    appState: AppState,
    path: Binding<NavigationPath>,
    visibilityContext: PostVisibilityContext = .public,
    isActionLoading: Bool = false,
    onAction: (() -> Void)? = nil
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

    contentConfiguration = UIHostingConfiguration {
      content
        .applyAppStateEnvironment(appState)
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
    contentConfiguration = nil
  }
}

@available(iOS 18.0, *)
final class MainPostCell: UICollectionViewCell {
  private var configuredIdentity: String?

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

  func configure(
    post: AppBskyFeedDefs.PostView,
    appState: AppState,
    path: Binding<NavigationPath>,
    opThreadPostIndex: Int? = nil,
    opThreadPostCount: Int? = nil,
    visibilityContext: PostVisibilityContext = .public,
    showsLineFromParent: Bool = false
  ) {
    let postIdentity = post.uri.uriString()
    let configurationIdentity = postIdentity + (showsLineFromParent ? "|line-in" : "")

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

    // Only reconfigure if needed (using post URI as identity check)
    if contentConfiguration == nil
      || configurationIdentity != configuredIdentity {

      configuredIdentity = configurationIdentity

      // Supply state at the UIKit hosting boundary for all main-post descendants.
      contentConfiguration = UIHostingConfiguration {
        content
          .applyAppStateEnvironment(appState)
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

  func configure(
    blocked: AppBskyUnspeccedDefs.ThreadItemBlocked,
    anchorURI: ATProtocolURI,
    appState: AppState,
    path: Binding<NavigationPath>
  ) {
    contentView.backgroundColor = UIColor(
      Color.dynamicBackground(appState.themeManager, currentScheme: contentView.getCurrentColorScheme())
    )

    let identity = anchorURI.uriString() + "|" + blocked.author.did.didString()
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
        .applyAppStateEnvironment(appState)
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
