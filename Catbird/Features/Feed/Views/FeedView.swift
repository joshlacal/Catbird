//
//  FeedView.swift
//  Catbird
//
//  Main feed view that uses FeedCollectionView for UIKit performance
//

import Foundation
import SwiftUI
import Petrel
import os

/// Main feed view that handles FeedModel integration and delegates to FeedCollectionView for UIKit performance
struct FeedView: View {
  // MARK: - Properties
  @Environment(AppState.self) private var appState
  @Environment(\.modelContext) private var modelContext
  @Environment(\.scenePhase) private var scenePhase
  @Binding var path: NavigationPath
  @Binding var selectedTab: Int

  let fetch: FetchType

  // Use the singleton FeedStateStore (computed property to avoid retain cycles)
  private var feedStateStore: FeedStateStore { FeedStateStore.shared }

  // State
  @State private var isInitialized = false
  @State private var stateManager: FeedStateManager?
  @State private var currentFetch: FetchType?
  @State private var hasAttemptedInitialLoad = false
  // Search UI removed

  // Performance
  private let logger = Logger(subsystem: "blue.catbird", category: "FeedView")
  
  // MARK: - Initialization
  
  init(fetch: FetchType, path: Binding<NavigationPath>, selectedTab: Binding<Int>) {
    self.fetch = fetch
    self._path = path
    self._selectedTab = selectedTab
  }
  
  // MARK: - Body
  var body: some View {
    Group {
      if let stateManager = stateManager {
        FeedCollectionView(
          stateManager: stateManager,
          navigationPath: $path
        )
        .opacity(appState.isTransitioningAccounts ? 0.0 : 1.0)
        .animation(.easeInOut(duration: 0.3), value: appState.isTransitioningAccounts)
      } else {
        ProgressView("Loading feed…")
      }
    }
    // Search UI removed
    .environment(\.currentFeedType, fetch)
    // CRITICAL FIX: Use .onAppear on the Group to ensure stateManager is initialized
    // BEFORE .task runs, preventing the race condition where .task sees nil stateManager
    .onAppear {
      if stateManager == nil || stateManager?.isCleanedUp == true {
        logger.debug("Initializing stateManager synchronously on appear")
        stateManager = feedStateStore.stateManager(for: fetch, appState: appState)
        currentFetch = fetch
      }
      if let manager = stateManager {
        feedStateStore.attach(manager)
      }
      
      // CRITICAL: Always ensure we attempt to load data when the view appears
      // This handles fresh views after account switch where transition may have already completed
      if let manager = stateManager, !appState.isTransitioningAccounts {
        if manager.posts.isEmpty, !hasAttemptedInitialLoad {
          hasAttemptedInitialLoad = true
          Task { @MainActor in
            logger.debug("Loading initial data on appear for feed: \(fetch.identifier)")
            await performInitialLoad(with: manager)
          }
        }
      }
    }
    .onDisappear {
      if let manager = stateManager {
        feedStateStore.detach(manager)
      }
    }
    .task {
      // Set model context on first appearance (safe to do in .task)
      if !isInitialized {
        isInitialized = true
        feedStateStore.setModelContext(modelContext)
      }
      
      // CRITICAL FIX: Guard against multiple initial load attempts
      // The .task modifier can fire multiple times during view lifecycle
      guard !hasAttemptedInitialLoad else {
        logger.debug("Skipping initial load - already attempted")
        return
      }
      
      // Load initial data if posts are empty, but NOT during account transition
      // Account transition will trigger loading via StateInvalidationEvent
      if let manager = stateManager, manager.posts.isEmpty, !appState.isTransitioningAccounts {
        logger.debug("Loading initial data for feed: \(fetch.identifier)")
        await performInitialLoad(with: manager)
      } else if stateManager != nil {
        hasAttemptedInitialLoad = true
        logger.debug("Skipping initial load - posts exist or transitioning accounts")
      }
    }
    .task(id: fetch.identifier) {
      // Handle feed type changes
      guard currentFetch != fetch else { return }
      
      logger.debug("Feed type changed from \(currentFetch?.identifier ?? "nil") to \(fetch.identifier)")
      Task { await appState.feedFeedbackManager.flushInteractions() }

      if let oldManager = stateManager {
        feedStateStore.detach(oldManager)
      }
      // Switch to a dedicated state manager per feed to keep per-feed scroll state
      let newManager = feedStateStore.stateManager(for: fetch, appState: appState)
      feedStateStore.attach(newManager)
      self.stateManager = newManager
      self.currentFetch = fetch
      
      // Reset the initial load flag for the new feed type
      // This allows the new feed to load its data
      hasAttemptedInitialLoad = false

      // Load data for the new feed if empty, but NOT during account transition
      if newManager.posts.isEmpty, !appState.isTransitioningAccounts {
        logger.debug("Loading initial data for new feed: \(fetch.identifier)")
        await performInitialLoad(with: newManager)
      } else if !appState.isTransitioningAccounts {
        hasAttemptedInitialLoad = true
        logger.debug("New feed already has \(newManager.posts.count) posts")
      }
    }
    .onChange(of: appState.isTransitioningAccounts) { wasTransitioning, isTransitioning in
      // CRITICAL FIX: When account transition completes, ensure we load data if needed
      if wasTransitioning && !isTransitioning {
        logger.debug("Account transition completed - checking if initial load needed")
        Task { @MainActor in
          if let manager = stateManager, needsInitialLoad(manager) {
            logger.debug("Loading initial data after account transition for feed: \(fetch.identifier)")
            await performInitialLoad(with: manager)
          }
        }
      }
    }
    .onChange(of: scenePhase) { _, phase in
      // A first load that was held back or failed while the app was starting
      // gets another attempt when the app comes back to the foreground.
      guard phase == .active, !appState.isTransitioningAccounts,
            let manager = stateManager, needsInitialLoad(manager) else { return }
      Task { @MainActor in
        logger.debug("Retrying initial load on scene activation for feed: \(fetch.identifier)")
        await performInitialLoad(with: manager)
      }
    }
    .id((appState.userDID ?? "") + fetch.identifier) // Reset view when user or feed changes
  }

  // MARK: - Initial Load

  /// Whether the feed is still empty because its first load never ran, was
  /// skipped (cancelled or held back by an account switch), or failed.
  private func needsInitialLoad(_ manager: FeedStateManager) -> Bool {
    guard manager.posts.isEmpty else { return false }
    switch manager.loadingState {
    case .idle:
      return !hasAttemptedInitialLoad
    case .error:
      return true
    case .loading, .refreshing, .loadingMore:
      return false
    }
  }

  /// Runs the first load and leaves the feed eligible for another attempt when
  /// the load returned without posts or an error, which happens when the view's
  /// task is cancelled or an account switch is still settling during launch.
  @MainActor
  private func performInitialLoad(with manager: FeedStateManager) async {
    hasAttemptedInitialLoad = true
    await manager.loadInitialData()
    if manager.posts.isEmpty, case .idle = manager.loadingState {
      hasAttemptedInitialLoad = false
    }
  }
}

// MARK: - Preview

//#Preview {
//    @Previewable @Environment(AppState.self) var appState
//  @State var navigationPath = NavigationPath()
//  @State var selectedTab = 0
//  
//  NavigationStack(path: $navigationPath) {
//    FeedView(
//      fetch: .timeline,
//      path: $navigationPath,
//      selectedTab: $selectedTab
//    )
//    .navigationTitle("Timeline")
//    .toolbarTitleDisplayMode(.large)
//  }
//}
