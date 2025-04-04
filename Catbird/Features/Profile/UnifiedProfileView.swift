import NukeUI
import OSLog
import Observation
import Petrel
import SwiftUI
import LazyPager
import Nuke
/// A unified profile view that handles both current user and other user profiles
struct UnifiedProfileView: View {
  @Environment(AppState.self) private var appState
  @State private var viewModel: ProfileViewModel
  @Binding var selectedTab: Int
  @Binding var lastTappedTab: Int?
  @Binding private var navigationPath: NavigationPath
  @State private var isShowingReportSheet = false
  @State private var isEditingProfile = false
  @State private var isShowingAccountSwitcher = false
  @State private var isShowingBlockConfirmation = false
  @State private var isBlocking = false
  @State private var isMuting = false
    
  private let logger = Logger(subsystem: "blue.catbird", category: "UnifiedProfileView")

  // MARK: - Initialization (keeping all initializers)
  init(
    appState: AppState, selectedTab: Binding<Int>, lastTappedTab: Binding<Int?>,
    path: Binding<NavigationPath>
  ) {
    let currentUserDID = appState.currentUserDID ?? ""
    _viewModel = State(
      wrappedValue: ProfileViewModel(
        client: appState.atProtoClient,
        userDID: currentUserDID,
        currentUserDID: currentUserDID
      ))
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
    _viewModel = State(
      wrappedValue: ProfileViewModel(
        client: appState.atProtoClient,
        userDID: userDID,
        currentUserDID: appState.currentUserDID
      ))
    self._selectedTab = selectedTab
    self._lastTappedTab = .constant(nil)
    _navigationPath = path
  }

  var body: some View {
    Group {
      if viewModel.isLoading && viewModel.profile == nil {
        loadingView
      } else if let profile = viewModel.profile {
          // Show account status bar only for current user (outside of List)
//          if viewModel.isCurrentUser {
//            accountStatusBar
//          }
//                .padding(0)

          // List contains all content
          List {
            // Profile header as first section
              
              Section {
                  ProfileHeader(
                      profile: profile,
                      viewModel: viewModel,
                      appState: appState,
                      isEditingProfile: $isEditingProfile,
                      path: $navigationPath
                  )
                  // 1. Define specific insets for the header row
                  .listRowInsets(EdgeInsets())
                  // 2. Apply padding below the header if needed
                  .padding(.bottom, 8)
                  // 3. Define the background shape for tap consumption
//                  .contentShape(Rectangle())
                  // 4. Consume taps on the background shape
//                  .onTapGesture {}
                  // 5. Explicitly allow hit testing for header content (buttons)
                  //    (May not be strictly necessary if buttons work, but reinforces)
//                  .allowsHitTesting(true)
              }
              // --- Modifiers applied ONLY to the Section ---
              .listRowSeparator(.hidden)
              .buttonStyle(.plain) // <--- Prevent List from treating row as button

              
            // Tab selector section
            Section {
              ProfileTabSelector(
                path: $navigationPath,
                selectedTab: $viewModel.selectedProfileTab,
                onTabChange: { tab in
                  Task {
                    switch tab {
                    case .posts:
                      if viewModel.posts.isEmpty { await viewModel.loadPosts() }
                    case .replies:
                      if viewModel.replies.isEmpty { await viewModel.loadReplies() }
                    case .media:
                      if viewModel.postsWithMedia.isEmpty { await viewModel.loadMediaPosts() }
                    case .likes:
                      if viewModel.likes.isEmpty { await viewModel.loadLikes() }
                    case .lists:
                      if viewModel.lists.isEmpty { await viewModel.loadLists() }
                    case .starterPacks:
                      if viewModel.starterPacks.isEmpty { await viewModel.loadStarterPacks() }
                    case .more:
                      break
                    }
                  }
                }
              )
            }
            .listRowSeparator(.hidden)
            .padding(.vertical, 0)
            .listSectionSpacing(0)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
              
            // Content section based on selected tab
            currentTabContentSection
          }
          .environment(\.defaultMinListHeaderHeight, 0) // <--- Try enforcing min header height
          .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listSectionSpacing(0)
          .listStyle(.plain)
          .refreshable {
            // Pull to refresh all content - using a single task
            await refreshAllContent()
          }
        
        .sheet(isPresented: $isShowingReportSheet) {
          if let profile = viewModel.profile,
            let atProtoClient = appState.atProtoClient
          {
            let reportingService = ReportingService(client: atProtoClient)

            ReportProfileView(
              profile: profile,
              reportingService: reportingService,
              onComplete: { success in
                isShowingReportSheet = false
              }
            )
          }
        }
        .sheet(isPresented: $isEditingProfile) {
          EditProfileView(isPresented: $isEditingProfile, viewModel: viewModel)
        }
        .sheet(isPresented: $isShowingAccountSwitcher) {
          AccountSwitcherView()
        }
      } else {
        errorView
      }
    }
    .navigationTitle(viewModel.profile != nil ? "@\(viewModel.profile!.handle)" : "Profile")
    .navigationBarTitleDisplayMode(.inline)
    .navigationDestination(for: ProfileNavigationDestination.self) { destination in
      switch destination {
      case .section(let tab):
        ProfileSectionView(viewModel: viewModel, tab: tab, path: $navigationPath)
      case .followers(let did):
          FollowersView(userDID: did, client: appState.atProtoClient, path: $navigationPath)
      case .following(let did):
          FollowingView(userDID: did, client: appState.atProtoClient, path: $navigationPath)
      }
    }
    .toolbar {
      if let profile = viewModel.profile {
        ToolbarItem(placement: .principal) {
          Text(profile.displayName ?? profile.handle.description)
            .font(.headline)
        }

        // Only show the report option for other users' profiles
        if viewModel.isCurrentUser {
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              Button {
                isShowingAccountSwitcher = true
              } label: {
                Label("Switch Account", systemImage: "person.crop.circle.badge.plus")
              }

              Button {
                Task {
                  try? await appState.handleLogout()
                }
              } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
              }
            } label: {
              Image(systemName: "ellipsis.circle")
            }
          }
        } else {
          ToolbarItem(placement: .primaryAction) {
            Menu {
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
            } label: {
              Image(systemName: "ellipsis.circle")
            }
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
      await initialLoad()
    }
  }

  // MARK: - New helper function for refreshing content
  private func refreshAllContent() async {
    // First refresh profile
    await viewModel.loadProfile()
    
    // Then refresh current tab content
    switch viewModel.selectedProfileTab {
    case .posts: await viewModel.loadPosts()
    case .replies: await viewModel.loadReplies()
    case .media: await viewModel.loadMediaPosts()
    case .likes: await viewModel.loadLikes()
    case .lists: await viewModel.loadLists()
    case .starterPacks: await viewModel.loadStarterPacks()
    case .more: break
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
        case .likes:
            postContentSection(
                posts: viewModel.likes,
                emptyMessage: "No liked posts",
                loadAction: viewModel.loadLikes
            )
        case .lists:
            listsContentSection
        case .starterPacks:
            starterPacksContentSection
        case .more:
            MoreView(path: $navigationPath)
        }
    }
    
  // MARK: - Post Content Section (generalized for reuse)
  @ViewBuilder
  private func postContentSection(
    posts: [AppBskyFeedDefs.FeedViewPost],
    emptyMessage: String,
    loadAction: @escaping () async -> Void
  ) -> some View {
    if viewModel.isLoading && posts.isEmpty {
      ProgressView("Loading...")
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding()
        .listRowSeparator(.hidden)
    } else if posts.isEmpty {
      emptyContentView("No Content", emptyMessage)
        .padding(.top, 40)
        .listRowSeparator(.hidden)
        .onAppear {
          Task { await loadAction() }
        }
    } else {
      // Post rows
      ForEach(posts, id: \.post.uri) { post in
        Button {
          navigationPath.append(NavigationDestination.post(post.post.uri))
        } label: {
          FeedPost(post: post, path: $navigationPath)
            .frame(width: UIScreen.main.bounds.width)
        }
        .buttonStyle(.plain)
        .applyListRowModifiers(id: post.id)
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
          .listRowSeparator(.hidden)
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
        .applyListRowModifiers(id: list.uri.uriString())
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
              .applyListRowModifiers(id: pack.uri.uriString())
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

  // MARK: - Context Menu for Profile
  @ViewBuilder
  private func profileContextMenu(_ profile: AppBskyActorDefs.ProfileViewDetailed) -> some View {
    if !viewModel.isCurrentUser {
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
    await viewModel.loadProfile()
    // Check if user has multiple accounts

    // Check muting and blocking status
    if let did = viewModel.profile?.did.didString(), !viewModel.isCurrentUser {
      self.isBlocking = await appState.isBlocking(did: did)
      self.isMuting = await appState.isMuting(did: did)
    }
  }

  // MARK: - Keep existing functionality
  // Keeping all existing functions like showReportProfileSheet, toggleMute, toggleBlock, etc.
  
  private func showReportProfileSheet() {
    isShowingReportSheet = true
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
  

  // MARK: - View Components
  private var loadingView: some View {
    VStack {
      ProgressView()
        .scaleEffect(1.5)
      Text("Loading profile...")
        .foregroundColor(.secondary)
        .padding(.top)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var errorView: some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 48))
        .foregroundColor(.orange)

      Text("Couldn't Load Profile")
        .font(.title2)
        .fontWeight(.semibold)

      if let error = viewModel.error {
        Text(error.localizedDescription)
          .font(.subheadline)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal)
      }

      Button(action: {
        Task {
          await viewModel.loadProfile()
        }
      }) {
        Text("Try Again")
          .padding(.horizontal, 24)
          .padding(.vertical, 10)
          .background(Color.accentColor)
          .foregroundColor(.white)
          .cornerRadius(8)
      }
      .padding(.top, 8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }



    
  @ViewBuilder
  private func emptyContentView(_ title: String, _ message: String) -> some View {
    VStack(spacing: 16) {
      Spacer()

      Image(systemName: "square.stack.3d.up.slash")
        .font(.system(size: 48))
        .foregroundColor(.secondary)

      Text(title)
        .font(.title3)
        .fontWeight(.semibold)

      Text(message)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)

      Spacer()
    }
    .frame(maxWidth: .infinity, minHeight: 300)
  }
}

// MARK: - Profile Header
struct ProfileHeader: View {
    let profile: AppBskyActorDefs.ProfileViewDetailed
    let viewModel: ProfileViewModel
    let appState: AppState  // Added AppState to use GraphManager
    @Binding var isEditingProfile: Bool
    @Binding var path: NavigationPath
    
    @State private var showingFollowersSheet = false
    @State private var showingFollowingSheet = false
    @State private var isFollowButtonLoading = false
    // Track local follow state to handle UI update before server sync
    @State private var localIsFollowing: Bool = false
    @State private var isShowingProfileImageViewer = false
    @Namespace private var imageTransition
    
    private let avatarSize: CGFloat = 80
    private let bannerHeight: CGFloat = 150
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Banner and Avatar
            bannerView
            
            // Profile info content
            profileInfoContent
            
            // Divider()
        }
        .frame(width: UIScreen.main.bounds.width)  // Use exact screen width for consistency
//        .sheet(isPresented: $showingFollowersSheet) {
//            followersSheet
//        }
//        .sheet(isPresented: $showingFollowingSheet) {
//            followingSheet
//        }
        .fullScreenCover(isPresented: $isShowingProfileImageViewer) {
            if let profile = viewModel.profile, let avatarURI = profile.avatar?.uriString() {
                ProfileImageViewerView(avatar: profile.avatar, isPresented: $isShowingProfileImageViewer, namespace: imageTransition)
                    .navigationTransition(.zoom(sourceID: avatarURI, in: imageTransition))
            }
        }
        .onAppear {
            // Initialize local follow state based on profile
            localIsFollowing = profile.viewer?.following != nil
        }
        .onChange(of: profile) { _, newProfile in
            // Update local follow state when profile changes
            localIsFollowing = newProfile.viewer?.following != nil
        }
    }
    
    private var bannerView: some View {
        ZStack(alignment: .bottom) {
            // Banner
            Group {
                if let bannerURL = profile.banner?.uriString() {
                    LazyImage(url: URL(string: bannerURL)) { state in
                        if let image = state.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(Color.accentColor.opacity(0.3))
                        }
                    }
                } else {
                    Rectangle().fill(Color.accentColor.opacity(0.3))
                }
            }
            .frame(width: UIScreen.main.bounds.width, height: bannerHeight)
            .clipped()
            
            HStack(alignment: .bottom) {
                // Avatar
                LazyImage(url: URL(string: profile.avatar?.uriString() ?? "")) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Circle().fill(Color.secondary.opacity(0.3))
                    }
                }
                .matchedTransitionSource(id: profile.avatar?.uriString() ?? "", in: imageTransition)
                .allowsHitTesting(true)
                .onTapGesture {
                    isShowingProfileImageViewer = true
                }
                .frame(width: avatarSize, height: avatarSize)
                .clipShape(Circle())
                .background(
                    Circle()
                        .stroke(Color(.systemBackground), lineWidth: 4)
                        .scaleEffect((avatarSize + 4) / avatarSize)
                )
                .offset(y: avatarSize / 2)
                .padding(.leading, 12)
                
                Spacer()
            }
            .frame(width: UIScreen.main.bounds.width)
        }
    }
    
    private var profileInfoContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Add space for the avatar overflow and position follow button
            ZStack(alignment: .trailing) {
                // Space for avatar overflow
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: avatarSize / 2 + 4)
                
                // Follow/Edit button at the trailing edge
                if viewModel.isCurrentUser {
                    editProfileButton
                        .allowsHitTesting(true)
                } else {
                    followButton
                        .allowsHitTesting(true)
                }
            }
            
            // Display name and handle
            VStack(alignment: .leading, spacing: 4) {
                    
                    Text(profile.displayName ?? profile.handle.description)
                        .font(.title3)
                        .fontWeight(.bold)
                        .lineLimit(nil)
                        .frame(width: UIScreen.main.bounds.width - 32, alignment: .leading)

                    
            HStack(spacing: 0) {

                Text("@\(profile.handle)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                if profile.viewer?.followedBy != nil {
                    FollowsBadgeView()
                        .padding(.leading, 4)
                }
            }
            .frame(width: UIScreen.main.bounds.width - 32, alignment: .leading)


            }
            
            // Bio
            if let description = profile.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .lineLimit(5)
                    .frame(width: UIScreen.main.bounds.width - 32, alignment: .leading)
            }
            
            // Stats
            HStack(spacing: 16) {
                // Following
                Button(action: {
                    
                    path.append(ProfileNavigationDestination.following(profile.did.didString()))
                    
                }) {
                    HStack(spacing: 4) {
                        Text("\(profile.followsCount ?? 0)")
                            .fixedSize(horizontal: true, vertical: false)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        
                        Text("Following")
                            .fixedSize(horizontal: true, vertical: false)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                
                // Followers
                Button(action: {
                    path.append(ProfileNavigationDestination.followers(profile.did.didString()))
                }) {
                    HStack(spacing: 4) {
                        Text("\(profile.followersCount ?? 0)")
                            .fixedSize(horizontal: true, vertical: false)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        
                        Text("Followers")
                            .fixedSize(horizontal: true, vertical: false)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                
                Spacer()
            }
            .frame(width: UIScreen.main.bounds.width - 32)
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
    }
    
    private var editProfileButton: some View {
        Button(action: {
            isEditingProfile = true
        }) {
            Text("Edit Profile")
                .font(.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            //        .background(Color.accentColor.opacity(0.7))
                .foregroundColor(.accentColor)
                .cornerRadius(16)
        }
        .overlay {
            Capsule().stroke(Color.accentColor, lineWidth: 1.5)
        }
        
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
                        .font(.footnote)
                    Text("Blocked")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .font(.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundColor(.red)
                .cornerRadius(16)
            }
            .overlay {
                Capsule().stroke(Color.red, lineWidth: 1.5)
            }
        } else if profile.viewer?.muted == true {
            // Show muted state
            Button(action: {
                // Do nothing - muting handled in parent view
            }) {
                HStack {
                    Image(systemName: "speaker.slash")
                        .font(.footnote)
                    Text("Muted")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .font(.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .foregroundColor(.orange)
                .cornerRadius(16)
            }
            .overlay {
                Capsule().stroke(Color.orange, lineWidth: 1.5)
            }
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
                        .font(.footnote)
                    Text("Following")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .font(.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .foregroundColor(.accentColor)
                .cornerRadius(16)
            }
            .overlay {
                Capsule().stroke(Color.accentColor, lineWidth: 1.5)
            }
            
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
                        .font(.footnote)
                    Text("Follow")
                }
                .font(.subheadline)
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
#Preview {
  let appState = AppState()
  return NavigationStack {
    UnifiedProfileView(
      appState: appState,
      selectedTab: .constant(3),
      lastTappedTab: .constant(nil),
      path: .constant(NavigationPath())
    )
  }
  .environment(appState)
}

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
