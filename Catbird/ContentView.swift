import Petrel
import SwiftUI

struct ContentView: View {
  @Environment(AppState.self) private var appState
  @State private var selectedTab = 0
  @State private var lastTappedTab: Int? = nil
  @State private var authRetryAttempted = false

  var body: some View {
    Group {
      let currentAuthState = appState.authState

      if case .authenticated = currentAuthState {
        MainContentView(
          selectedTab: $selectedTab,
          lastTappedTab: $lastTappedTab
        )
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
    .onChange(of: appState.authState) { oldValue, newValue in
      if case .authenticated = newValue {
        DispatchQueue.main.async {
          Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.1))
          }
        }
      }
    }
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

struct MainContentView: View {
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

  // Access the navigation manager directly
  private var navigationManager: AppNavigationManager {
    appState.navigationManager
  }

  var body: some View {
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
      }
      .onAppear {
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
        } else {
          // If no FAB, still provide space for tab bar
          Color.clear.frame(height: 49)
        }
      }
      .sheet(isPresented: $showingPostComposer) {
        PostComposerView(appState: appState)
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
  }
}
#Preview {
  ContentView()
    .environment(AppState())
}
