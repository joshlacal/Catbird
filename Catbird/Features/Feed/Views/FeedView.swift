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
        ProgressView("Loading feed...")
      }
    }
    // Search UI removed
    .environment(\.currentFeedType, fetch)
    // CRITICAL FIX: Use .onAppear on the Group to ensure stateManager is initialized
    // BEFORE .task runs, preventing the race condition where .task sees nil stateManager
    .onAppear {
      if stateManager == nil {
        logger.debug("Initializing stateManager synchronously on appear")
        stateManager = feedStateStore.stateManager(for: fetch, appState: appState)
        currentFetch = fetch
        
        // CRITICAL: Trigger initial data load immediately after creating stateManager
        // This ensures data loading happens even if .task already ran before stateManager existed
        if !hasAttemptedInitialLoad, !appState.isTransitioningAccounts {
          Task { @MainActor in
            if let manager = stateManager, manager.posts.isEmpty {
              hasAttemptedInitialLoad = true
              logger.debug("Loading initial data immediately after stateManager creation")
              await manager.loadInitialData()
            }
          }
        }
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
        hasAttemptedInitialLoad = true
        logger.debug("Loading initial data for feed: \(fetch.identifier)")
        await manager.loadInitialData()
      } else if stateManager != nil {
        hasAttemptedInitialLoad = true
        logger.debug("Skipping initial load - posts exist or transitioning accounts")
      }
    }
    .task(id: fetch.identifier) {
      // Handle feed type changes
      guard currentFetch != fetch else { return }
      
      logger.debug("Feed type changed from \(currentFetch?.identifier ?? "nil") to \(fetch.identifier)")
      appState.feedFeedbackManager.disable()

      // Switch to a dedicated state manager per feed to keep per-feed scroll state
      let newManager = feedStateStore.stateManager(for: fetch, appState: appState)
      self.stateManager = newManager
      self.currentFetch = fetch
      
      // Reset the initial load flag for the new feed type
      // This allows the new feed to load its data
      hasAttemptedInitialLoad = false

      // Load data for the new feed if empty, but NOT during account transition
      if newManager.posts.isEmpty, !appState.isTransitioningAccounts {
        hasAttemptedInitialLoad = true
        logger.debug("Loading initial data for new feed: \(fetch.identifier)")
        await newManager.loadInitialData()
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
          if let manager = stateManager, manager.posts.isEmpty, !hasAttemptedInitialLoad {
            hasAttemptedInitialLoad = true
            logger.debug("Loading initial data after account transition for feed: \(fetch.identifier)")
            await manager.loadInitialData()
          }
        }
      }
    }
    .onChange(of: scenePhase) { oldPhase, newPhase in
      logger.debug("Scene phase changed: \(String(describing: oldPhase)) -> \(String(describing: newPhase))")

      Task { @MainActor in
        await feedStateStore.handleScenePhaseChange(newPhase)
      }
    }
    .id((appState.userDID ?? "") + fetch.identifier) // Reset view when user or feed changes
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
