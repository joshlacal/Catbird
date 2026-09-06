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
  let prepareBlockConfirmation: @MainActor () async -> Void

  var body: some View {
    ZStack {
      ScrollView {
        VStack(spacing: 0) {
          ProfileBannerHeader(
            bannerURL: profile.banner.flatMap { URL(string: $0.uriString()) }
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
            prepareBlockConfirmation: prepareBlockConfirmation
          )
        }
        .frame(maxWidth: .infinity, alignment: .center)
      }
      .flexibleHeaderScrollView()
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
}

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
  let prepareBlockConfirmation: @MainActor () async -> Void

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
        prepareBlockConfirmation: prepareBlockConfirmation
      )
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .frame(maxWidth: contentMaxWidth, alignment: .center)
      .frame(maxWidth: .infinity, alignment: .center)

      if !viewModel.isCurrentUser && !viewModel.knownFollowers.isEmpty {
        FollowedByView(
          knownFollowers: viewModel.knownFollowers,
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

      Spacer(minLength: 200)
    }
  }
}

private struct ProfileBlockRelationshipView: View {
  let viewer: AppBskyActorDefs.ViewerState?
  @Binding var navigationPath: NavigationPath
  let prepareBlockConfirmation: @MainActor () async -> Void

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
              Task { await prepareBlockConfirmation() }
            }
            .appFont(AppTextRole.callout)
          }
          if let listRef = relationship.listRef {
            Button("View list") {
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
        ProgressView("Loading labeler information...")
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
        posts: viewModel.replies,
        emptyMessage: "No replies",
        hasAttemptedLoad: hasAttemptedLoadReplies,
        loadAction: viewModel.loadReplies,
        contentMaxWidth: contentMaxWidth,
        navigationPath: $navigationPath
      )
    case .media:
      ProfileFeedTabView(
        viewModel: viewModel,
        posts: viewModel.postsWithMedia,
        emptyMessage: "No media posts",
        hasAttemptedLoad: hasAttemptedLoadMedia,
        loadAction: viewModel.loadMediaPosts,
        contentMaxWidth: contentMaxWidth,
        navigationPath: $navigationPath
      )
    case .more:
      MoreView(path: $navigationPath)
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
      if !hasAttemptedLoad || (viewModel.isLoading && viewModel.posts.isEmpty) {
        ProgressView("Loading...")
          .frame(maxWidth: .infinity, minHeight: 100)
          .padding()
          .frame(maxWidth: contentMaxWidth, alignment: .center)
          .frame(maxWidth: .infinity, alignment: .center)
      } else if viewModel.posts.isEmpty && viewModel.pinnedPost == nil {
        ProfileEmptyStateView(
          title: "No Content",
          message: "No posts",
          isCurrentUser: viewModel.isCurrentUser
        )
        .padding(.top, 40)
        .frame(maxWidth: contentMaxWidth, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
      } else {
        if let pinnedPost = viewModel.pinnedPost {
          VStack(spacing: 0) {
            EnhancedFeedPost(
              feedViewPost: pinnedPost,
              path: $navigationPath
            )
            .frame(maxWidth: contentMaxWidth, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .center)

            Divider()
              .padding(.top, 8)
          }
        }

        ProfileCachedPostsList(
          feedKey: viewModel.profileFeedKey(for: .posts),
          contentMaxWidth: contentMaxWidth,
          isLoadingMore: viewModel.isLoadingMorePosts,
          loadMore: viewModel.loadPosts,
          path: $navigationPath
        )
      }
    }
  }
}

private struct ProfileFeedTabView: View {
  let viewModel: ProfileViewModel
  let posts: [AppBskyFeedDefs.FeedViewPost]
  let emptyMessage: String
  let hasAttemptedLoad: Bool
  let loadAction: @MainActor () async -> Void
  let contentMaxWidth: CGFloat
  @Binding var navigationPath: NavigationPath

  var body: some View {
    LazyVStack(spacing: 0) {
      if !hasAttemptedLoad || (viewModel.isLoading && posts.isEmpty) {
        ProgressView("Loading...")
          .frame(maxWidth: .infinity, minHeight: 100)
          .padding()
          .frame(maxWidth: contentMaxWidth, alignment: .center)
          .frame(maxWidth: .infinity, alignment: .center)
      } else if posts.isEmpty {
        ProfileEmptyStateView(
          title: "No Content",
          message: emptyMessage,
          isCurrentUser: viewModel.isCurrentUser
        )
        .padding(.top, 40)
        .frame(maxWidth: contentMaxWidth, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
      } else {
        ProfileCachedPostsList(
          feedKey: viewModel.profileFeedKey(for: viewModel.selectedProfileTab),
          contentMaxWidth: contentMaxWidth,
          isLoadingMore: viewModel.isLoadingMorePosts,
          loadMore: loadAction,
          path: $navigationPath
        )
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
