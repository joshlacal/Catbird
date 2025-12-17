import AVKit
import CatbirdMLSCore
import Foundation
import GRDB
import NaturalLanguage
import Nuke
import OSLog
import Petrel
import SwiftData
import SwiftUI
import UserNotifications

#if os(iOS)
import UIKit
#endif

// MARK: - MLS Service State

/// Observable state tracking MLS service initialization with retry logic
@Observable
final class MLSServiceState {
  var status: MLSInitStatus = .notStarted
  var retryCount: Int = 0
  var lastError: Error?
  let maxRetries: Int = 3
  
  /// Tracks database failure state with cooldown
  var databaseFailedAt: Date?
  
  /// Cooldown period before allowing database retry (5 minutes)
  let databaseRetryCooldown: TimeInterval = 300

  enum MLSInitStatus: Equatable {
    case notStarted
    case initializing
    case ready
    case failed(String)
    case retrying(attempt: Int)
    /// Database is severely corrupted and needs manual intervention or app restart
    case databaseFailed(String)

    static func == (lhs: MLSInitStatus, rhs: MLSInitStatus) -> Bool {
      switch (lhs, rhs) {
      case (.notStarted, .notStarted),
           (.initializing, .initializing),
           (.ready, .ready):
        return true
      case let (.failed(lhsMsg), .failed(rhsMsg)):
        return lhsMsg == rhsMsg
      case let (.retrying(lhsAttempt), .retrying(rhsAttempt)):
        return lhsAttempt == rhsAttempt
      case let (.databaseFailed(lhsMsg), .databaseFailed(rhsMsg)):
        return lhsMsg == rhsMsg
      default:
        return false
      }
    }
    
    /// Check if the service is in a state that should prevent polling
    var shouldStopPolling: Bool {
      switch self {
      case .databaseFailed, .failed:
        return true
      case .notStarted, .initializing, .ready, .retrying:
        return false
      }
    }
  }
  
  /// Check if we're within the cooldown period after database failure
  var isInDatabaseCooldown: Bool {
    guard let failedAt = databaseFailedAt else { return false }
    return Date().timeIntervalSince(failedAt) < databaseRetryCooldown
  }
  
  /// Mark database as failed - stops polling until cooldown expires
  func markDatabaseFailed(message: String) {
    status = .databaseFailed(message)
    databaseFailedAt = Date()
  }
  
  /// Clear database failure state (call after successful recovery)
  func clearDatabaseFailure() {
    if case .databaseFailed = status {
      status = .notStarted
    }
    databaseFailedAt = nil
  }
}

// MARK: - AppState

/// Central state container for the Catbird app
@Observable
final class AppState {
  // MARK: - Nested Types

  struct SearchRequest: Equatable {
    enum Focus: Equatable {
      case all
      case profiles
      case posts
      case feeds
    }

    let id: UUID
    let query: String
    let focus: Focus
    let originProfileDID: String?

    init(query: String, focus: Focus = .posts, originProfileDID: String? = nil) {
      self.id = UUID()
      self.query = query
      self.focus = focus
      self.originProfileDID = originProfileDID
    }
  }

  struct ReauthenticationRequest: Equatable {
    let id: UUID
    let handle: String
    let did: String
    let authURL: URL

    init(handle: String, did: String, authURL: URL) {
      self.id = UUID()
      self.handle = handle
      self.did = did
      self.authURL = authURL
    }
  }

  // MARK: - Core Properties

  /// User DID for this AppState instance (one AppState per account)
  let userDID: String

  /// Authenticated Petrel client (passed from AppStateManager)
  let client: ATProtoClient

  /// MLS database pool for encrypted messaging storage
  private(set) var mlsDatabase: DatabasePool?

  @ObservationIgnored private var isMLSStorageFlushInProgress = false

  // Logger
  @ObservationIgnored private let logger = Logger(subsystem: "blue.catbird", category: "AppState")

  // Graph manager - handles social graph operations
  @ObservationIgnored var graphManager: GraphManager

  // URL handling for deep links
  @ObservationIgnored let urlHandler: URLHandler

  // User preference settings
  var isAdultContentEnabled: Bool = false

  // Used to track which tab was tapped twice to trigger scroll to top
  // NOTE: This needs to be observable so UIKit controllers can react to it
  var tabTappedAgain: Int?

  // Current user's profile data for optimistic updates
  @ObservationIgnored var currentUserProfile: AppBskyActorDefs.ProfileViewBasic?

  // Account switching transition state for smooth UX
  // NOTE: Do NOT use @ObservationIgnored here - SwiftUI must observe this to dismiss the loading overlay
  var isTransitioningAccounts: Bool = false
  @ObservationIgnored var prewarmingFeedData: [AppBskyFeedDefs.FeedViewPost]?

  // MARK: - Component Managers

  /// Central event bus for coordinating state invalidation
  @ObservationIgnored let stateInvalidationBus = StateInvalidationBus()

  // Settings change tracking to prevent loops
  @ObservationIgnored private var lastSettingsHash: Int = 0
  @ObservationIgnored private var settingsUpdateDebounceTimer: Timer?

  /// Post shadow manager for handling interaction state (likes, reposts) - per account
  @ObservationIgnored let postShadowManager: PostShadowManager

  /// Bookmarks manager for handling bookmark operations - per account
  @ObservationIgnored let bookmarksManager: BookmarksManager

  /// Post manager for handling post creation and management
  @ObservationIgnored let postManager: PostManager

  /// Preferences manager for handling user preferences
  @ObservationIgnored let preferencesManager = PreferencesManager()

  /// Feed feedback manager for custom feed interactions
  @ObservationIgnored let feedFeedbackManager = FeedFeedbackManager()

  /// Age verification manager (deprecated; retained for source compatibility, no UI)
  @ObservationIgnored let ageVerificationManager = AgeVerificationManager()

  /// App-specific settings that aren't synced with the server
  @ObservationIgnored let appSettings = AppSettings()

  /// Font manager for handling typography and font settings - observes via fontDidChange
  @ObservationIgnored private let _fontManager = FontManager()

  #if canImport(FoundationModels)
    /// Shared Bluesky intelligence agent storage (lazy)
    @ObservationIgnored private var blueskyAgentStorage: Any?
  #endif

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

  /// Pending search request to be handled by the dedicated search tab
  @ObservationIgnored var pendingSearchRequest: SearchRequest?

  /// Pending reauthentication request when account switching fails due to expired tokens
  @ObservationIgnored var pendingReauthenticationRequest: ReauthenticationRequest?

  /// Feed filter settings manager
  @ObservationIgnored let feedFilterSettings = FeedFilterSettings()

  /// Persisted App Attest metadata shared with the notification service.
  var appAttestInfo: AppAttestInfo? {
    didSet {
      persistAppAttestInfo(appAttestInfo)
    }
  }

  /// Notification manager for handling push notifications
  @ObservationIgnored let notificationManager = NotificationManager()

  /// Activity subscription manager for app-level access
  @ObservationIgnored
  private var activitySubscriptionServiceStorage: ActivitySubscriptionService?

  @MainActor
  var activitySubscriptionService: ActivitySubscriptionService {
    if let existing = activitySubscriptionServiceStorage {
      return existing
    }

    let service = ActivitySubscriptionService(
      client: nil,
      notificationManager: notificationManager
    )
    activitySubscriptionServiceStorage = service
    return service
  }

  /// Composer draft manager for handling minimized post composer drafts
  @ObservationIgnored var composerDraftManager: ComposerDraftManager

  /// Toast manager for displaying temporary notifications
  @ObservationIgnored let toastManager = ToastManager()

  /// List manager for handling list operations
  @ObservationIgnored var listManager: ListManager

  /// Post hiding manager for hiding/unhiding posts with server sync
  @ObservationIgnored var postHidingManager: PostHidingManager

  #if os(iOS)
    /// Observable chat unread count for UI updates (Bluesky DMs)
    var chatUnreadCount: Int = 0

    /// Observable MLS unread count for UI updates (Catbird Groups)
    var mlsUnreadCount: Int = 0

    /// Combined unread count for Messages tab badge (Bluesky DMs + MLS)
    var totalMessagesUnreadCount: Int {
      chatUnreadCount + mlsUnreadCount
    }

    /// Chat manager for handling Bluesky chat operations
    @ObservationIgnored let chatManager: ChatManager

    /// MLS API client for encrypted messaging
    @ObservationIgnored
    private var mlsAPIClientStorage: MLSAPIClient?

    /// MLS conversation manager for group operations
    @ObservationIgnored
    private var mlsConversationManagerStorage: MLSConversationManager?

    /// Task for initializing MLS conversation manager (prevents concurrent initialization)
    @ObservationIgnored
    private var mlsConversationManagerInitTask: Task<MLSConversationManager?, Never>?

    /// MLS event stream manager for real-time messaging
    @ObservationIgnored
    private var mlsEventStreamManagerStorage: MLSEventStreamManager?

    /// Persistent cursor storage for MLS SSE resume
    @ObservationIgnored
    private var mlsCursorStoreContainerStorage: ModelContainer?

    /// Cursor store for MLS SSE resume (scoped to this account)
    @ObservationIgnored
    private var mlsCursorStoreStorage: CursorStore?

    /// MLS conversations list for encrypted messaging
    @ObservationIgnored var mlsConversations: [MLSConversationViewModel] = []

    /// Observable counter that triggers SwiftUI updates when MLS conversations change
    var mlsConversationsDidChange: Int = 0

    /// Profile enricher for MLS participants
    @ObservationIgnored
    let mlsProfileEnricher = MLSProfileEnricher()

    /// MLS service state for retry logic and status tracking
    @ObservationIgnored var mlsServiceState = MLSServiceState()
  #endif

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
  @ObservationIgnored private var chatPollingTimer: Timer?

  @ObservationIgnored private let appAttestDefaultsKey = "catbird.appAttestInfo"

  private var appAttestDefaults: UserDefaults {
    UserDefaults(suiteName: "group.blue.catbird.shared") ?? .standard
  }

  // MARK: - Initialization

  init(userDID: String, client: ATProtoClient) {
    self.userDID = userDID
    self.client = client
    logger.info("AppState initializing for account: \(userDID)")

    let isFaultOrderingMode = ProcessInfo.processInfo.environment["FAULT_ORDERING_ENABLE"] == "1"

    self.urlHandler = URLHandler()

    // Create per-account manager instances
    self.postShadowManager = PostShadowManager()
    self.bookmarksManager = BookmarksManager()

    // Initialize composer draft manager
    self.composerDraftManager = ComposerDraftManager(appState: nil)

    // Initialize theme manager with font manager dependency
    self._themeManager = ThemeManager(fontManager: _fontManager)

    // Initialize post manager with authenticated client
    self.postManager = PostManager(client: client, appState: nil)

    // Initialize graph manager with authenticated client
    self.graphManager = GraphManager(atProtoClient: client)

    // Initialize list manager with authenticated client
    self.listManager = ListManager(client: client, appState: nil)

    // Initialize post hiding manager (preferences manager will be set after auth)
    self.postHidingManager = PostHidingManager()

    #if os(iOS)
      // Initialize chat manager with authenticated client
      self.chatManager = ChatManager(client: client, appState: nil)
    #endif

    // Load user settings
    if let storedContentSetting = UserDefaults(suiteName: "group.blue.catbird.shared")?.object(
      forKey: "isAdultContentEnabled")
      as? Bool
    {
      self.isAdultContentEnabled = storedContentSetting
    }

    self.appAttestInfo = loadPersistedAppAttestInfo()

    // Configure notification manager with app state reference (skip for FaultOrdering)
    if !isFaultOrderingMode {
      notificationManager.configure(with: self)
    }

    // NOTE: Auth state observation removed in new architecture
    // Client is passed in already authenticated, no need to observe state changes
    // Managers are initialized with the client in init

    /* REMOVED: authStateObservationTask observer - no longer needed
    authStateObservationTask = Task { [weak self] in
      guard let self = self else { return }

      for await state in XYZ.stateChanges {
        Task { @MainActor in
          // Update currentUserDID when auth state changes
          let newDID = state.userDID
          if self.currentUserDID != newDID {
            self.currentUserDID = newDID
          }

          // When auth state changes, update ALL manager client references
          if case .authenticated = state {
            // Setup MLS database for authenticated user
            if let userDID = state.userDID {
              self.logger.info("🔐 User authenticated - setting up MLS database")
              await self.setupMLSDatabase(for: userDID)
            }

            self.postManager.updateClient(self.client)
            self.preferencesManager.updateClient(self.client)
            if !isFaultOrderingMode {
              await self.notificationManager.updateClient(self.client)
            }
            if let client = self.client {
              self.graphManager = GraphManager(atProtoClient: client)
              self.listManager.updateClient(client)
              self.listManager.updateAppState(self)
              self.activitySubscriptionService.updateClient(client)

              // Update preferences manager reference and load hidden posts
              Task { @MainActor in
                self.postHidingManager.updatePreferencesManager(self.preferencesManager)
                await self.postHidingManager.loadFromPreferences()
              }

#if canImport(FoundationModels)
              if #available(iOS 26.0, macOS 15.0, *), !isFaultOrderingMode {
                let agent = self.blueskyAgent
                Task {
                  await agent.updateClient(client)
                }
              }
#endif
#if canImport(FoundationModels)
              if #available(iOS 26.0, macOS 15.0, *), !isFaultOrderingMode {
                Task(priority: .background) {
                  await TopicSummaryService.shared.prepareLaunchWarmup(appState: self)
                }
              }
#endif
              #if os(iOS)
              if !isFaultOrderingMode {
                self.chatManager.updateAppState(self) // Wire AppState reference to ChatManager
                await self.chatManager.updateClient(client) // Update ChatManager client
                self.urlHandler.configure(with: self)
              }
              #else
              if !isFaultOrderingMode {
                self.urlHandler.configure(with: self)
              }
              #endif

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

                  Task { @MainActor in
                    await self.activitySubscriptionService.refreshSubscriptions()
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

            // Close MLS database for logged out user
            if let oldUserDID = self.currentUserDID {
              self.logger.info("🔒 User logged out - closing MLS database")
              await self.clearMLSDatabase(for: oldUserDID)
            }

            // Clear current user profile on logout/session expiry
            self.currentUserProfile = nil
            self.logger.debug("Cleared current user profile on unauthenticated state")

            // Clear user-specific composer drafts
            self.logger.debug("Cleared composer drafts on unauthenticated state")

            // Clear client on logout or session expiry
            self.postManager.updateClient(nil)
            self.preferencesManager.updateClient(nil)
            await self.notificationManager.updateClient(nil)
            self.graphManager = GraphManager(atProtoClient: nil)
            self.listManager.updateClient(nil)
            self.listManager.updateAppState(nil)
            self.activitySubscriptionService.updateClient(nil)
            self.postHidingManager.updatePreferencesManager(nil)
#if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 15.0, *) {
              if let agent = self.blueskyAgentStorage as? BlueskyIntelligenceAgent {
                Task {
                  await agent.updateClient(nil)
                }
              }
            }
#endif
            #if os(iOS)
            await self.chatManager.updateClient(nil)
            #endif

            // Clear widget data on logout
            FeedWidgetDataProvider.shared.clearWidgetData()
          } else if case .initializing = state {
            // Handle initializing state if needed
            self.logger.info("Auth state changed to initializing.")
          }
        }
      }
    }
    */ // End of removed authStateObservationTask

    // Set up circular references after initialization
    postManager.updateAppState(self)
    composerDraftManager.updateAppState(self)
    #if os(iOS)
      chatManager.updateAppState(self)
    #endif

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
    // Clean up notification observers
    NotificationCenter.default.removeObserver(self)
    // Cancel auth state observation task
    authStateObservationTask?.cancel()
    backgroundPollingTask?.cancel()
  }

  /// Cleanup method called when this AppState is evicted from cache
  /// This cancels long-running tasks and releases resources without deallocating the object
  @MainActor
  func cleanup() {
    logger.info("🧹 Cleaning up AppState for user: \(self.userDID)")

    // Cancel long-running tasks
    authStateObservationTask?.cancel()
    authStateObservationTask = nil

    backgroundPollingTask?.cancel()
    backgroundPollingTask = nil

    chatPollingTimer?.invalidate()
    chatPollingTimer = nil

    #if os(iOS)
      // CRITICAL FIX: Properly shutdown MLS managers to prevent database exhaustion
      // and race conditions during account switching
      mlsConversationManagerInitTask?.cancel()
      mlsConversationManagerInitTask = nil

      // Stop observing for NSE state change notifications
      // This prevents callbacks to a cleaned-up AppState
      MLSStateChangeNotifier.shared.stopObserving()
      logger.debug("🔕 Stopped observing for MLS state change notifications")

      // Capture references for async cleanup
      let conversationManager = mlsConversationManagerStorage
      let eventStreamManager = mlsEventStreamManagerStorage
      let userDIDForCleanup = userDID

      // Clear references immediately to prevent new operations
      mlsConversationManagerStorage = nil
      mlsEventStreamManagerStorage = nil
      mlsAPIClientStorage = nil

      // Perform async cleanup in background task
      Task {
        // Stop all event stream subscriptions FIRST and WAIT for completion
        // CRITICAL: SSE tasks may still be writing to the database
        if let eventManager = eventStreamManager {
          await eventManager.stopAllAndWait(timeout: 2.0)
        }

        // Shutdown conversation manager (cancels background tasks, drains DB queue)
        if let manager = conversationManager {
          await manager.shutdown()
        }

        // ═══════════════════════════════════════════════════════════════════════════
        // CRITICAL FIX (2024-12): Close MLS FFI context to flush ratchet state
        // ═══════════════════════════════════════════════════════════════════════════
        // The MLS FFI context (Rust layer) contains the cryptographic ratchet state.
        // If not flushed before closing, the ratchet advancement is lost, causing
        // SecretReuseError when the context is reopened.
        // ═══════════════════════════════════════════════════════════════════════════
        await MLSClient.shared.closeContext(for: userDIDForCleanup)
        
        // Close the GRDB database pool to release connections
        // CRITICAL FIX: Use closeDatabaseAndDrain to prevent WAL corruption
        await MLSGRDBManager.shared.closeDatabaseAndDrain(for: userDIDForCleanup, timeout: 5.0)
      }

      logger.info("🧹 MLS cleanup initiated for user: \(self.userDID)")
    #endif

    logger.debug("AppState cleanup complete")
  }

  // MARK: - Background Polling

  private func startBackgroundPolling() {
    backgroundPollingTask = Task(priority: .background) {
      var pollingCycleCount = 0
      
      while !Task.isCancelled {
        pollingCycleCount += 1
        
        await withTaskGroup(of: Void.self) { group in
          // Prune old feed models
          group.addTask {
            FeedModelContainer.shared.pruneOldModels(olderThan: 1800)
          }

          // Refresh preferences
          group.addTask {
            if await self.isAuthenticated {
              do {
                try await self.preferencesManager.fetchPreferences(forceRefresh: true)
              } catch {
                self.logger.error(
                  "Error during periodic preferences refresh: \(error.localizedDescription)")
              }
            }
          }
          
          // ═══════════════════════════════════════════════════════════════════════════
          // PERIODIC WAL HEALTH CHECK (2024-12): Monitor database health every 6 cycles
          // ═══════════════════════════════════════════════════════════════════════════
          // Every 30 minutes (6 * 5 min cycles), check WAL file health and log metrics.
          // This helps detect growing WAL files before they cause problems.
          // ═══════════════════════════════════════════════════════════════════════════
          if pollingCycleCount % 6 == 0 {
            group.addTask {
              #if os(iOS)
              let healthStatuses = await MLSGRDBManager.shared.checkAllWALHealth()
              let criticalCount = healthStatuses.filter { $0.status == .critical }.count
              let warningCount = healthStatuses.filter { $0.status == .warning }.count
              
              if criticalCount > 0 || warningCount > 0 {
                self.logger.warning("📊 WAL Health Check: \(criticalCount) critical, \(warningCount) warning")
                
                // Attempt passive checkpoint for problematic databases
                await MLSGRDBManager.shared.performIdleMaintenance(aggressiveCheckpoint: false)
              }
              
              // Log connection pool metrics
              let metrics = await MLSGRDBManager.shared.getConnectionPoolMetrics()
              if metrics.status != .healthy {
                self.logger.warning("📊 Connection Pool: \(metrics.status.rawValue) - \(metrics.openDatabaseCount) open, \(metrics.recentForceCloseCount) recent force closes")
              }
              #endif
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
    logger.info("🚀 Starting AppState.initialize() for user: \(self.userDID)")

    // Fast path for FaultOrdering tests - skip expensive operations
    let isFaultOrderingMode =
      ProcessInfo.processInfo.environment["FAULT_ORDERING_ENABLE"] == "1"
      || ProcessInfo.processInfo.environment["RUN_FAULT_ORDER"] == "1"
      || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    if isFaultOrderingMode {
      logger.info("⚡ FaultOrdering mode - using minimal initialization")
      // Skip ALL expensive operations
      logger.info("🏁 AppState.initialize() completed (FaultOrdering mode)")
      return
    }

    // Normal initialization path
    // Configure Nuke image pipeline with GIF support
    configureImagePipeline()

    configureURLHandler()

    // NOTE: Auth initialization removed - client is already authenticated and passed in init
    // All managers were initialized with the client in init

    // MLS database setup is now lazy - it will be initialized when user first accesses MLS chat
    // This saves ~50-100ms on app startup for users who don't use encrypted messaging
    logger.info("🔐 MLS database will be initialized lazily when first accessed")

    // Update manager client references (should already be set from init, but ensure consistency)
    logger.info("Updating manager clients for authenticated user")

    postManager.updateClient(client)
    preferencesManager.updateClient(client)
    await notificationManager.updateClient(client)
    graphManager = GraphManager(atProtoClient: client)
    listManager.updateClient(client)
    listManager.updateAppState(self)

    #if os(iOS)
      chatManager.updateAppState(self)
      await chatManager.updateClient(client)
      updateChatUnreadCount()
    #endif

    // Setup other components as needed (skip for FaultOrdering)
    if !isFaultOrderingMode {
      startBackgroundPolling()
      setupNotifications()
      #if os(iOS)
        setupChatObservers()
      #endif
    }

    // Apply current theme settings (this will now use SwiftData if available, UserDefaults fallback otherwise)
    _themeManager.applyTheme(
      theme: appSettings.theme,
      darkThemeMode: appSettings.darkThemeMode,
      forceImmediateNavigationTypography: true
    )

    logger.info(
      "Theme applied on startup: theme=\(self.appSettings.theme), darkMode=\(self.appSettings.darkThemeMode)"
    )

    // Get accounts list if authenticated (skip for FaultOrdering)
    if isAuthenticated && !isFaultOrderingMode {
      Task {
        await AppStateManager.shared.authentication.refreshAvailableAccounts()

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

  // REMOVED: switchToAccount(did:) method
  // AppState represents a SINGLE account (userDID is immutable).
  // Account switching is handled by AppStateManager, which creates/retrieves different AppState instances.
  // See AppStateManager.switchAccount(to:withDraft:) for proper account switching.

  @MainActor
  func refreshAfterAccountSwitch() async {
    logger.info("Refreshing data after account switch")
    isTransitioningAccounts = true

    // Clear old prefetched data and any shadowed interactions
    await prefetchedFeedCache.clear()
    await postShadowManager.clearAll()

    // Update client references in all managers before kicking off parallel refresh work
    postManager.updateClient(client)
    preferencesManager.updateClient(client)
    await notificationManager.updateClient(client)

    #if os(iOS)
      chatManager.updateAppState(self)  // Wire AppState reference to ChatManager
      await chatManager.updateClient(client)  // Update ChatManager client
      updateChatUnreadCount()  // Update chat unread count

    #endif

    // Client is non-optional now, so we can use it directly
    graphManager = GraphManager(atProtoClient: client)
    listManager.updateClient(client)
    listManager.updateAppState(self)

    // Run the heavyweight refresh in the background to keep the UI responsive
    Task(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      await self.runPostSwitchRefreshWork()
    }

    // Drop the transition overlay quickly; refresh work continues in the background
    isTransitioningAccounts = false
  }

  @MainActor
  private func runPostSwitchRefreshWork() async {
    logger.info("🔐 Setting up MLS database for account: \(self.userDID)")
    async let mlsDatabaseTask: Void = setupMLSDatabase(for: userDID)
    async let preferencesTask: Void = refreshPreferencesAfterAccountSwitch()
    async let profileTask: Void = loadCurrentUserProfile(did: userDID)

    // Pre-warm following feed without blocking the main transition
    Task(priority: .userInitiated) { [weak self] in
      await self?.prewarmFollowingFeed()
    }

    await mlsDatabaseTask
    #if os(iOS)
      await reinitializeMLSAfterSwitch()
    #endif

    await preferencesTask
    await profileTask
  }

  @MainActor
  private func refreshPreferencesAfterAccountSwitch() async {
    do {
      try await preferencesManager.fetchPreferences(forceRefresh: true)
      logger.info("Successfully refreshed preferences after account switch")

      try await preferencesManager.syncPreferencesWithAppSettings(self)
      logger.info("Successfully synchronized preferences with app settings after account switch")
    } catch {
      logger.error("Failed to refresh preferences after account switch: \(error)")
    }
  }

  #if os(iOS)
    @MainActor
    private func reinitializeMLSAfterSwitch() async {
      // CRITICAL FIX: Properly shutdown MLS managers BEFORE clearing references
      // This prevents:
      // 1. SQLite database exhaustion (error 7: out of memory)
      // 2. Disk I/O errors (error 10) from unclosed connections
      // 3. Race conditions where old managers continue polling after switch
      // 4. Account mismatch errors in sync operations
      
      logger.info("MLS: 🔄 Beginning graceful shutdown for account switch")
      
      // Step 1: Cancel any pending initialization to prevent new manager creation
      mlsConversationManagerInitTask?.cancel()
      mlsConversationManagerInitTask = nil
      
      // Step 2: Stop event stream subscriptions FIRST and WAIT for completion
      // CRITICAL FIX: SSE tasks may still be writing to the database. We must wait
      // for them to fully complete, not just cancel them, to prevent WAL corruption.
      if let eventManager = mlsEventStreamManagerStorage {
        logger.info("MLS: Stopping event stream subscriptions and waiting for completion...")
        await eventManager.stopAllAndWait(timeout: 2.0)
        mlsEventStreamManagerStorage = nil
        logger.info("MLS: ✅ Event streams fully stopped")
      }
      
      // Step 3: Shutdown conversation manager with STRICT timeout
      // CRITICAL FIX: Use TaskGroup to enforce timeout on shutdown
      // This prevents the "Database drain timed out" issue from blocking account switch
      if let manager = mlsConversationManagerStorage {
        logger.info("MLS: Shutting down conversation manager with timeout...")
        
        let oldManager = manager
        let shutdownTask = Task { await oldManager.shutdown() }

        let shutdownResult: Bool? = await withTaskGroup(of: Bool?.self) { group in
          // Task 1: Wait for graceful shutdown (do NOT run shutdown inside the group so we don't cancel it on timeout)
          group.addTask { await shutdownTask.value }

          // Task 2: Timeout after 3 seconds
          group.addTask {
            try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3 seconds
            return nil
          }

          let first = await group.next() ?? nil
          group.cancelAll()
          return first
        }

        if shutdownResult == true {
          logger.info("MLS: ✅ Conversation manager shutdown complete")
          mlsConversationManagerStorage = nil
        } else {
          if shutdownResult == nil {
            logger.warning("⚠️ MLS: Shutdown still in progress after 3s")
          } else {
            logger.critical("🚨 MLS: Shutdown completed but was NOT safe")
          }

          // Clear references so no new work gets scheduled on the old manager.
          mlsConversationManagerStorage = nil

          // Don't initialize a new MLS context until the old one finishes releasing DB handles.
          let userDIDAtSwitch = self.userDID
          mlsConversationManagerInitTask = Task<MLSConversationManager?, Never> { @MainActor [weak self] in
            guard let self else { return nil }

            _ = await shutdownTask.value
            try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms

            guard self.userDID == userDIDAtSwitch else { return nil }

            self.logger.info("MLS: 🔁 Retrying initialization after delayed shutdown")

            // Avoid deadlocking initializeMLS() on this Task by clearing the init task first.
            self.mlsConversationManagerInitTask = nil
            try? await self.initializeMLS()

            return self.mlsConversationManagerStorage
          }

          return
        }
      }
      
      // Step 4: Clear API client reference
      mlsAPIClientStorage = nil
      
      // CRITICAL FIX: Add a small delay between cleanup and initialization
      // This ensures iOS has time to release file handles and memory locks
      try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

      logger.info("MLS: Using SQLite storage for user \(self.userDID)")

      do {
        try await initializeMLS()
        logger.info("✅ MLS: Initialized successfully")

        // CRITICAL: Validate bundle state after account switch
        // This catches the desync where local storage shows 0 bundles but server has more
         let userDid = self.userDID 
          do {
            let bundleCount = try await MLSClient.shared.getKeyPackageBundleCount(for: userDid)
            logger.info("📊 [Account Switch] Local bundle count: \(bundleCount)")

            if bundleCount == 0 {
              logger.warning("⚠️ [Account Switch] No local bundles - triggering reconciliation")
              // Reconciliation will attempt non-destructive recovery first
              let result = try await MLSClient.shared.reconcileKeyPackagesWithServer(for: userDid)
              if result.desyncDetected {
                logger.warning("⚠️ [Account Switch] Desync detected and handled - server: \(result.serverAvailable), local: \(result.localBundles)")
              } else {
                logger.info("✅ [Account Switch] Bundle state reconciled successfully")
              }
            }
          } catch {
            logger.error("⚠️ [Account Switch] Bundle validation failed: \(error.localizedDescription)")
            // Don't fail - MLS can still work, reconciliation can happen later
          }
      } catch {
        logger.error("⚠️ MLS: Initialization failed: \(error.localizedDescription)")
        // Don't fail account setup if MLS init fails - user can retry later
      }
    }
  #endif

  /// Pre-warms the Following feed for the new account to enable smooth crossfade
  @MainActor
  private func prewarmFollowingFeed() async {
    // Use this AppState's authenticated client
    let client = self.client

    do {
      logger.info("Pre-warming following feed for smooth account transition")

      // Fetch initial posts for the following feed
      // Use 50 posts to match normal fetch behavior and account for filtering
      let (response, output) = try await client.app.bsky.feed.getTimeline(
        input: .init(limit: 50),  // Increased from 15 to account for aggressive filtering
      )
      if response != 200 {
        logger.error("Failed to pre-warm feed: HTTP \(response)")
        prewarmingFeedData = nil
        return
      }

      guard let output = output else {
        logger.error("Failed to pre-warm feed: No output data")
        prewarmingFeedData = nil
        return
      }
      // Store for potential crossfade transition
      prewarmingFeedData = output.feed

      logger.info("Pre-warmed \(output.feed.count) posts for feed transition")
    } catch {
      logger.error("Failed to pre-warm feed: \(error.localizedDescription)")
      prewarmingFeedData = nil
    }
  }

  // MARK: - OAuth Callback Handling

  /// Handles OAuth callback URLs - delegates to AppStateManager's auth manager
  @MainActor
  func handleOAuthCallback(_ url: URL) async throws {
    logger.info("AppState handling OAuth callback")
    try await AppStateManager.shared.authentication.handleCallback(url)
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
    UserDefaults(suiteName: "group.blue.catbird.shared")?.set(
      isAdultContentEnabled, forKey: "isAdultContentEnabled")
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

  /// Access to the AT Protocol client (returns this AppState's authenticated client)
  var atProtoClient: ATProtoClient? {
    client
  }

  #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 15.0, *)
    var blueskyAgent: BlueskyIntelligenceAgent {
      if let blueskyAgentStorage = blueskyAgentStorage as? BlueskyIntelligenceAgent {
        return blueskyAgentStorage
      }

      let agent = BlueskyIntelligenceAgent(client: client)
      blueskyAgentStorage = agent
      return agent
    }
  #endif

  /// Update post manager when client changes
  private func updatePostManagerClient() {
    postManager.updateClient(client)
  }

  /// Check if user is authenticated
  // NOTE: In new architecture, AppState only exists for authenticated users
  var isAuthenticated: Bool {
    true  // AppState is only created for authenticated accounts
  }

  /// Current auth state
  /// NOTE: This property is deprecated in new architecture - access auth via AppStateManager
  var authState: AuthState {
    .authenticated(userDID: userDID)  // AppState is always authenticated
  }

  /// The shared Nuke image pipeline
  var imagePipeline: ImagePipeline {
    ImagePipeline.shared
  }

  #if os(iOS)
    /// Get or create MLS API client lazily (only when MLS chat is actually accessed)
    @MainActor
    func getMLSAPIClient() async -> MLSAPIClient? {
      // Use this AppState's authenticated client
      let client = self.client

      if let existing = mlsAPIClientStorage {
        logger.debug("MLS: Reusing existing API client")
        return existing
      }

      logger.info("MLS: Creating new API client for production environment (lazy initialization)")
      // Create MLS client off main actor to avoid blocking UI
      let mlsClient = await Task.detached(priority: .userInitiated) {
        await MLSAPIClient(
          client: client,
          environment: .production
        )
      }.value
      mlsAPIClientStorage = mlsClient
      logger.info("MLS: API client created successfully")
      return mlsClient
    }

    /// Get or create MLS conversation manager (lazy initialization when first accessed)
    @MainActor
    func getMLSConversationManager() async -> MLSConversationManager? {
      // Use this AppState's userDID (AppState represents single authenticated account)
      let userDid = self.userDID

      // CRITICAL FIX: Verify this AppState matches the currently active account
      // This prevents using a stale AppState (and its manager) when the global auth has switched
      // and prevents "Account mismatch" errors in MLS sync operations
      if let activeDID = AppStateManager.shared.lifecycle.userDID, activeDID != userDid {
        logger.warning("MLS: ❌ AppState userDID (\(userDid)) does not match active user (\(activeDID)) - aborting manager retrieval")
        return nil
      }

      if AppStateManager.shared.isUserUnderStorageMaintenance(userDid) {
        logger.warning(
          "MLS: Storage maintenance in progress for user: \(userDid) - skipping conversation manager creation"
        )
        mlsServiceState.status = .failed("Storage maintenance in progress")
        return nil
      }

      // Check if existing manager is for the same user
      if let existing = mlsConversationManagerStorage {
        // Verify the manager is for the current user
        if existing.userDid == userDid {
          logger.debug("MLS: ♻️ Reusing existing conversation manager for user: \(userDid)")
          mlsServiceState.status = .ready
          return existing
        } else {
          logger.warning(
            "MLS: Existing conversation manager is for different user (\(existing.userDid ?? "nil")), creating new one"
          )
          mlsConversationManagerStorage = nil
          mlsConversationManagerInitTask?.cancel()
          mlsConversationManagerInitTask = nil
        }
      }

      // Check if initialization is already in progress
      if let existingTask = mlsConversationManagerInitTask {
        logger.info("MLS: ⏳ Waiting for existing initialization task to complete...")
        return await existingTask.value
      }

      // Update status to initializing
      mlsServiceState.status = .initializing

      // Create new initialization task
      logger.info("MLS: 🆕 Starting new conversation manager initialization for user: \(userDid)")
      let initTask = Task<MLSConversationManager?, Never> { @MainActor in
        guard let apiClient = await getMLSAPIClient() else {
          logger.error("MLS: ❌ Cannot create conversation manager - failed to get API client")
          let errorMsg = "Failed to get API client"
          mlsServiceState.status = .failed(errorMsg)
          mlsServiceState.lastError = MLSInitializationError.noConversationManager
          return nil
        }

        // Lazy setup MLS database if not already initialized
        // CRITICAL FIX (2024-12): Also re-initialize if the cached reference is a closed pool
        // After pool.close() is called, the reference isn't nil but is unusable
        var needsDatabaseSetup = mlsDatabase == nil
        if !needsDatabaseSetup {
          // Check if the pool is actually open (not a zombie closed reference)
          let isOpen = await MLSGRDBManager.shared.isDatabaseOpen(for: userDid)
          if !isOpen {
            logger.warning("MLS: 🔄 Database reference exists but pool is closed - re-initializing")
            mlsDatabase = nil
            needsDatabaseSetup = true
          }
        }
        if needsDatabaseSetup {
          logger.info("MLS: 🔐 Lazily initializing MLS database for user: \(userDid)")
          await setupMLSDatabase(for: userDid)
        }

        // Ensure database is available after lazy initialization
        guard let database = mlsDatabase else {
          logger.error("MLS: ❌ Cannot create conversation manager - database initialization failed")
          let errorMsg = "Database initialization failed"
          mlsServiceState.status = .failed(errorMsg)
          mlsServiceState.lastError = MLSInitializationError.noConversationManager
          return nil
        }

        // Ensure ATProtoClient is available for device registration
        guard let atProtoClient = atProtoClient else {
          logger.error("MLS: ❌ Cannot create conversation manager - atProtoClient is nil")
          let errorMsg = "AT Protocol client not available"
          mlsServiceState.status = .failed(errorMsg)
          mlsServiceState.lastError = MLSInitializationError.noConversationManager
          return nil
        }

        logger.info("MLS: Creating new conversation manager for user: \(userDid)")
        let manager = MLSConversationManager(
          apiClient: apiClient,
          database: database,
          userDid: userDid,
          atProtoClient: atProtoClient
        )

        // Initialize the manager before storing and returning it
        do {
          try await manager.initialize()
          logger.info("MLS: ✅ Created and initialized new conversation manager successfully")
          mlsConversationManagerStorage = manager
          mlsConversationManagerInitTask = nil
          mlsServiceState.status = .ready
          mlsServiceState.retryCount = 0  // Reset retry count on success
          mlsServiceState.lastError = nil
          return manager
        } catch {
          logger.error(
            "MLS: ❌ Failed to initialize conversation manager: \(error.localizedDescription)")
          logger.error("MLS: Initialization error details: \(String(describing: error))")
          mlsConversationManagerInitTask = nil
          mlsServiceState.status = .failed(error.localizedDescription)
          mlsServiceState.lastError = error
          return nil
        }
      }

      mlsConversationManagerInitTask = initTask
      return await initTask.value
    }

    /// Retry MLS initialization with exponential backoff
    @MainActor
    func retryMLSInitialization() async {
      guard mlsServiceState.retryCount < mlsServiceState.maxRetries else {
        logger.error("MLS: Max retry attempts (\(self.mlsServiceState.maxRetries)) reached")
        mlsServiceState.status = .failed("Max retry attempts reached. Please restart the app.")
        return
      }

      mlsServiceState.retryCount += 1
      mlsServiceState.status = .retrying(attempt: mlsServiceState.retryCount)

      logger.info("MLS: Retry attempt \(self.mlsServiceState.retryCount) of \(self.mlsServiceState.maxRetries)")

      // Exponential backoff: 1s, 2s, 4s
      let delaySeconds = pow(2.0, Double(mlsServiceState.retryCount - 1))
      logger.info("MLS: Waiting \(delaySeconds)s before retry...")

      try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))

      // Clear previous manager state
      mlsConversationManagerStorage = nil
      mlsConversationManagerInitTask?.cancel()
      mlsConversationManagerInitTask = nil

      // Attempt initialization
      let manager = await getMLSConversationManager()

      if manager != nil {
        logger.info("MLS: ✅ Retry successful")
      } else {
          logger.error("MLS: ❌ Retry attempt \(self.mlsServiceState.retryCount) failed")
      }
    }

    /// Get or create MLS event stream manager
    @MainActor
    func getMLSEventStreamManager() async -> MLSEventStreamManager? {
      guard let apiClient = await getMLSAPIClient() else {
        logger.error("MLS: Cannot create event stream manager - failed to get API client")
        return nil
      }

      if let existing = mlsEventStreamManagerStorage {
        logger.debug("MLS: Reusing existing event stream manager")
        await configureMLSCursorStoreIfNeeded(for: existing)
        return existing
      }

      logger.info("MLS: Creating new event stream manager")
      let manager = MLSEventStreamManager(apiClient: apiClient)
      await configureMLSCursorStoreIfNeeded(for: manager)
      mlsEventStreamManagerStorage = manager
      logger.info("MLS: Event stream manager created successfully")
      return manager
    }

    @MainActor
    private func configureMLSCursorStoreIfNeeded(for manager: MLSEventStreamManager) async {
      if mlsCursorStoreStorage == nil {
        do {
          let container = try CursorStore.createContainer()
          mlsCursorStoreContainerStorage = container
          mlsCursorStoreStorage = CursorStore(
            modelContext: container.mainContext,
            currentUserDID: userDID
          )
          logger.info("MLS: CursorStore initialized for SSE resume")
        } catch {
          logger.warning("MLS: Failed to initialize CursorStore: \(error.localizedDescription)")
        }
      }

      if let store = mlsCursorStoreStorage {
        await manager.configureCursorStore(store)
      }
    }

    /// Prepare MLS resources for destructive storage operations
    /// CRITICAL: This method BLOCKS until the database is fully closed
    /// Call this BEFORE switching to a different account to prevent key mismatch errors
    @MainActor
    func prepareMLSStorageReset() async {
      logger.info("MLS: Preparing AppState \(self.userDID) for storage reset")
      
      // Step 1: Cancel any pending initialization to prevent new operations
      mlsConversationManagerInitTask?.cancel()
      mlsConversationManagerInitTask = nil

      // Step 2: Stop SSE event streams FIRST and WAIT for completion
      // CRITICAL FIX: SSE streams can write to the database, so they must fully complete
      // BEFORE we try to close the database to prevent "database locked" and WAL corruption
      if let eventManager = mlsEventStreamManagerStorage {
        logger.info("MLS: Stopping event stream subscriptions and waiting...")
        await eventManager.stopAllAndWait(timeout: 2.0)
        mlsEventStreamManagerStorage = nil
        logger.info("MLS: ✅ Event streams fully stopped")
      }

      // Step 3: Shutdown conversation manager (cancels background tasks, drains DB queue)
      if let manager = mlsConversationManagerStorage {
        logger.info("MLS: Shutting down conversation manager...")
        await manager.prepareForStorageReset()
        mlsConversationManagerStorage = nil
        logger.info("MLS: Conversation manager shutdown complete")
      }

      // Step 4: Wait a short moment for any in-flight operations to complete
      // This gives cancelled tasks time to actually wind down
      try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

      // Step 5: Close database with drain to ensure all operations are flushed
      // CRITICAL FIX: Use closeDatabaseAndDrain to prevent race conditions during account switch
      if mlsDatabase != nil {
        logger.info("MLS: Closing database with drain for user: \(self.userDID)")
        let drainSuccess = await MLSGRDBManager.shared.closeDatabaseAndDrain(for: userDID, timeout: 5.0)
        if !drainSuccess {
          logger.critical("MLS: 🚨 Database drain failed - storage reset is unsafe; user should restart")
          mlsServiceState.markDatabaseFailed(message: "MLS database couldn’t be safely closed. Please restart the app.")
        }
        mlsDatabase = nil
        logger.info("MLS: Database close attempt complete")
      }
      
      logger.info("MLS: ✅ Storage reset preparation complete for \(self.userDID)")
    }
  #endif

  // MARK: - MLS Database Management

  /// Setup encrypted MLS database for current user (async to avoid main thread blocking)
  /// - Parameter userDID: User's decentralized identifier
  @MainActor
  private func setupMLSDatabase(for userDID: String) async {
    let start = Date()

    if AppStateManager.shared.isUserUnderStorageMaintenance(userDID) {
      logger.warning("MLS: Storage maintenance in progress for user: \(userDID) - skipping database open")
      self.mlsDatabase = nil
      mlsServiceState.status = .failed("Storage maintenance in progress")
      return
    }

    do {
      // Get database asynchronously (non-blocking)
      let database = try await MLSGRDBManager.shared.getDatabasePool(for: userDID)

      // Store in AppState
      self.mlsDatabase = database

      let duration = Date().timeIntervalSince(start)
      logger.info("✅ MLS database configured for \(userDID) in \(Int(duration * 1000))ms")

    } catch let error as MLSSQLCipherError {
      // Handle specific SQLCipher errors
      switch error {
      case .encryptionKeyMismatch(let message):
        // CRITICAL FIX: Key mismatch indicates account switching race condition
        // Do NOT mark as failed - this is recoverable by waiting for switch to complete
        logger.error("🔐 MLS database key mismatch: \(message)")
        logger.error("   This typically indicates an account switching race condition")
        logger.error("   The database will be retried after the switch completes")
        self.mlsDatabase = nil
        mlsServiceState.status = .failed("Account switching in progress - please wait")
        
      default:
        logger.error("❌ Failed to setup MLS database: \(error.localizedDescription)")
        self.mlsDatabase = nil
        
        // Check if database is in a severely failed state
        if await MLSGRDBManager.shared.isInFailedState(for: userDID) {
          mlsServiceState.markDatabaseFailed(message: "Database severely corrupted. Please restart the app.")
        }
      }
    } catch {
      logger.error("❌ Failed to setup MLS database: \(error.localizedDescription)")
      self.mlsDatabase = nil
      
      // Check if database is in a severely failed state
      if await MLSGRDBManager.shared.isInFailedState(for: userDID) {
          mlsServiceState.markDatabaseFailed(message: "Database severely corrupted. Please restart the app.")
      }
    }
  }

  /// Clear MLS database for current user (called on logout)
  @MainActor
  private func clearMLSDatabase(for userDID: String) async {
    logger.info("🔒 Closing MLS database for user: \(userDID)")

    // Clear local reference first to prevent any new operations
    self.mlsDatabase = nil

    // CRITICAL FIX: Use closeDatabaseAndDrain to ensure all operations complete
    // before closing. This prevents WAL/HMAC corruption during account switching.
    await MLSGRDBManager.shared.closeDatabaseAndDrain(for: userDID, timeout: 5.0)

    logger.info("✅ MLS database closed for user: \(userDID)")
  }

  /// Flush MLS storage to release file locks before app suspension
  ///
  /// This MUST be called when the app enters background to prevent iOS from
  /// terminating the app with 0xdead10cc (file lock held during suspension).
  /// The method checkpoints the SQLite WAL to release all file locks.
  @MainActor
  func flushMLSStorageForSuspension() async {
    if isMLSStorageFlushInProgress {
      logger.debug("⏭️ Skipping MLS storage flush - already in progress")
      return
    }

    isMLSStorageFlushInProgress = true
    defer { isMLSStorageFlushInProgress = false }

    logger.info("💾 Flushing MLS storage before app suspension...")

#if os(iOS)
    var bgTask: UIBackgroundTaskIdentifier = .invalid
    bgTask = UIApplication.shared.beginBackgroundTask(withName: "MLSStorageFlush") {
        self.logger.error("⏰ iOS background time expired during MLS storage flush")
      if bgTask != .invalid {
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
      }
    }
    defer {
      if bgTask != .invalid {
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
      }
    }
#endif

    do {
      try await MLSClient.shared.flushStorage(for: userDID)
      logger.info("✅ MLS storage flushed - safe for suspension")
    } catch {
      // Log but don't throw - we want the app to suspend gracefully even if flush fails
      logger.error("⚠️ MLS storage flush failed: \(error.localizedDescription)")
    }

    // Also checkpoint the GRDB database pool
    // CRITICAL FIX (2024-12): Don't use cached mlsDatabase reference - it may be closed
    // After pool.close() is called (during account switching or cleanup), the cached
    // reference becomes a "zombie" that throws "Connection is closed" on any operation.
    // Instead, check if the database is open in MLSGRDBManager and use that.
    if await MLSGRDBManager.shared.isDatabaseOpen(for: userDID) {
      do {
        // Get a fresh reference from the manager - this ensures we use an open pool
        let database = try await MLSGRDBManager.shared.getDatabasePool(for: userDID)
        try await database.writeWithoutTransaction { db in
          try db.checkpoint(.truncate)
        }
        logger.info("✅ MLS GRDB checkpoint completed")
      } catch {
        // "Connection is closed" errors are expected during account switching
        // Log as warning, not error, to avoid confusion
        let errorDesc = error.localizedDescription.lowercased()
        if errorDesc.contains("closed") || errorDesc.contains("sqlite error 21") {
          logger.warning("⚠️ MLS GRDB checkpoint skipped - database was closed (account switching?)")
        } else {
          logger.error("⚠️ MLS GRDB checkpoint failed: \(error.localizedDescription)")
        }
      }
    } else {
      logger.debug("⏭️ Skipping GRDB checkpoint - database not open for user")
    }
  }
  
  /// Reload MLS state from disk after returning from background
  ///
  /// **CRITICAL**: The Notification Service Extension (NSE) runs as a separate process
  /// and may advance the MLS ratchet while the app holds stale in-memory state.
  /// This method forces the MLSConversationManager to discard its in-memory state
  /// and reload from disk, picking up any changes made by the NSE.
  ///
  /// Call this when:
  /// - App enters foreground (UIApplication.willEnterForegroundNotification)
  /// - After handling a notification tap
  /// - After receiving a Darwin notification from NSE indicating state change
  @MainActor
  func reloadMLSStateFromDisk() async {
    logger.info("🔄 [AppState] Reloading MLS state from disk (catching up with NSE)")
    
    #if os(iOS)
    // Only reload if we have an active MLS manager
    if let manager = mlsConversationManagerStorage {
      await manager.reloadStateFromDisk()
      logger.info("✅ [AppState] MLS state reload complete")
      
      // Also reload conversations to pick up any new messages decrypted by NSE
      // This updates the UI with messages the NSE may have stored in the database
      await loadMLSConversations()
      logger.info("✅ [AppState] MLS conversations reloaded after state sync")
    } else {
      logger.debug("⏭️ [AppState] No MLS manager - skipping state reload")
    }
    #endif
  }
  
  /// Release MLS database readers to allow NSE to perform a clean checkpoint.
  ///
  /// **PHASE 5**: This is called when we receive the nseWillClose Darwin notification.
  /// The NSE is about to perform a TRUNCATE checkpoint and needs exclusive access
  /// to the WAL/SHM files. We release our connection WITHOUT checkpointing - the NSE
  /// will handle the checkpoint.
  ///
  /// After this method completes, the caller should post appAcknowledged to signal
  /// the NSE that it can proceed with the checkpoint.
  @MainActor
  func releaseMLSDatabaseReaders() async -> Bool {
    logger.info("🔓 [AppState] Releasing MLS database readers for NSE handshake")

    #if os(iOS)
    // Release our database connection WITHOUT checkpointing.
    // Fail-closed: if we can't close cleanly, do not acknowledge the handshake.
    if mlsConversationManagerStorage != nil {
      let released = await MLSGRDBManager.shared.releaseConnectionWithoutCheckpoint(for: userDID)
      if released {
        logger.info("✅ [AppState] Database readers released for NSE checkpoint")
        mlsDatabase = nil
      }
      return released
    } else {
      logger.debug("⏭️ [AppState] No active database readers to release")
      return true
    }
    #else
    return true
    #endif
  }
  
  /// Recover MLS database after a codec error by reconnecting
  /// Uses progressive repair: WAL/SHM repair first, then full reset if needed
  /// - Parameter userDID: User's decentralized identifier
  /// - Returns: True if recovery was successful
  @MainActor
  private func recoverMLSDatabase(for userDID: String) async -> Bool {
    logger.warning("🔄 Attempting MLS database recovery for user: \(userDID)")
    
    // Check if we're in cooldown period
    if mlsServiceState.isInDatabaseCooldown {
      let remaining = Int(mlsServiceState.databaseRetryCooldown - Date().timeIntervalSince(mlsServiceState.databaseFailedAt ?? Date()))
      logger.warning("⏳ Database recovery on cooldown (\(remaining)s remaining)")
      return false
    }
    
    // Clear local references
    self.mlsDatabase = nil
    self.mlsConversationManagerStorage = nil
    
    do {
      // Force reconnection through MLSGRDBManager (which uses progressive repair)
      let database = try await MLSGRDBManager.shared.reconnectDatabase(for: userDID)
      self.mlsDatabase = database
      
      // Clear any failure state
      mlsServiceState.clearDatabaseFailure()
      await MLSGRDBManager.shared.clearRepairState(for: userDID)
      
      logger.info("✅ MLS database recovered successfully for user: \(userDID)")
      return true
    } catch {
      logger.error("❌ MLS database recovery failed: \(error.localizedDescription)")
      
      // Check if database is in severely failed state (max repairs exceeded)
      if await MLSGRDBManager.shared.isInFailedState(for: userDID) {
          mlsServiceState.markDatabaseFailed(message: "Database recovery failed. Please restart the app to try again.")
        logger.error("🚨 Database in FAILED state - stopping all operations until app restart")
      }
      
      return false
    }
  }

  // MARK: - User Profile Methods

  /// Load the current user's profile for optimistic updates
  @MainActor
  private func loadCurrentUserProfile(did: String) async {

    guard let client = atProtoClient else {
      logger.error("❌ Cannot load profile - atProtoClient is nil")
      return
    }

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
          pronouns: profile.pronouns, avatar: profile.avatar,
          associated: profile.associated,
          viewer: profile.viewer,
          labels: profile.labels,
          createdAt: profile.createdAt,
          verification: profile.verification,
          status: profile.status
        )

      } else {
        logger.error("❌ Failed to load current user profile: HTTP \(responseCode)")
      }
    } catch {
      logger.error("❌ Failed to load current user profile: \(error.localizedDescription)")
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
    logger.info(
      "Theme reapplied after SwiftData initialization: theme=\(self.appSettings.theme), darkMode=\(self.appSettings.darkThemeMode)"
    )

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
    
    // ═══════════════════════════════════════════════════════════════════════════
    // MEMORY WARNING HANDLER (2024-12): Trigger MLS database emergency cleanup
    // ═══════════════════════════════════════════════════════════════════════════
    // When iOS sends a memory warning, aggressively close inactive databases
    // to prevent OOM kills and SQLite error 7 (file descriptor exhaustion).
    // ═══════════════════════════════════════════════════════════════════════════
    #if os(iOS)
    NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      self.logger.warning("⚠️ Memory warning received - triggering MLS database cleanup")
      
      Task {
        // Check database health before cleanup
        let healthStatuses = await MLSGRDBManager.shared.checkAllWALHealth()
        for health in healthStatuses where health.status == .critical {
          self.logger.error("🚨 Critical WAL health for \(health.userDID.prefix(20)): \(health.message)")
        }
        
        // Perform emergency cleanup
        let closedCount = await MLSGRDBManager.shared.emergencyCleanup()
        self.logger.info("🧹 Emergency cleanup closed \(closedCount) database(s)")
      }
    }
    #endif

    logger.debug("Theme and font observation configured")
  }

  // MARK: - Settings Observation

  /// Set up reactive observation for settings changes with change tracking
  @MainActor
  private func setupSettingsObservation() {
    // Remove any existing observers to prevent duplicates
    NotificationCenter.default.removeObserver(
      self, name: NSNotification.Name("AppSettingsChanged"), object: nil)

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
      self.settingsUpdateDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false)
      { [weak self] _ in
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

        self.logger.debug(
          "Applied debounced settings changes - theme: \(self.appSettings.theme), font: \(self.appSettings.fontStyle)"
        )
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
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard let self = self else { return }
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
    #if os(iOS)
      NotificationCenter.default.addObserver(
        forName: UIApplication.willEnterForegroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { [weak self] in
          await self?.notificationManager.checkUnreadNotifications()
        }
      }
    #elseif os(macOS)
      NotificationCenter.default.addObserver(
        forName: NSApplication.willBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { [weak self] in
          await self?.notificationManager.checkUnreadNotifications()
        }
      }
    #endif
  }

  #if os(iOS)
    /// Update chat unread count from chat manager
    @MainActor
    func updateChatUnreadCount() {
      let newCount = chatManager.totalUnreadCount
      if chatUnreadCount != newCount {
        chatUnreadCount = newCount
        logger.debug("Chat unread count updated: \(newCount)")
      }
    }

    /// Update MLS unread count from database
    @MainActor
    func updateMLSUnreadCount() {
      Task {
        do {
          let db = try await MLSGRDBManager.shared.getDatabasePool(for: userDID)
          let unreadCounts = try await MLSStorageHelpers.getUnreadCountsForAllConversations(
            from: db,
            currentUserDID: userDID
          )
          let newCount = unreadCounts.values.reduce(0, +)
          await MainActor.run {
            if mlsUnreadCount != newCount {
              mlsUnreadCount = newCount
              logger.debug("MLS unread count updated: \(newCount)")
            }
          }
        } catch {
          logger.error("Failed to update MLS unread count: \(error.localizedDescription)")
        }
      }
    }

    // MARK: - MLS (Encrypted Messaging)

    /// Initialize MLS for the current account
    @MainActor
    func initializeMLS() async throws {
      guard let manager = await getMLSConversationManager() else {
        logger.warning("MLS: No conversation manager available")
        throw MLSInitializationError.noConversationManager
      }

      logger.info("MLS: Initializing for current account")

      // Initialize the MLS crypto context
      try await manager.initialize()
      
      // ═══════════════════════════════════════════════════════════════════════════
      // CRITICAL FIX (2024-12): Observe Darwin notifications from NSE
      // ═══════════════════════════════════════════════════════════════════════════
      //
      // Problem: When the app is in foreground and NSE decrypts a message concurrently,
      // the app's in-memory MLS state becomes stale. The existing fix (reloading state
      // on background → foreground transition) doesn't help because scenePhase doesn't
      // change when the app is already active.
      //
      // Solution: NSE posts a Darwin Notification after decrypting a message.
      // We observe for that notification here and reload our MLS state from disk.
      // This ensures we catch up with any ratchet advances made by NSE, even when
      // the app is already in foreground.
      //
      // ═══════════════════════════════════════════════════════════════════════════
      MLSStateChangeNotifier.shared.observeWithAsyncHandler { [weak self] in
        guard let self = self else { return }
        self.logger.info("📥 [MLS] Received state change notification from NSE")
        self.logger.info("   NSE advanced the ratchet - reloading state from disk")
        await self.reloadMLSStateFromDisk()
      }
      logger.info("🔔 MLS: Observing for NSE state change notifications")
      
      // ═══════════════════════════════════════════════════════════════════════════
      // PHASE 5: Observe nseWillClose for coordinated handshake
      // ═══════════════════════════════════════════════════════════════════════════
      //
      // When NSE is about to close and checkpoint the database, it posts nseWillClose.
      // We need to release our database readers to prevent WAL/SHM locking conflicts
      // during the TRUNCATE checkpoint. After releasing, we acknowledge so NSE can proceed.
      //
      // ═══════════════════════════════════════════════════════════════════════════
      MLSStateChangeNotifier.shared.observeNSEWillCloseWithAsyncHandler { [weak self] in
        guard let self = self else { return }
        self.logger.info("📥 [Handshake] App received nseWillClose, releasing readers")
        
        // Release database readers by closing our cached connection
        // This allows NSE to perform a clean TRUNCATE checkpoint
        let released = await self.releaseMLSDatabaseReaders()
        
        if released {
          // Acknowledge so NSE can proceed with checkpoint
          MLSStateChangeNotifier.postAppAcknowledged()
          self.logger.info("📤 [Handshake] App posted appAcknowledged")
        } else {
          self.logger.warning("🚫 [Handshake] Did not release DB readers in time; not acknowledging")
        }
      }
      logger.info("🔔 MLS: Observing for NSE nseWillClose handshake notifications")

      // ✅ Reconcile key packages with server to detect storage corruption
      logger.info("MLS: Reconciling key packages with server...")
      do {
        let reconcileResult = try await MLSClient.shared.reconcileKeyPackagesWithServer(
          for: userDID)
        if reconcileResult.desyncDetected {
          logger.error("⚠️ MLS: Key package desync detected during initialization!")
          logger.error(
            "   Server: \(reconcileResult.serverAvailable) bundles | Local: \(reconcileResult.localBundles) bundles"
          )
          logger.error(
            "   This may cause NoMatchingKeyPackage errors when processing Welcome messages")
          // Note: Detailed recovery instructions are logged by reconcileKeyPackagesWithServer()
        } else {
          logger.info(
            "✅ MLS: Key packages in sync (server: \(reconcileResult.serverAvailable), local: \(reconcileResult.localBundles))"
          )
        }
      } catch {
        logger.warning(
          "⚠️ MLS: Failed to reconcile key packages (continuing anyway): \(error.localizedDescription)"
        )
        // Don't fail initialization if reconciliation fails - might be offline
      }

      // Load existing conversations (this processes pending Welcome messages)
      await loadMLSConversations()

      logger.info("MLS: Successfully initialized")
    }

    /// Load MLS conversations from the server
    @MainActor
    func loadMLSConversations() async {
      guard let manager = await getMLSConversationManager() else {
        logger.debug("MLS: No conversation manager available")
        mlsConversations = []
        mlsConversationsDidChange += 1
        updateMLSUnreadCount()
        return
      }

      do {
        // Sync with server to get latest conversations
        try await manager.syncWithServer()

        // Fetch unread counts from local database
        var unreadCounts: [String: Int] = [:]
        if let database = try? await MLSGRDBManager.shared.getDatabasePool(for: userDID) {
          for (convoId, _) in manager.conversations {
            if let count = try? await MLSStorageHelpers.getUnreadCount(
              from: database,
              conversationID: convoId,
              currentUserDID: userDID
            ) {
              unreadCounts[convoId] = count
            }
          }
        }

        // Map conversations from manager to view models with unread counts
        let conversations = Array(manager.conversations.values).map { convo -> MLSConversationViewModel in
          convo.toViewModel(unreadCount: unreadCounts[convo.groupId] ?? 0)
        }

        // Update UI immediately with basic conversation data
        mlsConversations = conversations
        mlsConversationsDidChange += 1
        updateMLSUnreadCount()

        // Enrich participant data with Bluesky profiles off the main actor
        if let client = atProtoClient {
          Task.detached { [weak self] in
            guard let self else { return }

            // Collect all unique participant DIDs
            let allDIDs = Array(Set(conversations.flatMap { conversation in
              conversation.participants.map { $0.id }
            }))

            // Fetch all profiles at once (off main actor)
            // Pass userDID to persist profiles to database for NSE rich notifications
            let enrichedProfilesMap = await self.mlsProfileEnricher.ensureProfiles(
              for: allDIDs,
              using: client,
              currentUserDID: self.userDID
            )

            // Update conversation participants with enriched profile data
            let enrichedConversations = conversations.map { conversation in
              let enrichedParticipants = conversation.participants.map { participant in
                if let profileData = enrichedProfilesMap[participant.id] {
                  return MLSParticipantViewModel(
                    id: participant.id,
                    handle: profileData.handle,
                    displayName: profileData.displayName,
                    avatarURL: profileData.avatarURL
                  )
                }
                return participant
              }

              return MLSConversationViewModel(
                id: conversation.id,
                name: conversation.name,
                participants: enrichedParticipants,
                lastMessagePreview: conversation.lastMessagePreview,
                lastMessageTimestamp: conversation.lastMessageTimestamp,
                unreadCount: conversation.unreadCount,
                isGroupChat: conversation.isGroupChat,
                groupId: conversation.groupId
              )
            }

            // Update UI on main actor
            await MainActor.run {
              self.mlsConversations = enrichedConversations
              self.mlsConversationsDidChange += 1
              self.updateMLSUnreadCount()
            }
          }
        }

        logger.info("MLS: Synced \(self.mlsConversations.count) conversations from server")
      } catch let sqlError as MLSSQLCipherError {
        // Handle specific SQLCipher errors
        switch sqlError {
        case .encryptionKeyMismatch(let message):
          // Key mismatch - do NOT attempt recovery, just wait for account switch to complete
          logger.error("MLS: 🔐 Key mismatch during conversation load: \(message)")
          logger.error("   This is expected during account switching - will retry automatically")
          mlsServiceState.status = .failed("Account switching in progress")
          
        default:
          logger.error("MLS: Failed to load conversations (SQLCipher): \(sqlError.localizedDescription)")
          // Check if this is a recoverable SQLCipher codec error
          if MLSGRDBManager.shared.isRecoverableCodecError(sqlError) {
            logger.warning("MLS: Detected recoverable database error, attempting recovery...")
            
            if await recoverMLSDatabase(for: self.userDID) {
              // Recovery successful - retry loading conversations once
              logger.info("MLS: Retrying conversation load after database recovery")
              if let retryManager = await getMLSConversationManager() {
                do {
                  try await retryManager.syncWithServer()
                  let conversations = Array(retryManager.conversations.values).map { $0.toViewModel() }
                  mlsConversations = conversations
                  mlsConversationsDidChange += 1
                  updateMLSUnreadCount()
                  logger.info("MLS: Successfully loaded \(conversations.count) conversations after recovery")
                  return
                } catch {
                  logger.error("MLS: Retry after recovery also failed: \(error.localizedDescription)")
                }
              }
            }
          }
        }
        
        mlsConversations = []
        mlsConversationsDidChange += 1
        updateMLSUnreadCount()
      } catch {
        logger.error("MLS: Failed to load conversations: \(error.localizedDescription)")
        
        // Check if this is a recoverable SQLCipher codec error
        if MLSGRDBManager.shared.isRecoverableCodecError(error) {
          logger.warning("MLS: Detected recoverable database error, attempting recovery...")
          
            if await recoverMLSDatabase(for: self.userDID) {
            // Recovery successful - retry loading conversations once
            logger.info("MLS: Retrying conversation load after database recovery")
            if let retryManager = await getMLSConversationManager() {
              do {
                try await retryManager.syncWithServer()
                let conversations = Array(retryManager.conversations.values).map { $0.toViewModel() }
                mlsConversations = conversations
                mlsConversationsDidChange += 1
                updateMLSUnreadCount()
                logger.info("MLS: Successfully loaded \(conversations.count) conversations after recovery")
                return
              } catch {
                logger.error("MLS: Retry after recovery also failed: \(error.localizedDescription)")
              }
            }
          }
        }
        
        mlsConversations = []
        mlsConversationsDidChange += 1
        updateMLSUnreadCount()
      }
    }

    /// Reload MLS conversations (called when new messages arrive)
    @MainActor
    func reloadMLSConversations() async {
      await loadMLSConversations()
    }

    /// Update MLS conversation list when a message is received
    @MainActor
    func handleMLSMessageReceived(conversationID: String) async {
      await reloadMLSConversations()
      logger.debug("MLS: Conversations reloaded after message in: \(conversationID)")
    }
  #endif

  #if os(iOS)
    /// Setup chat observers and background polling for unread messages
    private func setupChatObservers() {
      // Set up callback for when chat unread count changes
      chatManager.onUnreadCountChanged = { [weak self] in
        Task { @MainActor [weak self] in
          self?.updateChatUnreadCount()
        }
      }

      // Keep chat polling alive even when the chat tab isn't visible
      chatManager.startConversationsPolling()

      // Update chat unread count initially
      Task { @MainActor in
        updateChatUnreadCount()
      }

      // Load MLS conversations initially
      Task { @MainActor in
        await loadMLSConversations()
      }

      // Set up periodic polling for chat messages (since they don't come through push notifications)
      chatPollingTimer?.invalidate()
      chatPollingTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self = self, case .authenticated = self.authState else { return }

          // Load conversations to check for new messages and update unread counts
          await self.chatManager.loadConversations(refresh: true)
          self.updateChatUnreadCount()

          // Also reload MLS conversations
          await self.loadMLSConversations()
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
          self.chatManager.startConversationsPolling()
          await self.chatManager.loadConversations(refresh: true)
          self.updateChatUnreadCount()

          // Also reload MLS conversations
          await self.loadMLSConversations()
        }
      }
    }
  #endif

  @objc private func handleNotificationsMarkedAsSeen() {
    notificationManager.updateUnreadCountAfterSeen()
  }

  /// Syncs notification-related user data with the server
  func syncNotificationData() async {
    await notificationManager.syncAllUserData()
  }

  // MARK: - Authentication Methods (for backward compatibility)

  /// Logs out the current user (delegates to AppStateManager's authentication manager)
  @MainActor
  func handleLogout() async throws {
    logger.info("Logout requested - delegating to AppStateManager")

    // Close MLS database before logging out
      await clearMLSDatabase(for: userDID)

    // Clear preferences before logging out
    await preferencesManager.clearAllPreferences()
    logger.info("User preferences cleared during logout")

    // Perform the actual logout via AppStateManager
    await AppStateManager.shared.logout()
  }

  /// Add a new account (delegates to AppStateManager's authentication manager)
  @MainActor
  func addAccount(handle: String) async throws -> URL {
    logger.info("Adding new account: \(handle)")
    return try await AppStateManager.shared.authentication.addAccount(handle: handle)
  }

  /// Remove an account (delegates to AppStateManager's authentication manager)
  @MainActor
  func removeAccount(did: String) async throws {
    logger.info("Removing account: \(did)")

    // Close MLS database for removed account
    await clearMLSDatabase(for: did)

    try await AppStateManager.shared.authentication.removeAccount(did: did)

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
    parentPost: AppBskyFeedDefs.PostView? = nil,
    threadgateAllowRules: [AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion]? = nil
  ) async throws {
    try await postManager.createThread(
      posts: posts,
      languages: languages,
      selfLabels: selfLabels,
      hashtags: hashtags,
      facets: facets,
      embeds: embeds,
      parentPost: parentPost,
      threadgateAllowRules: threadgateAllowRules
    )
  }

  // MARK: - Post Composer Presentation

  /// Present the post composer for creating a new post, reply, or quote post
  @MainActor
  func presentPostComposer(
    parentPost: AppBskyFeedDefs.PostView? = nil, quotedPost: AppBskyFeedDefs.PostView? = nil
  ) {
    // Track quote interaction for feed feedback
    if let quotedPost = quotedPost {
      feedFeedbackManager.trackQuote(postURI: quotedPost.uri)
    }

    // Create the UIKit-backed post composer view with either a parent post (for reply) or quoted post
    let composerView = PostComposerViewUIKit(
      parentPost: parentPost,
      quotedPost: quotedPost,
      appState: self
    )
    .applyAppStateEnvironment(self)

    #if os(iOS)
      // Create a UIHostingController for the SwiftUI view
      let hostingController = UIHostingController(rootView: composerView)

      // Configure presentation style
      hostingController.modalPresentationStyle = .formSheet
      // Allow swipe-to-dismiss to enable draft auto-persist on dismiss
      hostingController.isModalInPresentation = false

      // Present the composer using the appropriate window system
      if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
        let rootViewController = windowScene.windows.first?.rootViewController
      {
        rootViewController.present(hostingController, animated: true)
      }
    #elseif os(macOS)
      // On macOS, present as a new window
      let hostingController = NSHostingController(rootView: composerView)
      let window = NSWindow(contentViewController: hostingController)
      window.title = "Post"
      window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
      window.setContentSize(NSSize(width: 600, height: 400))
      window.center()
      window.makeKeyAndOrderFront(nil)
    #endif
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

  // MARK: - App Attest Persistence

  private func loadPersistedAppAttestInfo() -> AppAttestInfo? {
    let defaults = appAttestDefaults
    guard let storedData = defaults.data(forKey: appAttestDefaultsKey) else {
      return nil
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    do {
      return try decoder.decode(AppAttestInfo.self, from: storedData)
    } catch {
      logger.error("Failed to decode App Attest info: \(error.localizedDescription)")
      defaults.removeObject(forKey: appAttestDefaultsKey)
      return nil
    }
  }

  private func persistAppAttestInfo(_ info: AppAttestInfo?) {
    let defaults = appAttestDefaults

    guard let info else {
      defaults.removeObject(forKey: appAttestDefaultsKey)
      return
    }

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    do {
      let data = try encoder.encode(info)
      defaults.set(data, forKey: appAttestDefaultsKey)
    } catch {
      logger.error("Failed to encode App Attest info: \(error.localizedDescription)")
    }
  }

  // MARK: - Content Filtering Helper

  /// Build FeedTunerSettings from current user preferences
  /// This ensures consistent filtering across feeds, threads, profiles, and search
  @MainActor
  func buildFilterSettings() async -> FeedTunerSettings {
    // Get current user DID (AppState represents single account)
    let currentUserDid = self.userDID

    // Get moderation preferences from PreferencesManager
    var contentLabelPrefs: [ContentLabelPreference] = []
    var adultContentEnabled = false
    var preferredLanguages: [String] = []
    var feedViewPref: FeedViewPreference?

    do {
      let preferences = try await preferencesManager.loadPreferences()
      contentLabelPrefs = preferences?.contentLabelPrefs ?? []
      adultContentEnabled = preferences?.adultContentEnabled ?? false
      preferredLanguages = preferences?.contentLanguages ?? ["en"]
      feedViewPref = preferences?.feedViewPref
    } catch {
      logger.warning("Could not load preferences for filtering: \(error.localizedDescription)")
    }

    // Get muted and blocked users from GraphManager
    let mutedUsers = graphManager.muteCache
    let blockedUsers = graphManager.blockCache

    // Get feed filter settings (quick filters - these override server prefs)
    let hideRepliesQuick = feedFilterSettings.hideReplies
    let hideRepostsQuick = feedFilterSettings.hideReposts
    let hideQuotePostsQuick = feedFilterSettings.hideQuotePosts
    let hideLinks = feedFilterSettings.hideLinks
    let onlyTextPosts = feedFilterSettings.onlyTextPosts
    let onlyMediaPosts = feedFilterSettings.onlyMediaPosts

    // Get hidden posts from PostHidingManager
    let hiddenPosts = postHidingManager.hiddenPosts

    // Build settings - combine quick filters with server-synced preferences
    return FeedTunerSettings(
      hideReplies: hideRepliesQuick || (feedViewPref?.hideReplies ?? false),
      hideRepliesByUnfollowed: feedViewPref?.hideRepliesByUnfollowed ?? false,
      hideRepliesByLikeCount: feedViewPref?.hideRepliesByLikeCount,
      hideReposts: hideRepostsQuick || (feedViewPref?.hideReposts ?? false),
      hideQuotePosts: hideQuotePostsQuick || (feedViewPref?.hideQuotePosts ?? false),
      hideNonPreferredLanguages: !preferredLanguages.isEmpty && preferredLanguages != ["en"],
      preferredLanguages: preferredLanguages,
      mutedUsers: mutedUsers,
      blockedUsers: blockedUsers,
      hideLinks: hideLinks,
      onlyTextPosts: onlyTextPosts,
      onlyMediaPosts: onlyMediaPosts,
      contentLabelPreferences: contentLabelPrefs,
      hideAdultContent: !adultContentEnabled,
      hiddenPosts: hiddenPosts,
      currentUserDid: currentUserDid
    )
  }
}

// MARK: - MLS Initialization Errors

enum MLSInitializationError: Error, LocalizedError {
  case noConversationManager

  var errorDescription: String? {
    switch self {
    case .noConversationManager:
      return "MLS conversation manager not available"
    }
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
