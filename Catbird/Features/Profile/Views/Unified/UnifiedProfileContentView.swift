import AppIntents
import Petrel
import SwiftUI

struct UnifiedProfileContentView: View {
  let profile: AppBskyActorDefs.ProfileViewDetailed
  let viewModel: ProfileViewModel
  let appState: AppState
  let contentMaxWidth: CGFloat
  let hasAttemptedLoadPosts: Bool
  let hasAttemptedLoadReplies: Bool
  let hasAttemptedLoadMedia: Bool
  @Binding var isEditingProfile: Bool
  @Binding var navigationPath: NavigationPath
  let refreshAllContent: @MainActor () async -> Void
  let onTabChange: @MainActor (ProfileTab) -> Void
  let requestUnblock: @MainActor () -> Void
  /// Reports whether the banner has scrolled fully out of view, taking the header name under the bar.
  var onHeaderScrolledPastChange: @MainActor (Bool) -> Void = { _ in }
  var scrollToTopRequestID: Int = 0

  private static let bannerHeight: CGFloat = 200

  #if os(iOS)
  @State private var headerGeometry = FlexibleHeaderGeometry()
  #endif

  var body: some View {
    #if os(iOS)
    iosBody
    #else
    macOSBody
    #endif
  }

  // MARK: - iOS Implementation (PostListCollectionView Stack)

  #if os(iOS)
  private var iosBody: some View {
    ZStack {
      PostListCollectionView(
        boxedPosts: currentBoxedPosts,
        headerView: AnyView(profileHeaderView),
        pinnedHeaderView: AnyView(profileTabPicker),
        // Labeler info, More, and the loading and empty states. Each shows only while the
        // tab has no rows, so it sits under the picker in the rows' place.
        emptyView: AnyView(VStack(spacing: 0) { tabContent }),
        hasMore: currentHasMore,
        isLoadingMore: currentIsLoadingMore,
        footerState: currentFooterState,
        onLoadMore: currentLoadMoreAction,
        onRefresh: { await refreshAllContent() },
        onScrollOffsetChanged: { normalizedOffset in
          headerGeometry.offset = min(normalizedOffset, 0)
          onHeaderScrolledPastChange(normalizedOffset > Self.bannerHeight)
        },
        scrollsToTop: true,
        scrollPositionKey: currentScrollPositionKey,
        scrollPositionScope: scrollPositionScope,
        scrollToTopRequestID: scrollToTopRequestID,
        appState: appState,
        accessibilityIdentifier: "profile.posts"
      ) { boxedPost in
        postRowView(boxedPost: boxedPost)
      }
      .extendingUnderTopBar()
      .environment(\.moderationListFilterExemptDID, profile.did.didString())
      .ignoresSafeArea(edges: .top)
      .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
    }
    // Loads a tab when it is chosen. Not from the picker's own onChange: the picker lives in a
    // collection view supplementary view, and a tab switch can remove that view for a moment.
    .onChange(of: viewModel.selectedProfileTab) { _, tab in
      if tab != .more { onTabChange(tab) }
    }
    .entityContext(
      EntityIdentifier(
        for: ProfileEntity.self,
        identifier: profile.did.didString()
      )
    )
  }

  private var currentScrollPositionKey: String {
    "\(scrollPositionScope):\(viewModel.selectedProfileTab.rawValue)"
  }

  /// This account's view of this profile: its tabs share the pinned picker's position.
  private var scrollPositionScope: String {
    "\(appState.userDID):\(profile.did.didString())"
  }

  private var currentBoxedPosts: [EquatableBox<AppBskyFeedDefs.FeedViewPost>] {
    switch viewModel.selectedProfileTab {
    case .posts:
      if !hasAttemptedLoadPosts || (viewModel.isLoading && viewModel.boxedPosts.isEmpty) {
        return []
      }
      var posts = viewModel.boxedPosts
      if let pinned = viewModel.pinnedPost {
        // The view model boxes the pin once, so the list compares this row by pointer.
        posts.insert(pinned, at: 0)
      }
      return posts
    case .replies:
      if !hasAttemptedLoadReplies || (viewModel.isLoading && viewModel.boxedReplies.isEmpty) {
        return []
      }
      return viewModel.boxedReplies
    case .media:
      if !hasAttemptedLoadMedia || (viewModel.isLoading && viewModel.boxedPostsWithMedia.isEmpty) {
        return []
      }
      return viewModel.boxedPostsWithMedia
    case .labelerInfo, .more:
      return []
    default:
      return []
    }
  }

  private var currentHasMore: Bool {
    switch viewModel.selectedProfileTab {
    case .posts: viewModel.hasMorePosts
    case .replies: viewModel.hasMoreReplies
    case .media: viewModel.hasMoreMedia
    default: false
    }
  }

  private var currentIsLoadingMore: Bool {
    switch viewModel.selectedProfileTab {
    case .posts, .replies, .media: viewModel.isLoadingMorePosts
    default: false
    }
  }

  private var currentFooterState: PostListFooterState {
    ProfilePostsTabLoading.footerState(
      hasMore: currentHasMore, isLoadingMore: currentIsLoadingMore, listIsEmpty: currentListIsEmpty
    )
  }

  /// Whether the open tab has no rows yet. Checked without building `currentBoxedPosts`,
  /// which copies the array.
  private var currentListIsEmpty: Bool {
    switch viewModel.selectedProfileTab {
    case .posts: viewModel.boxedPosts.isEmpty && viewModel.pinnedPost == nil
    case .replies: viewModel.boxedReplies.isEmpty
    case .media: viewModel.boxedPostsWithMedia.isEmpty
    default: true
    }
  }

  private var currentLoadMoreAction: (@MainActor () async -> Void)? {
    switch viewModel.selectedProfileTab {
    case .posts: { await viewModel.loadMorePosts() }
    case .replies: { await viewModel.loadMoreReplies() }
    case .media: { await viewModel.loadMoreMediaPosts() }
    default: nil
    }
  }

  @ViewBuilder
  private var profileHeaderView: some View {
    VStack(spacing: 0) {
      ProfileBannerHeader(
        bannerURL: profile.banner.flatMap { URL(string: $0.uriString()) },
        did: profile.did.didString(),
        labels: profile.labels
      )
      .frame(maxWidth: contentMaxWidth, alignment: .center)
      .frame(maxWidth: .infinity, alignment: .center)

      ProfileHeader(
        profile: profile,
        viewModel: viewModel,
        appState: appState,
        isEditingProfile: $isEditingProfile,
        path: $navigationPath,
        screenWidth: contentMaxWidth,
        hideAvatar: false
      )
      .padding(.horizontal, 16)
      .frame(maxWidth: contentMaxWidth, alignment: .center)
      .frame(maxWidth: .infinity, alignment: .center)

      ProfileBlockRelationshipView(
        viewer: profile.viewer,
        navigationPath: $navigationPath,
        requestUnblock: requestUnblock
      )
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .frame(maxWidth: contentMaxWidth, alignment: .center)
      .frame(maxWidth: .infinity, alignment: .center)

      if !viewModel.isCurrentUser && !viewModel.knownFollowers.isEmpty {
        FollowedByView(
          knownFollowers: viewModel.knownFollowers,
          knownFollowersTotal: max(profile.viewer?.knownFollowers?.count ?? 0, viewModel.knownFollowers.count),
          totalFollowersCount: profile.followersCount ?? 0,
          profileDID: profile.did.didString(),
          path: $navigationPath
        )
        .padding(.horizontal, 16)
        .frame(maxWidth: contentMaxWidth, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
      }
    }
    .frame(maxWidth: .infinity, alignment: .center)
    .environment(headerGeometry)
  }

  /// Under the profile information, and pinned below the navigation bar once scrolled up to it.
  @ViewBuilder
  private var profileTabPicker: some View {
    @Bindable var viewModel = viewModel

    // Tabs load from `iosBody`'s onChange, not from the picker.
    ProfileTabSelector(
      path: $navigationPath,
      selectedTab: $viewModel.selectedProfileTab,
      isLabeler: viewModel.isLabeler
    )
    .profileTabPickerTrackBacking(appState)
    .padding(.top, 12)
    .padding(.bottom, 8)
    .padding(.horizontal, 16)
    .frame(maxWidth: contentMaxWidth, alignment: .center)
    .frame(maxWidth: .infinity, alignment: .center)
  }

  @ViewBuilder
  private var tabContent: some View {
    switch viewModel.selectedProfileTab {
    case .labelerInfo:
      if let labelerDetails = viewModel.labelerDetails {
        LabelerInfoTab(labelerDetails: labelerDetails)
          .frame(maxWidth: contentMaxWidth, alignment: .center)
          .frame(maxWidth: .infinity, alignment: .center)
      } else {
        ProgressView("Loading…")
          .frame(maxWidth: .infinity, minHeight: 100)
          .padding()
      }
    case .more:
      MoreView(viewModel: viewModel, path: $navigationPath)
        .frame(maxWidth: contentMaxWidth, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
    case .posts:
      if ProfilePostsTabLoading.showsSpinner(
        hasAttempted: hasAttemptedLoadPosts, isLoading: viewModel.isLoading,
        isLoadingMore: viewModel.isLoadingMorePosts, postsEmpty: viewModel.boxedPosts.isEmpty,
        hasPinned: viewModel.pinnedPost != nil
      ) {
        ProgressView("Loading…")
          .frame(maxWidth: .infinity, minHeight: 100)
          .padding()
          .frame(maxWidth: contentMaxWidth, alignment: .center)
          .frame(maxWidth: .infinity, alignment: .center)
      } else if viewModel.boxedPosts.isEmpty && viewModel.pinnedPost == nil {
        ProfileEmptyStateView(
          title: "No Posts",
          message: "This account hasn’t posted yet.",
          isCurrentUser: viewModel.isCurrentUser
        )
        .padding(.top, 40)
        .frame(maxWidth: contentMaxWidth, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
      }
    case .replies:
      if !hasAttemptedLoadReplies || (viewModel.isLoading && viewModel.boxedReplies.isEmpty) {
        ProgressView("Loading…")
          .frame(maxWidth: .infinity, minHeight: 100)
          .padding()
          .frame(maxWidth: contentMaxWidth, alignment: .center)
          .frame(maxWidth: .infinity, alignment: .center)
      } else if viewModel.boxedReplies.isEmpty && viewModel.hasMoreReplies {
        VStack(spacing: 12) {
          if viewModel.isLoadingMorePosts {
            ProgressView()
          } else {
            Text("No recent posts here yet.")
              .appFont(AppTextRole.subheadline)
              .foregroundStyle(.secondary)
            Button("Load More") {
              Task { await viewModel.loadMoreReplies() }
            }
            .buttonStyle(.bordered)
          }
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(.top, 24)
        .frame(maxWidth: contentMaxWidth, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
      } else if viewModel.boxedReplies.isEmpty {
        ProfileEmptyStateView(
          title: "No Replies",
          message: "This account hasn’t replied to anyone yet.",
          isCurrentUser: viewModel.isCurrentUser
        )
        .padding(.top, 40)
        .frame(maxWidth: contentMaxWidth, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
      }
    case .media:
      if !hasAttemptedLoadMedia || (viewModel.isLoading && viewModel.boxedPostsWithMedia.isEmpty) {
        ProgressView("Loading…")
          .frame(maxWidth: .infinity, minHeight: 100)
          .padding()
          .frame(maxWidth: contentMaxWidth, alignment: .center)
          .frame(maxWidth: .infinity, alignment: .center)
      } else if viewModel.boxedPostsWithMedia.isEmpty && viewModel.hasMoreMedia {
        VStack(spacing: 12) {
          if viewModel.isLoadingMorePosts {
            ProgressView()
          } else {
            Text("No recent posts here yet.")
              .appFont(AppTextRole.subheadline)
              .foregroundStyle(.secondary)
            Button("Load More") {
              Task { await viewModel.loadMoreMediaPosts() }
            }
            .buttonStyle(.bordered)
          }
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(.top, 24)
        .frame(maxWidth: contentMaxWidth, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
      } else if viewModel.boxedPostsWithMedia.isEmpty {
        ProfileEmptyStateView(
          title: "No Media Posts",
          message: "This account hasn’t shared photos or videos yet.",
          isCurrentUser: viewModel.isCurrentUser
        )
        .padding(.top, 40)
        .frame(maxWidth: contentMaxWidth, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
      }
    default:
      EmptyView()
    }
  }

  @ViewBuilder
  private func postRowView(boxedPost: EquatableBox<AppBskyFeedDefs.FeedViewPost>) -> some View {
    VStack(spacing: 0) {
      EnhancedFeedPost(
        boxedPost: boxedPost,
        id: boxedPost.value.id,
        path: $navigationPath
      )
      // The widest the content gets, not `contentMaxWidth`: the list keeps a row as built until
      // its post changes, and `contentMaxWidth` follows a GeometryReader that mid-rotation briefly
      // measures a narrower screen. In a cell, which is never wider than that screen, this cap
      // comes to the same width, and is right whenever the row was built.
      .frame(maxWidth: UnifiedProfileView.maxResponsiveContentWidth, alignment: .center)
      .frame(maxWidth: .infinity, alignment: .center)

      Divider()
        .padding(.top, 8)
    }
    // Ends ProfileOpen at the first row, the pinned post included (it is row 0).
    .onAppear { viewModel.markFirstPostVisible() }
  }
  #endif

  // MARK: - macOS Implementation

  #if os(macOS)
  private var macOSBody: some View {
    ZStack {
      ScrollView {
        VStack(spacing: 0) {
          ProfileBannerHeader(
            bannerURL: profile.banner.flatMap { URL(string: $0.uriString()) },
            did: profile.did.didString(),
            labels: profile.labels
          )
          .frame(maxWidth: contentMaxWidth, alignment: .center)
          .frame(maxWidth: .infinity, alignment: .center)

          UnifiedProfileDetailsView(
            profile: profile,
            viewModel: viewModel,
            appState: appState,
            contentMaxWidth: contentMaxWidth,
            hasAttemptedLoadPosts: hasAttemptedLoadPosts,
            hasAttemptedLoadReplies: hasAttemptedLoadReplies,
            hasAttemptedLoadMedia: hasAttemptedLoadMedia,
            isEditingProfile: $isEditingProfile,
            navigationPath: $navigationPath,
            onTabChange: onTabChange,
            requestUnblock: requestUnblock
          )
        }
        .frame(maxWidth: .infinity, alignment: .center)
      }
      .flexibleHeaderScrollView()
      .onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.contentOffset.y + geometry.contentInsets.top > Self.bannerHeight
      } action: { _, isPast in
        onHeaderScrolledPastChange(isPast)
      }
      .refreshable { await refreshAllContent() }
      .ignoresSafeArea(edges: .top)
      .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
    }
    .entityContext(
      EntityIdentifier(
        for: ProfileEntity.self,
        identifier: profile.did.didString()
      )
    )
  }
  #endif
}

#if os(iOS)
private extension View {
  /// The tab picker's track is translucent. Pinned, rows scroll behind it, and the soft scroll
  /// edge blur fades out across it, so their text would read through its labels. This backs the
  /// track (a capsule from iOS 26) with the list's own background, which it sits on at rest
  /// anyway. Earlier systems put a bar material behind the whole pinned header instead.
  @ViewBuilder
  func profileTabPickerTrackBacking(_ appState: AppState) -> some View {
    if #available(iOS 26.0, *) {
      background {
        Color.clear
          .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
          .clipShape(Capsule())
      }
    } else {
      self
    }
  }
}
#endif

private struct ProfileBlockRelationshipView: View {
  let viewer: AppBskyActorDefs.ViewerState?
  @Binding var navigationPath: NavigationPath
  let requestUnblock: @MainActor () -> Void

  var body: some View {
    let relationship = BlockRelationship(viewer: viewer)
    if relationship.direction != .unknown {
      VStack(alignment: .leading, spacing: 6) {
        Text(relationship.statusText)
          .appFont(AppTextRole.subheadline)
          .fontWeight(.medium)
        HStack(spacing: 16) {
          if relationship.canUnblockDirectly {
            Button("Unblock") {
              requestUnblock()
            }
            .appFont(AppTextRole.callout)
          }
          if let listRef = relationship.listRef {
            Button("View List") {
              navigationPath.append(NavigationDestination.list(listRef.uri))
            }
            .appFont(AppTextRole.callout)
          }
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.systemGroupedBackground)
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .accessibilityElement(children: .contain)
    }
  }
}

#if os(macOS)
private struct UnifiedProfileDetailsView: View {
  let profile: AppBskyActorDefs.ProfileViewDetailed
  let viewModel: ProfileViewModel
  let appState: AppState
  let contentMaxWidth: CGFloat
  let hasAttemptedLoadPosts: Bool
  let hasAttemptedLoadReplies: Bool
  let hasAttemptedLoadMedia: Bool
  @Binding var isEditingProfile: Bool
  @Binding var navigationPath: NavigationPath
  let onTabChange: @MainActor (ProfileTab) -> Void
  let requestUnblock: @MainActor () -> Void

  var body: some View {
    @Bindable var viewModel = viewModel

    VStack(spacing: 0) {
      ProfileHeader(
        profile: profile,
        viewModel: viewModel,
        appState: appState,
        isEditingProfile: $isEditingProfile,
        path: $navigationPath,
        screenWidth: contentMaxWidth,
        hideAvatar: false
      )
      .padding(.horizontal, 16)
      .frame(maxWidth: contentMaxWidth, alignment: .center)
      .frame(maxWidth: .infinity, alignment: .center)

      ProfileBlockRelationshipView(
        viewer: profile.viewer,
        navigationPath: $navigationPath,
        requestUnblock: requestUnblock
      )
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .frame(maxWidth: contentMaxWidth, alignment: .center)
      .frame(maxWidth: .infinity, alignment: .center)

      if !viewModel.isCurrentUser && !viewModel.knownFollowers.isEmpty {
        FollowedByView(
          knownFollowers: viewModel.knownFollowers,
          knownFollowersTotal: max(profile.viewer?.knownFollowers?.count ?? 0, viewModel.knownFollowers.count),
          totalFollowersCount: profile.followersCount ?? 0,
          profileDID: profile.did.didString(),
          path: $navigationPath
        )
        .padding(.horizontal, 16)
        .frame(maxWidth: contentMaxWidth, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
      }

      ProfileTabSelector(
        path: $navigationPath,
        selectedTab: $viewModel.selectedProfileTab,
        onTabChange: onTabChange,
        isLabeler: viewModel.isLabeler
      )
      .padding(.top, 12)
      .padding(.horizontal, 16)
      .frame(maxWidth: contentMaxWidth, alignment: .center)
      .frame(maxWidth: .infinity, alignment: .center)

      ProfileCurrentTabView(
        viewModel: viewModel,
        contentMaxWidth: contentMaxWidth,
        hasAttemptedLoadPosts: hasAttemptedLoadPosts,
        hasAttemptedLoadReplies: hasAttemptedLoadReplies,
        hasAttemptedLoadMedia: hasAttemptedLoadMedia,
        navigationPath: $navigationPath
      )
      .environment(\.moderationListFilterExemptDID, profile.did.didString())

      Spacer(minLength: 200)
    }
  }
}

private struct ProfileCurrentTabView: View {
  let viewModel: ProfileViewModel
  let contentMaxWidth: CGFloat
  let hasAttemptedLoadPosts: Bool
  let hasAttemptedLoadReplies: Bool
  let hasAttemptedLoadMedia: Bool
  @Binding var navigationPath: NavigationPath

  var body: some View {
    switch viewModel.selectedProfileTab {
    case .labelerInfo:
      if let labelerDetails = viewModel.labelerDetails {
        LabelerInfoTab(labelerDetails: labelerDetails)
          .frame(maxWidth: contentMaxWidth, alignment: .center)
          .frame(maxWidth: .infinity, alignment: .center)
      } else {
        ProgressView("Loading…")
          .frame(maxWidth: .infinity, minHeight: 100)
          .padding()
      }
    case .posts:
      ProfilePostsTabView(
        viewModel: viewModel,
        contentMaxWidth: contentMaxWidth,
        hasAttemptedLoad: hasAttemptedLoadPosts,
        navigationPath: $navigationPath
      )
    case .replies:
      ProfileFeedTabView(
        viewModel: viewModel,
        posts: viewModel.boxedReplies,
        emptyTitle: "No Replies",
        emptyMessage: "This account hasn’t replied to anyone yet.",
        hasAttemptedLoad: hasAttemptedLoadReplies,
        hasMore: viewModel.hasMoreReplies,
        loadAction: viewModel.loadMoreReplies,
        contentMaxWidth: contentMaxWidth,
        navigationPath: $navigationPath
      )
    case .media:
      ProfileFeedTabView(
        viewModel: viewModel,
        posts: viewModel.boxedPostsWithMedia,
        emptyTitle: "No Media Posts",
        emptyMessage: "This account hasn’t shared photos or videos yet.",
        hasAttemptedLoad: hasAttemptedLoadMedia,
        hasMore: viewModel.hasMoreMedia,
        loadAction: viewModel.loadMoreMediaPosts,
        contentMaxWidth: contentMaxWidth,
        navigationPath: $navigationPath
      )
    case .more:
      MoreView(viewModel: viewModel, path: $navigationPath)
    default:
      EmptyView()
    }
  }
}

private struct ProfilePostsTabView: View {
  let viewModel: ProfileViewModel
  let contentMaxWidth: CGFloat
  let hasAttemptedLoad: Bool
  @Binding var navigationPath: NavigationPath

  var body: some View {
    LazyVStack(spacing: 0) {
      if ProfilePostsTabLoading.showsSpinner(
        hasAttempted: hasAttemptedLoad, isLoading: viewModel.isLoading,
        isLoadingMore: viewModel.isLoadingMorePosts, postsEmpty: viewModel.boxedPosts.isEmpty,
        hasPinned: viewModel.pinnedPost != nil
      ) {
        ProgressView("Loading…")
          .frame(maxWidth: .infinity, minHeight: 100)
          .padding()
          .frame(maxWidth: contentMaxWidth, alignment: .center)
          .frame(maxWidth: .infinity, alignment: .center)
      } else if viewModel.boxedPosts.isEmpty && viewModel.pinnedPost == nil {
        ProfileEmptyStateView(
          title: "No Posts",
          message: "This account hasn’t posted yet.",
          isCurrentUser: viewModel.isCurrentUser
        )
        .padding(.top, 40)
        .frame(maxWidth: contentMaxWidth, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
      } else {
        if let pinnedPost = viewModel.pinnedPost {
          VStack(spacing: 0) {
            EnhancedFeedPost(
              boxedPost: pinnedPost,
              path: $navigationPath
            )
            .frame(maxWidth: contentMaxWidth, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .center)

            Divider()
              .padding(.top, 8)
          }
          .onAppear { viewModel.markFirstPostVisible() }
        }

        ProfileBoxedPostsList(
          posts: viewModel.boxedPosts,
          contentMaxWidth: contentMaxWidth,
          isLoadingMore: viewModel.isLoadingMorePosts,
          hasMore: viewModel.hasMorePosts,
          loadMore: viewModel.loadMorePosts,
          path: $navigationPath,
          onRowAppear: viewModel.markFirstPostVisible
        )
      }
    }
  }
}

private struct ProfileFeedTabView: View {
  let viewModel: ProfileViewModel
  let posts: [EquatableBox<AppBskyFeedDefs.FeedViewPost>]
  let emptyTitle: String
  let emptyMessage: String
  let hasAttemptedLoad: Bool
  let hasMore: Bool
  let loadAction: @MainActor () async -> Void
  let contentMaxWidth: CGFloat
  @Binding var navigationPath: NavigationPath

  var body: some View {
    LazyVStack(spacing: 0) {
      if !hasAttemptedLoad || (viewModel.isLoading && posts.isEmpty) {
        ProgressView("Loading…")
          .frame(maxWidth: .infinity, minHeight: 100)
          .padding()
          .frame(maxWidth: contentMaxWidth, alignment: .center)
          .frame(maxWidth: .infinity, alignment: .center)
      } else if posts.isEmpty && hasMore {
        VStack(spacing: 12) {
          if viewModel.isLoadingMorePosts {
            ProgressView()
          } else {
            Text("No recent posts here yet.")
              .appFont(AppTextRole.subheadline)
              .foregroundStyle(.secondary)
            Button("Load More") {
              Task { await loadAction() }
            }
            .buttonStyle(.bordered)
          }
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(.top, 24)
        .frame(maxWidth: contentMaxWidth, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
      } else if posts.isEmpty {
        ProfileEmptyStateView(
          title: emptyTitle,
          message: emptyMessage,
          isCurrentUser: viewModel.isCurrentUser
        )
        .padding(.top, 40)
        .frame(maxWidth: contentMaxWidth, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
      } else {
        ProfileBoxedPostsList(
          posts: posts,
          contentMaxWidth: contentMaxWidth,
          isLoadingMore: viewModel.isLoadingMorePosts,
          hasMore: hasMore,
          loadMore: loadAction,
          path: $navigationPath,
          onRowAppear: viewModel.markFirstPostVisible
        )
      }
    }
  }
}
#endif

struct ProfileBoxedPostsList: View {
  let posts: [EquatableBox<AppBskyFeedDefs.FeedViewPost>]
  let contentMaxWidth: CGFloat
  let isLoadingMore: Bool
  let hasMore: Bool
  let loadMore: @MainActor () async -> Void
  @Binding var path: NavigationPath
  /// Called as each row appears; the macOS profile ends its ProfileOpen signpost on the first.
  var onRowAppear: @MainActor () -> Void = {}

  var body: some View {
    let lastPostID = posts.last?.value.id
    Group {
      ForEach(posts, id: \.value.id) { boxedPost in
        VStack(spacing: 0) {
          EnhancedFeedPost(
            boxedPost: boxedPost,
            id: boxedPost.value.id,
            path: $path
          )
          .frame(maxWidth: contentMaxWidth, alignment: .center)
          .frame(maxWidth: .infinity, alignment: .center)

          Divider()
            .padding(.top, 8)
        }
        .contentShape(Rectangle())
        .onAppear {
          onRowAppear()
          if hasMore && boxedPost.value.id == lastPostID && !isLoadingMore {
            Task { await loadMore() }
          }
        }
      }

      if isLoadingMore && hasMore {
        ProgressView()
          .padding()
          .frame(maxWidth: contentMaxWidth, alignment: .center)
          .frame(maxWidth: .infinity, alignment: .center)
      }
    }
  }
}

struct ProfileEmptyStateView: View {
  let title: String
  let message: String
  let isCurrentUser: Bool

  var body: some View {
    VStack(spacing: 20) {
      Spacer()

      Image(systemName: icon)
        .appFont(size: 56)
        .foregroundStyle(.secondary.opacity(0.6))
        .symbolEffect(.pulse)

      VStack(spacing: 8) {
        Text(title)
          .appFont(AppTextRole.title2)
          .fontWeight(.semibold)
          .foregroundStyle(.primary)

        Text(displayMessage)
          .appFont(AppTextRole.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 32)
      }

      Spacer()
    }
    .frame(maxWidth: .infinity, minHeight: 280)
    .background(Color.clear)
  }

  private var icon: String {
    switch title.lowercased() {
    case "no posts": "text.bubble"
    case "no replies": "arrowshape.turn.up.left"
    case "no media posts": "photo.on.rectangle"
    case "no likes": "heart"
    case "no lists": "list.bullet.rectangle"
    case "no feeds": "rectangle.grid.1x2"
    default: "square.stack.3d.up.slash"
    }
  }

  private var displayMessage: String {
    guard isCurrentUser else { return message }
    return switch title.lowercased() {
    case "no posts": "Share your thoughts! Your posts will appear here."
    case "no replies": "Join conversations by replying to posts."
    case "no media posts": "Share photos and videos to see them here."
    case "no likes": "Like posts to save them for later."
    default: message
    }
  }
}
