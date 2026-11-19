import Petrel
import SwiftUI

struct AddFeedSheet: View {
  @Environment(SceneNavigationContext.self) private var sceneContext
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @State private var storefrontModel: FeedStorefrontViewModel?
  @State private var searchModel: FeedDiscoveryViewModel?
  @State private var previewModel: FeedDiscoveryPreviewModel?
  @State private var path = NavigationPath()
  @State private var selectedTab = 0
  @State private var isShowingSceneExplorer = false

  private let initialQuery: String
  private let onOpen: ((AppBskyFeedDefs.GeneratorView) -> Void)?

  init(initialQuery: String = "", onOpen: ((AppBskyFeedDefs.GeneratorView) -> Void)? = nil) {
    self.initialQuery = initialQuery
    self.onOpen = onOpen
  }

  var body: some View {
    NavigationStack(path: $path) {
      Group {
        if let storefrontModel, let searchModel, let previewModel,
           storefrontModel.accountDID == appState.userDID,
           searchModel.accountDID == appState.userDID,
           previewModel.matchesSession(appState: appState) {
          FeedDiscoveryStorefrontView(
            storefront: storefrontModel,
            searchModel: searchModel,
            onSelectFeed: { path.append(FeedProductRoute(feed: $0)) },
            onSeeAllShelf: { path.append($0) },
            onOpenFeed: open,
            onOpenSceneExplorer: { isShowingSceneExplorer = true }
          )
          .id(sessionIdentity)
        } else {
          Group {
            if appState.atProtoClient == nil {
              ContentUnavailableView(
                "Feeds unavailable",
                systemImage: "network",
                description: Text("Sign in to discover feeds.")
              )
            } else {
              ProgressView("Loading feeds…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          }
        }
      }
      .navigationTitle("Discover Feeds")
      .modifier(DiscoveryNavigationBar())
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close", systemImage: "xmark") { dismiss() }
            .accessibilityIdentifier("feed.discovery.close")
            .keyboardShortcut(.cancelAction)
        }
      }
      .navigationDestination(for: FeedProductRoute.self) { route in
        if let previewModel {
          FeedProductPageView(
            feed: route.feed,
            preview: previewModel,
            path: $path,
            onOpen: open
          )
        }
      }
      .navigationDestination(for: FeedShelfDestination.self) { destination in
        if let storefrontModel {
          FeedShelfListView(
            destination: destination,
            storefront: storefrontModel,
            onSelectFeed: { path.append(FeedProductRoute(feed: $0)) },
            onOpenFeed: open
          )
        }
      }
      .navigationDestination(for: FeedDetailsRoute.self) { route in
        FeedDiscoveryDetailsView(
          feed: route.feed,
          path: $path,
          onPreview: { path.append(FeedPreviewRoute(feed: route.feed)) }
        )
      }
      .navigationDestination(for: FeedPreviewRoute.self) { route in
        FeedScreen(path: $path, uri: route.feed.uri, initialGenerator: route.feed)
          .navigationTitle(route.feed.displayName)
          .toolbar {
            ToolbarItem(placement: .primaryAction) {
              Button("Open Feed") { open(route.feed) }
            }
          }
      }
      .navigationDestination(for: NavigationDestination.self) { destination in
        NavigationHandler.viewForDestination(
          destination,
          path: $path,
          appState: appState,
          selectedTab: $selectedTab
        )
      }
    }
    .sheet(isPresented: $isShowingSceneExplorer) {
      NavigationStack {
        SceneIntelligenceOnboardingView(
          mode: .tuneExistingFeed,
          entryPoint: .explorer,
          onComplete: { isShowingSceneExplorer = false },
          onSkip: { isShowingSceneExplorer = false }
        )
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close") { isShowingSceneExplorer = false }
          }
        }
      }
      .applyAppStateEnvironment(appState)
      .environment(sceneContext)
    }
    .task(id: sessionIdentity) {
      let accountDID = appState.userDID
      guard let client = appState.atProtoClient else {
        storefrontModel?.cancel()
        searchModel?.cancel()
        previewModel?.cancel()
        storefrontModel = nil
        searchModel = nil
        previewModel = nil
        path = NavigationPath()
        return
      }
      if previewModel?.matchesSession(appState: appState) != true {
        previewModel?.cancel()
        previewModel = FeedDiscoveryPreviewModel(appState: appState)
      }
      if let storefrontModel {
        if storefrontModel.accountDID != accountDID { path = NavigationPath() }
        storefrontModel.updateAccount(client: client, accountDID: accountDID)
      } else {
        let created = FeedStorefrontViewModel(client: client, accountDID: accountDID)
        storefrontModel = created
        created.load()
      }
      if let searchModel {
        searchModel.updateAccount(client: client, accountDID: accountDID)
      } else {
        let session = FeedDiscoveryViewModel(
          client: client,
          accountDID: accountDID,
          initialQuery: initialQuery
        )
        searchModel = session
        if !initialQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          session.load()
        }
      }
      await appState.feedLibraryActions.refresh()
    }
    .onDisappear {
      storefrontModel?.cancel()
      searchModel?.cancel()
      previewModel?.cancel()
    }
  }

  private var sessionIdentity: DiscoverySessionIdentity {
    DiscoverySessionIdentity(
      accountDID: appState.userDID,
      client: appState.atProtoClient.map { ObjectIdentifier($0) }
    )
  }

  private func open(_ feed: AppBskyFeedDefs.GeneratorView) {
    if let onOpen {
      onOpen(feed)
    } else {
      sceneContext.navigationManager.navigate(to: .feed(feed.uri))
    }
    dismiss()
  }
}

private struct DiscoveryNavigationBar: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
    content.navigationBarTitleDisplayMode(.inline)
    #else
    content
    #endif
  }
}

private struct DiscoverySessionIdentity: Hashable {
  let accountDID: String
  let client: ObjectIdentifier?
}

private struct FeedProductRoute: Hashable {
  let feed: AppBskyFeedDefs.GeneratorView

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.feed.uri.uriString() == rhs.feed.uri.uriString()
  }

  func hash(into hasher: inout Hasher) { hasher.combine(feed.uri.uriString()) }
}

private struct FeedPreviewRoute: Hashable {
  let feed: AppBskyFeedDefs.GeneratorView

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.feed.uri.uriString() == rhs.feed.uri.uriString()
  }

  func hash(into hasher: inout Hasher) { hasher.combine(feed.uri.uriString()) }
}

private struct FeedDetailsRoute: Hashable {
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
