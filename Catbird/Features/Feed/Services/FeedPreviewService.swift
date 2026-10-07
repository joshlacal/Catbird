import Foundation
import OSLog
import Petrel

protocol FeedDiscoveryPreviewProviding: Sendable {
  func fetchPreview(for feedURI: ATProtocolURI) async throws -> [AppBskyFeedDefs.FeedViewPost]
  func invalidateCache(for feedURI: ATProtocolURI) async
}

/// Fetches only requested feeds and retains a small, account-scoped preview cache.
actor FeedPreviewService: FeedDiscoveryPreviewProviding {
  private let appState: AppState
  private var previewCache: [String: CachedPreview] = [:]
  private var cacheSession: FeedDiscoveryPreviewSession?
  private var cacheGeneration = 0
  private let cacheExpiration: TimeInterval = 300
  private let cacheLimit = 8
  private let logger = Logger(subsystem: "blue.catbird", category: "FeedPreviewService")

  private struct CachedPreview {
    let posts: [AppBskyFeedDefs.FeedViewPost]
    let fetchedAt: Date
    var lastAccessedAt: Date
  }

  init(appState: AppState) {
    self.appState = appState
  }

  func fetchPreview(for feedURI: ATProtocolURI) async throws -> [AppBskyFeedDefs.FeedViewPost] {
    try Task.checkCancellation()
    guard let client = appState.atProtoClient else {
      throw FeedPreviewError.clientNotAvailable
    }
    let session = FeedDiscoveryPreviewSession(accountDID: appState.userDID,
                                              clientIdentity: ObjectIdentifier(client))
    if cacheSession != session {
      clearAllCache()
      cacheSession = session
    }
    let generation = cacheGeneration
    let cacheKey = feedURI.uriString()
    let now = Date()
    previewCache = previewCache.filter { now.timeIntervalSince($0.value.fetchedAt) < cacheExpiration }
    if var cached = previewCache[cacheKey] {
      cached.lastAccessedAt = now
      previewCache[cacheKey] = cached
      return cached.posts
    }

    let parameters = AppBskyFeedGetFeed.Parameters(feed: feedURI, limit: 5)
    let (status, output) = try await client.app.bsky.feed.getFeed(input: parameters)
    try Task.checkCancellation()
    // A replaced client or cleared session must never refill the current cache.
    guard generation == cacheGeneration, cacheSession == session,
          appState.userDID == session.accountDID,
          appState.atProtoClient.map({ ObjectIdentifier($0) }) == session.clientIdentity else {
      throw CancellationError()
    }
    guard status == 200, let output else {
      logger.error("Feed preview request failed with status \(status)")
      throw FeedPreviewError.fetchFailed(status)
    }

    let posts = Array(output.feed.prefix(5))
    let fetchedAt = Date()
    previewCache[cacheKey] = CachedPreview(posts: posts, fetchedAt: fetchedAt, lastAccessedAt: fetchedAt)
    while previewCache.count > cacheLimit {
      guard let oldest = previewCache.min(by: { $0.value.lastAccessedAt < $1.value.lastAccessedAt })?.key else { break }
      previewCache.removeValue(forKey: oldest)
    }
    return posts
  }

  func invalidateCache(for feedURI: ATProtocolURI) {
    previewCache.removeValue(forKey: feedURI.uriString())
  }

  func clearAllCache() {
    cacheGeneration += 1
    previewCache.removeAll()
  }
}

enum FeedPreviewError: LocalizedError {
  case clientNotAvailable
  case fetchFailed(Int)
  case invalidFeedURI

  var errorDescription: String? {
    switch self {
    case .clientNotAvailable:
      return "Sign in to preview this feed."
    case .fetchFailed:
      return "This feed’s recent posts couldn’t be loaded. Try again."
    case .invalidFeedURI:
      return "This feed couldn’t be opened."
    }
  }
}
