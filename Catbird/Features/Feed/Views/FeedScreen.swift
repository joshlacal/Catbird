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
  @State private var isShowingCopilot: Bool = false
  @State private var isShowingReportSheet: Bool = false
  @State private var pendingDedicatedProposal: CopilotProposal?
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
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          if generatorView != nil {
            Button(role: .destructive) {
              isShowingReportSheet = true
            } label: {
              Label("Report Feed", systemImage: "exclamationmark.circle")
            }
          }
        } label: {
          Image(systemName: "ellipsis")
        }
      }
    }
    .sheet(isPresented: $isShowingReportSheet) {
      if let client = appState.atProtoClient, let generatorView = generatorView {
        let reportingService = ReportingService(client: client)
        let subject = reportingService.createFeedSubject(uri: generatorView.uri, cid: generatorView.cid)
        ReportFormView(
          reportingService: reportingService,
          subject: subject,
          contentDescription: "Feed: \(generatorView.displayName)"
        )
      }
    }
    .sheet(isPresented: $isShowingCopilot) {
      let feedName = generatorView?.displayName ?? "Feed"
      let feedURI = uri.uriString()
      CatbirdCopilotSheet(
        context: .feed(uri: feedURI, name: feedName),
        onConfirmedAction: { proposal in
          try await CopilotProposalCoordinator.executeConfirmed(
            proposal,
            context: .feed(uri: feedURI, name: feedName),
            expectedAccountDID: appState.userDID,
            appState: appState
          )
          await updateSubscriptionStatus()
        },
        onDedicatedAction: { proposal in
          pendingDedicatedProposal = proposal
        }
      )
    }
    .onChange(of: isShowingCopilot) { wasShowing, isShowing in
      if wasShowing && !isShowing, let proposal = pendingDedicatedProposal {
        pendingDedicatedProposal = nil
        if case .preparePostDraft(let text) = proposal {
          appState.presentPostComposer(initialText: text)
        }
      }
    }
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
        onSubscriptionToggle: { await toggleFeedSubscription(generatorView) },
        onLikedByTap: {
          path.append(NavigationDestination.postLikes(generatorView.uri.uriString()))
        },
        onAskCatbird: {
          isShowingCopilot = true
        },
        onReportTap: {
          isShowingReportSheet = true
        }
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

#Preview("FeedScreen") {
  @Previewable @State var path = NavigationPath()
  NavigationStack(path: $path) {
    FeedScreen(
      path: $path,
      uri: try! ATProtocolURI(uriString: "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.generator/whats-hot")
    )
  }
  .previewWithAuthenticatedState()
}
