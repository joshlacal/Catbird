#if os(macOS)
import NukeUI
import OSLog
import Petrel
import SwiftData
import SwiftUI

/// A sidebar view for macOS that displays pinned and saved feeds,
/// allowing the user to switch the active feed in the detail pane.
struct MacOSFeedsSidebar: View {
  @Environment(AppState.self) private var appState
  @Environment(\.modelContext) private var modelContext

  @Binding var selectedFeed: FetchType
  @Binding var currentFeedName: String

  @State private var viewModel: FeedsStartPageViewModel?
  @State private var pinnedFeeds: [String] = []
  @State private var savedFeeds: [String] = []
  @State private var isLoaded = false

  private let logger = Logger(subsystem: "blue.catbird", category: "MacOSFeedsSidebar")

  var body: some View {
    List(selection: Binding(
      get: { feedSelectionValue },
      set: { newValue in
        if let newValue {
          selectFeed(identifier: newValue)
        }
      }
    )) {
      // Timeline is always first
      Label("Timeline", systemImage: "house")
        .tag("timeline")

      if !pinnedFeedsWithoutTimeline.isEmpty {
        Section("Pinned") {
          ForEach(pinnedFeedsWithoutTimeline, id: \.self) { feedURI in
            feedRow(for: feedURI)
          }
        }
      }

      if !savedFeedsFiltered.isEmpty {
        Section("Saved") {
          ForEach(savedFeedsFiltered, id: \.self) { feedURI in
            feedRow(for: feedURI)
          }
        }
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("Feeds")
    .task {
      await initializeFeeds()
    }
    .onChange(of: appState.userDID) { _, _ in
      isLoaded = false
      Task { await initializeFeeds() }
    }
  }

  // MARK: - Feed Selection

  /// Maps the current selectedFeed to a string identifier for List selection
  private var feedSelectionValue: String? {
    switch selectedFeed {
    case .timeline:
      return "timeline"
    case .feed(let uri):
      return uri.uriString()
    case .list(let uri):
      return uri.uriString()
    default:
      return nil
    }
  }

  /// Pinned feeds excluding system timeline entries
  private var pinnedFeedsWithoutTimeline: [String] {
    pinnedFeeds.filter { !SystemFeedTypes.isTimelineFeed($0) }
  }

  /// Saved feeds that are not also pinned
  private var savedFeedsFiltered: [String] {
    let pinnedSet = Set(pinnedFeeds)
    return savedFeeds.filter { !pinnedSet.contains($0) && !SystemFeedTypes.isTimelineFeed($0) }
  }

  // MARK: - Feed Row

  @ViewBuilder
  private func feedRow(for feedURI: String) -> some View {
    let name = feedDisplayName(for: feedURI)
    let icon = feedIcon(for: feedURI)

    Label {
      Text(name)
    } icon: {
      if let avatarURL = feedAvatarURL(for: feedURI) {
        LazyImage(url: avatarURL) { state in
          if let image = state.image {
            image
              .resizable()
              .aspectRatio(contentMode: .fill)
          } else {
            Image(systemName: icon)
              .foregroundStyle(.secondary)
          }
        }
        .frame(width: 20, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 4))
      } else {
        Image(systemName: icon)
      }
    }
    .tag(feedURI)
  }

  // MARK: - Feed Metadata Helpers

  private func feedDisplayName(for feedURI: String) -> String {
    guard let vm = viewModel else { return feedURI }

    if SystemFeedTypes.isTimelineFeed(feedURI) {
      return "Timeline"
    }

    if let uri = try? ATProtocolURI(uriString: feedURI) {
      if let generator = vm.feedGenerators[uri] {
        return generator.displayName
      }
      if let list = vm.listDetails[uri] {
        return list.name
      }
    }

    // Fallback: extract record key from URI
    if let uri = try? ATProtocolURI(uriString: feedURI) {
      return uri.recordKey ?? "Feed"
    }
    return "Feed"
  }

  private func feedIcon(for feedURI: String) -> String {
    if feedURI.contains("/app.bsky.graph.list/") {
      return "list.bullet"
    }
    return "number"
  }

  private func feedAvatarURL(for feedURI: String) -> URL? {
    guard let vm = viewModel,
      let uri = try? ATProtocolURI(uriString: feedURI)
    else { return nil }

    if let generator = vm.feedGenerators[uri],
      let avatarURI = generator.avatar
    {
      return URL(string: avatarURI.uriString())
    }
    if let list = vm.listDetails[uri],
      let avatarURI = list.avatar
    {
      return URL(string: avatarURI.uriString())
    }
    return nil
  }

  // MARK: - Feed Selection Action

  private func selectFeed(identifier: String) {
    if identifier == "timeline" || SystemFeedTypes.isTimelineFeed(identifier) {
      selectedFeed = .timeline
      currentFeedName = "Timeline"
    } else if let uri = try? ATProtocolURI(uriString: identifier) {
      if identifier.contains("/app.bsky.graph.list/") {
        selectedFeed = .list(uri)
        currentFeedName = feedDisplayName(for: identifier)
      } else {
        selectedFeed = .feed(uri)
        currentFeedName = feedDisplayName(for: identifier)
      }
    }
  }

  // MARK: - Initialization

  private func initializeFeeds() async {
    guard !isLoaded else { return }

    let vm = FeedsStartPageViewModel(appState: appState)
    viewModel = vm

    await vm.initializeWithModelContext(modelContext)
    await vm.updateCaches()

    pinnedFeeds = vm.cachedPinnedFeeds
    savedFeeds = vm.cachedSavedFeeds
    isLoaded = true

    logger.debug("Loaded \(pinnedFeeds.count) pinned, \(savedFeeds.count) saved feeds for sidebar")
  }
}
#endif
