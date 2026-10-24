import SwiftUI
import Petrel
import OSLog
import Observation

/// A screen wrapper for viewing a specific feed URI outside the main feeds interface.
/// Shows feed details and shared library actions, retaining metadata during refresh.
struct FeedScreen: View {
  @Environment(AppState.self) private var appState
  @Binding var path: NavigationPath

  let uri: ATProtocolURI

  @State private var metadata: FeedScreenMetadata
  @State private var isShowingCopilot: Bool = false
  @State private var isShowingReportSheet: Bool = false
  @State private var pendingDedicatedProposal: CopilotProposal?
  private let logger = Logger(subsystem: "blue.catbird", category: "FeedScreen")

  init(path: Binding<NavigationPath>, uri: ATProtocolURI,
       initialGenerator: AppBskyFeedDefs.GeneratorView? = nil) {
    self._path = path
    self.uri = uri
    self._metadata = State(initialValue: FeedScreenMetadata(
      generator: initialGenerator?.uri == uri ? initialGenerator : nil))
  }

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
          if metadata.generator != nil {
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
      if let client = appState.atProtoClient, let generatorView = metadata.generator {
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
      let feedName = metadata.generator?.displayName ?? "Feed"
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
          await appState.feedLibraryActions.refresh()
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
      await appState.feedLibraryActions.refresh()
    }
  }

  // The UIKit header host retains this child. Read observable metadata in the
  // child body so updates do not depend on replacing the AnyView configuration.
  private var headerAnyView: AnyView? {
    AnyView(FeedScreenMetadataHeader(
      metadata: metadata,
      onLikedByTap: { feed in
        path.append(NavigationDestination.postLikes(feed.uri.uriString()))
      },
      onAskCatbird: { isShowingCopilot = true },
      onReportTap: { isShowingReportSheet = true },
      onRetry: { Task { await loadGenerator() } }
    ))
  }

  // MARK: - Data

  private func loadGenerator() async {
    guard !metadata.isLoading else { return }
    metadata.isLoading = true
    metadata.error = nil
    defer { metadata.isLoading = false }

    do {
      guard let client = appState.atProtoClient else {
        metadata.error = "Feed details are unavailable. Please try again."
        return
      }
      let response = try await client.app.bsky.feed.getFeedGenerator(input: .init(feed: uri))
      try Task.checkCancellation()
      guard response.responseCode == 200, let data = response.data else {
        metadata.error = "Feed details could not be loaded. Please try again."
        return
      }
      metadata.generator = data.view
    } catch {
      guard !Task.isCancelled, !(error is CancellationError) else { return }
      metadata.error = "Feed details could not be loaded. Please try again."
      logger.error("Failed to load generator for uri=\(self.uri.uriString()): \(error.localizedDescription)")
    }
  }


}

/// Shared by the screen and its independently hosted collection header.
@MainActor @Observable
private final class FeedScreenMetadata {
  var generator: AppBskyFeedDefs.GeneratorView?
  var isLoading = false
  var error: String?

  init(generator: AppBskyFeedDefs.GeneratorView?) {
    self.generator = generator
  }
}

private struct FeedScreenMetadataHeader: View {
  let metadata: FeedScreenMetadata
  let onLikedByTap: (AppBskyFeedDefs.GeneratorView) -> Void
  let onAskCatbird: () -> Void
  let onReportTap: () -> Void
  let onRetry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let generator = metadata.generator {
        FeedDiscoveryHeaderView(
          feed: generator,
          onLikedByTap: { onLikedByTap(generator) },
          onAskCatbird: onAskCatbird,
          onReportTap: onReportTap
        )
      }
      if let error = metadata.error {
        Text(error)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button("Retry feed details", action: onRetry)
          .disabled(metadata.isLoading)
          .frame(minHeight: 44)
      } else if metadata.isLoading && metadata.generator == nil {
        ProgressView("Loading feed details…")
      }
    }
    .padding(.horizontal)
    .padding(.top, 8)
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
