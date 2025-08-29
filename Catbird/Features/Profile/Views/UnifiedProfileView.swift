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

/// A unified profile view that handles both current user and other user profiles using SwiftUI
struct UnifiedProfileView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var currentColorScheme
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
    
  private let logger = Logger(subsystem: "blue.catbird", category: "UnifiedProfileView")

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
      _viewModel = State(wrappedValue: viewModel)
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
    
    _viewModel = State(wrappedValue: viewModel)
    self._selectedTab = selectedTab
    self._lastTappedTab = lastTappedTab
    _navigationPath = path
  }

  init(did: String, selectedTab: Binding<Int>, appState: AppState, path: Binding<NavigationPath>) {
    self.init(userDID: did, selectedTab: selectedTab, appState: appState, path: path)
  }

  private init(
    userDID: String, selectedTab: Binding<Int>, appState: AppState, path: Binding<NavigationPath>
  ) {
    // Create ProfileViewModel with unique identity to prevent metadata cache conflicts
    let viewModel = ProfileViewModel(
      client: appState.atProtoClient,
      userDID: userDID,
      currentUserDID: appState.currentUserDID,
      stateInvalidationBus: appState.stateInvalidationBus
    )
    
    _viewModel = State(wrappedValue: viewModel)
    self._selectedTab = selectedTab
    self._lastTappedTab = .constant(nil)
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
        GeometryReader { outerGeometry in
            let screenWidth = outerGeometry.size.width
            let hPadding = horizontalPadding(for: screenWidth)
            let maxWidth = maxContentWidth(for: screenWidth)
            
            
            return ZStack {
                ScrollView {
                    VStack(spacing: 0) {
                        // Banner section
                        bannerHeaderView(profile: profile)
                            .flexibleHeaderContent()
                            .background(Color.accentColor.opacity(0.05))

                        // Content section
                        VStack(spacing: 0) {
                            ProfileHeader(
                                profile: profile,
                                viewModel: viewModel,
                                appState: appState,
                                isEditingProfile: $isEditingProfile,
                                path: $navigationPath,
                                screenWidth: outerGeometry.size.width,
                                hideAvatar: false
                            )
                            .padding(.horizontal, 16)
                            
                            followedBySection(profile: profile, geometry: outerGeometry)
                                .padding(.horizontal, 16)
                            
                            tabSelectorSection(geometry: outerGeometry)
                                .padding(.horizontal, 16)
                            
                            currentTabContentSection
                        }
                        .padding(.horizontal, hPadding)
                    }
                    .frame(maxWidth: maxWidth, alignment: .center)
                }
                .flexibleHeaderScrollView()
                .refreshable { await refreshAllContent() }
                .ignoresSafeArea(edges: .top)
                .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
            }
        }
    }
  // MARK: - Helper Views
  @ViewBuilder
  private func followedBySection(profile: AppBskyActorDefs.ProfileViewDetailed, geometry: GeometryProxy) -> some View {
    if !viewModel.isCurrentUser && !viewModel.knownFollowers.isEmpty {
      FollowedByView(
        knownFollowers: viewModel.knownFollowers,
        totalFollowersCount: profile.followersCount ?? 0,
        profileDID: profile.did.didString(),
        path: $navigationPath
      )
      // Padding handled by parent container
    }
  }
  
  @ViewBuilder
  private func tabSelectorSection(geometry: GeometryProxy) -> some View {
    ProfileTabSelector(
      path: $navigationPath,
      selectedTab: $viewModel.selectedProfileTab,
      onTabChange: handleTabChange
    )
    // Padding handled by parent container
  }
  
  private func handleTabChange(_ tab: ProfileTab) {
    Task {
      switch tab {
      case .posts:
        if viewModel.posts.isEmpty { await viewModel.loadPosts() }
      case .replies:
        if viewModel.replies.isEmpty { await viewModel.loadReplies() }
      case .media:
        if viewModel.postsWithMedia.isEmpty { await viewModel.loadMediaPosts() }
      case .more:
        break
      default:
        break
      }
    }
  }

  // MARK: - Responsive Layout Helpers
  private func horizontalPadding(for width: CGFloat) -> CGFloat {
    // Consistent padding for all screen sizes
    return 0
  }
  
  private func maxContentWidth(for screenWidth: CGFloat) -> CGFloat {
    // On larger screens (iPad/Mac), constrain to 600pt max width
    // On smaller screens (iPhone), use full available width
    return min(screenWidth, 600)
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
    case .posts: await viewModel.loadPosts()
    case .replies: await viewModel.loadReplies()
    case .media: await viewModel.loadMediaPosts()
    case .more: break
    default: break
    }
  }
  
  // MARK: - Tab Content Sections
    @ViewBuilder
    private var currentTabContentSection: some View {
        switch viewModel.selectedProfileTab {
        case .posts:
            postContentSection(
                posts: viewModel.posts,
                emptyMessage: "No posts",
                loadAction: viewModel.loadPosts
            )
        case .replies:
            postContentSection(
                posts: viewModel.replies,
                emptyMessage: "No replies",
                loadAction: viewModel.loadReplies
            )
        case .media:
            postContentSection(
                posts: viewModel.postsWithMedia,
                emptyMessage: "No media posts",
                loadAction: viewModel.loadMediaPosts
            )
        case .more:
            MoreView(path: $navigationPath)
        default:
            // Other tabs should only be accessible through the More menu
            EmptyView()
        }
    }
    
  // MARK: - Post Content Section (generalized for reuse)
  @ViewBuilder
  private func postContentSection(
    posts: [AppBskyFeedDefs.FeedViewPost],
    emptyMessage: String,
    loadAction: @escaping () async -> Void
  ) -> some View {
    LazyVStack(spacing: 8) {
      if viewModel.isLoading && posts.isEmpty {
        ProgressView("Loading...")
          .frame(maxWidth: .infinity, minHeight: 100)
          .padding()
      } else if posts.isEmpty {
        emptyContentView("No Content", emptyMessage)
          .padding(.top, 40)
          .onAppear {
            Task { await loadAction() }
          }
      } else {
        // Post rows
        ForEach(posts, id: \.post.uri) { post in
          Button {
            navigationPath.append(NavigationDestination.post(post.post.uri))
          } label: {
            VStack(spacing: 0) {
              EnhancedFeedPost(
                cachedPost: CachedFeedViewPost(feedViewPost: post),
                path: $navigationPath
              )
              Divider()
                .padding(.top, 8)
            }
          }
          .buttonStyle(.plain)
          .onAppear {
            // Load more when reaching the end, but only if not already loading
            if post == posts.last && !viewModel.isLoadingMorePosts {
              Task { await loadAction() }
            }
          }
        }
          
        // Loading indicator for pagination
        if viewModel.isLoadingMorePosts {
          ProgressView()
            .padding()
            .frame(maxWidth: .infinity)
        }
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

  private func initialLoad() async {
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
      if viewModel.posts.isEmpty {
        await viewModel.loadPosts()
      }
    case .replies:
      if viewModel.replies.isEmpty {
        await viewModel.loadReplies()
      }
    case .media:
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
    ZStack(alignment: .center) {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
      } else {
        Rectangle()
          .fill(Color.accentColor.opacity(0.25))
      }
    }
    .contentShape(Rectangle())
    .accessibilityLabel("Profile banner")
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
      if viewModel.isLoading && viewModel.profile == nil {
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
        Button {
          showAddToListSheet(profile)
        } label: {
          Label("Add to List", systemImage: "list.bullet.rectangle")
        }
        Divider()
      }
      
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
    } label: {
      Image(systemName: "ellipsis.circle")
    }
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
                    .padding(.leading, horizontalPadding)
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
        }
        .onChange(of: profile) { _, newProfile in
            // Update local follow state when profile changes
            localIsFollowing = newProfile.viewer?.following != nil
        }
    }
    
    private var avatarView: some View {
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
    
    private var profileInfoContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top section with edit/follow button aligned to trailing edge
            HStack(alignment: .top) {
                Spacer()
                
                // Follow/Edit button at the trailing edge
                if viewModel.isCurrentUser {
                    editProfileButton
                        .allowsHitTesting(true)
                } else {
                    followButton
                        .allowsHitTesting(true)
                }
            }
            .padding(.top, 4)
            
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
            if let description = profile.description, !description.isEmpty {
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
}

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
                        LazyImage(url: URL(string: image)) { state in
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
                        .priority(.high)
                        .processors([
                            ImageProcessors.AsyncImageDownscaling(targetSize: CGSize(width: geometry.size.width, height: geometry.size.height))
                        ])
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
                    LazyImage(url: URL(string: imageUrl)) { state in
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
                    .priority(.high)
                    .processors([
                        ImageProcessors.AsyncImageDownscaling(targetSize: CGSize(width: geometry.size.width, height: geometry.size.height))
                    ])
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
    

