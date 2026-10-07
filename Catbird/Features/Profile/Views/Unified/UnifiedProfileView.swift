import AppIntents
import Foundation
import OSLog
import Petrel
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A unified profile view that handles both current user and other user profiles using SwiftUI
struct UnifiedProfileView: View {
  @Environment(SceneNavigationContext.self) private var sceneContext
  #if os(macOS)
  private static let maxResponsiveContentWidth: CGFloat = 700
  #else
  private static let maxResponsiveContentWidth: CGFloat = 600
  #endif
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var currentColorScheme
  @State private var viewModel: ProfileViewModel
  @Binding var selectedTab: Int
  @Binding var lastTappedTab: Int?
  @Binding private var navigationPath: NavigationPath
  @State private var isShowingReportSheet = false
  private struct PendingGermHandoff {
    let action: GermProfileAction
    let revision: UInt64
  }
  @State private var pendingGermAction: PendingGermHandoff?
  @State private var germLaunchError = false
  @State private var germLaunchAttemptID: UUID?
  @State private var isEditingProfile = false
  @State private var isShowingAccountSwitcher = false
  @State private var isShowingUnblockConfirmation = false
  @State private var isShowingBlockSheet = false
  @State private var isShowingLabelsOnMe = false
  @State private var isShowingMuteConfirmation = false
  @State private var isShowingSignOutConfirmation = false
  @State private var isShowingAddToListSheet = false
  @State private var isShowingCopilot = false
  @State private var pendingDedicatedProposal: CopilotProposal?
  @State private var isShowingSmartFilterEditor = false
  @State private var isBlocking = false
  @State private var isMuting = false
  @State private var profileForAddToList: AppBskyActorDefs.ProfileViewDetailed?
  @State private var hasAttemptedLoad = false
  @State private var hasAttemptedLoadPosts = false
  @State private var hasAttemptedLoadReplies = false
  @State private var hasAttemptedLoadMedia = false
  @State private var isHeaderScrolledPast = false
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

    self._selectedTab = selectedTab
    self._lastTappedTab = lastTappedTab
    _navigationPath = path
    self._viewModel = State(initialValue: viewModel)
  }

  init(did: String, selectedTab: Binding<Int>, appState: AppState, path: Binding<NavigationPath>) {
    let viewModel = ProfileViewModel(
      client: appState.atProtoClient,
      userDID: did,
      currentUserDID: appState.userDID,
      stateInvalidationBus: appState.stateInvalidationBus
    )
    
    self._selectedTab = selectedTab
    self._lastTappedTab = Binding.constant(nil)
    _navigationPath = path
    self._viewModel = State(initialValue: viewModel)
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

  private func performBlock() async -> Bool {
    await performBlockMutation(blocking: true)
  }

  private func performUnblock() async {
    guard await performBlockMutation(blocking: false) else {
      appState.toastManager.show(ToastItem(
        message: "Couldn’t unblock this account. Try again.", icon: "exclamationmark.triangle.fill"))
      return
    }
  }

  /// Returns whether the block or unblock was saved.
  private func performBlockMutation(blocking: Bool) async -> Bool {
    guard let profile = viewModel.profile, !viewModel.isCurrentUser else { return false }
    let did = profile.did.didString()
    let previousState = isBlocking
    isBlocking = blocking
    do {
      let success = blocking ? try await appState.block(did: did) : try await appState.unblock(did: did)
      if success {
        await reloadRelationshipState()
      } else {
        isBlocking = previousState
      }
      return success
    } catch {
      isBlocking = previousState
      logger.error("Failed to \(blocking ? "block" : "unblock") user: \(error.localizedDescription)")
      // Callers surface the failure (BlockAccountView for block, a toast for unblock).
      return false
    }
  }

  /// Reloads the profile after a block or mute change so the header, banner and posts match
  /// what the user just did.
  private func reloadRelationshipState() async {
    await viewModel.loadProfile()
    if let viewer = viewModel.profile?.viewer {
      isBlocking = viewer.blocking != nil
      isMuting = viewer.muted == true
    }
    await viewModel.loadPosts()
    if viewModel.selectedProfileTab == .replies {
      await viewModel.loadReplies()
    } else if viewModel.selectedProfileTab == .media {
      await viewModel.loadMediaPosts()
    }
  }

  /// Present the block confirmation sheet or the unblock alert.
  private func prepareBlockConfirmation() async {
    if isBlocking {
      isShowingUnblockConfirmation = true
    } else {
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
          ToastItem(message: "Couldn’t check whether this account is blocked. Try again.", icon: "exclamationmark.triangle.fill")
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
        sceneContext.tabTappedAgain = 3
      }
      lastTappedTab = nil
    }
  }

  private func searchPostsForProfile(_ profile: AppBskyActorDefs.ProfileViewDetailed) {
    let queryHandle = "from:\(profile.handle.description)"

    sceneContext.navigationManager.clearPath(for: 1)

    if let selectTab = sceneContext.navigationManager.tabSelection {
      selectTab(1)
    } else {
      sceneContext.navigationManager.updateCurrentTab(1)
    }

    selectedTab = 1
    lastTappedTab = nil

    sceneContext.pendingSearchRequest = AppState.SearchRequest(
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
        try? await viewModel.refreshLikes()
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
      sceneContext.presentPostComposer(initialText: text)

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

        if success {
          await reloadRelationshipState()
        } else {
          // Revert if unsuccessful
          isMuting = previousState
        }
      } catch {
        // Revert on error
        isMuting = !isMuting
        logger.error("Failed to toggle mute: \(error.localizedDescription)")
        appState.toastManager.show(
          ToastItem(message: "Couldn’t update mute settings. Try again.", icon: "exclamationmark.triangle.fill")
        )
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
      Text("Loading profile…")
        .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .secondary, currentScheme: currentColorScheme))
        .padding(.top)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
  }

  @ViewBuilder
  private var errorView: some View {
      Group {
          if case ProfileError.unavailable? = viewModel.error as? ProfileError {
              ContentUnavailableView(
                  "Account Unavailable",
                  systemImage: "person.crop.circle.badge.exclamationmark",
                  description: Text("This account may have been deactivated, suspended or deleted.")
              )
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
          } else if let error = viewModel.error {
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
                  
                  Text("This profile may not exist, or you may not be able to view it.")
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
          requestUnblock: { isShowingUnblockConfirmation = true },
          onHeaderScrolledPastChange: { isHeaderScrolledPast = $0 }
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
      case .section(let tab, let did):
        // SwiftUI can build this destination from a copy of the profile view whose @State
        // never attached, handing it a fresh view model with no profile. Reuse this view
        // model only when it has loaded the requested profile; otherwise the host loads it,
        // so a More section never comes up empty until pull-to-refresh.
        ProfileSectionHostView(
          did: did, tab: tab, appState: appState, path: $navigationPath,
          loadedViewModel: viewModel.profile?.did.didString() == did ? viewModel : nil
        )
        .id("\(did)_\(tab.rawValue)")
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
            onConfirmBlock: {
              await performBlock()
            }
          )
        }
      }
      .sheet(isPresented: $isShowingLabelsOnMe) {
        if let profile = viewModel.profile,
           let client = appState.atProtoClient {
          let reportingService = ReportingService(client: client)
          LabelsOnMeView(
            labels: AccountLabelPresentation.accountLabels(
              profile.labels ?? [], subjectDID: profile.did.didString(),
              subscribedIssuers: Set(((try? appState.preferencesManager.getLocalPreferences())?.labelers.map { $0.did.didString() } ?? []) + [ReportingService.officialBlueskyDID])
            ),
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
            Text(profile.displayName.flatMap {
              $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            } ?? profile.handle.description)
              .appFont(AppTextRole.headline)
              .opacity(isHeaderScrolledPast ? 1 : 0)
              .animation(.easeInOut(duration: 0.2), value: isHeaderScrolledPast)
              .accessibilityHidden(!isHeaderScrolledPast)
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
      .alert("Open Germ DM?", isPresented: Binding(
        get: { pendingGermAction != nil },
        set: { if !$0 { pendingGermAction = nil } }
      ), presenting: pendingGermAction) { handoff in
        Button("Cancel", role: .cancel) { clearGermAction() }
        Button("Open Germ DM") { openGerm(handoff) }
      } message: { handoff in
        Text("Continue to \(handoff.action.url.host() ?? "Germ") to message @\(viewModel.profile?.handle.description ?? ""). No message is sent by Catbird.")
      }
      .alert("Could Not Open Germ", isPresented: $germLaunchError) {
        Button("OK", role: .cancel) { }
      } message: {
        Text("Please try again. The Germ link opens the app when installed, or its website otherwise.")
      }
      .onChange(of: appState.userDID) { _, _ in clearGermAction() }
      .onChange(of: viewModel.profile?.did) { _, _ in clearGermAction() }
      .onChange(of: AppStateManager.shared.settingsAccountContextRevision) { _, _ in clearGermAction() }
      .onDisappear { clearGermAction() }
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
          Text("Mute @\(profile.handle)? You won’t see their posts and replies in your feeds.")
        }
      }
      .confirmationDialog(
        signOutConfirmationTitle,
        isPresented: $isShowingSignOutConfirmation,
        titleVisibility: .visible
      ) {
        Button("Sign Out", role: .destructive) {
          Task {
            do {
              try await appState.handleLogout()
            } catch {
              logger.error("Sign out failed: \(error.localizedDescription)")
              appState.toastManager.show(
                ToastItem(message: "Couldn’t sign out. Try again.", icon: "exclamationmark.triangle.fill")
              )
            }
          }
        }
        Button("Cancel", role: .cancel) {}
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
      profileShareLink

      Divider()

      Button {
        isShowingLabelsOnMe = true
      } label: {
        Label("Labels on Your Account", systemImage: "tag")
      }

      Button {
        isShowingAccountSwitcher = true
      } label: {
        Label("Switch Account", systemImage: "person.crop.circle.badge.plus")
      }
      
      Button(role: .destructive) {
        isShowingSignOutConfirmation = true
      } label: {
        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
      }
    } label: {
      Image(systemName: "ellipsis")
        .accessibilityLabel("More Options")
    }
  }

  private var signOutConfirmationTitle: String {
    if let handle = viewModel.profile?.handle.description {
      return "Sign out of @\(handle)?"
    }
    return "Sign out?"
  }
  
  @ViewBuilder
  private var otherUserMenu: some View {
    Menu {
      if let profile = viewModel.profile {
        profileShareLink
        if let action = germAction {
          Button {
            clearGermAction()
            pendingGermAction = PendingGermHandoff(
              action: action, revision: AppStateManager.shared.settingsAccountContextRevision
            )
          } label: {
            Label("Germ DM", image: "GermLogo")
          }
          .accessibilityHint("Opens an external app or website to compose a message")
        }

        Divider()

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
            Label(viewModel.isSubscribedToLabeler ? "Unsubscribe from Labeler" : "Subscribe to Labeler",
                  systemImage: viewModel.isSubscribedToLabeler ? "checkmark.circle.fill" : "checkmark.circle")
          }
          
          Divider()
          
          Button {
            showReportProfileSheet()
          } label: {
            Label("Report Labeler", systemImage: "flag")
          }
        } else {
          // Regular user options
          if CopilotAvailability.isAvailable {
            Button {
              isShowingCopilot = true
            } label: {
              Label("Ask Catbird", systemImage: "sparkles")
            }

            Divider()
          }

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
      Image(systemName: "ellipsis")
        .accessibilityLabel("More Options")
    }
  }
  
  private var germAction: GermProfileAction? {
    guard !sceneContext.isInvalidated, sceneContext.accountDID == appState.userDID,
          AppStateManager.shared.lifecycle.appState === appState,
          !AppStateManager.shared.authentication.isSwitchingAccount,
          viewModel.currentUserDID == appState.userDID,
          let profile = viewModel.profile else { return nil }
    #if os(iOS)
    let platform = "iOS"
    #else
    let platform = "web"
    #endif
    return GermProfileAction.make(
      metadata: profile.associated?.germ,
      profileDID: profile.did.didString(), viewerDID: appState.userDID,
      loadedForViewerDID: viewModel.currentUserDID,
      profileFollowsViewer: profile.viewer?.followedBy != nil,
      isBlocked: profile.viewer?.blocking != nil || profile.viewer?.blockedBy == true || profile.viewer?.blockingByList != nil,
      platform: platform
    )
  }

  private func clearGermAction() {
    pendingGermAction = nil
    germLaunchError = false
    germLaunchAttemptID = nil
  }

  private func openGerm(_ handoff: PendingGermHandoff) {
    let action = handoff.action
    let revision = handoff.revision
    clearGermAction()
    guard SettingsAccountBoundary.isCurrent(action.viewerDID, revision: revision),
          action == germAction, appState.userDID == action.viewerDID else { return }
    let attemptID = UUID()
    germLaunchAttemptID = attemptID
    #if os(iOS)
    UIApplication.shared.open(action.url, options: [:]) { success in
      Task { @MainActor in
        guard germLaunchAttemptID == attemptID,
              SettingsAccountBoundary.isCurrent(action.viewerDID, revision: revision),
              action == germAction else { return }
        germLaunchAttemptID = nil
        if !success { germLaunchError = true }
      }
    }
    #elseif os(macOS)
    let opened = NSWorkspace.shared.open(action.url)
    if germLaunchAttemptID == attemptID {
      germLaunchAttemptID = nil
      if !opened { germLaunchError = true }
    }
    #endif
  }

  // MARK: - Helper Methods
  
  @ViewBuilder
  private var profileShareLink: some View {
    if let profile = viewModel.profile,
       let url = URL(string: "https://bsky.app/profile/\(profile.handle.description)") {
      ShareLink(item: url) {
        Label("Share Profile", systemImage: "square.and.arrow.up")
      }
    }
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
