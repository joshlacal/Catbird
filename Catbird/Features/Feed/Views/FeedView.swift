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
  
  // Use the singleton FeedStateStore
  private var feedStateStore = FeedStateStore.shared
  
  // State
  @State private var isInitialized = false
  
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
      // Get or create state manager from the store
      let stateManager = feedStateStore.stateManager(for: fetch, appState: appState)
      
      FeedWithNewPostsIndicator(
        stateManager: stateManager,
        navigationPath: $path
      )
      .modifier(
        iOS18StateRestorationSupport(feedType: fetch)
      )
      #if DEBUG
      // Add debug gesture to test the indicator
      .onTapGesture(count: 3) {
        // Triple tap to trigger test indicator
        stateManager.debugTriggerNewPostsIndicator(count: 5)
        print("🐛 DEBUG: Triggered test new posts indicator via triple tap")
      }
      #endif
      .task(id: fetch.identifier) {
        // Set model context on first appearance
        if !isInitialized {
          isInitialized = true
          feedStateStore.setModelContext(modelContext)
          
          // Only load initial data on first initialization if posts are empty
          if stateManager.posts.isEmpty {
            logger.debug("Loading initial data for empty feed on first init: \(fetch.identifier)")
            await stateManager.loadInitialData()
          }
        } else if stateManager.posts.isEmpty && stateManager.currentFeedType.identifier != fetch.identifier {
          // Only load if switching to a different feed type that has no data
          logger.debug("Loading initial data for new feed type: \(fetch.identifier)")
          await stateManager.loadInitialData()
        } else {
          logger.debug("Skipping initial data load - feed already has \(stateManager.posts.count) posts")
        }
      }
      .onChange(of: fetch) { oldValue, newValue in
        guard oldValue != newValue else { return }
        
        logger.debug("Feed type changed from \(oldValue.identifier) to \(newValue.identifier)")
        
        // This is a user-initiated feed switch - mark it and trigger proper loading
        Task { @MainActor in
          await stateManager.updateFetchType(newValue, preserveScrollPosition: false)
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
