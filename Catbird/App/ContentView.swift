import OSLog
import Petrel
import SwiftUI
#if os(iOS)
import ExyteChat
#endif

struct ContentView: View {
  private let appState = AppState.shared
  @State private var selectedTab = 0
  @State private var lastTappedTab: Int?
  @State private var authRetryAttempted = false

  var body: some View {
    Group {
      let currentAuthState = appState.authState

      if case .authenticated = currentAuthState {
//          if #available(iOS 26.0, *) {
//            MainContentView26(
//              selectedTab: $selectedTab,
//              lastTappedTab: $lastTappedTab
//            )
//          } else
          if #available(iOS 18.0, *) {
            MainContentView18(
              selectedTab: $selectedTab,
              lastTappedTab: $lastTappedTab
            )
          } else {
            MainContentView17(
              selectedTab: $selectedTab,
              lastTappedTab: $lastTappedTab
            )
          }
      } else if case .authenticating = currentAuthState {
        ContentViewLoadingView(message: "Authenticating...")
      } else if case .initializing = currentAuthState {
        ContentViewLoadingView(message: "Initializing...")
          .onAppear {
            if !authRetryAttempted {
              DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Task {
                  authRetryAttempted = true
                  await appState.authManager.checkAuthenticationState()

                  if case .initializing = appState.authState {
                    try? await Task.sleep(for: .seconds(1))
                    await appState.authManager.checkAuthenticationState()
                  }
                }
              }
            }
          }
      } else if case .error(let message) = currentAuthState {
        // Handle authentication errors that require user intervention
        AuthErrorView(errorMessage: message, onRetry: {
          Task {
            appState.authManager.resetError()
            await appState.authManager.checkAuthenticationState()
          }
        })
      } else {
        LoginView()
      }
    }
    .onChange(of: appState.authState) { _, newValue in
      if case .authenticated = newValue {
        DispatchQueue.main.async {
          Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.1))
            // Check for onboarding after successful authentication
            appState.onboardingManager.checkForWelcomeOnboarding()
          }
        }
      } else if case .error(let message) = newValue {
        // Log authentication errors for debugging
        print("[ContentView] Authentication error: \(message)")
      }
    }
    .applyTheme(appState.themeManager)
    .fontManager(appState.fontManager)
//    .themedNavigationBar(appState.themeManager)
    // Theme and font changes are handled efficiently by the modifiers above
  }
}

// MARK: - Loading View

struct ContentViewLoadingView: View {
  private let appState = AppState.shared
  let message: String

  var body: some View {
    VStack(spacing: 20) {
      ProgressView()
        .scaleEffect(1.5)

      Text(message)
        .appFont(AppTextRole.headline)
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
        .textScale(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
  }
}

// MARK: - Authentication Error View

struct AuthErrorView: View {
  let errorMessage: String
  let onRetry: () -> Void
  
  private var errorInfo: (type: AuthenticationErrorHandler.AuthErrorType, message: String, shouldReAuthenticate: Bool) {
    // Create a mock error to use the handler
    let mockError = NSError(domain: "AuthError", code: 401, userInfo: [
      NSLocalizedDescriptionKey: errorMessage
    ])
    return AuthenticationErrorHandler.categorizeError(mockError)
  }
  
  var body: some View {
    VStack(spacing: 24) {
      VStack(spacing: 16) {
        Image(systemName: iconForErrorType(errorInfo.type))
          .font(.system(size: 60))
          .foregroundStyle(colorForErrorType(errorInfo.type))
        
        VStack(spacing: 8) {
          Text(AuthenticationErrorHandler.titleForErrorType(errorInfo.type))
            .appFont(AppTextRole.title2)
            .fontWeight(.semibold)
          
          Text(errorInfo.message)
            .appFont(AppTextRole.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
        }
      }
      
      VStack(spacing: 12) {
        Button(AuthenticationErrorHandler.actionButtonTitle(errorInfo.type)) {
          onRetry()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        
        if !errorMessage.isEmpty && errorInfo.type == .unknown {
          Text("Technical details: \(errorMessage)")
            .appFont(AppTextRole.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
    .padding()
  }
  
  private func iconForErrorType(_ type: AuthenticationErrorHandler.AuthErrorType) -> String {
    switch type {
    case .sessionExpired, .unauthorized, .tokenRefreshFailed:
      return "person.crop.circle.badge.exclamationmark"
    case .invalidCredentials:
      return "key.slash.fill"
    case .networkError:
      return "wifi.exclamationmark"
    case .serverError:
      return "server.rack"
    case .unknown:
      return "exclamationmark.triangle.fill"
    }
  }
  
  private func colorForErrorType(_ type: AuthenticationErrorHandler.AuthErrorType) -> Color {
    switch type {
    case .sessionExpired, .unauthorized, .tokenRefreshFailed, .invalidCredentials:
      return .orange
    case .networkError:
      return .blue
    case .serverError:
      return .red
    case .unknown:
      return .gray
    }
  }
}

// MARK: - Main Content Container View

@available(iOS 18.0, *)
struct MainContentView18: View {
  private let appState = AppState.shared
  @Binding var selectedTab: Int
  @Binding var lastTappedTab: Int?

  // Side drawer state for home tab
  @State private var isDrawerOpen = false
  @State private var isRootView = true
  @State private var selectedFeed: FetchType = .timeline
  @State private var currentFeedName: String = ""
  @State private var notificationBadgeCount: Int = 0

  // Add state for showing post composer
  @State private var showingPostComposer = false
  @State private var showingSettings = false
  @State private var showingNewMessageSheet = false
  @State private var hasInitializedFeed = false
  @State private var showingOnboarding = false

  // Access the navigation manager directly
  private var navigationManager: AppNavigationManager {
    appState.navigationManager
  }

  var body: some View {
    ZStack(alignment: .top) {
      #if os(iOS)
      SideDrawer(selectedTab: $selectedTab, isRootView: $isRootView, isDrawerOpen: $isDrawerOpen) {
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
            .id(appState.currentUserDID)
          }

          // Search Tab
          Tab(value: 1, role: .search) {
            RefinedSearchView(
              appState: appState,
              selectedTab: $selectedTab,
              lastTappedTab: $lastTappedTab
            )
            .id(appState.currentUserDID)
          }

          // Notifications Tab
          Tab("Notifications", systemImage: "bell", value: 2) {
            NotificationsView(
              appState: appState,
              selectedTab: $selectedTab,
              lastTappedTab: $lastTappedTab
            )
            .id(appState.currentUserDID)
          }
          .badge(notificationBadgeCount > 0 ? notificationBadgeCount : 0)

          Tab("Profile", systemImage: "person", value: 3) {
            NavigationStack(path: appState.navigationManager.pathBinding(for: 3)) {
              UnifiedProfileView(
                appState: appState,
                selectedTab: $selectedTab,
                lastTappedTab: $lastTappedTab,
                path: appState.navigationManager.pathBinding(for: 3)
              )
              .id(appState.currentUserDID)
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

          #if os(iOS)
          // Chat Tab (iOS only)
          Tab("Messages", systemImage: "envelope", value: 4) {
            ChatTabView(
              selectedTab: $selectedTab,
              lastTappedTab: $lastTappedTab
            )
            .id(appState.currentUserDID)
          }
          .badge(appState.chatUnreadCount > 0 ? appState.chatUnreadCount : 0)
          #endif
        }
        .onAppear {
          // Theme is already applied during AppState initialization - no need to reapply here
          
          // Initialize from notification manager
          notificationBadgeCount = appState.notificationManager.unreadCount

          // Set up notification observer
          NotificationCenter.default.addObserver(
            forName: NSNotification.Name("UnreadNotificationCountChanged"),
            object: nil,
            queue: .main
          ) { notification in
            if let count = notification.userInfo?["count"] as? Int {
              notificationBadgeCount = count
            }
          }
          
          // Note: Theme change updates are now handled by @Observable system in AppState
          // No need for NotificationCenter observers that conflict with SwiftUI observation
            
          Task {
            // Only initialize feed on first load
            if !hasInitializedFeed {
              hasInitializedFeed = true
              
              // First check for a pinned feed to use as default
              if let preferences = try? await appState.preferencesManager.getPreferences(),
                 let firstPinnedFeed = preferences.pinnedFeeds.first,
                 let uri = try? ATProtocolURI(uriString: firstPinnedFeed) {
                  
                let feedInfo = try? await appState.atProtoClient?.app.bsky.feed.getFeedGenerator(input: .init(feed: uri)).data
                  
                // Use the first pinned feed as default
                DispatchQueue.main.async {
                  selectedFeed = .feed(uri)
                  if let displayName = feedInfo?.view.displayName {
                    currentFeedName = displayName
                  } else {
                    currentFeedName = "Feed"
                  }
                }
              } else {
                // Fallback to timeline
                DispatchQueue.main.async {
                  selectedFeed = .timeline
                  currentFeedName = "Timeline"
                }
              }
            }
          }
            
          navigationManager.registerTabSelectionCallback { newTab in
            selectedTab = newTab
          }
        }
        .safeAreaInset(edge: .bottom) {
          if selectedTab == 0 || selectedTab == 3 {
            ZStack(alignment: .trailing) {
              // This creates space for the tab bar
              Color.clear.frame(height: 49)  // Tab bar height

              FAB(
                composeAction: { showingPostComposer = true },
                feedsAction: {},
                showFeedsButton: false
              )
              .offset(y: -100)  // Position FAB above tab bar
            }
          } else {
            // If no FAB, still provide space for tab bar
            Color.clear.frame(height: 49)
          }
        }
        .sheet(isPresented: $showingPostComposer) {
          PostComposerView(
            appState: appState,
            onMinimize: { composer in
              appState.composerDraftManager.storeDraft(ComposerDraft(from: composer))
              showingPostComposer = false
            }
          )
          .presentationDetents([PresentationDetent.medium, PresentationDetent.large])
          .presentationDragIndicator(.visible)
          .presentationBackground(.thinMaterial)
        }
        .sheet(isPresented: $showingNewMessageSheet) {
          NewMessageView()
            .presentationDetents([PresentationDetent.medium, PresentationDetent.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.thinMaterial)
        }
        .sheet(isPresented: $showingOnboarding) {
          WelcomeOnboardingView()
            .environment(appState)
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
      } drawer: {
        FeedsStartPage(
          appState: appState,
          selectedFeed: $selectedFeed,
          currentFeedName: $currentFeedName,
          isDrawerOpen: $isDrawerOpen
        )
      }
      .platformIgnoresSafeArea()
      .scrollDismissesKeyboard(.interactively)
      
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
          .id(appState.currentUserDID)
        }

        // Search Tab
        Tab(value: 1, role: .search) {
          RefinedSearchView(
            appState: appState,
            selectedTab: $selectedTab,
            lastTappedTab: $lastTappedTab
          )
          .id(appState.currentUserDID)
        }

        // Notifications Tab
        Tab("Notifications", systemImage: "bell", value: 2) {
          NotificationsView(
            appState: appState,
            selectedTab: $selectedTab,
            lastTappedTab: $lastTappedTab
          )
          .id(appState.currentUserDID)
        }
        .badge(notificationBadgeCount > 0 ? notificationBadgeCount : 0)

        Tab("Profile", systemImage: "person", value: 3) {
          NavigationStack(path: appState.navigationManager.pathBinding(for: 3)) {
            UnifiedProfileView(
              appState: appState,
              selectedTab: $selectedTab,
              lastTappedTab: $lastTappedTab,
              path: appState.navigationManager.pathBinding(for: 3)
            )
            .id(appState.currentUserDID)
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
      .onAppear {
        // Theme is already applied during AppState initialization - no need to reapply here
        
        // Initialize from notification manager
        notificationBadgeCount = appState.notificationManager.unreadCount

        // Set up notification observer
        NotificationCenter.default.addObserver(
          forName: NSNotification.Name("UnreadNotificationCountChanged"),
          object: nil,
          queue: .main
        ) { notification in
          if let count = notification.userInfo?["count"] as? Int {
            notificationBadgeCount = count
          }
        }
        
        // Note: Theme change updates are now handled by @Observable system in AppState
        // No need for NotificationCenter observers that conflict with SwiftUI observation
          
        Task {
          // Only initialize feed on first load
          if !hasInitializedFeed {
            hasInitializedFeed = true
            
            // First check for a pinned feed to use as default
            if let preferences = try? await appState.preferencesManager.getPreferences(),
               let firstPinnedFeed = preferences.pinnedFeeds.first,
               let uri = try? ATProtocolURI(uriString: firstPinnedFeed) {
                
              let feedInfo = try? await appState.atProtoClient?.app.bsky.feed.getFeedGenerator(input: .init(feed: uri)).data
                
              // Use the first pinned feed as default
              DispatchQueue.main.async {
                selectedFeed = .feed(uri)
                if let displayName = feedInfo?.view.displayName {
                  currentFeedName = displayName
                } else {
                  currentFeedName = "Feed"
                }
              }
            } else {
              // Fallback to timeline
              DispatchQueue.main.async {
                selectedFeed = .timeline
                currentFeedName = "Timeline"
              }
            }
          }
        }
          
        navigationManager.registerTabSelectionCallback { newTab in
          selectedTab = newTab
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if selectedTab == 0 || selectedTab == 3 {
          FAB(
            composeAction: { showingPostComposer = true },
            feedsAction: {},
            showFeedsButton: false
          )
          .padding(.bottom, 20)
          .padding(.trailing, 20)
        }
      }
      .sheet(isPresented: $showingPostComposer) {
        PostComposerView(
          appState: appState,
          onMinimize: { composer in
            appState.composerDraftManager.storeDraft(ComposerDraft(from: composer))
            showingPostComposer = false
          }
        )
      }
      .sheet(isPresented: $showingOnboarding) {
        WelcomeOnboardingView()
          .environment(appState)
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
      #endif
      
      NetworkStatusIndicator()
    }
  }
}

@available(iOS 17.0, *)
struct MainContentView17: View {
  private let appState = AppState.shared
  @Binding var selectedTab: Int
  @Binding var lastTappedTab: Int?

  // Side drawer state for home tab
  @State private var isDrawerOpen = false
  @State private var isRootView = true
  @State private var selectedFeed: FetchType = .timeline
  @State private var currentFeedName: String = "Timeline"
  @State private var notificationBadgeCount: Int = 0

  // Add state for showing post composer
  @State private var showingPostComposer = false
  @State private var showingSettings = false
  @State private var showingNewMessageSheet = false
  @State private var hasInitializedFeed = false
  @State private var showingOnboarding = false

  // Access the navigation manager directly
  private var navigationManager: AppNavigationManager {
    appState.navigationManager
  }

  var body: some View {
    ZStack(alignment: .top) {
      #if os(iOS)
      SideDrawer(selectedTab: $selectedTab, isRootView: $isRootView, isDrawerOpen: $isDrawerOpen) {
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
        HomeView(
          selectedTab: $selectedTab,
          lastTappedTab: $lastTappedTab,
          selectedFeed: $selectedFeed,
          currentFeedName: $currentFeedName,
          isDrawerOpen: $isDrawerOpen,
          isRootView: $isRootView
        )
        .id(appState.currentUserDID)
        .tabItem {
          Label("Home", systemImage: "house")
        }
        .tag(0)

        // Search Tab
        RefinedSearchView(
          appState: appState,
          selectedTab: $selectedTab,
          lastTappedTab: $lastTappedTab
        )
        .id(appState.currentUserDID)
        .tabItem {
          Label("Search", systemImage: "magnifyingglass")
        }
        .tag(1)

        // Notifications Tab
        ZStack(alignment: .topTrailing) {
          NotificationsView(
            appState: appState,
            selectedTab: $selectedTab,
            lastTappedTab: $lastTappedTab
          )
          .id(appState.currentUserDID)
          
        }
        .tabItem {
          // Custom badge is done in the tabItem
          Label {
            Text("Notifications")
          } icon: {
            if notificationBadgeCount > 0 {
              ZStack {
                Image(systemName: "bell")
              }
            } else {
              Image(systemName: "bell")
            }
          }
        }
        .badge(notificationBadgeCount > 0 ? notificationBadgeCount : 0)
        .tag(2)

        // Profile Tab
        NavigationStack(path: appState.navigationManager.pathBinding(for: 3)) {
          UnifiedProfileView(
            appState: appState,
            selectedTab: $selectedTab,
            lastTappedTab: $lastTappedTab,
            path: appState.navigationManager.pathBinding(for: 3)
          )
          .id(appState.currentUserDID)
          .navigationDestination(for: NavigationDestination.self) { destination in
            NavigationHandler.viewForDestination(
              destination,
              path: appState.navigationManager.pathBinding(for: 3),
              appState: appState,
              selectedTab: $selectedTab
            )
          }
        }
        .tabItem {
          Label("Profile", systemImage: "person")
        }
        .tag(3)

        #if os(iOS)
        // Chat Tab (iOS only)
        ChatTabView(
            selectedTab: $selectedTab,
            lastTappedTab: $lastTappedTab
        )
        .id(appState.currentUserDID) // Ensure view identity on user change
        .tabItem {
            Label("Messages", systemImage: "envelope")
        }
        .badge(appState.chatUnreadCount > 0 ? appState.chatUnreadCount : 0)
        .tag(4)
        #endif
      }
      .onAppear {
        // Theme is already applied during AppState initialization - no need to reapply here

        // Initialize from notification manager
        notificationBadgeCount = appState.notificationManager.unreadCount

        // Set up notification observer
        NotificationCenter.default.addObserver(
          forName: NSNotification.Name("UnreadNotificationCountChanged"),
          object: nil,
          queue: .main
        ) { notification in
          if let count = notification.userInfo?["count"] as? Int {
            notificationBadgeCount = count
          }
        }
        
        // Note: Theme change updates are now handled by @Observable system in AppState
        // No need for NotificationCenter observers that conflict with SwiftUI observation
          
        Task {
          // Only initialize feed on first load
          if !hasInitializedFeed {
            hasInitializedFeed = true
            
            // First check for a pinned feed to use as default
            if let preferences = try? await appState.preferencesManager.getPreferences(),
               let firstPinnedFeed = preferences.pinnedFeeds.first,
               let uri = try? ATProtocolURI(uriString: firstPinnedFeed) {
              // Use the first pinned feed as default
              DispatchQueue.main.async {
                selectedFeed = .feed(uri)
                // Use a simple default name that will be updated when FeedsStartPage loads
                currentFeedName = "Feed"
              }
            } else {
              // Fallback to timeline
              DispatchQueue.main.async {
                selectedFeed = .timeline
                currentFeedName = "Timeline"
              }
            }
          }
        }
          
        navigationManager.registerTabSelectionCallback { newTab in
          selectedTab = newTab
        }
      }
      .safeAreaInset(edge: .bottom) {
        if selectedTab == 0 {
          ZStack(alignment: .trailing) {
            // This creates space for the tab bar
            Color.clear.frame(height: 49)  // Tab bar height

            FAB(
              composeAction: { showingPostComposer = true },
              feedsAction: {},
              showFeedsButton: false
            )
            .offset(y: -100)  // Position FAB above tab bar
          }
        } else {
          // If no FAB, still provide space for tab bar
          Color.clear.frame(height: 49)
        }
      }
      .sheet(isPresented: $showingPostComposer) {
        PostComposerView(
          appState: appState,
          onMinimize: { composer in
            appState.composerDraftManager.storeDraft(ComposerDraft(from: composer))
            showingPostComposer = false
          }
        )
        .presentationDetents([PresentationDetent.medium, PresentationDetent.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.thinMaterial)
      }
      .sheet(isPresented: $showingNewMessageSheet) {
        NewMessageView()
          .presentationDetents([PresentationDetent.medium, PresentationDetent.large])
          .presentationDragIndicator(.visible)
          .presentationBackground(.thinMaterial)
      }
      .sheet(isPresented: $showingOnboarding) {
        WelcomeOnboardingView()
          .environment(appState)
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
      } drawer: {
        FeedsStartPage(
          appState: appState,
          selectedFeed: $selectedFeed,
          currentFeedName: $currentFeedName,
          isDrawerOpen: $isDrawerOpen
        )
      }
      .platformIgnoresSafeArea()
      .scrollDismissesKeyboard(.interactively)
      
      #elseif os(macOS)
      // macOS content goes here - similar to iOS but without SideDrawer
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
        HomeView(
          selectedTab: $selectedTab,
          lastTappedTab: $lastTappedTab,
          selectedFeed: $selectedFeed,
          currentFeedName: $currentFeedName,
          isDrawerOpen: $isDrawerOpen,
          isRootView: $isRootView
        )
        .id(appState.currentUserDID)
        .tabItem {
          Label("Home", systemImage: "house")
        }
        .tag(0)

        // Search Tab
        RefinedSearchView(
          appState: appState,
          selectedTab: $selectedTab,
          lastTappedTab: $lastTappedTab
        )
        .id(appState.currentUserDID)
        .tabItem {
          Label("Search", systemImage: "magnifyingglass")
        }
        .tag(1)

        // Notifications Tab
        NotificationsView(
          appState: appState,
          selectedTab: $selectedTab,
          lastTappedTab: $lastTappedTab
        )
        .id(appState.currentUserDID)
        .tabItem {
          Label("Notifications", systemImage: "bell")
        }
        .badge(notificationBadgeCount > 0 ? notificationBadgeCount : 0)
        .tag(2)

        // Profile Tab
        NavigationStack(path: appState.navigationManager.pathBinding(for: 3)) {
          UnifiedProfileView(
            appState: appState,
            selectedTab: $selectedTab,
            lastTappedTab: $lastTappedTab,
            path: appState.navigationManager.pathBinding(for: 3)
          )
          .id(appState.currentUserDID)
          .navigationDestination(for: NavigationDestination.self) { destination in
            NavigationHandler.viewForDestination(
              destination,
              path: appState.navigationManager.pathBinding(for: 3),
              appState: appState,
              selectedTab: $selectedTab
            )
          }
        }
        .tabItem {
          Label("Profile", systemImage: "person")
        }
        .tag(3)
      }
      .onAppear {
        // Similar initialization as iOS
        notificationBadgeCount = appState.notificationManager.unreadCount

        NotificationCenter.default.addObserver(
          forName: NSNotification.Name("UnreadNotificationCountChanged"),
          object: nil,
          queue: .main
        ) { notification in
          if let count = notification.userInfo?["count"] as? Int {
            notificationBadgeCount = count
          }
        }
          
        Task {
          if !hasInitializedFeed {
            hasInitializedFeed = true
            
            if let preferences = try? await appState.preferencesManager.getPreferences(),
               let firstPinnedFeed = preferences.pinnedFeeds.first,
               let uri = try? ATProtocolURI(uriString: firstPinnedFeed) {
              DispatchQueue.main.async {
                selectedFeed = .feed(uri)
                currentFeedName = "Feed"
              }
            } else {
              DispatchQueue.main.async {
                selectedFeed = .timeline
                currentFeedName = "Timeline"
              }
            }
          }
        }
          
        navigationManager.registerTabSelectionCallback { newTab in
          selectedTab = newTab
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if selectedTab == 0 {
          FAB(
            composeAction: { showingPostComposer = true },
            feedsAction: {},
            showFeedsButton: false
          )
          .padding(.bottom, 20)
          .padding(.trailing, 20)
        }
      }
      .sheet(isPresented: $showingPostComposer) {
        PostComposerView(
          appState: appState,
          onMinimize: { composer in
            appState.composerDraftManager.storeDraft(ComposerDraft(from: composer))
            showingPostComposer = false
          }
        )
      }
      .sheet(isPresented: $showingOnboarding) {
        WelcomeOnboardingView()
          .environment(appState)
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
      #endif
      
      NetworkStatusIndicator()
    }
  }
}

// MARK: - iOS 26+ Main Content View with TabView Bottom Accessory

//@available(iOS 26.0, *)
//struct MainContentView26: View {
//  private let appState = AppState.shared
//  @Binding var selectedTab: Int
//  @Binding var lastTappedTab: Int?
//
//  // Side drawer state for home tab
//  @State private var isDrawerOpen = false
//  @State private var isRootView = true
//  @State private var selectedFeed: FetchType = .timeline
//  @State private var currentFeedName: String = ""
//  @State private var notificationBadgeCount: Int = 0
//
//  // Remove FAB-related state since we're using bottom accessory
//  @State private var showingSettings = false
//  @State private var showingNewMessageSheet = false
//  @State private var hasInitializedFeed = false
//  @State private var showingOnboarding = false
//
//  // Access the navigation manager directly
//  private var navigationManager: AppNavigationManager {
//    appState.navigationManager
//  }
//
//  var body: some View {
//    ZStack(alignment: .top) {
//      SideDrawer(selectedTab: $selectedTab, isRootView: $isRootView, isDrawerOpen: $isDrawerOpen) {
//        TabView(
//          selection: Binding(
//            get: { selectedTab },
//            set: { newValue in
//              if selectedTab == newValue {
//                logger.debug("📱 TabView: Same tab tapped again: \(newValue)")
//                lastTappedTab = newValue
//              }
//              selectedTab = newValue
//
//              // Update the navigation manager with the new tab index
//              navigationManager.updateCurrentTab(newValue)
//            }
//          )
//        ) {
//        // Home Tab
//        Tab("Home", systemImage: "house", value: 0) {
//          HomeView(
//            selectedTab: $selectedTab,
//            lastTappedTab: $lastTappedTab,
//            selectedFeed: $selectedFeed,
//            currentFeedName: $currentFeedName,
//            isDrawerOpen: $isDrawerOpen,
//            isRootView: $isRootView
//          )
//          .id(appState.currentUserDID)
//        }
//
//        // Search Tab
//        Tab(value: 1, role: .search) {
//          RefinedSearchView(
//            appState: appState,
//            selectedTab: $selectedTab,
//            lastTappedTab: $lastTappedTab
//          )
//          .id(appState.currentUserDID)
//        }
//
//        // Notifications Tab
//        Tab("Notifications", systemImage: "bell", value: 2) {
//          NotificationsView(
//            appState: appState,
//            selectedTab: $selectedTab,
//            lastTappedTab: $lastTappedTab
//          )
//          .id(appState.currentUserDID)
//        }
//        .badge(notificationBadgeCount > 0 ? notificationBadgeCount : 0)
//
//        Tab("Profile", systemImage: "person", value: 3) {
//          NavigationStack(path: appState.navigationManager.pathBinding(for: 3)) {
//            UnifiedProfileView(
//              appState: appState,
//              selectedTab: $selectedTab,
//              lastTappedTab: $lastTappedTab,
//              path: appState.navigationManager.pathBinding(for: 3)
//            )
//            .id(appState.currentUserDID)
//            .navigationDestination(for: NavigationDestination.self) { destination in
//              NavigationHandler.viewForDestination(
//                destination,
//                path: appState.navigationManager.pathBinding(for: 3),
//                appState: appState,
//                selectedTab: $selectedTab
//              )
//            }
//          }
//        }
//
//        // Chat Tab
//        Tab("Messages", systemImage: "envelope", value: 4) {
//          ChatTabView(
//            selectedTab: $selectedTab,
//            lastTappedTab: $lastTappedTab
//          )
//          .id(appState.currentUserDID)
//        }
//        .badge(appState.chatUnreadCount > 0 ? appState.chatUnreadCount : 0)
//      }
//          
//      // iOS 26 TabView Bottom Accessory
//      .tabViewBottomAccessory {
//          TabViewBottomAccessoryWrapper()
//          .environment(appState)
//      }
//      .tabBarMinimizeBehavior(.onScrollDown)
//      .onAppear {
//        // Initialize from notification manager
//        notificationBadgeCount = appState.notificationManager.unreadCount
//
//        // Set up notification observer
//        NotificationCenter.default.addObserver(
//          forName: NSNotification.Name("UnreadNotificationCountChanged"),
//          object: nil,
//          queue: .main
//        ) { notification in
//          if let count = notification.userInfo?["count"] as? Int {
//            notificationBadgeCount = count
//          }
//        }
//        
//        Task {
//          // Only initialize feed on first load
//          if !hasInitializedFeed {
//            hasInitializedFeed = true
//            
//            // First check for a pinned feed to use as default
//            if let preferences = try? await appState.preferencesManager.getPreferences(),
//               let firstPinnedFeed = preferences.pinnedFeeds.first,
//               let uri = try? ATProtocolURI(uriString: firstPinnedFeed) {
//              
//              let feedInfo = try? await appState.atProtoClient?.app.bsky.feed.getFeedGenerator(input: .init(feed: uri)).data
//              
//              // Use the first pinned feed as default
//              DispatchQueue.main.async {
//                selectedFeed = .feed(uri)
//                if let displayName = feedInfo?.view.displayName {
//                  currentFeedName = displayName
//                } else {
//                  currentFeedName = "Feed"
//                }
//              }
//            } else {
//              // Fallback to timeline
//              DispatchQueue.main.async {
//                selectedFeed = .timeline
//                currentFeedName = "Timeline"
//              }
//            }
//          }
//        }
//        
//        navigationManager.registerTabSelectionCallback { newTab in
//          selectedTab = newTab
//        }
//      }
//      // No FAB safeAreaInset needed - bottom accessory handles this
//      #if os(iOS)
//      .sheet(isPresented: $showingNewMessageSheet) {
//        NewMessageView()
//      }
//      .sheet(isPresented: $showingOnboarding) {
//        WelcomeOnboardingView()
//          .environment(appState)
//      }
//      .onChange(of: appState.onboardingManager.showWelcomeSheet) { _, newValue in
//        showingOnboarding = newValue
//      }
//      .onChange(of: showingOnboarding) { _, newValue in
//        if !newValue && appState.onboardingManager.showWelcomeSheet {
//          Task { @MainActor in
//            appState.onboardingManager.completeWelcomeOnboarding()
//          }
//        }
//      }
//
//      } drawer: {
//        FeedsStartPage(
//          appState: appState,
//          selectedFeed: $selectedFeed,
//          currentFeedName: $currentFeedName,
//          isDrawerOpen: $isDrawerOpen
//        )
//      }
//      .ignoresSafeArea()
//      .scrollDismissesKeyboard(.interactively)
//      
//      NetworkStatusIndicator()
//    }
//  }
//}