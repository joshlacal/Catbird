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
  @State private var feedModel: FeedModel?

  // Navigation state tracking
  @State private var lastNavigationTime = Date.distantPast
  @State private var navigationDirection = 0  // -1: back, 0: none, 1: forward
  
  // Environment
  @Environment(\.colorScheme) private var colorScheme

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
        } else if let error = feedModel!.error {
          ErrorStateView(
            error: error,
            context: "Failed to load feed",
            retryAction: {
              Task {
                await retryLoadFeed()
              }
            }
          )
          .accessibleTransition(.opacity, appState: appState)
        } else if isInitialLoad && feedModel!.posts.isEmpty {
          loadingView
            .accessibleTransition(.opacity, appState: appState)
        } else if !isInitialLoad && feedModel!.posts.isEmpty {
          emptyStateView
            .accessibleTransition(.opacity, appState: appState)
        } else {
          contentView(model: feedModel!)
            .id(fetch.identifier)
            .accessibleTransition(.opacity, appState: appState)
        }
      }
      .accessibleAnimation(.easeInOut(duration: 0.3), value: isInitialLoad, appState: appState)
      .accessibleAnimation(.easeInOut(duration: 0.3), value: feedModel?.posts.isEmpty, appState: appState)
      .appDisplayScale(appState: appState)
      .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)

      if showScrollToTop {
        VStack {
          Spacer()
          scrollToTopButton
            .padding(.bottom, 20)
            .accessibleTransition(.scale.combined(with: .opacity), appState: appState)
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
  
  // MARK: - Helper Methods
  
  /// Retry loading the feed after an error
  @MainActor
  private func retryLoadFeed() async {
    guard let model = feedModel else { return }
    await model.loadFeed(fetch: fetch, forceRefresh: true, strategy: .fullRefresh)
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
        .foregroundStyle(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// Empty state when no posts are available
  private var emptyStateView: some View {
    VStack(spacing: DesignTokens.Spacing.sectionLarge) {
      Image(systemName: "text.bubble")
        .appFont(size: 60)
        .foregroundStyle(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))

      Text("No posts to show")
        .enhancedAppHeadline()

      Text("Pull down to refresh or check back later.")
        .enhancedAppSubheadline()
        .foregroundStyle(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
        .multilineTextAlignment(.center)
        .spacingBase(.horizontal)

      Button("Refresh") {
        Task {
          await loadInitialFeed()
        }
      }
      .buttonStyle(.borderedProminent)
      .spacingBase(.top)
    }
    .spacingBase()
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
        .appFont(AppTextRole.headline)
        .foregroundStyle(Color.dynamicText(appState.themeManager, style: .primary, currentScheme: .light))
        .spacingBase()
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
      await model.setCachedFeed(cachedFeed.posts, cursor: cachedFeed.cursor)
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
