import Petrel
import SwiftUI

struct AddFeedSheet: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @State private var model: FeedDiscoveryViewModel?
  @State private var path = NavigationPath()
  @State private var selectedTab = 0

  private let initialQuery: String
  private let onOpen: ((AppBskyFeedDefs.GeneratorView) -> Void)?

  init(initialQuery: String = "", onOpen: ((AppBskyFeedDefs.GeneratorView) -> Void)? = nil) {
    self.initialQuery = initialQuery
    self.onOpen = onOpen
  }

  var body: some View {
    NavigationStack(path: $path) {
      Group {
        if let model {
          discovery(model)
        } else {
          ContentUnavailableView("Feeds unavailable", systemImage: "network",
                                 description: Text("Sign in to discover feeds."))
        }
      }
      .navigationTitle("Discover Feeds")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
      }
      .navigationDestination(for: FeedPreviewRoute.self) { route in
        FeedScreen(path: $path, uri: route.feed.uri, initialGenerator: route.feed)
          .navigationTitle(route.feed.displayName)
          .toolbar {
            ToolbarItem(placement: .primaryAction) {
              Button("Open feed") { open(route.feed) }
            }
          }
      }
      .navigationDestination(for: NavigationDestination.self) { destination in
        NavigationHandler.viewForDestination(destination, path: $path,
                                             appState: appState, selectedTab: $selectedTab)
      }
    }
    .task(id: DiscoverySessionIdentity(accountDID: appState.userDID,
                                       client: appState.atProtoClient.map { ObjectIdentifier($0) })) {
      let accountDID = appState.userDID
      guard let client = appState.atProtoClient else {
        model?.cancel()
        model = nil
        path = NavigationPath()
        return
      }
      if let model {
        if model.accountDID != accountDID { path = NavigationPath() }
        model.updateAccount(client: client, accountDID: accountDID)
      } else {
        let session = FeedDiscoveryViewModel(client: client, accountDID: accountDID,
                                             initialQuery: initialQuery)
        model = session
        session.load()
      }
      await appState.feedLibraryActions.refresh()
    }
  }

  private func discovery(_ model: FeedDiscoveryViewModel) -> some View {
    @Bindable var model = model
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        if let error = appState.feedLibraryActions.refreshError {
          errorView("Saved feeds could not be loaded: \(error)") {
            Task { await appState.feedLibraryActions.refresh() }
          }
        }
        if model.isInitialLoading {
          ProgressView("Loading feeds…")
            .frame(maxWidth: .infinity)
        } else if let error = model.initialError {
          errorView(error) { model.retry() }
        } else if model.items.isEmpty {
          ContentUnavailableView {
            Label {
              if model.resultQuery.isEmpty { Text("No popular feeds") } else { Text("No matching feeds") }
            } icon: { Image(systemName: "magnifyingglass") }
          } description: {
            if model.resultQuery.isEmpty { Text("Try searching for a feed.") }
            else { Text("No feeds found for “\(model.resultQuery)”.") }
          } actions: {
            if !model.query.isEmpty {
              Button("Show Popular") { model.query = "" }
            }
          }
        }

        if !model.items.isEmpty {
          Group {
            if model.resultQuery.isEmpty { Text("Popular") }
            else { Text("Results for “\(model.resultQuery)”") }
          }
          .appFont(AppTextRole.headline)
          if model.isRefreshing {
            ProgressView("Updating feeds…")
          }
          if let error = model.refreshError {
            errorView(error) { model.retry() }
          }
          ForEach(model.items) { feed in
            FeedDiscoveryHeaderView(
              feed: feed,
              onTap: { path.append(FeedPreviewRoute(feed: feed)) },
              onLikedByTap: { path.append(NavigationDestination.postLikes(feed.uri.uriString())) },
              onOpenFeed: { open(feed) }
            )
          }
          if let error = model.pagingError {
            errorView(error) { model.loadMore() }
          } else if model.isLoadingMore {
            ProgressView("Loading more feeds…")
              .frame(maxWidth: .infinity)
          } else if model.cursor != nil {
            Button("Load more") { model.loadMore() }
              .buttonStyle(.bordered)
              .frame(maxWidth: .infinity)
              .disabled(model.isRefreshing || model.normalizedQuery != model.resultQuery)
          }
        }
      }
      .padding()
    }
    .searchable(text: $model.query, prompt: "Search feeds")
    .onSubmit(of: .search) { model.submit() }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
          .disabled(model.isInitialLoading || model.isRefreshing)
      }
    }
  }

  private func errorView(_ message: String, retry: @escaping () -> Void) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(message, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("Try Again", action: retry)
        .buttonStyle(.bordered)
    }
    .accessibilityElement(children: .contain)
  }

  private func open(_ feed: AppBskyFeedDefs.GeneratorView) {
    if let onOpen { onOpen(feed) }
    else { appState.navigationManager.navigate(to: .feed(feed.uri)) }
    dismiss()
  }
}

private struct DiscoverySessionIdentity: Hashable {
  let accountDID: String
  let client: ObjectIdentifier?
}

private struct FeedPreviewRoute: Hashable {
  let feed: AppBskyFeedDefs.GeneratorView

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.feed.uri.uriString() == rhs.feed.uri.uriString()
  }

  func hash(into hasher: inout Hasher) { hasher.combine(feed.uri.uriString()) }
}

extension AppBskyFeedDefs.GeneratorView: Identifiable {
  public var id: String { uri.uriString() }
}

#Preview("AddFeedSheet") {
  AddFeedSheet()
    .previewWithAuthenticatedState()
}
