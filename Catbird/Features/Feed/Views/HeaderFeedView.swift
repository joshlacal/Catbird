import Observation
import Petrel
import SwiftData
import SwiftUI

/// Extended version of FeedView that supports an optional header
struct HeaderFeedView<Header: View>: View {
    // MARK: - Properties
    let appState: AppState
    let fetch: FetchType
    @Binding var path: NavigationPath
    @Binding var selectedTab: Int
    let headerBuilder: () -> Header
    
    // Navigation state tracking
    @State private var lastNavigationTime = Date.distantPast
    @State private var navigationDirection = 0  // -1: back, 0: none, 1: forward
    
    // View state
    @State private var isInitialLoad = true
    @State private var showScrollToTop = false
    @State private var previousFeedType: FetchType?
    @State private var feedModel: FeedModel?
    
    // Flag to track if we're returning from another view
    let isReturningFromView: Bool

    // MARK: - Initialization
    init(
        appState: AppState,
        fetch: FetchType,
        path: Binding<NavigationPath>,
        selectedTab: Binding<Int>,
        isReturningFromView: Bool = false,
        @ViewBuilder headerBuilder: @escaping () -> Header
    ) {
        self.appState = appState
        self.fetch = fetch
        self._path = path
        self._selectedTab = selectedTab
        self.isReturningFromView = isReturningFromView
        self.headerBuilder = headerBuilder
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
                    try? await Task.sleep(nanoseconds: 150_000_000) // 0.15 seconds
                    
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
                await model.refreshIfNeeded(fetch: fetch, minInterval: 300)
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
                }
            }
        }
        .environment(\.defaultMinListRowHeight, 0)
        .environment(\.defaultMinListHeaderHeight, 0)
        .id("\(fetch.identifier)-feed-view")
    }

    // MARK: - Content Views

    /// The main feed content with optional header and posts
    private func contentView(model: FeedModel) -> some View {
        HeaderFeedContentView(
            posts: model.posts,
            appState: appState,
            path: $path,
            loadMoreAction: {
                await model.loadMore()
            },
            refreshAction: {
                await model.loadFeed(fetch: fetch, forceRefresh: true, strategy: .fullRefresh)
            },
            feedType: fetch,
            headerBuilder: headerBuilder
        )
    }

    /// Loading state when first loading the feed
    private var loadingView: some View {
        VStack {
            // Always show header even during loading
            headerBuilder()
                .padding(.bottom)
            
            ProgressView()
                .controlSize(.large)
                .padding()
            
            Text("Loading feed...")
                .foregroundColor(.secondary)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Empty state when no posts are available
    private var emptyStateView: some View {
        VStack {
            // Always show header even during empty state
            headerBuilder()
                .padding(.bottom)
                
            Spacer()
                
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
            
            Spacer()
        }
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

        await model.loadFeed(fetch: fetch, forceRefresh: true, strategy: .fullRefresh)
        
        await MainActor.run {
            isInitialLoad = false
        }

        Task.detached(priority: .background) {
            await model.prefetchNextPage()
        }
    }
}

/// Helper extension to create HeaderFeedView with no header
extension HeaderFeedView where Header == EmptyView {
    init(
        appState: AppState,
        fetch: FetchType,
        path: Binding<NavigationPath>,
        selectedTab: Binding<Int>,
        isReturningFromView: Bool = false
    ) {
        self.init(
            appState: appState,
            fetch: fetch,
            path: path,
            selectedTab: selectedTab,
            isReturningFromView: isReturningFromView,
            headerBuilder: { EmptyView() }
        )
    }
}
