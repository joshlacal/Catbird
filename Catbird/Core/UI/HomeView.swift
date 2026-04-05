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
  
  @State private var showingQuickFilter = false

  // For logging
  let id = UUID().uuidString.prefix(6)
  private let logger = Logger(subsystem: "blue.catbird", category: "HomeView")

  var body: some View {
    // Capture appState early to ensure it's available for sheet presentations
    let capturedAppState = appState
    let navigationPath = capturedAppState.navigationManager.pathBinding(for: 0)

    ZStack {
      mainNavigationView(navigationPath: navigationPath)
        .sheet(isPresented: $showingSettings) {
          SettingsView()
            .applyAppStateEnvironment(capturedAppState)
            .environment(capturedAppState)
        }
        .sheet(isPresented: $showingQuickFilter) {
          QuickFilterSheet()
            .applyAppStateEnvironment(capturedAppState)
            .environment(capturedAppState)
        }
    }
      .onAppear {
        capturedAppState.navigationManager.updateCurrentTab(0)
        // Sync isRootView on appear to recover from any stale state
        let currentPathCount = navigationPath.wrappedValue.count
        if currentPathCount == 0 && !isRootView {
          isRootView = true
        }
      }
      .onChange(of: selectedTab) { _, newTab in
        // When returning to the Home tab, re-sync isRootView from navigation path
        if newTab == 0 {
          let currentPathCount = navigationPath.wrappedValue.count
          let expectedIsRoot = currentPathCount == 0
          if isRootView != expectedIsRoot {
            isRootView = expectedIsRoot
            logger.debug("[\(id)] Synced isRootView to \(expectedIsRoot) on tab switch")
          }
        }
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
      .onChange(of: isDrawerOpen) { _, newValue in
        // When drawer closes, re-sync isRootView from the tab navigation path
        // to recover from any state corruption during drawer navigation
        if !newValue {
          let tabPathCount = navigationPath.wrappedValue.count
          if tabPathCount == 0 && !isRootView {
            isRootView = true
            logger.debug("[\(id)] Restored isRootView to true after drawer close")
          }
        }
      }
  }
  
  @ViewBuilder
  private func mainNavigationView(navigationPath: Binding<NavigationPath>) -> some View {
    #if os(macOS)
    NavigationSplitView {
      MacOSFeedsSidebar(
        selectedFeed: $selectedFeed,
        currentFeedName: $currentFeedName
      )
    } detail: {
      NavigationStack(path: navigationPath) {
        feedContentView(navigationPath: navigationPath)
          .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
          .navigationTitle(currentFeedName)
          .ensureNavigationFonts()
          .toolbar {
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
    .navigationSplitViewStyle(.balanced)
    #else
    NavigationStack(path: navigationPath) {
      feedContentView(navigationPath: navigationPath)
        .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
        .platformIgnoresSafeArea()
        .navigationTitle(currentFeedName)
        #if os(iOS)
        .toolbarTitleDisplayMode(.large)
        #endif
        .ensureNavigationFonts()
        #if !targetEnvironment(macCatalyst)
        .toolbar {
          leadingToolbarContent
//          centerToolbarContent
          trailingToolbarContent
        }
        #endif
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
    #endif
  }
  
  @ViewBuilder
  private func feedContentView(navigationPath: Binding<NavigationPath>) -> some View {
    nativeFeedView(navigationPath: navigationPath)
  }
  
  @ViewBuilder
  private func nativeFeedView(navigationPath: Binding<NavigationPath>) -> some View {
    FeedView(
      fetch: selectedFeed,
      path: navigationPath,
      selectedTab: $selectedTab
    )
  }
  
  
  private var leadingToolbarContent: some ToolbarContent {
    ToolbarItem(placement: leadingToolbarPlacement) {
      Button(action: {
        isDrawerOpen = true
      }) {
        Image(systemName: "square.grid.3x3.fill")
          .foregroundStyle(isRootView ? Color.accentColor : Color.secondary)
      }
      .disabled(!isRootView)
      .accessibilityLabel("Feed selector")
      .accessibilityHint("Opens feed selection drawer")
    }
  }

  private var leadingToolbarPlacement: ToolbarItemPlacement {
    #if os(iOS)
    .topBarLeading
    #else
    .automatic
    #endif
  }
  
//  private var centerToolbarContent: some ToolbarContent {
//    Group {
      // Filter button to the left of the trailing avatar
//      ToolbarItem(placement: .primaryAction) {
//        Button {
//          showingQuickFilter = true
//        } label: {
//          Image(systemName: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
//            .foregroundStyle(hasActiveFilters ? Color.accentColor : Color.secondary)
//        }
//        .accessibilityLabel("Filter feed")
//        .accessibilityHint("Opens quick filter options")
//      }
//    }
//  }
//
    
  private var hasActiveFilters: Bool {
    let quickFilters = [
      "Only Text Posts",
      "Only Media Posts",
      "Hide Reposts",
      "Hide Replies",
      "Hide Quote Posts",
      "Hide Link Posts"
    ]
    return quickFilters.contains { appState.feedFilterSettings.isFilterEnabled(name: $0) }
  }
  
  private var trailingToolbarContent: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      SettingsAvatarToolbarButton {
        showingSettings = true
      }
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
      Task { @MainActor in
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

#Preview("Home View") {
  HomeView(
    selectedTab: .constant(0),
    lastTappedTab: .constant(nil),
    selectedFeed: .constant(.timeline),
    currentFeedName: .constant("Following"),
    isDrawerOpen: .constant(false),
    isRootView: .constant(true)
  )
  .previewWithAuthenticatedState()
}
