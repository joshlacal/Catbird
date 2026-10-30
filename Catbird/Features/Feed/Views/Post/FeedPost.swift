//
//  FeedPost.swift
//  Catbird
//
//  Created by Josh LaCalamito on 6/29/24.
//

import Observation
import Petrel
import SwiftUI

/// A SwiftUI view that displays a post in the feed.
///
/// The feed item is held in an `EquatableBox`, and each section of the row is
/// its own small child view that reads the box. Neither this struct nor its
/// body type carries the 7.5 KB `FeedViewPost` or the `PostView`s built from
/// it, so a Debug build no longer stacks every section's temporaries into one
/// frame.
struct FeedPost: View, Equatable {

  static func == (lhs: FeedPost, rhs: FeedPost) -> Bool {
    lhs.id == rhs.id
  }

  // MARK: - Properties
  private let postBox: EquatableBox<AppBskyFeedDefs.FeedViewPost>
  /// The feed item's `id`, computed once and shared with every section.
  private let itemID: String
  private let showsRepostHeader: Bool
  private let showsPinnedBadge: Bool
  /// Which parent the row shows above the post; nil when it shows none.
  private let parentKind: ParentKind?
  @Binding var path: NavigationPath
  @Environment(\.horizontalSizeClass) private var hSizeClass

  private var contentMaxWidth: CGFloat {
    hSizeClass == .compact ? .infinity : 600
  }

  // MARK: - Layout Constants
  fileprivate static let baseUnit: CGFloat = 3
  private static let avatarSize: CGFloat = 48

  // MARK: - Initialization
  init(post: AppBskyFeedDefs.FeedViewPost, path: Binding<NavigationPath>) {
    postBox = EquatableBox(post)
    itemID = post.id
    showsRepostHeader = Self.isRepost(post)
    showsPinnedBadge = Self.isPinned(post)
    parentKind = ParentKind(item: post)
    _path = path
  }

  // MARK: - Computed Properties
  private var id: String {
    "\(itemID)-\(postBox.value.post.uri.uriString())"
  }

  // MARK: - Body
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Repost header if needed (above glass card)
      if showsRepostHeader {
        RepostHeaderRow(postBox: postBox, path: $path)
          .frame(height: FeedPost.baseUnit * 8)
          .padding(.horizontal, FeedPost.baseUnit * 4)
          .padding(.bottom, FeedPost.baseUnit * 1)
      }

      // Pinned badge if needed (above glass card)
      if showsPinnedBadge {
        PinnedBadge()
          .padding(.horizontal, FeedPost.baseUnit * 4)
          .padding(.bottom, FeedPost.baseUnit * 1)
      }

      // Main glass card container
      VStack(alignment: .leading, spacing: 0) {
        // Parent post if needed (for replies)
        if let parentKind {
          ParentRow(kind: parentKind, postBox: postBox, itemID: itemID, path: $path)
            .padding(.bottom, FeedPost.baseUnit * 2)
        }

        // Main post content
        MainPostRow(postBox: postBox, itemID: itemID, path: $path)
      }
      .padding(.vertical, FeedPost.baseUnit * 4)
      .padding(.horizontal, FeedPost.baseUnit * 4)
      .contentShape(Rectangle())
      .allowsHitTesting(true)
    }
    .padding(.horizontal, FeedPost.baseUnit * 2)
    .padding(.vertical, FeedPost.baseUnit * 1)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: contentMaxWidth, alignment: .center)
    .frame(maxWidth: .infinity, alignment: .center)
  }

  // MARK: - Row Flags

  /// Whether the item was reposted into the feed, so the repost header shows.
  private static func isRepost(_ post: AppBskyFeedDefs.FeedViewPost) -> Bool {
    if case .appBskyFeedDefsReasonRepost = post.reason {
      return true
    }
    return false
  }

  /// Whether the pinned badge shows above the post.
  private static func isPinned(_ post: AppBskyFeedDefs.FeedViewPost) -> Bool {
    if case .appBskyFeedDefsReasonPin = post.reason {
      return true
    }
    if let pinned = post.post.viewer?.pinned, pinned {
      return true
    }
    return false
  }
}

// MARK: - Row Sections

// Each section is its own view so the parent's body type holds only these
// small structs, and each section's body is built in its own SwiftUI update.
// Sections read the feed item through the box and build their large child
// views in plain helper functions, so the copied posts live in a short-lived
// frame instead of the body builder's.
extension FeedPost {

  /// The parent a reply row shows above its post.
  fileprivate enum ParentKind {
    case post
    case notFound
    case blocked
    case unexpected

    /// Nil when the item is not a reply, or is a repost (which shows no parent).
    init?(item: AppBskyFeedDefs.FeedViewPost) {
      guard let parent = item.reply?.parent, item.reason == nil else {
        return nil
      }
      switch parent {
      case .appBskyFeedDefsPostView:
        self = .post
      case .appBskyFeedDefsNotFoundPost:
        self = .notFound
      case .appBskyFeedDefsBlockedPost:
        self = .blocked
      case .unexpected:
        self = .unexpected
      }
    }
  }

  /// "Reposted by" header above the glass card.
  fileprivate struct RepostHeaderRow: View {
    let postBox: EquatableBox<AppBskyFeedDefs.FeedViewPost>
    @Binding var path: NavigationPath

    var body: some View {
      makeHeader()
    }

    private func makeHeader() -> RepostHeaderView? {
      guard case .appBskyFeedDefsReasonRepost(let reasonRepost) = postBox.value.reason else {
        return nil
      }
      return RepostHeaderView(reposter: reasonRepost.by, path: $path)
    }
  }

  /// "Pinned" badge above the glass card.
  fileprivate struct PinnedBadge: View {
    var body: some View {
      HStack(alignment: .center, spacing: 6) {
        Image(systemName: "pin")
          .foregroundColor(.secondary)
          .appFont(AppTextRole.subheadline)

        Text("Pinned")
          .appFont(AppTextRole.body)
          .textScale(.secondary)
          .foregroundColor(.secondary)
          .lineLimit(1)
          .allowsTightening(true)
          .fixedSize(horizontal: true, vertical: false)
      }
      .padding(.vertical, 8)
      .padding(.horizontal, 12)
    }
  }

  /// Renders the parent post if this is a reply
  fileprivate struct ParentRow: View {
    let kind: ParentKind
    let postBox: EquatableBox<AppBskyFeedDefs.FeedViewPost>
    let itemID: String
    @Binding var path: NavigationPath

    var body: some View {
      switch kind {
      case .post:
        ParentPostRow(postBox: postBox, itemID: itemID, path: $path)
      case .notFound:
        Text("Post not found")
          .appFont(AppTextRole.caption)
          .foregroundColor(.secondary)
          .padding(.vertical, FeedPost.baseUnit * 2)
      case .blocked:
        BlockedParentRow(postBox: postBox, path: $path)
      case .unexpected:
        Text("Post unavailable")
          .appFont(AppTextRole.caption)
          .foregroundColor(.secondary)
          .padding(.vertical, FeedPost.baseUnit * 2)
      }
    }
  }

  /// A visible parent post, shown above the reply.
  fileprivate struct ParentPostRow: View {
    let postBox: EquatableBox<AppBskyFeedDefs.FeedViewPost>
    let itemID: String
    @Binding var path: NavigationPath
    @Environment(AppState.self) private var appState

    var body: some View {
      if let parentURI = parentPostURI, let parentView = makeParentPostView() {
        parentView
          .environment(\.feedPostID, itemID)
          .id("\(itemID)-parent-\(parentURI.uriString())")
          .contentShape(Rectangle())
          .onTapGesture {
            path.append(NavigationDestination.post(parentURI))
          }
      }
    }

    private var parentPostURI: ATProtocolURI? {
      guard case .appBskyFeedDefsPostView(let parent) = postBox.value.reply?.parent else {
        return nil
      }
      return parent.uri
    }

    private func makeParentPostView() -> PostView? {
      guard case .appBskyFeedDefsPostView(let parent) = postBox.value.reply?.parent else {
        return nil
      }
      return PostView(
        post: parent,
        grandparentAuthor: postBox.value.reply?.grandparentAuthor,
        isParentPost: true,
        isSelectable: false,
        path: $path,
        appState: appState,
        hasVisibleThreadContext: true
      )
    }
  }

  /// A blocked parent post, shown as a tombstone above the reply.
  fileprivate struct BlockedParentRow: View {
    let postBox: EquatableBox<AppBskyFeedDefs.FeedViewPost>
    @Binding var path: NavigationPath

    var body: some View {
      makeCard()
    }

    private func makeCard() -> BlockedContentCard? {
      guard case .appBskyFeedDefsBlockedPost(let blocked) = postBox.value.reply?.parent else {
        return nil
      }
      return BlockedContentCard(
        relationship: BlockRelationship(blockedPost: blocked),
        authorDid: blocked.author.did.didString(),
        postUri: blocked.uri,
        variant: .feed,
        path: $path
      )
    }
  }

  /// Renders the main post content
  fileprivate struct MainPostRow: View {
    let postBox: EquatableBox<AppBskyFeedDefs.FeedViewPost>
    let itemID: String
    @Binding var path: NavigationPath
    @Environment(AppState.self) private var appState

    var body: some View {
      makePostView()
        .environment(\.feedPostID, itemID)
        .id("\(itemID)-main-\(postBox.value.post.uri.uriString())")
        .contentShape(Rectangle())
        // Make sure all interactions pass through properly
        .allowsHitTesting(true)
        .onTapGesture {
          path.append(NavigationDestination.post(postBox.value.post.uri))
        }
    }

    private func makePostView() -> PostView {
      // A deleted or blocked parent is already shown above the post, so it adds no
      // "in reply to" line (and the reply was not necessarily to the current user).
      let (grandparentAuthor, _) = computeReplyContext()

      return PostView(
        post: postBox.value.post,
        grandparentAuthor: grandparentAuthor,
        isParentPost: false,
        isSelectable: false,
        path: $path,
        appState: appState,
        isToYou: false,
        hasVisibleThreadContext: postBox.value.reply != nil
      )
    }

    /// Computes the reply context: grandparent author and whether this is a reply to a deleted/blocked post
    private func computeReplyContext() -> (grandparentAuthor: AppBskyActorDefs.ProfileViewBasic?, isReplyWithMissingParent: Bool) {
      // If this is a repost with a parent reply that exists
      if case .appBskyFeedDefsReasonRepost = postBox.value.reason,
         case let .appBskyFeedDefsPostView(parentReply) = postBox.value.reply?.parent {
        return (parentReply.author, false)
      }

      // If this is a reply to a deleted or blocked post, show the indicator
      if let parent = postBox.value.reply?.parent {
        switch parent {
        case .appBskyFeedDefsNotFoundPost, .appBskyFeedDefsBlockedPost:
          return (nil, true)
        default:
          return (nil, false)
        }
      }

      return (nil, false)
    }
  }
}

// MARK: - FeedPost Environment Value
struct FeedPostIDKey: EnvironmentKey {
  static let defaultValue: String? = nil
}

extension EnvironmentValues {
  var feedPostID: String? {
    get { self[FeedPostIDKey.self] }
    set { self[FeedPostIDKey.self] = newValue }
  }
}

#Preview("FeedPost") {
  AsyncPreviewDataContent { appState in
    await PreviewData.firstPost(from: appState)
  } content: { _, feedViewPost in
    ScrollView {
      FeedPost(post: feedViewPost, path: .constant(NavigationPath()))
    }
  }
}
