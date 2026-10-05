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
  
  // Scene roots register independently; data managers remain account/feed scoped.
  private var sceneLifecycle = FeedSceneLifecycle()
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

    // CRITICAL: Cache key must include account identity to prevent cross-account contamination
    let accountID = appState.userDID ?? "unknown-account"
    let cacheKey = "\(accountID)-\(feedType.identifier)"

    if let existing = stateManagers[cacheKey] {
      // CRITICAL: Validate cached manager belongs to the correct account
      // Without this check, we could return Account B's manager when switching back to Account A
      if existing.appState === appState {
        logger.debug("✅ Reusing existing state manager for \(cacheKey) (posts: \(existing.posts.count), isLoading: \(existing.isLoading))")

        // Ensure the existing state manager has the correct feed type
        // This handles cases where the feed type might have different parameters
        if existing.currentFeedType.identifier != feedType.identifier {
          logger.warning("⚠️ Feed type mismatch in existing state manager - updating from \(existing.currentFeedType.identifier) to \(feedType.identifier)")
          Task {
            await existing.updateFetchType(feedType)
          }
        }

        makeActive(existing)
        return existing
      } else {
        // AppState mismatch - this is a stale cached manager from a different account
        logger.warning("⚠️ Cached manager for \(cacheKey) has stale AppState reference - removing and creating new")
        existing.cleanup()
        stateManagers.removeValue(forKey: cacheKey)
      }
    }

    logger.debug("🔨 Creating new state manager for \(cacheKey)")

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
      feedType: feedType,
      initialScenePhase: sceneLifecycle.phase
    )

    stateManagers[cacheKey] = stateManager
    makeActive(stateManager)
    logger.debug("📦 Stored new state manager for \(cacheKey) in cache")

    // Attempt to restore persisted data
    Task {
      await restorePersistedData(for: stateManager, feedIdentifier: cacheKey)
    }

    return stateManager
  }
  
  /// Feeds the user has moved away from keep their posts for a quick return but
  /// stop auto-refreshing, so only the feed on screen polls the network.
  private func makeActive(_ active: FeedStateManager) {
    for manager in stateManagers.values {
      manager.setAutomaticRefreshEligible(manager === active)
    }
  }

  private func restorePersistedData(for stateManager: FeedStateManager, feedIdentifier: String) async {
    // Try to load persisted feed data
    if let bundle = await PersistentFeedStateManager.shared.loadFeedBundle(for: feedIdentifier),
       !bundle.posts.isEmpty {
      logger.debug("Restored \(bundle.posts.count) cached posts for \(feedIdentifier)")

      // Update the state manager's posts directly
      await stateManager.restorePersistedPosts(bundle.posts, cursor: bundle.cursor)

    }
  }
  
  /// Register once per scene-root lifetime. Repeated registration is idempotent.
  func registerScene(_ sceneID: UUID, phase: ScenePhase) async {
    guard let transition = sceneLifecycle.register(sceneID, phase: phase) else { return }
    await applySceneTransition(transition)
  }

  /// A feed view may forward phase changes, but it does not own scene teardown.
  func updateScenePhase(_ phase: ScenePhase, for sceneID: UUID) async {
    guard let transition = sceneLifecycle.update(phase, for: sceneID) else { return }
    await applySceneTransition(transition)
  }

  /// Called when the owning scene disconnects or replaces its account context.
  func unregisterScene(_ sceneID: UUID) async {
    guard let transition = sceneLifecycle.unregister(sceneID) else { return }
    await applySceneTransition(transition)
  }

  private func applySceneTransition(_ transition: FeedSceneLifecycle.Transition) async {
    logger.debug("Aggregate feed scene phase: \(String(describing: transition.previousPhase)) -> \(String(describing: transition.phase)), scenes: \(self.sceneLifecycle.phases.count)")
    if transition.phase == .background { lastBackgroundTime = Date().timeIntervalSince1970 }
    var resumedManagers: Set<ObjectIdentifier> = []
    await FeedSceneLifecycleEffects.apply(
      transition,
      isCurrent: { self.sceneLifecycle.isCurrent(transition) },
      save: { await self.saveAllStatesEnhanced(transition: transition) },
      notify: { phase in
        resumedManagers = await self.notifyManagers(of: phase, transition: transition)
        return !resumedManagers.isEmpty
      },
      resume: { duration in
        await self.handleAppBecameActive(
          backgroundDuration: duration, transition: transition, resumedManagers: resumedManagers
        )
      }
    )
  }

  // iOS 18+: Enhanced state saving with batch operations and pixel-perfect scroll positions
  private func saveAllStatesEnhanced(transition: FeedSceneLifecycle.Transition) async {
    logger.debug("Enhanced state saving for iOS 18+ backgrounding")

    guard sceneLifecycle.isCurrent(transition), !stateManagers.isEmpty else { return }

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
      guard sceneLifecycle.isCurrent(transition) else { return }
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
  private func performSmartRefreshForAllFeeds(
    transition: FeedSceneLifecycle.Transition, resumedManagers: Set<ObjectIdentifier>
  ) async {
    logger.debug("Performing smart refresh for all feeds after long background")
    
    for (identifier, stateManager) in stateManagers {
      guard sceneLifecycle.isCurrent(transition) else { return }
      guard resumedManagers.contains(ObjectIdentifier(stateManager)) else { continue }
      // Only refresh feeds that have posts (indicating they were actively used)
      if !stateManager.posts.isEmpty {
        logger.debug("Smart refreshing feed: \(identifier)")
        await stateManager.smartRefresh()
      }
    }
  }
  
  // iOS 18+: Check for new content without disrupting UI
  private func checkForNewContentNonDisruptive(
    transition: FeedSceneLifecycle.Transition, resumedManagers: Set<ObjectIdentifier>
  ) async {
    logger.debug("Checking for new content non-disruptively")
    
    for (identifier, stateManager) in stateManagers {
      guard sceneLifecycle.isCurrent(transition) else { return }
      guard resumedManagers.contains(ObjectIdentifier(stateManager)) else { continue }
      if !stateManager.posts.isEmpty {
        // Check if refresh is needed based on feed-specific logic
        if await shouldRefreshFeed(identifier) {
          logger.debug("Background refresh needed for: \(identifier)")
          // Perform background refresh that doesn't disrupt current UI
          guard sceneLifecycle.isCurrent(transition) else { return }
          await stateManager.backgroundRefresh()
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
    // Clear managers for this feed type across all accounts
    // Cache keys are now in format "accountID-feedIdentifier"
    let keysToRemove = stateManagers.keys.filter { $0.hasSuffix("-\(feedIdentifier)") }
    for key in keysToRemove {
      stateManagers[key]?.cleanup()
      stateManagers.removeValue(forKey: key)
    }
    logger.debug("Cleared state manager(s) for \(feedIdentifier) (\(keysToRemove.count) instances)")
  }
  
  func clearAllStateManagers() {
    for (_, stateManager) in stateManagers {
       stateManager.cleanup()
    }
    stateManagers.removeAll()
    logger.debug("Cleared all state managers")
  }
  
  // Only managers actually suspended by the aggregate can need restoration.
  private func handleAppBecameActive(
    backgroundDuration: TimeInterval, transition: FeedSceneLifecycle.Transition,
    resumedManagers: Set<ObjectIdentifier>
  ) async {
    guard sceneLifecycle.isCurrent(transition), !resumedManagers.isEmpty else { return }
    if backgroundDuration > 1800 {
      await performSmartRefreshForAllFeeds(transition: transition, resumedManagers: resumedManagers)
    } else if backgroundDuration > 600 {
      await checkForNewContentNonDisruptive(transition: transition, resumedManagers: resumedManagers)
    }
    // A short background needs no store-driven loading-state reset. Each
    // manager restores only its own canceled work when it actually resumes.
    guard sceneLifecycle.isCurrent(transition) else { return }
    await cleanupStaleData()
  }

  private func notifyManagers(
    of phase: ScenePhase, transition: FeedSceneLifecycle.Transition
  ) async -> Set<ObjectIdentifier> {
    var resumedManagers: Set<ObjectIdentifier> = []
    guard sceneLifecycle.isCurrent(transition) else { return resumedManagers }
    for (identifier, stateManager) in stateManagers {
      guard sceneLifecycle.isCurrent(transition) else { return resumedManagers }
      if await stateManager.handleScenePhaseTransition(phase) {
        resumedManagers.insert(ObjectIdentifier(stateManager))
      }
      logger.debug("Notified state manager \(identifier) of aggregate \(String(describing: phase)) transition")
    }
    return resumedManagers
  }

}

// MARK: - StateInvalidationSubscriber

extension FeedStateStore {
  /// Handle state invalidation events
  func handleStateInvalidation(_ event: StateInvalidationEvent) async {
    switch event {
    case .accountSwitched:
      // CRITICAL FIX: Do NOT clear persistent cache on account switch.
      // Doing so wipes data for the account we just switched TO if it was previously cached,
      // and prevents the previous account's data from being available if we switch back.
      // Data is already namespaced by account DID in the cache keys/database.
      logger.debug("🔄 Account switched - preserving feed state for seamless transition")

    // We can optionally clear memory for accounts that are no longer active to save RAM,
    // but we should NOT wipe the persistent store.
    // For now, we keep managers in memory as AppState eviction handles the heavy lifting
    // of cleaning up unused AppState instances, which naturally releases their resources.
      
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
