import NukeUI
import OSLog
import Petrel
import SwiftUI
import Observation

/// A unified profile view that handles both current user and other user profiles
struct UnifiedProfileView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: ProfileViewModel
    @Binding var selectedTab: Int
    @Binding var lastTappedTab: Int?
    @Binding private var navigationPath: NavigationPath
    @State private var isShowingReportSheet = false
    @State private var isEditingProfile = false
    
    private let logger = Logger(subsystem: "blue.catbird", category: "UnifiedProfileView")
    
    // MARK: - Initialization
    
    /// Initialize to show the current user's profile (for tab navigation)
    init(appState: AppState, selectedTab: Binding<Int>, lastTappedTab: Binding<Int?>, path: Binding<NavigationPath>) {
        let currentUserDID = appState.currentUserDID ?? ""
        _viewModel = State(
            wrappedValue: ProfileViewModel(
                client: appState.atProtoClient,
                userDID: currentUserDID,
                currentUserDID: currentUserDID // Pass the current user's DID separately
            ))
        self._selectedTab = selectedTab
        self._lastTappedTab = lastTappedTab
        _navigationPath = path
    }
    
    /// Initialize to show another user's profile (via navigation)
    init(did: String, selectedTab: Binding<Int>, appState: AppState, path: Binding<NavigationPath>) {
        self.init(userDID: did, selectedTab: selectedTab, appState: appState, path: path)
    }
    
    /// Shared initializer for both cases
    private init(userDID: String, selectedTab: Binding<Int>, appState: AppState, path: Binding<NavigationPath>) {
        _viewModel = State(
            wrappedValue: ProfileViewModel(
                client: appState.atProtoClient,
                userDID: userDID,
                currentUserDID: appState.currentUserDID // This is the key change!
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
                profileContent(profile)
                    .sheet(isPresented: $isShowingReportSheet) {
                        if let profile = viewModel.profile,
                           let atProtoClient = appState.atProtoClient {
                            let reportingService = ReportingService(client: atProtoClient)
                            
                            ReportProfileView(
                                profile: profile,
                                reportingService: reportingService,
                                onComplete: { success in
                                    isShowingReportSheet = false
                                    // Optionally show feedback about success/failure
                                }
                            )
                        }
                    }
                    .sheet(isPresented: $isEditingProfile) {
                        EditProfileView(isPresented: $isEditingProfile, viewModel: viewModel)                    }
            } else {
                errorView
            }
        }
        .navigationTitle(viewModel.profile != nil ? "@\(viewModel.profile!.handle)" : "Profile")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await viewModel.loadProfile()
        }
        .toolbar {
            if let profile = viewModel.profile {
                ToolbarItem(placement: .principal) {
                    Text(profile.displayName ?? profile.handle)
                        .font(.headline)
                }
                
                // Only show the report option for other users' profiles
                if !viewModel.isCurrentUser {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            // Report button
                            Button(role: .destructive) {
                                showReportProfileSheet()
                            } label: {
                                Label("Report Profile", systemImage: "flag")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                    }
                }
            }
        }
        .onChange(of: lastTappedTab) { _, newValue in
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
        .task {
            await viewModel.loadProfile()
        }
    }
    
    private func showReportProfileSheet() {
        isShowingReportSheet = true
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
    private func profileContent(_ profile: AppBskyActorDefs.ProfileViewDetailed) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                // Profile header
                ProfileHeader(profile: profile, viewModel: viewModel, appState: appState, isEditingProfile: $isEditingProfile)
                    .frame(maxWidth: .infinity)
                    .contextMenu {
                        if !viewModel.isCurrentUser {
                            Button(role: .destructive) {
                                showReportProfileSheet()
                            } label: {
                                Label("Report User", systemImage: "flag")
                            }
                        }
                    }
                
                // Tab selector
                ProfileTabSelector(selectedTab: $viewModel.selectedProfileTab, onTabChange: { tab in
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
                        }
                    }
                })
                .padding(.top, 8)
                
                // Tab content
                tabContentView
            }
            .frame(maxWidth: .infinity) // Constrain to screen width
        }
        .refreshable {
            // Pull to refresh all content
            await viewModel.loadProfile()
            
            // Refresh the current tab's content
            switch viewModel.selectedProfileTab {
            case .posts: await viewModel.loadPosts()
            case .replies: await viewModel.loadReplies()
            case .media: await viewModel.loadMediaPosts()
            case .likes: await viewModel.loadLikes()
            case .lists: await viewModel.loadLists()
            }
        }
        .scrollIndicators(.visible)
    }
    
    // MARK: - Tab Content View
    
    @ViewBuilder
    private var tabContentView: some View {
        VStack(spacing: 0) {
            switch viewModel.selectedProfileTab {
            case .posts:
                postsList
            case .replies:
                repliesList
            case .media:
                mediaList
            case .likes:
                likesList
            case .lists:
                listsList
            }
        }
        .padding(.top, 8)
        .frame(width: UIScreen.main.bounds.width)
    }
    
    // Lists for different content types
    private var postsList: some View {
        postRows(posts: viewModel.posts, emptyMessage: "No posts") {
            await viewModel.loadPosts()
        }
    }
    
    private var repliesList: some View {
        postRows(posts: viewModel.replies, emptyMessage: "No replies") {
            await viewModel.loadReplies()
        }
    }
    
    private var mediaList: some View {
        postRows(posts: viewModel.postsWithMedia, emptyMessage: "No media posts") {
            await viewModel.loadMediaPosts()
        }
    }
    
    private var likesList: some View {
        postRows(posts: viewModel.likes, emptyMessage: "No liked posts") {
            await viewModel.loadLikes()
        }
    }
    
    @ViewBuilder
    private var listsList: some View {
        if viewModel.isLoading && viewModel.lists.isEmpty {
            ProgressView("Loading lists...")
                .frame(maxWidth: .infinity, minHeight: 100)
                .padding()
        } else if viewModel.lists.isEmpty {
            emptyContentView("No Lists", "This user hasn't created any lists yet.")
                .padding(.top, 40)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.lists, id: \.uri) { list in
                    Button {
                        navigationPath.append(NavigationDestination.list(list.uri))
                    } label: {
                        ListRow(list: list)
                    }
                    .buttonStyle(.plain)
                    
                    Divider()
                    
                    // Load more when reaching the end
                    if list == viewModel.lists.last && !viewModel.isLoadingMorePosts {
                        Color.clear.frame(height: 20)
                            .onAppear {
                                Task { await viewModel.loadLists() }
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
            .onAppear {
                if viewModel.lists.isEmpty && !viewModel.isLoading {
                    Task { await viewModel.loadLists() }
                }
            }
        }
    }
    
    // Reusable post rows builder
    @ViewBuilder
    private func postRows(posts: [AppBskyFeedDefs.FeedViewPost], emptyMessage: String, load: @escaping () async -> Void) -> some View {
        if viewModel.isLoading && posts.isEmpty {
            ProgressView("Loading...")
                .frame(maxWidth: .infinity, minHeight: 100)
                .padding()
        } else if posts.isEmpty {
            emptyContentView("No Content", emptyMessage)
                .padding(.top, 40)
                .onAppear {
                    Task { await load() }
                }
        } else {
            LazyVStack(spacing: 0) {
                // Post rows
                ForEach(posts, id: \.post.uri) { post in
                    Button {
                        navigationPath.append(NavigationDestination.post(post.post.uri))
                    } label: {
                        FeedPost(post: post, path: $navigationPath)
                            .frame(width: UIScreen.main.bounds.width)
                    }
                    .buttonStyle(.plain)
                    
                    Divider()
                    
                    // Load more when reaching the end
                    if post == posts.last && !viewModel.isLoadingMorePosts {
                        Color.clear.frame(height: 20)
                            .onAppear {
                                Task { await load() }
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
            .onAppear {
                if posts.isEmpty && !viewModel.isLoading {
                    Task { await load() }
                }
            }
        }
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
    
    @State private var showingFollowersSheet = false
    @State private var showingFollowingSheet = false
    @State private var isFollowButtonLoading = false
    // Track local follow state to handle UI update before server sync
    @State private var localIsFollowing: Bool = false
    
    private let avatarSize: CGFloat = 80
    private let bannerHeight: CGFloat = 150
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Banner and Avatar
            bannerView
            
            // Profile info content
            profileInfoContent
            
            Divider()
        }
        .frame(width: UIScreen.main.bounds.width) // Use exact screen width for consistency
        .sheet(isPresented: $showingFollowersSheet) {
            followersSheet
        }
        .sheet(isPresented: $showingFollowingSheet) {
            followingSheet
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
        ZStack(alignment: .bottomLeading) {
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
            
            // Avatar
            LazyImage(url: URL(string: profile.avatar?.uriString() ?? "")) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Circle().fill(Color.secondary.opacity(0.3))
                }
            }
            .frame(width: avatarSize, height: avatarSize)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 4))
            .padding(.leading)
            .offset(y: avatarSize/2)
        }
    }
    
    private var profileInfoContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Add space for the avatar overflow
            Spacer().frame(height: avatarSize/2 + 4)
            
            // Display name and handle
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.displayName ?? profile.handle)
                    .font(.title3)
                    .fontWeight(.bold)
                    .lineLimit(1)
                    // Set explicit width
                    .frame(width: UIScreen.main.bounds.width - 32, alignment: .leading)
                
                Text("@\(profile.handle)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    // Set explicit width
                    .frame(width: UIScreen.main.bounds.width - 32, alignment: .leading)
            }
            
            // Bio
            if let description = profile.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .lineLimit(5)
                    // Set explicit width
                    .frame(width: UIScreen.main.bounds.width - 32, alignment: .leading)
            }
            
            // Stats and follow button
            HStack(spacing: 16) {
                // Following
                Button(action: { showingFollowingSheet = true }) {
                    HStack(spacing: 4) {
                        Text("\(profile.followsCount ?? 0)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        
                        Text("Following")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                
                // Followers
                Button(action: { showingFollowersSheet = true }) {
                    HStack(spacing: 4) {
                        Text("\(profile.followersCount ?? 0)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        
                        Text("Followers")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                // Follow/Edit button based on whether this is the current user or not
                if viewModel.isCurrentUser {
                    editProfileButton
                } else {
                    followButton
                }
            }
            // Set explicit width for the HStack
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
                .background(Color.accentColor.opacity(0.1))
                .foregroundColor(.accentColor)
                .cornerRadius(16)
        }
    }
    
    @ViewBuilder
    private var followButton: some View {
        if isFollowButtonLoading {
            ProgressView()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        } else if localIsFollowing {
            Button(action: {
                Task {
                    isFollowButtonLoading = true
                    
                    // Optimistically update UI
                    localIsFollowing = false
                    
                    do {
                        // Perform unfollow operation on server
                        let success = try await appState.unfollow(did: profile.did)
                        
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
                        print("Error unfollowing: \(error.localizedDescription)")
                        localIsFollowing = true
                    }
                    
                    isFollowButtonLoading = false
                }
            }) {
                HStack {
                    Image(systemName: "checkmark")
                        .font(.footnote)
                    Text("Following")
                }
                .font(.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.1))
                .foregroundColor(.accentColor)
                .cornerRadius(16)
            }
        } else {
            Button(action: {
                Task {
                    isFollowButtonLoading = true
                    
                    // Optimistically update UI
                    localIsFollowing = true
                    
                    do {
                        // Perform follow operation
                        let success = try await appState.follow(did: profile.did)
                        
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
                        print("Error following: \(error.localizedDescription)")
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
    
    private var followersSheet: some View {
        NavigationStack {
            Text("Followers")
                .navigationTitle("Followers")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            showingFollowersSheet = false
                        }
                    }
                }
        }
    }
    
    private var followingSheet: some View {
        NavigationStack {
            Text("Following")
                .navigationTitle("Following")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            showingFollowingSheet = false
                        }
                    }
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
