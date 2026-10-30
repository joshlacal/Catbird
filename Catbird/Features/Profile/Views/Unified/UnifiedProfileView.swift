import AppIntents
import CatbirdMLSCore
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
  /// Holds the one view model of this screen; see `ProfileViewModelSlot`.
  @State private var viewModelSlot: ProfileViewModelSlot
  /// Builds the view model on first use. The first use is the first line of `initialLoad()`,
  /// which then sets `hasAttemptedLoad`, so code that runs while building the body before that
  /// reads `loadedProfile` or `viewModelSlot` instead.
  private var viewModel: ProfileViewModel { viewModelSlot.viewModel }
  /// The profile, without building a view model to find it has none.
  private var loadedProfile: AppBskyActorDefs.ProfileViewDetailed? {
    viewModelSlot.builtViewModel?.profile
  }
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
  @State private var isShowingLiveStatusEditor = false
  @State private var isShowingLabelsOnMe = false
  @State private var isShowingMuteConfirmation = false
  @State private var isShowingSignOutConfirmation = false
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
  /// When the header last loaded, by appearing or by a refresh, so a quick return does not
  /// fetch it again.
  @State private var lastAppearanceLoad: Date?
  /// How old the header must be before returning to the screen refreshes it.
  private static let headerRefreshAge: TimeInterval = 60
  @State private var isHeaderScrolledPast = false
  @State private var scrollToTopRequestID = 0
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
    let viewModelSlot = ProfileViewModelSlot(
      client: appState.atProtoClient,
      userDID: appState.userDID,
      currentUserDID: appState.userDID,
      stateInvalidationBus: appState.stateInvalidationBus
    )

    self._selectedTab = selectedTab
    self._lastTappedTab = lastTappedTab
    _navigationPath = path
    self._viewModelSlot = State(initialValue: viewModelSlot)
  }

  init(did: String, selectedTab: Binding<Int>, appState: AppState, path: Binding<NavigationPath>) {
    // Labelers open on Labeler Info, chosen before the first load reads the tab.
    let viewModelSlot = ProfileViewModelSlot(
      client: appState.atProtoClient,
      userDID: did,
      currentUserDID: appState.userDID,
      stateInvalidationBus: appState.stateInvalidationBus,
      initialProfileTab: ProfileViewModelSlot.initialTab(
        for: did, subscribedLabelerDIDs: appState.moderationPolicy.prefs.labelers.lazy.map(\.did)
      )
    )

    self._selectedTab = selectedTab
    self._lastTappedTab = Binding.constant(nil)
    _navigationPath = path
    self._viewModelSlot = State(initialValue: viewModelSlot)
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
        if viewModel.boxedPosts.isEmpty { await viewModel.loadPosts() }
      case .replies:
        hasAttemptedLoadReplies = true
        if viewModel.boxedReplies.isEmpty { await viewModel.loadReplies() }
      case .media:
        hasAttemptedLoadMedia = true
        if viewModel.boxedPostsWithMedia.isEmpty { await viewModel.loadMediaPosts() }
      case .more:
        break
      default:
        break
      }
    }
  }

  // MARK: - New helper function for refreshing content
  private func refreshAllContent() async {
    lastAppearanceLoad = Date()
    switch viewModel.selectedProfileTab {
    case .posts:
      hasAttemptedLoadPosts = true
    case .replies:
      hasAttemptedLoadReplies = true
    case .media:
      hasAttemptedLoadMedia = true
    default:
      break
    }

    async let profileTask: Void = viewModel.loadProfile()
    async let followersTask: Void = loadKnownFollowersIfOtherProfile(reset: true)
    async let feedTask: Void = reloadSelectedTab()

    _ = await (profileTask, followersTask, feedTask)
  }

  /// Reloads the open post tab's first page. Its hasAttemptedLoad flag is set by the caller,
  /// outside the concurrent loads.
  private func reloadSelectedTab() async {
    switch viewModel.selectedProfileTab {
    case .posts:
      await viewModel.loadPosts()
    case .replies:
      await viewModel.loadReplies()
    case .media:
      await viewModel.loadMediaPosts()
    default:
      break
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
    if let profile = loadedProfile {
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
      let success: Bool
      if let coord = appState.mlsBlockCoordinator {
        // The coordinator also leaves MLS conversations shared with a blocked account.
        if blocking {
          try await coord.block(did: did)
        } else {
          try await coord.unblock(did: did)
        }
        success = true
      } else {
        success = blocking ? try await appState.block(did: did) : try await appState.unblock(did: did)
      }
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
    if let profile = viewModel.profile, profile.viewer != nil {
      await applyRelationshipState(from: profile)
    }
    await viewModel.loadPosts()
    if viewModel.selectedProfileTab == .replies {
      await viewModel.loadReplies()
    } else if viewModel.selectedProfileTab == .media {
      await viewModel.loadMediaPosts()
    }
  }

  /// Whether the Mute/Unmute item should say Unmute. `viewer.muted` is also true for a mute
  /// that comes from a subscribed mute list (the AppView ORs the two), and unmuteActor cannot
  /// remove that, so only list-muted profiles ask the graph's direct-mute cache. Every other
  /// profile answers from its viewer state without a lookup.
  static func directMuteState(
    muted: Bool?, isListMuted: Bool, directMuteLookup: () async -> Bool
  ) async -> Bool {
    guard isListMuted else { return muted == true }
    return await directMuteLookup()
  }

  /// Sets the toolbar menu's block and mute state from a loaded profile. A profile without
  /// viewer state asks the graph for both.
  private func applyRelationshipState(from profile: AppBskyActorDefs.ProfileViewDetailed) async {
    let did = profile.did.didString()
    if let viewer = profile.viewer {
      isBlocking = viewer.blocking != nil
      isMuting = await Self.directMuteState(
        muted: viewer.muted, isListMuted: viewer.mutedByList != nil
      ) {
        await appState.isMuting(did: did)
      }
    } else {
      isBlocking = await appState.isBlocking(did: did)
      isMuting = await appState.isMuting(did: did)
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
      scrollToTopRequestID += 1
      lastAppearanceLoad = Date()
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
    // The first read of `viewModel` builds it, with its initial tab, before anything below
    // reads the tab or starts a load. ProfileOpen runs from here to the first post row.
    viewModel.beginOpenSignpost()

    hasAttemptedLoad = true
    async let profileTask: Void = viewModel.loadProfile()
    async let followersTask: Void = loadKnownFollowersIfOtherProfile()
    async let feedTask: Void = refreshCurrentTabContent()

    _ = await (profileTask, followersTask, feedTask)

    // Blocking and muting come from the profile's viewer state, so the mute list is
    // scanned only for list-muted profiles (see directMuteState).
    if let profile = viewModel.profile, !viewModel.isCurrentUser {
      await applyRelationshipState(from: profile)
    }

    viewModel.endOpenSignpostIfNothingToShow()
  }

  /// The quiet header refresh when the user comes back to a loaded profile. It also re-reads
  /// the menu's block and mute state, which a pushed thread may have changed, so the header
  /// and the menu agree.
  private func refreshHeaderAfterReturn() async {
    await viewModel.loadProfile()
    if let profile = viewModel.profile, !viewModel.isCurrentUser, profile.viewer != nil {
      await applyRelationshipState(from: profile)
    }
  }

  /// When the user comes back to a loaded profile, loads again only what never arrived: the
  /// open tab's first page (failed, or cancelled by a push) and a "Followed by" row cut short.
  private func retryUnloadedContent() async {
    async let tabTask: Void = retryUnloadedTabContent()
    async let followersTask: Void = retryKnownFollowersIfCutShort()
    _ = await (tabTask, followersTask)
  }

  /// Known followers mean nothing on the user's own profile.
  private func loadKnownFollowersIfOtherProfile(reset: Bool = false) async {
    guard !viewModel.isCurrentUser else { return }
    await viewModel.loadKnownFollowers(reset: reset)
  }

  /// Loads the "Followed by" row again when the profile says it has some and the last load
  /// never answered (it failed, or a push cancelled it). An answer with nobody in it, such as
  /// when getKnownFollowers leaves out muted or blocked accounts, is not asked again.
  private func retryKnownFollowersIfCutShort() async {
    guard viewModel.knownFollowers.isEmpty, !viewModel.hasLoadedKnownFollowers,
          (viewModel.profile?.viewer?.knownFollowers?.count ?? 0) > 0 else { return }
    await loadKnownFollowersIfOtherProfile()
  }

  /// Like `refreshCurrentTabContent`, but a tab is loaded again only when its first page never
  /// came back (`needsFirstPageRetry`). A first page that came back empty counts as loaded, with
  /// or without a cursor, so a profile with no posts, replies or media, or one whose recent
  /// items hold no replies to others, costs no request on every return.
  private func retryUnloadedTabContent() async {
    switch viewModel.selectedProfileTab {
    case .posts:
      hasAttemptedLoadPosts = true
      if viewModel.needsFirstPageRetry(for: .posts) {
        await viewModel.loadPosts()
      }
    case .replies:
      hasAttemptedLoadReplies = true
      if viewModel.needsFirstPageRetry(for: .replies) {
        await viewModel.loadReplies()
      }
    case .media:
      hasAttemptedLoadMedia = true
      if viewModel.needsFirstPageRetry(for: .media) {
        await viewModel.loadMediaPosts()
      }
    case .labelerInfo:
      if viewModel.isLabeler, viewModel.labelerDetails == nil {
        await viewModel.loadLabelerDetails()
      }
    default:
      break
    }
  }
  
  private func refreshCurrentTabContent() async {
    switch viewModel.selectedProfileTab {
    case .posts:
      hasAttemptedLoadPosts = true
      if viewModel.boxedPosts.isEmpty {
        await viewModel.loadPosts()
      }
    case .replies:
      hasAttemptedLoadReplies = true
      if viewModel.boxedReplies.isEmpty {
        await viewModel.loadReplies()
      }
    case .media:
      hasAttemptedLoadMedia = true
      if viewModel.boxedPostsWithMedia.isEmpty {
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
          onHeaderScrolledPastChange: { isHeaderScrolledPast = $0 },
          scrollToTopRequestID: scrollToTopRequestID
        )
      } else {
        errorView
      }
    }
    .id(viewModelSlot.userDID) // Use stable userDID instead of profile?.did
    .navigationTitle("")
    .ensureDeepNavigationFonts()
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    #else
    .toolbarBackground(.hidden, for: .automatic)
    #endif
    .navigationDestination(for: ProfileNavigationDestination.self) { destination in
      switch destination {
      case .section(let tab, let did):
        // SwiftUI can build this destination from a copy of the profile view whose @State
        // never attached, so its slot has no view model. Reuse this view model only when it
        // has loaded the requested profile; otherwise the host loads it, so a More section
        // never comes up empty until pull-to-refresh. Reading `builtViewModel` never builds one.
        ProfileSectionHostView(
          did: did, tab: tab, appState: appState, path: $navigationPath,
          loadedViewModel: viewModelSlot.builtViewModel.flatMap {
            $0.profile?.did.didString() == did ? $0 : nil
          }
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
        if let profile = loadedProfile {
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
      .onChange(of: loadedProfile?.did) { _, _ in clearGermAction() }
      .onChange(of: AppStateManager.shared.settingsAccountContextRevision) { _, _ in clearGermAction() }
      .onDisappear {
        clearGermAction()
        // Never builds a view model: a screen that never loaded has no open to end.
        viewModelSlot.builtViewModel?.abandonOpenSignpost()
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
        if let profile = loadedProfile {
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
      .onChange(of: sceneContext.tabTappedAgain) { _, newValue in
        if newValue == 3 {
          scrollToTopRequestID += 1
        }
      }
      .task {
        // Coming back from a pushed screen runs this task again. A loaded profile keeps its
        // rows (Quick win 12 / P154): only content that never arrived loads again, and the
        // header refreshes quietly once it is over a minute old. `hasAttemptedLoad` is
        // checked first, so this never reads the view model of a screen that has not loaded.
        if hasAttemptedLoad, viewModel.profile != nil {
          if let lastAppearanceLoad,
             Date().timeIntervalSince(lastAppearanceLoad) > Self.headerRefreshAge {
            self.lastAppearanceLoad = Date()
            // Unstructured on purpose: leaving again must not cancel the refresh halfway.
            Task { await refreshHeaderAfterReturn() }
          }
          await retryUnloadedContent()
        } else {
          lastAppearanceLoad = Date()
          await initialLoad()
        }
      }
  }
  
  @ViewBuilder
  private var currentUserMenu: some View {
    Menu {
      profileShareLink

      Divider()

      if CatbirdFeatures.live {
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
      }

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
    if let handle = loadedProfile?.handle.description {
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
