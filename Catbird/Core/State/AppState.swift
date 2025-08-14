import Foundation
import Nuke
import OSLog
import Petrel
import SwiftData
import SwiftUI
import UserNotifications
import AVKit

/// Central state container for the Catbird app
@Observable
final class AppState {
  // MARK: - Singleton Pattern
  
  /// Shared instance to prevent multiple AppState creation
  static let shared = AppState()
  
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
  @ObservationIgnored private let logger = Logger(subsystem: "blue.catbird", category: "AppState")

  // Authentication manager - handles all auth operations
  @ObservationIgnored let authManager = AuthenticationManager()  // Instance of the AuthenticationManager class defined in AuthManager.swift

  // Graph manager - handles social graph operations
  @ObservationIgnored var graphManager: GraphManager

  // URL handling for deep links
  @ObservationIgnored let urlHandler: URLHandler

  // User preference settings
  var isAdultContentEnabled: Bool = false

  // Used to track which tab was tapped twice to trigger scroll to top
  @ObservationIgnored var tabTappedAgain: Int?
  
  // Current user's profile data for optimistic updates
  @ObservationIgnored var currentUserProfile: AppBskyActorDefs.ProfileViewBasic?

  // MARK: - Component Managers

  /// Central event bus for coordinating state invalidation
  @ObservationIgnored let stateInvalidationBus = StateInvalidationBus()
  
  // Settings change tracking to prevent loops
  @ObservationIgnored private var lastSettingsHash: Int = 0
  @ObservationIgnored private var settingsUpdateDebounceTimer: Timer?

  /// Post shadow manager for handling interaction state (likes, reposts)
  @ObservationIgnored let postShadowManager = PostShadowManager.shared

  /// Post manager for handling post creation and management
  @ObservationIgnored let postManager: PostManager

  /// Preferences manager for handling user preferences
  @ObservationIgnored let preferencesManager = PreferencesManager()

  /// App-specific settings that aren't synced with the server
  @ObservationIgnored let appSettings = AppSettings()
  
  /// Font manager for handling typography and font settings - observes via fontDidChange
  @ObservationIgnored private let _fontManager = FontManager()
  
  /// Theme manager for handling app-wide theme changes - observes via themeDidChange
  @ObservationIgnored private let _themeManager: ThemeManager
  
  // MARK: - Observable Theme/Font State
  
  /// Observable theme state that triggers SwiftUI updates
  var themeDidChange: Int = 0
  
  /// Observable font state that triggers SwiftUI updates  
  var fontDidChange: Int = 0
  
  /// Public access to theme manager
  var themeManager: ThemeManager { _themeManager }
  
  /// Public access to font manager
  var fontManager: FontManager { _fontManager }

  /// Navigation manager for handling navigation
  @ObservationIgnored let navigationManager = AppNavigationManager()

  /// Feed filter settings manager
  @ObservationIgnored let feedFilterSettings = FeedFilterSettings()

  /// Notification manager for handling push notifications
  @ObservationIgnored let notificationManager = NotificationManager()
  
  /// Composer draft manager for handling minimized post composer drafts
  let composerDraftManager = ComposerDraftManager()
  
  /// List manager for handling list operations
  @ObservationIgnored var listManager: ListManager
  
  /// Observable chat unread count for UI updates
  var chatUnreadCount: Int = 0

  /// Chat manager for handling Bluesky chat operations
  @ObservationIgnored let chatManager: ChatManager
  
  
  /// Network monitor for tracking connectivity status
  @ObservationIgnored let networkMonitor = NetworkMonitor()
  
  /// Onboarding manager for tracking user onboarding progress
  @ObservationIgnored let onboardingManager = OnboardingManager()

  // MARK: - Feed State

  /// Cache of prefetched feeds by type
  @ObservationIgnored private let prefetchedFeedCache = PrefetchedFeedCache()

  // Flag to track if AuthManager initialization is complete
  @ObservationIgnored private var isAuthManagerInitialized = false

  // For task cancellation when needed
  @ObservationIgnored private var authStateObservationTask: Task<Void, Never>?
  @ObservationIgnored private var backgroundPollingTask: Task<Void, Never>?

  // MARK: - Initialization

  private init() {
    AppState.initializationCount += 1
    logger.debug("AppState initializing (instance #\(AppState.initializationCount))")
    
    if AppState.initializationCount > 1 {
      logger.warning("⚠️ Multiple AppState instances detected! This may indicate a problem with view recreation.")
    }
    
    let isFaultOrderingMode = ProcessInfo.processInfo.environment["FAULT_ORDERING_ENABLE"] == "1"
    
    self.urlHandler = URLHandler()

    // Initialize theme manager with font manager dependency
    self._themeManager = ThemeManager(fontManager: _fontManager)

    // Initialize post manager with nil client (will be updated later)
    self.postManager = PostManager(client: nil, appState: nil)

    // Initialize graph manager with nil client (will be updated when auth is complete)
    self.graphManager = GraphManager(atProtoClient: nil)

    // Initialize list manager with nil client (will be updated when auth is complete)
    self.listManager = ListManager(client: nil, appState: nil)

    // Initialize chat manager with nil client (will be updated with self reference after initialization)
    self.chatManager = ChatManager(client: nil, appState: nil)

    // Load user settings
      if let storedContentSetting = UserDefaults(suiteName: "group.blue.catbird.shared")?.object(forKey: "isAdultContentEnabled")
      as? Bool {
      self.isAdultContentEnabled = storedContentSetting
    }

    // Configure notification manager with app state reference (skip for FaultOrdering)
    if !isFaultOrderingMode {
      notificationManager.configure(with: self)
    }

    // Set up observation of authentication state changes (simplified for FaultOrdering)
    authStateObservationTask = Task { [weak self] in
      guard let self = self else { return }

      for await state in authManager.stateChanges {
        Task { @MainActor in
          // When auth state changes, update ALL manager client references
          if case .authenticated = state {
            self.postManager.updateClient(self.authManager.client)
            self.preferencesManager.updateClient(self.authManager.client)
            if !isFaultOrderingMode {
              self.notificationManager.updateClient(self.authManager.client)
            }
            if let client = self.authManager.client {
              self.graphManager = GraphManager(atProtoClient: client)
              self.listManager.updateClient(client)
              self.listManager.updateAppState(self)
              if !isFaultOrderingMode {
                await self.chatManager.updateClient(client) // Update ChatManager client
                self.urlHandler.configure(with: self)
              }
              
              if !isFaultOrderingMode {
                Task { @MainActor in
                  await self.notificationManager.requestNotificationsAfterLogin()
                }

                // Notify that authentication is complete to refresh all views
                self.notifyAccountSwitched()

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
                  
                  // User profile loaded successfully
                  
                  // Clear any stale widget data and trigger fresh load
                  Task {
                    FeedWidgetDataProvider.shared.clearWidgetData()
                  }
                }
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
            self.listManager.updateClient(nil)
            self.listManager.updateAppState(nil)
             await self.chatManager.updateClient(nil)
            
            // Clear widget data on logout
            FeedWidgetDataProvider.shared.clearWidgetData()
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
    appSettings.applyInitialThemeSettings(to: _themeManager)
    
    // Apply initial font settings immediately from UserDefaults
    appSettings.applyInitialFontSettings(to: _fontManager)
    
    // Set up theme/font change observation on main actor
    Task { @MainActor in
      setupThemeAndFontObservation()
    }      
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
    backgroundPollingTask?.cancel()
  }

  // MARK: - Background Polling

  private func startBackgroundPolling() {
    backgroundPollingTask = Task(priority: .background) {
      while !Task.isCancelled {
        await withTaskGroup(of: Void.self) { group in
          // Prune old feed models
          group.addTask {
            FeedModelContainer.shared.pruneOldModels(olderThan: 1800)
          }

          // Refresh preferences
          group.addTask {
            if self.isAuthenticated {
              do {
                try await self.preferencesManager.fetchPreferences(forceRefresh: true)
              } catch {
                self.logger.error("Error during periodic preferences refresh: \(error.localizedDescription)")
              }
            }
          }
        }

        // Wait for 5 minutes before the next poll
        try? await Task.sleep(for: .seconds(300))
      }
    }
  }

  // MARK: - App Initialization

  @MainActor
  func initialize() async {
    logger.info("🚀 Starting AppState.initialize()")
    
    // Fast path for FaultOrdering tests - skip expensive operations
    let isFaultOrderingMode = ProcessInfo.processInfo.environment["FAULT_ORDERING_ENABLE"] == "1" ||
                              ProcessInfo.processInfo.environment["RUN_FAULT_ORDER"] == "1" ||
                              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    
    if isFaultOrderingMode {
      logger.info("⚡ FaultOrdering mode - using minimal initialization")
      
      // Even more aggressive optimization - skip auth entirely if we have any stored credentials
      // This avoids both keychain operations and network token refresh
      let hasStoredCredentials = UserDefaults(suiteName: "group.blue.catbird.shared")?.data(forKey: "lastLoggedInUser") != nil
      
      if hasStoredCredentials {
        logger.info("⚡ Found stored credentials, marking as authenticated without keychain/network operations")
        // Mark as authenticated without going through full initialization
        // Note: authManager.setAuthenticatedStateForFaultOrdering() would be called here
        // but we'll skip full auth for now to speed up FaultOrdering
        self.isAuthManagerInitialized = true
      } else {
        logger.info("⚡ No stored credentials, doing minimal auth initialization")
        await authManager.initialize()
        self.isAuthManagerInitialized = true
      }
      
      // Skip ALL expensive operations
      logger.info("🏁 AppState.initialize() completed (FaultOrdering mode)")
      return
    }
    
    // Normal initialization path
    // Configure Nuke image pipeline with GIF support
    configureImagePipeline()
    
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
      listManager.updateClient(client)
      listManager.updateAppState(self)
           await chatManager.updateClient(client) // Update ChatManager client if uncommented
           updateChatUnreadCount() // Update chat unread count
    } else {
      graphManager = GraphManager(atProtoClient: nil)  // Ensure graphManager is also updated if client is nil post-init
      listManager.updateClient(nil)
      listManager.updateAppState(nil)
    }

    // Setup other components as needed (skip for FaultOrdering)
    if !isFaultOrderingMode {
      startBackgroundPolling()
      setupNotifications()
      setupChatObservers()
    }
    
    // Apply current theme settings (this will now use SwiftData if available, UserDefaults fallback otherwise)
    _themeManager.applyTheme(
      theme: appSettings.theme,
      darkThemeMode: appSettings.darkThemeMode
    )
    
    logger.info("Theme applied on startup: theme=\(self.appSettings.theme), darkMode=\(self.appSettings.darkThemeMode)")

    // Get accounts list if authenticated (skip for FaultOrdering)
    if isAuthenticated && !isFaultOrderingMode {
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
    
    // Connect VideoCoordinator to app settings for real-time autoplay updates
    VideoCoordinator.shared.appSettings = appSettings

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
    await prefetchedFeedCache.clear()

    // Update client references in all managers
    postManager.updateClient(authManager.client)
    preferencesManager.updateClient(authManager.client)
    notificationManager.updateClient(authManager.client)
        await chatManager.updateClient(authManager.client) // Update ChatManager client
        updateChatUnreadCount() // Update chat unread count
    if let client = authManager.client {
      graphManager = GraphManager(atProtoClient: client)
      listManager.updateClient(client)
      listManager.updateAppState(self)
    } else {
      graphManager = GraphManager(atProtoClient: nil)
      listManager.updateClient(nil)
      listManager.updateAppState(nil)
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
  ) async {
    await prefetchedFeedCache.set(posts, cursor: cursor, for: fetchType)
  }

  /// Gets a prefetched feed if available
  func getPrefetchedFeed(_ fetchType: FetchType) async -> (
    posts: [AppBskyFeedDefs.FeedViewPost], cursor: String?
  )? {
    return await prefetchedFeedCache.get(for: fetchType)
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

  /// The shared Nuke image pipeline
  var imagePipeline: ImagePipeline {
    ImagePipeline.shared
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
  
  /// Configure Nuke image pipeline with GIF animation support
  private func configureImagePipeline() {
    Task {
      // Use the custom pipeline from ImageLoadingManager which has GIF support enabled
      let pipeline = ImageLoadingManager.shared.pipeline
      await MainActor.run {
        ImagePipeline.shared = pipeline
        logger.info("Configured Nuke image pipeline with GIF animation support")
      }
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
    _themeManager.applyTheme(theme: appSettings.theme, darkThemeMode: appSettings.darkThemeMode)
    logger.info("Theme reapplied after SwiftData initialization: theme=\(self.appSettings.theme), darkMode=\(self.appSettings.darkThemeMode)")
    
    // Apply initial font settings
    _fontManager.applyFontSettings(
      fontStyle: self.appSettings.fontStyle,
      fontSize: self.appSettings.fontSize,
      lineSpacing: self.appSettings.lineSpacing,
      letterSpacing: self.appSettings.letterSpacing,
      dynamicTypeEnabled: self.appSettings.dynamicTypeEnabled,
      maxDynamicTypeSize: self.appSettings.maxDynamicTypeSize
    )
    
    // Set up proper reactive observation for settings changes
    setupSettingsObservation()
  }

  // MARK: - Theme and Font Observation
  
  /// Set up observation for theme and font manager changes
  @MainActor
  private func setupThemeAndFontObservation() {
    // Set up theme change observer that triggers SwiftUI updates
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("ThemeChanged"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      // Trigger SwiftUI update for theme changes
      self.themeDidChange += 1
      logger.debug("Theme change triggered SwiftUI update")
    }
    
    // Set up font change observer that triggers SwiftUI updates
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("FontChanged"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      // Trigger SwiftUI update for font changes
      self.fontDidChange += 1
      logger.debug("Font change triggered SwiftUI update")
    }
    
    logger.debug("Theme and font observation configured")
  }
  
  // MARK: - Settings Observation
  
  /// Set up reactive observation for settings changes with change tracking
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
      
      // Create a hash of current settings to detect actual changes
      let currentSettingsHash = self.createSettingsHash()
      
      // Only process if settings actually changed
      guard currentSettingsHash != self.lastSettingsHash else {
        self.logger.debug("Settings notification received but no actual changes detected")
        return
      }
      
      self.lastSettingsHash = currentSettingsHash
      self.logger.debug("Processing actual settings change (hash: \(currentSettingsHash))")
      
      // Debounce rapid setting changes
      self.settingsUpdateDebounceTimer?.invalidate()
      self.settingsUpdateDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
        guard let self = self else { return }
        
        self.logger.debug("Applying debounced settings change")
        
        // Apply theme when settings change
        self._themeManager.applyTheme(
          theme: self.appSettings.theme,
          darkThemeMode: self.appSettings.darkThemeMode
        )
        
        // Apply font settings when they change
        self._fontManager.applyFontSettings(
          fontStyle: self.appSettings.fontStyle,
          fontSize: self.appSettings.fontSize,
          lineSpacing: self.appSettings.lineSpacing,
          letterSpacing: self.appSettings.letterSpacing,
          dynamicTypeEnabled: self.appSettings.dynamicTypeEnabled,
          maxDynamicTypeSize: self.appSettings.maxDynamicTypeSize
        )
        
        // Trigger SwiftUI updates
        self.themeDidChange += 1
        self.fontDidChange += 1
        
        // Update URL handler with new browser preference
        self.urlHandler.useInAppBrowser = self.appSettings.useInAppBrowser
        
        // Update VideoCoordinator with new autoplay preference
        VideoCoordinator.shared.appSettings = self.appSettings
        
        self.logger.debug("Applied debounced settings changes - theme: \(self.appSettings.theme), font: \(self.appSettings.fontStyle)")
      }
    }
    
    logger.debug("Settings observation configured with change tracking")
  }
  
  /// Create a hash of current settings to detect actual changes
  private func createSettingsHash() -> Int {
    var hasher = Hasher()
    hasher.combine(appSettings.theme)
    hasher.combine(appSettings.darkThemeMode)
    hasher.combine(appSettings.fontStyle)
    hasher.combine(appSettings.fontSize)
    hasher.combine(appSettings.lineSpacing)
    hasher.combine(appSettings.letterSpacing)
    hasher.combine(appSettings.dynamicTypeEnabled)
    hasher.combine(appSettings.maxDynamicTypeSize)
    hasher.combine(appSettings.useInAppBrowser)
    hasher.combine(appSettings.autoplayVideos)
    hasher.combine(appSettings.allowTenor)
    hasher.combine(appSettings.requireAltText)
    hasher.combine(appSettings.reduceMotion)
    hasher.combine(appSettings.increaseContrast)
    hasher.combine(appSettings.boldText)
    hasher.combine(appSettings.displayScale)
    hasher.combine(appSettings.prefersCrossfade)
    hasher.combine(appSettings.largerAltTextBadges)
    hasher.combine(appSettings.disableHaptics)
    return hasher.finalize()
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

  /// Update chat unread count from chat manager
  @MainActor
  func updateChatUnreadCount() {
    let newCount = chatManager.totalUnreadCount
    if chatUnreadCount != newCount {
      chatUnreadCount = newCount
      logger.debug("Chat unread count updated: \(newCount)")
    }
  }
  
  /// Setup chat observers and background polling for unread messages
  private func setupChatObservers() {
    // Set up callback for when chat unread count changes
    chatManager.onUnreadCountChanged = { [weak self] in
      Task { @MainActor [weak self] in
        self?.updateChatUnreadCount()
      }
    }
    
    // Update chat unread count initially
    Task { @MainActor in
      updateChatUnreadCount()
    }
    
    // Set up periodic polling for chat messages (since they don't come through push notifications)
    Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self = self, case .authenticated = self.authState else { return }
        
        // Load conversations to check for new messages and update unread counts
        await self.chatManager.loadConversations(refresh: true)
        self.updateChatUnreadCount()
      }
    }
    
    // Also update when app comes to foreground
    NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self = self else { return }
        await self.chatManager.loadConversations(refresh: true)
        self.updateChatUnreadCount()
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
  
  /// Notify that authentication was completed (triggers initial feed load)
  @MainActor
  func notifyAuthenticationCompleted() {
    logger.info("Authentication completed notification")
    stateInvalidationBus.notifyAuthenticationCompleted()
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

// MARK: - Prefetched Feed Cache

actor PrefetchedFeedCache {
  private var cache: [FetchType: (posts: [AppBskyFeedDefs.FeedViewPost], cursor: String?)] = [:]

  func set(_ posts: [AppBskyFeedDefs.FeedViewPost], cursor: String?, for fetchType: FetchType) {
    cache[fetchType] = (posts, cursor)
  }

  func get(for fetchType: FetchType) -> (posts: [AppBskyFeedDefs.FeedViewPost], cursor: String?)? {
    return cache[fetchType]
  }

  func clear() {
    cache.removeAll()
  }
}
