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
      } else {
        ProgressView()
          .task {
            // Initialize state manager once (defensive check)
            if stateManager == nil {
              stateManager = feedStateStore.stateManager(for: fetch, appState: appState)
              currentFetch = fetch
            }
          }
      }
    }
    // Search UI removed
    .environment(\.currentFeedType, fetch)
    .task(id: fetch.identifier) {
      // Check if this is a feed change
      if currentFetch != fetch {
        logger.debug("Feed type changed from \(currentFetch?.identifier ?? "nil") to \(fetch.identifier)")

        // Switch to a dedicated state manager per feed to keep per-feed scroll state
        let newManager = feedStateStore.stateManager(for: fetch, appState: appState)
        self.stateManager = newManager
        self.currentFetch = fetch

        // Set model context on first appearance
        if !isInitialized {
          isInitialized = true
          feedStateStore.setModelContext(modelContext)
        }

        // Load data for the new feed
        if newManager.posts.isEmpty {
          logger.debug("Loading initial data for new feed: \(fetch.identifier)")
          await newManager.loadInitialData()
        } else {
          logger.debug("New feed already has \(newManager.posts.count) posts")
        }
      } else if let stateManager = stateManager {
        // Same feed - just check if we need initial data
        // Set model context on first appearance
        if !isInitialized {
          isInitialized = true
          feedStateStore.setModelContext(modelContext)
        }

        // Always attempt to load initial data if posts are empty
        if stateManager.posts.isEmpty {
          logger.debug("Loading initial data for empty feed: \(fetch.identifier)")
          await stateManager.loadInitialData()
        } else {
          logger.debug("Skipping initial data load - feed already has \(stateManager.posts.count) posts")
        }
      }
    }
    .onChange(of: scenePhase) { oldPhase, newPhase in
      logger.debug("Scene phase changed: \(String(describing: oldPhase)) -> \(String(describing: newPhase))")

      Task { @MainActor in
        await feedStateStore.handleScenePhaseChange(newPhase)
      }
    }
    .id((appState.currentUserDID ?? "") + fetch.identifier) // Reset view when user or feed changes
  }
}

// MARK: - Preview

//#Preview {
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
