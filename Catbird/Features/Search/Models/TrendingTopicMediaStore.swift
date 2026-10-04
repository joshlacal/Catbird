import Foundation
import Nuke
import Observation
import Petrel
#if canImport(UIKit)
import UIKit
#endif

/// Account-owned raw preview cache. Only the presentation policy may extract image URLs.
@MainActor @Observable
final class TrendingTopicMediaStore {
  private struct Entry {
    let posts: [AppBskyFeedDefs.FeedViewPost]
    let quotedPosts: [String: AppBskyFeedDefs.PostView]
    let expiresAt: Date
  }
  private var entries: [String: Entry] = [:]
  private(set) var revision = 0
  @ObservationIgnored private let gate = TopicPreviewRequestGate()
  @ObservationIgnored private var requests: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored let prefetchCoordinator = TopicPreviewPrefetchCoordinator()
  @ObservationIgnored private let imagePrefetcher = ImagePrefetcher(
    pipeline: ImageLoadingManager.shared.pipeline, maxConcurrentRequestCount: 2)
  @ObservationIgnored private var imageOwnership = TopicPreviewImagePrefetchOwnership<ImageRequest, TrendingTopicImageRequests.Identity>()
  @ObservationIgnored private var lastLabelers: String?
  @ObservationIgnored private var graphObserver: NSObjectProtocol?
  @ObservationIgnored private var activityObserver: NSObjectProtocol?
  @ObservationIgnored private var inactivityObserver: NSObjectProtocol?
  private(set) var canReusePrefetchedFeed = true
  private(set) var isActive = true
  @ObservationIgnored private var prefetchedLinksUsed: Set<String> = []

  func consumePrefetchedFeedReuse(for link: String) -> Bool {
    guard canReusePrefetchedFeed, prefetchedLinksUsed.count < 20 else { return false }
    return prefetchedLinksUsed.insert(link).inserted
  }

  init() {
    graphObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name("UserGraphChanged"),
      object: nil, queue: .main) { [weak self] _ in
        // Graph notifications may originate off the main actor. Delivery is on the main queue.
        MainActor.assumeIsolated { self?.invalidateForGraphChange() }
      }
    #if canImport(UIKit)
    setActive(UIApplication.shared.applicationState == .active)
    activityObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
      object: nil, queue: .main) { [weak self] _ in
        // Refresh viewer metadata after another client or a background App Intent changed moderation.
        MainActor.assumeIsolated { self?.setActive(true) }
      }
    inactivityObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
      object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.setActive(false) }
      }
    #endif
  }

  func setActive(_ active: Bool) {
    guard isActive != active else { return }
    // Close admission before cancellation; a late metadata response cannot reopen it.
    isActive = active
    if active {
      // Visible .task identities observe revision; departed surfaces retain no resume callbacks.
      invalidateForGraphChange()
      prefetchCoordinator.setActive(true)
    } else {
      prefetchCoordinator.setActive(false)
      cancelRequests()
      cancelPrefetches()
    }
  }

  deinit {
    for request in requests.values { request.cancel() }
    if let graphObserver { NotificationCenter.default.removeObserver(graphObserver) }
    if let activityObserver { NotificationCenter.default.removeObserver(activityObserver) }
    if let inactivityObserver { NotificationCenter.default.removeObserver(inactivityObserver) }
  }

  func invalidateForGraphChange() {
    cancelRequests()
    cancelPrefetches()
    canReusePrefetchedFeed = false
    entries.removeAll()
    revision += 1
  }

  func invalidate(labelers: String) {
    guard lastLabelers != labelers else { return }
    lastLabelers = labelers
    cancelRequests()
    cancelPrefetches()
    entries.removeAll()
    revision += 1
  }

  func load(key: String, hydrate: (([AppBskyFeedDefs.FeedViewPost]) async -> [AppBskyFeedDefs.PostView])? = nil,
    fetch: @escaping () async throws -> [AppBskyFeedDefs.FeedViewPost]) async {
    guard isActive, !Task.isCancelled else { return }
    let id = UUID()
    // Own direct row requests as well as metadata batches, so account suspension cancels both.
    let request = Task { [weak self] in
      guard let self else { return }
      await self.performLoad(key: key, hydrate: hydrate, fetch: fetch)
    }
    requests[id] = request
    defer { requests.removeValue(forKey: id) }
    await withTaskCancellationHandler {
      await request.value
    } onCancel: {
      request.cancel()
    }
  }

  private func cancelRequests() {
    for request in requests.values { request.cancel() }
  }

  private func performLoad(key: String, hydrate: (([AppBskyFeedDefs.FeedViewPost]) async -> [AppBskyFeedDefs.PostView])?,
    fetch: () async throws -> [AppBskyFeedDefs.FeedViewPost]) async {
    guard isActive, !Task.isCancelled else { return }
    guard entries[key]?.expiresAt ?? .distantPast <= Date() else { return }
    let requestRevision = revision
    do {
      try await gate.acquire(key)
      defer { gate.release(key) }
      try Task.checkCancellation()
      guard isActive, revision == requestRevision else { return }
      guard entries[key]?.expiresAt ?? .distantPast <= Date() else { return }
      let posts = try await fetch()
      try Task.checkCancellation()
      guard isActive, revision == requestRevision else { return }
      let quotedPosts = await hydrate?(posts) ?? []
      try Task.checkCancellation()
      guard isActive, revision == requestRevision else { return }
      cache(posts: posts, quotedPosts: quotedPosts, key: key, lifetime: 300)
    } catch is CancellationError {
      // Cancellation does not poison a later visible row's cache.
    } catch {
      guard isActive, !Task.isCancelled, revision == requestRevision else { return }
      // A failed preview remains a fully usable text topic; back navigation does not retry it.
      cache(posts: [], quotedPosts: [], key: key, lifetime: 60)
    }
  }

  private func cache(posts: [AppBskyFeedDefs.FeedViewPost], quotedPosts: [AppBskyFeedDefs.PostView], key: String, lifetime: TimeInterval) {
    entries = entries.filter { $0.value.expiresAt > Date() }
    if entries.count >= 20, let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
      entries.removeValue(forKey: oldest)
    }
    var quotes: [String: AppBskyFeedDefs.PostView] = [:]
    for post in quotedPosts.prefix(6) { quotes[post.uri.uriString()] = post }
    entries[key] = Entry(posts: Array(posts.prefix(30)), quotedPosts: quotes, expiresAt: Date().addingTimeInterval(lifetime))
  }

  func preview(key: String, context: TrendingTopicPreviewPolicy.Context) -> TrendingTopicPreview {
    var context = context
    context.quotedPosts = entries[key]?.quotedPosts ?? [:]
    return TrendingTopicPreviewPolicy.select(entries[key]?.posts ?? [], context: context)
  }

  func warmImages(_ preview: TrendingTopicPreview, owner: TopicPreviewPrefetchOwner) {
    guard isActive else { return }
    // Six topics, three static cards and three avatars each; never expand with scroll renders.
    let additions = imageOwnership.append(TrendingTopicImageRequests.requests(for: preview), owner: owner,
      identity: TrendingTopicImageRequests.identity)
    imagePrefetcher.startPrefetching(with: additions)
  }

  func cancelPrefetch(owner: TopicPreviewPrefetchOwner) {
    prefetchCoordinator.cancel(owner: owner)
    resetImagePrefetch(owner: owner)
  }

  func resetImagePrefetch(owner: TopicPreviewPrefetchOwner) {
    let unowned = imageOwnership.remove(owner: owner, identity: TrendingTopicImageRequests.identity)
    imagePrefetcher.stopPrefetching(with: unowned)
  }

  private func cancelPrefetches() {
    prefetchCoordinator.cancelAll()
    imagePrefetcher.stopPrefetching()
    imageOwnership.removeAll()
  }
}

/// Prefetch and display use identical resized requests so the shared pipeline can coalesce them.
@MainActor
enum TrendingTopicImageRequests {
  /// Matches frozen Nuke's TaskLoadImageKey, including ordered processor identities.
  struct Identity: Hashable {
    let imageID: String?
    let cachePolicy: URLRequest.CachePolicy
    let allowsCellularAccess: Bool
    let scale: Float
    let thumbnail: ImageRequest.ThumbnailOptions?
    let options: ImageRequest.Options
    let processors: [AnyHashable]
  }

  static func identity(_ request: ImageRequest) -> Identity {
    let resource = request.urlRequest
    return Identity(imageID: request.imageId,
      cachePolicy: resource?.cachePolicy ?? .useProtocolCachePolicy,
      allowsCellularAccess: resource?.allowsCellularAccess ?? true,
      scale: (request.userInfo[.scaleKey] as? NSNumber)?.floatValue ?? 1,
      thumbnail: request.userInfo[.thumbnailKey] as? ImageRequest.ThumbnailOptions,
      options: request.options, processors: request.processors.map(\.hashableIdentifier))
  }

  static func request(_ url: URL, size: CGSize) -> ImageRequest {
    let pixels = CGSize(width: size.width * PlatformScreenInfo.scale, height: size.height * PlatformScreenInfo.scale)
    return ImageRequest(url: url, processors: [
      ImageProcessors.Resize(size: pixels, unit: .pixels, contentMode: .aspectFill)
    ], priority: .low)
  }

  static func requests(for preview: TrendingTopicPreview) -> [ImageRequest] {
    preview.media.prefix(3).map { request($0.url, size: CGSize(width: 62, height: 72)) }
      + preview.participants.prefix(3).map { request($0.avatar, size: CGSize(width: 26, height: 26)) }
  }
}

extension AppState {
  @MainActor
  var topicPreviewLabelers: String {
    ((try? preferencesManager.getLocalPreferences())?.labelers ?? []).map { $0.did.didString() }.sorted().joined(separator: ",")
  }

  @MainActor
  var topicPreviewAppliedLabelers: String {
    preferencesManager.appliedAcceptLabelerDIDs?.sorted().joined(separator: ",") ?? "unapplied"
  }

  @MainActor
  var topicPreviewLabelerScopeIsCurrent: Bool {
    guard let preferences = try? preferencesManager.getLocalPreferences() else { return false }
    return TrendingTopicPreviewPolicy.permitsLabelerScope(local: preferences.labelers.map { $0.did.didString() },
      applied: preferencesManager.appliedAcceptLabelerDIDs)
  }

  @MainActor
  func topicPreview(for link: String) -> TrendingTopicPreview {
    guard !isAccountSwitchSuspended, appSettings.showTrendingTopics, topicPreviewLabelerScopeIsCurrent,
          let preferences = try? preferencesManager.getLocalPreferences() else { return .init() }
    let filters = feedFilterSettings.activeFilters
    let languageFilter = LanguageFilterProcessor(contentLanguages: appSettings.contentLanguages)
    let context = TrendingTopicPreviewPolicy.Context(
      mutedUsers: graphManager.muteCache,
      blockedUsers: graphManager.blockCache,
      hiddenPosts: postHidingManager.hiddenPosts,
      mutedWords: preferences.mutedWords,
      feedPreference: preferences.feedViewPref,
      currentUserDID: userDID,
      allowsExternal: { url in
        guard let provider = TrendingTopicExternalMediaPolicy.provider(for: url) else { return true }
        return self.appSettings.externalMediaConsent(for: provider) != .hide
      },
      allowsPost: { item in
        filters.allSatisfy { $0.filterBlock(item) }
          && (!self.appSettings.hideNonPreferredLanguages || languageFilter.process(post: item))
      }
    )
    return trendingTopicMediaStore.preview(key: topicPreviewLabelers + "|" + link, context: context)
  }

  @MainActor
  func loadTopicPreview(for link: String) async {
    guard trendingTopicMediaStore.isActive, !isAccountSwitchSuspended, appSettings.showTrendingTopics, topicPreviewLabelerScopeIsCurrent,
          (try? preferencesManager.getLocalPreferences()) != nil,
          let client = atProtoClient, let uri = TrendingTopicPreviewPolicy.feedURI(for: link) else { return }
    let labelers = topicPreviewLabelers
    let viewerDID = userDID
    await withTopicPreviewAccountOperation {
      await trendingTopicMediaStore.load(key: labelers + "|" + link, hydrate: { posts in
        let uris = TrendingTopicPreviewPolicy.quotedPostURIs(in: posts)
        guard !uris.isEmpty, self.trendingTopicMediaStore.isActive, !Task.isCancelled, !self.isAccountSwitchSuspended,
              self.userDID == viewerDID, self.topicPreviewLabelers == labelers,
              self.topicPreviewLabelerScopeIsCurrent else { return [] }
        // Quote views omit thread-mute state. One bounded read resolves it under the same gate/header.
        let result = try? await client.app.bsky.feed.getPosts(input: .init(uris: uris))
        guard self.trendingTopicMediaStore.isActive, !Task.isCancelled, !self.isAccountSwitchSuspended, self.userDID == viewerDID,
              self.topicPreviewLabelers == labelers, self.topicPreviewLabelerScopeIsCurrent,
              let (status, response) = result, status == 200 else { return [] }
        return response?.posts ?? []
      }) {
        try Task.checkCancellation()
        guard self.trendingTopicMediaStore.isActive, !self.isAccountSwitchSuspended, self.userDID == viewerDID else { throw CancellationError() }
        // Reuse an already hydrated account feed when it has the default labeler scope.
        // Custom labeler subscriptions need a new response with their accepted-labeler header.
        if labelers.isEmpty, self.trendingTopicMediaStore.consumePrefetchedFeedReuse(for: link), let cached = await self.getPrefetchedFeed(.feed(uri)) {
          return Array(cached.posts.prefix(30))
        }
        try Task.checkCancellation()
        guard self.trendingTopicMediaStore.isActive, !self.isAccountSwitchSuspended,
              self.userDID == viewerDID else { throw CancellationError() }
        let (status, response) = try await client.app.bsky.feed.getFeed(input: .init(feed: uri, limit: 12))
        guard self.trendingTopicMediaStore.isActive, !self.isAccountSwitchSuspended, self.userDID == viewerDID, self.topicPreviewLabelers == labelers, self.topicPreviewLabelerScopeIsCurrent else { throw CancellationError() }
        guard status == 200, let response else { throw FeedPreviewError.fetchFailed(status) }
        return response.feed
      }
    }
  }

  @MainActor
  func topicPreviewPrefetchIdentity(links: [String]) -> String {
    "\(userDID)|\(topicPreviewLabelers)|\(topicPreviewAppliedLabelers)|\(trendingTopicMediaStore.revision)|"
      + TopicPreviewPrefetchCoordinator.boundedLinks(links).joined(separator: "|")
  }

  @MainActor
  func prefetchTopicPreviews(links: [String], owner: TopicPreviewPrefetchOwner) {
    guard trendingTopicMediaStore.isActive, !isAccountSwitchSuspended, appSettings.showTrendingTopics, topicPreviewLabelerScopeIsCurrent else { return }
    let links = TopicPreviewPrefetchCoordinator.boundedLinks(links)
    let viewerDID = userDID
    let labelers = topicPreviewLabelers
    let revision = trendingTopicMediaStore.revision
    let identity = topicPreviewPrefetchIdentity(links: links)
    let started = trendingTopicMediaStore.prefetchCoordinator.start(owner: owner, identity: identity, links: links) { [weak self] link in
      guard let self, self.trendingTopicMediaStore.isActive, !Task.isCancelled else { return }
      await self.loadTopicPreview(for: link)
      guard self.trendingTopicMediaStore.isActive, !Task.isCancelled, !self.isAccountSwitchSuspended, self.userDID == viewerDID,
            self.topicPreviewLabelers == labelers, self.topicPreviewLabelerScopeIsCurrent,
            self.trendingTopicMediaStore.revision == revision else { return }
      // Re-evaluate current local decisions after awaits and before issuing any image request.
      self.trendingTopicMediaStore.warmImages(self.topicPreview(for: link), owner: owner)
    }
    if started { trendingTopicMediaStore.resetImagePrefetch(owner: owner) }
  }

  @MainActor
  func cancelTopicPreviewPrefetch(owner: TopicPreviewPrefetchOwner) {
    trendingTopicMediaStore.cancelPrefetch(owner: owner)
  }
}
