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
  @State private var feedModel: FeedModel?

  // For logging
  let id = UUID().uuidString.prefix(6)
  private let logger = Logger(subsystem: "blue.catbird", category: "HomeView")

  var body: some View {
    let navigationPath = appState.navigationManager.pathBinding(for: 0)

    // Use NativeFeedContentView with direct UIKit integration for proper navigation bar behavior
    NavigationStack(path: navigationPath) {
      Group {
        if #available(iOS 18.0, *) {
          // Get posts reactively from feedModel
          let posts = feedModel?.applyFilters(withSettings: appState.feedFilterSettings) ?? []
          
          FullUIKitFeedWrapper(
            posts: posts,
            appState: appState,
            fetchType: selectedFeed,
            path: navigationPath,
            onScrollOffsetChanged: { _ in }
          )
          .task {
            // Initialize feedModel if needed
            if feedModel == nil {
              feedModel = FeedModelContainer.shared.getModel(for: selectedFeed, appState: appState)
            }
          }
        } else {
          FeedView(
            appState: appState,
            fetch: selectedFeed,
            path: navigationPath,
            selectedTab: $selectedTab
          )
        }
      }
      // Removed .id() modifier - view identity is managed by the wrapper
      .navigationTitle(currentFeedName)
      .navigationBarTitleDisplayMode(.large)
      .ensureNavigationFonts()
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button(action: {
            isDrawerOpen = true
          }) {
            Image(systemName: "circle.grid.3x3.circle")
              .foregroundStyle(isRootView ? Color.accentColor : Color.secondary)
          }
          .disabled(!isRootView)
        }

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
        }
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
    .sheet(isPresented: $showingSettings) {
      SettingsView()
    }
    .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
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

  private func handleSelectedFeedChange(oldValue: FetchType, newValue: FetchType) {
    if oldValue != newValue {
      // Update feedModel when switching feeds
      Task { @MainActor in
        feedModel = FeedModelContainer.shared.getModel(for: newValue, appState: appState)
      }
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
