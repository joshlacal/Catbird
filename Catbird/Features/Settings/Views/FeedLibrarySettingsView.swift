import SwiftUI
import Petrel

/// Settings uses the same account-owned library actions as feed discovery.
struct FeedLibrarySettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(SceneNavigationContext.self) private var sceneContext
  var initialFocus: SettingsControlID? = nil
  @State private var isLoading = true
  @State private var names: [String: String] = [:]
  @State private var creators: [String: String] = [:]
  private var actions: FeedLibraryActions { appState.feedLibraryActions }

  var body: some View {
    SettingsFocusedForm(initialFocus: initialFocus, isReady: !isLoading) {
      SettingsScopeSection()
      Section {
        if isLoading { ProgressView("Loading feed library…") }
        if let error = actions.refreshError {
          Text(error).foregroundStyle(.red)
          Button("Retry Loading") { Task { await load() } }
        }
        if !isLoading && actions.pinnedFeeds.isEmpty && actions.savedFeeds.isEmpty && actions.refreshError == nil {
          Text("No feeds in this account’s library.").foregroundStyle(.secondary)
        }
      }
      Section {
        ForEach(Array(actions.pinnedFeeds.enumerated()), id: \.offset) { _, uri in libraryRow(uri, pinned: true) }
          .onMove { offsets, destination in
            var reordered = actions.pinnedFeeds
            reordered.move(fromOffsets: offsets, toOffset: destination)
            Task { try? await actions.reorderPinned(reordered) }
          }
      } header: { Text("Pinned Feeds") } footer: {
        Text("The first pinned feed is your default. Use Edit to reorder, or choose Make Default in a feed’s menu. Following stays pinned.")
      }.settingsControl(.init(rawValue: "feed.feedLibrary"))
        .disabled(isOrdering)
      Section {
        ForEach(Array(actions.savedFeeds.enumerated()), id: \.offset) { _, uri in libraryRow(uri, pinned: false) }
      } header: { Text("Saved Feeds") } footer: {
        Text("Saved feeds stay in your library. Pin a feed to add it to the start page without replacing your default.")
      }
      orderFeedback
    }
    .navigationTitle("Feed Library")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .toolbar { ToolbarItem(placement: .primaryAction) { EditButton().disabled(isLoading || isOrdering) } }
    .task(id: appState.userDID) { await load() }
  }

  private var isOrdering: Bool { actions.orderState == .saving }
  private func title(_ uri: String) -> String {
    if SystemFeedTypes.isTimelineFeed(uri) { return "Following" }
    if let name = names[uri] { return name }
    if isLoading { return "Loading…" }
    return isList(uri) ? "List" : "Custom Feed"
  }

  private func isList(_ uri: String) -> Bool { uri.contains("/app.bsky.graph.list/") }

  private func libraryRow(_ raw: String, pinned: Bool) -> some View {
    VStack(alignment: .leading, spacing: 6) {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text(title(raw))
        if pinned && actions.pinnedFeeds.first == raw { Text("Default Feed").font(.caption).foregroundStyle(.secondary) }
        if let creator = creators[raw] { Text(creator).font(.caption).foregroundStyle(.secondary) }
      }
      Spacer()
      Menu {
        Button("Open Feed") { open(raw) }
        if pinned && actions.pinnedFeeds.first != raw {
          Button("Make Default") {
            Task { try? await actions.reorderPinned([raw] + actions.pinnedFeeds.filter { $0 != raw }) }
          }
        }
        if let uri = try? ATProtocolURI(uriString: raw), !SystemFeedTypes.isTimelineFeed(raw) {
          Button(pinned ? "Unpin to Saved" : "Pin to Start Page") {
            Task { _ = try? await actions.add(uri, to: pinned ? .unpinned : .pinned) }
          }
          Button("Remove from Library", role: .destructive) { Task { try? await actions.remove(uri) } }
          if case .pendingSync = actions.state(for: uri) {
            Button("Retry Sync") { Task { try? await actions.retry(uri) } }
          }
          if case .failed = actions.state(for: uri) {
            Button("Retry") { Task { try? await actions.retry(uri) } }
          }
        }
      } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
        .accessibilityLabel("Manage \(title(raw))")
    }
      if let uri = try? ATProtocolURI(uriString: raw) {
        switch actions.state(for: uri) {
        case .saving: ProgressView("Saving…").font(.caption)
        case .pendingSync: Text("Saved on this device · Sync pending").font(.caption).foregroundStyle(.secondary)
        case .failed(let error): Text(error).font(.caption).foregroundStyle(.red)
        default: EmptyView()
        }
      }
    }
  }

  @ViewBuilder private var orderFeedback: some View {
    switch actions.orderState {
    case .saving: Section { ProgressView("Saving feed order…") }
    case .pendingSync(let message), .failed(let message):
      Section {
        Text(message).foregroundStyle(.secondary)
        Button("Retry Saving Order") { Task { try? await actions.retryPinnedOrder() } }
      }
    default: EmptyView()
    }
  }

  private func open(_ raw: String) {
    if SystemFeedTypes.isTimelineFeed(raw) { sceneContext.navigationManager.navigate(to: .timeline) }
    else if let uri = try? ATProtocolURI(uriString: raw) {
      sceneContext.navigationManager.navigate(to: isList(raw) ? .listFeed(uri) : .feed(uri))
    }
  }

  private func load() async {
    let did = appState.userDID
    isLoading = true
    defer { isLoading = false }
    await actions.refresh()
    guard !Task.isCancelled, appState.userDID == did, let client = appState.atProtoClient else { return }
    let library = actions.pinnedFeeds + actions.savedFeeds
    let uris = library
      .filter { $0.contains("/app.bsky.feed.generator/") }.compactMap { try? ATProtocolURI(uriString: $0) }
    for start in stride(from: 0, to: uris.count, by: 25) {
      do {
        let batch = Array(uris[start..<min(start + 25, uris.count)])
        let response = try await client.app.bsky.feed.getFeedGenerators(input: .init(feeds: batch))
        guard !Task.isCancelled, appState.userDID == did else { return }
        for feed in response.data?.feeds ?? [] {
          names[feed.uri.uriString()] = feed.displayName
          creators[feed.uri.uriString()] = "By @" + feed.creator.handle.description
        }
      } catch { break }
    }
    for raw in library where isList(raw) && names[raw] == nil {
      guard let uri = try? ATProtocolURI(uriString: raw) else { continue }
      do {
        let response = try await client.app.bsky.graph.getList(input: .init(list: uri, limit: 1))
        guard !Task.isCancelled, appState.userDID == did else { return }
        if let list = response.data?.list {
          names[raw] = list.name
          creators[raw] = "List by @" + list.creator.handle.description
        }
      } catch is CancellationError { return }
      catch { continue }
    }
  }
}
