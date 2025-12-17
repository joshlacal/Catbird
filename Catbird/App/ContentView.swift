import AuthenticationServices
import OSLog
import Petrel
import SwiftUI

struct ContentView: View {
  @Environment(AppState.self) private var appState
  @Environment(AppStateManager.self) private var appStateManager
  @Environment(\.webAuthenticationSession) private var webAuthenticationSession
  @State private var selectedTab = 0
  @State private var lastTappedTab: Int?
  @State private var hasRestoredState = false
  @State private var showingComposerFromAccountSwitch = false
  @State private var isAutoReauthenticating = false
  @State private var hasTriggeredAutoReauth = false

  private let logger = Logger(subsystem: "blue.catbird", category: "ContentView")

  var body: some View {
    mainContent
  }

  @ViewBuilder
  private var mainContent: some View {
      let currentLifecycle = appStateManager.lifecycle

    ZStack {
      contentForLifecycle(currentLifecycle)

      if case .authenticated(let activeState) = currentLifecycle,
         activeState.isTransitioningAccounts {
        ContentViewLoadingView(message: accountSwitchMessage(for: activeState))
          .transition(.opacity)
          .zIndex(1)
          .ignoresSafeArea()
      }
      
      // Show loading overlay during auto-reauthentication
      if isAutoReauthenticating {
        ContentViewLoadingView(message: "Signing in...")
          .transition(.opacity)
          .zIndex(2)
          .ignoresSafeArea()
      }
    }
    .modifier(ContentViewModifiers(
      appStateManager: appStateManager,
      showingComposerFromAccountSwitch: $showingComposerFromAccountSwitch
    ))
    .task {
      // Auto-trigger re-authentication when we have an expired account
      await checkAndTriggerAutoReauth()
    }
    .onChange(of: appStateManager.authentication.expiredAccountInfo?.did) { oldDID, newDID in
      // React to expiredAccountInfo changes - trigger re-authentication when it's newly set
      if newDID != nil && oldDID == nil {
        logger.info("🔐 [AUTO-REAUTH] expiredAccountInfo newly set, triggering auto-reauth")
        Task {
          await checkAndTriggerAutoReauth()
        }
      }
    }
  }
  
  /// Check if we should auto-trigger re-authentication and do so
  private func checkAndTriggerAutoReauth() async {
    // Only proceed if:
    // 1. We have an expired account
    // 2. We haven't already triggered auto-reauth
    // 3. We're not currently authenticating
    // 4. We're in unauthenticated state
    guard let expiredAccount = appStateManager.authentication.expiredAccountInfo,
          !hasTriggeredAutoReauth,
          !isAutoReauthenticating,
          !appStateManager.authentication.state.isAuthenticating,
          case .unauthenticated = appStateManager.lifecycle else {
      return
    }
    
    logger.info("🔐 [AUTO-REAUTH] Starting automatic re-authentication for: \(expiredAccount.handle ?? expiredAccount.did)")
    
    hasTriggeredAutoReauth = true
    isAutoReauthenticating = true
    
    do {
      // Get auth URL for the expired account
      guard let authURL = try await appStateManager.authentication.startOAuthFlowForExpiredAccount() else {
        logger.error("🔐 [AUTO-REAUTH] Failed to get auth URL")
        isAutoReauthenticating = false
        return
      }
      
      logger.info("🔐 [AUTO-REAUTH] Got auth URL, opening browser")
      
      // Open web authentication session
      let callbackURL: URL
      if #available(iOS 17.4, *) {
        callbackURL = try await webAuthenticationSession.authenticate(
          using: authURL,
          callback: .https(host: "catbird.blue", path: "/oauth/callback"),
          preferredBrowserSession: .shared,
          additionalHeaderFields: [:]
        )
      } else {
        callbackURL = try await webAuthenticationSession.authenticate(
          using: authURL,
          callbackURLScheme: "catbird",
          preferredBrowserSession: .shared
        )
      }
      
      logger.info("🔐 [AUTO-REAUTH] Got callback, processing")
      
      // Process callback
      try await appStateManager.authentication.handleCallback(callbackURL)
      
      logger.info("✅ [AUTO-REAUTH] Re-authentication successful")
      
    } catch let error as ASWebAuthenticationSessionError {
      // User cancelled - clear expired account info to prevent retry loop
      logger.notice("🔐 [AUTO-REAUTH] User cancelled re-authentication")
      await appStateManager.authentication.clearExpiredAccountInfo()
      hasTriggeredAutoReauth = false  // Allow retry if they try again later
    } catch {
      // Other errors - log but don't clear expired account info so user can retry manually
      logger.error("🔐 [AUTO-REAUTH] Error: \(error.localizedDescription)")
      hasTriggeredAutoReauth = false  // Allow retry on error
    }
    
    isAutoReauthenticating = false
  }
}

private extension ContentView {
  @ViewBuilder
  func contentForLifecycle(_ lifecycle: AppLifecycle) -> some View {
    switch lifecycle {
    case .launching:
      launchingView
    case .unauthenticated:
      unauthenticatedView
    case .authenticated(let appState):
      authenticatedMainView(appState: appState)
    }
  }

  @ViewBuilder
  func authenticatedMainView(appState: AppState) -> some View {
      MainContentView(
        selectedTab: $selectedTab,
        lastTappedTab: $lastTappedTab
      )
      .applyAppStateEnvironment(appState)
      .environment(appStateManager)
  }

  @ViewBuilder
  var launchingView: some View {
    ContentViewLoadingView(message: "Loading...")
  }

  @ViewBuilder
  var unauthenticatedView: some View {
    // If we have an expired account (session expired, needs re-auth), show login
    // If we have any auth alert pending, show login to handle it
    // Otherwise if we have registered accounts, show account switcher
    // Otherwise show login for new user
    if appStateManager.authentication.expiredAccountInfo != nil || appStateManager.authentication.pendingAuthAlert != nil {
      LoginView()
    } else if appStateManager.authentication.hasRegisteredAccounts {
      AccountSwitcherView(showsDismissButton: false)
    } else {
      LoginView()
    }
  }
}

private extension ContentView {
  func accountSwitchMessage(for appState: AppState) -> String {
    if let label = accountSwitchLabel(for: appState) {
      return "Switching to \(label)"
    }
    return "Switching accounts"
  }

  func accountSwitchLabel(for appState: AppState) -> String? {
    // First check if we have a loaded profile
    if let profile = appState.currentUserProfile {
      let handle = profile.handle.description
      if let displayName = profile.displayName, !displayName.isEmpty {
        return displayName
      } else {
        return "@\(handle)"
      }
    }

    // Fall back to cached account info from authentication manager
    if let account = appStateManager.authentication.availableAccounts.first(where: { $0.did == appState.userDID }) {
      // Prefer cached display name, then cached handle, then credential handle
      if let displayName = account.cachedDisplayName, !displayName.isEmpty {
        return displayName
      } else if let handle = account.cachedHandle, !handle.isEmpty {
        return "@\(handle)"
      } else if let handle = account.handle, !handle.isEmpty {
        return "@\(handle)"
      }
    }

    return nil
  }
}

// MARK: - Loading View

struct ContentViewLoadingView: View {
  let message: String
  @Environment(\.colorScheme) private var colorScheme
  @Environment(AppState.self) private var appState: AppState?

  init(message: String) {
    self.message = message
  }

  var body: some View {
    ZStack {
      // Full-screen themed background - no gaps
      // Use themed background if appState available, otherwise use system background
      if let appState = appState {
        Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme)
          .ignoresSafeArea()
      } else {
        Color(uiColor: .systemBackground)
          .ignoresSafeArea()
      }

      VStack(spacing: 20) {
        ProgressView()
          .scaleEffect(1.5)

        Text(message)
          .appFont(AppTextRole.headline)
          .textCase(.uppercase)
          .foregroundStyle(.secondary)
          .textScale(.secondary)
      }
    }
    .contentShape(Rectangle())
    .allowsHitTesting(true)
  }
}

// MARK: - Main Content Container View

// Helper to apply matched transition source for zoom transitions
@available(iOS 18.0, *)
private struct ComposeSourceModifier: ViewModifier {
  let namespace: Namespace.ID

  func body(content: Content) -> some View {
    content
      .matchedTransitionSource(id: "compose", in: namespace)
  }
}

@available(iOS 18.0, *)
struct MainContentView: View {
  @Environment(AppState.self) private var appState
  @Binding var selectedTab: Int
  @Binding var lastTappedTab: Int?

  // Side drawer state for home tab
  @State private var isDrawerOpen = false
  @State private var isRootView = true
  @State private var selectedFeed: FetchType = .timeline
  @State private var currentFeedName: String = ""

  // Add state for showing post composer
  @State private var showingPostComposer = false
  @State private var showingSettings = false
  @State private var showingNewMessageSheet = false
  @State private var hasInitializedFeed = false
  @State private var showingOnboarding = false
  @State private var hasRestoredState = false
  @State private var isRestoringFeed = false // Prevent saving during account switch
  // Snapshot the draft at presentation time so autosave mutations don't recreate the sheet content
  @State private var composerInitialDraft: PostComposerDraft?
  // Namespace for iOS 26 matched transitions
  @Namespace private var composeTransitionNamespace

  // Access the navigation manager directly
  private var navigationManager: AppNavigationManager {
    appState.navigationManager
  }
  
  // MARK: - Per-Account Feed Memory
  
  /// Save the currently selected feed for the current account
  private func saveLastFeedForAccount() {
    // Don't save if we're in the middle of restoring/switching accounts
    guard !isRestoringFeed else { return }
    let userDID = appState.userDID
    let key = "lastSelectedFeed_\(userDID)"
    UserDefaults.standard.set(selectedFeed.identifier, forKey: key)
    logger.debug("💾 Saved last feed for account \(userDID): \(selectedFeed.identifier)")
  }

  /// Restore the last selected feed for the current account
  private func restoreLastFeedForAccount() async {
    isRestoringFeed = true
    defer { isRestoringFeed = false }

    let userDID = appState.userDID
    // userDID is always present for authenticated AppState

    let key = "lastSelectedFeed_\(userDID)"
    guard let savedFeedIdentifier = UserDefaults.standard.string(forKey: key) else {
      // No saved feed for this account, use first pinned feed or timeline
      await loadDefaultFeed()
      return
    }
    
    logger.debug("📂 Restoring last feed for account \(userDID): \(savedFeedIdentifier)")
    
    // Parse the saved feed identifier and restore it
    if savedFeedIdentifier == "timeline" {
      selectedFeed = .timeline
      currentFeedName = "Timeline"
    } else if savedFeedIdentifier.hasPrefix("feed:") {
      // Saved as "feed:<at-uri>"
      let uriString = String(savedFeedIdentifier.dropFirst("feed:".count))
      if let uri = try? ATProtocolURI(uriString: uriString) {
        selectedFeed = .feed(uri)
        currentFeedName = "Feed" // Will be updated by task(id: selectedFeed)
      } else {
        await loadDefaultFeed()
      }
    } else if savedFeedIdentifier.hasPrefix("list:") {
      // Saved as "list:<at-uri>" (compat: may include trailing name suffix in older formats)
      let remainder = String(savedFeedIdentifier.dropFirst("list:".count))
      let candidate: String
      if let range = remainder.range(of: "at://") {
        candidate = String(remainder[range.lowerBound...])
      } else {
        candidate = remainder
      }
      if let uri = try? ATProtocolURI(uriString: candidate) {
        selectedFeed = .list(uri)
        currentFeedName = "List" // Will be updated elsewhere if needed
      } else {
        await loadDefaultFeed()
      }
    } else {
      // Unknown format, fall back to default
      await loadDefaultFeed()
    }
  }
  
  /// Load the default feed (first pinned feed or timeline)
  private func loadDefaultFeed() async {
    // First check for a pinned feed to use as default
    if let preferences = try? await appState.preferencesManager.getPreferences(),
       let firstPinnedFeed = preferences.pinnedFeeds.first,
       let uri = try? ATProtocolURI(uriString: firstPinnedFeed) {
      if firstPinnedFeed.contains("/app.bsky.graph.list/") {
        selectedFeed = .list(uri)
        currentFeedName = "List"
      } else {
        selectedFeed = .feed(uri)
        currentFeedName = "Feed" // Will be updated by .task(id: selectedFeed)
      }
    } else {
      // Fallback to timeline
      selectedFeed = .timeline
      currentFeedName = "Timeline"
    }
  }

  var body: some View {
    ZStack(alignment: .top) {
      #if os(iOS)
      SideDrawer(selectedTab: $selectedTab, isRootView: $isRootView, isDrawerOpen: $isDrawerOpen, drawerWidth: PlatformScreenInfo.responsiveDrawerWidth) {
        if #available(iOS 26.0, *) {
          GlassEffectContainer(spacing: 20) {
            ZStack(alignment: .bottomTrailing) {
              TabView(
                selection: Binding(
                  get: { selectedTab },
                  set: { newValue in
                    if selectedTab == newValue {
                      logger.debug("📱 TabView: Same tab tapped again: \(newValue)")
                      lastTappedTab = newValue
                    }
                    selectedTab = newValue

                    // Update the navigation manager with the new tab index
                    navigationManager.updateCurrentTab(newValue)
                  }
                )
              ) {
                // Home Tab
                Tab("Home", systemImage: "house", value: 0) {
                  HomeView(
                    selectedTab: $selectedTab,
                    lastTappedTab: $lastTappedTab,
                    selectedFeed: $selectedFeed,
                    currentFeedName: $currentFeedName,
                    isDrawerOpen: $isDrawerOpen,
                    isRootView: $isRootView
                  )
                  .id(appState.userDID)
                }

                // Search Tab
                Tab(value: 1, role: .search) {
                  RefinedSearchView(
                    appState: appState,
                    selectedTab: $selectedTab,
                    lastTappedTab: $lastTappedTab
                  )
                  .id(appState.userDID)
                }

                // Notifications Tab
                Tab("Notifications", systemImage: "bell", value: 2) {
                  NotificationsView(
                    appState: appState,
                    selectedTab: $selectedTab,
                    lastTappedTab: $lastTappedTab
                  )
                  .id(appState.userDID)
                }
                .badge(appState.notificationManager.unreadCount > 0 ? appState.notificationManager.unreadCount : 0)

                // Profile Tab - Hidden on iPhone to save space
                if !PlatformDeviceInfo.isPhone {
                  Tab("Profile", systemImage: "person", value: 3) {
                    NavigationStack(path: appState.navigationManager.pathBinding(for: 3)) {
                      UnifiedProfileView(
                        appState: appState,
                        selectedTab: $selectedTab,
                        lastTappedTab: $lastTappedTab,
                        path: appState.navigationManager.pathBinding(for: 3)
                      )
                      .id(appState.userDID)
                      .navigationDestination(for: NavigationDestination.self) { destination in
                        NavigationHandler.viewForDestination(
                          destination,
                          path: appState.navigationManager.pathBinding(for: 3),
                          appState: appState,
                          selectedTab: $selectedTab
                        )
                      }
                    }
                  }
                }

                #if os(iOS)
                // Chat Tab (iOS only)
                Tab("Messages", systemImage: "envelope", value: 4) {
                  ChatTabView(
                    selectedTab: $selectedTab,
                    lastTappedTab: $lastTappedTab
                  )
                  .id(appState.userDID)
                }
                .badge(appState.totalMessagesUnreadCount > 0 ? appState.totalMessagesUnreadCount : 0)
                #endif
              }
              
              if (selectedTab == 0 && isRootView) || (selectedTab == 3 && !PlatformDeviceInfo.isPhone) {
                FAB(
                  composeAction: { showingPostComposer = true },
                  feedsAction: {},
                  showFeedsButton: false,
                  hasMinimizedComposer: appState.composerDraftManager.currentDraft != nil,
                  clearDraftAction: {
                    appState.composerDraftManager.clearDraft()
                  }
                )
                .padding(.bottom, 79)  // Tab bar (49) + spacing (30)
                .padding(.trailing, 5)
                // Mark FAB as the source of the Liquid Glass morph on iOS 26
                    // Source tagging now occurs inside FAB on the compose button itself
              }
            }
          }
        } else {
          ZStack(alignment: .bottomTrailing) {
            TabView(
              selection: Binding(
                get: { selectedTab },
                set: { newValue in
                  if selectedTab == newValue {
                    logger.debug("📱 TabView: Same tab tapped again: \(newValue)")
                    lastTappedTab = newValue
                  }
                  selectedTab = newValue

                  // Update the navigation manager with the new tab index
                  navigationManager.updateCurrentTab(newValue)
                }
              )
            ) {
              // Home Tab
              Tab("Home", systemImage: "house", value: 0) {
                HomeView(
                  selectedTab: $selectedTab,
                  lastTappedTab: $lastTappedTab,
                  selectedFeed: $selectedFeed,
                  currentFeedName: $currentFeedName,
                  isDrawerOpen: $isDrawerOpen,
                  isRootView: $isRootView
                )
                .id(appState.userDID)
              }

              // Search Tab
              Tab(value: 1, role: .search) {
                RefinedSearchView(
                  appState: appState,
                  selectedTab: $selectedTab,
                  lastTappedTab: $lastTappedTab
                )
                .id(appState.userDID)
              }

              // Notifications Tab
              Tab("Notifications", systemImage: "bell", value: 2) {
                NotificationsView(
                  appState: appState,
                  selectedTab: $selectedTab,
                  lastTappedTab: $lastTappedTab
                )
                .id(appState.userDID)
              }
              .badge(appState.notificationManager.unreadCount > 0 ? appState.notificationManager.unreadCount : 0)

              // Profile Tab - Hidden on iPhone to save space
              if !PlatformDeviceInfo.isPhone {
                Tab("Profile", systemImage: "person", value: 3) {
                  NavigationStack(path: appState.navigationManager.pathBinding(for: 3)) {
                    UnifiedProfileView(
                      appState: appState,
                      selectedTab: $selectedTab,
                      lastTappedTab: $lastTappedTab,
                      path: appState.navigationManager.pathBinding(for: 3)
                    )
                    .id(appState.userDID)
                    .navigationDestination(for: NavigationDestination.self) { destination in
                      NavigationHandler.viewForDestination(
                        destination,
                        path: appState.navigationManager.pathBinding(for: 3),
                        appState: appState,
                        selectedTab: $selectedTab
                      )
                    }
                  }
                }
              }

              #if os(iOS)
              // Chat Tab (iOS only)
              Tab("Messages", systemImage: "envelope", value: 4) {
                ChatTabView(
                  selectedTab: $selectedTab,
                  lastTappedTab: $lastTappedTab
                )
                .id(appState.userDID)
              }
              .badge(appState.totalMessagesUnreadCount > 0 ? appState.totalMessagesUnreadCount : 0)
              #endif
            }
            
            if (selectedTab == 0 && isRootView) || (selectedTab == 3 && !PlatformDeviceInfo.isPhone) {
              FAB(
                composeAction: { showingPostComposer = true },
                feedsAction: {},
                showFeedsButton: false,
                hasMinimizedComposer: appState.composerDraftManager.currentDraft != nil,
                clearDraftAction: {
                  appState.composerDraftManager.clearDraft()
                }
              )
              .padding(.bottom, 79)  // Tab bar (49) + spacing (30)
              .padding(.trailing, 5)
              // Mark FAB as the source of the Liquid Glass morph on iOS 26
                  // Source tagging now occurs inside FAB on the compose button itself
            }
          }
        }
      } drawer: {
          NavigationStack(path: appState.navigationManager.pathBinding(for: 0)) {
              FeedsStartPage(
                appState: appState,
                selectedFeed: $selectedFeed,
                currentFeedName: $currentFeedName,
                isDrawerOpen: $isDrawerOpen
              )
              .navigationDestination(for: NavigationDestination.self) { destination in
                NavigationHandler.viewForDestination(
                  destination,
                  path: appState.navigationManager.pathBinding(for: 0),
                  appState: appState,
                  selectedTab: $selectedTab
                )
              }
              .toolbar { // Native toolbar items shown while drawer is open (iOS)
                  if isDrawerOpen && selectedTab == 0 {
                      ToolbarItem(placement: .topBarTrailing) {
                          Button { isDrawerOpen = false } label: { Image(systemName: "xmark") }
                              .accessibilityLabel("Close Feeds Menu")
                      }
                      ToolbarItem(placement: .bottomBar) {
                          Button {
                              let did = appState.userDID
                              appState.navigationManager.navigate(to: .profile(did))
                              isDrawerOpen = false
                          } label: { Label("Profile", systemImage: "person") }
                              .accessibilityLabel("Profile")
                      }
                      ToolbarItem(placement: .bottomBar) {
                          Button {
                              appState.navigationManager.navigate(to: .bookmarks)
                              isDrawerOpen = false
                          } label: { Label("Bookmarks", systemImage: "bookmark") }
                              .accessibilityLabel("Bookmarks")
                      }
                      ToolbarItem(placement: .bottomBar) {
                          Button {
                              appState.navigationManager.navigate(to: .listManager)
                              isDrawerOpen = false
                          } label: { Label("My Lists", systemImage: "list.bullet") }
                              .accessibilityLabel("My Lists")
                      }
                  }
              }
          }
      }
      .platformIgnoresSafeArea()
      .scrollDismissesKeyboard(.interactively)
      .toastContainer()
      .onAppear {
        // Theme is already applied during AppState initialization - no need to reapply here
        
        // Restore UI state
        Task {
          await restoreUIState()
        }
        
        // Note: Theme change updates are now handled by @Observable system in AppState
        // No need for NotificationCenter observers that conflict with SwiftUI observation
          
        Task {
          // Only initialize feed on first load
          if !hasInitializedFeed {
            hasInitializedFeed = true
            
            // Restore last feed for current account
            await restoreLastFeedForAccount()
          }
        }
          
        navigationManager.registerTabSelectionCallback { newTab in
          selectedTab = newTab
        }
      }
      .sheet(isPresented: $showingPostComposer) {
        Group {
          if let draft = composerInitialDraft {
            PostComposerViewUIKit(
              restoringFromDraft: draft,
              appState: appState
            )
          } else {
            PostComposerViewUIKit(
              appState: appState
            )
          }
        }
        .applyAppStateEnvironment(appState)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .applyComposerNavigationTransition(
          enabled: (selectedTab == 0 || (selectedTab == 3 && !PlatformDeviceInfo.isPhone)),
          sourceID: "compose",
          namespace: composeTransitionNamespace
        )
      }
      .sheet(isPresented: $showingNewMessageSheet) {
        NewMessageView()
          .applyAppStateEnvironment(appState)
          .presentationDetents([PresentationDetent.medium, PresentationDetent.large])
          .presentationDragIndicator(.visible)
          .presentationBackground(.thinMaterial)
      }
      .sheet(isPresented: $showingOnboarding) {
        WelcomeOnboardingView()
          .applyAppStateEnvironment(appState)
      }
      .onChange(of: appState.onboardingManager.showWelcomeSheet) { _, newValue in
        showingOnboarding = newValue
      }
      .onChange(of: showingPostComposer) { _, isPresented in
        composerInitialDraft = isPresented ? appState.composerDraftManager.currentDraft : nil
      }
      .onChange(of: showingOnboarding) { _, newValue in
        if !newValue && appState.onboardingManager.showWelcomeSheet {
          Task { @MainActor in
            appState.onboardingManager.completeWelcomeOnboarding()
          }
        }
      }
      .onChange(of: appState.userDID) { oldDID, newDID in
        // Account switched - restore last feed for this account
        guard oldDID != newDID else { return }
        logger.debug("🔄 Account switched from \(oldDID) to \(newDID) - restoring last feed")
        
        // Set flag to prevent saving during restoration
        isRestoringFeed = true
        
        // IMMEDIATELY reset feed synchronously to prevent overlay
        selectedFeed = .timeline
        currentFeedName = "Timeline"
        
        // Reset initialization flag
        hasInitializedFeed = false
        
        // Clear drawer state
        isDrawerOpen = false
        
        // THEN restore last feed for new account asynchronously
        Task {
          await restoreLastFeedForAccount()
        }
      }
      .onChange(of: selectedFeed) { oldFeed, newFeed in
        // Save the selected feed for the current account whenever it changes
        if oldFeed.identifier != newFeed.identifier {
          saveLastFeedForAccount()
        }
      }
      .task(id: selectedFeed) {
        // Fetch feed name when selectedFeed changes to a custom feed
        if case .feed(let uri) = selectedFeed {
          // Fetch feed generator info to get display name
          if let client = appState.atProtoClient {
            do {
              let result = try await client.app.bsky.feed.getFeedGenerator(input: .init(feed: uri))
              if result.responseCode == 200, let data = result.data {
                await MainActor.run {
                  currentFeedName = data.view.displayName ?? "Feed"
                }
              } else {
                await MainActor.run {
                  currentFeedName = "Feed"
                }
              }
            } catch {
              logger.error("Failed to fetch feed name: \(error.localizedDescription)")
              await MainActor.run {
                currentFeedName = "Feed"
              }
            }
          }
        } else if case .timeline = selectedFeed {
          await MainActor.run {
            currentFeedName = "Timeline"
          }
        } else if case .list(let uri) = selectedFeed {
          do {
            let listDetails = try await appState.listManager.getListDetails(uri.uriString())
            await MainActor.run {
              currentFeedName = listDetails.name
            }
          } catch {
            logger.error("Failed to fetch list name: \(error.localizedDescription)")
            await MainActor.run {
              currentFeedName = uri.recordKey ?? "List"
            }
          }
        }
      }
      
      #elseif os(macOS)
      // macOS content goes here directly without SideDrawer
      TabView(
        selection: Binding(
          get: { selectedTab },
          set: { newValue in
            if selectedTab == newValue {
              logger.debug("📱 TabView: Same tab tapped again: \(newValue)")
              lastTappedTab = newValue
            }
            selectedTab = newValue

            // Update the navigation manager with the new tab index
            navigationManager.updateCurrentTab(newValue)
          }
        )
      ) {
        // Home Tab
        Tab("Home", systemImage: "house", value: 0) {
          HomeView(
            selectedTab: $selectedTab,
            lastTappedTab: $lastTappedTab,
            selectedFeed: $selectedFeed,
            currentFeedName: $currentFeedName,
            isDrawerOpen: $isDrawerOpen,
            isRootView: $isRootView
          )
          .id(appState.userDID)
        }

        // Search Tab
        Tab(value: 1, role: .search) {
          RefinedSearchView(
            appState: appState,
            selectedTab: $selectedTab,
            lastTappedTab: $lastTappedTab
          )
          .id(appState.userDID)
        }

        // Notifications Tab
        Tab("Notifications", systemImage: "bell", value: 2) {
          NotificationsView(
            appState: appState,
            selectedTab: $selectedTab,
            lastTappedTab: $lastTappedTab
          )
          .id(appState.userDID)
        }
        .badge(appState.notificationManager.unreadCount > 0 ? appState.notificationManager.unreadCount : 0)

        // Profile Tab - Hidden on iPhone to save space
        if !PlatformDeviceInfo.isPhone {
          Tab("Profile", systemImage: "person", value: 3) {
            NavigationStack(path: appState.navigationManager.pathBinding(for: 3)) {
              UnifiedProfileView(
                appState: appState,
                selectedTab: $selectedTab,
                lastTappedTab: $lastTappedTab,
                path: appState.navigationManager.pathBinding(for: 3)
              )
              .id(appState.userDID)
              .navigationDestination(for: NavigationDestination.self) { destination in
                NavigationHandler.viewForDestination(
                  destination,
                  path: appState.navigationManager.pathBinding(for: 3),
                  appState: appState,
                  selectedTab: $selectedTab
                )
              }
            }
          }
        }
      }
      .onAppear {
        // Theme is already applied during AppState initialization - no need to reapply here
        
        // Note: Theme change updates are now handled by @Observable system in AppState
        // No need for NotificationCenter observers that conflict with SwiftUI observation
          
        Task {
          // Only initialize feed on first load
          if !hasInitializedFeed {
            hasInitializedFeed = true
            
            // Restore last feed for current account
            await restoreLastFeedForAccount()
          }
        }
          
        navigationManager.registerTabSelectionCallback { newTab in
          selectedTab = newTab
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if (selectedTab == 0 && isRootView) || (selectedTab == 3 && !PlatformDeviceInfo.isPhone) {
          FAB(
            composeAction: { showingPostComposer = true },
            feedsAction: {},
            showFeedsButton: false
          )
          .padding(.bottom, 20)
          .padding(.trailing, 20)
          // Mark FAB as the source for the iOS 26 morph
          // Source tagging now occurs inside FAB on the compose button itself
        }
      }
      .sheet(isPresented: $showingPostComposer) {
        Group {
          if let draft = composerInitialDraft {
            PostComposerViewUIKit(
              restoringFromDraft: draft,
              appState: appState
            )
          } else {
            PostComposerViewUIKit(
              appState: appState
            )
          }
        }
        .applyAppStateEnvironment(appState)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .applyComposerNavigationTransition(
          enabled: (selectedTab == 0 || (selectedTab == 3 && !PlatformDeviceInfo.isPhone)),
          sourceID: "compose",
          namespace: composeTransitionNamespace
        )
      }
      .onChange(of: showingPostComposer) { _, isPresented in
        composerInitialDraft = isPresented ? appState.composerDraftManager.currentDraft : nil
      }
      .sheet(isPresented: $showingOnboarding) {
        WelcomeOnboardingView()
          .applyAppStateEnvironment(appState)
      }
      .onChange(of: appState.onboardingManager.showWelcomeSheet) { _, newValue in
        showingOnboarding = newValue
      }
      .onChange(of: showingOnboarding) { _, newValue in
        if !newValue && appState.onboardingManager.showWelcomeSheet {
          Task { @MainActor in
            appState.onboardingManager.completeWelcomeOnboarding()
          }
        }
      }
      .onChange(of: appState.userDID) { oldDID, newDID in
        // Account switched - restore last feed for this account (macOS version)
        guard oldDID != newDID else { return }
        logger.debug("🔄 Account switched from \(oldDID) to \(newDID) - restoring last feed")
        
        // Set flag to prevent saving during restoration
        isRestoringFeed = true
        
        // IMMEDIATELY reset feed synchronously to prevent overlay
        selectedFeed = .timeline
        currentFeedName = "Timeline"
        
        hasInitializedFeed = false
        isDrawerOpen = false
        
        // THEN restore last feed for new account asynchronously
        Task {
          await restoreLastFeedForAccount()
        }
      }
      .onChange(of: selectedFeed) { oldFeed, newFeed in
        if oldFeed.identifier != newFeed.identifier {
          saveLastFeedForAccount()
        }
      }
      .task(id: selectedFeed) {
        // Fetch feed name when selectedFeed changes to a custom feed (macOS version)
        if case .feed(let uri) = selectedFeed {
          // Fetch feed generator info to get display name
          if let client = appState.atProtoClient {
            do {
              let result = try await client.app.bsky.feed.getFeedGenerator(input: .init(feed: uri))
              if result.responseCode == 200, let data = result.data {
                await MainActor.run {
                  currentFeedName = data.view.displayName ?? "Feed"
                }
              } else {
                await MainActor.run {
                  currentFeedName = "Feed"
                }
              }
            } catch {
              logger.error("Failed to fetch feed name: \(error.localizedDescription)")
              await MainActor.run {
                currentFeedName = "Feed"
              }
            }
          }
        } else if case .timeline = selectedFeed {
          await MainActor.run {
            currentFeedName = "Timeline"
          }
        } else if case .list(_, let name) = selectedFeed {
          await MainActor.run {
            currentFeedName = name
          }
        }
      }
      #endif
      
      NetworkStatusIndicator()
    }
    #if targetEnvironment(macCatalyst)
    // Global Cmd-R binding for Mac Catalyst to refresh the current feed when on Home tab
    .overlay(alignment: .topLeading) {
      // Invisible button to register the keyboard shortcut reliably across the view
      Button(action: {
        Task { @MainActor in
          if selectedTab == 0 { // Only refresh on the Home tab
            let manager = FeedStateStore.shared.stateManager(for: selectedFeed, appState: appState)
            await manager.refresh()
          }
        }
      }) { EmptyView() }
      .keyboardShortcut("r", modifiers: .command)
      .opacity(0.001)
      .accessibilityHidden(true)
    }
    #endif
    // Provide the composer transition namespace to descendants so reply buttons
    // and other triggers can participate in the zoom transition to the composer.
    .environment(\.composerTransitionNamespace, composeTransitionNamespace)
  }
}

// MARK: - State Restoration Extensions

extension ContentView {
}

extension MainContentView {
  @MainActor
  func restoreUIState() async {
    guard !hasRestoredState else { return }
    hasRestoredState = true
  }
}


// MARK: - Conditional Navigation Transition Helper

extension View {
  @available(iOS 18.0, macOS 15.0, *)
  @ViewBuilder
  func applyComposerNavigationTransition(enabled: Bool, sourceID: String, namespace: Namespace.ID) -> some View {
    if enabled {
      self.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
    } else {
      self
    }
  }
}

// MARK: - ContentViewModifiers

private struct ContentViewModifiers: ViewModifier {
  let appStateManager: AppStateManager
  @Binding var showingComposerFromAccountSwitch: Bool

  private var pendingAlertBinding: Binding<AuthenticationManager.AuthAlert?> {
    Binding(
      get: { appStateManager.authentication.pendingAuthAlert },
      set: { _ in Task { await appStateManager.authentication.clearPendingAuthAlert() } }
    )
  }

  func body(content: Content) -> some View {
    content
      .alert(item: pendingAlertBinding, content: authAlertContent)
      .onChange(of: appStateManager.lifecycle) { _, newValue in
        if case .authenticated(let appState) = newValue {
          Task { @MainActor in
            await FeedStateStore.shared.triggerPostAuthenticationFeedLoad()
            appState.onboardingManager.checkForWelcomeOnboarding()
          }
        }
      }
      .onChange(of: appStateManager.pendingComposerDraft) { _, newValue in
        if let draft = newValue {
          logger.info("[ContentView] Pending composer draft detected after account switch - will reopen composer")
          logger.debug("[ContentView] Draft preview: text length \(draft.postText.count), media items \(draft.mediaItems.count)")

          Task { @MainActor in
            // Wait for transition overlay to clear (typically ~500ms)
            try? await Task.sleep(nanoseconds: 600_000_000)  // 600ms

            // Verify draft hasn't been manually cleared
            guard appStateManager.pendingComposerDraft != nil else {
              logger.debug("[ContentView] pendingComposerDraft was cleared before reopen - skipping")
              return
            }

            logger.info("[ContentView] Reopening composer with transferred draft")
            showingComposerFromAccountSwitch = true

            // Clear after presenting
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms buffer
            appStateManager.clearPendingComposerDraft()
            logger.debug("[ContentView] Cleared pendingComposerDraft after reopen")
          }
        }
      }
      .sheet(isPresented: $showingComposerFromAccountSwitch) {
        if let appState = appStateManager.lifecycle.appState {
          PostComposerViewUIKit(appState: appState)
        }
      }
      .modifier(AppStateThemeModifier(appStateManager: appStateManager))
  }

  private func authAlertContent(_ alert: AuthenticationManager.AuthAlert) -> Alert {
    Alert(
      title: Text(alert.title),
      message: Text(alert.message),
      dismissButton: .default(Text("OK"), action: {
        Task { await appStateManager.authentication.clearPendingAuthAlert() }
      })
    )
  }
}

// Helper modifier to apply theme/font only when authenticated
private struct AppStateThemeModifier: ViewModifier {
  let appStateManager: AppStateManager

  func body(content: Content) -> some View {
    if let appState = appStateManager.lifecycle.appState {
      content
        .applyTheme(appState.themeManager)
        .fontManager(appState.fontManager)
        .environment(\.toastManager, appState.toastManager)
    } else {
      content
    }
  }
}
