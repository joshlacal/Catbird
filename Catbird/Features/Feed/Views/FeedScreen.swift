import SwiftUI
import Petrel
import OSLog

/// A screen wrapper for viewing a specific feed URI outside the main feeds interface.
/// If the user is subscribed to this feed, shows a compact header with feed info.
struct FeedScreen: View {
  @Environment(AppState.self) private var appState
  @Binding var path: NavigationPath

  let uri: ATProtocolURI

  @State private var generatorView: AppBskyFeedDefs.GeneratorView?
  @State private var isSubscribed: Bool = false
  @State private var isLoading: Bool = false

  private let logger = Logger(subsystem: "blue.catbird", category: "FeedScreen")

  var body: some View {
    FeedCollectionView.create(
      for: .feed(uri),
      appState: appState,
      navigationPath: $path
    )
    .modifier(FeedHeaderInjector(
      header: headerAnyView
    ))
    .task(id: uri.uriString()) {
      await loadGenerator()
      await updateSubscriptionStatus()
    }
  }

  // Convert header to AnyView when we have generator details
  private var headerAnyView: AnyView? {
    guard let generatorView else { return nil }
    return AnyView(
      FeedDiscoveryHeaderView(
        feed: generatorView,
        isSubscribed: isSubscribed,
        onSubscriptionToggle: { await toggleFeedSubscription(generatorView) }
      )
      .padding(.horizontal)
      .padding(.top, 8)
    )
  }

  // MARK: - Data

  private func loadGenerator() async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }

    do {
      if let data = try await appState.atProtoClient?.app.bsky.feed.getFeedGenerator(input: .init(feed: uri)).data {
        await MainActor.run { self.generatorView = data.view }
      }
    } catch {
      logger.error("Failed to load generator for uri=\(self.uri.uriString()): \(error.localizedDescription)")
    }
  }

  private func updateSubscriptionStatus() async {
    do {
      let preferences = try await appState.preferencesManager.getPreferences()
      let u = uri.uriString()
      await MainActor.run {
        self.isSubscribed = preferences.pinnedFeeds.contains(u) || preferences.savedFeeds.contains(u)
      }
    } catch {
      await MainActor.run { self.isSubscribed = false }
    }
  }

  private func toggleFeedSubscription(_ feed: AppBskyFeedDefs.GeneratorView) async {
    let feedURIString = feed.uri.uriString()
    do {
      let preferences = try await appState.preferencesManager.getPreferences()

      if isSubscribed {
        await MainActor.run { preferences.removeFeed(feedURIString) }
      } else {
        await MainActor.run { preferences.addFeed(feedURIString, pinned: false) }
      }

      try await appState.preferencesManager.saveAndSyncPreferences(preferences)
      await appState.stateInvalidationBus.notify(.feedListChanged)
      await updateSubscriptionStatus()
    } catch {
      logger.error("Failed to toggle feed subscription: \(error.localizedDescription)")
    }
  }
}

// MARK: - FeedHeaderInjector

struct FeedHeaderInjector: ViewModifier {
  let header: AnyView?

  func body(content: Content) -> some View {
    content
      .environment(\.feedHeaderView, header)
  }
}

enum FeedHeaderEnvironmentKey: EnvironmentKey {
  static var defaultValue: AnyView? = nil
}

extension EnvironmentValues {
  var feedHeaderView: AnyView? {
    get { self[FeedHeaderEnvironmentKey.self] }
    set { self[FeedHeaderEnvironmentKey.self] = newValue }
  }
}
