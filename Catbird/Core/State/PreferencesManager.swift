import Foundation
import OSLog
import Petrel
import SwiftData
import SwiftUI
import OrderedCollections

/// Manages user preferences with proper state management and persistence
@Observable
final class PreferencesManager {
  static let acceptLabelersHeaderDidChange = Notification.Name("CatbirdAcceptLabelersHeaderDidChange")

  // MARK: - Properties

  private let logger = Logger(subsystem: "blue.catbird", category: "PreferencesManager")
  private let sharedDefaults: UserDefaults

  // Add cache for server preferences to maintain consistency
  private var cachedServerPreferences: Preferences?
  private var feedLibraryWriteRevision: UInt64 = 0
  /// Nil until this account's accepted-labeler header has finished applying to its current client.
  @MainActor private(set) var appliedAcceptLabelerDIDs: [String]?
  @MainActor private var labelerHeaderGeneration = 0

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

  // Centralized verification badge visibility observable
  @MainActor var hideVerificationBadges: Bool = false

  // Per-account scoping
  private(set) var accountDID: String = ""
  // Core dependencies
  private weak var client: ATProtoClient?
  private var modelContext: ModelContext?

  /// Injectable I/O for focused preference edits; production uses the account's ATProto client.
  struct SpecificPreferencesTransport {
    let getPreferences: @MainActor () async throws -> [AppBskyActorDefs.PreferencesForUnionArray]
    let putPreferences: @MainActor ([AppBskyActorDefs.PreferencesForUnionArray]) async throws -> Int
  }
  private let specificPreferencesTransport: SpecificPreferencesTransport?
  @MainActor private var preferenceSessionGeneration: UInt64 = 0
  @MainActor private var specificEditInProgress = false
  @MainActor private var specificEditWaiters: [CheckedContinuation<Void, Never>] = []

  private struct PreferenceOperationContext {
    let accountDID: String
    let generation: UInt64
    let client: ATProtoClient?
  }

  @MainActor
  private func capturePreferenceOperation(expectedAccountDID: String? = nil) throws -> PreferenceOperationContext {
    guard !accountDID.isEmpty, expectedAccountDID == nil || expectedAccountDID == accountDID else {
      throw PreferencesManagerError.accountChanged
    }
    guard client != nil || specificPreferencesTransport != nil else {
      throw PreferencesManagerError.clientNotInitialized
    }
    guard modelContext != nil else { throw PreferencesManagerError.modelContextNotInitialized }
    return PreferenceOperationContext(accountDID: accountDID, generation: preferenceSessionGeneration, client: client)
  }

  @MainActor
  private func validatePreferenceOperation(_ operation: PreferenceOperationContext) throws {
    guard accountDID == operation.accountDID, preferenceSessionGeneration == operation.generation,
          client === operation.client else { throw PreferencesManagerError.accountChanged }
    try Task.checkCancellation()
  }

  @MainActor
  private func acquireSpecificEdit() async {
    if specificEditInProgress {
      await withCheckedContinuation { specificEditWaiters.append($0) }
    } else {
      specificEditInProgress = true
    }
  }

  @MainActor
  private func releaseSpecificEdit() {
    if specificEditWaiters.isEmpty {
      specificEditInProgress = false
    } else {
      specificEditWaiters.removeFirst().resume()
    }
  }

  @MainActor
  private func readSpecificPreferenceItems(_ operation: PreferenceOperationContext) async throws -> [AppBskyActorDefs.PreferencesForUnionArray] {
    try validatePreferenceOperation(operation)
    let items: [AppBskyActorDefs.PreferencesForUnionArray]
    if let transport = specificPreferencesTransport {
      items = try await transport.getPreferences()
    } else {
      guard let client = operation.client else { throw PreferencesManagerError.clientNotInitialized }
      let response = try await client.app.bsky.actor.getPreferences(input: .init())
      guard response.responseCode >= 200 && response.responseCode < 300,
            let fetched = response.data?.preferences.items else { throw PreferencesManagerError.invalidData }
      items = fetched
    }
    try validatePreferenceOperation(operation)
    return items
  }

  /// AppState supplies the account-service admission boundary. Fixtures can omit it.
  @MainActor var beginSettingsAccountOperation: (() -> UUID?)?
  @MainActor var endSettingsAccountOperation: ((UUID) -> Void)?

  @MainActor
  func beginSettingsAccountIO() throws -> (() -> Void)? {
    guard let begin = beginSettingsAccountOperation else { return nil }
    guard let end = endSettingsAccountOperation, let token = begin() else {
      throw PreferencesManagerError.accountChanged
    }
    // Capture the matching completion hook before any suspension.
    return { end(token) }
  }

  // MARK: - Initialization

  init(
    client: ATProtoClient? = nil,
    modelContext: ModelContext? = nil,
    specificPreferencesTransport: SpecificPreferencesTransport? = nil,
    sharedDefaults: UserDefaults? = nil
  ) {
    self.specificPreferencesTransport = specificPreferencesTransport
    self.sharedDefaults = sharedDefaults ?? UserDefaults(suiteName: "group.blue.catbird.shared") ?? .standard
    self.client = client
    self.modelContext = modelContext
    logger.debug("PreferencesManager initialized")
  }

  /// Update client reference when it changes
  @MainActor
  func updateClient(_ client: ATProtoClient?) {
    preferenceSessionGeneration &+= 1
    self.client = client
    appliedAcceptLabelerDIDs = nil
    labelerHeaderGeneration += 1

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

  /// Configure the manager for a specific account
  @MainActor
  func configure(accountDID: String) {
    preferenceSessionGeneration &+= 1
    self.accountDID = accountDID
    appliedAcceptLabelerDIDs = nil
    labelerHeaderGeneration += 1
    // Clear cache so next fetch loads the correct account's data
    cachedServerPreferences = nil
    logger.debug("PreferencesManager configured for account: \(accountDID)")
    let generation = preferenceSessionGeneration
    Task { @MainActor [weak self] in
      guard let self, self.accountDID == accountDID, self.preferenceSessionGeneration == generation else { return }
      let prefs = try? await self.loadPreferences()
      guard self.accountDID == accountDID, self.preferenceSessionGeneration == generation else { return }
      self.hideVerificationBadges = prefs?.hideVerificationBadges ?? false
    }
  }

  private func scopedKey(_ baseKey: String) -> String {
    AppSettingsModel.scopedKey(baseKey, accountDID: accountDID)
  }

  private func scopedPreferencesFetchDescriptor() -> FetchDescriptor<Preferences> {
    let did = self.accountDID
    return FetchDescriptor<Preferences>(
      predicate: #Predicate<Preferences> { $0.accountDID == did }
    )
  }

  private func migrateLegacyPreferencesIfNeeded(in modelContext: ModelContext) throws -> Preferences? {
    guard !accountDID.isEmpty else { return nil }

    if let scoped = try modelContext.fetch(scopedPreferencesFetchDescriptor()).first {
      return scoped
    }

    let legacyDescriptor = FetchDescriptor<Preferences>(
      predicate: #Predicate<Preferences> { $0.accountDID.isEmpty }
    )
    guard let legacy = try modelContext.fetch(legacyDescriptor).first else {
      return nil
    }

    let accountRowDescriptor = FetchDescriptor<Preferences>(
      predicate: #Predicate<Preferences> { !$0.accountDID.isEmpty }
    )
    let existingAccountRows = try modelContext.fetch(accountRowDescriptor)

    guard existingAccountRows.isEmpty else {
      logger.debug("Leaving legacy preferences row in place because per-account preferences already exist")
      return nil
    }

    legacy.accountDID = accountDID
    try modelContext.save()
    logger.debug("Migrated legacy preferences row to account \(self.accountDID)")
    return legacy
  }

  // MARK: - Clear Preferences

  /// Clears local preferences for the current account when logging out
  @MainActor
  func clearAllPreferences() async {
    logger.info("Clearing preferences for current account due to logout")

    // Invalidate in-flight account operations before any row is deleted.
    preferenceSessionGeneration &+= 1
    let clearingGeneration = preferenceSessionGeneration
    let clearingAccount = accountDID
    let clearingClient = client
    // Clear cached server preferences
    cachedServerPreferences = nil

    // Reset state
    appliedAcceptLabelerDIDs = nil
    labelerHeaderGeneration += 1
    state = .initializing

    guard let modelContext = modelContext else {
      logger.warning("ModelContext not available when trying to clear preferences")
      return
    }

    do {
      let preferences = try modelContext.fetch(scopedPreferencesFetchDescriptor())

      // Delete current account's preferences
      for pref in preferences {
        modelContext.delete(pref)
      }

      // Save changes
      try modelContext.save()

      logger.info("Preferences for current account successfully cleared")
      state = .ready
      // Also clear accept-labelers header since there are no preferences
      if let clearingClient {
        guard preferenceSessionGeneration == clearingGeneration, accountDID == clearingAccount, client === clearingClient else { return }
        await clearingClient.setAcceptLabelers(dids: [])
      }
    } catch {
      logger.error("Failed to clear preferences: \(error.localizedDescription)")
      state = .error("Failed to clear preferences: \(error.localizedDescription)")
    }
  }

  // MARK: - Preferences Management

  /// Fetches preferences from server if needed
  @MainActor
  func fetchPreferences(forceRefresh: Bool = false) async throws {
    let operation = PreferenceOperationContext(accountDID: accountDID, generation: preferenceSessionGeneration, client: client)
    // Start with setting state
    state = .loading

    // Check if client exists before proceeding
    guard client != nil || specificPreferencesTransport != nil else {
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

    let finishAccountIO = try beginSettingsAccountIO()
    defer { finishAccountIO?() }
    await acquireSpecificEdit()
    defer { releaseSpecificEdit() }
    try validatePreferenceOperation(operation)

    do {
      // Try to load from SwiftData first
      let localPreferences = try await loadPreferences()
      try validatePreferenceOperation(operation)

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
      let feedRevisionAtRequest = feedLibraryWriteRevision
      let resultItems = try await readSpecificPreferenceItems(operation)

      // Process all preference types from server
      var serverSavedFeeds: [String] = []
      var serverPinnedFeeds: [String] = []
      var serverContentLabelPrefs: [ContentLabelPreference] = []
      var serverThreadViewPref: ThreadViewPreference?
      var serverFeedViewPref: FeedViewPreference?
      var serverAdultContentEnabled: Bool = false
      var serverMutedWords: [MutedWord] = []
      var serverHiddenPosts: [String] = []
      var serverLabelers: [LabelerPreference] = []
      var serverActiveProgressGuide: String?
      var serverQueuedNudges: [String] = []
      var serverNuxStates: [NuxState] = []
      var serverInterests: [String] = []
      var serverPostInteractionSettingsPref: AppBskyActorDefs.PostInteractionSettingsPref?
      var serverVerificationPrefs: AppBskyActorDefs.VerificationPrefs?
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

        case .threadViewPref(let value):
          serverThreadViewPref = ThreadViewPreference(
            sort: value.sort,
            prioritizeFollowedUsers: localPreferences?.threadViewPref?.prioritizeFollowedUsers
          )

        case .feedViewPref(let value):
          guard value.feed == "home" else { continue }
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
        case .postInteractionSettingsPref(let value):
          serverPostInteractionSettingsPref = value
        case .verificationPrefs(let value):
          serverVerificationPrefs = value
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
      try validatePreferenceOperation(operation)

      // Keep unsynchronized URI intents when a refresh returns older server membership.
      FeedLibraryPendingStore().reconcile(
        accountDID: accountDID, pinned: &serverPinnedFeeds, saved: &serverSavedFeeds)
      // Update feeds using the robust updateFeeds method
      if feedRevisionAtRequest == feedLibraryWriteRevision {
        currentPrefs.updateFeeds(pinned: serverPinnedFeeds, saved: serverSavedFeeds)
      }
      // A discovery write started or finished during this fetch: retain its newer
      // local feed lists, while still refreshing the unrelated preferences below.

      let beforeRefresh = currentPrefs.detachedSnapshot()
      // Update other preferences directly
      currentPrefs.contentLabelPrefs = serverContentLabelPrefs
      currentPrefs.threadViewPref = serverThreadViewPref
      currentPrefs.feedViewPref = serverFeedViewPref
      currentPrefs.adultContentEnabled = serverAdultContentEnabled
      currentPrefs.mutedWords = serverMutedWords
      currentPrefs.hiddenPosts = serverHiddenPosts
      currentPrefs.labelers = serverLabelers
      currentPrefs.activeProgressGuide = serverActiveProgressGuide
      currentPrefs.queuedNudges = serverQueuedNudges
      currentPrefs.nuxStates = serverNuxStates
      currentPrefs.interests = serverInterests
      currentPrefs.postInteractionSettingsPref = serverPostInteractionSettingsPref
      currentPrefs.verificationPrefs = serverVerificationPrefs
      currentPrefs.hideVerificationBadges = serverVerificationPrefs?.hideBadges ?? false
      currentPrefs.hasConfirmedServerPreferences = true
      // Save before publishing derived state; a local failure retains prior values.
      do { try await savePreferences(currentPrefs) }
      catch { currentPrefs.restoreValues(from: beforeRefresh); cachedServerPreferences = nil; throw error }
      self.hideVerificationBadges = serverVerificationPrefs?.hideBadges ?? false
      try validatePreferenceOperation(operation)
      logger.info("Local preferences updated and saved from server data.")

      // IMPORTANT: Update the cache with the processed preferences
      cachedServerPreferences = currentPrefs
      logger.debug("Updated cachedServerPreferences after processing server data.")

      // Apply accept-labelers header based on preferences
      await applyAcceptLabelersHeader(from: currentPrefs)
      try validatePreferenceOperation(operation)

      // Update state
      state = .ready

    } catch {
      logger.error("Failed to fetch and process preferences: \(error.localizedDescription)")
      if accountDID == operation.accountDID, preferenceSessionGeneration == operation.generation {
        state = .error(error.localizedDescription)
      }
      throw error
    }
  }

  /// Loads preferences from SwiftData for the current account
  @MainActor
  func loadPreferences() async throws -> Preferences? {
    guard let modelContext = modelContext else {
      logger.error("ModelContext not available for preferences load")
      throw PreferencesManagerError.modelContextNotInitialized
    }

    if let migrated = try migrateLegacyPreferencesIfNeeded(in: modelContext) {
      return migrated
    }

    let preferences = try modelContext.fetch(scopedPreferencesFetchDescriptor())
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

    if let migrated = try migrateLegacyPreferencesIfNeeded(in: modelContext) {
      return migrated
    }

    let preferences = try modelContext.fetch(scopedPreferencesFetchDescriptor())
    return preferences.first
  }

  /// A created default row is not evidence that an empty remote policy was accepted.
  @MainActor
  func confirmedFeedFilterPreferences() throws -> Preferences? {
    guard let value = try storedFeedFilterPreferencesWithoutMigration(),
          value.hasConfirmedServerPreferences else { return nil }
    return value
  }

  /// Keep known persisted safety rules during legacy-row confirmation failures.
  /// This fallback never establishes that an empty policy was confirmed.
  @MainActor
  func retainedLocalFeedFilterPreferences() throws -> Preferences? {
    guard let value = try storedFeedFilterPreferencesWithoutMigration() else { return nil }
    guard value.hasConfirmedServerPreferences || !value.mutedWords.isEmpty || !value.contentLabelPrefs.isEmpty
      || !value.labelers.isEmpty || !value.hiddenPosts.isEmpty || value.feedViewPref != nil || value.adultContentEnabled else { return nil }
    return value
  }

  @MainActor
  private func storedFeedFilterPreferencesWithoutMigration() throws -> Preferences? {
    if let cachedServerPreferences, cachedServerPreferences.accountDID == accountDID { return cachedServerPreferences }
    guard let modelContext else { throw PreferencesManagerError.modelContextNotInitialized }
    return try modelContext.fetch(scopedPreferencesFetchDescriptor()).first
  }

  /// Map the entire latest filter policy, not just the edited field, after a confirmed response.
  @MainActor
  private func applyConfirmedFilterPolicy(_ items: [AppBskyActorDefs.PreferencesForUnionArray], to value: Preferences) {
    var labels: [ContentLabelPreference] = []
    var adult = false
    var words: [MutedWord] = []
    var hidden: [String] = []
    var labelers: [LabelerPreference] = []
    var thread: ThreadViewPreference?
    var home: FeedViewPreference?
    for item in items {
      switch item {
      case .contentLabelPref(let p): labels.append(.init(labelerDid: p.labelerDid, label: p.label, visibility: p.visibility))
      case .adultContentPref(let p): adult = p.enabled
      case .mutedWordsPref(let p): words = p.items.map { .init(id: $0.id ?? "", value: $0.value, targets: $0.targets.map(\.rawValue), actorTarget: $0.actorTarget, expiresAt: $0.expiresAt?.date) }
      case .hiddenPostsPref(let p): hidden = p.items.map { $0.uriString() }
      case .labelersPref(let p): labelers = p.labelers.map { .init(did: $0.did) }
      case .threadViewPref(let p): thread = .init(sort: p.sort, prioritizeFollowedUsers: value.threadViewPref?.prioritizeFollowedUsers)
      case .feedViewPref(let p) where p.feed == "home":
        home = .init(hideReplies: p.hideReplies, hideRepliesByUnfollowed: p.hideRepliesByUnfollowed,
          hideRepliesByLikeCount: p.hideRepliesByLikeCount, hideReposts: p.hideReposts, hideQuotePosts: p.hideQuotePosts)
      default: break
      }
    }
    value.contentLabelPrefs = labels; value.adultContentEnabled = adult; value.mutedWords = words
    value.hiddenPosts = hidden; value.labelers = labelers; value.threadViewPref = thread; value.feedViewPref = home
    value.hasConfirmedServerPreferences = true
  }

  /// Settings editing must not treat the generic offline fallback as a remote refresh.
  @MainActor
  func refreshSettingsPreferences(expectedAccountDID: String? = nil) async throws -> Preferences {
    let operation = try capturePreferenceOperation(expectedAccountDID: expectedAccountDID)
    try await fetchPreferences(forceRefresh: true)
    try validatePreferenceOperation(operation)
    let preferences = try await getPreferences()
    try validatePreferenceOperation(operation)
    return preferences
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
    logger.debug("Creating default preferences for account: \(self.accountDID)")
    let newPreferences = Preferences(accountDID: self.accountDID)
    modelContext.insert(newPreferences)
    try modelContext.save()
    return newPreferences
  }

  /// Saves preferences to SwiftData
  @MainActor
  func savePreferences(_ preferences: Preferences) async throws {
    guard preferences.accountDID.isEmpty || preferences.accountDID == accountDID else {
      throw PreferencesManagerError.accountChanged
    }
    guard let modelContext = modelContext else {
      logger.error("ModelContext not available for preferences save")
      throw PreferencesManagerError.modelContextNotInitialized
    }

    if let existingPreferences = try await loadPreferences() {
      // Update all properties of the existing preferences
      existingPreferences.hasConfirmedServerPreferences = preferences.hasConfirmedServerPreferences
      existingPreferences.pinnedFeeds = preferences.pinnedFeeds
      existingPreferences.savedFeeds = preferences.savedFeeds
      existingPreferences.contentLabelPrefs = preferences.contentLabelPrefs
      existingPreferences.threadViewPref = preferences.threadViewPref
      existingPreferences.feedViewPref = preferences.feedViewPref
      existingPreferences.adultContentEnabled = preferences.adultContentEnabled
      existingPreferences.mutedWords = preferences.mutedWords
      existingPreferences.hiddenPosts = preferences.hiddenPosts
      existingPreferences.labelers = preferences.labelers
      existingPreferences.activeProgressGuide = preferences.activeProgressGuide
      existingPreferences.queuedNudges = preferences.queuedNudges
      existingPreferences.nuxStates = preferences.nuxStates
      existingPreferences.interests = preferences.interests
      existingPreferences.postInteractionSettingsPref = preferences.postInteractionSettingsPref
      existingPreferences.verificationPrefs = preferences.verificationPrefs
      existingPreferences.hideVerificationBadges = preferences.hideVerificationBadges
    } else {
      preferences.accountDID = accountDID
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
    let operation = try capturePreferenceOperation(expectedAccountDID: preferences.accountDID.isEmpty ? nil : preferences.accountDID)
    feedLibraryWriteRevision &+= 1
    defer { feedLibraryWriteRevision &+= 1 }
    let pendingStore = FeedLibraryPendingStore()
    let replacements = pendingStore.supersedePending(accountDID: operation.accountDID,
      pinned: preferences.pinnedFeeds, saved: preferences.savedFeeds)
    if let confirmed = try confirmedFeedFilterPreferences(), confirmed !== preferences {
      preferences.contentLabelPrefs = confirmed.contentLabelPrefs
      preferences.adultContentEnabled = confirmed.adultContentEnabled
      preferences.mutedWords = confirmed.mutedWords; preferences.labelers = confirmed.labelers
      preferences.postInteractionSettingsPref = confirmed.postInteractionSettingsPref
      preferences.verificationPrefs = confirmed.verificationPrefs
      preferences.hideVerificationBadges = confirmed.hideVerificationBadges
      preferences.hasConfirmedServerPreferences = true
    }
    // First save locally. A failed local write must not replace an older retry intent.
    do { try await savePreferences(preferences) }
    catch {
      for change in replacements {
        pendingStore.complete(change.replacement, accountDID: operation.accountDID, restoring: change.previous)
      }
      throw error
    }

    // Update cache so getPreferences returns the latest pinnedFeeds order
    try validatePreferenceOperation(operation)
    cachedServerPreferences = preferences

    // Acknowledgment applies only to the retry revisions included in this write.
    let pendingAtSync = pendingStore.entries(accountDID: operation.accountDID)
    try await syncToServer(preferences, expectedAccountDID: operation.accountDID)
    try validatePreferenceOperation(operation)
    for entry in pendingAtSync { pendingStore.complete(entry, accountDID: operation.accountDID) }

    // Refresh cache again post-sync
    try validatePreferenceOperation(operation)
    cachedServerPreferences = preferences

    logger.debug("Preferences saved and synced to server")

    // Safety fields and the labeler header are owned by focused, confirmed edits.
  }

  /// Discovery keeps a durable local change when network synchronization fails.
  /// A thrown error means local persistence failed; pendingSync means local success only.
  @MainActor
  func saveFeedLibraryPreferences(_ preferences: Preferences) async throws -> FeedLibraryPersistence {
    feedLibraryWriteRevision &+= 1
    defer { feedLibraryWriteRevision &+= 1 }
    var pinned = preferences.pinnedFeeds
    var saved = preferences.savedFeeds
    FeedLibraryPendingStore().reconcile(accountDID: accountDID, pinned: &pinned, saved: &saved)
    preferences.pinnedFeeds = pinned
    preferences.savedFeeds = saved
    try await savePreferences(preferences)
    cachedServerPreferences = preferences
    do {
      try await syncFeedLibraryToServer(preferences)
      return .synced
    } catch {
      return .pendingSync(error.localizedDescription)
    }
  }

  /// Merge URI intents into the freshest server list, retaining unknown preferences
  /// and existing feed IDs/types/order. This endpoint has no compare-and-swap token.
  @MainActor
  private func syncFeedLibraryToServer(_ preferences: Preferences) async throws {
    let operation = try capturePreferenceOperation(expectedAccountDID: preferences.accountDID)
    let finishAccountIO = try beginSettingsAccountIO()
    defer { finishAccountIO?() }
    await acquireSpecificEdit()
    defer { releaseSpecificEdit() }
    try validatePreferenceOperation(operation)
    guard let client = operation.client else { throw PreferencesManagerError.clientNotInitialized }
    let revision = feedLibraryWriteRevision
    let store = FeedLibraryPendingStore()
    let pending = store.entries(accountDID: operation.accountDID)
    let pendingOrder = store.pinnedOrder(accountDID: operation.accountDID)
    let response = try await client.app.bsky.actor.getPreferences(input: .init())
    try validatePreferenceOperation(operation)
    guard (200..<300).contains(response.responseCode), let server = response.data else {
      throw PreferencesManagerError.invalidData
    }
    var items = server.preferences.items
    var feeds: [AppBskyActorDefs.SavedFeed] = []
    var hasV2 = false
    for item in items {
      switch item {
      case .savedFeedsPrefV2(let value): feeds = value.items; hasV2 = true
      default: break
      }
    }
    if !hasV2 {
      for item in items {
        if case .savedFeedsPref(let value) = item {
          let pinned = value.pinned.map { $0.uriString() }
          let saved = value.saved.map { $0.uriString() }
          var identifiers: [String: String] = [:]
          for uri in pinned + saved + ["following"] { identifiers[uri] = await TIDGenerator.next() }
          feeds = FeedLibraryServerMerge.migrateV1(pinned: pinned, saved: saved,
            timelineIndex: value.timelineIndex, newIDs: identifiers)
        }
      }
    }
    var newIDs: [String: String] = [SystemFeedTypes.following: await TIDGenerator.next()]
    for entry in pending { newIDs[entry.uri] = await TIDGenerator.next() }
    feeds = FeedLibraryServerMerge.apply(pending, to: feeds, newIDs: newIDs)
    feeds = FeedLibraryServerMerge.applyPinnedOrder(pendingOrder, to: feeds)
    // An intervening local writer supersedes this captured operation.
    guard revision == feedLibraryWriteRevision else { throw PreferencesManagerError.invalidData }
    items.removeAll {
      switch $0 { case .savedFeedsPref, .savedFeedsPrefV2: true; default: false }
    }
    items.append(.savedFeedsPrefV2(.init(items: feeds)))
    items.append(.savedFeedsPref(.init(
      pinned: feeds.filter { $0.pinned }.compactMap { try? ATProtocolURI(uriString: $0.value) },
      saved: feeds.compactMap { try? ATProtocolURI(uriString: $0.value) },
      timelineIndex: feeds.filter { $0.pinned }.firstIndex { $0.type == "timeline" })))
    try validatePreferenceOperation(operation)
    let code = try await client.app.bsky.actor.putPreferences(input: .init(preferences: .init(items: items)))
    try validatePreferenceOperation(operation)
    guard (200..<300).contains(code), revision == feedLibraryWriteRevision else {
      throw PreferencesManagerError.invalidData
    }
    preferences.pinnedFeeds = feeds.filter { $0.pinned }.map { $0.value }
    preferences.savedFeeds = feeds.filter { !$0.pinned }.map { $0.value }
    try await savePreferences(preferences)
    // Other pending URIs were included too, but only their exact captured revisions
    // may be acknowledged. A later edit remains pending.
    try validatePreferenceOperation(operation)
    for entry in pending { store.complete(entry, accountDID: operation.accountDID) }
    if let pendingOrder { store.completePinnedOrder(pendingOrder, accountDID: operation.accountDID) }
  }

  /// Syncs current preferences to the Bluesky API
  @MainActor
  private func syncToServer(_ preferences: Preferences, expectedAccountDID: String? = nil) async throws {
    let operation = try capturePreferenceOperation(expectedAccountDID: expectedAccountDID ?? (preferences.accountDID.isEmpty ? nil : preferences.accountDID))
    let finishAccountIO = try beginSettingsAccountIO()
    defer { finishAccountIO?() }
    await acquireSpecificEdit()
    defer { releaseSpecificEdit() }
    let items = try await readSpecificPreferenceItems(operation)

    // Start with ALL existing preferences from server
    var allPrefItems = items

    // Retained generic callers edit feed membership, hidden posts, NUX, or interests.
    // All focused fields retain the latest remote records, including unknown/scoped keys.
    allPrefItems.removeAll { item in
      switch item {
      case .savedFeedsPref, .savedFeedsPrefV2:
        return true  // Remove feed prefs as we'll update them
      case .personalDetailsPref:
        // Do not alter or write personalDetailsPref via putPreferences.
        return false
      case .hiddenPostsPref:
        return !preferences.hiddenPosts.isEmpty  // Only remove if we have hidden posts
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

    // 8. Add hidden posts if present
    if !prefsToSync.hiddenPosts.isEmpty {
      let hiddenPostUris = prefsToSync.hiddenPosts.compactMap { try? ATProtocolURI(uriString: $0) }

      allPrefItems.append(.hiddenPostsPref(AppBskyActorDefs.HiddenPostsPref(items: hiddenPostUris)))
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
    try validatePreferenceOperation(operation)
    let responseCode: Int
    if let transport = specificPreferencesTransport { responseCode = try await transport.putPreferences(allPrefItems) }
    else {
      guard let client = operation.client else { throw PreferencesManagerError.clientNotInitialized }
      responseCode = try await client.app.bsky.actor.putPreferences(input: input)
    }
    try validatePreferenceOperation(operation)

    if !(200..<300).contains(responseCode) {
      logger.error("Failed to sync preferences to server, response code: \(responseCode)")
      throw NSError(
        domain: "Preferences", code: responseCode,
        userInfo: [NSLocalizedDescriptionKey: "Server returned error code \(responseCode)"])
    }

    let beforeCommit = preferences.detachedSnapshot()
    applyConfirmedFilterPolicy(allPrefItems, to: preferences)
    do { try await savePreferences(preferences) }
    catch { preferences.restoreValues(from: beforeCommit); cachedServerPreferences = nil; throw error }
    try validatePreferenceOperation(operation)
    logger.info("Successfully synced all preferences to server")
  }

  // MARK: - Convenience Methods for All Preference Types

  @MainActor
  func setContentLabelVisibility(
    label: String, visibility: String, labelerDid: DID? = nil, expectedAccountDID: String? = nil
  ) async throws {
    try await updateContentLabelPreferences([
      ContentLabelPreference(labelerDid: labelerDid, label: label, visibility: visibility)
    ], expectedAccountDID: expectedAccountDID)
  }

  @MainActor
  func setAdultContentEnabled(_ enabled: Bool, expectedAccountDID: String? = nil) async throws {
    try await updateAdultContentEnabled(enabled, expectedAccountDID: expectedAccountDID)
  }

  @MainActor
  func setThreadViewPreferences(
    sort: String? = nil, prioritizeFollowedUsers: Bool? = nil, expectedAccountDID: String? = nil
  ) async throws {
    let operation = try capturePreferenceOperation(expectedAccountDID: expectedAccountDID)
    if let sort {
      try await updateSpecificPreferences(preferenceType: "threadView", expectedAccountDID: operation.accountDID) {
        (_: AppBskyActorDefs.ThreadViewPref?) -> AppBskyActorDefs.ThreadViewPref? in .init(sort: sort)
      }
      try validatePreferenceOperation(operation)
    }
    if let prioritizeFollowedUsers {
      let preferences = try await getPreferences()
      try validatePreferenceOperation(operation)
      preferences.threadViewPref = .init(sort: preferences.threadViewPref?.sort,
                                         prioritizeFollowedUsers: prioritizeFollowedUsers)
      try await savePreferences(preferences)
    }
  }

  @MainActor
  func setFeedViewPreferences(
    hideReplies: Bool? = nil, hideRepliesByUnfollowed: Bool? = nil,
    hideRepliesByLikeCount: Int? = nil, hideReposts: Bool? = nil, hideQuotePosts: Bool? = nil,
    clearReplyLikeThreshold: Bool = false, expectedAccountDID: String? = nil
  ) async throws {
    try await updateSpecificPreferences(preferenceType: "feedView", expectedAccountDID: expectedAccountDID) {
      (current: AppBskyActorDefs.FeedViewPref?) -> AppBskyActorDefs.FeedViewPref? in
      let existing = current.map { FeedViewPreference(hideReplies: $0.hideReplies,
        hideRepliesByUnfollowed: $0.hideRepliesByUnfollowed, hideRepliesByLikeCount: $0.hideRepliesByLikeCount,
        hideReposts: $0.hideReposts, hideQuotePosts: $0.hideQuotePosts) }
      let changed = Self.applyingFeedViewChanges(to: existing, hideReplies: hideReplies,
        hideRepliesByUnfollowed: hideRepliesByUnfollowed, hideRepliesByLikeCount: hideRepliesByLikeCount,
        hideReposts: hideReposts, hideQuotePosts: hideQuotePosts, clearReplyLikeThreshold: clearReplyLikeThreshold)
      return .init(feed: "home", hideReplies: changed.hideReplies,
        hideRepliesByUnfollowed: changed.hideRepliesByUnfollowed,
        hideRepliesByLikeCount: changed.hideRepliesByLikeCount, hideReposts: changed.hideReposts,
        hideQuotePosts: changed.hideQuotePosts)
    }
  }

  /// Omitted fields retain the existing value; clearing the optional threshold is explicit.
  static func applyingFeedViewChanges(
    to existing: FeedViewPreference?,
    hideReplies: Bool? = nil,
    hideRepliesByUnfollowed: Bool? = nil,
    hideRepliesByLikeCount: Int? = nil,
    hideReposts: Bool? = nil,
    hideQuotePosts: Bool? = nil,
    clearReplyLikeThreshold: Bool = false
  ) -> FeedViewPreference {
    FeedViewPreference(
      hideReplies: hideReplies ?? existing?.hideReplies,
      hideRepliesByUnfollowed: hideRepliesByUnfollowed ?? existing?.hideRepliesByUnfollowed,
      hideRepliesByLikeCount: clearReplyLikeThreshold ? nil : (hideRepliesByLikeCount ?? existing?.hideRepliesByLikeCount),
      hideReposts: hideReposts ?? existing?.hideReposts,
      hideQuotePosts: hideQuotePosts ?? existing?.hideQuotePosts
    )
  }

  @MainActor
  func addMutedWord(
    word: String, targets: [String], actorTarget: String? = nil, expiresAt: Date? = nil,
    expectedAccountDID: String? = nil
  ) async throws {
    let operation = try capturePreferenceOperation(expectedAccountDID: expectedAccountDID)
    let id = await TIDGenerator.next().description
    try validatePreferenceOperation(operation)
    let expiry = expiresAt.flatMap { ATProtocolDate(iso8601String: ISO8601DateFormatter().string(from: $0)) }
    try await updateSpecificPreferences(preferenceType: "mutedWords", expectedAccountDID: operation.accountDID) {
      (current: [AppBskyActorDefs.MutedWord]?) -> [AppBskyActorDefs.MutedWord]? in
      var words = current ?? []
      words.append(.init(id: id, value: word, targets: targets.map { $0 == "content" ? .content : .tag },
                         actorTarget: actorTarget, expiresAt: expiry))
      return words
    }
  }

  @MainActor
  func removeMutedWord(id: String, expectedAccountDID: String? = nil) async throws {
    guard !id.isEmpty else { throw PreferencesManagerError.invalidData }
    try await updateSpecificPreferences(preferenceType: "mutedWords", expectedAccountDID: expectedAccountDID) {
      (current: [AppBskyActorDefs.MutedWord]?) -> [AppBskyActorDefs.MutedWord]? in
      let words = current ?? []
      let matchingCount = words.filter { $0.id == id }.count
      guard matchingCount <= 1 else { throw PreferencesManagerError.invalidData }
      guard matchingCount == 1 else { return nil }
      return words.filter { $0.id != id }
    }
  }

  @MainActor
  func hidePost(_ uri: String, expectedAccountDID: String? = nil) async throws {
    let postURI = try ATProtocolURI(uriString: uri)
    try await updateSpecificPreferences(preferenceType: "hiddenPosts", expectedAccountDID: expectedAccountDID) {
      (current: [ATProtocolURI]?) -> [ATProtocolURI]? in
      var posts = current ?? []
      guard !posts.contains(where: { $0.uriString() == uri }) else { return nil }
      posts.append(postURI)
      return posts
    }
  }

  @MainActor
  func unhidePost(_ uri: String, expectedAccountDID: String? = nil) async throws {
    try await updateSpecificPreferences(preferenceType: "hiddenPosts", expectedAccountDID: expectedAccountDID) {
      (current: [ATProtocolURI]?) -> [ATProtocolURI]? in
      (current ?? []).filter { $0.uriString() != uri }
    }
  }

  @MainActor
  func addLabeler(_ did: DID, expectedAccountDID: String? = nil) async throws {
    try await updateSpecificPreferences(preferenceType: "labelers", expectedAccountDID: expectedAccountDID) {
      (current: [AppBskyActorDefs.LabelerPrefItem]?) -> [AppBskyActorDefs.LabelerPrefItem]? in
      var labelers = current ?? []
      guard !labelers.contains(where: { $0.did == did }) else { return nil }
      guard labelers.count < 19 else { throw PreferencesManagerError.labelerLimitExceeded }
      labelers.append(.init(did: did))
      return labelers
    }
  }

  @MainActor
  func removeLabeler(_ did: DID, expectedAccountDID: String? = nil) async throws {
    try await removeLabelers([did.didString()], expectedAccountDID: expectedAccountDID)
  }

  @MainActor
  func removeLabelers(_ dids: Set<String>, expectedAccountDID: String? = nil) async throws {
    guard !dids.isEmpty else { return }
    try await updateSpecificPreferences(preferenceType: "labelers", expectedAccountDID: expectedAccountDID) {
      (current: [AppBskyActorDefs.LabelerPrefItem]?) -> [AppBskyActorDefs.LabelerPrefItem]? in
      (current ?? []).filter { !dids.contains($0.did.didString()) }
    }
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
    try await updateSpecificPreferences(preferenceType: "interests") { (current: [String]?) -> [String]? in
      var tags = current ?? []
      guard !tags.contains(tag) else { return nil }
      tags.append(tag)
      return tags
    }
  }

  @MainActor
  func removeInterest(_ tag: String) async throws {
    try await updateSpecificPreferences(preferenceType: "interests") { (current: [String]?) -> [String]? in
      (current ?? []).filter { $0 != tag }
    }
  }

  /// The lexicon permits an empty tag list; commit local values only after the server accepts it.
  @MainActor
  func updateInterests(_ interests: [String]) async throws {
    try await updateSpecificPreferences(preferenceType: "interests") { (_: [String]?) -> [String]? in
      interests
    }
  }

  /// Updates specific preferences with server-first approach for better safety
  @MainActor
  func updateSpecificPreferences<T>(
    preferenceType: String,
    expectedAccountDID: String? = nil,
    update: @escaping (T?) throws -> T?
  ) async throws where T: Codable {
    let operation = try capturePreferenceOperation(expectedAccountDID: expectedAccountDID)
    let finishAccountIO = try beginSettingsAccountIO()
    defer { finishAccountIO?() }
    await acquireSpecificEdit()
    defer { releaseSpecificEdit() }
    try validatePreferenceOperation(operation)
    let items: [AppBskyActorDefs.PreferencesForUnionArray]
    if let transport = specificPreferencesTransport {
      items = try await transport.getPreferences()
    } else {
      guard let client = operation.client else { throw PreferencesManagerError.clientNotInitialized }
      let params = AppBskyActorGetPreferences.Parameters()
      let serverPrefs = try await client.app.bsky.actor.getPreferences(input: params)
      guard serverPrefs.responseCode >= 200 && serverPrefs.responseCode < 300,
            let fetchedItems = serverPrefs.data?.preferences.items else {
        throw NSError(
          domain: "Preferences",
          code: serverPrefs.responseCode != 0 ? serverPrefs.responseCode : -1,
          userInfo: [NSLocalizedDescriptionKey: "Failed to fetch existing preferences from server before update"]
        )
      }
      items = fetchedItems
    }
    try validatePreferenceOperation(operation)

    // Keep all existing preferences
    var allPrefs = items

    // Find existing preference of this type
    var existingValue: T?

    for pref in allPrefs {
      // Check if this is the preference type we're looking for
      switch (preferenceType, pref) {
      case ("savedFeeds", .savedFeedsPrefV2(let value)):
        if T.self == [AppBskyActorDefs.SavedFeed].self {

          existingValue = value.items as? T
        }
      case ("adultContent", .adultContentPref(let value)):
        if T.self == Bool.self {

          existingValue = value.enabled as? T
        }
      case ("contentLabels", .contentLabelPref):
        if T.self == [AppBskyActorDefs.ContentLabelPref].self {

          existingValue = allPrefs.compactMap { item -> AppBskyActorDefs.ContentLabelPref? in
            if case .contentLabelPref(let value) = item { return value }
            return nil
          } as? T
        }
      case ("threadView", .threadViewPref(let value)):
        if T.self == AppBskyActorDefs.ThreadViewPref.self {

          existingValue = value as? T
        }
      case ("feedView", .feedViewPref(let value)):
        if T.self == AppBskyActorDefs.FeedViewPref.self, value.feed == "home" {

          existingValue = value as? T
        }
      case ("mutedWords", .mutedWordsPref(let value)):
        if T.self == [AppBskyActorDefs.MutedWord].self {

          existingValue = value.items as? T
        }
      case ("hiddenPosts", .hiddenPostsPref(let value)):
        if T.self == [ATProtocolURI].self {

          existingValue = value.items as? T
        }
      case ("labelers", .labelersPref(let value)):
        if T.self == [AppBskyActorDefs.LabelerPrefItem].self {

          existingValue = value.labelers as? T
        }
      case ("interests", .interestsPref(let value)):
        if T.self == [String].self {

          existingValue = value.tags as? T
        }
      case ("postInteractionSettings", .postInteractionSettingsPref(let value)):
        existingValue = [value] as? T
      case ("verification", .verificationPrefs(let value)):
        existingValue = [value] as? T
      default:
        break
      }
    }

    // Update the preference
    if let updatedValue = try update(existingValue) {
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
      case "postInteractionSettings":
        guard let values = updatedValue as? [AppBskyActorDefs.PostInteractionSettingsPref] else { throw PreferencesManagerError.invalidData }
        allPrefs.removeAll { if case .postInteractionSettingsPref = $0 { return true }; return false }
        if let value = values.first { newPref = .postInteractionSettingsPref(value) }
      case "verification":
        guard let values = updatedValue as? [AppBskyActorDefs.VerificationPrefs] else { throw PreferencesManagerError.invalidData }
        allPrefs.removeAll { if case .verificationPrefs = $0 { return true }; return false }
        if let value = values.first { newPref = .verificationPrefs(value) }

      default:
        throw PreferencesManagerError.invalidData
      }

      // Replace or add the preference if it was created
      if let newPref = newPref {
        if preferenceType != "contentLabels" {
          allPrefs.removeAll { item in
            switch (preferenceType, item) {
            case ("adultContent", .adultContentPref), ("threadView", .threadViewPref),
                 ("mutedWords", .mutedWordsPref), ("hiddenPosts", .hiddenPostsPref),
                 ("labelers", .labelersPref), ("interests", .interestsPref),
                 ("savedFeeds", .savedFeedsPrefV2): return true
            case ("feedView", .feedViewPref(let value)): return value.feed == "home"
            default: return false
            }
          }
          allPrefs.append(newPref)
        }
      }

      // Send to server
      let apiPreferences = AppBskyActorDefs.Preferences(items: allPrefs)
      let input = AppBskyActorPutPreferences.Input(preferences: apiPreferences)

      let responseCode: Int
      try validatePreferenceOperation(operation)
      if let transport = specificPreferencesTransport {
        responseCode = try await transport.putPreferences(allPrefs)
      } else {
        guard let client = operation.client else { throw PreferencesManagerError.clientNotInitialized }
        responseCode = try await client.app.bsky.actor.putPreferences(input: input)
      }
      try validatePreferenceOperation(operation)

      if !(200..<300).contains(responseCode) {
        throw NSError(
          domain: "Preferences", code: responseCode,
          userInfo: [NSLocalizedDescriptionKey: "Server returned error code \(responseCode)"])
      }

      // Only update local model after successful server update
      let localPrefs = try await getPreferences()
      try validatePreferenceOperation(operation)

      let beforeCommit = localPrefs.detachedSnapshot()
      applyConfirmedFilterPolicy(allPrefs, to: localPrefs)
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
            prioritizeFollowedUsers: localPrefs.threadViewPref?.prioritizeFollowedUsers
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
      case "postInteractionSettings":
        localPrefs.postInteractionSettingsPref = (updatedValue as? [AppBskyActorDefs.PostInteractionSettingsPref])?.first
      case "verification":
        localPrefs.verificationPrefs = (updatedValue as? [AppBskyActorDefs.VerificationPrefs])?.first
        localPrefs.hideVerificationBadges = localPrefs.verificationPrefs?.hideBadges ?? false

      default:
        break
      }

      do { try await savePreferences(localPrefs) }
      catch {
        localPrefs.restoreValues(from: beforeCommit)
        cachedServerPreferences = nil
        state = .error("The server saved this change, but local storage failed. Reload preferences to recover.")
        throw error
      }
      try validatePreferenceOperation(operation)
      cachedServerPreferences = localPrefs
      if preferenceType == "verification" { hideVerificationBadges = localPrefs.hideVerificationBadges }
      if ["adultContent", "contentLabels", "mutedWords", "hiddenPosts", "labelers", "feedView", "threadView"].contains(preferenceType) {
        NotificationCenter.default.post(name: NSNotification.Name("FeedPreferencesChanged"), object: nil,
                                        userInfo: ["accountDID": operation.accountDID])
      }
      if preferenceType == "adultContent" {
        sharedDefaults.set(localPrefs.adultContentEnabled, forKey: scopedKey("isAdultContentEnabled"))
      } else if preferenceType == "labelers" {
        await applyAcceptLabelersHeader(from: localPrefs)
        try validatePreferenceOperation(operation)
      }
    } else {
      // A successful fresh GET is authoritative even when the requested edit already exists.
      try await publishConfirmedNoOp(items, preferenceType: preferenceType, operation: operation)
    }
  }

  @MainActor
  private func publishConfirmedNoOp(
    _ items: [AppBskyActorDefs.PreferencesForUnionArray], preferenceType: String,
    operation: PreferenceOperationContext
  ) async throws {
    try validatePreferenceOperation(operation)
    let localPrefs = try await getPreferences()
    try validatePreferenceOperation(operation)
    let beforeCommit = localPrefs.detachedSnapshot()
    applyConfirmedFilterPolicy(items, to: localPrefs)
    if preferenceType == "interests" {
      localPrefs.interests = items.compactMap { item -> [String]? in
        if case .interestsPref(let value) = item { return value.tags }
        return nil
      }.last ?? []
    }
    do { try await savePreferences(localPrefs) }
    catch {
      localPrefs.restoreValues(from: beforeCommit)
      cachedServerPreferences = nil
      state = .error("Confirmed preferences could not be saved locally. Reload preferences to recover.")
      throw error
    }
    try validatePreferenceOperation(operation)
    cachedServerPreferences = localPrefs
    sharedDefaults.set(localPrefs.adultContentEnabled, forKey: scopedKey("isAdultContentEnabled"))
    await applyAcceptLabelersHeader(from: localPrefs)
    try validatePreferenceOperation(operation)
    state = .ready
    NotificationCenter.default.post(name: NSNotification.Name("FeedPreferencesChanged"), object: nil,
                                    userInfo: ["accountDID": operation.accountDID])
  }

  @MainActor
  func removeContentLabelOverride(label: String, labelerDid: DID, expectedAccountDID: String? = nil) async throws {
    try await updateSpecificPreferences(preferenceType: "contentLabels", expectedAccountDID: expectedAccountDID) {
      (current: [AppBskyActorDefs.ContentLabelPref]?) in
      (current ?? []).filter { !($0.label == label && $0.labelerDid?.didString() == labelerDid.didString()) }
    }
  }

  /// Repairs preferences by ensuring all data is valid and complete
  @MainActor
  func repairPreferences() async throws {
    // Get current server preferences
    guard let client = client else {
      throw PreferencesManagerError.clientNotInitialized
    }

    let operation = try capturePreferenceOperation()
    let finishAccountIO = try beginSettingsAccountIO()
    defer { finishAccountIO?() }
    let feedRevisionAtRequest = feedLibraryWriteRevision
    let params = AppBskyActorGetPreferences.Parameters()
    let serverPrefs = try await client.app.bsky.actor.getPreferences(input: params)

    try validatePreferenceOperation(operation)
    guard (200..<300).contains(serverPrefs.responseCode), serverPrefs.data != nil else {
      throw PreferencesManagerError.invalidData
    }

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
          FeedLibraryPendingStore().reconcile(accountDID: accountDID,
            pinned: &pinnedFeeds, saved: &savedFeeds)
          if feedRevisionAtRequest == feedLibraryWriteRevision {
            localPrefs.updateFeeds(pinned: pinnedFeeds, saved: savedFeeds)
          }
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
    let did = self.accountDID
    let descriptor = FetchDescriptor<Preferences>(
      predicate: #Predicate<Preferences> { $0.accountDID == did }
    )
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

    let restoredAdultContent = backup["adultContentEnabled"] as? Bool
    let restoringAccount = accountDID

    // Validate and save
    try validatePreferences(preferences)
    try await saveAndSyncPreferences(preferences)
    if let restoredAdultContent {
      try await updateAdultContentEnabled(restoredAdultContent, expectedAccountDID: restoringAccount)
    }
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
    sharedDefaults.set(preferences.adultContentEnabled, forKey: scopedKey("isAdultContentEnabled"))

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
  func updateAdultContentEnabled(_ enabled: Bool, expectedAccountDID: String? = nil) async throws {
    try await updateSpecificPreferences(preferenceType: "adultContent", expectedAccountDID: expectedAccountDID) {
      (_: Bool?) -> Bool? in enabled
    }
  }

  /// Upsert only the supplied (label, service) keys using the latest remote snapshot.
  @MainActor
  func updateContentLabelPreferences(
    _ contentLabels: [ContentLabelPreference], expectedAccountDID: String? = nil
  ) async throws {
    guard !contentLabels.isEmpty else { return }
    try await updateSpecificPreferences(preferenceType: "contentLabels", expectedAccountDID: expectedAccountDID) {
      (current: [AppBskyActorDefs.ContentLabelPref]?) -> [AppBskyActorDefs.ContentLabelPref]? in
      let existing = (current ?? []).map {
        ContentLabelPreference(labelerDid: $0.labelerDid, label: $0.label, visibility: $0.visibility)
      }
      return Preferences.mergingContentLabelPreferences(contentLabels, into: existing).map {
        .init(labelerDid: $0.labelerDid, label: $0.label, visibility: $0.visibility)
      }
    }
  }

  // MARK: - Accept-Labelers Header Application
  /// Updates the network header `atproto-accept-labelers` based on current preferences
  @MainActor
  private func applyAcceptLabelersHeader(from preferences: Preferences) async {
    // Include the default Bluesky moderation service (always-on) and user-selected labelers
    let defaultModDID = "did:plc:ar7c4by46qjdydhdevvrndac"

    var uniqueDIDs = OrderedSet<String>()
    uniqueDIDs.append(defaultModDID)
    for item in preferences.labelers {
      uniqueDIDs.append(item.did.didString())
    }

    // Cap at 20 total (1 default + up to 19 user labelers)
    let dids = Array(uniqueDIDs.prefix(20))

    if let client = client {
      let appliedAccountDID = accountDID
      labelerHeaderGeneration += 1
      let generation = labelerHeaderGeneration
      appliedAcceptLabelerDIDs = nil
      await client.setAcceptLabelers(dids: dids)
      guard self.client === client else { return }
      guard accountDID == appliedAccountDID, generation == labelerHeaderGeneration else {
        // An overlapping setter may have finished last; omit previews until a fresh application.
        appliedAcceptLabelerDIDs = nil
        return
      }
      appliedAcceptLabelerDIDs = dids
      NotificationCenter.default.post(
        name: Self.acceptLabelersHeaderDidChange,
        object: self,
        userInfo: ["accountDID": appliedAccountDID, "labelerDIDs": dids]
      )
      logger.info("Applied atproto-accept-labelers header for \(dids.count) labeler(s) including default moderation service")
    } else {
      logger.debug("Client not available; deferring accept-labelers header update")
    }
  }
  
  /// Retained compatibility entry point. Language choices have no server serializer.
  @MainActor
  func updateLanguagePreferences(appLanguage: String?, primaryLanguage: String, contentLanguages: [String]) async throws {
    let expectedDID = accountDID
    try await updateReadingLanguagePreferences(primaryLanguage: primaryLanguage, contentLanguages: contentLanguages, expectedAccountDID: expectedDID)
    if let appLanguage {
      sharedDefaults.set(appLanguage, forKey: "appLanguage")
    } else {
      sharedDefaults.removeObject(forKey: "appLanguage")
    }
  }

  struct ReadingLanguagePersistence {
    var fetch: (ModelContext, String) throws -> Preferences?
    var save: (ModelContext) throws -> Void
    static let live = Self(
      fetch: { context, accountDID in
        let descriptor = FetchDescriptor<Preferences>(predicate: #Predicate { $0.accountDID == accountDID })
        return try context.fetch(descriptor).first
      }, save: { try $0.save() }
    )
  }
  var readingLanguagePersistence = ReadingLanguagePersistence.live
  var readingLanguageDefaults: UserDefaults?

  /// Publish this account's confirmed local reading choice without sending unrelated preferences.
  @MainActor
  func updateReadingLanguagePreferences(primaryLanguage: String, contentLanguages: [String], expectedAccountDID: String) async throws {
    guard !expectedAccountDID.isEmpty, accountDID == expectedAccountDID else {
      throw PreferencesManagerError.invalidData
    }
    let operation = PreferenceOperationContext(accountDID: accountDID, generation: preferenceSessionGeneration, client: client)
    await acquireSpecificEdit()
    defer { releaseSpecificEdit() }
    try validatePreferenceOperation(operation)
    guard let modelContext else { throw PreferencesManagerError.modelContextNotInitialized }
    let context = ModelContext(modelContext.container)
    context.autosaveEnabled = false
    if let local = try readingLanguagePersistence.fetch(context, expectedAccountDID) {
      guard accountDID == expectedAccountDID else { throw PreferencesManagerError.invalidData }
      local.primaryLanguage = primaryLanguage
      local.contentLanguages = contentLanguages
      try readingLanguagePersistence.save(context)
    }
    guard accountDID == expectedAccountDID else { throw PreferencesManagerError.invalidData }
    let defaults = readingLanguageDefaults ?? sharedDefaults
    // There is no suspension between the account proof and this local transaction.
    defaults.set(primaryLanguage, forKey: AppSettingsModel.scopedKey("primaryLanguage", accountDID: expectedAccountDID))
    defaults.set(contentLanguages, forKey: AppSettingsModel.scopedKey("contentLanguages", accountDID: expectedAccountDID))
    defaults.set(contentLanguages, forKey: AppSettingsModel.scopedKey("userPreferredLanguages", accountDID: expectedAccountDID))
    if cachedServerPreferences?.accountDID == expectedAccountDID {
      cachedServerPreferences?.primaryLanguage = primaryLanguage
      cachedServerPreferences?.contentLanguages = contentLanguages
    }
    NotificationCenter.default.post(name: NSNotification.Name("LanguagePreferencesChanged"), object: self,
      userInfo: ["accountDID": expectedAccountDID])
  }

  /// Updates feed view preference and syncs to server
  @MainActor
  func updateFeedViewPreference(_ feedViewPref: FeedViewPreference) async throws {
    try await setFeedViewPreferences(hideReplies: feedViewPref.hideReplies,
      hideRepliesByUnfollowed: feedViewPref.hideRepliesByUnfollowed,
      hideRepliesByLikeCount: feedViewPref.hideRepliesByLikeCount,
      hideReposts: feedViewPref.hideReposts, hideQuotePosts: feedViewPref.hideQuotePosts)
  }

  // MARK: - Post Interaction Settings (G40)
  
  @MainActor
  func cachedPostInteractionSettingsPref() -> AppBskyActorDefs.PostInteractionSettingsPref? {
    if let cached = cachedServerPreferences?.postInteractionSettingsPref {
      return cached
    }
    guard let modelContext = modelContext else { return nil }
    let descriptor = scopedPreferencesFetchDescriptor()
    if let local = try? modelContext.fetch(descriptor).first {
      return local.postInteractionSettingsPref
    }
    return nil
  }

  @MainActor
  func getPostInteractionSettingsPref() async throws -> AppBskyActorDefs.PostInteractionSettingsPref? {
    let prefs = try await getPreferences()
    return prefs.postInteractionSettingsPref
  }
  
  @MainActor
  func getConfirmedPostInteractionSettingsPref(
    expectedAccountDID: String? = nil
  ) async throws -> AppBskyActorDefs.PostInteractionSettingsPref? {
    let operation = try capturePreferenceOperation(expectedAccountDID: expectedAccountDID)
    let finishAccountIO = try beginSettingsAccountIO()
    defer { finishAccountIO?() }
    await acquireSpecificEdit()
    defer { releaseSpecificEdit() }
    let items = try await readSpecificPreferenceItems(operation)
    return items.compactMap { item -> AppBskyActorDefs.PostInteractionSettingsPref? in
      if case .postInteractionSettingsPref(let value) = item { return value }
      return nil
    }.last
  }

  @MainActor
  func setPostInteractionSettingsPref(
    _ pref: AppBskyActorDefs.PostInteractionSettingsPref?, expectedAccountDID: String? = nil
  ) async throws {
    try await updateSpecificPreferences(preferenceType: "postInteractionSettings", expectedAccountDID: expectedAccountDID) {
      (_: [AppBskyActorDefs.PostInteractionSettingsPref]?) -> [AppBskyActorDefs.PostInteractionSettingsPref]? in
      pref.map { [$0] } ?? []
    }
  }

  // MARK: - Verification Preferences (G45)
  
  @MainActor
  func getVerificationPrefs() async throws -> AppBskyActorDefs.VerificationPrefs? {
    let prefs = try await getPreferences()
    return prefs.verificationPrefs
  }
  
  @MainActor
  func setVerificationPrefs(_ pref: AppBskyActorDefs.VerificationPrefs?, expectedAccountDID: String? = nil) async throws {
    try await updateSpecificPreferences(preferenceType: "verification", expectedAccountDID: expectedAccountDID) {
      (_: [AppBskyActorDefs.VerificationPrefs]?) -> [AppBskyActorDefs.VerificationPrefs]? in
      pref.map { [$0] } ?? []
    }
  }

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
  case labelerLimitExceeded
  case accountChanged

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
    case .labelerLimitExceeded:
      return "You can add up to 19 custom labelers in addition to the default moderation service"
    case .accountChanged:
      return "The account changed. Reload these settings before saving."
    }
  }
}
