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
            }
          }
      }
    }
    // Search UI removed
    .environment(\.currentFeedType, fetch)
    .task(id: fetch.identifier) {
      guard let stateManager = stateManager else { return }
      
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
    .onChange(of: fetch) { oldValue, newValue in
      guard oldValue != newValue else { return }
      logger.debug("Feed type changed from \(oldValue.identifier) to \(newValue.identifier)")
      
      // Switch to a dedicated state manager per feed to keep per-feed scroll state
      let newManager = feedStateStore.stateManager(for: newValue, appState: appState)
      self.stateManager = newManager
      Task { @MainActor in
        if newManager.posts.isEmpty { await newManager.loadInitialData() }
      }
    }
      .onChange(of: scenePhase) { oldPhase, newPhase in
        logger.debug("Scene phase changed: \(String(describing: oldPhase)) -> \(String(describing: newPhase))")
        
        Task { @MainActor in
          await feedStateStore.handleScenePhaseChange(newPhase)
        }
      }
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
