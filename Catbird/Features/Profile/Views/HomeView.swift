import Foundation
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
  @State private var feedViewError: String?
  @State private var feedViewKey = UUID()
  @State private var lastNavigationTime = Date()
  @State private var navigationStackKey = UUID()

  // For logging
  let id = UUID().uuidString.prefix(6)

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
            .appFont(AppTextRole.caption)
            .padding()
        }
      }
      .onAppear {
        // Update current tab index when this tab appears
        appState.navigationManager.updateCurrentTab(0)
        
        // Apply theme immediately to ensure navigation bar is correct
        appState.themeManager.applyTheme(
          theme: appState.appSettings.theme,
          darkThemeMode: appState.appSettings.darkThemeMode
        )
        
        // Note: Navigation bars are already updated by ThemeManager.applyTheme()
        // No need to recreate the entire navigation stack on theme changes
      }
      .navigationDestination(for: NavigationDestination.self) { destination in
        NavigationHandler.viewForDestination(
          destination, path: navigationPath, appState: appState, selectedTab: $selectedTab
        )
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
      .navigationTitle(currentFeedName)
      .toolbar {
        // Leading toolbar item
        ToolbarItem(placement: .navigationBarLeading) {
          Button {
            isDrawerOpen = true
          } label: {
            Image(systemName: "circle.grid.3x3.circle")
          }
        }

        // Avatar toolbar item - now using UIKitAvatarView
        ToolbarItem(placement: .navigationBarTrailing) {
          Button {
            showingSettings = true
          } label: {
            UIKitAvatarView(
              did: appState.currentUserDID,
              client: appState.atProtoClient,
              size: 24
            )
            .frame(width: 24, height: 24)
            // Force recreation when DID changes
            .id("avatar-\(appState.currentUserDID ?? "none")")
            .overlay {
              Circle()
                .stroke(Color.primary.opacity(0.5), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.2), radius: 1, x: 0, y: 1)
            .accessibilityLabel("User Avatar")
          }
        }
      }
    }
    .id(navigationStackKey)
    .sheet(isPresented: $showingSettings) {
      SettingsView()
    }
    .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
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
    // Handle the case when home tab is tapped again
    if newValue == 0, selectedTab == 0 {
      // Trigger scroll to top using appState
      appState.tabTappedAgain = 0

      // Reset after handling
      DispatchQueue.main.async {
        lastTappedTab = nil
      }
    }
  }

  @ViewBuilder
  private func initializeFeedView() -> some View {
    let navigationPath = appState.navigationManager.pathBinding(for: 0)

    VStack(alignment: .center) {
      // Use feedViewKey to force recreation when selectedFeed changes
      FeedView(
        appState: appState,
        fetch: selectedFeed,
        path: navigationPath,
        selectedTab: $selectedTab,
        isReturningFromView: isReturningFromView
      )
      .id(feedViewKey.uuidString)
    }
  }
}
