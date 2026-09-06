import AppIntents
import CatbirdMLSCore
import Foundation
import OSLog
import Petrel
import SwiftUI

/// A unified profile view that handles both current user and other user profiles using SwiftUI
struct UnifiedProfileView: View {
  private static let maxResponsiveContentWidth: CGFloat = 600
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var currentColorScheme
  @State private var viewModel: ProfileViewModel
  @Binding var selectedTab: Int
  @Binding var lastTappedTab: Int?
  @Binding private var navigationPath: NavigationPath
  @State private var isShowingReportSheet = false
  @State private var isEditingProfile = false
  @State private var isShowingAccountSwitcher = false
  @State private var isShowingUnblockConfirmation = false
  @State private var isShowingBlockSheet = false
  @State private var isShowingLiveStatusEditor = false
  @State private var isShowingLabelsOnMe = false
  @State private var isShowingMuteConfirmation = false
  @State private var isShowingAddToListSheet = false
  @State private var isShowingCopilot = false
  @State private var pendingDedicatedProposal: CopilotProposal?
  @State private var isShowingSmartFilterEditor = false
  @State private var isBlocking = false
  /// Conversations the current user would auto-leave if they block this profile.
  /// Populated just before presenting the block-confirmation alert so the
  /// dialog can warn "you'll leave N shared conversations".
  @State private var blockAffectedConvos: [MLSConversationSnapshot] = []
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

  // MARK: - Initialization
  init(
    appState: AppState,
    selectedTab: Binding<Int>,
    lastTappedTab: Binding<Int?>,
    path: Binding<NavigationPath>
  ) {
    let viewModel = ProfileViewModel(
      client: appState.atProtoClient,
      userDID: appState.userDID,
      currentUserDID: appState.userDID,
      stateInvalidationBus: appState.stateInvalidationBus
    )

    self._viewModel = State(initialValue: viewModel)
    self._selectedTab = selectedTab
    self._lastTappedTab = lastTappedTab
    _navigationPath = path
  }

  init(did: String, selectedTab: Binding<Int>, appState: AppState, path: Binding<NavigationPath>) {
    let viewModel = ProfileViewModel(
      client: appState.atProtoClient,
      userDID: did,
      currentUserDID: appState.userDID,
      stateInvalidationBus: appState.stateInvalidationBus
    )
    
    self._viewModel = State(initialValue: viewModel)
    self._selectedTab = selectedTab
    self._lastTappedTab = Binding.constant(nil)
    _navigationPath = path
  }

  var body: some View {
    GeometryReader { proxy in
      swiftUIImplementation(contentMaxWidth: contentMaxWidth(for: proxy.size.width))
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
    }
  }
  
  private func contentMaxWidth(for availableWidth: CGFloat) -> CGFloat {
    min(max(availableWidth, 0), Self.maxResponsiveContentWidth)
  }

  @ViewBuilder
  private func swiftUIImplementation(contentMaxWidth: CGFloat) -> some View {
    profileViewConfiguration(contentMaxWidth: contentMaxWidth)
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
  


  // MARK: - Lists Content Section
  @ViewBuilder
  private var listsContentSection: some View {
    if viewModel.isLoading && viewModel.lists.isEmpty {
      ProgressView("Loading lists...")
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding()
        .listRowSeparator(.hidden)
    } else if viewModel.lists.isEmpty {
      ProfileEmptyStateView(
        title: "No Lists",
        message: "This user hasn't created any lists yet.",
        isCurrentUser: viewModel.isCurrentUser
      )
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
      ProfileEmptyStateView(
        title: "No Starter Packs",
        message: "This user hasn't created any starter packs yet.",
        isCurrentUser: viewModel.isCurrentUser
      )
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
      ProfileEmptyStateView(
        title: "No Feeds",
        message: "This user hasn't created any feeds yet.",
        isCurrentUser: viewModel.isCurrentUser
      )
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
        requestMuteToggle()
      } label: {
        if isMuting {
          Label("Unmute User", systemImage: "speaker.wave.2")
        } else {
          Label("Mute User", systemImage: "speaker.slash")
        }
      }

      Button(role: .destructive) {
        Task { await prepareBlockConfirmation() }
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
  private var unblockAlertButtons: some View {
    Button("Cancel", role: .cancel) {}

    Button("Unblock", role: .destructive) {
      Task { await performUnblock() }
    }
  }

  @ViewBuilder
  private var unblockAlertMessage: some View {
    if let profile = viewModel.profile {
      Text(BlockConfirmation.unblockMessage(handle: profile.handle.description))
    }
  }

  private func performBlock() async {
    await performBlockMutation(blocking: true)
  }

  private func performUnblock() async {
    await performBlockMutation(blocking: false)
  }

  private func performBlockMutation(blocking: Bool) async {
    guard let profile = viewModel.profile, !viewModel.isCurrentUser else { return }
    let did = profile.did.didString()
    let previousState = isBlocking
    isBlocking = blocking
    do {
      if let coord = appState.mlsBlockCoordinator {
        if blocking {
          try await coord.block(did: did)
        } else {
          try await coord.unblock(did: did)
        }
      } else {
        let success = blocking ? try await appState.block(did: did) : try await appState.unblock(did: did)
        if !success {
          isBlocking = previousState
        }
      }
    } catch {
      isBlocking = previousState
      logger.error("Failed to \(blocking ? "block" : "unblock") user: \(error.localizedDescription)")
    }
  }

  /// Compute the list of MLS conversations that would be left when blocking
  /// the displayed profile, then present the confirmation sheet or alert.
  private func prepareBlockConfirmation() async {
    if isBlocking {
      isShowingUnblockConfirmation = true
    } else {
      if let profile = viewModel.profile,
         let coord = appState.mlsBlockCoordinator {
        let did = profile.did.didString()
        blockAffectedConvos = await coord.affectedConversations(for: did)
      } else {
        blockAffectedConvos = []
      }
      isShowingBlockSheet = true
    }
  }

  /// Refreshes the live block state for a Copilot proposal and opens the
  /// block/unblock confirmation only when the state matches the requested
  /// action (`confirmWhenBlocking`).
  private func confirmBlockAction(did: String, confirmWhenBlocking: Bool) {
    Task {
      do {
        let state = try await appState.graphManager.freshRelationshipState(did: did)
        self.isBlocking = state.blocking
        if state.blocking == confirmWhenBlocking {
          await prepareBlockConfirmation()
        }
      } catch {
        logger.error("Failed to verify block state before confirmation: \(error.localizedDescription)")
        appState.toastManager.show(
          ToastItem(message: "Failed to verify block status", icon: "exclamationmark.triangle.fill")
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
      if let profile = viewModel.profile, !viewModel.isCurrentUser {
        let did = profile.did.didString()
        if let viewer = profile.viewer {
          self.isBlocking = viewer.blocking != nil
        } else {
          self.isBlocking = await appState.isBlocking(did: did)
        }
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

  private func showReportProfileSheet() {
    isShowingReportSheet = true
  }

  private func showAddToListSheet(_ profile: AppBskyActorDefs.ProfileViewDetailed) {
    profileForAddToList = profile
    isShowingAddToListSheet = true
  }

  @MainActor
  private func handleDedicatedProposal(_ proposal: CopilotProposal) {
    guard let profile = viewModel.profile else { return }
    let targetDID = profile.did.didString()

    switch proposal {
    case .reportActor(let did):
      guard did == targetDID else { return }
      showReportProfileSheet()

    case .addActorToList(let did):
      guard did == targetDID else { return }
      showAddToListSheet(profile)

    case .blockActor(let did):
      guard did == targetDID else { return }
      confirmBlockAction(did: did, confirmWhenBlocking: false)

    case .unblockActor(let did):
      guard did == targetDID else { return }
      confirmBlockAction(did: did, confirmWhenBlocking: true)

    case .preparePostDraft(let text):
      appState.presentPostComposer(initialText: text)

    default:
      break
    }
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

  private func requestMuteToggle() {
    if !isMuting && DestructiveActionConfirmation.shouldConfirm(
      isEnabled: appState.appSettings.confirmBeforeActions
    ) {
      isShowingMuteConfirmation = true
    } else {
      toggleMute()
    }
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
    
    
  // MARK: - View Configuration
  @ViewBuilder
  private func profileNavigationConfiguration(contentMaxWidth: CGFloat) -> some View {
    Group {
      if !hasAttemptedLoad || (viewModel.isLoading && viewModel.profile == nil) {
        loadingView
      } else if let profile = viewModel.profile {
        UnifiedProfileContentView(
          profile: profile,
          viewModel: viewModel,
          appState: appState,
          contentMaxWidth: contentMaxWidth,
          hasAttemptedLoadPosts: hasAttemptedLoadPosts,
          hasAttemptedLoadReplies: hasAttemptedLoadReplies,
          hasAttemptedLoadMedia: hasAttemptedLoadMedia,
          isEditingProfile: $isEditingProfile,
          navigationPath: $navigationPath,
          refreshAllContent: refreshAllContent,
          onTabChange: handleTabChange,
          prepareBlockConfirmation: prepareBlockConfirmation
        )
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
  }

  @ViewBuilder
  private func profilePresentationConfiguration(contentMaxWidth: CGFloat) -> some View {
    profileNavigationConfiguration(contentMaxWidth: contentMaxWidth)
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
          .environment(AppStateManager.shared)
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
      .sheet(isPresented: $isShowingCopilot) {
        if let profile = viewModel.profile {
          let context = CopilotContext.profile(
            did: profile.did.didString(),
            handle: profile.handle.description,
            displayName: profile.displayName
          )
          CatbirdCopilotSheet(
            context: context,
            onConfirmedAction: { proposal in
              try await CopilotProposalCoordinator.executeConfirmed(
                proposal,
                context: context,
                expectedAccountDID: appState.userDID,
                appState: appState
              )
              await viewModel.loadProfile()
            },
            onDedicatedAction: { proposal in
              pendingDedicatedProposal = proposal
            }
          )
        }
      }
      .onChange(of: isShowingCopilot) { wasShowing, isShowing in
        if wasShowing && !isShowing, let proposal = pendingDedicatedProposal {
          pendingDedicatedProposal = nil
          handleDedicatedProposal(proposal)
        }
      }
      .sheet(isPresented: $isShowingSmartFilterEditor) {
        if let profile = viewModel.profile {
          SmartFilterEditorSheet(
            targetActorDID: profile.did.didString(),
            actorName: "@\(profile.handle.description)"
          )
        }
      }
      .sheet(isPresented: $isShowingBlockSheet) {
        if let profile = viewModel.profile {
          let basic = AppBskyActorDefs.ProfileViewBasic(
            did: profile.did,
            handle: profile.handle,
            displayName: profile.displayName,
            pronouns: profile.pronouns,
            avatar: profile.avatar,
            associated: profile.associated,
            viewer: profile.viewer,
            labels: profile.labels,
            createdAt: profile.createdAt,
            verification: profile.verification,
            status: profile.status,
            debug: nil
          )
          BlockAccountView(
            profile: basic,
            mlsAffectedConvoCount: blockAffectedConvos.count,
            onConfirmBlock: {
              await performBlock()
            }
          )
        }
      }
      .sheet(isPresented: $isShowingLiveStatusEditor, onDismiss: {
        Task {
          await viewModel.loadProfile()
        }
      }) {
        LiveStatusEditorSheet()
      }
      .sheet(isPresented: $isShowingLabelsOnMe) {
        if let profile = viewModel.profile,
           let client = appState.atProtoClient {
          let reportingService = ReportingService(client: client)
          LabelsOnMeView(
            labels: profile.labels ?? [],
            targetDescription: "Account @\(profile.handle.description)",
            viewerDID: appState.userDID,
            reportingService: reportingService
          )
        }
      }
  }

  @ViewBuilder
  private func profileViewConfiguration(contentMaxWidth: CGFloat) -> some View {
    profilePresentationConfiguration(contentMaxWidth: contentMaxWidth)
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
      .alert("Unblock User", isPresented: $isShowingUnblockConfirmation) {
        unblockAlertButtons
      } message: {
        unblockAlertMessage
      }
      .alert("Mute User", isPresented: $isShowingMuteConfirmation) {
        Button("Cancel", role: .cancel) { }
        Button("Mute", role: .destructive) { toggleMute() }
      } message: {
        if let profile = viewModel.profile {
          Text("Mute @\(profile.handle)? You won't see their posts and replies in your feeds.")
        }
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
        Task {
          await appState.liveStatusManager.fetchCurrentStatus()
          isShowingLiveStatusEditor = true
        }
      } label: {
        if appState.liveStatusManager.hasActiveLiveStatus {
          Label("Edit Live", systemImage: "antenna.radiowaves.left.and.right")
        } else {
          Label("Go Live", systemImage: "antenna.radiowaves.left.and.right")
        }
      }

      Button {
        isShowingLabelsOnMe = true
      } label: {
        Label("Labels on your account", systemImage: "tag")
      }

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
            isShowingCopilot = true
          } label: {
            Label("Ask Catbird", systemImage: "sparkles")
          }

          Button {
            isShowingSmartFilterEditor = true
          } label: {
            Label("Filter Posts…", systemImage: "line.3.horizontal.decrease.circle")
          }

          Divider()

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
            requestMuteToggle()
          } label: {
            Label(isMuting ? "Unmute User" : "Mute User",
                  systemImage: isMuting ? "speaker.wave.2" : "speaker.slash")
          }
          
          Button(role: .destructive) {
            Task { await prepareBlockConfirmation() }
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
      let screenW = size.width
      _layoutDebugLogger.debug("[\(tag)] width=\(size.width, privacy: .public), screen=\(screenW, privacy: .public), overflow=\(size.width > screenW ? "YES" : "no", privacy: .public)")
    }
  }
}
#endif

// MARK: - Preview
// #Preview {
//    @Previewable @Environment(AppState.self) var appState
//  let appState = appState
//    NavigationStack {
//    UnifiedProfileView(
//      appState: appState,
//      selectedTab: .constant(3),
//      lastTappedTab: .constant(nil),
//      path: .constant(NavigationPath())
//    )
//  }
//  .environment(appState)
// }

    

#Preview {
    AsyncPreviewContent { appState in
        
        NavigationStack {
            UnifiedProfileView(
                appState: appState,
                selectedTab: .constant(0),
                lastTappedTab: .constant(nil),
                path: .constant(NavigationPath())
            )
        }
    }
}
