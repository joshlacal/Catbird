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
  
  // Static tracking to prevent multiple instances
  private static var initializationCount = 0
  #if DEBUG
  // Reset method for debugging purposes only
  static func resetInitializationCount() {
    initializationCount = 0
  }
  #endif

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
  var tabTappedAgain: Int?
  
  // Current user's profile data for optimistic updates
  var currentUserProfile: AppBskyActorDefs.ProfileViewBasic?

  // MARK: - Component Managers

  /// Central event bus for coordinating state invalidation
  let stateInvalidationBus = StateInvalidationBus()

  /// Post shadow manager for handling interaction state (likes, reposts)
  let postShadowManager = PostShadowManager.shared

  /// Post manager for handling post creation and management
  let postManager: PostManager

  /// Preferences manager for handling user preferences
  let preferencesManager = PreferencesManager()

  /// App-specific settings that aren't synced with the server
  let appSettings = AppSettings()
  
  /// Theme manager for handling app-wide theme changes
  let themeManager = ThemeManager()
  
  /// Font manager for handling typography and font settings
  let fontManager = FontManager()

  /// Navigation manager for handling navigation
  let navigationManager = AppNavigationManager()

  /// Feed filter settings manager
  let feedFilterSettings = FeedFilterSettings()

  /// Notification manager for handling push notifications
  let notificationManager = NotificationManager()

  /// Chat manager for handling Bluesky chat operations
    let chatManager: ChatManager
  
  
  /// Network monitor for tracking connectivity status
  let networkMonitor = NetworkMonitor()

  // MARK: - Feed State

  /// Cache of prefetched feeds by type
  @ObservationIgnored private var prefetchedFeeds:
    [FetchType: (posts: [AppBskyFeedDefs.FeedViewPost], cursor: String?)] = [:]

  // Flag to track if AuthManager initialization is complete
  private var isAuthManagerInitialized = false

  // For task cancellation when needed
  @ObservationIgnored private var authStateObservationTask: Task<Void, Never>?

  // MARK: - Initialization

  init() {
    AppState.initializationCount += 1
    logger.debug("AppState initializing (instance #\(AppState.initializationCount))")
    
    if AppState.initializationCount > 1 {
      logger.warning("⚠️ Multiple AppState instances detected! This may indicate a problem with view recreation.")
    }
    self.urlHandler = URLHandler()

    // Initialize post manager with nil client (will be updated later)
    self.postManager = PostManager(client: nil, appState: nil)

    // Initialize graph manager with nil client (will be updated when auth is complete)
    self.graphManager = GraphManager(atProtoClient: nil)

    // Initialize chat manager with nil client (will be updated with self reference after initialization)
        self.chatManager = ChatManager(client: nil, appState: nil)

    // Load user settings
      if let storedContentSetting = UserDefaults(suiteName: "group.blue.catbird.shared")?.object(forKey: "isAdultContentEnabled")
      as? Bool {
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
                await self.chatManager.updateClient(client) // Update ChatManager client
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

                  guard let userDID = self.currentUserDID else {
                  self.logger.error("No current user DID after authentication")
                  return
                }

                // Wait briefly for auth to fully establish
                try? await Task.sleep(nanoseconds: 200_000_000)
                
                // Load current user profile for optimistic updates
                await self.loadCurrentUserProfile(did: userDID)
              }
            }
          } else if case .unauthenticated = state {
            // Always clear clients when state becomes unauthenticated, regardless of initialization status.
            self.logger.info("Auth state changed to unauthenticated. Clearing clients.")
            // Clear client on logout or session expiry
            self.postManager.updateClient(nil)
            self.preferencesManager.updateClient(nil)
            self.notificationManager.updateClient(nil)
            self.graphManager = GraphManager(atProtoClient: nil)
             await self.chatManager.updateClient(nil)
            // Add profile reset if needed
          } else if case .initializing = state {
            // Handle initializing state if needed
            self.logger.info("Auth state changed to initializing.")
          }
        }
      }
    }

    // Set up circular references after initialization
    postManager.updateAppState(self)
    chatManager.updateAppState(self)
    
    // Apply initial theme settings immediately from UserDefaults
    // This ensures proper theme is applied even before SwiftData is fully initialized
    appSettings.applyInitialThemeSettings(to: themeManager)
    
    // Apply initial font settings immediately from UserDefaults
    appSettings.applyInitialFontSettings(to: fontManager)
    
    // NOTE: Settings observation is set up later in initializePreferencesManager
    // to avoid duplicate observers
    
    logger.debug("AppState initialization complete")
  }
  
  deinit {
    logger.debug("AppState deinitializing (instance #\(AppState.initializationCount))")
    // Clean up notification observers
    NotificationCenter.default.removeObserver(self)
    // Cancel auth state observation task
    authStateObservationTask?.cancel()
  }

  // MARK: - App Initialization

  @MainActor
  func initialize() async {
    logger.info("🚀 Starting AppState.initialize()")
    configureURLHandler()

    // Initialize AuthManager FIRST
    await authManager.initialize()
    // Mark AuthManager initialization as complete AFTER it finishes
    self.isAuthManagerInitialized = true
    logger.info(
      "🏁 AuthManager.initialize() completed. isAuthManagerInitialized = \(self.isAuthManagerInitialized)"
    )

    // Update client references in all managers (potentially redundant if handled by stateChanges observer, but safe)
    // This ensures managers have the correct client *after* initialization completes.
    logger.info("Updating manager clients after AuthManager initialization.")
      
    postManager.updateClient(authManager.client)
    preferencesManager.updateClient(authManager.client)
    notificationManager.updateClient(authManager.client)
    if let client = authManager.client {
      graphManager = GraphManager(atProtoClient: client)
           await chatManager.updateClient(client) // Update ChatManager client if uncommented
    } else {
      graphManager = GraphManager(atProtoClient: nil)  // Ensure graphManager is also updated if client is nil post-init
    }

    // Setup other components as needed
    setupModelPruningTimer()
    setupPreferencesRefreshTimer()
    setupNotifications()
    
    // Apply current theme settings (this will now use SwiftData if available, UserDefaults fallback otherwise)
    themeManager.applyTheme(
      theme: appSettings.theme,
      darkThemeMode: appSettings.darkThemeMode
    )
    
    logger.info("Theme applied on startup: theme=\(self.appSettings.theme), darkMode=\(self.appSettings.darkThemeMode)")

    // Get accounts list if authenticated
    if isAuthenticated {
      Task {
        await authManager.refreshAvailableAccounts()

        // Synchronize server preferences with app settings
        do {
          try await preferencesManager.syncPreferencesWithAppSettings(self)
          logger.info("Successfully synchronized server preferences with app settings")
        } catch {
          logger.error("Failed to synchronize preferences: \(error.localizedDescription)")
        }
      }
    }

    logger.info("🏁 AppState.initialize() completed")
  }

  @MainActor
  func switchToAccount(did: String) async throws {
    logger.info("Switching to account: \(did)")

    // 3. Yield before account switch to ensure UI updates
    await Task.yield()
    logger.debug("SWITCH: Yielded after resetting profile state")

    // 4. Switch account in AuthManager
    try await authManager.switchToAccount(did: did)
    logger.debug("SWITCH: AuthManager switched account")

    // 5. Update client references in all managers
    await refreshAfterAccountSwitch()

    // 6. Notify that account was switched to trigger view refreshes
    notifyAccountSwitched()

    // 7. Wait to ensure client is ready
    try await Task.sleep(nanoseconds: 300_000_000)  // 300ms

  }

  @MainActor
  func refreshAfterAccountSwitch() async {
    // Update client references in all managers
    logger.info("Refreshing data after account switch")

    // Clear old prefetched data
    prefetchedFeeds.removeAll()

    // Update client references in all managers
    postManager.updateClient(authManager.client)
    preferencesManager.updateClient(authManager.client)
    notificationManager.updateClient(authManager.client)
        await chatManager.updateClient(authManager.client) // Update ChatManager client
    if let client = authManager.client {
      graphManager = GraphManager(atProtoClient: client)
    } else {
      graphManager = GraphManager(atProtoClient: nil)
    }

    // Reload preferences
    do {
      // Fetch preferences with force refresh to ensure we have the latest data
      try await preferencesManager.fetchPreferences(forceRefresh: true)
      logger.info("Successfully refreshed preferences after account switch")

      // Synchronize server preferences with app settings after account switch
      try await preferencesManager.syncPreferencesWithAppSettings(self)
      logger.info("Successfully synchronized preferences with app settings after account switch")
    } catch {
      logger.error("Failed to refresh preferences after account switch: \(error)")
    }
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
      UserDefaults(suiteName: "group.blue.catbird.shared")?.set(isAdultContentEnabled, forKey: "isAdultContentEnabled")
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
  
  // MARK: - User Profile Methods
  
  /// Load the current user's profile for optimistic updates
  @MainActor
  private func loadCurrentUserProfile(did: String) async {
    guard let client = atProtoClient else { return }
    
    do {
      let (responseCode, profileData) = try await client.app.bsky.actor.getProfile(
        input: .init(actor: ATIdentifier(string: did))
      )
      
      if responseCode == 200, let profile = profileData {
        // Convert ProfileViewDetailed to ProfileViewBasic
        currentUserProfile = AppBskyActorDefs.ProfileViewBasic(
          did: profile.did,
          handle: profile.handle,
          displayName: profile.displayName,
          avatar: profile.avatar,
          associated: profile.associated,
          viewer: profile.viewer,
          labels: profile.labels,
          createdAt: profile.createdAt,
          verification: profile.verification,
          status: profile.status
        )
        
        logger.debug("Loaded current user profile: @\(profile.handle.description)")
      } else {
        logger.error("Failed to load current user profile: HTTP \(responseCode)")
      }
    } catch {
      logger.error("Failed to load current user profile: \(error.localizedDescription)")
    }
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
    appSettings.initialize(with: modelContext)
    logger.debug("Initialized PreferencesManager and AppSettings with ModelContext")
    
    // Apply theme settings (now that SwiftData is available, this will use the persisted values)
    themeManager.applyTheme(theme: appSettings.theme, darkThemeMode: appSettings.darkThemeMode)
    logger.info("Theme reapplied after SwiftData initialization: theme=\(self.appSettings.theme), darkMode=\(self.appSettings.darkThemeMode)")
    
    // Apply initial font settings
    fontManager.applyFontSettings(
      fontStyle: self.appSettings.fontStyle,
      fontSize: self.appSettings.fontSize,
      lineSpacing: self.appSettings.lineSpacing,
      dynamicTypeEnabled: self.appSettings.dynamicTypeEnabled,
      maxDynamicTypeSize: self.appSettings.maxDynamicTypeSize
    )
    
    // Set up proper reactive observation for settings changes
    setupSettingsObservation()
  }

  // MARK: - Settings Observation
  
  /// Set up reactive observation for settings changes
  @MainActor
  private func setupSettingsObservation() {
    // Remove any existing observers to prevent duplicates
    NotificationCenter.default.removeObserver(self, name: NSNotification.Name("AppSettingsChanged"), object: nil)
    
    // Set up observation for theme and font changes via NotificationCenter
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("AppSettingsChanged"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      
      // Apply theme when settings change
      self.themeManager.applyTheme(
        theme: self.appSettings.theme,
        darkThemeMode: self.appSettings.darkThemeMode
      )
      
      // Apply font settings when they change
      self.fontManager.applyFontSettings(
        fontStyle: self.appSettings.fontStyle,
        fontSize: self.appSettings.fontSize,
        lineSpacing: self.appSettings.lineSpacing,
        dynamicTypeEnabled: self.appSettings.dynamicTypeEnabled,
        maxDynamicTypeSize: self.appSettings.maxDynamicTypeSize
      )
      
      // Update URL handler with new browser preference
      self.urlHandler.useInAppBrowser = self.appSettings.useInAppBrowser
      
      logger.debug("Applied settings changes - theme: \(self.appSettings.theme), font: \(self.appSettings.fontStyle)")
    }
    
    logger.debug("Settings observation configured")
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

    // Ensure widget has initial data - force update after a delay to allow app to fully initialize
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
      self.notificationManager.updateWidgetUnreadCount(self.notificationManager.unreadCount)
      self.logger.info(
        "Initializing widget data at app startup with count: \(self.notificationManager.unreadCount)"
      )
    }

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
  
  // MARK: - Post Composer Presentation
  
  /// Present the post composer for creating a new post, reply, or quote post
  @MainActor
  func presentPostComposer(parentPost: AppBskyFeedDefs.PostView? = nil, quotedPost: AppBskyFeedDefs.PostView? = nil) {
    // Create the post composer view with either a parent post (for reply) or quoted post
    let composerView = PostComposerView(
      parentPost: parentPost,
      quotedPost: quotedPost,
      appState: self
    )
    .environment(self) // Explicitly provide the AppState to the environment
    
    // Create a UIHostingController for the SwiftUI view
    let hostingController = UIHostingController(rootView: composerView)
    
    // Configure presentation style
    hostingController.modalPresentationStyle = .formSheet
    hostingController.isModalInPresentation = true
    
    // Present the composer using the shared window scene
    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let rootViewController = windowScene.windows.first?.rootViewController {
       rootViewController.present(hostingController, animated: true)
    }
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
  
  // MARK: - State Invalidation Methods
  
  /// Notify that a post was created (triggers feed refresh)
  @MainActor
  func notifyPostCreated(_ post: AppBskyFeedDefs.PostView) {
    logger.info("Post created notification: \(post.uri)")
    stateInvalidationBus.notifyPostCreated(post)
  }
  
  /// Notify that a reply was created (triggers thread and feed refresh)
  @MainActor
  func notifyReplyCreated(_ reply: AppBskyFeedDefs.PostView, parentUri: String) {
    logger.info("Reply created notification: \(reply.uri) -> \(parentUri)")
    stateInvalidationBus.notifyReplyCreated(reply, parentUri: parentUri)
  }
  
  /// Notify that account was switched (triggers full state refresh)
  @MainActor
  func notifyAccountSwitched() {
    logger.info("Account switched notification")
    stateInvalidationBus.notifyAccountSwitched()
  }
  
  /// Notify that a feed was updated
  @MainActor
  func notifyFeedUpdated(_ fetchType: FetchType) {
    logger.debug("Feed updated notification: \(fetchType.identifier)")
    stateInvalidationBus.notifyFeedUpdated(fetchType)
  }
  
  /// Notify that a profile was updated
  @MainActor
  func notifyProfileUpdated(_ did: String) {
    logger.debug("Profile updated notification: \(did)")
    stateInvalidationBus.notifyProfileUpdated(did)
  }
  
  /// Notify that a thread was updated
  @MainActor
  func notifyThreadUpdated(_ rootUri: String) {
    logger.debug("Thread updated notification: \(rootUri)")
    stateInvalidationBus.notifyThreadUpdated(rootUri)
  }
}
