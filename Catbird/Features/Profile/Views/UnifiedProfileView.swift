import Foundation
import NukeUI
import OSLog
import Observation
import Petrel
import SwiftUI
#if os(iOS)
import LazyPager
#endif
import Nuke
import TipKit
import SwiftData

/// A unified profile view that handles both current user and other user profiles using SwiftUI
struct UnifiedProfileView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var currentColorScheme
  @Environment(\.horizontalSizeClass) private var hSizeClass
  @State private var viewModel: ProfileViewModel
  @Binding var selectedTab: Int
  @Binding var lastTappedTab: Int?
  @Binding private var navigationPath: NavigationPath
  @State private var isShowingReportSheet = false
  @State private var isEditingProfile = false
  @State private var isShowingAccountSwitcher = false
  @State private var isShowingBlockConfirmation = false
  @State private var isShowingAddToListSheet = false
  @State private var isBlocking = false
  @State private var isMuting = false
  @State private var profileForAddToList: AppBskyActorDefs.ProfileViewDetailed?
  @State private var hasAttemptedLoad = false
  @State private var hasAttemptedLoadPosts = false
  @State private var hasAttemptedLoadReplies = false
  @State private var hasAttemptedLoadMedia = false
  private let logger = Logger(subsystem: "blue.catbird", category: "UnifiedProfileView")
  #if DEBUG
  private let layoutLogger = Logger(subsystem: "blue.catbird", category: "LayoutDebug")
  #endif

  // MARK: - Computed Properties
  
  /// Computed property to convert the viewModel's pinned post to a cached version
  /// This prevents recreating the CachedFeedViewPost on every render
  private var cachedPinnedPost: CachedFeedViewPost? {
    guard let pinnedPost = viewModel.pinnedPost else { return nil }
    return CachedFeedViewPost(feedViewPost: pinnedPost)
  }

  // MARK: - Initialization (keeping all initializers)
  init(
    appState: AppState, selectedTab: Binding<Int>, lastTappedTab: Binding<Int?>,
    path: Binding<NavigationPath>
  ) {
    // Gracefully handle missing user DID instead of crashing
    guard let userDID = appState.currentUserDID else {
      // Create a fallback view model for the case where user isn't logged in
      let viewModel = ProfileViewModel(
        client: nil,
        userDID: "fallback",
        currentUserDID: nil,
        stateInvalidationBus: nil
      )
      self._viewModel = State(initialValue: viewModel)
      self._selectedTab = selectedTab
      self._lastTappedTab = lastTappedTab
      _navigationPath = path
      return
    }
    
    // Create ProfileViewModel with unique identity to prevent metadata cache conflicts
    let viewModel = ProfileViewModel(
      client: appState.atProtoClient,
      userDID: userDID,
      currentUserDID: appState.currentUserDID,
      stateInvalidationBus: appState.stateInvalidationBus
    )
    
    self._viewModel = State(initialValue: viewModel)
    self._selectedTab = selectedTab
    self._lastTappedTab = lastTappedTab
    _navigationPath = path
  }

  init(did: String, selectedTab: Binding<Int>, appState: AppState, path: Binding<NavigationPath>) {
    // Create ProfileViewModel with unique identity to prevent metadata cache conflicts
    let viewModel = ProfileViewModel(
      client: appState.atProtoClient,
      userDID: did,
      currentUserDID: appState.currentUserDID,
      stateInvalidationBus: appState.stateInvalidationBus
    )
    
    self._viewModel = State(initialValue: viewModel)
    self._selectedTab = selectedTab
    self._lastTappedTab = Binding.constant(nil)
    _navigationPath = path
  }

  var body: some View {
    // Always use SwiftUI implementation
    swiftUIImplementation
  }
  
  @ViewBuilder
  private var swiftUIImplementation: some View {
    profileViewConfiguration
  }
  
  @ViewBuilder
    private func profileContentView(profile: AppBskyActorDefs.ProfileViewDetailed) -> some View {
        ZStack {
            ScrollView {
                VStack(spacing: 0) {
                    // Banner section - constrained to 600pt like other content
                    bannerHeaderView(profile: profile)
                        .flexibleHeaderContent()
                        .background(Color.accentColor.opacity(0.05))
                        .frame(maxWidth: 600, alignment: .center)
                        .frame(maxWidth: .infinity, alignment: .center)

                    // Content section - using NotificationsView pattern
                    VStack(spacing: 0) {
                        // Profile header constrained like NotificationCard
                        ProfileHeader(
                            profile: profile,
                            viewModel: viewModel,
                            appState: appState,
                            isEditingProfile: $isEditingProfile,
                            path: $navigationPath,
                            screenWidth: 600, // Use constrained width like NotificationsView
                            hideAvatar: false
                        )
                        .padding(.horizontal, 16)
                        .frame(maxWidth: 600, alignment: .center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        
                        // Followed by section
                        followedBySection(profile: profile)
                            .padding(.horizontal, 16)
                            .frame(maxWidth: 600, alignment: .center)
                            .frame(maxWidth: .infinity, alignment: .center)
                        
                        // Tab selector
                        tabSelectorSection()
                            .padding(.horizontal, 16)
                            .frame(maxWidth: 600, alignment: .center)
                            .frame(maxWidth: .infinity, alignment: .center)
                        
                        // Posts content with full-width dividers
                        currentTabContentSection
                        
                        // Spacer
                        Spacer(minLength: 200)
                    }
                }
                // Clamp scroll content to viewport width to avoid horizontal expansion
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .flexibleHeaderScrollView()
            .refreshable { await refreshAllContent() }
            .ignoresSafeArea(edges: .top)
            .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
        }
    }
  // MARK: - Helper Views
  @ViewBuilder
  private func followedBySection(profile: AppBskyActorDefs.ProfileViewDetailed) -> some View {
    if !viewModel.isCurrentUser && !viewModel.knownFollowers.isEmpty {
      FollowedByView(
        knownFollowers: viewModel.knownFollowers,
        totalFollowersCount: profile.followersCount ?? 0,
        profileDID: profile.did.didString(),
        path: $navigationPath
      )
    }
  }
  
  @ViewBuilder
  private func tabSelectorSection() -> some View {
    @Bindable var viewModel = viewModel
    ProfileTabSelector(
      path: $navigationPath,
      selectedTab: $viewModel.selectedProfileTab,
      onTabChange: handleTabChange,
      isLabeler: viewModel.isLabeler
    )
  }
  
  private func handleTabChange(_ tab: ProfileTab) {
    Task {
      switch tab {
      case .labelerInfo:
        // Ensure labeler details are loaded
        if viewModel.isLabeler && viewModel.labelerDetails == nil {
          await viewModel.loadLabelerDetails()
        }
      case .posts:
        hasAttemptedLoadPosts = true
        if viewModel.posts.isEmpty { await viewModel.loadPosts() }
      case .replies:
        hasAttemptedLoadReplies = true
        if viewModel.replies.isEmpty { await viewModel.loadReplies() }
      case .media:
        hasAttemptedLoadMedia = true
        if viewModel.postsWithMedia.isEmpty { await viewModel.loadMediaPosts() }
      case .more:
        break
      default:
        break
      }
    }
  }


  // MARK: - New helper function for refreshing content
  private func refreshAllContent() async {
    // First refresh profile
    await viewModel.loadProfile()
    
    // Load known followers for other users
    if !viewModel.isCurrentUser {
      await viewModel.loadKnownFollowers()
    }
    
    // Then refresh current tab content
    switch viewModel.selectedProfileTab {
    case .posts:
      hasAttemptedLoadPosts = true
      await viewModel.loadPosts()
    case .replies:
      hasAttemptedLoadReplies = true
      await viewModel.loadReplies()
    case .media:
      hasAttemptedLoadMedia = true
      await viewModel.loadMediaPosts()
    case .more: break
    default: break
    }
  }
  
  // MARK: - Tab Content Sections
    @ViewBuilder
    private var currentTabContentSection: some View {
        switch viewModel.selectedProfileTab {
        case .labelerInfo:
            if let labelerDetails = viewModel.labelerDetails {
                LabelerInfoTab(labelerDetails: labelerDetails)
                    .frame(maxWidth: 600, alignment: .center)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ProgressView("Loading labeler information...")
                    .frame(maxWidth: .infinity, minHeight: 100)
                    .padding()
            }
        case .posts:
            postsTabContentSection()
        case .replies:
            postContentSection(
                posts: viewModel.replies,
                emptyMessage: "No replies",
                hasAttemptedLoad: hasAttemptedLoadReplies,
                loadAction: viewModel.loadReplies
            )
        case .media:
            postContentSection(
                posts: viewModel.postsWithMedia,
                emptyMessage: "No media posts",
                hasAttemptedLoad: hasAttemptedLoadMedia,
                loadAction: viewModel.loadMediaPosts
            )
        case .more:
            MoreView(path: $navigationPath)
        default:
            // Other tabs should only be accessible through the More menu
            EmptyView()
        }
    }
    
  // MARK: - Posts Tab Content Section (with pinned post support)
  @ViewBuilder
  private func postsTabContentSection() -> some View {
    LazyVStack(spacing: 0) {
      if !hasAttemptedLoadPosts || (viewModel.isLoading && viewModel.posts.isEmpty) {
        ProgressView("Loading...")
          .frame(maxWidth: .infinity, minHeight: 100)
          .padding()
          .frame(maxWidth: 600, alignment: .center)
          .frame(maxWidth: .infinity, alignment: .center)
      } else if viewModel.posts.isEmpty && viewModel.pinnedPost == nil {
        emptyContentView("No Content", "No posts")
          .padding(.top, 40)
          .frame(maxWidth: 600, alignment: .center)
          .frame(maxWidth: .infinity, alignment: .center)
      } else {
        // Show pinned post first if it exists
        if let cachedPinned = cachedPinnedPost {
          VStack(spacing: 0) {
            // Post content
            EnhancedFeedPost(
              cachedPost: cachedPinned,
              path: $navigationPath
            )
            .frame(maxWidth: 600, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .center)
            
            Divider()
              .padding(.top, 8)
          }
        }
        
        // Show cached posts (excluding pinned posts)
        ProfileCachedPostsList(
          feedKey: viewModel.profileFeedKey(for: .posts),
          isLoadingMore: viewModel.isLoadingMorePosts,
          loadMore: {
            await viewModel.loadPosts()
          },
          path: $navigationPath
        )
      }
    }
  }
  
  // MARK: - Post Content Section (generalized for reuse)
  @ViewBuilder
  private func postContentSection(
    posts: [AppBskyFeedDefs.FeedViewPost],
    emptyMessage: String,
    hasAttemptedLoad: Bool,
    loadAction: @escaping () async -> Void
  ) -> some View {
    LazyVStack(spacing: 0) {
      if !hasAttemptedLoad || (viewModel.isLoading && posts.isEmpty) {
        ProgressView("Loading...")
          .frame(maxWidth: .infinity, minHeight: 100)
          .padding()
          .frame(maxWidth: 600, alignment: .center)
          .frame(maxWidth: .infinity, alignment: .center)
      } else if posts.isEmpty {
        emptyContentView("No Content", emptyMessage)
          .padding(.top, 40)
          .frame(maxWidth: 600, alignment: .center)
          .frame(maxWidth: .infinity, alignment: .center)
      } else {
        // Use cached SwiftData objects and EnhancedFeedPost for consistency
        ProfileCachedPostsList(
          feedKey: viewModel.profileFeedKey(for: viewModel.selectedProfileTab),
          isLoadingMore: viewModel.isLoadingMorePosts,
          loadMore: {
            await loadAction()
          },
          path: $navigationPath
        )
      }
    }
  }

  // MARK: - Cached Posts List (SwiftData-backed)
  struct ProfileCachedPostsList: View {
    let feedKey: String
    let isLoadingMore: Bool
    let loadMore: @MainActor () async -> Void
    @Binding var path: NavigationPath

    @Query private var cached: [CachedFeedViewPost]

    init(
      feedKey: String,
      isLoadingMore: Bool,
      loadMore: @escaping @MainActor () async -> Void,
      path: Binding<NavigationPath>
    ) {
      self.feedKey = feedKey
      self.isLoadingMore = isLoadingMore
      self.loadMore = loadMore
      self._path = path
      self._cached = Query(
        filter: #Predicate<CachedFeedViewPost> { post in
          post.feedType == feedKey
        }
      )
    }
    
    // Sort posts: feedOrder first (if present), then by createdAt
    private var sortedCached: [CachedFeedViewPost] {
      cached.sorted { post1, post2 in
        // If both have feedOrder, sort by feedOrder
        if let order1 = post1.feedOrder, let order2 = post2.feedOrder {
          return order1 < order2
        }
        // If only post1 has feedOrder, it comes first
        if post1.feedOrder != nil {
          return true
        }
        // If only post2 has feedOrder, it comes first
        if post2.feedOrder != nil {
          return false
        }
        // If neither has feedOrder, sort by createdAt (newest first)
        return post1.createdAt > post2.createdAt
      }
    }

    var body: some View {
      ForEach(sortedCached) { cachedPost in
        VStack(spacing: 0) {
          EnhancedFeedPost(
            cachedPost: cachedPost,
            path: $path
          )
          .frame(maxWidth: 600, alignment: .center)
          .frame(maxWidth: .infinity, alignment: .center)

          Divider()
            .padding(.top, 8)
        }
        .contentShape(Rectangle())
        .onAppear {
          // Load more when reaching the end
          if cachedPost == sortedCached.last && !isLoadingMore {
            Task { await loadMore() }
          }
        }
      }

      if isLoadingMore {
        ProgressView()
          .padding()
          .frame(maxWidth: 600, alignment: .center)
          .frame(maxWidth: .infinity, alignment: .center)
      }
    }
  }

  // MARK: - Lists Content Section
  @ViewBuilder
  private var listsContentSection: some View {
    if viewModel.isLoading && viewModel.lists.isEmpty {
      ProgressView("Loading lists...")
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding()
        .listRowSeparator(.hidden)
    } else if viewModel.lists.isEmpty {
      emptyContentView("No Lists", "This user hasn't created any lists yet.")
        .padding(.top, 40)
        .listRowSeparator(.hidden)
        .onAppear {
          Task { await viewModel.loadLists() }
        }
    } else {
      ForEach(viewModel.lists, id: \.uri) { list in
        Button {
          navigationPath.append(NavigationDestination.list(list.uri))
        } label: {
          ListRow(list: list)
        }
        .buttonStyle(.plain)
        .onAppear {
          // Load more when reaching the end
          if list == viewModel.lists.last && !viewModel.isLoadingMorePosts {
            Task { await viewModel.loadLists() }
          }
        }
      }
        
      // Loading indicator for pagination
      if viewModel.isLoadingMorePosts {
        ProgressView()
          .padding()
          .frame(maxWidth: .infinity)
          .listRowSeparator(.hidden)
      }
    }
  }

  // MARK: - Starter Packs Content Section
  @ViewBuilder
  private var starterPacksContentSection: some View {
    if viewModel.isLoading && viewModel.starterPacks.isEmpty {
      ProgressView("Loading starter packs...")
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding()
        .listRowSeparator(.hidden)
    } else if viewModel.starterPacks.isEmpty {
      emptyContentView("No Starter Packs", "This user hasn't created any starter packs yet.")
        .padding(.top, 40)
        .listRowSeparator(.hidden)
        .onAppear {
          Task { await viewModel.loadStarterPacks() }
        }
    } else {
      ForEach(viewModel.starterPacks, id: \.uri) { pack in
        StarterPackRowView(pack: pack)
          .onAppear {
            // Load more when reaching the end
            if pack == viewModel.starterPacks.last && !viewModel.isLoadingMorePosts {
              Task { await viewModel.loadStarterPacks() }
            }
          }
      }
        
      // Loading indicator for pagination
      if viewModel.isLoadingMorePosts {
        ProgressView()
          .padding()
          .frame(maxWidth: .infinity)
          .listRowSeparator(.hidden)
      }
    }
  }

  // MARK: - Feeds Content Section
  @ViewBuilder
  private var feedsContentSection: some View {
    if viewModel.isLoading && viewModel.feeds.isEmpty {
      ProgressView("Loading feeds...")
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding()
        .listRowSeparator(.hidden)
    } else if viewModel.feeds.isEmpty {
      emptyContentView("No Feeds", "This user hasn't created any feeds yet.")
        .padding(.top, 40)
        .listRowSeparator(.hidden)
        .onAppear {
          Task { await viewModel.loadFeeds() }
        }
    } else {
      ForEach(viewModel.feeds, id: \.uri) { feed in
        Button {
          navigationPath.append(NavigationDestination.feed(feed.uri))
        } label: {
          FeedRowView(feed: feed)
        }
        .buttonStyle(.plain)
        .onAppear {
          // Load more when reaching the end
          if feed == viewModel.feeds.last && !viewModel.isLoadingMorePosts {
            Task { await viewModel.loadFeeds() }
          }
        }
      }
        
      // Loading indicator for pagination
      if viewModel.isLoadingMorePosts {
        ProgressView()
          .padding()
          .frame(maxWidth: .infinity)
          .listRowSeparator(.hidden)
      }
    }
  }

  // MARK: - Context Menu for Profile
  @ViewBuilder
  private func profileContextMenu(_ profile: AppBskyActorDefs.ProfileViewDetailed) -> some View {
    if !viewModel.isCurrentUser {
      Button {
        showAddToListSheet(profile)
      } label: {
        Label("Add to List", systemImage: "list.bullet.rectangle")
      }

      Button {
        searchPostsForProfile(profile)
      } label: {
        Label("Search This Profile", systemImage: "magnifyingglass")
      }

      Divider()

      Button {
        showReportProfileSheet()
      } label: {
        Label("Report User", systemImage: "flag")
      }

      Button {
        toggleMute()
      } label: {
        if isMuting {
          Label("Unmute User", systemImage: "speaker.wave.2")
        } else {
          Label("Mute User", systemImage: "speaker.slash")
        }
      }

      Button(role: .destructive) {
        isShowingBlockConfirmation = true
      } label: {
        if isBlocking {
          Label("Unblock User", systemImage: "person.crop.circle.badge.checkmark")
        } else {
          Label("Block User", systemImage: "person.crop.circle.badge.xmark")
        }
      }
    }
  }

  // MARK: - Alert Content
  @ViewBuilder
  private var alertButtons: some View {
    Button("Cancel", role: .cancel) {}

    Button(isBlocking ? "Unblock" : "Block", role: .destructive) {
      toggleBlock()
    }
  }

  @ViewBuilder
  private var alertMessage: some View {
    if let profile = viewModel.profile {
      if isBlocking {
        Text("Unblock @\(profile.handle)? You'll be able to see each other's posts again.")
      } else {
        Text(
          "Block @\(profile.handle)? You won't see each other's posts, and they won't be able to follow you."
        )
      }
    }
  }

  // MARK: - Event Handlers
  private func handleTabChange(_ newValue: Int?) {
    guard selectedTab == 3 else { return }

    if newValue == 3 {
      // Double-tapped profile tab - refresh profile and scroll to top
      Task {
        await viewModel.loadProfile()
        // Send scroll to top command
        appState.tabTappedAgain = 3
      }
      lastTappedTab = nil
    }
  }

  private func searchPostsForProfile(_ profile: AppBskyActorDefs.ProfileViewDetailed) {
    let queryHandle = "from:\(profile.handle.description)"

    appState.navigationManager.clearPath(for: 1)

    if let selectTab = appState.navigationManager.tabSelection {
      selectTab(1)
    } else {
      appState.navigationManager.updateCurrentTab(1)
    }

    selectedTab = 1
    appState.navigationManager.updateCurrentTab(1)
    lastTappedTab = nil

    appState.pendingSearchRequest = AppState.SearchRequest(
      query: queryHandle,
      focus: .posts,
      originProfileDID: profile.did.didString()
    )
  }

  private func initialLoad() async {
    hasAttemptedLoad = true
    do {
      await viewModel.loadProfile()
      
      // Check muting and blocking status
      if let did = viewModel.profile?.did.didString(), !viewModel.isCurrentUser {
        self.isBlocking = await appState.isBlocking(did: did)
        self.isMuting = await appState.isMuting(did: did)
        
        // Load known followers for other users
        await viewModel.loadKnownFollowers()
      }
      
      // Load initial content for current tab
      await refreshCurrentTabContent()
      
    } catch {
      logger.error("Failed to load initial profile data: \(error.localizedDescription)")
    }
  }
  
  private func refreshCurrentTabContent() async {
    switch viewModel.selectedProfileTab {
    case .posts:
      hasAttemptedLoadPosts = true
      if viewModel.posts.isEmpty {
        await viewModel.loadPosts()
      }
    case .replies:
      hasAttemptedLoadReplies = true
      if viewModel.replies.isEmpty {
        await viewModel.loadReplies()
      }
    case .media:
      hasAttemptedLoadMedia = true
      if viewModel.postsWithMedia.isEmpty {
        await viewModel.loadMediaPosts()
      }
    case .likes:
      if viewModel.likes.isEmpty {
        await viewModel.loadLikes()
      }
    default:
      break
    }
  }

  // MARK: - Keep existing functionality
  // Keeping all existing functions like showReportProfileSheet, toggleMute, toggleBlock, etc.
  
  private func showReportProfileSheet() {
    isShowingReportSheet = true
  }
  
  private func showAddToListSheet(_ profile: AppBskyActorDefs.ProfileViewDetailed) {
    profileForAddToList = profile
    isShowingAddToListSheet = true
  }

  private func toggleMute() {
    guard let profile = viewModel.profile, !viewModel.isCurrentUser else { return }

    let did = profile.did.didString()
    Task {
      do {
        let previousState = isMuting

        // Optimistically update UI
        isMuting.toggle()

        let success: Bool
        if previousState {
          // Unmute
          success = try await appState.unmute(did: did)
        } else {
          // Mute
          success = try await appState.mute(did: did)
        }

        if !success {
          // Revert if unsuccessful
          isMuting = previousState
        }
      } catch {
        // Revert on error
        isMuting = !isMuting
        logger.error("Failed to toggle mute: \(error.localizedDescription)")
      }
    }
  }

  private func toggleBlock() {
    guard let profile = viewModel.profile, !viewModel.isCurrentUser else { return }

    let did = profile.did.didString()
    Task {
      do {
        let previousState = isBlocking

        // Optimistically update UI
        isBlocking.toggle()

        let success: Bool
        if previousState {
          // Unblock
          success = try await appState.unblock(did: did)
        } else {
          // Block
          success = try await appState.block(did: did)
        }

        if !success {
          // Revert if unsuccessful
          isBlocking = previousState
        }
      } catch {
        // Revert on error
        isBlocking = !isBlocking
        logger.error("Failed to toggle block: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Banner Header View
  @ViewBuilder
  private func bannerHeaderView(profile: AppBskyActorDefs.ProfileViewDetailed) -> some View {
    let banner = ZStack(alignment: .center) {
      if let bannerURL = profile.banner?.uriString() {
        LazyImage(url: URL(string: bannerURL)) { state in
          if let image = state.image {
            image
              .resizable()
              .scaledToFill() // Fill width, crop vertically if needed
              .overlay(Color.black.opacity(0.15).blendMode(.overlay))
          } else if state.error != nil {
            Rectangle().fill(Color.accentColor.opacity(0.25))
          } else {
            Rectangle().fill(Color.accentColor.opacity(0.15))
              .overlay(ProgressView().tint(.white))
          }
        }
      } else {
        Rectangle()
          .fill(Color.accentColor.opacity(0.25))
      }
    }
    .clipped() // Ensure banner content doesn’t overflow assigned frame
    .contentShape(Rectangle())
    .accessibilityLabel("Profile banner")

    if hSizeClass == .compact {
      banner
        .containerRelativeFrame(.horizontal)
    } else {
      banner
    }
  }
  
  // Responsive banner height based on screen size
  private var responsiveBannerHeight: CGFloat {
    #if os(iOS)
    switch UIScreen.main.bounds.width {
    case ..<375: return 120  // Small iPhones (SE)
    case ..<430: return 140  // Standard iPhones (iPhone 16, 15, etc.)
    default: return 160      // Large phones (iPhone 16 Pro Max, etc.)
    }
    #else
    return 180 // macOS - slightly larger for desktop experience
    #endif
  }

  // MARK: - View Components
  private var loadingView: some View {
    VStack {
      ProgressView()
        .scaleEffect(1.5)
        .tint(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .primary, currentScheme: currentColorScheme))
      Text("Loading profile...")
        .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .secondary, currentScheme: currentColorScheme))
        .padding(.top)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
  }

  @ViewBuilder
  private var errorView: some View {
      Group {
          if let error = viewModel.error {
              ErrorStateView(
                error: error,
                context: "Failed to load profile",
                retryAction: { Task { await viewModel.loadProfile() } }
              )
          } else {
              VStack(spacing: 16) {
                  Image(systemName: "exclamationmark.triangle")
                      .appFont(size: 48)
                      .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .primary, currentScheme: currentColorScheme))
                  
                  Text("Profile Not Found")
                      .appFont(AppTextRole.title2)
                      .fontWeight(.semibold)
                      .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .primary, currentScheme: currentColorScheme))
                  
                  Text("This profile may not exist or is not accessible")
                      .appFont(AppTextRole.subheadline)
                      .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .secondary, currentScheme: currentColorScheme))
                      .multilineTextAlignment(.center)
                      .padding(.horizontal)
              }
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
          }
      }
  }
    
  @ViewBuilder
    private func emptyContentView(_ title: String, _ message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            
            // Tab-specific icons
            Image(systemName: emptyStateIcon(for: title))
                .appFont(size: 56)
                .foregroundStyle(.secondary.opacity(0.6))
                .symbolEffect(.pulse)
            
            VStack(spacing: 8) {
                Text(title)
                    .appFont(AppTextRole.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                
                Text(enhancedEmptyMessage(for: title, message: message))
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
    
    // Enhanced empty state messaging
    private func emptyStateIcon(for title: String) -> String {
        switch title.lowercased() {
        case "no posts": return "text.bubble"
        case "no replies": return "arrowshape.turn.up.left"
        case "no media posts": return "photo.on.rectangle"
        case "no likes": return "heart"
        case "no lists": return "list.bullet.rectangle"
        case "no feeds": return "rectangle.grid.1x2"
        default: return "square.stack.3d.up.slash"
        }
    }
    
    private func enhancedEmptyMessage(for title: String, message: String) -> String {
        if viewModel.isCurrentUser {
            switch title.lowercased() {
            case "no posts": return "Share your thoughts! Your posts will appear here."
            case "no replies": return "Join conversations by replying to posts."
            case "no media posts": return "Share photos and videos to see them here."
            case "no likes": return "Like posts to save them for later."
            default: return message
            }
        } else {
            return message
        }
    }
    
  // MARK: - View Configuration
  @ViewBuilder
  private var profileViewConfiguration: some View {
    Group {
      if !hasAttemptedLoad || (viewModel.isLoading && viewModel.profile == nil) {
        loadingView
      } else if let profile = viewModel.profile {
        profileContentView(profile: profile)
      } else {
        errorView
      }
    }
    .id(viewModel.userDID) // Use stable userDID instead of profile?.did
    .navigationTitle("")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    #else
    .toolbarBackground(.hidden, for: .automatic)
    #endif
    .ensureDeepNavigationFonts()
    .navigationDestination(for: ProfileNavigationDestination.self) { destination in
      switch destination {
      case .section(let tab):
        ProfileSectionView(viewModel: viewModel, tab: tab, path: $navigationPath)
          .id("\(viewModel.userDID)_\(tab.rawValue)") // Stable composite ID
      case .followers(let did):
        FollowersView(userDID: did, client: appState.atProtoClient, path: $navigationPath)
          .id(did)
      case .following(let did):
        FollowingView(userDID: did, client: appState.atProtoClient, path: $navigationPath)
          .id(did)
      case .knownFollowers(let did):
        KnownFollowersView(userDID: did, path: $navigationPath)
          .id(did)
      }
    }
    // FIXED: Apply modifiers directly instead of using recursive computed properties
    .sheet(isPresented: $isShowingReportSheet) {
      if let profile = viewModel.profile,
         let atProtoClient = appState.atProtoClient {
        let reportingService = ReportingService(client: atProtoClient)
        ReportProfileView(
          profile: profile,
          reportingService: reportingService,
          onComplete: { _ in isShowingReportSheet = false }
        )
      }
    }
    .sheet(isPresented: $isEditingProfile) {
      EditProfileView(isPresented: $isEditingProfile, viewModel: viewModel)
    }
    .sheet(isPresented: $isShowingAccountSwitcher) {
      AccountSwitcherView()
    }
    .sheet(isPresented: $isShowingAddToListSheet) {
      if let profile = profileForAddToList {
        AddToListSheet(
          userDID: profile.did.didString(),
          userHandle: profile.handle.description,
          userDisplayName: profile.displayName
        )
      }
    }
    .toolbar {
      if let profile = viewModel.profile {
        ToolbarItem(placement: .principal) {
          Text(profile.displayName ?? profile.handle.description)
            .appFont(AppTextRole.headline)
        }
        
        if viewModel.isCurrentUser {
          ToolbarItem(placement: .primaryAction) {
            currentUserMenu
          }
        } else {
          ToolbarItem(placement: .primaryAction) {
            otherUserMenu
          }
        }
      }
    }
    .alert(isBlocking ? "Unblock User" : "Block User", isPresented: $isShowingBlockConfirmation) {
      alertButtons
    } message: {
      alertMessage
    }
    .onChange(of: lastTappedTab) { _, newValue in
      handleTabChange(newValue)
    }
    .task {
      // Wrap in error handling to prevent crashes
      do {
        await initialLoad()
      } catch {
        logger.error("Failed to load initial profile data: \(error.localizedDescription)")
        // Let the error state be handled by the view model
      }
    }
  }
  
  @ViewBuilder
  private var currentUserMenu: some View {
    Menu {
      Button {
        isShowingAccountSwitcher = true
      } label: {
        Label("Switch Account", systemImage: "person.crop.circle.badge.plus")
      }
      
      Button {
        Task { try? await appState.handleLogout() }
      } label: {
        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
      }
    } label: {
      Image(systemName: "ellipsis.circle")
    }
  }
  
  @ViewBuilder
  private var otherUserMenu: some View {
    Menu {
      if let profile = viewModel.profile {
        // Labeler-specific options
        if viewModel.isLabeler {
          Button {
            Task {
              do {
                if viewModel.isSubscribedToLabeler {
                  try await viewModel.unsubscribeFromLabeler()
                } else {
                  try await viewModel.subscribeToLabeler()
                }
              } catch {
                logger.error("Error toggling labeler subscription: \(error.localizedDescription)")
              }
            }
          } label: {
            Label(viewModel.isSubscribedToLabeler ? "Unsubscribe from labeler" : "Subscribe to labeler",
                  systemImage: viewModel.isSubscribedToLabeler ? "checkmark.circle.fill" : "checkmark.circle")
          }
          
          Button {
            shareLabeler(profile)
          } label: {
            Label("Share labeler", systemImage: "square.and.arrow.up")
          }
          
          Divider()
          
          Button {
            showReportProfileSheet()
          } label: {
            Label("Report labeler", systemImage: "flag")
          }
        } else {
          // Regular user options
          Button {
            showAddToListSheet(profile)
          } label: {
            Label("Add to List", systemImage: "list.bullet.rectangle")
          }

          Button {
            searchPostsForProfile(profile)
          } label: {
            Label("Search This Profile", systemImage: "magnifyingglass")
          }
          
          Divider()
          
          Button {
            showReportProfileSheet()
          } label: {
            Label("Report User", systemImage: "flag")
          }

          Button {
            toggleMute()
          } label: {
            Label(isMuting ? "Unmute User" : "Mute User",
                  systemImage: isMuting ? "speaker.wave.2" : "speaker.slash")
          }
          
          Button(role: .destructive) {
            isShowingBlockConfirmation = true
          } label: {
            Label(isBlocking ? "Unblock User" : "Block User",
                  systemImage: isBlocking ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark")
          }
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
    }
  }
  
  // MARK: - Helper Methods
  
  private func shareLabeler(_ profile: AppBskyActorDefs.ProfileViewDetailed) {
    guard let labelerDetails = viewModel.labelerDetails else { return }
    
    let shareText = "Check out this labeler: @\(profile.handle.description)"
    let shareURL = URL(string: "https://bsky.app/profile/\(profile.handle.description)")
    
    #if os(iOS)
    let activityVC = UIActivityViewController(
      activityItems: [shareText, shareURL].compactMap { $0 },
      applicationActivities: nil
    )
    
    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let rootViewController = windowScene.windows.first?.rootViewController {
      rootViewController.present(activityVC, animated: true)
    }
    #elseif os(macOS)
    let picker = NSSharingServicePicker(items: [shareText, shareURL].compactMap { $0 })
    if let view = NSApplication.shared.keyWindow?.contentView {
      picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
    }
    #endif
  }
}

// MARK: - Profile Header
struct ProfileHeader: View {
    let profile: AppBskyActorDefs.ProfileViewDetailed
    let viewModel: ProfileViewModel
    let appState: AppState
    @Binding var isEditingProfile: Bool
    @Binding var path: NavigationPath
    let screenWidth: CGFloat
    let hideAvatar: Bool
    
    @Environment(\.colorScheme) private var colorScheme
    @State private var isFollowButtonLoading = false
    @State private var localIsFollowing: Bool = false
    @State private var localActivitySubscription: AppBskyNotificationDefs.ActivitySubscription?
    @State private var isActivitySubscriptionLoading = false
    @State private var activitySubscriptionError: String?
    @State private var isShowingProfileImageViewer = false
    @Namespace private var imageTransition
    
    private let avatarSize: CGFloat = 80
    
    // Standardized spacing constants
    private let horizontalPadding: CGFloat = 16
    private let verticalSpacing: CGFloat = 12
    
    private let logger = Logger(subsystem: "blue.catbird", category: "ProfileHeader")
    
    var body: some View {
        // Use ZStack to allow avatar to overlap the banner area above
        ZStack(alignment: .topLeading) {
            // Main content with minimal top padding for overlapping avatar
            profileInfoContent
                .padding(.top, hideAvatar ? verticalSpacing : 8)

            // Avatar positioned to overlap the banner above
            if !hideAvatar {
                avatarView
                    .offset(y: -avatarSize / 2)
                    // Use consistent 16pt padding from the content edge
                    .padding(.leading, 16)
            }
        }
//        .sheet(isPresented: $showingFollowersSheet) {
//            followersSheet
//        }
//        .sheet(isPresented: $showingFollowingSheet) {
//            followingSheet
//        }
#if os(iOS)
        .fullScreenCover(isPresented: $isShowingProfileImageViewer) {
            if let profile = viewModel.profile, let avatarURI = profile.avatar?.uriString() {
                ProfileImageViewerView(avatar: profile.avatar, isPresented: $isShowingProfileImageViewer, namespace: imageTransition)
                    .navigationTransition(.zoom(sourceID: avatarURI, in: imageTransition))
            }
        }
#elseif os(macOS)
        .sheet(isPresented: $isShowingProfileImageViewer) {
            if let profile = viewModel.profile {
                ProfileImageViewerView(avatar: profile.avatar, isPresented: $isShowingProfileImageViewer, namespace: imageTransition)
            }
        }
#endif
        .onAppear {
            // Initialize local follow state based on profile
            localIsFollowing = profile.viewer?.following != nil
            updateLocalActivitySubscription()
        }
        .onChange(of: profile) { _, newProfile in
            // Update local follow state when profile changes
            localIsFollowing = newProfile.viewer?.following != nil
            updateLocalActivitySubscription()
        }
        .onChange(of: activitySubscriptionSnapshot) { _, _ in
            updateLocalActivitySubscription()
        }
    }
    
    private var activitySubscriptionService: ActivitySubscriptionService {
        appState.activitySubscriptionService
    }

    // Snapshot type to ensure Equatable conformance for onChange
    private struct SubscriptionSnapshot: Equatable {
        let id: String
        let post: Bool
        let reply: Bool
    }

    private var activitySubscriptionSnapshot: [SubscriptionSnapshot] {
        activitySubscriptionService.subscriptions.map { entry in
            SubscriptionSnapshot(
                id: entry.id,
                post: entry.subscription?.post ?? false,
                reply: entry.subscription?.reply ?? false
            )
        }
    }
    
    private var isSubscriptionUpdating: Bool {
        isActivitySubscriptionLoading || activitySubscriptionService.isUpdating(did: profile.did.didString())
    }
    
    private var canSubscribeToActivity: Bool {
        guard !viewModel.isCurrentUser else { return false }
        if profile.viewer?.blocking != nil || profile.viewer?.blockedBy == true {
            return false
        }
        if let allowSubscriptions = profile.associated?.activitySubscription?.allowSubscriptions {
            // The lexicon currently allows: followers, mutuals, or none.
            switch allowSubscriptions {
            case "none":
                return false
            case "followers":
                return profile.viewer?.following != nil
            case "mutuals":
                return profile.viewer?.following != nil && profile.viewer?.followedBy != nil
            default:
                return true
            }
        }
        return true
    }
    
    private var currentActivitySubscriptionState: ActivitySubscriptionState {
        guard let subscription = localActivitySubscription else { return .none }
        switch (subscription.post, subscription.reply) {
        case (true, true):
            return .postsAndReplies
        case (true, false):
            return .postsOnly
        case (false, true):
            return .repliesOnly
        default:
            return .none
        }
    }
    
    private var nextActivitySubscriptionState: ActivitySubscriptionState {
        switch currentActivitySubscriptionState {
        case .none:
            return .postsOnly
        case .postsOnly:
            return .postsAndReplies
        case .postsAndReplies, .repliesOnly:
            return .none
        }
    }
    
    private var subscriptionButtonIcon: String {
        switch currentActivitySubscriptionState {
        case .none:
            return "bell"
        case .postsOnly:
            return "bell.badge"
        case .postsAndReplies:
            return "bell.badge.fill"
        case .repliesOnly:
            return "bubble.left"
        }
    }
    
    private var subscriptionButtonTint: Color {
        switch currentActivitySubscriptionState {
        case .none:
            return .secondary
        case .postsOnly, .postsAndReplies:
            return .indigo
        case .repliesOnly:
            return .teal
        }
    }
    
    private var subscriptionButtonAccessibilityLabel: String {
        switch currentActivitySubscriptionState {
        case .none:
            return "Activity notifications off"
        case .postsOnly:
            return "Activity notifications for posts"
        case .postsAndReplies:
            return "Activity notifications for posts and replies"
        case .repliesOnly:
            return "Activity notifications for replies"
        }
    }
    
    private var isSubscriptionControlDisabled: Bool {
        isSubscriptionUpdating
    }
    
    @ViewBuilder
    private var activitySubscriptionControl: some View {
        Button(action: cycleActivitySubscriptionState) {
            Group {
                if isSubscriptionUpdating {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(subscriptionButtonTint)
                        .frame(width: 36, height: 36)
                } else {
                    Image(systemName: subscriptionButtonIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(subscriptionButtonTint)
                        .frame(width: 18, height: 18)
                        .padding(10)
                        .background(
                            Circle()
                                .fill(currentActivitySubscriptionState == .none ? Color.clear : subscriptionButtonTint.opacity(0.15))
                        )
                        .overlay(
                            Circle()
                                .stroke(subscriptionButtonTint.opacity(0.8), lineWidth: 1.5)
                        )
                        .contentShape(Circle())
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(subscriptionButtonAccessibilityLabel)
        .accessibilityHint("Cycles activity notifications between posts, posts & replies, or off")
        .disabled(isSubscriptionControlDisabled)
    }
    
    private func cycleActivitySubscriptionState() {
        guard canSubscribeToActivity, !isSubscriptionControlDisabled else { return }
        let did = profile.did.didString()
        let nextState = nextActivitySubscriptionState
        activitySubscriptionError = nil
        isActivitySubscriptionLoading = true

        Task {
            do {
                let updatedSubscription: AppBskyNotificationDefs.ActivitySubscription?

                switch nextState {
                case .none:
                    try await activitySubscriptionService.clearSubscription(for: did)
                    updatedSubscription = nil
                case .postsOnly:
                    updatedSubscription = try await activitySubscriptionService.setSubscription(for: did, posts: true, replies: false)
                case .postsAndReplies:
                    updatedSubscription = try await activitySubscriptionService.setSubscription(for: did, posts: true, replies: true)
                case .repliesOnly:
                    updatedSubscription = try await activitySubscriptionService.setSubscription(for: did, posts: false, replies: true)
                }

                await MainActor.run {
                    localActivitySubscription = updatedSubscription
                    activitySubscriptionError = nil
                }
            } catch {
                logger.error("Failed to update activity subscription: \(error.localizedDescription)")
                await MainActor.run {
                    activitySubscriptionError = error.localizedDescription
                }
            }

            await MainActor.run {
                isActivitySubscriptionLoading = false
            }
        }
    }

    private func updateLocalActivitySubscription() {
        let did = profile.did.didString()
        if let subscription = profile.viewer?.activitySubscription {
            localActivitySubscription = subscription
        } else if let cached = activitySubscriptionService.subscription(for: did) {
            localActivitySubscription = cached
        } else {
            localActivitySubscription = nil
        }
    }

    private enum ActivitySubscriptionState {
        case none
        case postsOnly
        case postsAndReplies
        case repliesOnly
    }
    
    private var isLabeler: Bool {
        viewModel.isLabeler
    }
    
    private var avatarView: some View {
        Group {
            if isLabeler {
                // Square avatar for labelers
                LazyImage(url: URL(string: profile.avatar?.uriString() ?? "")) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.3))
                    }
                }
                .matchedTransitionSource(id: profile.avatar?.uriString() ?? "", in: imageTransition)
                .onTapGesture {
                    isShowingProfileImageViewer = true
                }
                .frame(width: avatarSize, height: avatarSize)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme), lineWidth: 4)
                        .scaleEffect((avatarSize + 8) / avatarSize)
                )
                .zIndex(10)
            } else {
                // Circular avatar for regular users
                LazyImage(url: URL(string: profile.avatar?.uriString() ?? "")) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Circle().fill(Color.secondary.opacity(0.3))
                    }
                }
                .matchedTransitionSource(id: profile.avatar?.uriString() ?? "", in: imageTransition)
                .onTapGesture {
                    isShowingProfileImageViewer = true
                }
                .frame(width: avatarSize, height: avatarSize)
                .clipShape(Circle())
                .background(
                    Circle()
                        .stroke(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme), lineWidth: 4)
                        .scaleEffect((avatarSize + 8) / avatarSize)
                )
                .zIndex(10)
            }
        }
    }
    
    private var profileInfoContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top section with edit/follow/subscribe button aligned to trailing edge
            HStack(alignment: .top, spacing: 8) {
                Spacer()
                
                if viewModel.isCurrentUser {
                    editProfileButton
                        .allowsHitTesting(true)
                } else if isLabeler {
                    HStack(spacing: 8) {
                        subscribeButton
                            .allowsHitTesting(true)
                        labelerLikeButton
                            .allowsHitTesting(true)
                    }
                } else {
                    HStack(spacing: 8) {
                        followButton
                            .allowsHitTesting(true)
                        if canSubscribeToActivity {
                            activitySubscriptionControl
                        }
                    }
                }
            }
            .padding(.top, 4)

            if let activitySubscriptionError {
                Text(activitySubscriptionError)
                    .appCaption()
                    .foregroundStyle(.red)
                    .padding(.top, 2)
            }
            
            // Display name and handle
            VStack(alignment: .leading, spacing: 6) {
                Text(profile.displayName ?? profile.handle.description)
                    .enhancedAppHeadline()
                    .fontWeight(.bold)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                
                HStack(spacing: 8) {
                    Text("@\(profile.handle)")
                        .enhancedAppSubheadline()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    
                    if profile.viewer?.followedBy != nil {
                        FollowsBadgeView()
                    }
                }
            }
            
            // Bio
            if let attributedBio = bioAttributedString(for: profile) {
                TappableTextView(attributedString: attributedBio)
                    .padding(.top, 2)
            } else if let description = profile.description, !description.isEmpty {
                Text(description)
                    .enhancedAppBody()
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            // Stats
            HStack(spacing: 24) {
                // Following
                Button(action: {
                    
                    path.append(ProfileNavigationDestination.following(profile.did.didString()))
                    
                }) {
                    HStack(spacing: 6) {
                        Text("\(profile.followsCount ?? 0)")
                            .appFont(AppTextRole.subheadline)
                            .fontWeight(.semibold)
                        
                        Text("Following")
                            .appFont(AppTextRole.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                
                // Followers
                Button(action: {
                    path.append(ProfileNavigationDestination.followers(profile.did.didString()))
                }) {
                    HStack(spacing: 6) {
                        Text("\(profile.followersCount ?? 0)")
                            .appFont(AppTextRole.subheadline)
                            .fontWeight(.semibold)
                        
                        Text("Followers")
                            .appFont(AppTextRole.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                
                Spacer()
            }
        }
        .padding(.bottom, verticalSpacing)
    }

    // MARK: - Bio Helpers

    private func bioAttributedString(for profile: AppBskyActorDefs.ProfileViewDetailed) -> AttributedString? {
        guard let description = profile.description, !description.isEmpty else {
            return nil
        }

        let attributedBio = NSMutableAttributedString(string: description)

        applyDetectedLinks(in: description, to: attributedBio)
        applyDetectedHandles(in: description, to: attributedBio)

        return AttributedString(attributedBio)
    }

    private func applyDetectedLinks(in text: String, to attributedText: NSMutableAttributedString) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        detector.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match, let url = match.url else { return }
            guard !hasLinkAttribute(in: attributedText, range: match.range) else { return }
            applyLinkAttributes(url: url, range: match.range, on: attributedText)
        }
    }

    private func applyDetectedHandles(in text: String, to attributedText: NSMutableAttributedString) {
        let pattern = "(?<![\\w@])@[A-Za-z0-9][A-Za-z0-9.-]*"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match else { return }
            guard !hasLinkAttribute(in: attributedText, range: match.range) else { return }

            let handleWithPrefix = nsText.substring(with: match.range)
            let handle = String(handleWithPrefix.dropFirst())
            guard !handle.isEmpty else { return }

            let encodedHandle = handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle
            guard let url = URL(string: "mention://\(encodedHandle)") else { return }
            applyLinkAttributes(url: url, range: match.range, on: attributedText, underline: false)
        }
    }

    private func applyLinkAttributes(
        url: URL,
        range: NSRange,
        on attributedText: NSMutableAttributedString,
        underline: Bool = true
    ) {
        var attributes: [NSAttributedString.Key: Any] = [
            .link: url,
            .foregroundColor: PlatformColor.platformLink
        ]

        if underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        attributedText.addAttributes(attributes, range: range)
    }

    private func hasLinkAttribute(in attributedText: NSMutableAttributedString, range: NSRange) -> Bool {
        var hasLink = false
        attributedText.enumerateAttribute(.link, in: range, options: []) { value, _, stop in
            if value != nil {
                hasLink = true
                stop.pointee = true
            }
        }
        return hasLink
    }
    
    private var editProfileButton: some View {
        Button(action: {
            isEditingProfile = true
        }) {
            Text("Edit Profile")
                .appFont(AppTextRole.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .foregroundColor(.accentColor)
        }
        .background(
            Capsule()
                .stroke(Color.accentColor, lineWidth: 1.5)
        )
    }
    
    @ViewBuilder
    private var followButton: some View {
        if isFollowButtonLoading {
            ProgressView()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        } else if profile.viewer?.blocking != nil {
            // Show blocked state instead of follow button
            Button(action: {
                // Do nothing - blocking handled in parent view
            }) {
                HStack {
                    Image(systemName: "person.crop.circle.badge.xmark")
                        .appFont(AppTextRole.footnote)
                    Text("Blocked")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .appFont(AppTextRole.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundColor(.red)
                .cornerRadius(16)
            }
            .background(
                Capsule()
                    .stroke(Color.red, lineWidth: 1.5)
            )
        } else if profile.viewer?.muted == true {
            // Show muted state
            Button(action: {
                // Do nothing - muting handled in parent view
            }) {
                HStack {
                    Image(systemName: "speaker.slash")
                        .appFont(AppTextRole.footnote)
                    Text("Muted")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .appFont(AppTextRole.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .foregroundColor(.orange)
                .cornerRadius(16)
            }
            .background(
                Capsule()
                    .stroke(Color.orange, lineWidth: 1.5)
            )
        } else if localIsFollowing {
            Button(action: {
                Task(priority: .userInitiated) {  // Explicit priority
                    isFollowButtonLoading = true
                    
                    // Optimistically update UI
                    localIsFollowing = false
                    
                    do {
                        // Perform unfollow operation on server
                        let success = try await appState.unfollow(did: profile.did.didString())  // Use performUnfollow
                        
                        if success {
                            // Add a small delay before reloading to allow server to update
                            try? await Task.sleep(for: .seconds(0.5))
                            await viewModel.loadProfile()
                        } else {
                            // Revert local state if operation failed
                            localIsFollowing = true
                        }
                    } catch {
                        // Log error and revert local state
                        logger.debug("Error unfollowing: \(error.localizedDescription)")
                        localIsFollowing = true
                    }
                    
                    isFollowButtonLoading = false
                }
            }) {
                HStack {
                    Image(systemName: "checkmark")
                        .appFont(AppTextRole.footnote)
                    Text("Following")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .appFont(AppTextRole.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .foregroundColor(.accentColor)
                .cornerRadius(16)
            }
            .background(
                Capsule()
                    .stroke(Color.accentColor, lineWidth: 1.5)
            )
            
        } else {
            Button(action: {
                Task(priority: .userInitiated) {  // Explicit priority
                    isFollowButtonLoading = true
                    
                    // Optimistically update UI
                    localIsFollowing = true
                    
                    do {
                        // Perform follow operation
                        let success = try await appState.follow(did: profile.did.didString())  // Use performFollow
                        
                        if success {
                            // Add a small delay before reloading
                            try? await Task.sleep(for: .seconds(0.5))
                            await viewModel.loadProfile()
                        } else {
                            // Revert local state if operation failed
                            localIsFollowing = false
                        }
                    } catch {
                        // Log error and revert local state
                        logger.debug("Error following: \(error.localizedDescription)")
                        localIsFollowing = false
                    }
                    
                    isFollowButtonLoading = false
                }
            }) {
                HStack {
                    Image(systemName: "plus")
                        .appFont(AppTextRole.footnote)
                    Text("Follow")
                }
                .appFont(AppTextRole.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(16)
            }
        }
    }
    
    // MARK: - Labeler Buttons
    
    @State private var isSubscribeButtonLoading = false
    @State private var isLikeButtonLoading = false
    
    @ViewBuilder
    private var subscribeButton: some View {
        Group {
            if isSubscribeButtonLoading {
                ProgressView()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else if viewModel.isSubscribedToLabeler {
                Button(action: {
                    Task(priority: .userInitiated) {
                        isSubscribeButtonLoading = true
                        do {
                            try await viewModel.unsubscribeFromLabeler()
                        } catch {
                            logger.error("Error unsubscribing from labeler: \(error.localizedDescription)")
                        }
                        isSubscribeButtonLoading = false
                    }
                }) {
                    HStack {
                        Image(systemName: "checkmark")
                            .appFont(AppTextRole.footnote)
                        Text("Subscribed")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .appFont(AppTextRole.subheadline)
                    .fontWeight(.medium)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .foregroundColor(.accentColor)
                    .cornerRadius(16)
                }
                .background(
                    Capsule()
                        .stroke(Color.accentColor, lineWidth: 1.5)
                )
            } else {
                Button(action: {
                    Task(priority: .userInitiated) {
                        isSubscribeButtonLoading = true
                        do {
                            try await viewModel.subscribeToLabeler()
                        } catch {
                            logger.error("Error subscribing to labeler: \(error.localizedDescription)")
                        }
                        isSubscribeButtonLoading = false
                    }
                }) {
                    HStack {
                        Image(systemName: "plus")
                            .appFont(AppTextRole.footnote)
                        Text("Subscribe")
                    }
                    .appFont(AppTextRole.subheadline)
                    .fontWeight(.medium)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(16)
                }
            }
        }
    }
    
    @ViewBuilder
    private var labelerLikeButton: some View {
        Button(action: {
            Task(priority: .userInitiated) {
                isLikeButtonLoading = true
                do {
                    if viewModel.isLabelerLiked {
                        try await viewModel.unlikeLabeler()
                    } else {
                        try await viewModel.likeLabeler()
                    }
                } catch {
                    logger.error("Error toggling labeler like: \(error.localizedDescription)")
                }
                isLikeButtonLoading = false
            }
        }) {
            HStack(spacing: 6) {
                if isLikeButtonLoading {
                    ProgressView()
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: viewModel.isLabelerLiked ? "heart.fill" : "heart")
                        .foregroundStyle(viewModel.isLabelerLiked ? .red : .primary)
                }
                
                if viewModel.labelerLikeCount > 0 {
                    Text("\(viewModel.labelerLikeCount)")
                        .appCaption()
                }
            }
            .padding(8)
            .background(
                Circle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLikeButtonLoading)
    }
}

#if DEBUG
// MARK: - Layout Debugging Helpers
private struct _SizePreferenceKey: PreferenceKey {
  static var defaultValue: CGSize = .zero
  static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private let _layoutDebugLogger = Logger(subsystem: "blue.catbird", category: "LayoutDebug")

private extension View {
  func debugSize(_ tag: String) -> some View {
    background(
      GeometryReader { proxy in
        Color.clear.preference(key: _SizePreferenceKey.self, value: proxy.size)
      }
    )
    .onPreferenceChange(_SizePreferenceKey.self) { size in
      #if os(iOS)
      let screenW = UIScreen.main.bounds.width
      #else
      let screenW = size.width
      #endif
      _layoutDebugLogger.debug("[\(tag)] width=\(size.width, privacy: .public), screen=\(screenW, privacy: .public), overflow=\(size.width > screenW ? "YES" : "no", privacy: .public)")
    }
  }
}
#endif

// MARK: - Preview
//#Preview {
//  let appState = AppState.shared
//    NavigationStack {
//    UnifiedProfileView(
//      appState: appState,
//      selectedTab: .constant(3),
//      lastTappedTab: .constant(nil),
//      path: .constant(NavigationPath())
//    )
//  }
//  .environment(appState)
//}

struct ProfileImageViewerView: View {
    let avatar: URI?
    @Environment(AppState.self) private var appState
    @Binding var isPresented: Bool
    var namespace: Namespace.ID
    @State private var opacity: CGFloat = 0.0
    
    var body: some View {
        ZStack {
            Color.black
                .opacity(opacity)
                .ignoresSafeArea()
            
            if let avatarURI = avatar {
                let imageUrl = avatarURI.uriString()
                
#if os(iOS)
                LazyPager(data: [imageUrl]) { image in
                    GeometryReader { geometry in
                        LazyImage(request: ImageLoadingManager.imageRequest(
                            for: URL(string: image) ?? URL(string: "about:blank")!,
                            targetSize: CGSize(width: geometry.size.width, height: geometry.size.height)
                        )) { state in
                            if let fullImage = state.image {
                                fullImage
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                                    .id(image) // Use the image string for proper identification
                                    .matchedTransitionSource(id: image, in: namespace)

                            } else if state.error != nil {
                                Image(systemName: "exclamationmark.triangle")
                                    .appFont(AppTextRole.largeTitle)
                                    .foregroundColor(.white)
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                            } else {
                                ProgressView()
                                    .tint(.white)
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                            }
                        }
                        .pipeline(ImageLoadingManager.shared.pipeline)
                    }
                }
                .zoomable(min: 1.0, max: 3.0, doubleTapGesture: .scale(2.0))
                .onDismiss(backgroundOpacity: $opacity) {
                    isPresented = false
                }
                .settings { config in
                    config.dismissVelocity = 1.5
                    config.dismissTriggerOffset = 0.2
                    config.dismissAnimationLength = 0.3
                    config.fullFadeOnDragAt = 0.3
                    config.pinchGestureEnableOffset = 15
                    config.shouldCancelSwiftUIAnimationsOnDismiss = false
                }
                .id("pager-\(imageUrl)")
#else
                // macOS: Simple image viewer without LazyPager
                GeometryReader { geometry in
                    LazyImage(request: ImageLoadingManager.imageRequest(
                        for: URL(string: imageUrl) ?? URL(string: "about:blank")!,
                        targetSize: CGSize(width: geometry.size.width, height: geometry.size.height)
                    )) { state in
                        if let fullImage = state.image {
                            fullImage
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                                .id(imageUrl)
                                .matchedTransitionSource(id: imageUrl, in: namespace)
                        } else if state.error != nil {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundColor(.white)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                        } else {
                            ProgressView()
                                .tint(.white)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                        }
                    }
                    .pipeline(ImageLoadingManager.shared.pipeline)
                }
                .onTapGesture {
                    isPresented = false
                }
                .id("viewer-\(imageUrl)")
#endif
            } else {
                // Fallback for when no image is available
                VStack {
                    Text("No image available")
                        .foregroundColor(.white)
                    Button("Close") {
                        isPresented = false
                    }
                    .padding()
                    .background(Color.gray.opacity(0.5))
                    .cornerRadius(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.8))
            }
        }
    }
}
    // MARK: - Pinned Post View
    struct PinnedPostView: View {
        let pinnedPost: AppBskyFeedDefs.PostView
        @Binding var path: NavigationPath
        @Environment(AppState.self) private var appState
        
        var body: some View {
            VStack(spacing: 0) {
                // Pinned badge indicator
                HStack(spacing: 6) {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Pinned Post")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                
                // Post content using PostView with appropriate parameters
                PostView(
                    post: pinnedPost,
                    grandparentAuthor: nil,
                    isParentPost: false,
                    isSelectable: true,
                    path: $path,
                    appState: appState,
                    isToYou: false
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: 600, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
    
    // MARK: - Feed Row View
    struct FeedRowView: View {
        let feed: AppBskyFeedDefs.GeneratorView
        
        var body: some View {
            HStack(spacing: 14) {
                // Feed image
                if let avatarURL = feed.avatar {
                    LazyImage(url: URL(string: avatarURL.uriString())) { state in
                        if let image = state.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(Color.secondary.opacity(0.3))
                        }
                    }
                    .frame(width: 50, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 50, height: 50)
                }
                
                // Feed info
                VStack(alignment: .leading, spacing: 4) {
                    Text(feed.displayName)
                        .appFont(AppTextRole.headline)
                        .lineLimit(1)
                    
                    Text("by @\(feed.creator.handle)")
                        .appFont(AppTextRole.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    
                    if let description = feed.description, !description.isEmpty {
                        Text(description)
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                    
                    // Show likes count if available
                    if feed.likeCount ?? 0 > 0 {
                        Text("\(feed.likeCount ?? 0) likes")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                // Chevron indicator
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
                    .appFont(AppTextRole.caption)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
    }
