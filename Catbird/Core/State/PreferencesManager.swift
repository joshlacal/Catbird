import Foundation
import OSLog
import Petrel
import SwiftData
import SwiftUI

/// Manages user preferences with proper state management and persistence
@Observable
final class PreferencesManager {
  // MARK: - Properties

  private let logger = Logger(subsystem: "blue.catbird", category: "PreferencesManager")

  // Add cache for server preferences to maintain consistency
  private var cachedServerPreferences: Preferences?

  // Current state
  enum PreferencesState: Equatable {
    case initializing
    case ready
    case loading
    case error(String)

    // Custom implementation for Equatable
    static func == (lhs: PreferencesState, rhs: PreferencesState) -> Bool {
      switch (lhs, rhs) {
      case (.initializing, .initializing):
        return true
      case (.ready, .ready):
        return true
      case (.loading, .loading):
        return true
      case (.error(let lhsMsg), .error(let rhsMsg)):
        return lhsMsg == rhsMsg
      default:
        return false
      }
    }
  }

  private(set) var state: PreferencesState = .initializing

  // Core dependencies
  private weak var client: ATProtoClient?
  private var modelContext: ModelContext?

  // MARK: - Initialization

  init(client: ATProtoClient? = nil, modelContext: ModelContext? = nil) {
    self.client = client
    self.modelContext = modelContext
    logger.debug("PreferencesManager initialized")
  }

  /// Update client reference when it changes
  func updateClient(_ client: ATProtoClient?) {
    self.client = client

    // Reset cache when client changes - we'll need to refetch data for the new user
    if client == nil {
      logger.info("Client reset - clearing cached server preferences")
      cachedServerPreferences = nil
    }
  }

  /// Set or update the model context
  func setModelContext(_ modelContext: ModelContext) {
    self.modelContext = modelContext
    state = .ready
    logger.debug("ModelContext set for PreferencesManager")
  }

  // MARK: - Clear Preferences

  /// Clears all user preferences when logging out
  @MainActor
  func clearAllPreferences() async {
    logger.info("Clearing all preferences data due to logout")

    // Clear cached server preferences
    cachedServerPreferences = nil

    // Reset state
    state = .initializing

    guard let modelContext = modelContext else {
      logger.warning("ModelContext not available when trying to clear preferences")
      return
    }

    do {
      // Fetch all preferences
      let descriptor = FetchDescriptor<Preferences>()
      let preferences = try modelContext.fetch(descriptor)

      // Delete all existing preferences
      for pref in preferences {
        modelContext.delete(pref)
      }

      // Save changes
      try modelContext.save()

      logger.info("All preferences data successfully cleared")
      state = .ready
    } catch {
      logger.error("Failed to clear preferences: \(error.localizedDescription)")
      state = .error("Failed to clear preferences: \(error.localizedDescription)")
    }
  }

  // MARK: - Preferences Management

  /// Fetches preferences from server if needed
  @MainActor
  func fetchPreferences(forceRefresh: Bool = false) async throws {
    // Start with setting state
    state = .loading

    // Check if client exists before proceeding
    guard let client = client else {
      logger.warning("ATProto client not available for preferences fetch - deferring fetch")
      state = .ready  // Set to ready instead of error to allow app to continue
      return  // Return without throwing error
    }

    // Ensure model context is available
    guard modelContext != nil else {
      logger.error("ModelContext not available for preferences")
      state = .error("ModelContext not initialized")
      throw PreferencesManagerError.modelContextNotInitialized
    }

    do {
      // Try to load from SwiftData first
      let localPreferences = try await loadPreferences()

      // Use cached server preferences if available and not forcing refresh
      if !forceRefresh, let cachedPrefs = cachedServerPreferences {
        logger.info(
          "Using cached server preferences (pinned: \(cachedPrefs.pinnedFeeds.count), saved: \(cachedPrefs.savedFeeds.count))"
        )
        // Ensure the cache is also applied to SwiftData if it differs significantly
        // This handles cases where the app might have quit before a save completed.
        if let localPrefs = localPreferences,
          !arePreferencesSemanticallyEqual(localPrefs, cachedPrefs) {
          logger.warning(
            "Cached preferences differ from local SwiftData. Updating SwiftData from cache.")
          try await savePreferences(cachedPrefs)  // Update local store
        }
        state = .ready
        return
      }

      // Detect minimal preferences that suggest incomplete data
      let hasMinimalLocalPrefs =
        localPreferences == nil
        || (localPreferences!.savedFeeds.isEmpty && localPreferences!.pinnedFeeds.count <= 1
          && localPreferences!.pinnedFeeds.allSatisfy { SystemFeedTypes.isTimelineFeed($0) })

      // Use local preferences if they're complete and we're not forcing refresh
      if !forceRefresh && localPreferences != nil && !hasMinimalLocalPrefs {
        logger.info(
          "Using complete local preferences - Pinned: \(localPreferences?.pinnedFeeds.count ?? 0), Saved: \(localPreferences?.savedFeeds.count ?? 0)"
        )
        // Cache these complete local preferences
        cachedServerPreferences = localPreferences
        state = .ready
        return
      }

      // Log why we're fetching from server
      if forceRefresh {
        logger.info("Force refreshing preferences from server")
      } else if hasMinimalLocalPrefs {
        logger.info("Found minimal local preferences, fetching from server")
      } else {
        logger.info("No local preferences found, fetching from server")
      }

      // Fetch from server
      logger.info("Fetching preferences from server")
      let params = AppBskyActorGetPreferences.Parameters()
      let serverResponse = try await client.app.bsky.actor.getPreferences(input: params)

      guard let resultItems = serverResponse.data?.preferences.items else {
        logger.error("No preferences data found in server response")
        state = .error("No preferences data found")
        throw PreferencesManagerError.invalidData
      }

      // Process all preference types from server
      var serverSavedFeeds: [String] = []
      var serverPinnedFeeds: [String] = []
      var serverContentLabelPrefs: [ContentLabelPreference] = []
      var serverThreadViewPref: ThreadViewPreference?
      var serverFeedViewPref: FeedViewPreference?
      var serverAdultContentEnabled: Bool = false
      var serverBirthDate: Date?
      var serverMutedWords: [MutedWord] = []
      var serverHiddenPosts: [String] = []
      var serverLabelers: [LabelerPreference] = []
      var serverActiveProgressGuide: String?
      var serverQueuedNudges: [String] = []
      var serverNuxStates: [NuxState] = []
      var serverInterests: [String] = []

      // --- Process Server Response ---
      var didProcessV2Feeds = false  // Flag to prioritize V2
      for pref in resultItems {
        switch pref {
        case .savedFeedsPref(let value):  // V1
          if !didProcessV2Feeds {  // Only process V1 if V2 wasn't found
            serverSavedFeeds = value.saved.map { $0.uriString() }
            serverPinnedFeeds = value.pinned.map { $0.uriString() }
            logger.debug(
              "[fetchPreferences] Processed V1 Feeds (V2 not found): Pinned=\(serverPinnedFeeds.count), Saved=\(serverSavedFeeds.count)"
            )
          } else {
            logger.debug(
              "[fetchPreferences] Skipping V1 Feeds processing because V2 was already processed.")
          }

        case .savedFeedsPrefV2(let value):  // V2 (overwrites V1, preserves order)
          serverPinnedFeeds = value.items.filter { $0.pinned }.map { $0.value }
          serverSavedFeeds = value.items.filter { !$0.pinned }.map { $0.value }
          didProcessV2Feeds = true  // Mark V2 as processed
          logger.debug(
            "[fetchPreferences] Processed V2 Feeds: Pinned=\(serverPinnedFeeds.count), Saved=\(serverSavedFeeds.count)"
          )
          logger.debug("[fetchPreferences] V2 Pinned Order: \(serverPinnedFeeds)")

        case .contentLabelPref(let value):
          serverContentLabelPrefs.append(
            ContentLabelPreference(
              labelerDid: value.labelerDid,
              label: value.label,
              visibility: value.visibility
            ))

        case .adultContentPref(let value):
          serverAdultContentEnabled = value.enabled

        case .personalDetailsPref(let value):
          if let dateStr = value.birthDate?.date {
            serverBirthDate = dateStr
          }

        case .threadViewPref(let value):
          serverThreadViewPref = ThreadViewPreference(
            sort: value.sort,
            prioritizeFollowedUsers: value.prioritizeFollowedUsers
          )

        case .feedViewPref(let value):
          serverFeedViewPref = FeedViewPreference(
            hideReplies: value.hideReplies,
            hideRepliesByUnfollowed: value.hideRepliesByUnfollowed,
            hideRepliesByLikeCount: value.hideRepliesByLikeCount,
            hideReposts: value.hideReposts,
            hideQuotePosts: value.hideQuotePosts
          )

        case .mutedWordsPref(let value):
          serverMutedWords = value.items.map { item in
            MutedWord(
              id: item.id ?? "",
              value: item.value,
              targets: item.targets.map { $0.rawValue },
              actorTarget: item.actorTarget,
              expiresAt: item.expiresAt?.date
            )
          }

        case .hiddenPostsPref(let value):
          serverHiddenPosts = value.items.map { $0.uriString() }

        case .labelersPref(let value):
          serverLabelers = value.labelers.map { LabelerPreference(did: $0.did) }

        case .bskyAppStatePref(let value):
          serverActiveProgressGuide = value.activeProgressGuide?.guide
          serverQueuedNudges = value.queuedNudges ?? []
          serverNuxStates = (value.nuxs ?? []).map { nux in
            NuxState(
              id: nux.id,
              completed: nux.completed,
              data: nux.data,
              expiresAt: nux.expiresAt?.date
            )
          }

        case .interestsPref(let value):
          serverInterests = value.tags
          default:
            logger.debug("Unhandled preference type encountered: \(String(describing: pref))")
        }
      }
      // --- End Processing Server Response ---

      logger.info(
        "Server preferences parsed - Pinned: \(serverPinnedFeeds.count), Saved: \(serverSavedFeeds.count)"
      )

      // --- Update Local Preferences using updateFeeds logic ---
      let currentPrefs = try await getPreferences()  // Get or create local instance

      // Update feeds using the robust updateFeeds method
      currentPrefs.updateFeeds(pinned: serverPinnedFeeds, saved: serverSavedFeeds)

      // Update other preferences directly
      currentPrefs.contentLabelPrefs = serverContentLabelPrefs
      currentPrefs.threadViewPref = serverThreadViewPref
      currentPrefs.feedViewPref = serverFeedViewPref
      currentPrefs.adultContentEnabled = serverAdultContentEnabled
      currentPrefs.birthDate = serverBirthDate
      currentPrefs.mutedWords = serverMutedWords
      currentPrefs.hiddenPosts = serverHiddenPosts
      currentPrefs.labelers = serverLabelers
      currentPrefs.activeProgressGuide = serverActiveProgressGuide
      currentPrefs.queuedNudges = serverQueuedNudges
      currentPrefs.nuxStates = serverNuxStates
      currentPrefs.interests = serverInterests

      // Save the updated local preferences object
      try await savePreferences(currentPrefs)  // Saves the modified currentPrefs to SwiftData
      logger.info("Local preferences updated and saved from server data.")

      // IMPORTANT: Update the cache with the processed preferences
      cachedServerPreferences = currentPrefs
      logger.debug("Updated cachedServerPreferences after processing server data.")

      // Update state
      state = .ready

    } catch {
      logger.error("Failed to fetch and process preferences: \(error.localizedDescription)")
      state = .error(error.localizedDescription)
      throw error
    }
  }

  /// Loads preferences from SwiftData
  @MainActor
  func loadPreferences() async throws -> Preferences? {
    guard let modelContext = modelContext else {
      logger.error("ModelContext not available for preferences load")
      throw PreferencesManagerError.modelContextNotInitialized
    }

    let descriptor = FetchDescriptor<Preferences>()
    let preferences = try modelContext.fetch(descriptor)
    return preferences.first
  }

  /// Gets local preferences synchronously from cache or SwiftData (non-async version)
  func getLocalPreferences() throws -> Preferences? {
    // First try cached server preferences
    if let cachedPrefs = cachedServerPreferences {
      return cachedPrefs
    }
    
    // Fall back to SwiftData (synchronous fetch)
    guard let modelContext = modelContext else {
      logger.error("ModelContext not available for synchronous preferences load")
      throw PreferencesManagerError.modelContextNotInitialized
    }
    
    let descriptor = FetchDescriptor<Preferences>()
    let preferences = try modelContext.fetch(descriptor)
    return preferences.first
  }

  /// Gets current preferences, creating default if none exist
  /// - Now prioritizes cached server preferences to ensure consistency
  @MainActor
  func getPreferences() async throws -> Preferences {
    guard let modelContext = modelContext else {
      logger.error("ModelContext not available for preferences get")
      throw PreferencesManagerError.modelContextNotInitialized
    }

    // First priority: return cached server preferences if available
    if let cachedPrefs = cachedServerPreferences {
      logger.debug("Returning cached server preferences")
      return cachedPrefs
    }

    // Second priority: load from SwiftData
    if let preferences = try await loadPreferences() {
      // If these are complete preferences (not just default following), cache them
      if !preferences.pinnedFeeds.isEmpty && preferences.pinnedFeeds.count > 1
        || !preferences.pinnedFeeds.allSatisfy({ SystemFeedTypes.isTimelineFeed($0) }) {
        logger.debug("Caching complete local preferences")
        cachedServerPreferences = preferences
      }
      return preferences
    }

    // Last resort: create default preferences
    logger.debug("Creating default preferences")
    let newPreferences = Preferences()
    modelContext.insert(newPreferences)
    try modelContext.save()
    return newPreferences
  }

  /// Saves preferences to SwiftData
  @MainActor
  func savePreferences(_ preferences: Preferences) async throws {
    guard let modelContext = modelContext else {
      logger.error("ModelContext not available for preferences save")
      throw PreferencesManagerError.modelContextNotInitialized
    }

    if let existingPreferences = try await loadPreferences() {
      // Update all properties of the existing preferences
      existingPreferences.pinnedFeeds = preferences.pinnedFeeds
      existingPreferences.savedFeeds = preferences.savedFeeds
      existingPreferences.contentLabelPrefs = preferences.contentLabelPrefs
      existingPreferences.threadViewPref = preferences.threadViewPref
      existingPreferences.feedViewPref = preferences.feedViewPref
      existingPreferences.adultContentEnabled = preferences.adultContentEnabled
      existingPreferences.birthDate = preferences.birthDate
      existingPreferences.mutedWords = preferences.mutedWords
      existingPreferences.hiddenPosts = preferences.hiddenPosts
      existingPreferences.labelers = preferences.labelers
      existingPreferences.activeProgressGuide = preferences.activeProgressGuide
      existingPreferences.queuedNudges = preferences.queuedNudges
      existingPreferences.nuxStates = preferences.nuxStates
      existingPreferences.interests = preferences.interests
    } else {
      modelContext.insert(preferences)
    }
    try modelContext.save()
    logger.debug("Preferences saved successfully")
  }

  /// Updates preferences with new feed lists AND SAVES
  @MainActor
  func updatePreferences(savedFeeds: [String], pinnedFeeds: [String]) async throws {
    guard let modelContext = modelContext else {
      logger.error("ModelContext not available for preferences update")
      throw PreferencesManagerError.modelContextNotInitialized
    }

    let preferences = try await getPreferences()  // Get existing or default
    preferences.updateFeeds(pinned: pinnedFeeds, saved: savedFeeds)  // Use the model's logic

    // Save the changes locally
    try await savePreferences(preferences)  // This handles insert or update in SwiftData

    // Update the cache
    cachedServerPreferences = preferences

    logger.info(
      "Preferences updated locally with \(preferences.savedFeeds.count) saved feeds and \(preferences.pinnedFeeds.count) pinned feeds"
    )
    // Note: Syncing is handled separately by saveAndSyncPreferences or setPinned/SavedFeeds
  }

  /// Saves preferences to both SwiftData and Bluesky API
  @MainActor
  func saveAndSyncPreferences(_ preferences: Preferences) async throws {
    // First save locally
    try await savePreferences(preferences)

    // Update cache so getPreferences returns the latest pinnedFeeds order
    cachedServerPreferences = preferences

    // Then sync with server
    try await syncToServer(preferences)

    // Refresh cache again post-sync
    cachedServerPreferences = preferences

    logger.debug("Preferences saved and synced to server")
  }

  /// Syncs current preferences to the Bluesky API
  @MainActor
  private func syncToServer(_ preferences: Preferences) async throws {
    guard let client = client else {
      logger.warning("ATProto client not available for preferences sync")
      throw PreferencesManagerError.clientNotInitialized
    }

    // IMPORTANT: Get current preferences from server first
    logger.debug("Fetching current server preferences before updating")
    let params = AppBskyActorGetPreferences.Parameters()
    let serverPrefs = try await client.app.bsky.actor.getPreferences(input: params)

    // Start with ALL existing preferences from server
    var allPrefItems = serverPrefs.data?.preferences.items ?? []

    // Only remove the specific preferences we're updating
    allPrefItems.removeAll { item in
      switch item {
      case .savedFeedsPref, .savedFeedsPrefV2:
        return true  // Remove feed prefs as we'll update them
      case .adultContentPref:
        return true  // Remove if we're updating it
      case .contentLabelPref:
        return true  // Remove all content labels as we'll update them
      case .threadViewPref:
        return preferences.threadViewPref != nil  // Only remove if we have a new value
      case .feedViewPref:
        return preferences.feedViewPref != nil  // Only remove if we have a new value
      case .personalDetailsPref:
        return preferences.birthDate != nil  // Only remove if we have a birth date
      case .mutedWordsPref:
        return !preferences.mutedWords.isEmpty  // Only remove if we have muted words
      case .hiddenPostsPref:
        return !preferences.hiddenPosts.isEmpty  // Only remove if we have hidden posts
      case .labelersPref:
        return !preferences.labelers.isEmpty  // Only remove if we have labelers
      case .bskyAppStatePref:
        return preferences.activeProgressGuide != nil || !preferences.nuxStates.isEmpty
          || !preferences.queuedNudges.isEmpty  // Only remove if we have app state prefs
      case .interestsPref:
        return !preferences.interests.isEmpty  // Only remove if we have interests
      default:
        return false  // Keep all other preference types
      }
    }

    // Ensure timeline feed is present
    let prefsToSync = preferences
    let timelineInPinned = prefsToSync.pinnedFeeds.contains {
      SystemFeedTypes.isTimelineFeed($0)
    }

    if !timelineInPinned {
      // Ensure timeline feed exists without changing order
      prefsToSync.pinnedFeeds.append(SystemFeedTypes.following)
      logger.warning("Added missing timeline feed before syncing to server")
    }

    // Create V2 saved feeds format
    var savedItems: [AppBskyActorDefs.SavedFeed] = []

    // Add pinned feeds in their exact order
    for uri in preferences.pinnedFeeds {
      let feedType = SystemFeedTypes.isTimelineFeed(uri) ? "timeline" : "feed"
      savedItems.append(
        AppBskyActorDefs.SavedFeed(
          id: await TIDGenerator.next(),  // Generate new ID for server consistency
          type: feedType,
          value: uri,
          pinned: true
        )
      )
    }

    // Add saved feeds (order doesn't strictly matter as much for saved, but maintain consistency)
    for uri in preferences.savedFeeds {
      savedItems.append(
        AppBskyActorDefs.SavedFeed(
          id: await TIDGenerator.next(),  // Generate new ID
          type: "feed",  // Assume saved are always custom feeds
          value: uri,
          pinned: false
        )
      )
    }

    // Add feed preferences (V2)
    allPrefItems.append(.savedFeedsPrefV2(AppBskyActorDefs.SavedFeedsPrefV2(items: savedItems)))

    // Add V1 format for backward compatibility (order might be less critical here, but use current order)
    let pinnedUris = preferences.pinnedFeeds.compactMap { try? ATProtocolURI(uriString: $0) }
    let savedUris = preferences.savedFeeds.compactMap { try? ATProtocolURI(uriString: $0) }

    allPrefItems.append(
      .savedFeedsPref(
        AppBskyActorDefs.SavedFeedsPref(
          pinned: pinnedUris,
          saved: savedUris,
          timelineIndex: nil
        )))

    // 2. Add all content label preferences
    for pref in prefsToSync.contentLabelPrefs {
      allPrefItems.append(
        .contentLabelPref(
          AppBskyActorDefs.ContentLabelPref(
            labelerDid: pref.labelerDid,
            label: pref.label,
            visibility: pref.visibility
          )))
    }

    // 3. Add adult content preference
    allPrefItems.append(
      .adultContentPref(
        AppBskyActorDefs.AdultContentPref(
          enabled: prefsToSync.adultContentEnabled
        )))

    // 4. Add birth date if present
    if let birthDate = prefsToSync.birthDate {
      let dateFormatter = ISO8601DateFormatter()
      let dateString = dateFormatter.string(from: birthDate)

      let atpDate = ATProtocolDate(iso8601String: dateString)

      allPrefItems.append(
        .personalDetailsPref(
          AppBskyActorDefs.PersonalDetailsPref(
            birthDate: atpDate
          )))
    }

    // 5. Add thread view preferences if present
    if let threadPref = prefsToSync.threadViewPref {
      allPrefItems.append(
        .threadViewPref(
          AppBskyActorDefs.ThreadViewPref(
            sort: threadPref.sort,
            prioritizeFollowedUsers: threadPref.prioritizeFollowedUsers
          )))
    }

    // 6. Add feed view preferences if present
    if let feedPref = prefsToSync.feedViewPref {
      allPrefItems.append(
        .feedViewPref(
          AppBskyActorDefs.FeedViewPref(
            feed: "home",  // Important: Always use "home" for following feed
            hideReplies: feedPref.hideReplies,
            hideRepliesByUnfollowed: feedPref.hideRepliesByUnfollowed,
            hideRepliesByLikeCount: feedPref.hideRepliesByLikeCount,
            hideReposts: feedPref.hideReposts,
            hideQuotePosts: feedPref.hideQuotePosts
          )))
    }

    // 7. Add muted words if present
    if !prefsToSync.mutedWords.isEmpty {
      let mutedWordItems = prefsToSync.mutedWords.map { word -> AppBskyActorDefs.MutedWord in
        let targets = word.targets.map { target -> AppBskyActorDefs.MutedWordTarget in
          return target == "content" ? .content : .tag
        }

        var expiresAtDate: ATProtocolDate?
        if let expires = word.expiresAt {
          let dateFormatter = ISO8601DateFormatter()
          expiresAtDate = ATProtocolDate(iso8601String: dateFormatter.string(from: expires))
        }

        return AppBskyActorDefs.MutedWord(
          id: word.id,
          value: word.value,
          targets: targets,
          actorTarget: word.actorTarget,
          expiresAt: expiresAtDate
        )
      }

      allPrefItems.append(.mutedWordsPref(AppBskyActorDefs.MutedWordsPref(items: mutedWordItems)))
    }

    // 8. Add hidden posts if present
    if !prefsToSync.hiddenPosts.isEmpty {
      let hiddenPostUris = prefsToSync.hiddenPosts.compactMap { try? ATProtocolURI(uriString: $0) }

      allPrefItems.append(.hiddenPostsPref(AppBskyActorDefs.HiddenPostsPref(items: hiddenPostUris)))
    }

    // 9. Add labelers if present
    if !prefsToSync.labelers.isEmpty {
      let labelerItems = prefsToSync.labelers.map { labeler -> AppBskyActorDefs.LabelerPrefItem in
        return AppBskyActorDefs.LabelerPrefItem(did: labeler.did)
      }

      allPrefItems.append(.labelersPref(AppBskyActorDefs.LabelersPref(labelers: labelerItems)))
    }

    // 10. Add app state preferences if needed
    if !prefsToSync.nuxStates.isEmpty || prefsToSync.activeProgressGuide != nil
      || !prefsToSync.queuedNudges.isEmpty {
      var progressGuide: AppBskyActorDefs.BskyAppProgressGuide?
      if let guide = prefsToSync.activeProgressGuide {
        progressGuide = AppBskyActorDefs.BskyAppProgressGuide(guide: guide)
      }

      let nuxItems = prefsToSync.nuxStates.map { nux -> AppBskyActorDefs.Nux in
        var expiresAtDate: ATProtocolDate?
        if let expires = nux.expiresAt {
          let dateFormatter = ISO8601DateFormatter()
          expiresAtDate = ATProtocolDate(iso8601String: dateFormatter.string(from: expires))
        }

        return AppBskyActorDefs.Nux(
          id: nux.id,
          completed: nux.completed,
          data: nux.data,
          expiresAt: expiresAtDate
        )
      }

      allPrefItems.append(
        .bskyAppStatePref(
          AppBskyActorDefs.BskyAppStatePref(
            activeProgressGuide: progressGuide,
            queuedNudges: prefsToSync.queuedNudges.isEmpty ? nil : prefsToSync.queuedNudges,
            nuxs: nuxItems.isEmpty ? nil : nuxItems
          )))
    }

    // 11. Add interests if present
    if !prefsToSync.interests.isEmpty {
      allPrefItems.append(
        .interestsPref(AppBskyActorDefs.InterestsPref(tags: prefsToSync.interests)))
    }

    // Create the final preferences object and send to server
    let apiPreferences = AppBskyActorDefs.Preferences(items: allPrefItems)
    let input = AppBskyActorPutPreferences.Input(preferences: apiPreferences)

    // Send to server
    let responseCode = try await client.app.bsky.actor.putPreferences(input: input)

    if responseCode != 200 {
      logger.error("Failed to sync preferences to server, response code: \(responseCode)")
      throw NSError(
        domain: "Preferences", code: responseCode,
        userInfo: [NSLocalizedDescriptionKey: "Server returned error code \(responseCode)"])
    }

    logger.info("Successfully synced all preferences to server")
  }

  // MARK: - Convenience Methods for All Preference Types

  @MainActor
  func setContentLabelVisibility(label: String, visibility: String, labelerDid: DID? = nil)
    async throws {
    let preferences = try await getPreferences()
    preferences.setContentLabelVisibility(
      for: label, visibility: visibility, labelerDid: labelerDid)
    try await saveAndSyncPreferences(preferences)
  }

  @MainActor
  func setAdultContentEnabled(_ enabled: Bool) async throws {
    let preferences = try await getPreferences()
    preferences.adultContentEnabled = enabled
    try await saveAndSyncPreferences(preferences)
  }

  @MainActor
  func setBirthDate(_ date: Date) async throws {
    let preferences = try await getPreferences()
    preferences.birthDate = date
    try await saveAndSyncPreferences(preferences)
  }

  @MainActor
  func setThreadViewPreferences(sort: String? = nil, prioritizeFollowedUsers: Bool? = nil)
    async throws {
    let preferences = try await getPreferences()

    // Get existing or create new
    var threadPref =
      preferences.threadViewPref ?? ThreadViewPreference(sort: nil, prioritizeFollowedUsers: nil)

    // Update only provided values
    if let sort = sort {
      threadPref = ThreadViewPreference(
        sort: sort,
        prioritizeFollowedUsers: threadPref.prioritizeFollowedUsers
      )
    }

    if let prioritize = prioritizeFollowedUsers {
      threadPref = ThreadViewPreference(
        sort: threadPref.sort,
        prioritizeFollowedUsers: prioritize
      )
    }

    preferences.threadViewPref = threadPref
    try await saveAndSyncPreferences(preferences)
  }

  @MainActor
  func setFeedViewPreferences(
    hideReplies: Bool? = nil,
    hideRepliesByUnfollowed: Bool? = nil,
    hideRepliesByLikeCount: Int? = nil,
    hideReposts: Bool? = nil,
    hideQuotePosts: Bool? = nil
  ) async throws {
    let preferences = try await getPreferences()

    // Get existing or create new
    var feedPref =
      preferences.feedViewPref
      ?? FeedViewPreference(
        hideReplies: nil,
        hideRepliesByUnfollowed: nil,
        hideRepliesByLikeCount: nil,
        hideReposts: nil,
        hideQuotePosts: nil
      )

    // Only update provided values
    feedPref = FeedViewPreference(
      hideReplies: hideReplies ?? feedPref.hideReplies,
      hideRepliesByUnfollowed: hideRepliesByUnfollowed ?? feedPref.hideRepliesByUnfollowed,
      hideRepliesByLikeCount: hideRepliesByLikeCount ?? feedPref.hideRepliesByLikeCount,
      hideReposts: hideReposts ?? feedPref.hideReposts,
      hideQuotePosts: hideQuotePosts ?? feedPref.hideQuotePosts
    )

    preferences.feedViewPref = feedPref
    try await saveAndSyncPreferences(preferences)
  }

  @MainActor
  func addMutedWord(
    word: String,
    targets: [String],
    actorTarget: String? = nil,
    expiresAt: Date? = nil
  ) async throws {
    let preferences = try await getPreferences()
    preferences.addMutedWord(word, targets: targets, actorTarget: actorTarget, expiresAt: expiresAt)
    try await saveAndSyncPreferences(preferences)
  }

  @MainActor
  func removeMutedWord(id: String) async throws {
    let preferences = try await getPreferences()
    preferences.removeMutedWord(id: id)
    try await saveAndSyncPreferences(preferences)
  }

  @MainActor
  func hidePost(_ uri: String) async throws {
    let preferences = try await getPreferences()
    preferences.hidePost(uri)
    try await saveAndSyncPreferences(preferences)
  }

  @MainActor
  func unhidePost(_ uri: String) async throws {
    let preferences = try await getPreferences()
    preferences.unhidePost(uri)
    try await saveAndSyncPreferences(preferences)
  }

  @MainActor
  func addLabeler(_ did: DID) async throws {
    let preferences = try await getPreferences()
    preferences.addLabeler(did)
    try await saveAndSyncPreferences(preferences)
  }

  @MainActor
  func removeLabeler(_ did: DID) async throws {
    let preferences = try await getPreferences()
    preferences.removeLabeler(did)
    try await saveAndSyncPreferences(preferences)
  }

  @MainActor
  func setNuxCompleted(_ id: String, completed: Bool = true) async throws {
    let preferences = try await getPreferences()
    preferences.setNuxCompleted(id, completed: completed)
    try await saveAndSyncPreferences(preferences)
  }

  @MainActor
  func setActiveProgressGuide(_ guide: String?) async throws {
    let preferences = try await getPreferences()
    preferences.activeProgressGuide = guide
    try await saveAndSyncPreferences(preferences)
  }

  @MainActor
  func addInterest(_ tag: String) async throws {
    let preferences = try await getPreferences()
    if !preferences.interests.contains(tag) {
      preferences.interests.append(tag)
      try await saveAndSyncPreferences(preferences)
    }
  }

  @MainActor
  func removeInterest(_ tag: String) async throws {
    let preferences = try await getPreferences()
    preferences.interests.removeAll { $0 == tag }
    try await saveAndSyncPreferences(preferences)
  }

  /// Updates the entire list of user interests and syncs with server
  @MainActor
  func updateInterests(_ interests: [String]) async throws {
    let preferences = try await getPreferences()
    preferences.interests = interests
    try await saveAndSyncPreferences(preferences)
  }

  /// Updates specific preferences with server-first approach for better safety
  @MainActor
  func updateSpecificPreferences<T>(
    preferenceType: String,
    update: @escaping (T?) -> T?
  ) async throws where T: Codable {
    // Get current server preferences
    guard let client = client else {
      throw PreferencesManagerError.clientNotInitialized
    }

    let params = AppBskyActorGetPreferences.Parameters()
    let serverPrefs = try await client.app.bsky.actor.getPreferences(input: params)

    // Keep all existing preferences
    var allPrefs = serverPrefs.data?.preferences.items ?? []

    // Find existing preference of this type
    var existingIndex: Int?
    var existingValue: T?

    for (index, pref) in allPrefs.enumerated() {
      // Check if this is the preference type we're looking for
      switch (preferenceType, pref) {
      case ("savedFeeds", .savedFeedsPrefV2(let value)):
        if T.self == [AppBskyActorDefs.SavedFeed].self {
          existingIndex = index
          existingValue = value.items as? T
        }
      case ("adultContent", .adultContentPref(let value)):
        if T.self == Bool.self {
          existingIndex = index
          existingValue = value.enabled as? T
        }
      case ("contentLabels", .contentLabelPref):
        if T.self == [AppBskyActorDefs.ContentLabelPref].self {
          // For content labels, we need to collect all of them
          if existingIndex == nil {
            existingIndex = index
            existingValue = [] as? T
          }
          // We'll handle this collection separately
        }
      case ("threadView", .threadViewPref(let value)):
        if T.self == AppBskyActorDefs.ThreadViewPref.self {
          existingIndex = index
          existingValue = value as? T
        }
      case ("feedView", .feedViewPref(let value)):
        if T.self == AppBskyActorDefs.FeedViewPref.self {
          existingIndex = index
          existingValue = value as? T
        }
      case ("mutedWords", .mutedWordsPref(let value)):
        if T.self == [AppBskyActorDefs.MutedWord].self {
          existingIndex = index
          existingValue = value.items as? T
        }
      case ("hiddenPosts", .hiddenPostsPref(let value)):
        if T.self == [ATProtocolURI].self {
          existingIndex = index
          existingValue = value.items as? T
        }
      case ("labelers", .labelersPref(let value)):
        if T.self == [AppBskyActorDefs.LabelerPrefItem].self {
          existingIndex = index
          existingValue = value.labelers as? T
        }
      case ("interests", .interestsPref(let value)):
        if T.self == [String].self {
          existingIndex = index
          existingValue = value.tags as? T
        }
      default:
        break
      }
    }

    // Update the preference
    if let updatedValue = update(existingValue) {
      // Create new preference with updated value
      var newPref: AppBskyActorDefs.PreferencesForUnionArray?

      switch preferenceType {
      case "savedFeeds":
        if let feeds = updatedValue as? [AppBskyActorDefs.SavedFeed] {
          newPref = .savedFeedsPrefV2(AppBskyActorDefs.SavedFeedsPrefV2(items: feeds))
        } else {
          throw PreferencesManagerError.invalidData
        }

      case "adultContent":
        if let enabled = updatedValue as? Bool {
          newPref = .adultContentPref(AppBskyActorDefs.AdultContentPref(enabled: enabled))
        } else {
          throw PreferencesManagerError.invalidData
        }

      case "contentLabels":
        if let labels = updatedValue as? [AppBskyActorDefs.ContentLabelPref] {
          // For content labels, we need to handle differently since there's one per label
          // Remove all existing content labels
          allPrefs.removeAll { item in
            if case .contentLabelPref = item {
              return true
            }
            return false
          }

          // Add all updated labels
          for label in labels {
            allPrefs.append(.contentLabelPref(label))
          }

          // Skip the normal append/replace logic
          existingIndex = nil
        } else {
          throw PreferencesManagerError.invalidData
        }

      case "threadView":
        if let threadPref = updatedValue as? AppBskyActorDefs.ThreadViewPref {
          newPref = .threadViewPref(threadPref)
        } else {
          throw PreferencesManagerError.invalidData
        }

      case "feedView":
        if let feedPref = updatedValue as? AppBskyActorDefs.FeedViewPref {
          newPref = .feedViewPref(feedPref)
        } else {
          throw PreferencesManagerError.invalidData
        }

      case "mutedWords":
        if let words = updatedValue as? [AppBskyActorDefs.MutedWord] {
          newPref = .mutedWordsPref(AppBskyActorDefs.MutedWordsPref(items: words))
        } else {
          throw PreferencesManagerError.invalidData
        }

      case "hiddenPosts":
        if let posts = updatedValue as? [ATProtocolURI] {
          newPref = .hiddenPostsPref(AppBskyActorDefs.HiddenPostsPref(items: posts))
        } else {
          throw PreferencesManagerError.invalidData
        }

      case "labelers":
        if let labelers = updatedValue as? [AppBskyActorDefs.LabelerPrefItem] {
          newPref = .labelersPref(AppBskyActorDefs.LabelersPref(labelers: labelers))
        } else {
          throw PreferencesManagerError.invalidData
        }

      case "interests":
        if let tags = updatedValue as? [String] {
          newPref = .interestsPref(AppBskyActorDefs.InterestsPref(tags: tags))
        } else {
          throw PreferencesManagerError.invalidData
        }

      default:
        throw PreferencesManagerError.invalidData
      }

      // Replace or add the preference if it was created
      if let newPref = newPref {
        if let idx = existingIndex, preferenceType != "contentLabels" {
          allPrefs[idx] = newPref
        } else if preferenceType != "contentLabels" {
          allPrefs.append(newPref)
        }
      }

      // Send to server
      let apiPreferences = AppBskyActorDefs.Preferences(items: allPrefs)
      let input = AppBskyActorPutPreferences.Input(preferences: apiPreferences)

      let responseCode = try await client.app.bsky.actor.putPreferences(input: input)

      if responseCode != 200 {
        throw NSError(
          domain: "Preferences", code: responseCode,
          userInfo: [NSLocalizedDescriptionKey: "Server returned error code \(responseCode)"])
      }

      // Only update local model after successful server update
      let localPrefs = try await getPreferences()

      // Update local preferences based on type
      switch preferenceType {
      case "savedFeeds":
        if let feeds = updatedValue as? [AppBskyActorDefs.SavedFeed] {
          let pinnedFeeds = feeds.filter { $0.pinned }.map { $0.value }
          let savedFeeds = feeds.filter { !$0.pinned }.map { $0.value }
          localPrefs.updateFeeds(pinned: pinnedFeeds, saved: savedFeeds)
        }

      case "adultContent":
        if let enabled = updatedValue as? Bool {
          localPrefs.adultContentEnabled = enabled
        }

      case "contentLabels":
        if let labels = updatedValue as? [AppBskyActorDefs.ContentLabelPref] {
          localPrefs.contentLabelPrefs = labels.map {
            ContentLabelPreference(
              labelerDid: $0.labelerDid,
              label: $0.label,
              visibility: $0.visibility
            )
          }
        }

      case "threadView":
        if let pref = updatedValue as? AppBskyActorDefs.ThreadViewPref {
          localPrefs.threadViewPref = ThreadViewPreference(
            sort: pref.sort,
            prioritizeFollowedUsers: pref.prioritizeFollowedUsers
          )
        }

      case "feedView":
        if let pref = updatedValue as? AppBskyActorDefs.FeedViewPref {
          localPrefs.feedViewPref = FeedViewPreference(
            hideReplies: pref.hideReplies,
            hideRepliesByUnfollowed: pref.hideRepliesByUnfollowed,
            hideRepliesByLikeCount: pref.hideRepliesByLikeCount,
            hideReposts: pref.hideReposts,
            hideQuotePosts: pref.hideQuotePosts
          )
        }

      case "mutedWords":
        if let words = updatedValue as? [AppBskyActorDefs.MutedWord] {
          localPrefs.mutedWords = words.map { word in
            MutedWord(
              id: word.id ?? "",
              value: word.value,
              targets: word.targets.map { $0.rawValue },
              actorTarget: word.actorTarget,
              expiresAt: word.expiresAt?.date
            )
          }
        }

      case "hiddenPosts":
        if let posts = updatedValue as? [ATProtocolURI] {
          localPrefs.hiddenPosts = posts.map { $0.uriString() }
        }

      case "labelers":
        if let labelers = updatedValue as? [AppBskyActorDefs.LabelerPrefItem] {
          localPrefs.labelers = labelers.map { LabelerPreference(did: $0.did) }
        }

      case "interests":
        if let tags = updatedValue as? [String] {
          localPrefs.interests = tags
        }

      default:
        break
      }

      try await savePreferences(localPrefs)
    }
  }

  /// Repairs preferences by ensuring all data is valid and complete
  @MainActor
  func repairPreferences() async throws {
    // Get current server preferences
    guard let client = client else {
      throw PreferencesManagerError.clientNotInitialized
    }

    let params = AppBskyActorGetPreferences.Parameters()
    let serverPrefs = try await client.app.bsky.actor.getPreferences(input: params)

    // Load local preferences
    let localPrefs = try await getPreferences()
    var needsSync = false

    // Process server preferences to extract all feeds
    var pinnedFeeds: [String] = []
    var savedFeeds: [String] = []

    for pref in serverPrefs.data?.preferences.items ?? [] {
      switch pref {
      case .savedFeedsPrefV2(let value):
        // Extract feeds from V2 format
        pinnedFeeds = value.items.filter { $0.pinned }.map { $0.value }
        savedFeeds = value.items.filter { !$0.pinned }.map { $0.value }

        // Only add "following" if it's missing
        if !pinnedFeeds.contains(where: { SystemFeedTypes.isTimelineFeed($0) }) {
          pinnedFeeds.insert(SystemFeedTypes.following, at: 0)
          needsSync = true
          logger.warning("Repair needed: Timeline feed missing from pinned feeds")
        }

        // If we have server feeds but local feeds are empty or different, update local
        if (!pinnedFeeds.isEmpty || !savedFeeds.isEmpty)
          && (localPrefs.pinnedFeeds.count <= 1 || localPrefs.savedFeeds.isEmpty) {
          localPrefs.updateFeeds(pinned: pinnedFeeds, saved: savedFeeds)
          needsSync = true
          logger.info("Updating local feeds with server data")
        }

      default:
        break
      }
    }

    // If any changes were made, sync them
    if needsSync {
      try await savePreferences(localPrefs)
      logger.info("Preferences repaired successfully")
    } else {
      logger.info("No preference repairs needed")
    }
  }

  /// Validates preferences before saving
  private func validatePreferences(_ preferences: Preferences) throws {
    // Validate feeds
    guard !preferences.pinnedFeeds.isEmpty else {
      throw PreferencesManagerError.invalidData
    }

    // Validate content label preferences
    for pref in preferences.contentLabelPrefs {
      guard !pref.label.isEmpty, pref.labelerDid != nil else {
        throw PreferencesManagerError.invalidData
      }
    }

    // Validate muted words
    for word in preferences.mutedWords {
      guard !word.value.isEmpty else {
        throw PreferencesManagerError.invalidData
      }
    }
  }

  // MARK: - SwiftData Backup/Restore

  /// Backup preferences to a file using SwiftData export
  @MainActor
  func backupPreferences(to url: URL) async throws {
    guard let modelContext = modelContext else {
      throw PreferencesManagerError.modelContextNotInitialized
    }

    // Use SwiftData's persistence mechanism
    let descriptor = FetchDescriptor<Preferences>()
    let preferences = try modelContext.fetch(descriptor)

    guard let prefs = preferences.first else {
      throw PreferencesManagerError.backupFailed
    }

    // We need to create a serializable representation
    // This is a simplification - you would need custom serialization
    // since Preferences is a SwiftData model and not directly Encodable
    let backup: [String: Any] = [
      "pinnedFeeds": prefs.pinnedFeeds,
      "savedFeeds": prefs.savedFeeds,
      "contentLabelPrefs": prefs.contentLabelPrefs,
      "adultContentEnabled": prefs.adultContentEnabled
      // Add other properties as needed
    ]

    // Convert to JSON data
      let jsonData = try JSONSerialization.data(withJSONObject: backup, options: .prettyPrinted)
    try jsonData.write(to: url)
  }

  /// Restore preferences from a backup file
  @MainActor
  func restorePreferences(from url: URL) async throws {
    guard let modelContext = modelContext else {
      throw PreferencesManagerError.modelContextNotInitialized
    }

    let data = try Data(contentsOf: url)
    guard let backup = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw PreferencesManagerError.restoreFailed
    }

    // Get current preferences or create new
    let preferences = try await getPreferences()

    // Update properties from backup
    if let pinnedFeeds = backup["pinnedFeeds"] as? [String] {
      preferences.pinnedFeeds = pinnedFeeds
    }

    if let savedFeeds = backup["savedFeeds"] as? [String] {
      preferences.savedFeeds = savedFeeds
    }

    // You would need to handle more complex types like contentLabelPrefs
    // This is just a simplified example

    if let adultContentEnabled = backup["adultContentEnabled"] as? Bool {
      preferences.adultContentEnabled = adultContentEnabled
    }

    // Validate and save
    try validatePreferences(preferences)
    try await saveAndSyncPreferences(preferences)
  }

  /// Add the missing updatePreference function
  @MainActor
  func updatePreference<T: Codable>(_ preferenceType: String, update: @escaping (T?) -> T?)
    async throws {
    return try await updateSpecificPreferences(preferenceType: preferenceType, update: update)
  }

  /// Sets the entire list of pinned feeds and syncs changes.
  @MainActor
  func setPinnedFeeds(_ newOrder: [String]) async throws {
    guard modelContext != nil else {
      logger.error("ModelContext not available for setPinnedFeeds")
      throw PreferencesManagerError.modelContextNotInitialized
    }

    let preferences = try await getPreferences()

    // Ensure timeline feed is present before setting
    var finalOrder = newOrder
    if !finalOrder.contains(where: { SystemFeedTypes.isTimelineFeed($0) }) {
      // Add default timeline if missing
      finalOrder.insert(SystemFeedTypes.following, at: 0)  // Or restore saved position if needed
      logger.warning("Timeline feed was missing in setPinnedFeeds input, added default at front.")
    }

    preferences.pinnedFeeds = finalOrder
    logger.debug("Setting pinned feeds to: \(finalOrder)")
    try await saveAndSyncPreferences(preferences)
    logger.info("Successfully set and synced pinned feeds.")
  }

  /// Sets the entire list of saved feeds and syncs changes.
  @MainActor
  func setSavedFeeds(_ newOrder: [String]) async throws {
    guard modelContext != nil else {
      logger.error("ModelContext not available for setSavedFeeds")
      throw PreferencesManagerError.modelContextNotInitialized
    }

    let preferences = try await getPreferences()
    // Ensure saved feeds don't contain pinned feeds
    let pinnedSet = Set(preferences.pinnedFeeds)
    preferences.savedFeeds = newOrder.filter { !pinnedSet.contains($0) }
    logger.debug("Setting saved feeds to: \(preferences.savedFeeds)")
    try await saveAndSyncPreferences(preferences)
    logger.info("Successfully set and synced saved feeds.")
  }

  /// Synchronizes preferences with app settings to ensure consistency
  @MainActor
  func syncPreferencesWithAppSettings(_ appState: AppState) async throws {
    let preferences = try await getPreferences()

    // Update app settings from server preferences

    // Adult content setting
    appState.isAdultContentEnabled = preferences.adultContentEnabled
    UserDefaults(suiteName: "group.blue.catbird.shared")?.set(preferences.adultContentEnabled, forKey: "isAdultContentEnabled")

    // Thread view preferences
    if let threadViewPref = preferences.threadViewPref {
      appState.appSettings.threadSortOrder = threadViewPref.sort ?? "hot"
      appState.appSettings.prioritizeFollowedUsers = threadViewPref.prioritizeFollowedUsers ?? true
    }

    // Feed view preferences - these don't directly map to app settings

    logger.info("Synchronized preferences with app settings")
  }

  /// Updates adult content setting and syncs to server
  @MainActor
  func updateAdultContentEnabled(_ enabled: Bool) async throws {
    let preferences = try await getPreferences()
    preferences.adultContentEnabled = enabled

    // Also update the app state's copy for consistency
    UserDefaults(suiteName: "group.blue.catbird.shared")?.set(enabled, forKey: "isAdultContentEnabled")

    try await saveAndSyncPreferences(preferences)
  }

  /// Updates content label preferences and syncs to server
  @MainActor
  func updateContentLabelPreferences(_ contentLabels: [ContentLabelPreference]) async throws {
    let preferences = try await getPreferences()
    preferences.contentLabelPrefs = contentLabels
    try await saveAndSyncPreferences(preferences)
  }
  
  /// Updates language preferences and syncs with server
  @MainActor
  func updateLanguagePreferences(appLanguage: String?, primaryLanguage: String, contentLanguages: [String]) async throws {
    // Store in UserDefaults for immediate persistence
    let defaults = UserDefaults(suiteName: "group.blue.catbird.shared")
    
    // Save app language (local only)
    if let appLang = appLanguage {
      defaults?.set(appLang, forKey: "appLanguage")
    } else {
      defaults?.removeObject(forKey: "appLanguage")
    }
    
    // Save primary language
    defaults?.set(primaryLanguage, forKey: "primaryLanguage")
    
    // Save content languages
    defaults?.set(contentLanguages, forKey: "contentLanguages")
    
    // Also save preferred languages for post composer
    defaults?.set(contentLanguages, forKey: "userPreferredLanguages")
    
    // Sync language preferences with server if client is available
    if let client = client {
      do {
        // Get current preferences
        let preferences = try await getPreferences()
        
        // Update language-related preferences
        // In AT Protocol, language preferences are stored as content filters
        // We'll create a custom preference type for language preferences
        preferences.primaryLanguage = primaryLanguage
        preferences.contentLanguages = contentLanguages
        
        // Save and sync to server
        try await saveAndSyncPreferences(preferences)
        
        logger.info("Language preferences synced to server - Primary: \(primaryLanguage), Content: \(contentLanguages.joined(separator: ", "))")
      } catch {
        logger.error("Failed to sync language preferences to server: \(error.localizedDescription)")
        // Don't throw the error, as local storage succeeded
      }
    } else {
      logger.warning("No client available - language preferences stored locally only")
    }
    
    logger.info("Language preferences updated - App: \(appLanguage ?? "system"), Primary: \(primaryLanguage), Content: \(contentLanguages.joined(separator: ", "))")
    
    // Notify state invalidation to refresh feeds with new language filters
    // This will be picked up by feeds to filter content appropriately
    NotificationCenter.default.post(name: NSNotification.Name("LanguagePreferencesChanged"), object: nil)
  }

  /// Updates feed view preference and syncs to server
  @MainActor
  func updateFeedViewPreference(_ feedViewPref: FeedViewPreference) async throws {
    let preferences = try await getPreferences()
    preferences.feedViewPref = feedViewPref
    try await saveAndSyncPreferences(preferences)
  }

  // Helper to compare relevant parts of preferences for caching logic
  private func arePreferencesSemanticallyEqual(_ pref1: Preferences, _ pref2: Preferences) -> Bool {
    // Compare feed orders and other critical settings if needed
    return pref1.pinnedFeeds == pref2.pinnedFeeds && pref1.savedFeeds == pref2.savedFeeds
    // Add comparisons for other prefs if necessary
  }
}

/// Errors specific to preferences management
enum PreferencesManagerError: Error, LocalizedError {
  case invalidData
  case clientNotInitialized
  case modelContextNotInitialized
  case backupFailed
  case restoreFailed

  var errorDescription: String? {
    switch self {
    case .invalidData:
      return "Invalid or missing preferences data"
    case .clientNotInitialized:
      return "AT Protocol client not initialized"
    case .modelContextNotInitialized:
      return "SwiftData model context not initialized"
    case .backupFailed:
      return "Failed to backup preferences"
    case .restoreFailed:
      return "Failed to restore preferences from backup"
    }
  }
}
