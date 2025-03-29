import Foundation
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
        await MainActor.run {
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
              Task {
                do {
                  try await self.preferencesManager.fetchPreferences(forceRefresh: true)
                } catch {
                  self.logger.error(
                    "Error fetching preferences after authentication: \(error.localizedDescription)"
                  )
                }
              }
            }
          } else if case .unauthenticated = state {
            // Clear client on logout
            self.postManager.updateClient(nil)
            self.preferencesManager.updateClient(nil)
            self.notificationManager.updateClient(nil)
            self.graphManager = GraphManager(atProtoClient: nil)
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

  /// Refresh all data after account switching
  @MainActor
  func refreshAfterAccountSwitch() async {
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
      try await preferencesManager.fetchPreferences(forceRefresh: true)
      logger.info("Successfully refreshed preferences after account switch")
    } catch {
      logger.error("Failed to refresh preferences after account switch: \(error)")
    }

    // Refresh other data as needed
    // Any other state that needs resetting
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
      print("NavigateAction called with destination: \(destination)")

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
    embed: AppBskyFeedPost.AppBskyFeedPostEmbedUnion?
  ) async throws {
    // Delegate to PostManager
    try await postManager.createPost(
      postText,
      languages: languages,
      metadata: metadata,
      hashtags: hashtags,
      facets: facets,
      parentPost: parentPost,
      selfLabels: selfLabels,
      embed: embed
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

  /// Switch to another account
  @MainActor
  func switchToAccount(did: String) async throws {
    logger.info("Switching to account: \(did)")

    // First switch account through auth manager
    try await authManager.switchToAccount(did: did)

    // Then refresh all app state with new account data
    await refreshAfterAccountSwitch()
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

  // MARK: - Post Management

  // Add support for thread creation
  func createThread(
    posts: [String],
    languages: [LanguageCodeContainer],
    selfLabels: ComAtprotoLabelDefs.SelfLabels,
    hashtags: [String] = [],
    facets: [[AppBskyRichtextFacet]?] = [],
    embeds: [AppBskyFeedPost.AppBskyFeedPostEmbedUnion?]? = nil
  ) async throws {
    try await postManager.createThread(
      posts: posts,
      languages: languages,
      selfLabels: selfLabels,
      hashtags: hashtags,
      facets: facets,
      embeds: embeds
    )
  }
}
