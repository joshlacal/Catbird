import Petrel
import SwiftUI

/// The main home view that displays feeds and handles sidebar/drawer functionality
struct HomeView: View {
  @Environment(AppState.self) private var appState

  // Navigation and state bindings
  @Binding var selectedTab: Int
  @Binding var lastTappedTab: Int?
  @Binding var selectedFeed: FetchType
  @Binding var currentFeedName: String
  @Binding var isDrawerOpen: Bool
  @Binding var isRootView: Bool

  // Local state

  @State private var showingSettings = false
  @State private var isReturningFromView = false
  @State private var feedViewError: String? = nil
  // Key to force view recreation when feed changes
  @State private var feedViewKey = UUID()
  // Track last navigation time to detect returning from a view
  @State private var lastNavigationTime = Date()

  var body: some View {
    let navigationPath = appState.navigationManager.pathBinding(for: 0)
    return NavigationStack(path: navigationPath) {
      VStack {
        // Initialize FeedView with current settings
        initializeFeedView()

        // Display any errors that might have occurred
        if let error = feedViewError {
          Text("Error: \(error)")
            .foregroundStyle(.red)
            .font(.caption)
            .padding()
        }
      }
      .onAppear {
        // Update current tab index when this tab appears
          appState.navigationManager.updateCurrentTab(0)
      }
      .navigationDestination(for: NavigationDestination.self) { destination in
        NavigationHandler.viewForDestination(destination, path: navigationPath, appState: appState, selectedTab: $selectedTab)
          .navigationTitle(NavigationHandler.titleForDestination(destination))
      }
      .onChange(of: navigationPath.wrappedValue) { oldPath, newPath in
        handleNavigationChange(oldCount: oldPath.count, newCount: newPath.count)
      }
      .onChange(of: selectedFeed) { oldValue, newValue in
        handleSelectedFeedChange(oldValue: oldValue, newValue: newValue)
      }
      .onChange(of: lastTappedTab) { oldValue, newValue in
        handleLastTappedTabChange(oldValue: oldValue, newValue: newValue)
      }
      .onAppear {
        print(
          "📱 HomeView appeared, selectedTab: \(selectedTab), lastTappedTab: \(String(describing: lastTappedTab))"
        )
      }
      .navigationTitle(currentFeedName)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button {
            isDrawerOpen = true
          } label: {
            Image(systemName: "circle.grid.3x3.circle")
          }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
          Button {
            showingSettings = true
          } label: {
            Image(systemName: "gear")
          }
        }
      }
    }
    .sheet(isPresented: $showingSettings) {
      SettingsView()
    }
    .toolbarBackground(.visible, for: .tabBar)
    .tabItem {
      Label("Home", systemImage: "house")
    }
  }

  private func handleNavigationChange(oldCount: Int, newCount: Int) {
    // Update isRootView based on navigation depth
    isRootView = (newCount == 0)

    // Track navigation state to detect when we're returning from a view
    if oldCount > newCount {
      // We're returning from a deeper view
      isReturningFromView = true
      lastNavigationTime = Date()

      // Reset the flag after a short delay
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        isReturningFromView = false
      }
    }
  }

  private func handleSelectedFeedChange(oldValue: FetchType, newValue: FetchType) {
    // Force FeedView recreation when feed changes
    if oldValue != newValue {
      // Generate a new UUID to force the view to be recreated
      feedViewKey = UUID()

      // Clear any cached models to ensure fresh content
      Task { @MainActor in
        FeedModelContainer.shared.clearCache()
      }
    }
  }

  private func handleLastTappedTabChange(oldValue: Int?, newValue: Int?) {
    print(
      "📱 HomeView: lastTappedTab changed from \(String(describing: oldValue)) to \(String(describing: newValue))"
    )
    // Handle the case when home tab is tapped again
    if newValue == 0, selectedTab == 0 {
      print("📱 HomeView: Home tab tapped again! Setting tabTappedAgain to 0")
      // Trigger scroll to top using appState
      appState.tabTappedAgain = 0

      // Reset after handling
      DispatchQueue.main.async {
        lastTappedTab = nil
        print("📱 HomeView: Reset lastTappedTab to nil")
      }
    }
  }

  @ViewBuilder
  private func initializeFeedView() -> some View {
    let navigationPath = appState.navigationManager.pathBinding(for: 0)

    VStack {
      // Use feedViewKey to force recreation when selectedFeed changes
      FeedView(
        appState: appState,
        fetch: selectedFeed,
        path: navigationPath,
        selectedTab: $selectedTab,
        isReturningFromView: isReturningFromView
      )
      .id(feedViewKey)  // Key forces view recreation
    }
  }
}
