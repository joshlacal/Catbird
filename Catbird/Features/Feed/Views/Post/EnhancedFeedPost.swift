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
///
/// Each section of the row is its own small view that holds the feed entry
/// through `EquatableBox`. When the sections were nested `@ViewBuilder`
/// functions, every level's opaque type contained the whole row (several
/// `PostView`s and inline Petrel models), Debug builds reserved a stack copy of
/// it per modifier step, and one reply row overflowed the device's 1 MB
/// main-thread stack.
struct EnhancedFeedPost: View {

  // MARK: - Types
  private enum Source {
    case cached(CachedFeedViewPost)
    case raw(EquatableBox<AppBskyFeedDefs.FeedViewPost>)
  }

  // MARK: - Properties
  let id: String
  @Binding var path: NavigationPath
  private let source: Source
  private let isReadOnly: Bool

  @Environment(\.feedInteractionTarget) private var inheritedInteractionTarget

  fileprivate static let baseUnit: CGFloat = 3

  // MARK: - Initializers
  init(cachedPost: CachedFeedViewPost, path: Binding<NavigationPath>, isReadOnly: Bool = false) {
    self.id = cachedPost.id
    self.source = .cached(cachedPost)
    self._path = path
    self.isReadOnly = isReadOnly
  }

  init(feedViewPost: AppBskyFeedDefs.FeedViewPost, path: Binding<NavigationPath>, isReadOnly: Bool = false) {
    self.id = feedViewPost.id
    self.source = .raw(EquatableBox(feedViewPost))
    self._path = path
    self.isReadOnly = isReadOnly
  }

  // MARK: - Computed Properties
  var feedViewPost: AppBskyFeedDefs.FeedViewPost? {
    entry?.value
  }

  /// The feed entry, boxed. Cached rows reuse the box their model keeps, so an
  /// unchanged row diffs by pointer.
  private var entry: EquatableBox<AppBskyFeedDefs.FeedViewPost>? {
    switch source {
    case .cached(let cachedPost):
      return try? cachedPost.feedViewPostBox
    case .raw(let box):
      return box
    }
  }

  private var threadDisplayMode: FeedThreadMode {
    guard case .cached(let cachedPost) = source,
          let mode = cachedPost.threadDisplayMode
    else { return .standard }

    switch mode {
    case "expanded":
      return .expanded
    case "collapsed":
      return .collapsed(hiddenCount: cachedPost.threadHiddenCount ?? 0)
    default:
      return .standard
    }
  }

  private var sliceItems: [FeedSliceItem]? {
    guard case .cached(let cachedPost) = source else { return nil }
    return cachedPost.sliceItems
  }

  // MARK: - Body
  var body: some View {
    if let entry {
      FeedEntryContent(
        entry: entry,
        id: id,
        threadMode: threadDisplayMode,
        sliceItems: sliceItems,
        isReadOnly: isReadOnly,
        path: $path
      )
      .environment(\.isReadOnlyPostPreview, isReadOnly)
      .environment(\.feedInteractionTarget, isReadOnly ? nil : inheritedInteractionTarget)
    }
  }
}

// MARK: - Thread Mode

private enum FeedThreadMode: Equatable {
  case standard
  case expanded
  case collapsed(hiddenCount: Int)
}

// MARK: - Row Content

/// The repost header, pinned badge and thread content, with the row's layout.
private struct FeedEntryContent: View {
  let entry: EquatableBox<AppBskyFeedDefs.FeedViewPost>
  let id: String
  let threadMode: FeedThreadMode
  let sliceItems: [FeedSliceItem]?
  let isReadOnly: Bool
  @Binding var path: NavigationPath

  @Environment(\.horizontalSizeClass) private var hSizeClass

  private static let baseUnit = EnhancedFeedPost.baseUnit

  private var contentMaxWidth: CGFloat {
    #if os(macOS)
    return 700
    #else
    return hSizeClass == .compact ? .infinity : 600
    #endif
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if isRepost {
        FeedRepostHeader(entry: entry, isReadOnly: isReadOnly, path: $path)
      }

      if showsPinnedBadge {
        pinnedPostBadge
          .frame(height: Self.baseUnit * 8)
          .padding(.horizontal, Self.baseUnit * 2)
          .padding(.bottom, Self.baseUnit * 2)
      }

      switch threadMode {
      case .standard:
        FeedStandardThread(entry: entry, isReadOnly: isReadOnly, path: $path)

      case .expanded:
        FeedExpandedThread(entry: entry, id: id, sliceItems: sliceItems, isReadOnly: isReadOnly, path: $path)

      case .collapsed(let hiddenCount):
        FeedCollapsedThread(
          entry: entry,
          id: id,
          sliceItems: sliceItems,
          hiddenCount: hiddenCount,
          isReadOnly: isReadOnly,
          path: $path
        )
      }
    }
    .padding(.top, Self.baseUnit * 3)
    .padding(.horizontal, Self.baseUnit * 1.5)
    .fixedSize(horizontal: false, vertical: true)
    .contentShape(Rectangle())
    .allowsHitTesting(true)
    .frame(maxWidth: contentMaxWidth, alignment: .center)
    .frame(maxWidth: .infinity, alignment: .center)
  }

  private var isRepost: Bool {
    if case .appBskyFeedDefsReasonRepost = entry.value.reason {
      return true
    }
    return false
  }

  private var showsPinnedBadge: Bool {
    if case .appBskyFeedDefsReasonPin = entry.value.reason {
      return true
    }

    return entry.value.post.viewer?.pinned == true
  }

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
    }
    .foregroundColor(.secondary)
    .padding(.leading, 3)
  }
}

/// "Reposted by" header for a reposted entry.
private struct FeedRepostHeader: View {
  let entry: EquatableBox<AppBskyFeedDefs.FeedViewPost>
  let isReadOnly: Bool
  @Binding var path: NavigationPath

  private static let baseUnit = EnhancedFeedPost.baseUnit

  var body: some View {
    if case .appBskyFeedDefsReasonRepost(let reasonRepost) = entry.value.reason {
      RepostHeaderView(reposter: reasonRepost.by, path: $path)
        .allowsHitTesting(!isReadOnly)
        .disabled(isReadOnly)
        .frame(height: Self.baseUnit * 8)
        .padding(.horizontal, Self.baseUnit * 2)
        .padding(.bottom, Self.baseUnit * 2)
    }
  }
}

// MARK: - Standard Thread Content

/// A single entry: its parent post (for a reply that is not a repost or pin)
/// above the post itself.
private struct FeedStandardThread: View {
  let entry: EquatableBox<AppBskyFeedDefs.FeedViewPost>
  let isReadOnly: Bool
  @Binding var path: NavigationPath

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if showsParent {
        FeedParentPostRow(entry: entry, isReadOnly: isReadOnly, path: $path)
          .padding(.bottom, EnhancedFeedPost.baseUnit * 2)
      }

      FeedMainPostRow(entry: entry, isReadOnly: isReadOnly, path: $path)
    }
  }

  private var showsParent: Bool {
    entry.value.reply != nil && entry.value.reason == nil
  }
}

/// The parent of a reply, or the placeholder for a missing or blocked parent.
private struct FeedParentPostRow: View {
  let entry: EquatableBox<AppBskyFeedDefs.FeedViewPost>
  let isReadOnly: Bool
  @Binding var path: NavigationPath

  @Environment(AppState.self) private var appState

  private static let baseUnit = EnhancedFeedPost.baseUnit

  var body: some View {
    if let parentPost = entry.value.reply?.parent {
      switch parentPost {
      case .appBskyFeedDefsPostView(let postView):
        PostView(
          post: postView,
          grandparentAuthor: entry.value.reply?.grandparentAuthor,
          isParentPost: true,
          isSelectable: false,
          path: $path,
          appState: appState
        )
        .environment(\.feedPostID, entry.value.id)
        .id("\(entry.value.id)-parent-\(postView.uri.uriString())")
        .contentShape(Rectangle())
        .onTapGesture {
          guard !isReadOnly else { return }
          path.append(NavigationDestination.post(postView.uri))
        }
      case .appBskyFeedDefsNotFoundPost(let notFound):
        PostNotFoundView(uri: notFound.uri, reason: .notFound, path: $path)
          .padding(.top, Self.baseUnit)
          .padding(.bottom, Self.baseUnit * 2)

      case .appBskyFeedDefsBlockedPost(let blocked):
        BlockedContentCard(
          relationship: BlockRelationship(blockedPost: blocked),
          authorDid: blocked.author.did.didString(),
          postUri: blocked.uri,
          variant: .feed,
          path: $path
        )
        .padding(.top, Self.baseUnit)

      case .unexpected:
        Text("Post unavailable")
          .appFont(AppTextRole.caption)
          .foregroundColor(.secondary)
          .padding(.vertical, Self.baseUnit * 2)
      }
    }
  }
}

/// The entry's own post.
private struct FeedMainPostRow: View {
  let entry: EquatableBox<AppBskyFeedDefs.FeedViewPost>
  let isReadOnly: Bool
  @Binding var path: NavigationPath

  @Environment(AppState.self) private var appState

  var body: some View {
    PostView(
      post: entry.value.post,
      grandparentAuthor: repostedParentAuthor,
      isParentPost: false,
      isSelectable: false,
      path: $path,
      appState: appState
    )
    .environment(\.feedPostID, entry.value.id)
    .id("\(entry.value.id)-main-\(entry.value.post.uri.uriString())")
    .contentShape(Rectangle())
    .allowsHitTesting(true)
    .onTapGesture {
      guard !isReadOnly else { return }
      path.append(NavigationDestination.post(entry.value.post.uri))
    }
  }

  /// A reposted reply shows no parent row, so its "in reply to" line names the
  /// parent's author instead.
  private var repostedParentAuthor: AppBskyActorDefs.ProfileViewBasic? {
    if case .appBskyFeedDefsReasonRepost = entry.value.reason,
       case let .appBskyFeedDefsPostView(parentPost) = entry.value.reply?.parent {
      return parentPost.author
    }
    return nil
  }
}

// MARK: - Expanded Thread Content

/// Every post of a consolidated thread slice, top to bottom.
private struct FeedExpandedThread: View {
  let entry: EquatableBox<AppBskyFeedDefs.FeedViewPost>
  let id: String
  let sliceItems: [FeedSliceItem]?
  let isReadOnly: Bool
  @Binding var path: NavigationPath

  @Environment(AppState.self) private var appState

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let sliceItems, !sliceItems.isEmpty {
        ForEach(Array(sliceItems.enumerated()), id: \.element.id) { index, item in
          let isLast = index == sliceItems.count - 1
          let postURI = item.post.uri

          PostView(
            post: item.post,
            grandparentAuthor: nil,
            isParentPost: !isLast,
            isSelectable: false,
            path: $path,
            appState: appState,
            hasVisibleThreadContext: true
          )
          .environment(\.feedPostID, id)
          .contentShape(Rectangle())
          .onTapGesture {
            guard !isReadOnly else { return }
            path.append(NavigationDestination.post(postURI))
          }

          if !isLast {
            Spacer()
              .frame(height: EnhancedFeedPost.baseUnit * 2)
          }
        }
      } else {
        FeedStandardThread(entry: entry, isReadOnly: isReadOnly, path: $path)
      }
    }
  }
}

// MARK: - Collapsed Thread Content

/// A long thread slice: its root, a separator for the hidden middle, and its
/// last two posts.
private struct FeedCollapsedThread: View {
  let entry: EquatableBox<AppBskyFeedDefs.FeedViewPost>
  let id: String
  let sliceItems: [FeedSliceItem]?
  let hiddenCount: Int
  let isReadOnly: Bool
  @Binding var path: NavigationPath

  @Environment(AppState.self) private var appState

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let sliceItems, sliceItems.count >= 3 {
        let rootItem = sliceItems[0]
        let rootURI = rootItem.post.uri
        PostView(
          post: rootItem.post,
          grandparentAuthor: nil,
          isParentPost: true,
          isSelectable: false,
          path: $path,
          appState: appState,
          hasVisibleThreadContext: true
        )
        .environment(\.feedPostID, id)
        .contentShape(Rectangle())
        .onTapGesture {
          guard !isReadOnly else { return }
          path.append(NavigationDestination.post(rootURI))
        }

        ThreadSeparatorView(hiddenPostCount: hiddenCount) {
          guard !isReadOnly else { return }
          if case let .appBskyFeedDefsPostView(parentReply)? = entry.value.reply?.root {
            path.append(NavigationDestination.post(parentReply.uri))
          }
        }

        let lastTwoItems = Array(sliceItems.suffix(2))
        ForEach(Array(lastTwoItems.enumerated()), id: \.element.id) { index, item in
          let isLast = index == lastTwoItems.count - 1
          let postURI = item.post.uri

          PostView(
            post: item.post,
            grandparentAuthor: isLast ? nil : item.parentAuthor,
            isParentPost: !isLast,
            isSelectable: false,
            path: $path,
            appState: appState,
            hasVisibleThreadContext: true
          )
          .environment(\.feedPostID, id)
          .contentShape(Rectangle())
          .onTapGesture {
            guard !isReadOnly else { return }
            path.append(NavigationDestination.post(postURI))
          }

          if !isLast {
            Spacer()
              .frame(height: EnhancedFeedPost.baseUnit * 2)
          }
        }
      } else {
        FeedStandardThread(entry: entry, isReadOnly: isReadOnly, path: $path)
      }
    }
  }
}
