import Observation
import Petrel
import SwiftData
import SwiftUI

struct FeedView: View {
  // MARK: - Properties
  let appState: AppState
  let fetch: FetchType
  @Binding var path: NavigationPath
  @Binding var selectedTab: Int

  // Flag to track if we're returning from another view (e.g., ThreadView)
  let isReturningFromView: Bool

  // View state
  @State private var isInitialLoad = true
  @State private var showScrollToTop = false
  @State private var previousFeedType: FetchType?
  @State private var feedModel: FeedModel? = nil

  // Navigation state tracking
  @State private var lastNavigationTime = Date.distantPast
  @State private var navigationDirection = 0  // -1: back, 0: none, 1: forward

  // MARK: - Initialization
  init(
    appState: AppState,
    fetch: FetchType,
    path: Binding<NavigationPath>,
    selectedTab: Binding<Int>,
    isReturningFromView: Bool = false
  ) {
    self.appState = appState
    self.fetch = fetch
    self._path = path
    self._selectedTab = selectedTab
    self.isReturningFromView = isReturningFromView
  }

  // MARK: - Body
  var body: some View {
    ZStack {
      Group {
        if feedModel == nil {
          Color.clear.onAppear {
            Task {
              let model = FeedModelContainer.shared.getModel(for: fetch, appState: appState)
              self.feedModel = model
              await loadInitialFeed()
            }
          }
          ProgressView("Loading feed...")
        } else if isInitialLoad && feedModel!.posts.isEmpty {
          loadingView
            .transition(.opacity)
        } else if !isInitialLoad && feedModel!.posts.isEmpty {
          emptyStateView
            .transition(.opacity)
        } else {
          contentView(model: feedModel!)
            .id(fetch.identifier)
            .transition(.opacity)
        }
      }
      .animation(.easeInOut(duration: 0.3), value: isInitialLoad)
      .animation(.easeInOut(duration: 0.3), value: feedModel?.posts.isEmpty)
      .background(Color.primaryBackground.ignoresSafeArea())

      if showScrollToTop {
        VStack {
          Spacer()
          scrollToTopButton
            .padding(.bottom, 20)
            .transition(.scale.combined(with: .opacity))
        }
      }
    }
    .onChange(of: path.count) { oldCount, newCount in
      lastNavigationTime = Date()
      navigationDirection = oldCount < newCount ? 1 : (oldCount > newCount ? -1 : 0)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        navigationDirection = 0
      }
    }
    .onChange(of: fetch) { oldValue, newValue in
      if oldValue != newValue {
        previousFeedType = oldValue

        withAnimation(.easeInOut(duration: 0.25)) {
          isInitialLoad = true
        }

        Task {
          try? await Task.sleep(nanoseconds: 150_000_000)  // 0.15 seconds

          let model = FeedModelContainer.shared.getModel(for: newValue, appState: appState)

          await MainActor.run {
            model.posts = []
            self.feedModel = model
          }

          await loadInitialFeed()
        }
      }
    }
    .onReceive(
      NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
    ) { _ in
      guard let model = feedModel else { return }
      Task {
        let didRefresh = await model.refreshIfNeeded(fetch: fetch, minInterval: 300)

        // If feed was refreshed, trigger scroll to top
        if didRefresh {
          await MainActor.run {
            appState.tabTappedAgain = selectedTab
          }
        }
      }
    }
    .onAppear {
      guard let model = feedModel else { return }

      let shouldRefresh =
        !isReturningFromView && navigationDirection != -1
        && model.shouldRefreshFeed(minInterval: 300) && !model.posts.isEmpty

      if shouldRefresh {
        Task {
          await model.loadFeed(fetch: fetch, forceRefresh: false, strategy: .backgroundRefresh)
          appState.triggerScrollToTop(for: selectedTab)
        }
      }
    }
    .environment(\.defaultMinListRowHeight, 0)
    .environment(\.defaultMinListHeaderHeight, 0)
    .id("\(fetch.identifier)-feed-view")
  }

  // MARK: - Content Views

  /// The main feed content with posts
  private func contentView(model: FeedModel) -> some View {
    // Get filtered posts directly from the model
    let filteredPosts = model.applyFilters(withSettings: appState.feedFilterSettings)

    return FeedContentView(
      posts: filteredPosts,
      appState: appState,
      path: $path,
      loadMoreAction: {
        await model.loadMoreWithFiltering(filterSettings: appState.feedFilterSettings)
      },
      refreshAction: {
        await model.loadFeedWithFiltering(
          fetch: fetch,
          forceRefresh: true,
          strategy: .fullRefresh,
          filterSettings: appState.feedFilterSettings
        )
      },
      feedType: fetch
    )
  }

  /// Loading state when first loading the feed
  private var loadingView: some View {
    VStack {
      ProgressView()
        .controlSize(.large)
        .padding()

      Text("Loading feed...")
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// Empty state when no posts are available
  private var emptyStateView: some View {
    VStack(spacing: 20) {
      Image(systemName: "text.bubble")
        .font(.system(size: 60))
        .foregroundColor(.secondary)

      Text("No posts to show")
        .font(.headline)

      Text("Pull down to refresh or check back later.")
        .font(.subheadline)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)

      Button("Refresh") {
        Task {
          await loadInitialFeed()
        }
      }
      .buttonStyle(.borderedProminent)
      .padding(.top)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// Scroll to top button
  private var scrollToTopButton: some View {
    Button(action: {
      appState.tabTappedAgain = selectedTab
      withAnimation {
        showScrollToTop = false
      }
    }) {
      Image(systemName: "arrow.up")
        .font(.headline)
        .foregroundColor(.white)
        .padding()
        .background(Circle().fill(Color.accentColor))
        .shadow(radius: 4)
    }
  }

  // MARK: - Helper Methods

  /// Loads the initial feed data
  private func loadInitialFeed() async {
    guard let model = feedModel else { return }

    await MainActor.run {
      isInitialLoad = true
    }

    await MainActor.run {
      if let previous = previousFeedType, previous.identifier != fetch.identifier {
        model.posts = []
      }
    }

    if let cachedFeed = await appState.getPrefetchedFeed(fetch) {
      model.setCachedFeed(cachedFeed.posts, cursor: cachedFeed.cursor)
      isInitialLoad = false
    }

    await model.loadFeedWithFiltering(
      fetch: fetch,
      forceRefresh: true,
      strategy: .fullRefresh,
      filterSettings: appState.feedFilterSettings
    )

    await MainActor.run {
      isInitialLoad = false
    }

    Task.detached(priority: .background) {
      await model.prefetchNextPage()
    }
  }
}
