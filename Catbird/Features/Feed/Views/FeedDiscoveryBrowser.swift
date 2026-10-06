import Petrel
import SwiftUI

/// The pager changes selection; only the browser's selected-feed task loads posts.
struct FeedDiscoveryBrowser: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(AppState.self) private var appState
  @Bindable var model: FeedDiscoveryViewModel
  let preview: FeedDiscoveryPreviewModel
  @Binding var path: NavigationPath
  let onDetails: (AppBskyFeedDefs.GeneratorView) -> Void
  let onOpen: (AppBskyFeedDefs.GeneratorView) -> Void

  @State private var selectedID: String?
  @State private var feedAnchors: [String: String] = [:]
  @State private var retryGeneration = 0
  @State private var pendingAdvanceFrom: String?

  private var selectedFeed: AppBskyFeedDefs.GeneratorView? {
    model.items.first { $0.id == selectedID } ?? model.items.first
  }

  private var selection: Binding<String> {
    Binding(get: { selectedFeed?.id ?? "" }, set: { select($0) })
  }

  private var selectedIndex: Int? {
    model.items.firstIndex { $0.id == selectedFeed?.id }
  }

  var body: some View {
    VStack(spacing: 0) {
      discoveryStatus
      if !model.items.isEmpty {
        feedNavigator
        Divider()
        feedPages
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(platformColor: .platformSystemBackground))
    .accessibilityIdentifier("feed.discovery.browser")
    .searchable(text: $model.query, prompt: "Search feeds")
    .onSubmit(of: .search) { model.submit() }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Refresh", systemImage: "arrow.clockwise", action: refreshSelected)
          .disabled(model.isInitialLoading || model.isRefreshing)
      }
    }
    .onChange(of: model.items.map(\.id), initial: true) { _, ids in
      if let previous = pendingAdvanceFrom,
         let index = ids.firstIndex(of: previous), ids.indices.contains(index + 1) {
        select(ids[index + 1])
      } else if selectedID == nil || !ids.contains(selectedID ?? "") {
        selectedID = ids.first
        retryGeneration = 0
        pendingAdvanceFrom = nil
      }
      feedAnchors = feedAnchors.filter { ids.contains($0.key) }
    }
    .onChange(of: model.query) { _, _ in pendingAdvanceFrom = nil }
    .onChange(of: model.isLoadingMore) { _, loading in
      if !loading { finishPendingAdvance() }
    }
    .task(id: PreviewRequest(feedID: selectedFeed?.id, retry: retryGeneration)) {
      guard let feed = selectedFeed else {
        preview.cancel()
        return
      }
      let savedAnchor = feedAnchors[feed.id]
      await preview.load(feed: feed, forceRefresh: retryGeneration > 0)
      guard !Task.isCancelled, selectedFeed?.id == feed.id, preview.selectedFeedURI == feed.id else { return }
      switch preview.state {
      case .loaded, .empty, .filtered: break
      case .idle, .loading, .failed: return
      }
      if let savedAnchor, savedAnchor == headerAnchor(feed)
          || preview.posts.contains(where: { postAnchor($0) == savedAnchor }) {
        feedAnchors[feed.id] = savedAnchor
      } else {
        feedAnchors[feed.id] = headerAnchor(feed)
      }
    }
    .onDisappear { preview.cancel() }
  }

}

extension FeedDiscoveryBrowser {
  @ViewBuilder private var feedPages: some View {
    #if os(iOS)
    TabView(selection: selection) {
      ForEach(model.items) { feed in
        feedPage(feed).tag(feed.id)
      }
    }
    .tabViewStyle(.page(indexDisplayMode: .never))
    #else
    if let feed = selectedFeed { feedPage(feed).id(feed.id) }
    #endif
  }

  private var feedNavigator: some View {
    HStack(spacing: 4) {
      Button(action: previous) {
        Image(systemName: "chevron.backward").frame(minWidth: 44, minHeight: 44)
      }
      .disabled(selectedIndex == nil || selectedIndex == 0)
      .accessibilityLabel("Previous feed")
      .accessibilityIdentifier("feed.discovery.previous")

      Picker("Feed", selection: selection) {
        ForEach(model.items) { feed in
          Label {
            Text(feed.displayName)
          } icon: {
            Image(systemName: appState.feedLibraryActions.membership(for: feed.uri) == .absent
                  ? "square.stack" : "checkmark.circle.fill")
          }
          .tag(feed.id)
        }
      }
      .pickerStyle(.menu)
      .frame(maxWidth: .infinity, minHeight: 44)
      .accessibilityIdentifier("feed.discovery.selection")
      .accessibilityValue(selectionAccessibilityValue)

      Button(action: advance) {
        Image(systemName: "chevron.forward").frame(minWidth: 44, minHeight: 44)
      }
      .disabled(!canAdvance || model.isLoadingMore)
      .accessibilityLabel("Next feed")
      .accessibilityIdentifier("feed.discovery.next")
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 8)
  }

  private func feedPage(_ feed: AppBskyFeedDefs.GeneratorView) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        selectedIdentity(feed)
          .padding(12)
          .id(headerAnchor(feed))
        Divider()
        Text("Recent posts")
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(.secondary)
          .accessibilityAddTraits(.isHeader)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
        recentPosts(feed)
        if selectedFeed?.id == feed.id { pagingStatus.padding(12) }
      }
      .scrollTargetLayout()
      .frame(maxWidth: 700)
      .frame(maxWidth: .infinity)
    }
    .scrollPosition(id: anchor(for: feed), anchor: .top)
    .scrollDismissesKeyboard(.interactively)
    .refreshable { if selectedFeed?.id == feed.id { refreshSelected() } }
    .accessibilityIdentifier("feed.discovery.page.\(feed.id)")
  }

  private func selectedIdentity(_ feed: AppBskyFeedDefs.GeneratorView) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      FeedDiscoveryIdentity(feed: feed)
      if let description = feed.description, !description.isEmpty {
        Text(description)
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      let layout = dynamicTypeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
        : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
      layout {
        // A neighboring page may be visible mid-swipe, but cannot mutate a feed.
        FeedLibraryControls(feed: feed, onOpen: { onOpen(feed) })
          .id(feed.id)
        Button { onDetails(feed) } label: {
          Text("Details").frame(minHeight: 44)
        }
        .accessibilityLabel("Full description and creator")
        .accessibilityIdentifier("feed.discovery.details")
        Button("Open Feed") { onOpen(feed) }
          .frame(minHeight: 44)
          .accessibilityIdentifier("feed.discovery.open")
      }
      .disabled(selectedFeed?.id != feed.id)
    }
  }

  @ViewBuilder private func recentPosts(_ feed: AppBskyFeedDefs.GeneratorView) -> some View {
    if preview.selectedFeedURI != feed.id {
      ProgressView("Loading preview…").frame(maxWidth: .infinity).padding()
    } else {
      switch preview.state {
      case .idle, .loading:
        ProgressView("Loading preview…").frame(maxWidth: .infinity).padding()
      case .empty:
        ContentUnavailableView("No recent posts", systemImage: "text.bubble",
                               description: Text("Try another feed or check again later."))
        retryPreviewButton.padding(12)
      case .filtered:
        ContentUnavailableView("No posts to preview", systemImage: "eye.slash",
                               description: Text("Your moderation and content settings hide the available posts."))
        retryPreviewButton.padding(12)
      case .failed(let message):
        FeedDiscoveryRetryView(message: message) { retryGeneration += 1 }.padding(12)
      case .loaded:
        ForEach(preview.posts, id: \.id) { post in
          VStack(spacing: 0) {
            EnhancedFeedPost(feedViewPost: post, path: $path, isReadOnly: true)
              .padding(.horizontal, 8)
            Divider()
          }
          .id(postAnchor(post))
        }
      }
    }
  }

  private var retryPreviewButton: some View {
    Button("Try Again") { retryGeneration += 1 }
      .buttonStyle(.bordered)
      .frame(minHeight: 44)
  }

  @ViewBuilder private var discoveryStatus: some View {
    if let error = appState.feedLibraryActions.refreshError {
      FeedDiscoveryRetryView(message: error) {
        Task { await appState.feedLibraryActions.refresh() }
      }
      .padding(12)
    }
    if model.isInitialLoading {
      ProgressView("Loading feeds…").frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let error = model.initialError {
      FeedDiscoveryRetryView(message: error) { model.retry() }.padding(12)
    } else if model.items.isEmpty {
      ContentUnavailableView {
        Label {
          if model.resultQuery.isEmpty { Text("No popular feeds") } else { Text("No matching feeds") }
        } icon: { Image(systemName: "magnifyingglass") }
      } description: {
        if model.resultQuery.isEmpty { Text("Try searching for a feed.") } else {
          Text("No feeds found for “\(model.resultQuery)”.")
        }
      } actions: {
        if !model.query.isEmpty {
          Button("Show Popular") { model.query = "" }.frame(minHeight: 44)
        }
      }
    }
    if model.isRefreshing { ProgressView("Updating feeds…").padding(8) }
    if let error = model.refreshError {
      FeedDiscoveryRetryView(message: error) { model.retry() }.padding(12)
    }
  }

  @ViewBuilder private var pagingStatus: some View {
    if let error = model.pagingError {
      FeedDiscoveryRetryView(message: error) { model.loadMore() }
    } else if model.isLoadingMore {
      ProgressView("Loading more feeds…").frame(maxWidth: .infinity)
    } else if model.cursor != nil {
      Button("Load More Feeds") { model.loadMore() }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
        .disabled(model.isRefreshing || model.normalizedQuery != model.resultQuery)
    }
  }

}

extension FeedDiscoveryBrowser {
  private func select(_ id: String) {
    pendingAdvanceFrom = nil
    guard model.items.contains(where: { $0.id == id }), selectedFeed?.id != id else { return }
    selectedID = id
    retryGeneration = 0
  }

  private func previous() {
    guard let index = selectedIndex, index > 0 else { return }
    select(model.items[index - 1].id)
  }

  private var canAdvance: Bool {
    guard let index = selectedIndex else { return false }
    return model.items.indices.contains(index + 1)
      || (model.cursor != nil && !model.isRefreshing && model.normalizedQuery == model.resultQuery)
  }

  private func advance() {
    guard let feed = selectedFeed, let index = selectedIndex else { return }
    if model.items.indices.contains(index + 1) {
      select(model.items[index + 1].id)
    } else if canAdvance {
      pendingAdvanceFrom = feed.id
      model.loadMore()
    }
  }

  private func refreshSelected() {
    pendingAdvanceFrom = nil
    model.refresh()
    retryGeneration += 1
  }

  private func finishPendingAdvance() {
    guard let previous = pendingAdvanceFrom,
          let index = model.items.firstIndex(where: { $0.id == previous }) else { return }
    if model.items.indices.contains(index + 1) {
      select(model.items[index + 1].id)
    } else if model.cursor == nil {
      pendingAdvanceFrom = nil
    }
  }

  private var selectionAccessibilityValue: String {
    guard let feed = selectedFeed, let index = selectedIndex else { return "" }
    let status: String
    switch appState.feedLibraryActions.membership(for: feed.uri) {
    case .absent: status = String(localized: "Not added")
    case .saved: status = String(localized: "Saved")
    case .pinned: status = String(localized: "Pinned")
    }
    return String(localized: "\(feed.displayName), \(status), feed \(index + 1) of \(model.items.count)")
  }

  private func anchor(for feed: AppBskyFeedDefs.GeneratorView) -> Binding<String?> {
    Binding(get: { feedAnchors[feed.id] ?? headerAnchor(feed) }, set: { value in
      guard selectedFeed?.id == feed.id, preview.selectedFeedURI == feed.id,
            preview.state == .loaded, let value else { return }
      feedAnchors[feed.id] = value
    })
  }

  private func headerAnchor(_ feed: AppBskyFeedDefs.GeneratorView) -> String { "header:\(feed.id)" }
  private func postAnchor(_ post: AppBskyFeedDefs.FeedViewPost) -> String { "post:\(post.id)" }

  private struct PreviewRequest: Hashable {
    let feedID: String?
    let retry: Int
  }
}
