import Foundation
import Observation
import Petrel

/// Drives the App Store-style Feed Discovery Storefront: dynamic shelves
/// ("Popular on Bluesky", "Liked by People You Follow", "By Catbird", and "By Category")
/// with account-switch isolation and lazy category enrichment.
@MainActor
@Observable
final class FeedStorefrontViewModel {
  private(set) var catbirdFeeds: [AppBskyFeedDefs.GeneratorView] = []
  private(set) var popularFeeds: [AppBskyFeedDefs.GeneratorView] = []
  private(set) var popularCursor: String?
  private(set) var followLikedFeeds: [FollowLikedFeed] = []
  private(set) var categoryBuckets: [FeedDiscoveryCategory: [AppBskyFeedDefs.GeneratorView]] = [:]
  private(set) var categoryRemoteFeeds: [FeedDiscoveryCategory: [AppBskyFeedDefs.GeneratorView]] = [:]
  private(set) var categoryCursors: [FeedDiscoveryCategory: String] = [:]

  var selectedCategory: FeedDiscoveryCategory?

  private(set) var isInitialLoading = false
  private(set) var isRefreshing = false
  private(set) var isLoadingFollowLiked = false
  private(set) var isLoadingMorePopular = false
  private(set) var loadingCategories: Set<FeedDiscoveryCategory> = []
  private(set) var initialError: String?
  private(set) var refreshError: String?
  private(set) var pagingError: String?
  private(set) var accountDID: String

  @ObservationIgnored private var provider: any FeedStorefrontProviding
  @ObservationIgnored private var clientIdentity: ObjectIdentifier?
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var followLikedTask: Task<Void, Never>?
  @ObservationIgnored private var morePopularTask: Task<Void, Never>?
  @ObservationIgnored private var categoryTasks: [FeedDiscoveryCategory: Task<Void, Never>] = [:]
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var hasLoaded = false
  @ObservationIgnored private var consumedPopularCursors: Set<String> = []

  init(provider: any FeedStorefrontProviding, accountDID: String) {
    self.provider = provider
    self.accountDID = accountDID
  }

  convenience init(client: ATProtoClient, accountDID: String) {
    self.init(provider: FeedDiscoveryProvider(client: client), accountDID: accountDID)
    self.clientIdentity = ObjectIdentifier(client)
  }

  var hasDirectFollowLikes: Bool {
    followLikedFeeds.contains { !$0.likedByHandles.isEmpty }
  }

  var followLikedShelfTitle: String {
    hasDirectFollowLikes
      ? String(localized: "Liked by People You Follow", comment: "Feed discovery shelf title showing feeds liked by accounts the user follows")
      : String(localized: "Suggested for You", comment: "Feed discovery shelf title showing personalized feed recommendations")
  }

  var followLikedShelfSubtitle: String {
    hasDirectFollowLikes
      ? String(localized: "Feeds saved or liked across your follow graph", comment: "Feed discovery shelf subtitle when feeds are liked by followed accounts")
      : String(localized: "Personalized picks from across Bluesky", comment: "Feed discovery shelf subtitle for personalized recommendations")
  }

  /// Categories that currently have at least one feed bucketed from loaded shelves.
  var populatedCategories: [FeedDiscoveryCategory] {
    FeedDiscoveryCategory.allCases.filter { !(categoryBuckets[$0] ?? []).isEmpty }
  }

  /// Combined local bucket + remote category results, deduplicated by URI.
  func feeds(for category: FeedDiscoveryCategory) -> [AppBskyFeedDefs.GeneratorView] {
    let local = categoryBuckets[category] ?? []
    let remote = categoryRemoteFeeds[category] ?? []
    var seen = Set<String>()
    var combined: [AppBskyFeedDefs.GeneratorView] = []
    for feed in local + remote where seen.insert(feed.uri.uriString()).inserted {
      combined.append(feed)
    }
    return combined
  }

  func isLoading(category: FeedDiscoveryCategory) -> Bool {
    loadingCategories.contains(category)
  }

  func load() {
    guard !hasLoaded else { return }
    refresh()
  }

  func refresh() {
    cancel()
    hasLoaded = true
    initialError = nil
    refreshError = nil
    pagingError = nil
    isInitialLoading = popularFeeds.isEmpty
    isRefreshing = !popularFeeds.isEmpty

    let capturedGen = generation
    let capturedAccount = accountDID
    let provider = provider

    loadTask = Task { [weak self] in
      async let popularResult: Result<FeedDiscoveryPage, Error> = {
        do {
          return .success(try await provider.fetchPopularFeeds(cursor: nil, limit: 36))
        } catch {
          return .failure(error)
        }
      }()
      async let catbirdResult = provider.fetchCatbirdFeeds()

      let (popRes, catbird) = await (popularResult, catbirdResult)
      guard let self, !Task.isCancelled,
            self.generation == capturedGen, self.accountDID == capturedAccount
      else { return }

      self.catbirdFeeds = catbird

      switch popRes {
      case .success(let page):
        var seen = Set<String>()
        self.popularFeeds = page.feeds.filter { seen.insert($0.uri.uriString()).inserted }
        self.popularCursor = page.cursor
        self.consumedPopularCursors = []
        self.rebuildCategoryBuckets()
        self.isInitialLoading = false
        self.isRefreshing = false
        self.startFollowLikedLoad(candidates: self.popularFeeds, generation: capturedGen, account: capturedAccount)
      case .failure(let error):
        if !(error is CancellationError), !Task.isCancelled {
          if self.popularFeeds.isEmpty {
            self.initialError = error.localizedDescription
          } else {
            self.refreshError = error.localizedDescription
          }
        }
        self.isInitialLoading = false
        self.isRefreshing = false
      }
    }
  }

  func loadMorePopular() {
    guard !isInitialLoading, !isRefreshing, !isLoadingMorePopular,
          let cursor = popularCursor
    else { return }
    pagingError = nil
    isLoadingMorePopular = true

    let capturedGen = generation
    let capturedAccount = accountDID
    let provider = provider

    morePopularTask = Task { [weak self] in
      do {
        let page = try await provider.fetchPopularFeeds(cursor: cursor, limit: 24)
        guard let self, !Task.isCancelled,
              self.generation == capturedGen, self.accountDID == capturedAccount
        else { return }
        var seen = Set(self.popularFeeds.map { $0.uri.uriString() })
        let unique = page.feeds.filter { seen.insert($0.uri.uriString()).inserted }
        self.popularFeeds.append(contentsOf: unique)
        self.consumedPopularCursors.insert(cursor)
        self.popularCursor = page.cursor.flatMap { self.consumedPopularCursors.contains($0) ? nil : $0 }
        self.rebuildCategoryBuckets()
        self.isLoadingMorePopular = false
      } catch {
        guard let self, self.generation == capturedGen, self.accountDID == capturedAccount else { return }
        if !(error is CancellationError), !Task.isCancelled {
          self.pagingError = error.localizedDescription
        }
        self.isLoadingMorePopular = false
      }
    }
  }

  func loadCategoryIfNeeded(_ category: FeedDiscoveryCategory, loadMore: Bool = false) {
    if !loadMore, categoryRemoteFeeds[category] != nil { return }
    if loadingCategories.contains(category) { return }
    let cursor = loadMore ? categoryCursors[category] : nil
    if loadMore && cursor == nil { return }

    loadingCategories.insert(category)
    let capturedGen = generation
    let capturedAccount = accountDID
    let provider = provider

    categoryTasks[category]?.cancel()
    categoryTasks[category] = Task { [weak self] in
      do {
        let page = try await provider.fetchCategoryFeeds(category: category, cursor: cursor)
        guard let self, !Task.isCancelled,
              self.generation == capturedGen, self.accountDID == capturedAccount
        else { return }
        if loadMore {
          var seen = Set((self.categoryRemoteFeeds[category] ?? []).map { $0.uri.uriString() })
          let unique = page.feeds.filter { seen.insert($0.uri.uriString()).inserted }
          self.categoryRemoteFeeds[category, default: []].append(contentsOf: unique)
        } else {
          var seen = Set<String>()
          self.categoryRemoteFeeds[category] = page.feeds.filter { seen.insert($0.uri.uriString()).inserted }
        }
        if let next = page.cursor, next != cursor {
          self.categoryCursors[category] = next
        } else {
          self.categoryCursors.removeValue(forKey: category)
        }
        self.loadingCategories.remove(category)
      } catch {
        guard let self, self.generation == capturedGen, self.accountDID == capturedAccount else { return }
        self.loadingCategories.remove(category)
      }
    }
  }

  func updateAccount(client: ATProtoClient, accountDID: String) {
    let identity = ObjectIdentifier(client)
    guard self.accountDID != accountDID || clientIdentity != identity else { return }
    updateAccount(provider: FeedDiscoveryProvider(client: client), accountDID: accountDID)
    clientIdentity = identity
  }

  func updateAccount(provider: any FeedStorefrontProviding, accountDID: String) {
    let changedAccount = self.accountDID != accountDID
    cancel()
    self.provider = provider
    self.accountDID = accountDID
    clientIdentity = nil
    if changedAccount {
      catbirdFeeds = []
      popularFeeds = []
      popularCursor = nil
      consumedPopularCursors = []
      followLikedFeeds = []
      categoryBuckets = [:]
      categoryRemoteFeeds = [:]
      categoryCursors = [:]
      selectedCategory = nil
      hasLoaded = false
    }
    refresh()
  }

  func cancel() {
    generation += 1
    loadTask?.cancel()
    loadTask = nil
    followLikedTask?.cancel()
    followLikedTask = nil
    morePopularTask?.cancel()
    morePopularTask = nil
    for task in categoryTasks.values { task.cancel() }
    categoryTasks.removeAll()
    isInitialLoading = false
    isRefreshing = false
    isLoadingFollowLiked = false
    isLoadingMorePopular = false
    loadingCategories.removeAll()
  }
}

extension FeedStorefrontViewModel {
  private func startFollowLikedLoad(
    candidates: [AppBskyFeedDefs.GeneratorView],
    generation capturedGen: Int,
    account capturedAccount: String
  ) {
    followLikedTask?.cancel()
    isLoadingFollowLiked = true
    let provider = provider
    followLikedTask = Task { [weak self] in
      let results = await provider.fetchFollowLikedFeeds(candidates: candidates)
      guard let self, !Task.isCancelled,
            self.generation == capturedGen, self.accountDID == capturedAccount
      else { return }
      self.followLikedFeeds = results
      self.isLoadingFollowLiked = false
      self.rebuildCategoryBuckets()
    }
  }

  private func rebuildCategoryBuckets() {
    var combined: [AppBskyFeedDefs.GeneratorView] = []
    var seen = Set<String>()
    for feed in popularFeeds + followLikedFeeds.map(\.feed) + catbirdFeeds
    where seen.insert(feed.uri.uriString()).inserted {
      combined.append(feed)
    }
    categoryBuckets = FeedDiscoveryCategoryClassifier.bucket(combined)
  }

  /// Chunks an array into App Store Top Charts-style stacked columns (default: 3 rows per column).
  nonisolated static func chunkIntoColumns<T>(_ items: [T], rowsPerColumn: Int = 3) -> [[T]] {
    let size = max(1, rowsPerColumn)
    guard !items.isEmpty else { return [] }
    return stride(from: 0, to: items.count, by: size).map { start in
      Array(items[start..<min(start + size, items.count)])
    }
  }
}
