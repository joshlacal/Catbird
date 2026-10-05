import Observation
import Accelerate
import OSLog
import Petrel
import SwiftData
import SwiftUI

/// Defines different strategies for loading feed data
enum FeedLoadStrategy {
  /// Complete refresh - replaces all posts
  case fullRefresh
  /// Background refresh - loads new data but preserves UI state until complete
  case backgroundRefresh
  /// Only load if necessary (e.g., empty feed)
  case loadIfNeeded
}

/// Observable model for managing feed data and state
@Observable
final class FeedModel: StateInvalidationSubscriber {
  // MARK: - Properties

  private let logger = Logger(OSLog.feedModel)
  let feedManager: FeedManager
  private let appState: AppState
  private let feedTuner = FeedTuner()
  private let contentFilterService = ContentFilterService()
  @ObservationIgnored @MainActor private var confirmedFilterPreferences: FeedPreferenceSnapshot?
  @ObservationIgnored @MainActor private var settingsRefreshGate: SettingsFeedRefreshGate?
  @ObservationIgnored @MainActor private var readingFilterSignature: ReadingLanguageFilterSignature
  @ObservationIgnored private var settingsObservers: [NSObjectProtocol] = []
  @ObservationIgnored private let prepareSlices: @Sendable ([FeedSlice]) async throws -> [PreparedFeedSlice]

  /// Whether this feed's generator accepts interaction feedback, and its DID for proxy routing.
  /// Nil for non-custom feeds and until the generator info for the current feed is known.
  private(set) var generatorInteractionInfo: FeedGeneratorInteractionInfo?
  private func cacheKey(for feedIdentifier: String) -> String {
    let account = appState.userDID ?? "unknown-account"
    return "\(account)-\(feedIdentifier)"
  }
  
  @MainActor var posts: [CachedFeedViewPost] = [] {
    didSet { contentRevision &+= 1 }
  }
  @MainActor private var contentRevision: UInt64 = 0

  // State tracking
  @MainActor private(set) var isLoading = false
  @MainActor private(set) var isLoadingMore = false
  @MainActor private(set) var isBackgroundRefreshing = false
  @MainActor private(set) var hasMore = true
  @MainActor private(set) var error: Error?
  /// The failure of the most recent page request, cleared when the next one starts.
  @MainActor private(set) var loadMoreError: Error?
  @MainActor private(set) var lastRefreshTime = Date.distantPast

  // Pagination
  @MainActor private var cursor: String?
  
  // A replacement or account reset invalidates work suspended in preparation.
  @MainActor private var publicationGeneration: UInt64 = 0

  private struct PublicationIdentity {
    let generation: UInt64
    let feedKey: String
    let fetchIdentifier: String
  }

  @MainActor
  private func beginFeedGeneration() {
    publicationGeneration &+= 1
    isLoading = false
    isLoadingMore = false
    isBackgroundRefreshing = false
  }

  @MainActor
  private func publicationIdentity(for fetch: FetchType) -> PublicationIdentity {
    PublicationIdentity(
      generation: publicationGeneration,
      feedKey: cacheKey(for: fetch.identifier),
      fetchIdentifier: fetch.identifier
    )
  }

  @MainActor
  private func checkPublication(_ identity: PublicationIdentity) throws {
    try Task.checkCancellation()
    guard identity.generation == publicationGeneration,
          identity.feedKey == cacheKey(for: identity.fetchIdentifier),
          identity.fetchIdentifier == lastFeedType.identifier,
          identity.fetchIdentifier == feedManager.fetchType.identifier else {
      throw CancellationError()
    }
  }

  /// Serialization runs on the concurrent executor; SwiftData models are
  /// created only after returning to the main actor and checking ownership.
  @MainActor
  private func prepareCachedPosts(
    _ slices: [FeedSlice],
    publication: PublicationIdentity,
    smartFilterDecisions: [String: FeedFilterDecision] = [:]
  ) async throws -> [CachedFeedViewPost] {
    try checkPublication(publication)
    let prepared = try await prepareSlices(slices)
    try checkPublication(publication)
    let cachedPosts = prepared.map { preparedSlice in
      let cached = CachedFeedViewPost(prepared: preparedSlice, feedType: publication.feedKey)
      switch smartFilterDecisions[preparedSlice.slice.id] {
      case .collapsed(let ruleID):
        cached.smartFilterCollapseRuleID = ruleID.uuidString
      case .pending:
        cached.isSmartFilterPending = true
      default:
        break
      }
      return cached
    }
    let localFilters = appState.feedFilterSettings
    return filterCachedPosts(cachedPosts,
      settings: appState.makeFilterSettings(snapshot: retainedFilterPreferenceSnapshot(), localFilters: localFilters),
      hideDuplicateParents: localFilters.isFilterEnabled(name: "Hide Duplicate Posts"))
  }
  // Navigation state
  @MainActor var isReturningFromNavigation = false

  // Feed type tracking
  private(set) var lastFeedType: FetchType

  // MARK: - Initialization

  init(
    feedManager: FeedManager,
    appState: AppState,
    prepareSlices: @escaping @Sendable ([FeedSlice]) async throws -> [PreparedFeedSlice] = PreparedFeedSlice.prepare
  ) {
    self.prepareSlices = prepareSlices
    self.feedManager = feedManager
    self.appState = appState
    self.lastFeedType = feedManager.fetchType
    self.readingFilterSignature = ReadingLanguageFilterSignature(
      hideOtherLanguages: appState.appSettings.hideNonPreferredLanguages
        || appState.feedFilterSettings.isFilterEnabled(name: "Filter by Language"),
      preferredLanguages: appState.appSettings.contentLanguages)
    
    // Subscribe to state invalidation events
    appState.stateInvalidationBus.subscribe(self)
    
    // Subscribe to social graph changes (mute/block/follow changes)
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("UserGraphChanged"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        await self?.handleSocialGraphChange()
      }
    }
    
    // Settings edits use a separate scoped refresh; graph/intent behavior stays independent.
    for name in ["FeedPreferencesChanged", "FeedFiltersChanged", "LanguagePreferencesChanged", "AppSettingsChanged"] {
      let token = NotificationCenter.default.addObserver(
        forName: NSNotification.Name(name), object: nil, queue: .main
      ) { [weak self] notification in
        let originDID = notification.userInfo?["accountDID"] as? String
        let settingsIdentity = (notification.object as? AppSettings).map(ObjectIdentifier.init)
        MainActor.assumeIsolated {
          self?.handleSettingsPreferenceChange(originDID: originDID, settingsIdentity: settingsIdentity,
            isAppSettingsChange: name == "AppSettingsChanged")
        }
      }
      settingsObservers.append(token)
    }
    
    // Subscribe to intent rule changes
    NotificationCenter.default.addObserver(
      forName: .intentRulesDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        await self?.handleSocialGraphChange()
      }
    }

    // Subscribe to intent control feature flag changes
    NotificationCenter.default.addObserver(
      forName: .intentControlsFeatureFlagDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        await self?.handleSocialGraphChange()
      }
    }
  }
  
  deinit {
    // Unsubscribe from state invalidation events
    appState.stateInvalidationBus.unsubscribe(self)
    
    // Remove NotificationCenter observers
    settingsObservers.forEach(NotificationCenter.default.removeObserver)
    NotificationCenter.default.removeObserver(self)
  }
  // MARK: - Feed Generator Info
  
  /// Fetch feed generator information for custom feeds
  private func fetchFeedGeneratorInfo(for feedURI: ATProtocolURI) async -> AppBskyFeedDefs.GeneratorView? {
    guard let client = appState.atProtoClient else {
      logger.warning("No AT Proto client available - cannot fetch feed generator info")
      return nil
    }
    
    // Retry logic for fetching generator info
    for attempt in 1...3 {
      do {
        let result = try await client.app.bsky.feed.getFeedGenerator(input: .init(feed: feedURI))
        
        if result.responseCode == 200, let data = result.data {
          logger.debug("Fetched feed generator info for \(feedURI.uriString()): \(data.view.displayName ?? "Unknown")")
          return data.view
        } else {
          logger.warning("Failed to fetch feed generator info (attempt \(attempt)): HTTP \(result.responseCode)")
        }
      } catch {
        logger.error("Error fetching feed generator info for \(feedURI.uriString()) (attempt \(attempt)): \(error.localizedDescription)")
      }
      
      // Wait before retrying
      if attempt < 3 {
        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
      }
    }
    
    return nil
  }
  
  // MARK: - Data Restoration
  
  @MainActor
  func restorePersistedPosts(_ posts: [CachedFeedViewPost], cursor: String?) async {
    guard self.posts.isEmpty else {
      logger.debug("Posts already loaded, skipping restoration")
      return
    }
    
    // Filter out posts that can't be decoded (malformed cached data)
    var validPosts: [CachedFeedViewPost] = []
    var invalidPostIds: [String] = []
    
    for post in posts {
      if (try? post.feedViewPost) != nil {
        validPosts.append(post)
      } else {
        invalidPostIds.append(post.id)
        logger.warning("Cached post \(post.id) cannot be decoded - will be removed from cache")
      }
    }
    
    // If we found invalid posts, remove them from the cache
    if !invalidPostIds.isEmpty {
      logger.info("Removing \(invalidPostIds.count) invalid cached posts")
      Task.detached { [invalidPostIds] in
        await PersistentFeedStateManager.shared.removeInvalidPosts(withIds: invalidPostIds)
      }
    }
    
    self.posts = validPosts
    self.isLoading = false
    // Preserve pagination state if we have a stored cursor; allow pagination fallback when nil
    self.hasMore = cursor != nil || !validPosts.isEmpty
    self.cursor = cursor
    
    logger.debug("Restored \(validPosts.count) persisted posts to FeedModel (\(invalidPostIds.count) invalid posts filtered out)")

    // Refresh shadows for restored posts
    let feedViewPosts = validPosts.compactMap { try? $0.feedViewPost }
    await refreshPostShadows(feedViewPosts, authoritative: false)
  }
  
  /// Applies pre-warmed feed data from account switching for smooth transition
  @MainActor
  private func applyPrewarmedData(
    _ prewarmData: [AppBskyFeedDefs.FeedViewPost], publication: PublicationIdentity
  ) async {
    let filterSettings = await getFilterSettings()
    let tunedPosts = await feedTuner.tune(prewarmData, filterSettings: filterSettings)
    guard let cachedPosts = try? await prepareCachedPosts(tunedPosts, publication: publication) else { return }

    self.posts = cachedPosts
    self.cursor = nil  // Will be set on next loadMore
    self.isLoading = false
    self.isLoadingMore = false
    self.hasMore = true
    self.lastRefreshTime = Date()
    
    // Refresh post shadows for pre-warmed data
    await refreshPostShadows(prewarmData, authoritative: false)
    guard (try? checkPublication(publication)) != nil else { return }

    logger.info("Applied \(cachedPosts.count) pre-warmed posts to feed from \(prewarmData.count) raw posts")
    
    // If aggressive filtering left us with too few posts, do a normal fetch
    let minPostsThreshold = 10
    if cachedPosts.count < minPostsThreshold {
      logger.warning("Only \(cachedPosts.count) posts after filtering prewarmed data - fetching more")
      
      // Clear prewarmed posts and do a normal fetch
      self.posts = []
      self.isLoading = true
      
      do {
        let (fetchedPosts, newCursor) = try await feedManager.fetchFeed(fetchType: lastFeedType, cursor: nil)
        try checkPublication(publication)

        await appState.storePrefetchedFeed(fetchedPosts, cursor: newCursor, for: lastFeedType)
        
        // Process with FeedTuner
        let slices = await feedTuner.tune(fetchedPosts, filterSettings: filterSettings)
        let newPosts = try await prepareCachedPosts(slices, publication: publication)
        
        self.posts = newPosts
        self.cursor = newCursor
        self.isLoading = false
        self.hasMore = newCursor != nil
        self.lastRefreshTime = Date()
        
        await refreshPostShadows(fetchedPosts)
        
        logger.info("Fetched \(newPosts.count) additional posts after insufficient prewarmed data")
      } catch {
        guard (try? checkPublication(publication)) != nil else { return }
        logger.error("Failed to fetch additional posts after prewarming: \(error)")
        self.isLoading = false
        // Keep the prewarmed posts we had rather than showing nothing
        self.posts = cachedPosts
      }
    }
  }

  // MARK: - Feed Loading

  @MainActor
  func loadFeed(
    fetch: FetchType,
    forceRefresh: Bool = true,
    strategy: FeedLoadStrategy = .fullRefresh
  ) async {
    guard !Task.isCancelled else { return }
    if lastFeedType != fetch { beginFeedGeneration() }
    self.lastFeedType = fetch
    feedManager.updateFetchType(fetch)
    let requestedFeedKey = cacheKey(for: fetch.identifier)
    let requestedGeneration = publicationGeneration
    
    // Check for pre-warmed data from account switch
    if case .timeline = fetch, let prewarmData = appState.prewarmingFeedData, forceRefresh {
      logger.info("Using pre-warmed feed data for smooth account transition")
      beginFeedGeneration()
      let publication = publicationIdentity(for: fetch)
      defer {
        if publication.generation == publicationGeneration { isLoading = false }
      }
      await applyPrewarmedData(prewarmData, publication: publication)
      guard (try? checkPublication(publication)) != nil else { return }
      appState.prewarmingFeedData = nil  // Clear after use
      return
    }
    
    // Resolve whether a custom feed's generator accepts feedback. A fresh cached
    // answer applies immediately; otherwise it stays unknown until the network answers.
    if case .feed(let generatorUri) = fetch {
      let feedURI = generatorUri.uriString()
      if let cached = appState.feedGeneratorInfoCache.info(for: feedURI) {
        if generatorInteractionInfo != cached {
          generatorInteractionInfo = cached
        }
      } else {
        let generatorInfo = await fetchFeedGeneratorInfo(for: generatorUri)
        guard !Task.isCancelled, requestedGeneration == publicationGeneration,
              requestedFeedKey == cacheKey(for: fetch.identifier),
              lastFeedType == fetch, feedManager.fetchType == fetch else { return }
        if let generatorInfo {
          generatorInteractionInfo = appState.feedGeneratorInfoCache.store(generatorInfo, forFeedURI: feedURI)
        } else if generatorInteractionInfo?.feedURI != feedURI {
          logger.warning("No feed generator info for \(feedURI); feedback stays off")
          generatorInteractionInfo = nil
        }
      }
    } else if generatorInteractionInfo != nil {
      generatorInteractionInfo = nil
    }

    if isLoading || (strategy == .loadIfNeeded && !posts.isEmpty) {
      return
    }

    guard requestedGeneration == publicationGeneration,
          requestedFeedKey == cacheKey(for: fetch.identifier),
          lastFeedType == fetch, feedManager.fetchType == fetch else { return }
    beginFeedGeneration()
    let publication = publicationIdentity(for: fetch)
    defer {
      if publication.generation == publicationGeneration {
        if strategy == .backgroundRefresh {
          isBackgroundRefreshing = false
        } else {
          isLoading = false
        }
      }
    }

    if strategy == .backgroundRefresh {
      isBackgroundRefreshing = true
    } else {
      isLoading = true
    }

    error = nil

    guard appState.atProtoClient != nil else {
      logger.warning("🔥 FEED MODEL: No AT Proto client available - cannot load feed data for \(fetch.identifier)")
      if strategy == .backgroundRefresh {
        isBackgroundRefreshing = false
      } else {
        isLoading = false
      }
      return
    }

    do {
      let (fetchedPosts, newCursor) = try await feedManager.fetchFeed(fetchType: fetch, cursor: nil)
      try checkPublication(publication)

      await appState.storePrefetchedFeed(fetchedPosts, cursor: newCursor, for: fetch)

      // Process posts using FeedTuner (following React Native pattern)
      logger.debug("🔍 About to call feedTuner.tune() with \(fetchedPosts.count) posts")
      let filterSettings = await getFilterSettings()
      let slices = await feedTuner.tune(fetchedPosts, filterSettings: filterSettings)
      logger.debug("🔍 FeedTuner returned \(slices.count) slices")
      let newPosts = try await prepareCachedPosts(slices, publication: publication)

      self.cursor = newCursor
      self.hasMore = newCursor != nil
      self.lastRefreshTime = Date()

      if strategy == .backgroundRefresh && !posts.isEmpty {
        let existingIds = Set(posts.map { $0.id })
        let newIds = Set(newPosts.map { $0.id })
        let uniqueNewPostCount = newIds.subtracting(existingIds).count

        if uniqueNewPostCount > posts.count / 10 || forceRefresh {
          self.posts = newPosts
          // Persist feed data for caching using account-scoped key
          await PersistentFeedStateManager.shared.saveFeedData(
            self.posts,
            for: publication.feedKey,
            cursor: newCursor
          )
        }
      } else {
        self.posts = newPosts
        // Persist feed data for caching
        await PersistentFeedStateManager.shared.saveFeedData(
          self.posts,
          for: publication.feedKey,
          cursor: newCursor
        )
      }

      try checkPublication(publication)
      logger.debug("🔍 loadFeed completed - loaded \(self.posts.count) posts, cursor: \(newCursor ?? "nil"), hasMore: \(self.hasMore)")

      await refreshPostShadows(fetchedPosts)
      
      // Update widget data
      try checkPublication(publication)
      FeedWidgetDataProvider.shared.updateWidgetData(from: newPosts, feedType: fetch)
    } catch {
      // Use standardized error handling
      error.logError(context: "Feed load for \(fetch.identifier)", operation: "loadFeed")
      
      // Only show errors to user if they're not cancellations
      if publication.generation == publicationGeneration && error.shouldShowToUser {
        self.error = error
      }
    }

  }

  @MainActor
  func setCachedFeed(_ cachedPosts: [AppBskyFeedDefs.FeedViewPost], cursor: String?) async {
    guard !Task.isCancelled else { return }
    beginFeedGeneration()
    let publication = publicationIdentity(for: lastFeedType)
    let filterSettings = await getFilterSettings()
    let slices = await feedTuner.tune(cachedPosts, filterSettings: filterSettings)
    guard let prepared = try? await prepareCachedPosts(slices, publication: publication) else { return }
    self.posts = prepared
    self.cursor = cursor
    self.hasMore = cursor != nil
    FeedWidgetDataProvider.shared.updateWidgetData(from: self.posts, feedType: lastFeedType)
  }

  @MainActor
  func loadMore() async {
    guard !Task.isCancelled else { return }
    guard !isLoading && !isLoadingMore && hasMore else {
        logger.debug("🔍 loadMore skipped - isLoading: \(self.isLoading), isLoadingMore: \(self.isLoadingMore), hasMore: \(self.hasMore), cursor: \(self.cursor ?? "nil")")
      return
    }

    let publication = publicationIdentity(for: feedManager.fetchType)
    defer {
      if publication.generation == publicationGeneration { isLoadingMore = false }
    }
    isLoadingMore = true
    loadMoreError = nil
      logger.debug("🔍 Starting loadMore with cursor: \(self.cursor ?? "nil")")

    guard appState.atProtoClient != nil else {
      logger.warning("🔥 No AT Proto client available for loadMore")
      isLoadingMore = false
      return
    }

    let fetchType = feedManager.fetchType

    do {
      let (fetchedPosts, newCursor) = try await feedManager.fetchFeed(
        fetchType: fetchType,
        cursor: cursor
      )

      // Process new posts using FeedTuner
      let filterSettings = await getFilterSettings()
      let newSlices = await feedTuner.tune(fetchedPosts, filterSettings: filterSettings)
      let newCachedPosts = try await prepareCachedPosts(newSlices, publication: publication)
      let existingIds = Set(posts.map { $0.id })
      let uniqueNewPosts = newCachedPosts.filter { !existingIds.contains($0.id) }

      self.posts.append(contentsOf: uniqueNewPosts)
      self.cursor = newCursor
      self.hasMore = newCursor != nil
      // Persist combined feed data for caching using account-scoped key
      await PersistentFeedStateManager.shared.saveFeedData(
        self.posts,
        for: publication.feedKey,
        cursor: newCursor
      )
      
      try checkPublication(publication)
      logger.debug("🔍 loadMore completed - added \(uniqueNewPosts.count) posts, newCursor: \(newCursor ?? "nil"), hasMore: \(self.hasMore)")

      await refreshPostShadows(fetchedPosts)
    } catch {
      // Use standardized error handling
      error.logError(context: "Load more for \(fetchType.identifier)", operation: "loadMore")
      
      // Only show errors to user if they're not cancellations
      if publication.generation == publicationGeneration && error.shouldShowToUser {
        self.error = error
        self.loadMoreError = error
      }
    }

  }

  func prefetchNextPage() async {
    let cursorValue = await MainActor.run { cursor }
    let shouldPrefetch = await MainActor.run { hasMore && !isLoadingMore && !isLoading }

    guard let cursor = cursorValue, shouldPrefetch else { return }

    let fetchType = feedManager.fetchType

    do {
      let (fetchedPosts, _) = try await feedManager.fetchFeed(
        fetchType: fetchType,
        cursor: cursor
      )
      await refreshPostShadows(fetchedPosts)
    } catch {
      // Ignore prefetch errors
    }
  }

  /// Refresh post shadows in parallel for better performance.
  ///
  /// - Parameter authoritative: Pass `true` only for pages just fetched from the
  ///   network. Restored or prewarmed pages may predate an interaction the shadow
  ///   already holds, so they must not be allowed to clear it.
  private func refreshPostShadows(_ posts: [AppBskyFeedDefs.FeedViewPost], authoritative: Bool = true) async {
    await SpotlightEntityDonator.shared.donate(posts: posts.map(\.post))

    // Use task group for parallel shadow updates
    await withTaskGroup(of: Void.self) { group in
      for post in posts {
        group.addTask {
          await self.appState.postShadowManager.updateShadow(forUri: post.post.uri.uriString()) { shadow in
            shadow.hydrateFromServer(
              likeUri: post.post.viewer?.like,
              repostUri: post.post.viewer?.repost,
              authoritative: authoritative
            )
          }
        }
      }
    }

    // Every fetched page funnels through this method regardless of load
    // path (initial load, load-more, prefetch, prewarm, restore), making it
    // the single seam to batch-warm blocked-author identity for this page's
    // threadgate-hidden reply parents/roots — mirrors the per-thread-page
    // prefetch in UIKitThreadView.processThreadData().
    prefetchBlockedAuthors(from: posts)
  }

  /// Collects blocked-author DIDs from `.appBskyFeedDefsBlockedPost` reply
  /// parents/roots in a fetched feed page and fires ONE hydrator prefetch,
  /// so blocked-reply tombstone cards can render handles/avatars without a
  /// per-card fetch stampede. Per-card hydration already coalesces within
  /// 100ms, so this is a purely additive optimization — safe to no-op.
  private func prefetchBlockedAuthors(from posts: [AppBskyFeedDefs.FeedViewPost]) {
    var blockedDids: [String] = []
    for post in posts {
      if case .appBskyFeedDefsBlockedPost(let blocked) = post.reply?.parent {
        blockedDids.append(blocked.author.did.didString())
      }
      if case .appBskyFeedDefsBlockedPost(let blocked) = post.reply?.root {
        blockedDids.append(blocked.author.did.didString())
      }
    }
    guard !blockedDids.isEmpty else { return }
    Task { await appState.blockedAuthorHydrator?.prefetch(dids: blockedDids) }
  }

  @MainActor
  func shouldRefreshFeed(minInterval: TimeInterval = 300) -> Bool {
    return Date().timeIntervalSince(lastRefreshTime) > minInterval
  }

  @MainActor
  func refreshIfNeeded(fetch: FetchType, minInterval: TimeInterval = 300) async -> Bool {
    if shouldRefreshFeed(minInterval: minInterval) {
      await loadFeed(
        fetch: fetch,
        forceRefresh: false,
        strategy: FeedLoadStrategy.backgroundRefresh
      )
      return true
    }
    return false
  }

  // MARK: - Public Loading State Management
  
  @MainActor
  func markAsNeedingInitialLoad() {
    isLoading = true
  }

  // MARK: - Helper Methods for MainActor properties

  @MainActor
  private func setLastFeedType(_ type: FetchType) {
    lastFeedType = type
  }

  @MainActor
  private func setIsLoading(_ value: Bool) {
    isLoading = value
  }

  @MainActor
  private func setIsLoadingMore(_ value: Bool) {
    isLoadingMore = value
  }

  @MainActor
  private func setIsBackgroundRefreshing(_ value: Bool) {
    isBackgroundRefreshing = value
  }

  @MainActor
  func currentCursor() -> String? {
    cursor
  }

  @MainActor
  private func setError(_ error: Error?) {
    self.error = error
  }

  @MainActor
  private func setCursor(_ cursor: String?) {
    self.cursor = cursor
  }

  @MainActor
  private func setHasMore(_ value: Bool) {
    hasMore = value
  }

  @MainActor
  private func setLastRefreshTime(_ time: Date) {
    lastRefreshTime = time
  }

  @MainActor
  private func appendPosts(_ newPosts: [CachedFeedViewPost]) {
    posts.append(contentsOf: newPosts)
  }

  @MainActor
  private func updatePosts(
    _ filteredPosts: [CachedFeedViewPost], strategy: FeedLoadStrategy, forceRefresh: Bool
  ) {
    if strategy == .backgroundRefresh && !posts.isEmpty {
      let existingIds = Set(posts.map { $0.id })
      let newIds = Set(filteredPosts.map { $0.id })
      let uniqueNewPostCount = newIds.subtracting(existingIds).count

      if uniqueNewPostCount > posts.count / 10 || forceRefresh {
        posts = filteredPosts
      }
    } else {
      posts = filteredPosts
    }
  }

  // MARK: - Feed Filtering Extensions

  // Helper function to deduplicate posts
  @MainActor
  private func deduplicatePosts(_ postsToFilter: [CachedFeedViewPost]) -> [CachedFeedViewPost] {
    // Set to collect all parent post URIs from replies
    var parentPostURIs = Set<String>()

    // First pass: collect all parent post URIs
    for cachedPost in postsToFilter {
      guard let feedViewPost = try? cachedPost.feedViewPost else { continue }

      if let reply = feedViewPost.reply {
        switch reply.parent {
        case .appBskyFeedDefsPostView(let parentView):
          parentPostURIs.insert(parentView.uri.uriString())
        default:
          break
        }
      }
    }

    // Second pass: filter out standalone posts that are also parents in replies
    return postsToFilter.filter { cachedPost in
      guard let post = try? cachedPost.feedViewPost else {
        return false
      }

      let postURI = post.post.uri.uriString()

      // If this post's URI is in the parent set AND it's not a reply itself, filter it out
      if parentPostURIs.contains(postURI) && post.reply == nil {
        return false
      }

      // Keep all other posts
      return true
    }
  }

  // Filter the current posts and return filtered posts, applying deduplication if active
  @MainActor
  func applyFilters(withSettings filterSettings: FeedFilterSettings) -> [CachedFeedViewPost] {
    let settings = appState.makeFilterSettings(snapshot: retainedFilterPreferenceSnapshot(), localFilters: filterSettings)
    return filterCachedPosts(posts, settings: settings,
      hideDuplicateParents: filterSettings.isFilterEnabled(name: "Hide Duplicate Posts"))
  }

  /// The same immutable predicate is used by ordinary and cached feed entries.
  @MainActor
  private func filterCachedPosts(_ candidates: [CachedFeedViewPost], settings: FeedTunerSettings,
                                hideDuplicateParents: Bool) -> [CachedFeedViewPost] {
    let visible = candidates.filter { cached in
      guard let post = try? cached.feedViewPost else { return false }
      return contentFilterService.shouldShowFeedViewPost(post, settings: settings)
    }
    return hideDuplicateParents ? deduplicatePosts(visible) : visible
  }

  // Process and filter posts when loading, applying deduplication if active
  @MainActor
  func processAndFilterPosts(
    fetchedPosts: [AppBskyFeedDefs.FeedViewPost],
    newCursor: String?,
    filterSettings: FeedFilterSettings,
    feedType: FetchType
  ) async throws -> [CachedFeedViewPost] {
    let publication = publicationIdentity(for: feedType)
    // First process posts using FeedTuner (following React Native pattern)
    logger.debug("🔍 processAndFilterPosts: About to call feedTuner.tune() with \(fetchedPosts.count) posts")
    let tunerSettings = await getFilterSettings()
    let slices = await feedTuner.tune(fetchedPosts, filterSettings: tunerSettings)
    logger.debug("🔍 processAndFilterPosts: FeedTuner returned \(slices.count) slices")

    // Smart Filters are intentionally scoped to Home in v0. Non-candidates pay
    // only the DID-index lookup; semantic misses remain visible while classified.
    let smartFilterDecisions: [String: FeedFilterDecision]
    if feedType == .timeline {
      smartFilterDecisions = await SmartFilterCoordinator.shared.decisions(
        for: slices,
        accountDID: appState.userDID
      )
    } else {
      smartFilterDecisions = [:]
    }
    let visibleSlices = slices.filter { slice in
      if case .hidden = smartFilterDecisions[slice.id] { return false }
      return true
    }
    
    let newCachedPosts = try await prepareCachedPosts(
      visibleSlices, publication: publication, smartFilterDecisions: smartFilterDecisions
    )

    let deduplicatedPosts = filterCachedPosts(newCachedPosts, settings: tunerSettings,
      hideDuplicateParents: filterSettings.isFilterEnabled(name: "Hide Duplicate Posts"))

    if feedType == .timeline {
      let result = await IntentControlCoordinator.shared.applyIntentControls(
        to: deduplicatedPosts,
        accountDID: appState.userDID
      )
      try checkPublication(publication)
      return result
    }
    return deduplicatedPosts
  }

  // Enhanced loadFeed method with filtering capabilities
  @MainActor
  func loadFeedWithFiltering(
    fetch: FetchType,
    forceRefresh: Bool = true,
    strategy: FeedLoadStrategy = .fullRefresh,
    filterSettings: FeedFilterSettings
  ) async {
    guard !Task.isCancelled else { return }
    // Update feed type
    if lastFeedType != fetch { beginFeedGeneration() }
    lastFeedType = fetch
    feedManager.updateFetchType(fetch)

    // Check if we should skip loading
    if isLoading || (strategy == .loadIfNeeded && !posts.isEmpty) {
      return
    }

    beginFeedGeneration()
    let publication = publicationIdentity(for: fetch)
    defer {
      if publication.generation == publicationGeneration {
        if strategy == .backgroundRefresh {
          isBackgroundRefreshing = false
        } else {
          isLoading = false
        }
      }
    }

    // Set loading state
    if strategy == .backgroundRefresh {
      isBackgroundRefreshing = true
    } else {
      isLoading = true
    }

    // Reset error state
    error = nil

    // Check for client availability
    guard appState.atProtoClient != nil else {
      logger.warning("🔥 FEED MODEL: No AT Proto client available - cannot load feed data for \(fetch.identifier)")
      if strategy == .backgroundRefresh {
        isBackgroundRefreshing = false
      } else {
        isLoading = false
      }
      return
    }

    do {
      // Fetch posts
      let (fetchedPosts, newCursor) = try await feedManager.fetchFeed(fetchType: fetch, cursor: nil)
      try checkPublication(publication)

      // Store in prefetch cache
        await appState.storePrefetchedFeed(fetchedPosts, cursor: newCursor, for: fetch)

      // Process and filter posts (this now includes deduplication logic)
      let filteredPosts = try await processAndFilterPosts(
        fetchedPosts: fetchedPosts,
        newCursor: newCursor,
        filterSettings: filterSettings,
        feedType: fetch
      )
      try checkPublication(publication)

      // Update posts list
      updatePosts(filteredPosts, strategy: strategy, forceRefresh: forceRefresh)

      // Update pagination state
      cursor = newCursor
      hasMore = newCursor != nil
      lastRefreshTime = Date()

      // Update shadows
      await refreshPostShadows(fetchedPosts)
    } catch {
      if publication.generation == publicationGeneration, !Task.isCancelled, !error.isCancellation {
        self.error = error
      }
    }

  }

  // Enhanced loadMore method with filtering capabilities
  @MainActor
  func loadMoreWithFiltering(filterSettings: FeedFilterSettings) async {
    guard !Task.isCancelled else { return }
    // Check if we can load more
    guard !isLoading && !isLoadingMore && hasMore && cursor != nil else {
      return
    }

    let publication = publicationIdentity(for: feedManager.fetchType)
    defer {
      if publication.generation == publicationGeneration { isLoadingMore = false }
    }
    // Set loading state
    isLoadingMore = true

    // Check for client availability
    guard appState.atProtoClient != nil else {
      isLoadingMore = false
      return
    }

    // Get current fetch type
    let fetchType = feedManager.fetchType

    do {
      // Get current cursor
      let currentCursor = cursor

      // Fetch more posts
      let (fetchedPosts, newCursor) = try await feedManager.fetchFeed(
        fetchType: fetchType,
        cursor: currentCursor
      )
      try checkPublication(publication)

      // Process and filter posts (this now includes deduplication logic)
      let filteredNewPosts = try await processAndFilterPosts(
        fetchedPosts: fetchedPosts,
        newCursor: newCursor,
        filterSettings: filterSettings,
        feedType: fetchType
      )
      try checkPublication(publication)

      // Filter out duplicates based on ID before appending
      let existingIds = Set(posts.map { $0.id })
      let uniqueNewPosts = filteredNewPosts.filter { !existingIds.contains($0.id) }

      // Append unique posts
      posts.append(contentsOf: uniqueNewPosts)

      // Update pagination state
      cursor = newCursor
      hasMore = newCursor != nil

      // Update shadows
      await refreshPostShadows(fetchedPosts)
    } catch {
      if publication.generation == publicationGeneration, !Task.isCancelled, !error.isCancellation {
        self.error = error
      }
    }

  }
  
  // MARK: - State Invalidation Handling
  
  /// Handle state invalidation events from the central event bus
  func handleStateInvalidation(_ event: StateInvalidationEvent) async {
      logger.debug("Handling state invalidation event: \(String(describing: event))")
    
    switch event {
    case .postCreated(let post):
      // Add new post optimistically to timeline feeds
      if lastFeedType == .timeline {
        await addPostOptimistically(post)
      }
      
    case .replyCreated(_, let parentUri):
      // For timeline feeds, we might want to show the reply
      if lastFeedType == .timeline {
        // Check if the parent post is visible in the current feed
        let parentVisible = await MainActor.run {
          posts.contains { cachedPost in
            guard let post = try? cachedPost.feedViewPost else { return false }
            return post.post.uri.uriString() == parentUri
          }
        }
        
        if parentVisible {
          // If parent is visible, refresh to show the reply in context
          await refreshFeedAfterEvent()
        }
        // Otherwise, ignore - the reply will appear when timeline refreshes naturally
      }
      
    case .accountSwitched:
      // Clear and reload feed when account is switched
      await clearAndReloadFeed()
      
    case .authenticationCompleted:
      // Authentication completed - reload feed if it's empty
        Task { @MainActor in

        if posts.isEmpty {
                await clearAndReloadFeed()
            }
      }
      
    case .feedUpdated(let fetchType):
      // Refresh if this is the same feed type
      if lastFeedType.identifier == fetchType.identifier {
        await refreshFeedAfterEvent()
      }
      
    case .profileUpdated:
      // Refresh if this is a profile feed
      if case .author = lastFeedType {
        await refreshFeedAfterEvent()
      }
      
    case .threadUpdated:
      // Thread updates don't typically affect feed views
      break
      
    case .chatMessageReceived, .notificationsUpdated:
      // These don't affect feed content
      break
      
    case .postLiked, .postUnliked, .postReposted, .postUnreposted:
      // These are handled by PostShadowManager, no feed refresh needed
      break
    case .feedListChanged:
      // Feed list changes don't affect individual feed content,
      // this is handled at the feeds management level
      break
    }
  }
  
  /// Refresh the feed in response to a state invalidation event
  @MainActor
  private func refreshFeedAfterEvent() async {
    // Only refresh if we're not already loading
    guard !isLoading && !isLoadingMore else {
      return
    }
    
    // Use background refresh to avoid disrupting the user if we have posts,
    // otherwise do a full refresh to populate empty feed
    let strategy: FeedLoadStrategy = posts.isEmpty ? .fullRefresh : .backgroundRefresh
    await loadFeed(fetch: lastFeedType, forceRefresh: true, strategy: strategy)
  }
  
  /// Clear the current feed and reload it completely
  @MainActor
  private func clearAndReloadFeed() async {
    beginFeedGeneration()
    // Clear current posts
    posts.removeAll()
    cursor = nil
    hasMore = true
    error = nil
    
    // Reload the feed
    await loadFeed(fetch: lastFeedType, forceRefresh: true, strategy: .fullRefresh)
  }
  
  /// Add a new post optimistically to the feed
  @MainActor
  private func addPostOptimistically(_ post: AppBskyFeedDefs.PostView) async {
    logger.info("Adding post optimistically to feed: \(post.uri.uriString())")
    
    // Create a FeedViewPost wrapper
    let feedViewPost = AppBskyFeedDefs.FeedViewPost(
      post: post,
      reply: nil,
      reason: nil,
      feedContext: nil,
      reqId: nil
    )
    
    // Create a cached post with temporary flag
    let feedKey = cacheKey(for: lastFeedType.identifier)
    guard let cachedPost = CachedFeedViewPost(from: feedViewPost, feedType: feedKey) else {
      logger.error("Failed to create cached post for optimistic insert")
      return
    }
    cachedPost.isTemporary = true

    // Insert at the beginning of the feed
    posts.insert(cachedPost, at: 0)
    
    // Update post shadow for the new post
    await appState.postShadowManager.updateShadow(forUri: post.uri.uriString()) { shadow in
      // Mark as created by current user
      shadow.isOptimistic = true
    }
    
    // Schedule a background refresh to get the real post data
    Task {
      try? await Task.sleep(for: .seconds(1))
      await refreshFeedAfterEvent()
    }
  }
  
  /// Handle social graph changes (mute/block/follow state changes)
  @MainActor
  func handleSocialGraphChange() async {
    logger.debug("Social graph changed, refiltering feed content")
    let publication = publicationIdentity(for: lastFeedType)
    let filterSettings = await getFilterSettings()

    while !Task.isCancelled {
      guard (try? checkPublication(publication)) != nil, !posts.isEmpty else { return }
      let revision = contentRevision
      let validFeedViewPosts = posts.compactMap { try? $0.feedViewPost }
      guard !validFeedViewPosts.isEmpty else { return }

      let tunedSlices = await feedTuner.tune(validFeedViewPosts, filterSettings: filterSettings)
      guard let reprocessedPosts = try? await prepareCachedPosts(tunedSlices, publication: publication) else { return }

      var finalReprocessed = reprocessedPosts
      if lastFeedType == .timeline {
        finalReprocessed = await IntentControlCoordinator.shared.applyIntentControls(
          to: reprocessedPosts,
          accountDID: appState.userDID
        )
      }
      guard (try? checkPublication(publication)) != nil else { return }
      // Pagination and optimistic insertions keep the generation. Retry from
      // the latest posts if either changed the content while filtering awaited.
      guard revision == contentRevision else { continue }

      let currentIds = posts.map { $0.id }
      let newIds = finalReprocessed.map { $0.id }
      let currentHidden = posts.map { $0.intentHiddenRuleText }
      let newHidden = finalReprocessed.map { $0.intentHiddenRuleText }
      if currentIds != newIds || currentHidden != newHidden {
        posts = finalReprocessed
        logger.debug("Feed content updated after social graph/intent change: \(currentIds.count) -> \(newIds.count) posts")
      }
      return
    }
  }

  // MARK: - Helper Methods

  @MainActor
  private func handleSettingsPreferenceChange(originDID: String?, settingsIdentity: ObjectIdentifier?,
                                              isAppSettingsChange: Bool) {
    let manager = AppStateManager.shared
    guard originDID == appState.userDID,
          manager.lifecycle.isAuthenticated, manager.lifecycle.appState === appState else { return }
    let signature = ReadingLanguageFilterSignature(
      hideOtherLanguages: appState.appSettings.hideNonPreferredLanguages
        || appState.feedFilterSettings.isFilterEnabled(name: "Filter by Language"),
      preferredLanguages: appState.appSettings.contentLanguages)
    if isAppSettingsChange {
      guard settingsIdentity == ObjectIdentifier(appState.appSettings), signature != readingFilterSignature else { return }
    }
    readingFilterSignature = signature
    let context = SettingsFeedRefreshContext(accountDID: appState.userDID,
      accountRevision: manager.settingsAccountContextRevision,
      clientIdentity: appState.atProtoClient.map(ObjectIdentifier.init))
    if settingsRefreshGate == nil { settingsRefreshGate = SettingsFeedRefreshGate() }
    settingsRefreshGate?.request(context: context, isCurrentContext: { [weak self] context in
      guard let self else { return false }
      let manager = AppStateManager.shared
      return manager.lifecycle.isAuthenticated && manager.lifecycle.appState === self.appState
        && manager.lifecycle.userDID == context.accountDID
        && manager.settingsAccountContextRevision == context.accountRevision
        && self.appState.atProtoClient.map(ObjectIdentifier.init) == context.clientIdentity
    }, isLoading: { [weak self] in
      guard let self else { return false }
      return self.isLoading || self.isLoadingMore || self.isBackgroundRefreshing
    }, prepare: { [weak self] isCurrent in
      guard let self else { return }
      _ = await self.getFilterSettings()
      guard isCurrent() else { return }
      let filtered = self.applyFilters(withSettings: self.appState.feedFilterSettings)
      if filtered.count != self.posts.count { self.posts = filtered }
    }, reload: { [weak self] in
      guard let self else { return }
      // The existing loader owns generations, pagination, caps and publication.
      await self.loadFeed(fetch: self.lastFeedType, forceRefresh: true, strategy: .fullRefresh)
    })
  }
  
  /// Failures retain confirmed account preferences and still honor local/graph filters.
  @MainActor
  private func getFilterSettings() async -> FeedTunerSettings {
    let accountDID = appState.userDID
    let clientIdentity = appState.atProtoClient.map(ObjectIdentifier.init)
    let accountRevision = AppStateManager.shared.settingsAccountContextRevision
    func isCurrentRead() -> Bool {
      !Task.isCancelled && appState.userDID == accountDID
        && appState.atProtoClient.map(ObjectIdentifier.init) == clientIdentity
        && AppStateManager.shared.settingsAccountContextRevision == accountRevision
    }
    _ = retainedFilterPreferenceSnapshot()
    do {
      if try appState.preferencesManager.confirmedFeedFilterPreferences() == nil {
        // A synthesized default empty row is not a confirmed empty mute policy.
        _ = try await appState.preferencesManager.refreshSettingsPreferences()
        guard isCurrentRead() else { return appState.makeFilterSettings(snapshot: confirmedFilterPreferences) }
        _ = retainedFilterPreferenceSnapshot()
      }
    } catch {
      logger.warning("Couldn’t read feed preferences; retaining confirmed account filters: \(error)")
    }
    return appState.makeFilterSettings(snapshot: confirmedFilterPreferences)
  }

  /// Read-only local authority lookup is also safe at synchronous publication seams.
  @MainActor
  private func retainedFilterPreferenceSnapshot() -> FeedPreferenceSnapshot? {
    let confirmed = (try? appState.preferencesManager.confirmedFeedFilterPreferences()).map(FeedPreferenceSnapshot.init)
    let retainedLocal = confirmed == nil
      ? (try? appState.preferencesManager.retainedLocalFeedFilterPreferences()).map(FeedPreferenceSnapshot.init) : nil
    confirmedFilterPreferences = FeedPreferenceSnapshotStore.shared.resolve(accountDID: appState.userDID,
      confirmed: confirmed, retainedLocal: retainedLocal)
    return confirmedFilterPreferences
  }

}
