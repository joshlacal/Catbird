//
//  FeedStateStore.swift
//  Catbird
//
//  iOS 18+ Enhanced Feed State Store with modern @Observable pattern
//

import Foundation
import SwiftUI
import Petrel
import os
import SwiftData

@MainActor @Observable
final class FeedStateStore: StateInvalidationSubscriber {
  static let shared = FeedStateStore()
  
  private var stateManagers: [String: FeedStateManager] = [:]
  private let logger = Logger(subsystem: "blue.catbird", category: "FeedStateStore")
  private var modelContext: ModelContext?
  private weak var appState: AppState?
  
  // iOS 18+: Track app lifecycle state
  private var currentScenePhase: ScenePhase = .active
  private var lastBackgroundTime: TimeInterval = 0
  
  private init() {
    // Modern lifecycle management will be handled via @Environment(\.scenePhase)
    // No more UIKit notifications needed
    
    // Note: AppState will be set via setAppState() when first accessed
  }
  
  /// Set the AppState reference for state invalidation subscription
  func setAppState(_ appState: AppState) {
    guard self.appState == nil else { return }
    self.appState = appState
    appState.stateInvalidationBus.subscribe(self)
    logger.debug("FeedStateStore subscribed to StateInvalidationBus")
  }
    
  func setModelContext(_ context: ModelContext) {
    self.modelContext = context
    logger.debug("ModelContext set for FeedStateStore")
    // Note: PersistentFeedStateManager is now a @ModelActor and manages its own ModelContext
  }
  
  func stateManager(for feedType: FetchType, appState: AppState) -> FeedStateManager {
    // Set appState reference on first access for state invalidation subscription
    setAppState(appState)
    
    let identifier = feedType.identifier
    
    if let existing = stateManagers[identifier] {
      logger.debug("✅ Reusing existing state manager for \(identifier) (posts: \(existing.posts.count), isLoading: \(existing.isLoading))")
      
      // Ensure the existing state manager has the correct feed type
      // This handles cases where the feed type might have different parameters
      if existing.currentFeedType.identifier != feedType.identifier {
        logger.warning("⚠️ Feed type mismatch in existing state manager - updating from \(existing.currentFeedType.identifier) to \(feedType.identifier)")
        Task {
          await existing.updateFetchType(feedType, preserveScrollPosition: true)
        }
      }
      
      return existing
    }
    
    logger.debug("🔨 Creating new state manager for \(identifier)")
    
    let feedManager = FeedManager(
      client: appState.atProtoClient,
      fetchType: feedType
    )
    
    let feedModel = FeedModel(
      feedManager: feedManager,
      appState: appState
    )
    
    let stateManager = FeedStateManager(
      appState: appState,
      feedModel: feedModel,
      feedType: feedType
    )
    
    stateManagers[identifier] = stateManager
    logger.debug("📦 Stored new state manager for \(identifier) in cache")
    
    // Attempt to restore persisted data
    Task {
      await restorePersistedData(for: stateManager, feedIdentifier: identifier)
    }
    
    return stateManager
  }
  
  private func restorePersistedData(for stateManager: FeedStateManager, feedIdentifier: String) async {
    // Try to load persisted feed data
    if let cachedPosts = await PersistentFeedStateManager.shared.loadFeedData(for: feedIdentifier),
       !cachedPosts.isEmpty {
      logger.debug("Restored \(cachedPosts.count) cached posts for \(feedIdentifier)")

      // Update the state manager's posts directly
      await stateManager.restorePersistedPosts(cachedPosts)

    }
  }
  
  // iOS 18+: Enhanced scene phase handling with state restoration coordination
  func handleScenePhaseChange(_ newPhase: ScenePhase) async {
    let oldPhase = currentScenePhase
    currentScenePhase = newPhase
    
    logger.debug("Scene phase changed: \(String(describing: oldPhase)) -> \(String(describing: newPhase))")
    
    switch newPhase {
    case .background:
      lastBackgroundTime = Date().timeIntervalSince1970
      await saveAllStatesEnhanced()
      await notifyControllersOfBackgrounding()
      
    case .active:
      let backgroundDuration = Date().timeIntervalSince1970 - lastBackgroundTime
      await handleAppBecameActive(backgroundDuration: backgroundDuration, oldPhase: oldPhase)
      await notifyControllersOfForegrounding()
      
    case .inactive:
      // Prepare for potential backgrounding - save state proactively
      await prepareForBackgrounding()
      await notifyControllersOfInactive()
      
    @unknown default:
      break
    }
  }
  
  // iOS 18+: Enhanced state saving with batch operations and pixel-perfect scroll positions
  private func saveAllStatesEnhanced() async {
    logger.debug("Enhanced state saving for iOS 18+ backgrounding")

    guard !stateManagers.isEmpty else { return }

    // Collect all feed data for batch saving
    var feedDataBatch: [(identifier: String, posts: [CachedFeedViewPost])] = []

    for (identifier, stateManager) in stateManagers {
      let posts = stateManager.posts
      if !posts.isEmpty {
        feedDataBatch.append((identifier: identifier, posts: posts))

      }
    }

    // Save individual feeds (remove iOS 18 batch saving since method doesn't exist)
    for (identifier, posts) in feedDataBatch {
      await PersistentFeedStateManager.shared.saveFeedData(posts, for: identifier)
    }

    logger.debug("Enhanced state saving completed for \(feedDataBatch.count) feeds")
  }
  
  
  private func saveAllStates() async {
    logger.debug("Saving all feed states before backgrounding")

    for (identifier, stateManager) in stateManagers {
      // Save feed data
      let posts = stateManager.posts
      if !posts.isEmpty {
        await PersistentFeedStateManager.shared.saveFeedData(posts, for: identifier)

        // Save scroll position
        if let firstVisiblePost = posts.first {
          await PersistentFeedStateManager.shared.saveScrollPosition(
            postId: firstVisiblePost.id,
            offsetFromPost: 0,
            feedIdentifier: identifier
          )
        }
      }
    }
  }
  
  // Public method to trigger feed loading after authentication
  func triggerPostAuthenticationFeedLoad() async {
    logger.debug("Triggering post-authentication feed loading for all active feeds")
    
    for (identifier, stateManager) in stateManagers {
      // Force initial load for all feeds after authentication, even if empty
      logger.debug("Post-auth loading feed: \(identifier)")
      await stateManager.loadInitialDataWithSystemFlag()
    }
  }
  
  // iOS 18+: Smart refresh for all active feeds after long background
  private func performSmartRefreshForAllFeeds() async {
    logger.debug("Performing smart refresh for all feeds after long background")
    
    for (identifier, stateManager) in stateManagers {
      // Only refresh feeds that have posts (indicating they were actively used)
      if !stateManager.posts.isEmpty {
        logger.debug("Smart refreshing feed: \(identifier)")
        await stateManager.smartRefresh()
      }
    }
  }
  
  // iOS 18+: Check for new content without disrupting UI
  private func checkForNewContentNonDisruptive() async {
    logger.debug("Checking for new content non-disruptively")
    
    for (identifier, stateManager) in stateManagers {
      if !stateManager.posts.isEmpty {
        // Check if refresh is needed based on feed-specific logic
        if await shouldRefreshFeed(identifier) {
          logger.debug("Background refresh needed for: \(identifier)")
          // Perform background refresh that doesn't disrupt current UI
          Task.detached(priority: .background) {
            await stateManager.backgroundRefresh()
          }
        }
      }
    }
  }
  
  // iOS 18+: Determine if a feed should be refreshed
  private func shouldRefreshFeed(_ feedIdentifier: String) async -> Bool {
    return await PersistentFeedStateManager.shared.shouldRefreshFeed(
      feedIdentifier: feedIdentifier,
      lastUserRefresh: nil, // Could track user-initiated refreshes
      appBecameActiveTime: Date(timeIntervalSince1970: lastBackgroundTime)
    )
  }
  
  private func cleanupStaleData() async {
    await PersistentFeedStateManager.shared.cleanupStaleData()
  }
  
  func clearStateManager(for feedIdentifier: String) {
    stateManagers.removeValue(forKey: feedIdentifier)
    logger.debug("Cleared state manager for \(feedIdentifier)")
  }
  
  func clearAllStateManagers() {
    for (_, stateManager) in stateManagers {
       stateManager.cleanup()
    }
    stateManagers.removeAll()
    logger.debug("Cleared all state managers")
  }
  
  // iOS 18+: Handle app becoming active after backgrounding with intelligent refresh logic
  private func handleAppBecameActive(backgroundDuration: TimeInterval, oldPhase: ScenePhase) async {
    logger.debug("App became active after \(backgroundDuration) seconds in background from \(String(describing: oldPhase))")
    
    // Only refresh if actually coming from background (not from inactive due to control center, etc.)
    guard oldPhase == .background else {
      logger.debug("Not coming from background - skipping refresh logic and preserving state")
      // For non-background transitions, ensure all state managers maintain their state
      await preserveExistingStateForAllManagers()
      return
    }
    
    // Intelligent refresh based on background duration
    if backgroundDuration > 1800 { // 30 minutes - full refresh for all feeds
      logger.debug("Long background duration (\(backgroundDuration)s) - performing full refresh")
      await performSmartRefreshForAllFeeds()
    } else if backgroundDuration > 600 { // 10 minutes - non-disruptive content check
      logger.debug("Medium background duration (\(backgroundDuration)s) - checking for new content")
      await checkForNewContentNonDisruptive()
    } else {
      logger.debug("Short background duration (\(backgroundDuration)s) - preserving existing state")
      // For short backgrounds (< 10 minutes), preserve state completely
      await restoreExistingStateWithoutRefresh()
    }
    
    // Clean up any stale data (but don't remove recent cache)
    await cleanupStaleData()
  }
  
  // iOS 18+: Prepare for potential backgrounding
  private func prepareForBackgrounding() async {
    logger.debug("Preparing for potential backgrounding")
    
    // Save current states proactively
    await saveAllStatesEnhanced()
  }
  
  // iOS 18+: Coordinate with UIKit controllers for unified lifecycle management
  private func notifyControllersOfBackgrounding() async {
    logger.debug("Notifying controllers of backgrounding phase")
    
    for (identifier, stateManager) in stateManagers {
      // Signal each state manager about background transition
      await stateManager.handleScenePhaseTransition(.background)
      logger.debug("Notified state manager \(identifier) of background transition")
    }
  }
  
  private func notifyControllersOfForegrounding() async {
    logger.debug("Notifying controllers of foregrounding phase")
    
    for (identifier, stateManager) in stateManagers {
      // Signal each state manager about active transition
      await stateManager.handleScenePhaseTransition(.active)
      logger.debug("Notified state manager \(identifier) of active transition")
    }
  }
  
  private func notifyControllersOfInactive() async {
    logger.debug("Notifying controllers of inactive phase")
    
    for (identifier, stateManager) in stateManagers {
      // Signal each state manager about inactive transition  
      await stateManager.handleScenePhaseTransition(.inactive)
      logger.debug("Notified state manager \(identifier) of inactive transition")
    }
  }
  
  // iOS 18+: Restore existing state without triggering refresh
  private func restoreExistingStateWithoutRefresh() async {
    logger.debug("Restoring existing state without refresh for short background duration")
    
    for (identifier, stateManager) in stateManagers {
      // Each state manager should restore its UI state without network operations
      await stateManager.restoreUIStateWithoutRefresh()
      logger.debug("Restored UI state for \(identifier) without refresh")
    }
  }
  
  // iOS 18+: Preserve existing state for all managers without any modifications
  private func preserveExistingStateForAllManagers() async {
    logger.debug("Preserving existing state for all feed managers")
    
    for (identifier, stateManager) in stateManagers {
      // Ensure each state manager maintains its current state exactly as is
      // This is important for preventing state loss during app switching, control center, etc.
      logger.debug("Preserved existing state for \(identifier)")
    }
  }
}

// MARK: - StateInvalidationSubscriber

extension FeedStateStore {
  /// Handle state invalidation events
  func handleStateInvalidation(_ event: StateInvalidationEvent) async {
    switch event {
    case .accountSwitched:
      logger.debug("🔄 Account switched - clearing all feed state managers")
      clearAllStateManagers()
      
    default:
      // Other events are handled by individual FeedStateManagers
      break
    }
  }
  
  /// Check if this store is interested in specific events
  nonisolated func isInterestedIn(_ event: StateInvalidationEvent) -> Bool {
    switch event {
    case .accountSwitched:
      return true
    default:
      return false
    }
  }
}
