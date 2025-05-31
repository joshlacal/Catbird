import Petrel
import SwiftUI
import ExyteChat

struct ContentView: View {
  @Environment(AppState.self) private var appState
  @State private var selectedTab = 0
  @State private var lastTappedTab: Int?
  @State private var authRetryAttempted = false

  var body: some View {
    Group {
      let currentAuthState = appState.authState

      if case .authenticated = currentAuthState {
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
      } else {
        LoginView()
      }
    }
    .onChange(of: appState.authState) { _, newValue in
      if case .authenticated = newValue {
        DispatchQueue.main.async {
          Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.1))
          }
        }
      }
    }
    .applyTheme(appState.themeManager)
    .fontManager(appState.fontManager)
  }
}

// MARK: - Loading View

struct ContentViewLoadingView: View {
  @Environment(AppState.self) private var appState
  let message: String

  var body: some View {
    VStack(spacing: 20) {
      ProgressView()
        .scaleEffect(1.5)

      Text(message)
        .font(.headline)
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
        .textScale(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
  }
}

// MARK: - Main Content Container View

@available(iOS 18.0, *)
struct MainContentView18: View {
  @Environment(AppState.self) private var appState
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

  // Access the navigation manager directly
  private var navigationManager: AppNavigationManager {
    appState.navigationManager
  }

  var body: some View {
    ZStack(alignment: .top) {
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

        // Chat Tab
        Tab("Messages", systemImage: "envelope", value: 4) {
            // Assuming ChatTabView is defined elsewhere (e.g., ChatUI.swift)
            ChatTabView(
                selectedTab: $selectedTab,
                lastTappedTab: $lastTappedTab
            )
            .id(appState.currentUserDID) // Ensure view identity on user change
        }
      }
      .onAppear {
          UITabBarItem.appearance().badgeColor = UIColor(Color.accentColor)
        // Apply theme immediately when view appears
        appState.themeManager.applyTheme(
          theme: appState.appSettings.theme,
          darkThemeMode: appState.appSettings.darkThemeMode
        )
        
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
        
        // Set up theme change observer to update UIKit appearances
        NotificationCenter.default.addObserver(
          forName: NSNotification.Name("ThemeChanged"),
          object: nil,
          queue: .main
        ) { _ in
          // Force update all UIKit components immediately
          if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            for window in windowScene.windows {
              // Force tab bars to update
              if let tabBarController = window.rootViewController?.children.first(where: { $0 is UITabBarController }) as? UITabBarController {
                tabBarController.tabBar.setNeedsDisplay()
                tabBarController.tabBar.layoutIfNeeded()
              }
              
              // Force all navigation bars in the window to update
              window.rootViewController?.view.subviews.forEach { subview in
                if let navBar = subview as? UINavigationBar {
                  navBar.setNeedsDisplay()
                  navBar.layoutIfNeeded()
                }
              }
              
              // Also recursively find navigation controllers and force their nav bars to update
              func updateNavigationBars(in viewController: UIViewController?) {
                guard let vc = viewController else { return }
                
                if let navController = vc as? UINavigationController {
                  navController.navigationBar.setNeedsDisplay()
                  navController.navigationBar.layoutIfNeeded()
                }
                
                vc.children.forEach { updateNavigationBars(in: $0) }
                
                if let presentedVC = vc.presentedViewController {
                  updateNavigationBars(in: presentedVC)
                }
              }
              
              updateNavigationBars(in: window.rootViewController)
            }
          }
        }
          
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
            .offset(y: -80)  // Position FAB above tab bar
          }
        } else if selectedTab == 4 {
            if appState.navigationManager.pathBinding(for: 4).wrappedValue.isEmpty {
              ChatFAB(newMessageAction: {
                showingNewMessageSheet = true
              })
              .offset(y: -80)  // Match the offset of the main FAB
            }
        } else {
          // If no FAB, still provide space for tab bar
          Color.clear.frame(height: 49)
        }
      }
    
      .sheet(isPresented: $showingPostComposer) {
        PostComposerView(appState: appState)
      }
      .sheet(isPresented: $showingNewMessageSheet) {
        NewMessageView()
      }

    } drawer: {
      FeedsStartPage(
        appState: appState,
        selectedFeed: $selectedFeed,
        currentFeedName: $currentFeedName,
        isDrawerOpen: $isDrawerOpen
      )
      }
      .ignoresSafeArea()
      .scrollDismissesKeyboard(.interactively)
      
      NetworkStatusIndicator()
    }
  }
}

@available(iOS 17.0, *)
struct MainContentView17: View {
  @Environment(AppState.self) private var appState
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

  // Access the navigation manager directly
  private var navigationManager: AppNavigationManager {
    appState.navigationManager
  }

  var body: some View {
    ZStack(alignment: .top) {
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

        // Chat Tab
        // Assuming ChatTabView is defined elsewhere (e.g., ChatUI.swift)
        ChatTabView(
            selectedTab: $selectedTab,
            lastTappedTab: $lastTappedTab
        )
        .id(appState.currentUserDID) // Ensure view identity on user change
        .tabItem {
            Label("Messages", systemImage: "envelope")
        }
        .tag(4)
      }
      .onAppear {
          UITabBarItem.appearance().badgeColor = UIColor(Color.accentColor)
        // Apply theme immediately when view appears
        appState.themeManager.applyTheme(
          theme: appState.appSettings.theme,
          darkThemeMode: appState.appSettings.darkThemeMode
        )

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
        
        // Set up theme change observer to update UIKit appearances
        NotificationCenter.default.addObserver(
          forName: NSNotification.Name("ThemeChanged"),
          object: nil,
          queue: .main
        ) { _ in
          // Force update all UIKit components immediately
          if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            for window in windowScene.windows {
              // Force tab bars to update
              if let tabBarController = window.rootViewController?.children.first(where: { $0 is UITabBarController }) as? UITabBarController {
                tabBarController.tabBar.setNeedsDisplay()
                tabBarController.tabBar.layoutIfNeeded()
              }
              
              // Force all navigation bars in the window to update
              window.rootViewController?.view.subviews.forEach { subview in
                if let navBar = subview as? UINavigationBar {
                  navBar.setNeedsDisplay()
                  navBar.layoutIfNeeded()
                }
              }
              
              // Also recursively find navigation controllers and force their nav bars to update
              func updateNavigationBars(in viewController: UIViewController?) {
                guard let vc = viewController else { return }
                
                if let navController = vc as? UINavigationController {
                  navController.navigationBar.setNeedsDisplay()
                  navController.navigationBar.layoutIfNeeded()
                }
                
                vc.children.forEach { updateNavigationBars(in: $0) }
                
                if let presentedVC = vc.presentedViewController {
                  updateNavigationBars(in: presentedVC)
                }
              }
              
              updateNavigationBars(in: window.rootViewController)
            }
          }
        }
          
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
            .offset(y: -80)  // Position FAB above tab bar
          }
        } else if selectedTab == 3 {
            if appState.navigationManager.pathBinding(for: 4).wrappedValue.isEmpty {
              ChatFAB(newMessageAction: {
                showingNewMessageSheet = true
              })
              .offset(y: -80)  // Match the offset of the main FAB
            }
        } else {
          // If no FAB, still provide space for tab bar
          Color.clear.frame(height: 49)
        }
      }
      .sheet(isPresented: $showingPostComposer) {
        PostComposerView(appState: appState)
      }
      .sheet(isPresented: $showingNewMessageSheet) {
        NewMessageView()
      }

      } drawer: {
        FeedsStartPage(
          appState: appState,
          selectedFeed: $selectedFeed,
          currentFeedName: $currentFeedName,
          isDrawerOpen: $isDrawerOpen
        )
      }
      .ignoresSafeArea()
      .scrollDismissesKeyboard(.interactively)
      
      NetworkStatusIndicator()
    }
  }
}
#Preview {
  ContentView()
    .environment(AppState())
}
