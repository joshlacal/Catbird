//
//  FeedsStartPageViewModel.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/26/24.
//

import OSLog
import Observation
import Petrel
import SwiftData
import SwiftUI

@MainActor @Observable
final class FeedsStartPageViewModel {
  var feedGenerators: [ATProtocolURI: AppBskyFeedDefs.GeneratorView] = [:]
  var isLoading = false
  var errorMessage: String?

  // Cache for synchronous access
  private var _cachedPinnedFeeds: [String] = []
  private var _cachedSavedFeeds: [String] = []
  private var _cachedPinnedFeedsSet: Set<String> = Set()
  
  // List metadata cache
  var listDetails: [ATProtocolURI: AppBskyGraphDefs.ListView] = [:]

  // Synchronous accessors for cached data
  var cachedPinnedFeeds: [String] { _cachedPinnedFeeds }
  var cachedSavedFeeds: [String] { _cachedSavedFeeds }

  // Sync method to check if a feed is pinned
  func isPinnedSync(_ feedURI: String) -> Bool {
    return _cachedPinnedFeedsSet.contains(feedURI)
  }

  private var lastFetchTime: Date?
  private let fetchInterval: TimeInterval = 300  // 5 minutes
  private var didLogout = false  // Track if a logout occurred

  // Add tracking for loaded state to prevent double-initialization
  private var hasLoadedFeedsAtLeastOnce = false
  private var hasAttemptedPreferencesRepair = false

  private let maxGeneratorRetryAttempts = 4
  private let generatorRetryDelayBase: UInt64 = 500_000_000 // 0.5 seconds base delay

  // logger
  private let logger = Logger(subsystem: "blue.catbird", category: "FeedsStartPageViewModel")

  private var appState: AppState
  var modelContext: ModelContext?

  init(appState: AppState, modelContext: ModelContext? = nil) {
    self.appState = appState
    self.modelContext = modelContext

    // Setup observation of authentication state changes to detect logouts
    Task {
      for await state in AppStateManager.shared.authentication.stateChanges {
        if case .unauthenticated = state {
          // Mark that a logout occurred
          self.didLogout = true

          // Clear local feed data immediately on logout
          self.feedGenerators = [:]
          self.lastFetchTime = nil
          self._cachedPinnedFeeds = []
          self._cachedSavedFeeds = []
          self._cachedPinnedFeedsSet = Set()

          // Reset loaded state
          self.hasLoadedFeedsAtLeastOnce = false

          logger.info("User logged out - cleared local feed data")
        } else if case .authenticated = state {
          // Don't trigger an immediate refresh if we already have data
          // This prevents double-loading and race conditions
          if !self.hasLoadedFeedsAtLeastOnce {
            logger.info("First authentication detected - will load feeds when view is ready")
            // Don't do anything here - wait for the view to trigger initialization
          } else {
            logger.info("Auth state change detected but feeds already loaded - no action needed")
          }
        }
      }
    }
  }

  @MainActor
  func initializeWithModelContext(_ modelContext: ModelContext) async {
    // Set model context
    self.modelContext = modelContext

    // Initialize PreferencesManager with ModelContext
    appState.initializePreferencesManager(with: modelContext)

    logger.debug("✅ ModelContext is set and PreferencesManager initialized")

    // Only force refresh if we haven't loaded feeds before
    if !hasLoadedFeedsAtLeastOnce {
      logger.info("🔄 Forcing first feed refresh during initialization")
      await loadFeedsIfNeeded(forceRefresh: true)
      await updateCaches()
      hasLoadedFeedsAtLeastOnce = true
    } else {
      logger.info("Skipping feed refresh - feeds already loaded once")
      // Just update the caches to ensure we're in sync
      await updateCaches()
    }

    // If we still have issues, try to repair server preferences
    if feedGenerators.isEmpty && hasLoadedFeedsAtLeastOnce {
      logger.info("⚠️ Feed generators still empty after loading, repairing preferences...")
      try? await appState.preferencesManager.repairPreferences()
      await loadFeedsIfNeeded(forceRefresh: true)
      await updateCaches()
    }
  }

  // Method to update caches
  @MainActor
  func updateCaches() async {
    do {
      let preferences = try await appState.preferencesManager.getPreferences()
      _cachedPinnedFeeds = preferences.pinnedFeeds
      _cachedSavedFeeds = preferences.savedFeeds
      _cachedPinnedFeedsSet = Set(preferences.pinnedFeeds)

      // Update widget data with feed preferences
      await updateWidgetFeedPreferences()

      logger.debug(
        "Updated caches with \(self._cachedPinnedFeeds.count) pinned and \(self._cachedSavedFeeds.count) saved feeds"
      )
    } catch {
      logger.error("Error updating caches: \(error.localizedDescription)")
    }
  }
  
  /// Updates widget with current feed preferences and generator information
  @MainActor
  private func updateWidgetFeedPreferences() async {
    // Create feed generator display name mapping
    var feedGeneratorDisplayNames: [String: String] = [:]
    
    for (uri, generator) in feedGenerators {
      feedGeneratorDisplayNames[uri.uriString()] = generator.displayName
    }
    
    // Include list names as well
    for (uri, list) in listDetails {
      feedGeneratorDisplayNames[uri.uriString()] = list.name
    }
    
    // Add system feeds
    feedGeneratorDisplayNames["timeline"] = "Home Timeline"
    feedGeneratorDisplayNames["following"] = "Following"
    
    // Update widget with current preferences
    FeedWidgetDataProvider.shared.updateSharedFeedPreferences(
      pinnedFeeds: _cachedPinnedFeeds,
      savedFeeds: _cachedSavedFeeds,
      feedGenerators: feedGeneratorDisplayNames
    )
    
    logger.debug("Updated widget with feed preferences")
  }

  func loadFeedsIfNeeded(forceRefresh: Bool = false) async {
    guard !isLoading else { return }

    isLoading = true
    logger.info("📊 Loading feeds with forceRefresh=\(forceRefresh)")
    do {
      // Initialize PreferencesManager if needed
      if let modelContext = modelContext {
        appState.initializePreferencesManager(with: modelContext)
      }

      // Try to load preferences using PreferencesManager with force refresh option
      try await appState.preferencesManager.fetchPreferences(forceRefresh: forceRefresh)

      // Update caches
      await updateCaches()

      // Fetch feed generators and list details based on the preferences
      await self.fetchFeedGenerators()
      await self.fetchListDetails()

      errorMessage = nil

      // Mark that we've successfully loaded feeds at least once
      hasLoadedFeedsAtLeastOnce = true
      logger.debug(
        "Successfully loaded feeds, hasLoadedFeedsAtLeastOnce=\(self.hasLoadedFeedsAtLeastOnce)")
    } catch {
      if let prefError = error as? PreferencesManagerError {
        switch prefError {
        case .clientNotInitialized, .modelContextNotInitialized:
          logger.debug("Skipping error alert for transient preferences state: \(prefError.localizedDescription)")
        case .invalidData where !hasAttemptedPreferencesRepair:
          hasAttemptedPreferencesRepair = true
          logger.warning("Preferences data invalid during load; attempting repair before retry")
          try? await appState.preferencesManager.repairPreferences()
          isLoading = false
          await loadFeedsIfNeeded(forceRefresh: true)
          return
        default:
          errorMessage = "Failed to fetch preferences: \(prefError.localizedDescription)"
          logger.error("Error loading feeds: \(prefError.localizedDescription)")
        }
      } else {
        errorMessage = "Failed to fetch preferences: \(error.localizedDescription)"
        logger.error("Error loading feeds: \(error.localizedDescription)")
      }
    }
    isLoading = false
  }

  func fetchFeedGenerators(attempt: Int = 0) async {
    do {
      let preferences = try await appState.preferencesManager.getPreferences()
      
      // Start with all unique feeds
      let allUniqueFeeds = Array(Set(preferences.pinnedFeeds + preferences.savedFeeds))
      
      // Filter out system feeds before trying to convert to URIs
      let customFeeds = allUniqueFeeds.filter { !SystemFeedTypes.isTimelineFeed($0) }
      
      // If we already have generators and nothing to fetch, just keep them
      if customFeeds.isEmpty && !feedGenerators.isEmpty {
        logger.info(
          "No custom feeds to fetch, but keeping existing \(self.feedGenerators.count) generators")
        return
      }
      
      // Only convert custom FEED GENERATORS to URIs (exclude lists to avoid API errors)
      let generatorFeeds = customFeeds.filter { $0.contains("/app.bsky.feed.generator/") }
      let feedURIs = generatorFeeds.compactMap { try? ATProtocolURI(uriString: $0) }
      
      // It's normal to have no custom generator feeds
      if feedURIs.isEmpty {
        logger.info("No custom feed generators to fetch (only system feeds and/or lists)")
        // Don't clear existing feed generators if we have them
        if !feedGenerators.isEmpty {
          logger.info("Keeping existing \(self.feedGenerators.count) feed generators")
        }
        return
      }
      
      // Safely unwrap the client
      guard let client = appState.atProtoClient else {
        // Client not ready yet - retry with backoff
        if attempt < maxGeneratorRetryAttempts {
          let delay = generatorRetryDelayBase * UInt64(1 << attempt) // Exponential backoff
          logger.info("ATProto client not ready, retrying in \(Double(delay) / 1_000_000_000)s (attempt \(attempt + 1)/\(self.maxGeneratorRetryAttempts))")
          try? await Task.sleep(nanoseconds: delay)
          await fetchFeedGenerators(attempt: attempt + 1)
        } else {
          logger.error("ATProto client not available after \(self.maxGeneratorRetryAttempts) attempts")
        }
        return
      }
      
      logger.info("Attempting to fetch \(feedURIs.count) feed generators (attempt \(attempt + 1))")
      let input = AppBskyFeedGetFeedGenerators.Parameters(feeds: feedURIs)
      let (responseCode, output) = try await client.app.bsky.feed.getFeedGenerators(input: input)
      
      if responseCode == 200, let generators = output?.feeds {
        logger.info("✅ Successfully fetched \(generators.count) feed generators")
        // IMPORTANT: Don't completely replace feedGenerators - update it
        for generator in generators {
          feedGenerators[generator.uri] = generator
        }
      } else if responseCode == 401 {
        // Don't clear existing generators on auth failure - keep stale data for better UX
        logger.warning("Unauthorized when fetching feed generators (attempt \(attempt + 1)); scheduling retry")
        if attempt < maxGeneratorRetryAttempts {
          let delay = generatorRetryDelayBase * UInt64(1 << attempt) // Exponential backoff: 0.5s, 1s, 2s, 4s
          try? await Task.sleep(nanoseconds: delay)
          await fetchFeedGenerators(attempt: attempt + 1)
        } else {
          logger.error("Feed generator fetch unauthorized after \(self.maxGeneratorRetryAttempts) attempts")
        }
        return
      } else {
        logger.error("Feed generator fetch failed with code: \(responseCode)")
        // Retry on other failures too
        if attempt < maxGeneratorRetryAttempts {
          let delay = generatorRetryDelayBase * UInt64(1 << attempt)
          try? await Task.sleep(nanoseconds: delay)
          await fetchFeedGenerators(attempt: attempt + 1)
        }
      }
    } catch {
      // Check if it's a cancellation error
      let nsError = error as NSError
      if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
        // This is a cancellation error, don't update UI or show alerts
        logger.debug("Feed generator fetch cancelled")
        return
      }

      if attempt < maxGeneratorRetryAttempts {
        let delay = generatorRetryDelayBase * UInt64(1 << attempt) // Exponential backoff
        logger.info("Transient error fetching feed generators (\(error.localizedDescription)); retrying in \(Double(delay) / 1_000_000_000)s (attempt \(attempt + 1)/\(self.maxGeneratorRetryAttempts))")
        try? await Task.sleep(nanoseconds: delay)
        await fetchFeedGenerators(attempt: attempt + 1)
        return
      }

      logger.error("Feed generator fetch failed after \(self.maxGeneratorRetryAttempts) attempts: \(error.localizedDescription)")
    }
  }

  func fetchListDetails() async {
    do {
      let preferences = try await appState.preferencesManager.getPreferences()
      let allUniqueFeeds = Array(Set(preferences.pinnedFeeds + preferences.savedFeeds))
      let listURIs = allUniqueFeeds
        .filter { $0.contains("/app.bsky.graph.list/") }
        .compactMap { try? ATProtocolURI(uriString: $0) }

      guard !listURIs.isEmpty else { return }

      // Track batch operation for Instruments visibility
      let signpostId = PerformanceSignposts.beginBatchOperation("list-details-fetch", count: listURIs.count)
      var successCount = 0
      var failureCount = 0

      // Fetch all list details in parallel instead of sequentially (fixes N+1)
      await withTaskGroup(of: (ATProtocolURI, AppBskyGraphDefs.ListView?).self) { group in
        for uri in listURIs {
          group.addTask {
            let uriString = uri.uriString()
            do {
              let details = try await self.appState.listManager.getListDetails(uriString)
              return (uri, details)
            } catch {
              self.logger.error("Failed to fetch list details for \(uriString): \(error.localizedDescription)")
              return (uri, nil)
            }
          }
        }

        for await (uri, details) in group {
          if let details = details {
            self.listDetails[uri] = details
            successCount += 1
          } else {
            failureCount += 1
          }
        }
      }

      PerformanceSignposts.endBatchOperation(id: signpostId, successCount: successCount, failureCount: failureCount)

      // After fetching, update widget mapping
      await updateWidgetFeedPreferences()
    } catch {
      logger.error("Error fetching list details: \(error.localizedDescription)")
    }
  }

  func extractTitle(from uri: ATProtocolURI) -> String {
    return uri.recordKey ?? "Unknown Feed"
  }

  // MARK: - Feed Management Functions

  /// Checks if a feed is pinned
  func isPinned(_ feedURI: String) async -> Bool {
    do {
      let preferences = try await appState.preferencesManager.getPreferences()
      return preferences.pinnedFeeds.contains(feedURI)
    } catch {
      logger.error("Error checking if feed is pinned: \(error.localizedDescription)")
      return false
    }
  }

  func isItemPinned(_ item: String) async -> Bool {
    do {
      let preferences = try await appState.preferencesManager.getPreferences()
      return preferences.pinnedFeeds.contains(item)
    } catch {
      logger.error("Error checking if item is pinned: \(error.localizedDescription)")
      return false
    }
  }

  /// Gets pinned feeds from the preferences manager
  func getPinnedFeeds() async -> [String] {
    do {
      let preferences = try await appState.preferencesManager.getPreferences()
      return preferences.pinnedFeeds
    } catch {
      logger.error("Error getting pinned feeds: \(error.localizedDescription)")
      return []
    }
  }

  /// Gets saved feeds from the preferences manager
  func getSavedFeeds() async -> [String] {
    do {
      let preferences = try await appState.preferencesManager.getPreferences()
      return preferences.savedFeeds
    } catch {
      logger.error("Error getting saved feeds: \(error.localizedDescription)")
      return []
    }
  }

  /// Toggles pin status for a feed URI
  @MainActor
  func togglePinStatus(for feedURI: String) async {
    do {
      // Get current preferences
      let preferences = try await appState.preferencesManager.getPreferences()

      // First check if this is a protected feed
      if SystemFeedTypes.isTimelineFeed(feedURI) && preferences.pinnedFeeds.contains(feedURI) {
        logger.warning("Attempted to unpin protected system feed: \(feedURI)")
        // Don't allow unpinning of timeline feeds
        return
      }

      // Toggle pin status
      preferences.togglePinStatus(for: feedURI)

      // Save changes to both SwiftData and API
      try await appState.preferencesManager.saveAndSyncPreferences(preferences)

      // Update caches after change
      await updateCaches()
      
      // Notify state invalidation bus that feeds have changed
      await appState.stateInvalidationBus.notify(.feedListChanged)
    } catch {
      errorMessage = "Failed to toggle pin status: \(error.localizedDescription)"
      logger.error("Error toggling pin status: \(error.localizedDescription)")
    }
  }

  /// Removes a feed from both pinned and saved lists
  @MainActor
  func removeFeed(_ feedURI: String) async {
    do {
      // Get current preferences
      let preferences = try await appState.preferencesManager.getPreferences()

      // First check if this is a protected feed
      if SystemFeedTypes.isTimelineFeed(feedURI) {
        logger.warning("Attempted to remove protected system feed: \(feedURI)")
        // Don't allow removal of timeline feeds
        return
      }

      // Remove feed
      preferences.removeFeed(feedURI)

      // Remove from feedGenerators if it exists
      if let uri = try? ATProtocolURI(uriString: feedURI) {
        feedGenerators.removeValue(forKey: uri)
      }

      // Save changes to both SwiftData and API
      try await appState.preferencesManager.saveAndSyncPreferences(preferences)

      // Update caches after change
      await updateCaches()
      
      // Notify state invalidation bus that feeds have changed
      await appState.stateInvalidationBus.notify(.feedListChanged)
    } catch {
      errorMessage = "Failed to remove feed: \(error.localizedDescription)"
      logger.error("Error removing feed: \(error.localizedDescription)")
    }
  }

  /// Reorders a pinned feed
  @MainActor
  func reorderPinnedFeed(from source: String, to destination: String) async {
    do {
      // Get current preferences
      let preferences = try await appState.preferencesManager.getPreferences()
      var currentPinned = preferences.pinnedFeeds

      guard let sourceIndex = currentPinned.firstIndex(of: source),
        let destinationIndex = currentPinned.firstIndex(of: destination)
      else {
        logger.error("Failed to find source or destination index for reordering pinned feeds.")
        return
      }

      // Perform reorder
      let item = currentPinned.remove(at: sourceIndex)

      // Calculate insertion point - CORRECTED LOGIC
      let insertionPoint: Int
      if sourceIndex < destinationIndex {
        // Moving DOWN: Insert *after* the destination item's original position.
        // Since an item *before* the destination was removed, the destination's effective index
        // for insertion remains its original index.
        insertionPoint = destinationIndex
      } else {
        // Moving UP: Insert *at* the destination item's original position.
        insertionPoint = destinationIndex
      }

      // Clamp index to valid range (especially needed if moving down to the last item)
      let clampedInsertionPoint = max(0, min(insertionPoint, currentPinned.count))

      currentPinned.insert(item, at: clampedInsertionPoint)
      // --- End Corrected Logic ---

      logger.debug("✅ Reordered pinned feed. New order: \(currentPinned)")

      // Save the reordered list using the new method
      try await appState.preferencesManager.setPinnedFeeds(currentPinned)

      // Update caches after change
      await updateCaches()
      
      // Notify state invalidation bus that feeds have changed
      await appState.stateInvalidationBus.notify(.feedListChanged)
    } catch {
      errorMessage = "Failed to reorder pinned feed: \(error.localizedDescription)"
      logger.error("Error reordering pinned feed: \(error.localizedDescription)")
    }
  }

  /// Reorders a saved feed
  @MainActor
  func reorderSavedFeed(from source: String, to destination: String) async {
    do {
      // Get current preferences
      let preferences = try await appState.preferencesManager.getPreferences()
      var currentSaved = preferences.savedFeeds

      guard let sourceIndex = currentSaved.firstIndex(of: source),
        let destinationIndex = currentSaved.firstIndex(of: destination)
      else {
        logger.error("Failed to find source or destination index for reordering saved feeds.")
        return
      }

      // Perform reorder
      let item = currentSaved.remove(at: sourceIndex)

      // Calculate insertion point - CORRECTED LOGIC
      let insertionPoint: Int
      if sourceIndex < destinationIndex {
        // Moving DOWN: Insert *after* the destination item's original position.
        insertionPoint = destinationIndex
      } else {
        // Moving UP: Insert *at* the destination item's original position.
        insertionPoint = destinationIndex
      }

      // Clamp index to valid range
      let clampedInsertionPoint = max(0, min(insertionPoint, currentSaved.count))

      currentSaved.insert(item, at: clampedInsertionPoint)
      // --- End Corrected Logic ---

      logger.debug("✅ Reordered saved feed. New order: \(currentSaved)")

      // Save the reordered list using the new method
      try await appState.preferencesManager.setSavedFeeds(currentSaved)

      // Update caches after change
      await updateCaches()
      
      // Notify state invalidation bus that feeds have changed
      await appState.stateInvalidationBus.notify(.feedListChanged)
    } catch {
      errorMessage = "Failed to reorder saved feed: \(error.localizedDescription)"
      logger.error("Error reordering saved feed: \(error.localizedDescription)")
    }
  }
  /// Adds a new feed
  @MainActor
  func addFeed(_ feedURI: String, pinned: Bool = false) async {
    // Validate the URI first
    guard (try? ATProtocolURI(uriString: feedURI)) != nil else {
      errorMessage = "Invalid feed URI"
      logger.error("Attempted to add invalid feed URI: \(feedURI)")
      return
    }

    do {
      // 1. Get the current preferences object
      let preferences = try await appState.preferencesManager.getPreferences()

      // 2. Call the addFeed method on the Preferences object
      preferences.addFeed(feedURI, pinned: pinned)
      logger.debug("Locally added feed '\(feedURI)' with pinned=\(pinned)")

      // 3. Save and sync the modified preferences object via the manager
      try await appState.preferencesManager.saveAndSyncPreferences(preferences)
      logger.info("Saved and synced preferences after adding feed '\(feedURI)'")

      // 4. Refresh feed generators to include the new feed
      await fetchFeedGenerators()

      // 5. Update local caches
      await updateCaches()
      
      // 6. Notify state invalidation bus that feeds have changed
      await appState.stateInvalidationBus.notify(.feedListChanged)

    } catch {
      errorMessage = "Failed to add feed: \(error.localizedDescription)"
      logger.error("Error adding feed '\(feedURI)': \(error.localizedDescription)")
    }
  }

  /// Filters feeds based on search text
  func filteredFeeds(_ feeds: [String], searchText: String) -> [String] {
    if searchText.isEmpty {
      return feeds
    }

    return feeds.filter { feed in
      // Try to get the generator view for the feed URI
      if let uri = try? ATProtocolURI(uriString: feed),
        let generator = feedGenerators[uri] {
        // Check display name and description
        let displayNameMatch =
          generator.displayName.localizedCaseInsensitiveContains(searchText)
        let descriptionMatch =
          generator.description?.localizedCaseInsensitiveContains(searchText) ?? false
        return displayNameMatch || descriptionMatch
      } else {
        // Fallback to checking the URI itself if generator info isn't available
        return feed.localizedCaseInsensitiveContains(searchText)
      }
    }
  }

  @MainActor
  func setDefaultFeed(_ feedURI: String) async {
    // Sets the dropped feed as the default by moving it to the top of pinned feeds
    logger.debug("Attempting to set default feed: \(feedURI)")

    do {
      // Get current preferences
      let preferences = try await appState.preferencesManager.getPreferences()
      var currentPinned = preferences.pinnedFeeds

      // Check if this feed is already the first one
      if currentPinned.first == feedURI {
        logger.debug("Feed \(feedURI) is already the default feed")
        return
      }

      // If this feed is already in the list, remove it first
      currentPinned.removeAll { $0 == feedURI }

      // Insert at the beginning
      currentPinned.insert(feedURI, at: 0)

      logger.debug("New pinned order with \(feedURI) at front: \(currentPinned)")

      // Save the reordered list (this will sync to server)
      try await appState.preferencesManager.setPinnedFeeds(currentPinned)

      // Ensure the feed is also marked as saved if it wasn't pinned before (pinning implies saving)
      // This might be handled implicitly by setPinnedFeeds/sync logic, but double-check PreferencesManager logic if needed.
      // Consider if addFeedSafely logic needs adjustment or if setPinnedFeeds handles adding to saved implicitly.
      // For now, assume setPinnedFeeds handles the sync correctly.

      logger.info("✅ Successfully set \(feedURI) as the default feed.")

      // Update caches after change
      await updateCaches()
      
      // Notify state invalidation bus that feeds have changed
      await appState.stateInvalidationBus.notify(.feedListChanged)

    } catch {
      errorMessage = "Failed to set default feed: \(error.localizedDescription)"
      logger.error("❌ Failed to set default feed: \(error.localizedDescription)")
    }
  }
}
