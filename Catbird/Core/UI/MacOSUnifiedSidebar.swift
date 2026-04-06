#if os(macOS)
import NukeUI
import OSLog
import Petrel
import SwiftData
import SwiftUI

/// Unified macOS sidebar combining functional items (Search, Notifications, Chat, Profile)
/// with feed navigation (Timeline, Pinned, Saved) in a single List.
struct MacOSUnifiedSidebar: View {
  @Environment(AppState.self) private var appState
  @Environment(\.modelContext) private var modelContext

  @Binding var selection: SidebarItem?

  // Feed state
  @State private var viewModel: FeedsStartPageViewModel?
  @State private var pinnedFeeds: [String] = []
  @State private var savedFeeds: [String] = []
  @State private var isLoaded = false

  private let logger = Logger(subsystem: "blue.catbird", category: "MacOSUnifiedSidebar")

  var body: some View {
    List(selection: $selection) {
      // MARK: - Functional Items
      Section {
        Label("Search", systemImage: "magnifyingglass")
          .tag(SidebarItem.search)

        notificationsRow

        chatRow

        Label("Profile", systemImage: "person")
          .tag(SidebarItem.profile)
      }

      // MARK: - Timeline (always first, not draggable)
      Section {
        Label("Timeline", systemImage: "house")
          .tag(SidebarItem.feed(.timeline))
      }

      // MARK: - Pinned Feeds
      if !pinnedFeedsFiltered.isEmpty {
        Section("Pinned") {
          ForEach(pinnedFeedsFiltered, id: \.self) { feedURI in
            feedRow(for: feedURI)
          }
          .onMove { source, destination in
            movePinnedFeeds(from: source, to: destination)
          }
        }
      }

      // MARK: - Saved Feeds
      if !savedFeedsFiltered.isEmpty {
        Section("Saved") {
          ForEach(savedFeedsFiltered, id: \.self) { feedURI in
            feedRow(for: feedURI)
          }
          .onMove { source, destination in
            moveSavedFeeds(from: source, to: destination)
          }
        }
      }
    }
    .listStyle(.sidebar)
    .task {
      await initializeFeeds()
    }
    .onChange(of: appState.userDID) { _, _ in
      isLoaded = false
      Task { await initializeFeeds() }
    }
  }

  // MARK: - Notification Row

  private var notificationsRow: some View {
    HStack {
      Label("Notifications", systemImage: "bell")
      Spacer()
      if appState.notificationManager.unreadCount > 0 {
        Text("\(appState.notificationManager.unreadCount)")
          .font(.caption2)
          .fontWeight(.bold)
          .foregroundStyle(.white)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.red, in: Capsule())
      }
    }
    .tag(SidebarItem.notifications)
  }

  // MARK: - Chat Row

  private var chatRow: some View {
    HStack {
      Label("Chat", systemImage: "bubble.left.and.bubble.right")
      Spacer()
      if appState.totalMessagesUnreadCount > 0 {
        Text("\(appState.totalMessagesUnreadCount)")
          .font(.caption2)
          .fontWeight(.bold)
          .foregroundStyle(.white)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.red, in: Capsule())
      }
    }
    .tag(SidebarItem.chat)
  }

  // MARK: - Feed Row

  @ViewBuilder
  private func feedRow(for feedURI: String) -> some View {
    let name = feedDisplayName(for: feedURI)

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
            Image(systemName: feedIcon(for: feedURI))
              .foregroundStyle(.secondary)
          }
        }
        .frame(width: 20, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 4))
      } else {
        Image(systemName: feedIcon(for: feedURI))
      }
    }
    .tag(feedTag(for: feedURI))
  }

  // MARK: - Feed Data

  private var pinnedFeedsFiltered: [String] {
    pinnedFeeds.filter { !SystemFeedTypes.isTimelineFeed($0) }
  }

  private var savedFeedsFiltered: [String] {
    let pinnedSet = Set(pinnedFeeds)
    return savedFeeds.filter { !pinnedSet.contains($0) && !SystemFeedTypes.isTimelineFeed($0) }
  }

  private func feedTag(for feedURI: String) -> SidebarItem {
    if SystemFeedTypes.isTimelineFeed(feedURI) {
      return .feed(.timeline)
    }
    guard let uri = try? ATProtocolURI(uriString: feedURI) else {
      return .feed(.timeline)
    }
    if feedURI.contains("/app.bsky.graph.list/") {
      return .feed(.list(uri))
    }
    return .feed(.feed(uri))
  }

  private func feedDisplayName(for feedURI: String) -> String {
    guard let vm = viewModel else { return feedURI }
    if SystemFeedTypes.isTimelineFeed(feedURI) { return "Timeline" }
    if let uri = try? ATProtocolURI(uriString: feedURI) {
      if let generator = vm.feedGenerators[uri] { return generator.displayName }
      if let list = vm.listDetails[uri] { return list.name }
    }
    if let uri = try? ATProtocolURI(uriString: feedURI) {
      return uri.recordKey ?? "Feed"
    }
    return "Feed"
  }

  private func feedIcon(for feedURI: String) -> String {
    if feedURI.contains("/app.bsky.graph.list/") { return "list.bullet" }
    return "number"
  }

  private func feedAvatarURL(for feedURI: String) -> URL? {
    guard let vm = viewModel, let uri = try? ATProtocolURI(uriString: feedURI) else { return nil }
    if let generator = vm.feedGenerators[uri], let avatarURI = generator.avatar {
      return URL(string: avatarURI.uriString())
    }
    if let list = vm.listDetails[uri], let avatarURI = list.avatar {
      return URL(string: avatarURI.uriString())
    }
    return nil
  }

  // MARK: - Feed Reordering

  private func movePinnedFeeds(from source: IndexSet, to destination: Int) {
    var filtered = pinnedFeedsFiltered
    filtered.move(fromOffsets: source, toOffset: destination)
    let timelineEntries = pinnedFeeds.filter { SystemFeedTypes.isTimelineFeed($0) }
    pinnedFeeds = timelineEntries + filtered
    Task { await syncFeedPreferences() }
  }

  private func moveSavedFeeds(from source: IndexSet, to destination: Int) {
    var filtered = savedFeedsFiltered
    filtered.move(fromOffsets: source, toOffset: destination)
    savedFeeds = filtered + savedFeeds.filter { pinnedFeedsFiltered.contains($0) || SystemFeedTypes.isTimelineFeed($0) }
    Task { await syncFeedPreferences() }
  }

  private func syncFeedPreferences() async {
    // Feed preference sync will be wired once we verify the Petrel API
    // For now, reorder is local only
    logger.debug("Feed reorder completed (local only)")
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
    logger.debug("Loaded \(pinnedFeeds.count) pinned, \(savedFeeds.count) saved feeds")
  }
}
#endif
