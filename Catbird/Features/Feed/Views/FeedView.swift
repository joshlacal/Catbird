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
  @Binding var path: NavigationPath
  @Binding var selectedTab: Int
  
  let fetch: FetchType
  
  // State
  @State private var stateManager: FeedStateManager?
  @State private var isInitialized = false
  
  // Performance
  private let logger = Logger(subsystem: "blue.catbird", category: "FeedView")
  
  // MARK: - Initialization
  
  init(appState: AppState, fetch: FetchType, path: Binding<NavigationPath>, selectedTab: Binding<Int>) {
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
        .task {
          if !isInitialized {
            isInitialized = true
            await stateManager.loadInitialData()
          }
        }
        .onChange(of: fetch) { oldValue, newValue in
          guard oldValue != newValue else { return }
          
          logger.debug("Feed type changed from \(oldValue.identifier) to \(newValue.identifier)")
          
          Task {
            await stateManager.updateFetchType(newValue)
          }
        }
      } else {
        Color.clear
          .onAppear {
            setupStateManager()
          }
      }
    }
  }
  
  // MARK: - Setup
  
  private func setupStateManager() {
    // Create the state manager with proper dependencies
    let feedManager = FeedManager(
      client: appState.atProtoClient,
      fetchType: fetch
    )
    
    let feedModel = FeedModel(
      feedManager: feedManager,
      appState: appState
    )
    
    self.stateManager = FeedStateManager(
      appState: appState,
      feedModel: feedModel,
      feedType: fetch
    )
  }
}

// MARK: - Preview

//#Preview {
//  @State var navigationPath = NavigationPath()
//  @State var selectedTab = 0
//  
//  NavigationStack(path: $navigationPath) {
//    FeedView(
//      appState: AppState.shared,
//      fetch: .timeline,
//      path: $navigationPath,
//      selectedTab: $selectedTab
//    )
//    .navigationTitle("Timeline")
//    .navigationBarTitleDisplayMode(.large)
//  }
//}
