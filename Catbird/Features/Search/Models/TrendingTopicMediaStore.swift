import Foundation
import Nuke
import Observation
import Petrel
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Per-topic observation: one topic's preview arriving re-renders only the views showing that topic.
@MainActor @Observable
final class TopicPreviewSlot {
  var generation = 0
}

/// Account-owned raw preview cache. Only the presentation policy may extract image URLs.
@MainActor @Observable
final class TrendingTopicMediaStore {
  private struct Entry {
    let posts: [AppBskyFeedDefs.FeedViewPost]
    let quotedPosts: [String: AppBskyFeedDefs.PostView]
    let expiresAt: Date
    let generation: Int
  }
  private struct Selection {
    let generation: Int
    let token: TopicPreviewContextToken
    let preview: TrendingTopicPreview
  }
  @ObservationIgnored private var entries: [String: Entry] = [:]
  @ObservationIgnored private var slots: [String: TopicPreviewSlot] = [:]
  @ObservationIgnored private var selections: [String: Selection] = [:]
  @ObservationIgnored private var retainedImages = TopicPreviewImageRetention<TrendingTopicImageRequests.Identity, Nuke.PlatformImage>()
  @ObservationIgnored private var entryGeneration = 0
  private(set) var revision = 0
  /// Subscribed labelers' definitions, keyed by the labeler set they were loaded for.
  @ObservationIgnored private var labelDefinitions: (labelers: String, definitions: ContentLabelDefinitionLookup.Definitions)?
  /// The only observed signal for definitions: it changes once per labeler set, so cards
  /// re-select their previews once instead of observing the definitions themselves.
  private(set) var labelDefinitionsGeneration = 0
  @ObservationIgnored private let gate = TopicPreviewRequestGate()
  @ObservationIgnored private var requests: [UUID: Task<Void, Never>] = [:]
  /// Requests admitted past the gate. Their fetch outlives the requesting card.
  @ObservationIgnored private var startedRequests: Set<UUID> = []
  @ObservationIgnored let prefetchCoordinator = TopicPreviewPrefetchCoordinator()
  /// Trend art is above-the-fold discovery content; warm it ahead of ordinary low-priority prefetch.
  @ObservationIgnored private let imagePrefetcher: ImagePrefetcher = {
    let prefetcher = ImagePrefetcher(pipeline: ImageLoadingManager.shared.pipeline, maxConcurrentRequestCount: 4)
    prefetcher.priority = .normal
    return prefetcher
  }()
  @ObservationIgnored private var imageOwnership = TopicPreviewImagePrefetchOwnership<ImageRequest, TrendingTopicImageRequests.Identity>()
  @ObservationIgnored private var lastLabelers: String?
  @ObservationIgnored private var graphObserver: NSObjectProtocol?
  @ObservationIgnored private var activityObserver: NSObjectProtocol?
  @ObservationIgnored private var inactivityObserver: NSObjectProtocol?
  @ObservationIgnored private var memoryObserver: NSObjectProtocol?
  private(set) var canReusePrefetchedFeed = true
  private(set) var isActive = true
  @ObservationIgnored private var prefetchedLinksUsed: Set<String> = []

  func labelDefinitions(for labelers: String) -> ContentLabelDefinitionLookup.Definitions? {
    labelDefinitions?.labelers == labelers ? labelDefinitions?.definitions : nil
  }

  func setLabelDefinitions(_ definitions: ContentLabelDefinitionLookup.Definitions, for labelers: String) {
    labelDefinitions = (labelers, definitions)
    labelDefinitionsGeneration += 1
  }

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
    memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
      object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.retainedImages.removeAll() }
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
      retainedImages.removeAll()
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
    if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
  }

  func invalidateForGraphChange() {
    cancelRequests()
    cancelPrefetches()
    canReusePrefetchedFeed = false
    removeAllEntries()
    revision += 1
  }

  func invalidate(labelers: String) {
    guard lastLabelers != labelers else { return }
    lastLabelers = labelers
    labelDefinitions = nil
    cancelRequests()
    cancelPrefetches()
    removeAllEntries()
    revision += 1
  }

  func load(
    key: String,
    hydrate: (([AppBskyFeedDefs.FeedViewPost]) async -> [AppBskyFeedDefs.PostView])? = nil,
    fetch: @escaping () async throws -> [AppBskyFeedDefs.FeedViewPost]
  ) async {
    guard isActive, !Task.isCancelled else { return }
    let id = UUID()
    // Own direct row requests as well as metadata batches, so account suspension cancels both.
    let request = Task { [weak self] in
      guard let self else { return }
      await self.performLoad(id: id, key: key, hydrate: hydrate, fetch: fetch)
    }
    requests[id] = request
    defer {
      requests.removeValue(forKey: id)
      startedRequests.remove(id)
    }
    // A lazy card scrolling away or redrawing cancels its task. A request still queued at the
    // gate is dropped, but a started fetch completes and caches, so the card that reappears
    // finds the result instead of losing it and refetching. Invalidation still cancels both.
    await withTaskCancellationHandler {
      await request.value
    } onCancel: {
      Task { @MainActor [weak self] in self?.dropIfQueued(id) }
    }
  }

  private func dropIfQueued(_ id: UUID) {
    guard !startedRequests.contains(id) else { return }
    requests[id]?.cancel()
  }

  private func cancelRequests() {
    for request in requests.values { request.cancel() }
  }

  private func performLoad(
    id: UUID,
    key: String,
    hydrate: (([AppBskyFeedDefs.FeedViewPost]) async -> [AppBskyFeedDefs.PostView])?,
    fetch: () async throws -> [AppBskyFeedDefs.FeedViewPost]
  ) async {
    guard isActive, !Task.isCancelled else { return }
    guard entries[key]?.expiresAt ?? .distantPast <= Date() else { return }
    let requestRevision = revision
    do {
      try await gate.acquire(key)
      defer { gate.release(key) }
      try Task.checkCancellation()
      guard isActive, revision == requestRevision else { return }
      guard entries[key]?.expiresAt ?? .distantPast <= Date() else { return }
      startedRequests.insert(id)
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
    let now = Date()
    for (expiredKey, entry) in entries where entry.expiresAt <= now { removeEntry(expiredKey) }
    if entries.count >= 20, let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
      removeEntry(oldest)
    }
    var quotes: [String: AppBskyFeedDefs.PostView] = [:]
    for post in quotedPosts.prefix(TrendingTopicPreviewPolicy.maxHydratedQuotes) { quotes[post.uri.uriString()] = post }
    entryGeneration += 1
    entries[key] = Entry(posts: Array(posts.prefix(30)), quotedPosts: quotes,
      expiresAt: now.addingTimeInterval(lifetime), generation: entryGeneration)
    slot(for: key).generation += 1
  }

  /// Observers of a removed topic are notified; the next read observes a fresh slot.
  private func removeEntry(_ key: String) {
    entries.removeValue(forKey: key)
    selections.removeValue(forKey: key)
    slots.removeValue(forKey: key)?.generation += 1
  }

  private func removeAllEntries() {
    retainedImages.removeAll()
    entries.removeAll()
    selections.removeAll()
    for slot in slots.values { slot.generation += 1 }
    slots.removeAll()
  }

  private func slot(for key: String) -> TopicPreviewSlot {
    if let slot = slots[key] { return slot }
    let slot = TopicPreviewSlot()
    slots[key] = slot
    return slot
  }

  func preview(key: String, context: TrendingTopicPreviewPolicy.Context) -> TrendingTopicPreview {
    _ = slot(for: key).generation
    var context = context
    context.quotedPosts = entries[key]?.quotedPosts ?? [:]
    return TrendingTopicPreviewPolicy.select(entries[key]?.posts ?? [], context: context)
  }

  /// Render path: selects once per cached response and context token, so scrolling past a
  /// trend card reuses the moderated preview instead of re-filtering up to thirty posts.
  func preview(
    key: String,
    token: TopicPreviewContextToken,
    context: () -> TrendingTopicPreviewPolicy.Context
  ) -> TrendingTopicPreview {
    _ = slot(for: key).generation
    guard let entry = entries[key] else { return TrendingTopicPreview() }
    if let selection = selections[key], selection.generation == entry.generation, selection.token == token {
      return selection.preview
    }
    var context = context()
    context.quotedPosts = entry.quotedPosts
    let preview = TrendingTopicPreviewPolicy.select(entry.posts, context: context)
    selections[key] = Selection(generation: entry.generation, token: token, preview: preview)
    return preview
  }

  func warmImages(
    _ preview: TrendingTopicPreview,
    participants: [TrendingTopicPreview.Participant]? = nil,
    displayScale: CGFloat,
    owner: TopicPreviewPrefetchOwner
  ) {
    guard isActive else { return }
    // Six topics, three static cards and three avatars each; never expand with scroll renders.
    let requests = TrendingTopicImageRequests.requests(for: preview, participants: participants ?? preview.participants,
      displayScale: displayScale)
    let additions = imageOwnership.append(requests, owner: owner,
      identity: TrendingTopicImageRequests.identity)
    imagePrefetcher.startPrefetching(with: additions)
  }

  /// Called only for requests selected by the current moderated artwork, never to select media.
  /// Memory-only lookup avoids disk decode and an empty LazyImage state on the first frame.
  func image(for request: ImageRequest) -> Nuke.PlatformImage? {
    guard isActive, !request.options.contains(.disableMemoryCacheReads) else { return nil }
    if let image = retainedImages.value(for: TrendingTopicImageRequests.identity(request)) { return image }
    guard let container = ImageLoadingManager.shared.pipeline.cache[request], !container.isPreview else { return nil }
    return staticImage(container.image)?.image
  }

  /// No tasks are retained. Late image completion cannot repopulate an invalidated account.
  func retainImage(_ image: Nuke.PlatformImage, for request: ImageRequest, revision expectedRevision: Int) {
    guard isActive, revision == expectedRevision, !request.options.contains(.disableMemoryCacheWrites),
          let still = staticImage(image) else { return }
    retainedImages.insert(still.image, for: TrendingTopicImageRequests.identity(request), cost: still.cost)
  }

  private func staticImage(_ image: Nuke.PlatformImage) -> (image: Nuke.PlatformImage, cost: Int)? {
    #if os(macOS)
    guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let still = Nuke.PlatformImage(cgImage: bitmap, size: image.size)
    #else
    guard let bitmap = image.cgImage else { return nil }
    let still = Nuke.PlatformImage(cgImage: bitmap, scale: image.scale, orientation: image.imageOrientation)
    #endif
    // Retain one bitmap only, without original GIF data, frames or container metadata.
    let (cost, overflow) = bitmap.bytesPerRow.multipliedReportingOverflow(by: bitmap.height)
    guard !overflow else { return nil }
    return (still, cost)
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

  static let cardSize = CGSize(width: 62, height: 72)
  static let avatarSize = CGSize(width: 26, height: 26)

  /// Priority is not part of the load identity, so visible rows raise a coalesced prefetch.
  static func request(_ url: URL, size: CGSize, displayScale: CGFloat, priority: ImageRequest.Priority = .low) -> ImageRequest {
    let pixels = CGSize(width: size.width * displayScale, height: size.height * displayScale)
    return ImageRequest(url: url, processors: [
      ImageProcessors.Resize(size: pixels, unit: .pixels, contentMode: .aspectFill)
    ], priority: priority)
  }

  static func requests(
    for preview: TrendingTopicPreview,
    participants: [TrendingTopicPreview.Participant]? = nil,
    displayScale: CGFloat
  ) -> [ImageRequest] {
    preview.media.prefix(3).map { request($0.url, size: cardSize, displayScale: displayScale) }
      + (participants ?? preview.participants).prefix(3).map { request($0.avatar, size: avatarSize, displayScale: displayScale) }
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
    topicArtwork(for: link, actors: nil).preview
  }

  /// Moderated "who is chatting" avatars for a trend; empty whenever previews are not permitted.
  @MainActor
  func topicParticipants(for link: String, actors: [AppBskyActorDefs.ProfileViewBasic]) -> [TrendingTopicPreview.Participant] {
    topicArtwork(for: link, actors: actors).participants ?? []
  }

  @MainActor
  func loadTopicPreview(for link: String) async {
    guard trendingTopicMediaStore.isActive, !isAccountSwitchSuspended, appSettings.showTrendingTopics, topicPreviewLabelerScopeIsCurrent,
          (try? preferencesManager.getLocalPreferences()) != nil,
          let client = atProtoClient, let uri = TrendingTopicPreviewPolicy.feedURI(for: link) else { return }
    let labelers = topicPreviewLabelers
    let viewerDID = userDID
    await loadTopicPreviewLabelDefinitions(client: client)
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

  /// Custom labels block previews until their labeler definitions are known; one shared,
  /// account-scoped request (the feed's own cache) resolves them for every trend.
  @MainActor
  private func loadTopicPreviewLabelDefinitions(client: ATProtoClient) async {
    let labelers = topicPreviewLabelers
    guard trendingTopicMediaStore.labelDefinitions(for: labelers) == nil,
          let preferences = try? preferencesManager.getLocalPreferences() else { return }
    let viewerDID = userDID
    guard let definitions = try? await withTopicPreviewLabelerIO({
      try await ContentLabelDefinitionLookup.subscribedDefinitions(appState: self, preferences: preferences, client: client)
    }), userDID == viewerDID, topicPreviewLabelers == labelers else { return }
    trendingTopicMediaStore.setLabelDefinitions(definitions, for: labelers)
  }

  @MainActor
  private func withTopicPreviewLabelerIO(
    _ operation: @MainActor () async throws -> ContentLabelDefinitionLookup.Definitions
  ) async throws -> ContentLabelDefinitionLookup.Definitions? {
    var result: ContentLabelDefinitionLookup.Definitions?
    var failure: Error?
    await withTopicPreviewAccountOperation {
      do { result = try await operation() } catch { failure = error }
    }
    if let failure { throw failure }
    return result
  }

  @MainActor
  func topicPreviewPrefetchIdentity(links: [String]) -> String {
    "\(userDID)|\(topicPreviewLabelers)|\(topicPreviewAppliedLabelers)|\(trendingTopicMediaStore.revision)|"
      + TopicPreviewPrefetchCoordinator.boundedLinks(links).joined(separator: "|")
  }

  /// Preferred entry point: trend actors let avatars warm before any preview feed responds.
  @MainActor
  func prefetchTopicPreviews(trends: [AppBskyUnspeccedDefs.TrendView], displayScale: CGFloat, owner: TopicPreviewPrefetchOwner) {
    let actors = Dictionary(trends.map { ($0.link, $0.actors) }, uniquingKeysWith: { first, _ in first })
    prefetchTopicPreviews(links: trends.map(\.link), actors: actors, displayScale: displayScale, owner: owner)
  }

  @MainActor
  func prefetchTopicPreviews(
    links: [String],
    actors: [String: [AppBskyActorDefs.ProfileViewBasic]] = [:],
    displayScale: CGFloat,
    owner: TopicPreviewPrefetchOwner
  ) {
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
      let artwork = self.topicArtwork(for: link, actors: actors[link] ?? [])
      self.trendingTopicMediaStore.warmImages(artwork.preview, participants: artwork.participants,
        displayScale: displayScale, owner: owner)
    }
    // A running or completed batch with this identity already warmed these avatars.
    guard started else { return }
    trendingTopicMediaStore.resetImagePrefetch(owner: owner)
    // Trend actors arrive with getTrends; their avatars need no preview round trip.
    for link in links {
      let participants = topicParticipants(for: link, actors: actors[link] ?? [])
      guard !participants.isEmpty else { continue }
      trendingTopicMediaStore.warmImages(TrendingTopicPreview(), participants: participants,
        displayScale: displayScale, owner: owner)
    }
  }

  @MainActor
  func cancelTopicPreviewPrefetch(owner: TopicPreviewPrefetchOwner) {
    trendingTopicMediaStore.cancelPrefetch(owner: owner)
  }
}
