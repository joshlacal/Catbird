import SwiftUI
import Petrel

@Observable
@MainActor
final class ModeratedAccountsModel {
  struct Entry: Identifiable, Equatable {
    let did: String
    let handle: String
    let displayName: String?
    let avatar: URL?
    var id: String { did }
  }

  struct Page {
    let entries: [Entry]
    let cursor: String?
  }

  struct Transport {
    let isCurrent: @MainActor () -> Bool
    let fetch: @MainActor (String?) async throws -> Page
    let remove: @MainActor (String) async throws -> Bool
  }

  private(set) var entries: [Entry] = []
  private(set) var cursor: String?
  private(set) var hasLoaded = false
  private(set) var isLoading = false
  private(set) var removing: Set<String> = []
  private(set) var errorMessage: String?
  private var transport: Transport?
  private var generation = 0
  private var consumedCursors: Set<String> = []
  private var retryRemoval: Entry?
  private var retryRefresh = false

  func configure(_ transport: Transport) {
    generation += 1
    self.transport = transport
    entries = []
    cursor = nil
    hasLoaded = false
    isLoading = false
    removing = []
    errorMessage = nil
    consumedCursors = []
    retryRemoval = nil
    retryRefresh = false
  }

  func loadNextPage(refresh: Bool = false) async {
    guard let transport, transport.isCurrent(), !isLoading, removing.isEmpty,
          refresh || !hasLoaded || cursor != nil else { return }
    let requestGeneration = generation
    let requestCursor = refresh ? nil : cursor
    isLoading = true
    errorMessage = nil
    retryRemoval = nil
    retryRefresh = refresh
    defer { if generation == requestGeneration { isLoading = false } }
    do {
      let page = try await transport.fetch(requestCursor)
      guard generation == requestGeneration, transport.isCurrent() else { return }
      try Task.checkCancellation()
      let previousCursors = refresh ? Set<String>() : consumedCursors
      if let next = page.cursor, next == requestCursor || previousCursors.contains(next) {
        throw NSError(domain: "ModeratedAccounts", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "The account list returned a repeated page. Try refreshing."])
      }
      var merged = refresh ? [] : entries
      for entry in page.entries {
        if let index = merged.firstIndex(where: { $0.did == entry.did }) { merged[index] = entry }
        else { merged.append(entry) }
      }
      entries = merged
      consumedCursors = previousCursors
      if let requestCursor { consumedCursors.insert(requestCursor) }
      cursor = page.cursor
      hasLoaded = true
    } catch {
      guard generation == requestGeneration, transport.isCurrent() else { return }
      errorMessage = UserFacingError.message(for: error, action: "load these accounts") ?? "Couldn’t load these accounts. Try again."
    }
  }

  func remove(_ entry: Entry) async {
    guard let transport, transport.isCurrent(), !isLoading,
          removing.isEmpty, entries.contains(where: { $0.did == entry.did }) else { return }
    let requestGeneration = generation
    removing.insert(entry.did)
    errorMessage = nil
    retryRemoval = entry
    defer { if generation == requestGeneration { removing.remove(entry.did) } }
    do {
      guard try await transport.remove(entry.did) else {
        throw NSError(domain: "ModeratedAccounts", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "The account couldn’t be removed. Try again."])
      }
      guard generation == requestGeneration, transport.isCurrent() else { return }
      entries.removeAll { $0.did == entry.did }
      retryRemoval = nil
    } catch {
      guard generation == requestGeneration, transport.isCurrent() else { return }
      errorMessage = UserFacingError.message(for: error, action: "update this account") ?? "Couldn’t update this account. Try again."
    }
  }
  func retry() async {
    if let entry = retryRemoval { await remove(entry) }
    else { await loadNextPage(refresh: retryRefresh || !hasLoaded) }
  }
}

struct ModeratedAccountsSettingsView: View {
  enum Kind {
    case muted, blocked
    var title: String { self == .blocked ? "Blocked Accounts" : "Muted Accounts" }
    var action: String { self == .blocked ? "Unblock" : "Unmute" }
    var control: String { self == .blocked ? "moderation.blockedAccounts" : "moderation.mutedAccounts" }
  }

  let kind: Kind
  @Environment(AppState.self) private var appState
  @State private var model = ModeratedAccountsModel()
  @State private var selectedEntry: ModeratedAccountsModel.Entry?
  @State private var showConfirmation = false

  var body: some View {
    List {
      Section {
        ForEach(model.entries) { entry in
          HStack(spacing: 12) {
            ProfileAvatarView(url: entry.avatar, fallbackText: String(entry.handle.prefix(1).uppercased()), size: 40)
            VStack(alignment: .leading) {
              Text(entry.displayName ?? entry.handle)
              Text("@\(entry.handle)").appFont(AppTextRole.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if model.removing.contains(entry.did) { ProgressView().controlSize(.small) }
            else {
              Button(kind.action) { selectedEntry = entry; showConfirmation = true }
                .buttonStyle(.borderless)
                .disabled(model.isLoading || !model.removing.isEmpty)
                .accessibilityLabel("\(kind.action) @\(entry.handle)")
            }
          }
        }
        if model.isLoading { ProgressView("Loading accounts…") }
        if model.hasLoaded && model.entries.isEmpty && !model.isLoading {
          Text(kind == .blocked ? "No blocked accounts" : "No muted accounts").foregroundStyle(.secondary)
        }
        if model.cursor != nil && !model.isLoading {
          Button("Load More") { Task { await model.loadNextPage() } }
            .disabled(!model.removing.isEmpty)
            .accessibilityIdentifier("\(kind.control).loadMore")
        }
      }
      if let error = model.errorMessage {
        Section {
          Text(error).foregroundStyle(.secondary)
          Button("Try Again") { Task { await model.retry() } }
            .disabled(model.isLoading || !model.removing.isEmpty)
            .accessibilityIdentifier("\(kind.control).retry")
        }
      }
    }
    .navigationTitle(kind.title)
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .task(id: appState.userDID) {
      configureTransport()
      await model.loadNextPage()
    }
    .refreshable { await model.loadNextPage(refresh: true) }
    .confirmationDialog("\(kind.action) Account?", isPresented: $showConfirmation, titleVisibility: .visible) {
      Button(kind.action, role: .destructive) {
        if let entry = selectedEntry { Task { await model.remove(entry) } }
      }
      Button("Cancel", role: .cancel) { selectedEntry = nil }
    } message: {
      if let entry = selectedEntry { Text("\(kind.action) @\(entry.handle)?") }
    }
  }

  private func configureTransport() {
    let account = appState.userDID
    let state = appState
    let client = appState.atProtoClient
    let graph = appState.graphManager
    let manager = appState.preferencesManager
    model.configure(.init(isCurrent: {
      state.userDID == account && state.atProtoClient === client && state.graphManager === graph
    }, fetch: { cursor in
      let finishAccountIO = try manager.beginSettingsAccountIO()
      defer { finishAccountIO?() }
      guard let client else { throw PreferencesManagerError.clientNotInitialized }
      if kind == .blocked {
        let (code, data) = try await client.app.bsky.graph.getBlocks(input: .init(limit: 50, cursor: cursor))
        guard (200..<300).contains(code), let data else { throw PreferencesManagerError.invalidData }
        return .init(entries: data.blocks.map {
          .init(did: $0.did.didString(), handle: $0.handle.description, displayName: $0.displayName, avatar: $0.finalAvatarURL())
        }, cursor: data.cursor)
      }
      let (code, data) = try await client.app.bsky.graph.getMutes(input: .init(limit: 50, cursor: cursor))
      guard (200..<300).contains(code), let data else { throw PreferencesManagerError.invalidData }
      return .init(entries: data.mutes.map {
        .init(did: $0.did.didString(), handle: $0.handle.description, displayName: $0.displayName, avatar: $0.finalAvatarURL())
      }, cursor: data.cursor)
    }, remove: { did in
      guard state.userDID == account, state.atProtoClient === client, state.graphManager === graph else {
        throw PreferencesManagerError.accountChanged
      }
      let finishAccountIO = try manager.beginSettingsAccountIO()
      defer { finishAccountIO?() }
      // GraphManager resolves the block URI; a subject DID is never a record key.
      return kind == .blocked ? try await graph.unblock(did: did) : try await graph.unmute(did: did)
    }))
  }
}
