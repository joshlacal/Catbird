import Petrel
import SwiftUI

/// Displays feed content with an optional header using a scrollable list
struct HeaderFeedContentView<Header: View>: View {
  // MARK: - Properties
  let posts: [CachedFeedViewPost]
  let appState: AppState
  @Binding var path: NavigationPath
  let loadMoreAction: @Sendable () async -> Void
  let refreshAction: @Sendable () async -> Void
  let feedType: FetchType
  let headerBuilder: () -> Header

  // Base unit for spacing
  private let baseUnit: CGFloat = 3

  // MARK: - Body
  var body: some View {
    HeaderFeedListView(
      posts: posts,
      path: $path,
      appState: appState,
      loadMoreAction: { await loadMoreAction() },
      refreshAction: { await refreshAction() },
      feedType: feedType,
      headerBuilder: headerBuilder
    )
    .id(feedType.identifier)
    .transition(.opacity)
  }
}

/// A view that renders a list of posts with a header and refresh behavior
struct HeaderFeedListView<Header: View>: View {
  // MARK: - Properties
  let posts: [CachedFeedViewPost]
  @Binding var path: NavigationPath
  let appState: AppState
  let loadMoreAction: @Sendable () async -> Void
  let refreshAction: @Sendable () async -> Void
  let feedType: FetchType
  let headerBuilder: () -> Header

  // Using a mixed type ScrollPosition to support both strings and integers
  @State private var scrollPosition: ScrollPosition = ScrollPosition()
  @State private var isRefreshing = false

  // Base unit for spacing
  private let baseUnit: CGFloat = 3

  // Helper struct to ensure unique IDs for ForEach
  private struct IndexedPost: Identifiable {
    let index: Int
    let post: CachedFeedViewPost
    var id: String { "\(index)-\(post.id)" }
  }

  // Create indexed posts with guaranteed unique IDs
  private var indexedPosts: [IndexedPost] {
    posts.enumerated().map { IndexedPost(index: $0.offset, post: $0.element) }
  }

  // MARK: - Body
  var body: some View {
    List {
      // Header section (pinned to top)
      Section {
        headerBuilder()
          .listRowInsets(EdgeInsets())
          .listRowSeparator(.hidden)
      }
      .listSectionSeparator(.hidden)

      // Invisible anchor for scroll-to-top
      Color.clear
        .frame(height: 0)
        .id("top")
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())

      // Post content
      ForEach(indexedPosts) { indexedPost in
        FeedPostRow(
          post: indexedPost.post,
          index: indexedPost.index,
          path: $path
        )
        .id(indexedPost.index)  // Simple integer ID for ScrollPosition
        .onAppear {
          let feedModel = FeedModelContainer.shared.getModel(for: feedType, appState: appState)
        }

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
          .padding(baseUnit * 2)
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
    .scrollPosition($scrollPosition)
    .scrollTargetLayout()
    .onAppear {
      // Restore saved scroll position when view appears
      Task {
        let feedModel = FeedModelContainer.shared.getModel(for: feedType, appState: appState)
      }
    }
    .onChange(of: appState.tabTappedAgain) { _, tapped in
      if tapped == 0 {
        // Scroll to top when tab is tapped again
        withAnimation(.easeInOut(duration: 0.3)) {
          scrollPosition.scrollTo(id: "top")
        }
      }
    }
  }
}
