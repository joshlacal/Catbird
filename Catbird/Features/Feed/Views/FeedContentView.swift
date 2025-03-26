//
//  FeedContentView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 1/31/25.
//

import Petrel
import SwiftUI

/// Displays the feed content using a scrollable list with optimized performance
struct FeedContentView: View {
  // MARK: - Properties
  let posts: [CachedFeedViewPost]
  let appState: AppState
  @Binding var path: NavigationPath
  let loadMoreAction: @Sendable () async -> Void
  let refreshAction: @Sendable () async -> Void
  let feedType: FetchType

  // Base unit for spacing
  private static let baseUnit: CGFloat = 3

  // For filtered posts
  @State private var filteredPosts: [CachedFeedViewPost] = []
  @State private var isApplyingFilters = false

  // MARK: - Body
  var body: some View {
    ZStack {
    ScrollViewReader { proxy in
      FeedListView(
        posts: posts,
        path: $path,
        proxy: proxy,
        appState: appState,
        loadMoreAction: { await loadMoreAction() },
        refreshAction: { await refreshAction() },
        feedType: feedType
      )
      .id(feedType.identifier)  // Use stable ID based on feed type
      // Simple clean transition - just fade in and out
      .transition(.opacity)
    }


      // Show filter loading indicator when applying filters
      if isApplyingFilters {
        VStack {
          FilterLoadingIndicator()
          Spacer()
        }
      }
    }
    .task {
      await applyFilters()
    }
    .onChange(of: posts) {
      Task {
        await applyFilters()
      }
    }
    .onChange(of: appState.feedFilterSettings.activeFilterIds) {
      Task {
        await applyFilters()
      }
    }
  }

  // Apply filters with loading state
  private func applyFilters() async {
    guard !isApplyingFilters else { return }

    // Show loading indicator if we have active filters
    if !appState.feedFilterSettings.activeFilters.isEmpty {
      await MainActor.run {
        isApplyingFilters = true
      }

      // Add a small delay to prevent flickering for fast operations
      try? await Task.sleep(nanoseconds: 150_000_000)  // 0.15 seconds
    }

    // Apply filters
    let activeFilters = appState.feedFilterSettings.activeFilters

    await MainActor.run {
      if activeFilters.isEmpty {
        // No active filters - use all posts
        filteredPosts = posts
      } else {
        // Apply filters
        filteredPosts = posts.filter { cachedPost in
          let post = cachedPost.feedViewPost

          // Post passes if it passes ALL active filters
          for filter in activeFilters {
            if !filter.filterBlock(post) {
              return false
            }
          }

          return true
        }
      }

      // Hide loading indicator
      isApplyingFilters = false
    }
  }
}

/// A view that renders a list of posts along with a top anchor and refresh behavior
struct FeedListView: View {
  // MARK: - Properties
  let posts: [CachedFeedViewPost]
  @Binding var path: NavigationPath
  let proxy: ScrollViewProxy
  let appState: AppState
  let loadMoreAction: @Sendable () async -> Void
  let refreshAction: @Sendable () async -> Void
  let feedType: FetchType

  // Base unit for spacing
  private static let baseUnit: CGFloat = 3

  // State to track refreshing status
  @State private var isRefreshing = false

  // Specific ID for the top anchor that's consistently used
  private let topAnchorID = "feed-top-anchor"

  // Helper struct to ensure unique IDs for ForEach
  private struct IndexedPost: Identifiable {
    let index: Int
    let post: CachedFeedViewPost
    var id: String { "\(index)-\(post.id)" }  // Combine index and post ID for uniqueness
  }

  // Create indexed posts with guaranteed unique IDs
  private var indexedPosts: [IndexedPost] {
    posts.enumerated().map { IndexedPost(index: $0.offset, post: $0.element) }
  }

  // MARK: - Body
  var body: some View {
    List {
      // Invisible anchor for scroll-to-top with a consistent ID
      Color.clear
        .frame(height: 1)
        .id(topAnchorID)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())

      // Post content - using indexedPosts with guaranteed unique IDs
      ForEach(indexedPosts) { indexedPost in
        // Post row without individual animations
        FeedPostRow(
          post: indexedPost.post,
          index: indexedPost.index,
          path: $path
        )

        // Trigger load more if near the bottom
        if indexedPost.index >= posts.count - 5 && posts.count >= 10 {
          LoadMoreTrigger(loadMoreAction: { @Sendable in
            await loadMoreAction()
          })
        }
      }

      // Loading indicator at bottom
      if !posts.isEmpty {
        ProgressView()
          .scaleEffect(0.8)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(FeedListView.baseUnit * 2)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
          .listRowSeparator(.hidden)
      }
    }
    .listStyle(PlainListStyle())
    .environment(\.defaultMinListRowHeight, 0)
    .scrollContentBackground(.hidden)
    .scrollDisabled(false)
    .scrollDismissesKeyboard(.immediately)
    .refreshable {
      isRefreshing = true
      await refreshAction()
      isRefreshing = false
    }
    .onChange(of: appState.tabTappedAgain) { old, tapped in
      if tapped == 0 {
        // Use a slight delay to ensure the scrolling happens after any layout changes
        DispatchQueue.main.async {
          // Use explicit animation with completion to ensure proper timing
          withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(topAnchorID, anchor: .top)
          }

          // Reset the tabTappedAgain value after handling
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            appState.tabTappedAgain = nil
          }
        }
      }
    }
  }
}
