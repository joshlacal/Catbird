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
  @State private var stateManager: FeedStateManager?
  @State private var searchText: String = ""
  @State private var searchResults: [CachedFeedViewPost] = []
  @State private var showingResults: Bool = false
  
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
        .overlay(alignment: .top) {
          if showingResults {
            SemanticResultsList(
              results: searchResults,
              onSelect: { fvp in
                showingResults = false
                searchText = ""
                path.append(NavigationDestination.post(fvp.feedViewPost.post.uri))
              },
              onDismiss: {
                showingResults = false
              }
            )
            .transition(.move(edge: .top))
          }
        }
      } else {
        ProgressView()
          .onAppear {
            // Initialize state manager once
            self.stateManager = feedStateStore.stateManager(for: fetch, appState: appState)
          }
      }
    }
    .searchable(text: $searchText, placement: .toolbar, prompt: "Search this feed")
    .onSubmit(of: .search) {
      Task { @MainActor in
        guard let sm = stateManager else { return }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { showingResults = false; return }
        let hits = await sm.semanticSearch(q, topK: 30)
        searchResults = hits
        showingResults = true
      }
    }
    .onChange(of: searchText) { _, newValue in
      if newValue.isEmpty { showingResults = false }
    }
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

// MARK: - Semantic search results overlay

private struct SemanticResultsList: View {
  let results: [CachedFeedViewPost]
  let onSelect: (CachedFeedViewPost) -> Void
  let onDismiss: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Semantic results")
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Close") { onDismiss() }
          .buttonStyle(.borderless)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.ultraThinMaterial)

      Divider()

      List(results, id: \.id) { item in
        Button {
          onSelect(item)
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            if let text = item.mainFeedPost?.text, !text.isEmpty {
              Text(text)
                .appFont(AppTextRole.body)
                .lineLimit(3)
            } else {
              Text("(no text)")
                .appFont(AppTextRole.caption)
                .foregroundStyle(.secondary)
            }
            Text(item.feedViewPost.post.author.handle.description)
              .appFont(AppTextRole.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .listStyle(.plain)
      .frame(maxHeight: 360)
      .background(.ultraThinMaterial)
    }
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .shadow(radius: 8)
    .padding()
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
