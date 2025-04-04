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
  // Remove local preferences property and just use the preferencesManager
  // when needed to avoid duplicate sources of truth
  var feedGenerators: [ATProtocolURI: AppBskyFeedDefs.GeneratorView] = [:]
  var isLoading = false
  var errorMessage: String?

  // Cache for synchronous access
  private var _cachedPinnedFeeds: [String] = []
  private var _cachedSavedFeeds: [String] = []
  private var _cachedPinnedFeedsSet: Set<String> = Set()

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

  // logger
  private let logger = Logger(subsystem: "blue.catbird", category: "FeedsStartPageViewModel")

  private var appState: AppState
  var modelContext: ModelContext?

  init(appState: AppState, modelContext: ModelContext? = nil) {
    self.appState = appState
    self.modelContext = modelContext
    
    // Setup observation of authentication state changes to detect logouts
    Task {
      for await state in appState.authManager.stateChanges {
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
      logger.debug("Updated caches with \(self._cachedPinnedFeeds.count) pinned and \(self._cachedSavedFeeds.count) saved feeds")
    } catch {
      logger.error("Error updating caches: \(error.localizedDescription)")
    }
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

      // Fetch feed generators based on the preferences
      await fetchFeedGenerators()

      errorMessage = nil
      
      // Mark that we've successfully loaded feeds at least once
      hasLoadedFeedsAtLeastOnce = true
      logger.debug("Successfully loaded feeds, hasLoadedFeedsAtLeastOnce=\(self.hasLoadedFeedsAtLeastOnce)")
    } catch {
      errorMessage = "Failed to fetch preferences: \(error.localizedDescription)"
      logger.error("Error loading feeds: \(error.localizedDescription)")
    }
    isLoading = false
  }

  func fetchFeedGenerators() async {
    do {
      let preferences = try await appState.preferencesManager.getPreferences()
      
      // Start with all unique feeds
      let allUniqueFeeds = Array(Set(preferences.pinnedFeeds + preferences.savedFeeds))
//      logger.debug("All feeds: \(allUniqueFeeds)")
      
      // Filter out system feeds before trying to convert to URIs
      let customFeeds = allUniqueFeeds.filter { !SystemFeedTypes.isTimelineFeed($0) }
//      logger.debug("Custom feeds to fetch: \(customFeeds)")
      
      // If we already have generators and nothing to fetch, just keep them
      if customFeeds.isEmpty && !feedGenerators.isEmpty {
        logger.info("No custom feeds to fetch, but keeping existing \(self.feedGenerators.count) generators")
        return
      }
      
      // Only convert custom feeds to URIs
      let feedURIs = customFeeds.compactMap { try? ATProtocolURI(uriString: $0) }
      
      // It's normal to have no custom feeds for new users
      if feedURIs.isEmpty {
        logger.info("No custom feeds to fetch generators for (only system feeds)")
        // Don't clear existing feed generators if we have them
        if !feedGenerators.isEmpty {
          logger.info("Keeping existing \(self.feedGenerators.count) feed generators")
        }
        return
      }

      // Safely unwrap the client
      guard let client = appState.atProtoClient else {
        errorMessage = "ATProto client is not initialized"
        logger.error("ATProto client not available for feed generator fetch")
        return
      }

      logger.info("Attempting to fetch \(feedURIs.count) feed generators")
      let input = AppBskyFeedGetFeedGenerators.Parameters(feeds: feedURIs)
      let (responseCode, output) = try await client.app.bsky.feed.getFeedGenerators(input: input)

      if responseCode == 200, let generators = output?.feeds {
        logger.info("Successfully fetched \(generators.count) feed generators")
        // IMPORTANT: Don't completely replace feedGenerators - update it
        for generator in generators {
          feedGenerators[generator.uri] = generator
        }
      } else {
        errorMessage = "Failed to fetch feed generators. Response code: \(responseCode)"
        logger.error("Feed generator fetch failed with code: \(responseCode)")
      }
    } catch {
        // Check if it's a cancellation error
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == -999 {
            // This is a cancellation error, don't update UI
            logger.debug("Feed generator fetch cancelled")
            return
        }
        
        // Only set error message for non-cancellation errors
        errorMessage = "Error fetching feed generators: \(error.localizedDescription)"
        logger.error("Exception in fetchFeedGenerators: \(error.localizedDescription)")
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

      guard let sourceIndex = preferences.pinnedFeeds.firstIndex(of: source),
        let destinationIndex = preferences.pinnedFeeds.firstIndex(of: destination)
      else { return }

      let item = preferences.pinnedFeeds.remove(at: sourceIndex)
        let newIndex = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
        preferences.pinnedFeeds.insert(item, at: newIndex)

      // Save changes to both SwiftData and API
      try await appState.preferencesManager.saveAndSyncPreferences(preferences)

      // Update caches after change
      await updateCaches()
    } catch {
      errorMessage = "Failed to reorder feed: \(error.localizedDescription)"
      logger.error("Error reordering feed: \(error.localizedDescription)")
    }
  }

  /// Reorders a saved feed
    @MainActor
    func reorderSavedFeed(from source: String, to destination: String) async {
      do {
        // Get current preferences
        let preferences = try await appState.preferencesManager.getPreferences()

        guard let sourceIndex = preferences.savedFeeds.firstIndex(of: source),
              let destinationIndex = preferences.savedFeeds.firstIndex(of: destination)
        else { return }

        let item = preferences.savedFeeds.remove(at: sourceIndex)
        // Fix this line:
        let newIndex = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
        preferences.savedFeeds.insert(item, at: newIndex)

        // Log the reordering
        logger.debug("✅ Reordered saved feed from index \(sourceIndex) to \(newIndex)")

        // Save changes to both SwiftData and API
        try await appState.preferencesManager.saveAndSyncPreferences(preferences)

        // Update caches after change
        await updateCaches()
      } catch {
        errorMessage = "Failed to reorder feed: \(error.localizedDescription)"
        logger.error("Error reordering feed: \(error.localizedDescription)")
      }
    }
  /// Adds a new feed
  @MainActor
  func addFeed(_ feedURI: String, pinned: Bool = false) async {
    // Validate the URI first
    guard (try? ATProtocolURI(uriString: feedURI)) != nil else {
      errorMessage = "Invalid feed URI"
      return
    }

    do {
      try await appState.preferencesManager.addFeedSafely(feedURI, pinned: pinned)

      // Refresh feed generators to include the new feed
      await fetchFeedGenerators()

      // Update caches after adding feed
      await updateCaches()
    } catch {
      errorMessage = "Failed to add feed: \(error.localizedDescription)"
      logger.error("Error adding feed: \(error.localizedDescription)")
    }
  }

  /// Filters feeds based on search text
  func filteredFeeds(_ feeds: [String], searchText: String) -> [String] {
    if searchText.isEmpty {
      return feeds
    }

    return feeds.filter { feed in
      if let uri = try? ATProtocolURI(uriString: feed) {
        if let generator = feedGenerators[uri] {
          return generator.displayName.localizedCaseInsensitiveContains(searchText)
        } else {
          return extractTitle(from: uri).localizedCaseInsensitiveContains(searchText)
        }
      }
      return false
    }
  }
}
