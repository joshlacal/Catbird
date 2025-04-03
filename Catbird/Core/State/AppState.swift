import Foundation
import Nuke
import OSLog
import Petrel
import SwiftData
import SwiftUI
import UserNotifications

/// Central state container for the Catbird app
@Observable
final class AppState {
  // MARK: - Core Properties

  // Logger
  private let logger = Logger(subsystem: "blue.catbird", category: "AppState")

  // Authentication manager - handles all auth operations
  let authManager = AuthenticationManager()  // Instance of the AuthenticationManager class defined in AuthManager.swift

  // Graph manager - handles social graph operations
  var graphManager: GraphManager

  // URL handling for deep links
  let urlHandler: URLHandler

  // User preference settings
  var isAdultContentEnabled: Bool = false

  // Used to track which tab was tapped twice to trigger scroll to top
  var tabTappedAgain: Int? = nil

  var currentUserProfile: AppBskyActorDefs.ProfileViewDetailed? = nil

  // MARK: - Component Managers

  /// Post shadow manager for handling interaction state (likes, reposts)
  let postShadowManager = PostShadowManager.shared

  /// Post manager for handling post creation and management
  let postManager: PostManager

  /// Preferences manager for handling user preferences
  let preferencesManager = PreferencesManager()

  /// Navigation manager for handling navigation
  let navigationManager = AppNavigationManager()

  /// Feed filter settings manager
  let feedFilterSettings = FeedFilterSettings()

  /// Notification manager for handling push notifications
  let notificationManager = NotificationManager()

  // MARK: - Feed State

  /// Cache of prefetched feeds by type
  @ObservationIgnored private var prefetchedFeeds:
    [FetchType: (posts: [AppBskyFeedDefs.FeedViewPost], cursor: String?)] = [:]

  // For task cancellation when needed
  @ObservationIgnored private var authStateObservationTask: Task<Void, Never>?

  // MARK: - Initialization

  init() {
    logger.debug("AppState initializing")
    self.urlHandler = URLHandler()

    // Initialize post manager with nil client (will be updated later)
    self.postManager = PostManager(client: nil)

    // Initialize graph manager with nil client (will be updated when auth is complete)
    self.graphManager = GraphManager(atProtoClient: nil)

    // Load user settings
    if let storedContentSetting = UserDefaults.standard.object(forKey: "isAdultContentEnabled")
      as? Bool
    {
      self.isAdultContentEnabled = storedContentSetting
    }

    // Configure notification manager with app state reference
    notificationManager.configure(with: self)

    // Set up observation of authentication state changes
    authStateObservationTask = Task { [weak self] in
      guard let self = self else { return }

      for await state in authManager.stateChanges {
        Task { @MainActor in
          // When auth state changes, update ALL manager client references
          if case .authenticated = state {
            self.postManager.updateClient(self.authManager.client)
            self.preferencesManager.updateClient(self.authManager.client)
            self.notificationManager.updateClient(self.authManager.client)
            if let client = self.authManager.client {
              self.graphManager = GraphManager(atProtoClient: client)
              self.urlHandler.configure(with: self)
              Task { @MainActor in
                await self.notificationManager.requestNotificationsAfterLogin()
              }

              // When we authenticate, also try to refresh preferences
              Task { @MainActor in

                do {
                  try await self.preferencesManager.fetchPreferences(forceRefresh: true)
                } catch {
                  self.logger.error(
                    "Error fetching preferences after authentication: \(error.localizedDescription)"
                  )
                }

                guard let currentUserDID = self.currentUserDID else {
                  self.logger.error("No current user DID after authentication")
                  return
                }

                // Fetch the current user profile after authentication
                do {
                  let profile = try await self.atProtoClient?.app.bsky.actor.getProfile(
                    input: .init(actor: ATIdentifier(string: currentUserDID))
                  ).data

                  self.currentUserProfile = profile
                  self.logger.info("Successfully fetched current user profile after authentication")
                } catch {
                  self.logger.error(
                    "Failed to fetch current user profile: \(error.localizedDescription)")
                }
              }
            }
          } else if case .unauthenticated = state {
            // Clear client on logout
            self.postManager.updateClient(nil)
            self.preferencesManager.updateClient(nil)
            self.notificationManager.updateClient(nil)
            self.graphManager = GraphManager(atProtoClient: nil)
          } else if case .initializing = state {
            // Force profile clear during account switch transition
            await MainActor.run {
              self.currentUserProfile = nil
              self.logger.info(
                "AUTH CHANGE: Force cleared currentUserProfile during initializing state")
            }
          }
        }
      }
    }

    logger.debug("AppState initialization complete")
  }

  deinit {
    // Cancel ongoing tasks
    authStateObservationTask?.cancel()
  }

  // MARK: - App Initialization

  @MainActor
  func initialize() async {
    logger.info("🚀 Starting AppState.initialize()")
    configureURLHandler()

    // Initialize auth manager first
    await authManager.initialize()

    // Update client references in all managers
    postManager.updateClient(authManager.client)
    preferencesManager.updateClient(authManager.client)
    notificationManager.updateClient(authManager.client)
    if let client = authManager.client {
      graphManager = GraphManager(atProtoClient: client)
    }

    // Setup other components as needed
    setupModelPruningTimer()
    setupPreferencesRefreshTimer()
    setupNotifications()

    // Get accounts list if authenticated
    if isAuthenticated {
      Task {
        await authManager.refreshAvailableAccounts()
      }
    }

    logger.info("🏁 AppState.initialize() completed")
  }

  @MainActor
  func switchToAccount(did: String) async throws {
    logger.info("Switching to account: \(did)")

    // 1. Capture the old avatar URL *before* clearing the profile
    let _ = currentUserProfile?.avatar?.url

    // 2. COMPLETELY CLEAR the current user profile including avatar URL
    // Set to nil FORCEFULLY on the main thread to ensure immediate UI update
    await MainActor.run {
      self.currentUserProfile = nil
      logger.debug("SWITCH: currentUserProfile thoroughly cleared to nil")
    }

    // 3. Give SwiftUI a chance to process the nil state update
    await Task.yield()
    logger.debug("SWITCH: Yielded after setting profile to nil")

    // 4. Use a more aggressive cache clearing approach
    ImageLoadingManager.shared.pipeline.cache.removeAll()
    logger.info("SWITCH: Cleared ALL image caches for clean switch")

    // 5. Switch account in AuthManager
    try await authManager.switchToAccount(did: did)
    logger.debug("SWITCH: AuthManager switched account")

    // 6. Refresh app state
    await refreshAfterAccountSwitch()

    // NEW: Add a deliberate delay to ensure client is fully ready
    try await Task.sleep(nanoseconds: 500_000_000)  // 500ms

    // 7. Now fetch profile when we're sure client is ready
    await reloadCurrentUserProfile()

    // 8. Final verification of profile state
    if let newURL = currentUserProfile?.avatar?.url {
      logger.info("SWITCH: New profile has avatar URL: \(newURL.absoluteString)")
    } else {
      logger.warning("SWITCH: New profile has nil avatar URL after reload")
    }

    // 9. Verify profile switch completion
    try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
    logger.info("SWITCH: Additional verification check after reload")
    if let actualProfileDID = currentUserProfile?.did.didString(),
      actualProfileDID != did
    {
      logger.error("SWITCH: Profile DID mismatch! Expected \(did) but got \(actualProfileDID)")
      // Force another reload
      await reloadCurrentUserProfile()
    }

    NotificationCenter.default.post(name: .init("ForceToolbarRecreation"), object: nil)

  }

  @MainActor
  func reloadCurrentUserProfile() async {
    guard let client = authManager.client, let did = currentUserDID else {
      logger.warning("Cannot reload profile: Missing client or DID.")
      await MainActor.run { currentUserProfile = nil }
      return
    }

    // Retry mechanism - try up to 5 times with increasing delays
    for attempt in 1...5 {
      do {
        logger.debug("RELOAD: Profile fetch attempt \(attempt) for DID: \(did)")
        let profile = try await client.app.bsky.actor.getProfile(
          input: .init(actor: ATIdentifier(string: did))
        ).data

        await MainActor.run {
          self.currentUserProfile = profile
          logger.info("RELOAD: Successfully loaded profile on attempt \(attempt)")
          NotificationCenter.default.post(name: .init("UserProfileUpdated"), object: nil)
          NotificationCenter.default.post(name: .init("AccountSwitchComplete"), object: nil)
          NotificationCenter.default.post(name: .init("ForceToolbarRecreation"), object: nil)
        }

        return  // Success - exit the function
      } catch {
        logger.error("RELOAD: Attempt \(attempt) failed: \(error.localizedDescription)")

        if attempt < 5 {
          // Exponential backoff - 200ms, 400ms, 800ms, 1600ms
          try? await Task.sleep(nanoseconds: UInt64(200_000_000 * pow(2.0, Double(attempt - 1))))
        } else {
          // Last attempt failed
          await MainActor.run { currentUserProfile = nil }
        }
      }
    }
  }

  @MainActor
  func refreshAfterAccountSwitch() async {
    // **Important:** DO NOT set currentUserProfile = nil here.
    // It should be handled by the calling function (switchToAccount)
    // or reloadCurrentUserProfile if needed.
    logger.info("Refreshing data after account switch")

    // Clear old prefetched data
    prefetchedFeeds.removeAll()

    // Update client references in all managers
    postManager.updateClient(authManager.client)
    preferencesManager.updateClient(authManager.client)
    notificationManager.updateClient(authManager.client)
    if let client = authManager.client {
      graphManager = GraphManager(atProtoClient: client)
    } else {
      graphManager = GraphManager(atProtoClient: nil)
    }

    // Reload preferences
    do {
      // Fetch preferences, but maybe don't force refresh if profile load failed? Or handle error better.
      try await preferencesManager.fetchPreferences(forceRefresh: true)
      logger.info("Successfully refreshed preferences after account switch")
    } catch {
      logger.error("Failed to refresh preferences after account switch: \(error)")
    }
    // Any other state that needs resetting after managers have new clients
  }

  /// Set up a timer to periodically prune old feed models
  private func setupModelPruningTimer() {
    // Set up a timer to prune old models every 5 minutes
    Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
      guard self != nil else { return }

      Task {
        // Prune models that haven't been accessed in 30 minutes
        FeedModelContainer.shared.pruneOldModels(olderThan: 1800)
      }
    }

    logger.debug("Feed model pruning timer set up")
  }

  /// Set up a timer to periodically refresh preferences
  private func setupPreferencesRefreshTimer() {
    // Set up a timer to refresh preferences every 10 minutes when the app is active
    Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
      guard let self = self, self.isAuthenticated else { return }

      Task {
        do {
          self.logger.info("Performing periodic preferences refresh")
          try await self.preferencesManager.fetchPreferences(forceRefresh: true)
        } catch {
          self.logger.error(
            "Error during periodic preferences refresh: \(error.localizedDescription)")
        }
      }
    }

    // Also refresh when app comes to foreground
    NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self, self.isAuthenticated else { return }

      Task {
        do {
          self.logger.info("Refreshing preferences after app returns to foreground")
          try await self.preferencesManager.fetchPreferences(forceRefresh: true)
        } catch {
          self.logger.error(
            "Error refreshing preferences on foreground: \(error.localizedDescription)")
        }
      }
    }

    logger.debug("Preferences periodic refresh timer set up")
  }

  // MARK: - OAuth Callback Handling

  /// Handles OAuth callback URLs - delegates to auth manager
  @MainActor
  func handleOAuthCallback(_ url: URL) async throws {
    logger.info("AppState handling OAuth callback")
    try await authManager.handleCallback(url)
  }

  /// Force updates the authentication state (used in rare cases where state updates aren't properly propagated)
  @MainActor
  func forceUpdateAuthState(_ isAuthenticated: Bool) {
    logger.warning("Force updating auth state to: \(isAuthenticated)")
    // This is a safety mechanism, prefer not to use it
  }

  // MARK: - User Settings

  /// Toggles adult content setting
  func toggleAdultContent() {
    isAdultContentEnabled.toggle()
    UserDefaults.standard.set(isAdultContentEnabled, forKey: "isAdultContentEnabled")
  }

  // MARK: - Feed Methods

  /// Stores a prefetched feed for faster initial loading
  func storePrefetchedFeed(
    _ posts: [AppBskyFeedDefs.FeedViewPost], cursor: String?, for fetchType: FetchType
  ) {
    prefetchedFeeds[fetchType] = (posts, cursor)
  }

  /// Gets a prefetched feed if available
  func getPrefetchedFeed(_ fetchType: FetchType) async -> (
    posts: [AppBskyFeedDefs.FeedViewPost], cursor: String?
  )? {
    return prefetchedFeeds[fetchType]
  }

  // MARK: - Convenience Accessors

  /// Access to the AT Protocol client
  var atProtoClient: ATProtoClient? {
    authManager.client
  }

  /// Update post manager when client changes
  private func updatePostManagerClient() {
    postManager.updateClient(authManager.client)
  }

  /// Check if user is authenticated
  var isAuthenticated: Bool {
    authManager.state.isAuthenticated
  }

  /// Current user's DID
  var currentUserDID: String? {
    authManager.state.userDID
  }

  /// Current auth state
  var authState: AuthState {
    authManager.state
  }

  // MARK: Navigation
  func configureURLHandler() {
    urlHandler.navigateAction = { [weak self] destination, tabIndex in

      self?.navigationManager.navigate(to: destination, in: tabIndex)
    }
  }

  // MARK: - Preferences Management

  /// Initializes the preferences manager with a model context
  @MainActor
  func initializePreferencesManager(with modelContext: ModelContext) {
    preferencesManager.setModelContext(modelContext)
    logger.debug("Initialized PreferencesManager with ModelContext")
  }

  // MARK: - Post Creation Method (for backward compatibility)

  /// Creates a new post or reply (delegates to PostManager)
  func createNewPost(
    _ postText: String,
    languages: [LanguageCodeContainer],
    metadata: [String: String],
    hashtags: [String],
    facets: [AppBskyRichtextFacet],
    parentPost: AppBskyFeedDefs.PostView?,
    selfLabels: ComAtprotoLabelDefs.SelfLabels,
    embed: AppBskyFeedPost.AppBskyFeedPostEmbedUnion?,
    threadgateAllowRules: [AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion]? = nil
  ) async throws {
    // Delegate to PostManager with the threadgate rules
    try await postManager.createPost(
      postText,
      languages: languages,
      metadata: metadata,
      hashtags: hashtags,
      facets: facets,
      parentPost: parentPost,
      selfLabels: selfLabels,
      embed: embed,
      threadgateAllowRules: threadgateAllowRules
    )
  }

  // MARK: - Push Notifications Setup

  /// Set up push notifications
  private func setupNotifications() {
    // Set the notification manager as the delegate for UNUserNotificationCenter
    UNUserNotificationCenter.current().delegate = notificationManager

    // Configure notification manager with app state reference for navigation
    notificationManager.configure(with: self)

    // Check current notification status
    Task {
      await notificationManager.checkNotificationStatus()
    }

    // Start background unread notification checking
    notificationManager.startUnreadNotificationChecking()

    // Observe notifications marked as seen
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleNotificationsMarkedAsSeen),
      name: NSNotification.Name("NotificationsMarkedAsSeen"),
      object: nil
    )

    // Also check when app comes to foreground
    NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { [weak self] in
        await self?.notificationManager.checkUnreadNotifications()
      }
    }
  }

  @objc private func handleNotificationsMarkedAsSeen() {
    notificationManager.updateUnreadCountAfterSeen()
  }

  /// Syncs notification-related user data with the server
  func syncNotificationData() async {
    await notificationManager.syncAllUserData()
  }

  // MARK: - Authentication Methods (for backward compatibility)

  /// Logs out the current user (delegates to AuthenticationManager)
  @MainActor
  func handleLogout() async throws {
    logger.info("Logout requested - delegating to AuthManager")

    // Clear preferences before logging out
    await preferencesManager.clearAllPreferences()
    logger.info("User preferences cleared during logout")

    // Perform the actual logout
    await authManager.logout()
  }

  /// Add a new account
  @MainActor
  func addAccount(handle: String) async throws -> URL {
    logger.info("Adding new account: \(handle)")
    return try await authManager.addAccount(handle: handle)
  }

  /// Remove an account
  @MainActor
  func removeAccount(did: String) async throws {
    logger.info("Removing account: \(did)")
    try await authManager.removeAccount(did: did)

    // Check if we still have any accounts
    if isAuthenticated {
      await refreshAfterAccountSwitch()
    }
  }

  // MARK: - Social Graph Methods

  @discardableResult
  func follow(did: String) async throws -> Bool {
    // graphManager is non-optional, direct access is safe if initialized correctly
    // Throwing an error if client isn't set might be handled within GraphManager itself
    return try await self.graphManager.follow(did: did)
  }

  // Using GraphError instead of AuthError
  @discardableResult
  func unfollow(did: String) async throws -> Bool {
    // graphManager is non-optional, direct access is safe if initialized correctly
    // Throwing an error if client isn't set might be handled within GraphManager itself
    return try await self.graphManager.unfollow(did: did)
  }

  // MARK: - Thread Creation / Post Management

  // Add support for thread creation with threadgates
  func createThread(
    posts: [String],
    languages: [LanguageCodeContainer],
    selfLabels: ComAtprotoLabelDefs.SelfLabels,
    hashtags: [String] = [],
    facets: [[AppBskyRichtextFacet]?] = [],
    embeds: [AppBskyFeedPost.AppBskyFeedPostEmbedUnion?]? = nil,
    threadgateAllowRules: [AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion]? = nil
  ) async throws {
    try await postManager.createThread(
      posts: posts,
      languages: languages,
      selfLabels: selfLabels,
      hashtags: hashtags,
      facets: facets,
      embeds: embeds,
      threadgateAllowRules: threadgateAllowRules
    )
  }
  
  // MARK: - Performance Optimization Methods

  /// Waits for the next refresh cycle of the app state
  /// This is a performance optimization method that allows components to wait for a good moment to update
  /// rather than using arbitrary fixed delays
  func waitForNextRefreshCycle() async {
    // Default implementation: a small but adaptive delay
    // In the future, this could be connected to actual app refresh cycles
    let baseDelay: UInt64 = 100_000_000  // 100ms base delay

    // Adjust based on current system load if needed
    let processingPressure = ProcessInfo.processInfo.thermalState

    let finalDelay: UInt64
    switch processingPressure {
    case .nominal:
      finalDelay = baseDelay
    case .fair:
      finalDelay = baseDelay * 2  // 200ms
    case .serious:
      finalDelay = baseDelay * 3  // 300ms
    case .critical:
      finalDelay = baseDelay * 4  // 400ms
    @unknown default:
      finalDelay = baseDelay
    }

    // Wait for the calculated delay
    try? await Task.sleep(nanoseconds: finalDelay)

    // Log at debug level for performance profiling
    //    logger.debug(
    //      "Completed waitForNextRefreshCycle (delay: \(Double(finalDelay) / 1_000_000_000.0))s"
    //    )
  }
}
