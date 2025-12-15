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
        .platformIgnoresSafeArea()
        .navigationTitle(currentFeedName)
        #if os(iOS)
        .toolbarTitleDisplayMode(.large)
        #endif
        .ensureNavigationFonts()
        .toolbar {
          leadingToolbarContent
//          centerToolbarContent
          trailingToolbarContent
          #if targetEnvironment(macCatalyst)
          // Add a refresh button for Mac Catalyst and bind Cmd-R
          ToolbarItem(placement: .primaryAction) {
            Button {
              Task { @MainActor in
                let manager = FeedStateStore.shared.stateManager(for: selectedFeed, appState: appState)
                await manager.refresh()
              }
            } label: {
              Image(systemName: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh Feed")
            .accessibilityLabel("Refresh feed")
          }
          #endif
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
      ToolbarItem(placement: .topBarLeading) {
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
      Button(action: {
        showingSettings = true
      }) {
        let avatarURL = appState.currentUserProfile?.finalAvatarURL()

        return AvatarView(
          did: appState.userDID,
          client: appState.atProtoClient,
          size: 30,
          avatarURL: avatarURL
        )
        .scaledToFit()
        .frame(width: 30, height: 30)
        .clipShape(Circle())
        .id("\(appState.userDID)-\(appState.currentUserProfile?.avatar?.description ?? "noavatar")")
      }
      .buttonStyle(.plain)
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
