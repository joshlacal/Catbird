import Foundation
import OSLog
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

  // For logging
  let id = UUID().uuidString.prefix(6)
  private let logger = Logger(subsystem: "blue.catbird", category: "HomeView")

  var body: some View {
    let navigationPath = appState.navigationManager.pathBinding(for: 0)
    
    mainNavigationView(navigationPath: navigationPath)
      .sheet(isPresented: $showingSettings) {
        SettingsView()
      }
      .onAppear {
        appState.navigationManager.updateCurrentTab(0)
      }
      .onChange(of: selectedFeed) { oldValue, newValue in
        handleSelectedFeedChange(oldValue: oldValue, newValue: newValue)
      }
      .onChange(of: lastTappedTab) { oldValue, newValue in
        handleLastTappedTabChange(oldValue: oldValue, newValue: newValue)
      }
      .onChange(of: navigationPath.wrappedValue) { oldPath, newPath in
        handleNavigationChange(oldCount: oldPath.count, newCount: newPath.count)
      }
  }
  
  @ViewBuilder
  private func mainNavigationView(navigationPath: Binding<NavigationPath>) -> some View {
    NavigationStack(path: navigationPath) {
      feedContentView(navigationPath: navigationPath)
        .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
        .ignoresSafeArea()
        .navigationTitle(currentFeedName)
        .toolbarTitleDisplayMode(.large)
        .ensureNavigationFonts()
        .toolbar {
          leadingToolbarContent
          trailingToolbarContent
        }
        .navigationDestination(for: NavigationDestination.self) { destination in
          NavigationHandler.viewForDestination(
            destination,
            path: navigationPath,
            appState: appState,
            selectedTab: .constant(0)
          )
          .ensureDeepNavigationFonts()
        }
    }
  }
  
  @ViewBuilder
  private func feedContentView(navigationPath: Binding<NavigationPath>) -> some View {
    // Use NativeFeedContentView for all iOS versions
    nativeFeedView(navigationPath: navigationPath)
  }
  
  @ViewBuilder
  private func nativeFeedView(navigationPath: Binding<NavigationPath>) -> some View {
    // Use the proven FeedView -> NativeFeedContentView integration pattern
    FeedView(
      fetch: selectedFeed,
      path: navigationPath,
      selectedTab: $selectedTab
    )
  }
  
  
  private var leadingToolbarContent: some ToolbarContent {
    ToolbarItem(placement: .navigationBarLeading) {
      Button(action: {
        isDrawerOpen = true
      }) {
        Image(systemName: "circle.grid.3x3.circle")
          .foregroundStyle(isRootView ? Color.accentColor : Color.secondary)
      }
      .disabled(!isRootView)
      .accessibilityLabel("Feed selector")
      .accessibilityHint("Opens feed selection drawer")
    }
  }
  
  private var trailingToolbarContent: some ToolbarContent {
    ToolbarItem(placement: .navigationBarTrailing) {
      Button(action: {
        showingSettings = true
      }) {
        UIKitAvatarView(
          did: appState.currentUserDID,
          client: appState.atProtoClient,
          size: 28
        )
      }
      .accessibilityLabel("Profile and settings")
      .accessibilityHint("Opens your profile and app settings")
      .accessibilityAddTraits(.isButton)
    }
  }

  private func handleSelectedFeedChange(oldValue: FetchType, newValue: FetchType) {
    if oldValue != newValue {
      // FeedView now handles its own model updates when feed changes
      logger.debug("[\(id)] Feed changed from \(oldValue.identifier) to \(newValue.identifier)")
    }
  }

  private func handleLastTappedTabChange(oldValue: Int?, newValue: Int?) {
    if newValue == 0, selectedTab == 0 {
      appState.tabTappedAgain = 0
      DispatchQueue.main.async {
        lastTappedTab = nil
      }
    }
  }

  private func handleNavigationChange(oldCount: Int, newCount: Int) {
    // Update isRootView based on navigation depth
    isRootView = (newCount == 0)

    // Log navigation state changes for debugging
    logger.debug(
      "[\(id)] Navigation changed: oldCount=\(oldCount), newCount=\(newCount), isRootView=\(isRootView)"
    )
  }
}
