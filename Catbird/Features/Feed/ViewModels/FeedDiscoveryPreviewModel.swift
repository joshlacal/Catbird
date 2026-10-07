import Foundation
import Observation
import Petrel

struct FeedDiscoveryPreviewSession: Hashable, Sendable {
  let accountDID: String
  let clientIdentity: ObjectIdentifier?
}

enum FeedDiscoveryPreviewState: Equatable {
  case idle, loading, loaded, empty, filtered
  case failed(String)
}

/// One selected preview, owned by the discovery sheet's account session.
@MainActor
@Observable
final class FeedDiscoveryPreviewModel {
  private(set) var selectedFeedURI: String?
  private(set) var posts: [AppBskyFeedDefs.FeedViewPost] = []
  private(set) var state: FeedDiscoveryPreviewState = .idle
  let accountDID: String
  let clientIdentity: ObjectIdentifier?

  @ObservationIgnored private let provider: any FeedDiscoveryPreviewProviding
  @ObservationIgnored private let currentSession: @MainActor () -> FeedDiscoveryPreviewSession
  @ObservationIgnored private let filterPosts: @MainActor ([AppBskyFeedDefs.FeedViewPost]) async -> [AppBskyFeedDefs.FeedViewPost]
  @ObservationIgnored private var request: Task<[AppBskyFeedDefs.FeedViewPost], Error>?
  @ObservationIgnored private var generation = 0

  convenience init(appState: AppState) {
    self.init(provider: FeedPreviewService(appState: appState), currentSession: {
      FeedDiscoveryPreviewSession(accountDID: appState.userDID,
        clientIdentity: appState.atProtoClient.map { ObjectIdentifier($0) })
    }, filterPosts: { posts in
      let settings = await appState.buildFilterSettings()
      return await Self.moderatedPosts(posts, settings: settings)
    })
  }

  init(provider: any FeedDiscoveryPreviewProviding,
       currentSession: @escaping @MainActor () -> FeedDiscoveryPreviewSession,
       filterPosts: @escaping @MainActor ([AppBskyFeedDefs.FeedViewPost]) async -> [AppBskyFeedDefs.FeedViewPost]) {
    self.provider = provider
    self.currentSession = currentSession
    self.filterPosts = filterPosts
    let session = currentSession()
    accountDID = session.accountDID
    clientIdentity = session.clientIdentity
  }

  func matchesSession(appState: AppState) -> Bool {
    accountDID == appState.userDID
      && clientIdentity == appState.atProtoClient.map { ObjectIdentifier($0) }
  }

  /// Call from `.task(id:)`; cancellation propagates to the selected feed request.
  func load(feed: AppBskyFeedDefs.GeneratorView, forceRefresh: Bool = false) async {
    guard !Task.isCancelled else { return }
    cancel()
    let selectedURI = feed.uri.uriString()
    selectedFeedURI = selectedURI
    let session = currentSession()
    guard session.accountDID == accountDID, session.clientIdentity == clientIdentity,
          clientIdentity != nil else {
      state = .failed(FeedPreviewError.clientNotAvailable.localizedDescription)
      return
    }
    state = .loading
    let capturedGeneration = generation
    let provider = provider
    let request = Task {
      if forceRefresh { await provider.invalidateCache(for: feed.uri) }
      try Task.checkCancellation()
      return try await provider.fetchPreview(for: feed.uri)
    }
    self.request = request

    await withTaskCancellationHandler {
      do {
        let rawPosts = try await request.value
        try Task.checkCancellation()
        guard isCurrent(generation: capturedGeneration, session: session, uri: selectedURI) else { return }
        let visiblePosts = await filterPosts(rawPosts)
        try Task.checkCancellation()
        guard isCurrent(generation: capturedGeneration, session: session, uri: selectedURI) else { return }
        posts = visiblePosts
        state = visiblePosts.isEmpty ? (rawPosts.isEmpty ? .empty : .filtered) : .loaded
        self.request = nil
      } catch {
        guard isCurrent(generation: capturedGeneration, session: session, uri: selectedURI) else { return }
        self.request = nil
        if error is CancellationError || Task.isCancelled {
          state = .idle
        } else {
          state = .failed(FeedPreviewError.fetchFailed(0).localizedDescription)
        }
      }
    } onCancel: {
      request.cancel()
    }
  }

  func cancel() {
    generation += 1
    request?.cancel()
    request = nil
    selectedFeedURI = nil
    posts = []
    state = .idle
  }

  private func isCurrent(generation: Int, session: FeedDiscoveryPreviewSession, uri: String) -> Bool {
    self.generation == generation && currentSession() == session && selectedFeedURI == uri
  }

  /// Uses the same moderation stage as FeedTuner without starting a timeline or feedback session.
  static func moderatedPosts(_ posts: [AppBskyFeedDefs.FeedViewPost], settings: FeedTunerSettings) async
    -> [AppBskyFeedDefs.FeedViewPost] {
    let filtered = await ContentFilterService().filterFeedViewPosts(posts, settings: settings)
    return filtered.filter { post in
      var authors = [post.post.author]
      if let reply = post.reply {
        if case .appBskyFeedDefsPostView(let parent) = reply.parent { authors.append(parent.author) }
        if case .appBskyFeedDefsPostView(let root) = reply.root { authors.append(root.author) }
      }
      if case .appBskyFeedDefsReasonRepost(let reason) = post.reason { authors.append(reason.by) }
      return authors.allSatisfy {
        BlockRelationship(viewer: $0.viewer).direction == .unknown
          && $0.viewer?.muted != true && $0.viewer?.mutedByList == nil
      }
    }
  }
}
