import Foundation
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
    let expiresAt: Date
  }
  private var entries: [String: Entry] = [:]
  private(set) var revision = 0
  @ObservationIgnored private let gate = TopicPreviewRequestGate()
  @ObservationIgnored private var lastLabelers: String?
  @ObservationIgnored private var graphObserver: NSObjectProtocol?
  @ObservationIgnored private var activityObserver: NSObjectProtocol?
  private(set) var canReusePrefetchedFeed = true
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
    activityObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
      object: nil, queue: .main) { [weak self] _ in
        // Refresh viewer metadata after another client or a background App Intent changed moderation.
        MainActor.assumeIsolated { self?.invalidateForGraphChange() }
      }
    #endif
  }

  deinit {
    if let graphObserver { NotificationCenter.default.removeObserver(graphObserver) }
    if let activityObserver { NotificationCenter.default.removeObserver(activityObserver) }
  }

  func invalidateForGraphChange() {
    canReusePrefetchedFeed = false
    entries.removeAll()
    revision += 1
  }

  func invalidate(labelers: String) {
    guard lastLabelers != labelers else { return }
    lastLabelers = labelers
    entries.removeAll()
    revision += 1
  }

  func load(key: String, fetch: () async throws -> [AppBskyFeedDefs.FeedViewPost]) async {
    guard entries[key]?.expiresAt ?? .distantPast <= Date() else { return }
    let requestRevision = revision
    do {
      try await gate.acquire(key)
      defer { gate.release(key) }
      try Task.checkCancellation()
      guard revision == requestRevision else { return }
      guard entries[key]?.expiresAt ?? .distantPast <= Date() else { return }
      let posts = try await fetch()
      try Task.checkCancellation()
      guard revision == requestRevision else { return }
      cache(posts: posts, key: key, lifetime: 300)
    } catch is CancellationError {
      // Cancellation does not poison a later visible row's cache.
    } catch {
      guard !Task.isCancelled, revision == requestRevision else { return }
      // A failed preview remains a fully usable text topic; back navigation does not retry it.
      cache(posts: [], key: key, lifetime: 60)
    }
  }

  private func cache(posts: [AppBskyFeedDefs.FeedViewPost], key: String, lifetime: TimeInterval) {
    entries = entries.filter { $0.value.expiresAt > Date() }
    if entries.count >= 20, let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
      entries.removeValue(forKey: oldest)
    }
    entries[key] = Entry(posts: Array(posts.prefix(30)), expiresAt: Date().addingTimeInterval(lifetime))
  }

  func preview(key: String, context: TrendingTopicPreviewPolicy.Context) -> TrendingTopicPreview {
    TrendingTopicPreviewPolicy.select(entries[key]?.posts ?? [], context: context)
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
      allowsPost: { item in
        filters.allSatisfy { $0.filterBlock(item) }
          && (!self.appSettings.hideNonPreferredLanguages || languageFilter.process(post: item))
      }
    )
    return trendingTopicMediaStore.preview(key: topicPreviewLabelers + "|" + link, context: context)
  }

  @MainActor
  func loadTopicPreview(for link: String) async {
    guard !isAccountSwitchSuspended, appSettings.showTrendingTopics, topicPreviewLabelerScopeIsCurrent,
          (try? preferencesManager.getLocalPreferences()) != nil,
          let client = atProtoClient, let uri = TrendingTopicPreviewPolicy.feedURI(for: link) else { return }
    let labelers = topicPreviewLabelers
    await trendingTopicMediaStore.load(key: labelers + "|" + link) {
      try Task.checkCancellation()
      guard !self.isAccountSwitchSuspended else { throw CancellationError() }
      // Reuse an already hydrated account feed when it has the default labeler scope.
      // Custom labeler subscriptions need a new response with their accepted-labeler header.
      if labelers.isEmpty, self.trendingTopicMediaStore.consumePrefetchedFeedReuse(for: link), let cached = await self.getPrefetchedFeed(.feed(uri)) {
        return Array(cached.posts.prefix(30))
      }
      let (status, response) = try await client.app.bsky.feed.getFeed(input: .init(feed: uri, limit: 12))
      guard !self.isAccountSwitchSuspended, self.topicPreviewLabelers == labelers, self.topicPreviewLabelerScopeIsCurrent else { throw CancellationError() }
      guard status == 200, let response else { throw FeedPreviewError.fetchFailed(status) }
      return response.feed
    }
  }
}
