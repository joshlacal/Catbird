#if os(iOS)
import AppIntents
import Petrel
import SwiftUI
import UIKit

// MARK: - Cell Types
@available(iOS 18.0, *)
final class ParentPostCell: UICollectionViewCell {
  private var configuredIdentity: String?

  override init(frame: CGRect) {
    super.init(frame: frame)
    // Background color will be set in configure method
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
    parentPost: ParentPost,
    appState: AppState,
    path: Binding<NavigationPath>,
    visibilityContext: PostVisibilityContext = .public
  ) {
    // Set themed background color
      contentView.backgroundColor = UIColor(
        Color.dynamicBackground(appState.themeManager, currentScheme: contentView.getCurrentColorScheme())
      )

    // Responder-level onscreen-context annotation — SwiftUI modifiers inside
    // UIHostingConfiguration content aren't collected by the system.
    // Only annotate if the id is a real at-uri; synthetic ids (e.g. from
    // .unexpected thread items) can't be resolved and would cause ATProtocolError.
#if compiler(>=7.0)
    if #available(iOS 26.0, *),
      let entityURI = AppEntityAnnotationIdentifiers.postURI(parentPost.id) {
      appEntityIdentifier = EntityIdentifier(for: PostEntity.self, identifier: entityURI)
    } else if #available(iOS 26.0, *) {
      appEntityIdentifier = nil
    }
#endif
    
    let content = AnyView(
      WidthLimitedContainer(maxWidth: 600) {
        ParentPostView(
          parentPost: parentPost,
          path: path,
          appState: appState,
          visibilityContext: visibilityContext
        )
        .padding(.horizontal, 3)
        .padding(.vertical, 3)
      }
    )

    // Only reconfigure if needed (using post id as identity check)
    if contentConfiguration == nil
      || parentPost.id != configuredIdentity {

      configuredIdentity = parentPost.id

      // Configure with SwiftUI content
      contentConfiguration = UIHostingConfiguration {
        content.transaction { txn in txn.animation = nil }.fixedSize(horizontal: false, vertical: true)
      }
      .margins(.all, .zero)
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
#if compiler(>=7.0)
    if #available(anyAppleOS 26.0, *) {
      appEntityIdentifier = nil
    }
#endif
    // Clean up resources when cell is reused
    contentConfiguration = nil
    configuredIdentity = nil
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
    visibilityContext: PostVisibilityContext = .public
  ) {
    let postIdentity = post.uri.uriString()

#if compiler(>=7.0)
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
    
    // Avoid removing/readding subviews if configuration hasn't changed
    let content =
      VStack(spacing: 0) {
        WidthLimitedContainer(maxWidth: 600) {
          ThreadViewMainPostView(
            post: post,
            showLine: false,
            path: path,
            appState: appState,
            visibilityContext: visibilityContext,
            opThreadPostIndex: opThreadPostIndex,
            opThreadPostCount: opThreadPostCount
          )
          .padding(.horizontal, 6)
          .padding(.vertical, 6)
        }

        // Full-bleed divider across entire screen width
        Divider()
          .padding(.bottom, 9)
      }
    .id(postIdentity)

    // Only reconfigure if needed (using post URI as identity check)
    if contentConfiguration == nil
      || postIdentity != configuredIdentity {

      configuredIdentity = postIdentity

      // Configure with SwiftUI content
      contentConfiguration = UIHostingConfiguration {
          content.transaction { txn in txn.animation = nil }.fixedSize(horizontal: false, vertical: true)
      }
      .margins(.all, .zero)
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
#if compiler(>=7.0)
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
      VStack(spacing: 0) {
        WidthLimitedContainer(maxWidth: 600) {
          BlockedContentCard(
            relationship: BlockRelationship(threadItemBlocked: blocked),
            authorDid: blocked.author.did.didString(),
            postUri: anchorURI,
            variant: .anchor,
            path: path
          )
          .applyAppStateEnvironment(appState)
          .padding(.horizontal, 6)
          .padding(.vertical, 6)
        }

        Divider()
          .padding(.bottom, 9)
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

@available(iOS 18.0, *)
final class ReplyCell: UICollectionViewCell {
  override init(frame: CGRect) {
    super.init(frame: frame)
    // Background color will be set in configure method
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
    replyWrapper: ReplyWrapper, 
    nestedReplies: [ReplyWrapper],
    opAuthorID: String, 
    appState: AppState,
    path: Binding<NavigationPath>,
    visibilityContext: PostVisibilityContext = .public
  ) {
#if compiler(>=7.0)
    if #available(anyAppleOS 26.0, *),
      let entityURI = AppEntityAnnotationIdentifiers.postURI(replyWrapper.id) {
      appEntityIdentifier = EntityIdentifier(for: PostEntity.self, identifier: entityURI)
    } else if #available(anyAppleOS 26.0, *) {
      appEntityIdentifier = nil
    }
#endif

    // Set themed background color
      contentView.backgroundColor = UIColor(
        Color.dynamicBackground(appState.themeManager, currentScheme: contentView.getCurrentColorScheme())
      )
    
    let content = AnyView(
      VStack(spacing: 0) {
        WidthLimitedContainer(maxWidth: 600) {
          ReplyView(
            replyWrapper: replyWrapper,
            opAuthorID: opAuthorID,
            nestedReplies: nestedReplies,
            path: path,
            appState: appState,
            visibilityContext: visibilityContext
          )
          .padding(.horizontal, 10)
        }

        // Full-bleed divider across entire screen width
        Divider()
          .padding(.vertical, 3)
      }
    )

    // Configure with SwiftUI content
    contentConfiguration = UIHostingConfiguration {
      content.transaction { txn in txn.animation = nil }.fixedSize(horizontal: false, vertical: true)
    }
    .margins(.all, .zero)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
#if compiler(>=7.0)
    if #available(anyAppleOS 26.0, *) {
      appEntityIdentifier = nil
    }
#endif
    contentConfiguration = nil
  }
}
#endif
