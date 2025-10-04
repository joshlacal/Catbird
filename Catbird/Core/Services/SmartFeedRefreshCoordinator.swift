import Foundation
import OSLog
import SwiftUI
import SwiftData
import Petrel

// MARK: - Refresh Strategy

enum RefreshStrategy {
  case immediate          // User-initiated (pull-to-refresh)
  case background        // App became active after backgrounding
  case scheduled         // Periodic background refresh
  case cached           // Show cached data first
  case offline          // No network, cached only
}

enum RefreshPriority {
  case critical    // Account changes, auth completion
  case high       // User pull-to-refresh
  case medium     // App active after background
  case low        // Scheduled background refresh
  case none       // Use cached data
}

// MARK: - Smart Feed Refresh Coordinator

@Observable
final class SmartFeedRefreshCoordinator {
  private let logger = Logger(
    subsystem: "blue.catbird", 
    category: "SmartRefresh"
  )
  
  private let persistentManager = PersistentFeedStateManager.shared
  private let continuityManager = FeedContinuityManager()
  
  // SwiftData context
  private var modelContext: ModelContext?
  
  // State tracking
  private var lastAppBecameActive = Date()
  private var lastUserRefreshTime: [String: Date] = [:]
  private var backgroundRefreshTimers: [String: Timer] = [:]
  private var isOffline = false
  
  // Current refresh operations
  private var activeRefreshTasks: [String: Task<Void, Never>] = [:]
  
  init() {
    setupAppStateObservation()
    setupNetworkMonitoring()
  }
  
  func setModelContext(_ context: ModelContext) {
    self.modelContext = context
    // Note: PersistentFeedStateManager is now a @ModelActor and manages its own context
  }
  
  // MARK: - Public Interface
  
  /// Determine refresh strategy for a feed
  func getRefreshStrategy(
    for feedIdentifier: String,
    userInitiated: Bool = false,
    forced: Bool = false
  ) async -> RefreshStrategy {

    // Always refresh if forced (account switch, etc.)
    if forced {
      logger.debug("Forced refresh for \(feedIdentifier)")
      return .immediate
    }

    // User-initiated always takes priority
    if userInitiated {
      lastUserRefreshTime[feedIdentifier] = Date()
      logger.debug("User-initiated refresh for \(feedIdentifier)")
      return .immediate
    }

    // If offline, use cached data only
    if isOffline {
      logger.debug("Offline mode for \(feedIdentifier)")
      return .offline
    }

    // Check if we should refresh based on cached data age and app state
    let shouldRefresh = await persistentManager.shouldRefreshFeed(
      feedIdentifier: feedIdentifier,
      lastUserRefresh: lastUserRefreshTime[feedIdentifier],
      appBecameActiveTime: lastAppBecameActive
    )
    
    if shouldRefresh {
      let timeSinceActive = Date().timeIntervalSince(lastAppBecameActive)
      if timeSinceActive < 300 { // App recently became active (within 5 minutes)
        logger.debug("Background refresh for \(feedIdentifier) (app recently active)")
        return .background
      } else {
        logger.debug("Scheduled refresh for \(feedIdentifier)")
        return .scheduled
      }
    }
    
    logger.debug("Using cached data for \(feedIdentifier)")
    return .cached
  }
  
  /// Execute refresh with smart strategy
  func executeRefresh(
    for feedIdentifier: String,
    feedModel: FeedModel,
    fetchType: FetchType,
    appState: AppState,
    strategy: RefreshStrategy,
    onProgress: ((String) -> Void)? = nil,
    onComplete: @escaping ([CachedFeedViewPost]) -> Void,
    onError: ((Error) -> Void)? = nil
  ) {
    
    // Cancel any existing refresh for this feed
    activeRefreshTasks[feedIdentifier]?.cancel()
    
    activeRefreshTasks[feedIdentifier] = Task { @MainActor in
      await performRefreshOperation(
        feedIdentifier: feedIdentifier,
        feedModel: feedModel,
        fetchType: fetchType,
        appState: appState,
        strategy: strategy,
        onProgress: onProgress,
        onComplete: onComplete,
        onError: onError
      )
      
      activeRefreshTasks[feedIdentifier] = nil
    }
  }
  
  /// Load cached data immediately from SwiftData
  func loadCachedData(for feedIdentifier: String) async -> [CachedFeedViewPost]? {
    return await persistentManager.loadFeedData(for: feedIdentifier)
  }
  
  /// Check for new content in background
  func checkForNewContent(
    feedIdentifier: String,
    currentPosts: [CachedFeedViewPost],
    onNewContentFound: @escaping (Int) -> Void
  ) {
    continuityManager.checkForNewContent(
      currentPosts: currentPosts,
      feedIdentifier: feedIdentifier,
      onNewContentFound: onNewContentFound
    )
  }
  
  /// Cancel refresh for a feed
  func cancelRefresh(for feedIdentifier: String) {
    activeRefreshTasks[feedIdentifier]?.cancel()
    activeRefreshTasks[feedIdentifier] = nil
    backgroundRefreshTimers[feedIdentifier]?.invalidate()
    backgroundRefreshTimers[feedIdentifier] = nil
  }
  
  /// Schedule background refresh
  func scheduleBackgroundRefresh(
    for feedIdentifier: String,
    interval: TimeInterval = 300 // 5 minutes
  ) {
    backgroundRefreshTimers[feedIdentifier]?.invalidate()
    
    backgroundRefreshTimers[feedIdentifier] = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      self?.logger.debug("Background refresh timer fired for \(feedIdentifier)")
      
      // Only refresh if data is stale and app is active
      guard let self = self else { return }
      
      #if os(iOS)
      guard UIApplication.shared.applicationState == .active else { return }
      #elseif os(macOS)
      guard NSApplication.shared.isActive else { return }
      #endif
      
      // Check if we should refresh based on cached data staleness
      let shouldRefresh = self.persistentManager.shouldRefreshFeed(
        feedIdentifier: feedIdentifier,
        lastUserRefresh: self.lastUserRefreshTime[feedIdentifier],
        appBecameActiveTime: self.lastAppBecameActive
      )
      
      guard shouldRefresh else {
        return
      }
      
      // Trigger background refresh
      // This would be called by the feed view controller
    }
  }
  
  // MARK: - Private Implementation
  
  @MainActor
  private func performRefreshOperation(
    feedIdentifier: String,
    feedModel: FeedModel,
    fetchType: FetchType,
    appState: AppState,
    strategy: RefreshStrategy,
    onProgress: ((String) -> Void)?,
    onComplete: @escaping ([CachedFeedViewPost]) -> Void,
    onError: ((Error) -> Void)?
  ) async {
    
    logger.debug("Starting refresh for \(feedIdentifier) with strategy \(String(describing: strategy))")
    
    switch strategy {
    case .cached:
      // Load cached data only
      if let cachedPosts = await loadCachedData(for: feedIdentifier) {
        logger.debug("Loaded \(cachedPosts.count) cached posts for \(feedIdentifier)")
        onComplete(cachedPosts)
        continuityManager.updateContinuityInfo(for: feedIdentifier, posts: cachedPosts)
      } else {
        // No cached data, fall back to immediate refresh
        await performNetworkRefresh(
          feedIdentifier: feedIdentifier,
          feedModel: feedModel,
          fetchType: fetchType,
          appState: appState,
          strategy: .immediate,
          onProgress: onProgress,
          onComplete: onComplete,
          onError: onError
        )
      }
      
    case .offline:
      // Offline mode - cached only with banner
      if let cachedPosts = await loadCachedData(for: feedIdentifier) {
        logger.debug("Offline: Using \(cachedPosts.count) cached posts for \(feedIdentifier)")
        onComplete(cachedPosts)
        continuityManager.showCacheFallbackBanner()
      } else {
        onError?(SmartRefreshError.offline)
      }
      
    case .immediate, .background, .scheduled:
      await performNetworkRefresh(
        feedIdentifier: feedIdentifier,
        feedModel: feedModel,
        fetchType: fetchType,
        appState: appState,
        strategy: strategy,
        onProgress: onProgress,
        onComplete: onComplete,
        onError: onError
      )
    }
  }
  
  @MainActor
  private func performNetworkRefresh(
    feedIdentifier: String,
    feedModel: FeedModel,
    fetchType: FetchType,
    appState: AppState,
    strategy: RefreshStrategy,
    onProgress: ((String) -> Void)?,
    onComplete: @escaping ([CachedFeedViewPost]) -> Void,
    onError: ((Error) -> Void)?
  ) async {
    
    do {
      // Show appropriate loading state
      switch strategy {
      case .immediate:
        onProgress?("Refreshing...")
      case .background:
        onProgress?("Updating in background...")
        continuityManager.showLoadingGapBanner()
      case .scheduled:
        onProgress?("Checking for updates...")
      default:
        break
      }
      
      // Perform the actual network refresh
      await feedModel.loadFeedWithFiltering(
        fetch: fetchType,
        forceRefresh: true,
        strategy: .fullRefresh,
        filterSettings: appState.feedFilterSettings
      )
      
      // Get the updated posts
      let updatedPosts = feedModel.applyFilters(withSettings: appState.feedFilterSettings)

      // Save to persistent storage
      await persistentManager.saveFeedData(updatedPosts, for: feedIdentifier)
      
      // Update continuity info
      continuityManager.updateContinuityInfo(for: feedIdentifier, posts: updatedPosts, hasNewContent: true)
      
      // Hide loading indicators
      continuityManager.hideBanner()
      
      logger.debug("Network refresh completed for \(feedIdentifier): \(updatedPosts.count) posts")
      onComplete(updatedPosts)
      
    } catch {
      logger.error("Network refresh failed for \(feedIdentifier): \(error)")

      // Fall back to cached data if available
      if let cachedPosts = await loadCachedData(for: feedIdentifier) {
        logger.debug("Falling back to cached data for \(feedIdentifier)")
        onComplete(cachedPosts)
        continuityManager.showCacheFallbackBanner()
      } else {
        onError?(error)
      }
    }
  }
  
  // MARK: - App State Observation
  
  private func setupAppStateObservation() {
    #if os(iOS)
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.handleAppBecameActive()
    }
    
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.handleAppEnteredBackground()
    }
    #elseif os(macOS)
    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.handleAppBecameActive()
    }
    
    NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.handleAppEnteredBackground()
    }
    #endif
  }
  
  private func setupNetworkMonitoring() {
    // This would integrate with NetworkMonitor
    // For now, we'll use a simple reachability check
    Task {
      await monitorNetworkStatus()
    }
  }
  
  private func handleAppBecameActive() {
    lastAppBecameActive = Date()
    logger.debug("App became active")

    // Clean up stale data
    Task {
      await persistentManager.cleanupStaleData()
    }

    // Check network status
    Task {
      await updateNetworkStatus()
    }
  }
  
  private func handleAppEnteredBackground() {
    logger.debug("App entered background")
    
    // Cancel all active refreshes
    for (feedId, task) in activeRefreshTasks {
      task.cancel()
      logger.debug("Cancelled refresh task for \(feedId)")
    }
    activeRefreshTasks.removeAll()
  }
  
  @MainActor
  private func monitorNetworkStatus() async {
    // Simple network monitoring
    // In a real implementation, this would use Network framework
    while !Task.isCancelled {
      await updateNetworkStatus()
      try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
    }
  }
  
  @MainActor
  private func updateNetworkStatus() async {
    let wasOffline = isOffline
    // Simple connectivity check
    isOffline = false // This would be replaced with actual network checking
    
    if wasOffline && !isOffline {
      logger.debug("Network connection restored")
      continuityManager.showConnectionRestoredBanner()
    }
  }
  
  deinit {
    // Cancel all timers and tasks
    for timer in backgroundRefreshTimers.values {
      timer.invalidate()
    }
    
    for task in activeRefreshTasks.values {
      task.cancel()
    }
    
    NotificationCenter.default.removeObserver(self)
  }
}

// MARK: - Smart Refresh Error

enum SmartRefreshError: Error, LocalizedError {
  case offline
  case timeout
  case serverError
  
  var errorDescription: String? {
    switch self {
    case .offline:
      return "No internet connection"
    case .timeout:
      return "Request timed out"
    case .serverError:
      return "Server error"
    }
  }
}
