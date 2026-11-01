import Foundation
import Petrel

/// Per-account trend and trending-video lists shared by Search and the timeline interstitial, with at
/// most one request per account and list in flight.
///
/// Trends are also kept on disk (`TrendingTopicsDiskCache`) so the next launch paints them at once.
/// A list counts as fresh, and skips the network, only when it was fetched within `freshAge` and after
/// the last invalidation; anything older is shown while a refresh runs. That includes every list read
/// back from disk in a new process, so a mute, block or label applied elsewhere is picked up by the
/// refresh instead of waiting out the fresh window.
@MainActor
final class TrendingTopicListCache {
  typealias Trend = AppBskyUnspeccedDefs.TrendView
  typealias Video = AppBskyFeedDefs.FeedViewPost

  /// How long a list fetched in this session skips the network.
  static let freshAge: TimeInterval = 10 * 60

  private struct Cached<Value> {
    let value: [Value]
    let fetchedAt: Date
  }

  private struct InFlight<Value: Sendable> {
    let id: UUID
    let task: Task<[Value], Error>
  }

  private let disk: TrendingTopicsDiskCache
  private let now: () -> Date
  private var trends: [String: Cached<Trend>] = [:]
  private var videos: [String: Cached<Video>] = [:]
  private var trendsInFlight: [String: InFlight<Trend>] = [:]
  private var videosInFlight: [String: InFlight<Video>] = [:]
  /// Lists fetched before this instant are never fresh.
  private var trustedSince: Date

  init(disk: TrendingTopicsDiskCache = TrendingTopicsDiskCache(), now: @escaping () -> Date = Date.init) {
    self.disk = disk
    self.now = now
    trustedSince = now()
  }

  // MARK: Trends

  /// This account's trends from memory, else from disk (up to `TrendingTopicsDiskCache.maxAge` old).
  func cachedTrends(for accountDID: String) -> (trends: [Trend], isFresh: Bool)? {
    guard !accountDID.isEmpty else { return nil }
    if let memory = trends[accountDID] {
      if now().timeIntervalSince(memory.fetchedAt) < TrendingTopicsDiskCache.maxAge {
        return (memory.value, isFresh(memory.fetchedAt))
      }
      trends[accountDID] = nil
    }
    guard let stored = disk.load(accountDID: accountDID) else { return nil }
    trends[accountDID] = Cached(value: stored.trends, fetchedAt: stored.savedAt)
    return (stored.trends, isFresh(stored.savedAt))
  }

  func fetchOrCoalesceTrends(
    for accountDID: String,
    force: Bool = false,
    fetch: @escaping @MainActor () async throws -> [Trend]
  ) async throws -> [Trend] {
    if !force, let cached = cachedTrends(for: accountDID), cached.isFresh {
      return cached.trends
    }
    return try await coalesce(\.trendsInFlight, accountDID: accountDID, fetch: fetch) { cache, list in
      cache.storeTrends(list, for: accountDID)
    }
  }

  private func storeTrends(_ list: [Trend], for accountDID: String) {
    guard !accountDID.isEmpty, !list.isEmpty else { return }
    let fetchedAt = now()
    trends[accountDID] = Cached(value: list, fetchedAt: fetchedAt)
    disk.store(list, accountDID: accountDID, savedAt: fetchedAt)
  }

  // MARK: Videos (memory only)

  func cachedVideos(for accountDID: String) -> (videos: [Video], isFresh: Bool)? {
    guard !accountDID.isEmpty, let memory = videos[accountDID] else { return nil }
    return (memory.value, isFresh(memory.fetchedAt))
  }

  func fetchOrCoalesceVideos(
    for accountDID: String,
    force: Bool = false,
    fetch: @escaping @MainActor () async throws -> [Video]
  ) async throws -> [Video] {
    if !force, let cached = cachedVideos(for: accountDID), cached.isFresh {
      return cached.videos
    }
    return try await coalesce(\.videosInFlight, accountDID: accountDID, fetch: fetch) { cache, list in
      guard !accountDID.isEmpty, !list.isEmpty else { return }
      cache.videos[accountDID] = Cached(value: list, fetchedAt: cache.now())
    }
  }

  // MARK: Invalidation

  /// Forgets every list in memory and every request in flight, and stops trusting anything fetched
  /// so far. Requests already sent still answer their callers but are not cached. Stored trends stay
  /// on disk to paint the next launch, as stale lists. Used when the app leaves the foreground and when
  /// an account is suspended or retired.
  func invalidate() {
    trends.removeAll()
    videos.removeAll()
    trendsInFlight.removeAll()
    videosInFlight.removeAll()
    trustedSince = now()
  }

  /// `invalidate()`, and also removes every account's stored trends. Used after a mute, block or
  /// labeler change, which every stored list predates.
  func invalidateIncludingDisk() {
    invalidate()
    disk.removeAll()
  }

  // MARK: Helpers

  private func isFresh(_ fetchedAt: Date) -> Bool {
    fetchedAt >= trustedSince && now().timeIntervalSince(fetchedAt) < Self.freshAge
  }

  private func coalesce<Value: Sendable>(
    _ inFlight: ReferenceWritableKeyPath<TrendingTopicListCache, [String: InFlight<Value>]>,
    accountDID: String,
    fetch: @escaping @MainActor () async throws -> [Value],
    store: @escaping @MainActor (TrendingTopicListCache, [Value]) -> Void
  ) async throws -> [Value] {
    if let existing = self[keyPath: inFlight][accountDID] {
      return try await existing.task.value
    }
    let id = UUID()
    let task = Task { @MainActor [weak self] () throws -> [Value] in
      defer {
        if self?[keyPath: inFlight][accountDID]?.id == id {
          self?[keyPath: inFlight][accountDID] = nil
        }
      }
      let values = try await fetch()
      // Invalidation drops the entry: a response to a request sent before it is not cached.
      if let self, self[keyPath: inFlight][accountDID]?.id == id {
        store(self, values)
      }
      return values
    }
    self[keyPath: inFlight][accountDID] = InFlight(id: id, task: task)
    return try await task.value
  }
}

extension TrendingTopicMediaStore {
  func cachedTrends(for accountDID: String) -> (trends: [TrendingTopicListCache.Trend], isFresh: Bool)? {
    lists.cachedTrends(for: accountDID)
  }

  func fetchOrCoalesceTrends(
    for accountDID: String,
    force: Bool = false,
    fetch: @escaping @MainActor () async throws -> [TrendingTopicListCache.Trend]
  ) async throws -> [TrendingTopicListCache.Trend] {
    try await lists.fetchOrCoalesceTrends(for: accountDID, force: force, fetch: fetch)
  }

  func cachedVideos(for accountDID: String) -> (videos: [TrendingTopicListCache.Video], isFresh: Bool)? {
    lists.cachedVideos(for: accountDID)
  }

  func fetchOrCoalesceVideos(
    for accountDID: String,
    force: Bool = false,
    fetch: @escaping @MainActor () async throws -> [TrendingTopicListCache.Video]
  ) async throws -> [TrendingTopicListCache.Video] {
    try await lists.fetchOrCoalesceVideos(for: accountDID, force: force, fetch: fetch)
  }
}
