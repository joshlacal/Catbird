//
//  NativeFeedContentView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/4/25.
//

import SwiftUI
import SwiftData

// MARK: - Native FeedContentView with UIViewControllerRepresentable

struct NativeFeedContentView: View {
  // MARK: - Properties
  let posts: [CachedFeedViewPost]
  let appState: AppState
  @Binding var path: NavigationPath
  let loadMoreAction: @Sendable () async -> Void
  let refreshAction: @Sendable () async -> Void
  let feedType: FetchType
  let onScrollOffsetChanged: ((CGFloat) -> Void)?
  
  @Environment(\.modelContext) private var modelContext

  init(
    posts: [CachedFeedViewPost],
    appState: AppState,
    path: Binding<NavigationPath>,
    loadMoreAction: @escaping @Sendable () async -> Void,
    refreshAction: @escaping @Sendable () async -> Void,
    feedType: FetchType,
    onScrollOffsetChanged: ((CGFloat) -> Void)? = nil
  ) {
    self.posts = posts
    self.appState = appState
    self._path = path
    self.loadMoreAction = loadMoreAction
    self.refreshAction = refreshAction
    self.feedType = feedType
    self.onScrollOffsetChanged = onScrollOffsetChanged
  }

  var body: some View {
    if #available(iOS 18.0, *) {
      // Use UIViewControllerRepresentable for native NavigationStack integration
      NativeFeedViewControllerRepresentable(
        posts: posts,
        appState: appState,
        fetchType: feedType,
        path: $path,
        loadMoreAction: loadMoreAction,
        refreshAction: refreshAction,
        modelContext: modelContext,
        onScrollOffsetChanged: onScrollOffsetChanged
      )
    } else {
      // Fallback to existing SwiftUI implementation
      FeedContentView(
        posts: posts,
        appState: appState,
        path: $path,
        loadMoreAction: loadMoreAction,
        refreshAction: refreshAction,
        feedType: feedType
      )
    }
  }
}

// MARK: - Native UIViewControllerRepresentable

@available(iOS 18.0, *)
struct NativeFeedViewControllerRepresentable: UIViewControllerRepresentable {
  let posts: [CachedFeedViewPost]
  let appState: AppState
  let fetchType: FetchType
  @Binding var path: NavigationPath
  let loadMoreAction: @Sendable () async -> Void
  let refreshAction: @Sendable () async -> Void
  let modelContext: ModelContext
  let onScrollOffsetChanged: ((CGFloat) -> Void)?
  
  func makeUIViewController(context: Context) -> FeedViewController {
    let feedController = FeedViewController(
      appState: appState,
      fetchType: fetchType,
      path: $path,
      modelContext: modelContext
    )
    
    // Configure for SwiftUI navigation integration
    feedController.collectionView.contentInsetAdjustmentBehavior = .automatic
    feedController.collectionView.scrollsToTop = true
    
    // Set up scroll offset callback for navigation bar behavior
    feedController.onScrollOffsetChanged = onScrollOffsetChanged
    
    // Log initial post count for debugging
    print("UIKitFeedView: NativeFeedViewControllerRepresentable.makeUIViewController called with \(posts.count) posts for fetchType: \(fetchType.identifier)")
    
    // Load initial posts immediately
    Task { @MainActor in
      await feedController.loadPostsDirectly(posts)
    }
    
    return feedController
  }
  
  func updateUIViewController(_ uiViewController: FeedViewController, context: Context) {
    // Update scroll offset callback
    uiViewController.onScrollOffsetChanged = onScrollOffsetChanged
    
    // Log post updates for debugging
    print("UIKitFeedView: NativeFeedViewControllerRepresentable.updateUIViewController called with \(posts.count) posts")
    
    // Only update posts if they've actually changed (loadPostsDirectly has its own change detection)
    Task { @MainActor in
      await uiViewController.loadPostsDirectly(posts)
    }
    
    // Handle fetch type changes
    if uiViewController.fetchType.identifier != fetchType.identifier {
      uiViewController.handleFetchTypeChange(to: fetchType)
    }
  }
}

