import AVFoundation
import Sentry

import CoreText
import GRDB
import OSLog
import Petrel
import Security
import SwiftData
import SwiftUI
import TipKit
import CatbirdMLSCore
import CatbirdMLSService
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import UserNotifications
import WidgetKit
import Darwin // For sysctl constants
#if canImport(FoundationModels)
import FoundationModels
#endif

// App-wide logger
let logger = Logger(subsystem: "blue.catbird", category: "AppLifecycle")

// NOTE: ModelContainerState enum moved to AppStateManager.swift to persist across App struct recreations

@main
struct CatbirdApp: App {
  #if os(iOS)
  // MARK: - App Delegate for UIKit callbacks
    class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    // Note: Access AppState via AppStateManager.shared.activeState instead of storing it

    func application(
      _ application: UIApplication,
      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Initialize Sentry through SentryService for proper configuration
        SentryService.start()

        // Initialize MetricKit for performance and diagnostic monitoring
        MetricKitManager.shared.start()
        MetricKitManager.shared.beginExtendedLaunchMeasurement(taskName: "AppInitialization")

        // Set notification center delegate for handling MLS notifications
        UNUserNotificationCenter.current().delegate = self

      // BGTask registration moved to CatbirdApp.init() to ensure it happens before SwiftUI rendering
      
      // Request widget updates at app launch
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(1))
        guard AppStateManager.shared.lifecycle.appState != nil else { return }
        // Force widget to refresh
        WidgetCenter.shared.reloadAllTimelines()
        logger.info("🔄 Requested widget refresh at app launch")
      }
      
      // Tell UIKit that state restoration setup is complete
      application.completeStateRestoration()

      // Schedule BGTasks now that registration happened at the beginning
      if #available(iOS 13.0, *) {
        BGTaskSchedulerManager.schedule()
        ChatBackgroundRefreshManager.schedule()
        BackgroundCacheRefreshManager.schedule()
        MLSBackgroundRefreshManager.scheduleInitialRefresh()
      }
      
      return true
    }

    func application(
      _ application: UIApplication, 
      shouldSaveApplicationState coder: NSCoder
    ) -> Bool {
      // Enable state saving - always save unless in testing mode
      let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
      logger.debug("State restoration: shouldSaveApplicationState = \(!isTesting)")
      return !isTesting
    }

    func application(
      _ application: UIApplication, 
      shouldRestoreApplicationState coder: NSCoder
    ) -> Bool {
      // Enable state restoration - always restore unless in testing mode
      let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
      logger.debug("State restoration: shouldRestoreApplicationState = \(!isTesting)")
      return !isTesting
    }

    func application(
      _ application: UIApplication,
      viewControllerWithRestorationIdentifierPath identifierComponents: [String],
      coder: NSCoder
    ) -> UIViewController? {
      // Let view controllers handle their own restoration
      logger.debug("State restoration: viewControllerWithRestorationIdentifierPath = \(identifierComponents)")
      return nil
    }

    func application(
      _ application: UIApplication,
      didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
      let logger = Logger(subsystem: "blue.catbird", category: "AppDelegate")
      logger.info("📱 Received device token from APNS, length: \(deviceToken.count) bytes")

      // Forward the device token to our notification manager
      guard let activeState = AppStateManager.shared.lifecycle.appState else {
        logger.error("❌ Cannot handle device token - no active AppState")
        return
      }

      Task {
        await activeState.notificationManager.handleDeviceToken(deviceToken)
      }
    }

    func application(
      _ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
      let logger = Logger(subsystem: "blue.catbird", category: "AppDelegate")
      logger.error("Failed to register for remote notifications: \(error.localizedDescription)")
    }

    func application(
      _ application: UIApplication,
      didReceiveRemoteNotification userInfo: [AnyHashable: Any],
      fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
      let logger = Logger(subsystem: "blue.catbird", category: "AppDelegate")
      logger.info("Received remote notification")

      // Check if this is an MLS notification
      if let type = userInfo["type"] as? String, type == "keyPackageLowInventory" {
        logger.info("Processing MLS key package low inventory notification")

        Task { @MainActor in
          guard let activeState = AppStateManager.shared.lifecycle.appState else {
            logger.warning("AppState not available for MLS notification handling")
            completionHandler(.noData)
            return
          }
          await MLSNotificationHandler.shared.handleKeyPackageLowInventory(userInfo: userInfo, appState: activeState)
          completionHandler(.newData)
        }
      } else if let convoId = userInfo["convoId"] as? String ?? userInfo["conversationId"] as? String {
        logger.info("Processing MLS chat notification for conversation: \(convoId)")
        
        // Trigger a sync for this conversation if possible
        Task { @MainActor in
            guard let activeState = AppStateManager.shared.lifecycle.appState else {
                completionHandler(.noData)
                return
            }
            
            // If we have a conversation manager, trigger a sync/catchup
            if let manager = await activeState.getMLSConversationManager() {
                logger.info("Triggering catchup for conversation \(convoId)")
                await manager.triggerCatchup(for: convoId)
                completionHandler(.newData)
            } else {
                completionHandler(.noData)
            }
        }
      } else {
        logger.debug("Not an MLS notification, ignoring. Keys: \(userInfo.keys.map { String(describing: $0) }.joined(separator: ", "))")
        completionHandler(.noData)
      }
    }
  }

  #endif
  
  // MARK: - State
  // Use singleton AppState to prevent multiple instances
  internal let appStateManager = AppStateManager.shared
  
  // Convenience property to access active AppState
  @MainActor
  var appState: AppState? {
    appStateManager.lifecycle.appState
  }
  
  // NOTE: didInitialize, hasHandledSceneAppear, hasRestoredState, and modelContainerState
  // have been moved to AppStateManager.shared to persist across App struct recreations.
  // Using @State in App structs is unreliable - iOS can recreate the struct on background/foreground
  // transitions and reset all @State to initial values.
  
  // These biometric-related states stay as @State since they intentionally reset on app relaunch
  // (security feature: require re-authentication after 5 minutes in background)
  @State private var isAuthenticatedWithBiometric = false
  @State private var showBiometricPrompt = false
  @State private var hasBiometricCheck = false
  
  // MARK: - State Restoration
  @State private var restorationIdentifier = "CatbirdMainApp"

  @Environment(\.modelContext) private var modelContext
  @Environment(\.scenePhase) private var scenePhase

  #if os(iOS)
  // App delegate instance
  @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
  #endif

  // MARK: - Initialization
  init() {
    logger.info("🚀 CatbirdApp initializing")

    // Bridge Petrel logs into Sentry (Sentry is initialized in AppDelegate)
    PetrelSentryBridge.enable()
    // Bridge Petrel auth incidents to UI to prevent silent auto-switching UX
    PetrelAuthUIBridge.enable()

    // BGTask registration deferred to background task to speed up launch

      
#if os(iOS)
NavigationFontConfig.applyEarlyNavigationBarAppearance()
#endif


    // Don't configure audio session at app launch - let it remain in default state
    // This prevents interrupting music or other audio apps when the app starts
    // AudioSessionManager will configure it only when needed (explicit unmute)
    #if os(iOS)
    logger.debug("✅ Skipping audio session configuration at launch to preserve music")
    #endif

    // ModelContainer initialization deferred to async task to avoid blocking main thread

    #if DEBUG
        setupDebugTools()
    #endif

    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 15.0, *) {
      Task(priority: .background) {
        await TopicSummaryService.shared.prepareModelWarmupIfNeeded()
      }
    }
    #endif
  }

  // MARK: - Schema Version Management

  /// Current schema version - increment this when making breaking schema changes
  /// This forces a database reset for users with older incompatible schemas
  private static let currentSchemaVersion = 2  // Increment when schema changes break migration

  /// Checks if database needs reset due to schema version mismatch
  private func shouldResetDatabase() -> Bool {
    let savedVersion = UserDefaults.standard.integer(forKey: "CatbirdSchemaVersion")
    return savedVersion != 0 && savedVersion < Self.currentSchemaVersion
  }

  /// Saves current schema version after successful initialization
  private func saveSchemaVersion() {
    UserDefaults.standard.set(Self.currentSchemaVersion, forKey: "CatbirdSchemaVersion")
  }

  // MARK: - ModelContainer Async Initialization

  @MainActor
  private func initializeModelContainer() async {
    logger.info("📦 Starting async ModelContainer initialization")

    // Check for schema version mismatch and proactively reset if needed
    if shouldResetDatabase() {
      logger.warning("⚠️ Schema version mismatch detected, resetting database for clean migration")
      if let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
        deleteAllDatabaseFiles(in: docsURL)
      }
    }

    do {
      guard let appDocumentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
        throw NSError(domain: "CatbirdApp", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to access documents directory"])
      }

      // Ensure app group container directories exist before SwiftData initialization
      // SwiftData may try to use the app group container for storage
      if let appGroupContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.blue.catbird.shared") {
        let applicationSupportDir = appGroupContainer.appendingPathComponent("Library/Application Support", isDirectory: true)
        if !FileManager.default.fileExists(atPath: applicationSupportDir.path) {
          do {
            try FileManager.default.createDirectory(at: applicationSupportDir, withIntermediateDirectories: true)
            logger.debug("✅ Created app group Application Support directory")
          } catch {
            logger.warning("⚠️ Failed to create app group Application Support directory: \(error.localizedDescription)")
          }
        }
      }

      let container: ModelContainer

        // Full model container for normal use
        container = try ModelContainer(
          for: CachedFeedViewPost.self, PersistedScrollPosition.self, PersistedFeedState.self, FeedContinuityInfo.self, Preferences.self, AppSettingsModel.self, DraftPost.self,
          configurations: ModelConfiguration(cloudKitDatabase: .none)
        )
        logger.debug("✅ Model container initialized successfully")

      // Save schema version on successful init
      saveSchemaVersion()
      appStateManager.modelContainerState = .ready(container)

    } catch {
      logger.error("❌ Could not initialize ModelContainer: \(error)")

      // Try to recover
      do {
        let container = try await recoverModelContainer(error: error)
        appStateManager.modelContainerState = .ready(container)
      } catch {
        logger.error("❌ Failed to recover ModelContainer: \(error)")
        appStateManager.modelContainerState = .failed(error)
      }
    }
  }

  @MainActor
  private func recoverModelContainer(error: Error) async throws -> ModelContainer {
      // Try to recover by deleting corrupted database
      let fileManager = FileManager.default
      guard let appDocumentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
        // Fallback to in-memory storage if documents directory is inaccessible
        logger.warning("⚠️ Documents directory inaccessible, using in-memory storage")
        let container = try ModelContainer(
          for: CachedFeedViewPost.self, Preferences.self, AppSettingsModel.self, DraftPost.self,
          configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return container
      }

      // Delete ALL SQLite-related files (main database + journal files)
      deleteAllDatabaseFiles(in: appDocumentsURL)

      // Retry initialization
      do {
        let container = try ModelContainer(
          for: CachedFeedViewPost.self, PersistedScrollPosition.self, PersistedFeedState.self, FeedContinuityInfo.self, Preferences.self, AppSettingsModel.self, DraftPost.self,
          configurations: ModelConfiguration(cloudKitDatabase: .none)
        )
        logger.debug("✅ Model container recreated successfully after recovery")
        return container
      } catch {
        // Final fallback to in-memory storage
        logger.warning("⚠️ Using in-memory storage as fallback after recovery failed: \(error)")
        let container = try ModelContainer(
          for: CachedFeedViewPost.self, PersistedScrollPosition.self, PersistedFeedState.self, FeedContinuityInfo.self, Preferences.self, AppSettingsModel.self, DraftPost.self,
          configurations: ModelConfiguration("Catbird", isStoredInMemoryOnly: true)
        )
        return container
      }
  }

  /// Deletes all SQLite database files (main, WAL, SHM) to ensure clean recovery
  private func deleteAllDatabaseFiles(in directory: URL) {
    let fileManager = FileManager.default
    let dbFiles = [
      "Catbird.sqlite",
      "Catbird.sqlite-wal",
      "Catbird.sqlite-shm",
      "default.store",           // SwiftData may use this name
      "default.store-wal",
      "default.store-shm"
    ]

    for fileName in dbFiles {
      let fileURL = directory.appendingPathComponent(fileName)
      if fileManager.fileExists(atPath: fileURL.path) {
        do {
          try fileManager.removeItem(at: fileURL)
          logger.info("🔄 Removed database file: \(fileName)")
        } catch {
          logger.warning("⚠️ Failed to remove \(fileName): \(error.localizedDescription)")
        }
      }
    }

    // Also check Application Support directory where SwiftData might store files
    if let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      for fileName in dbFiles {
        let fileURL = appSupportURL.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: fileURL.path) {
          do {
            try fileManager.removeItem(at: fileURL)
            logger.info("🔄 Removed database file from App Support: \(fileName)")
          } catch {
            logger.warning("⚠️ Failed to remove \(fileName) from App Support: \(error.localizedDescription)")
          }
        }
      }
    }
  }

  // MARK: - Background Task Registration

  @MainActor
  private func registerBackgroundTasks() async {
    #if os(iOS)
    if #available(iOS 13.0, *) {
      logger.debug("📋 Registering background tasks")
      BGTaskSchedulerManager.registerIfNeeded()
      ChatBackgroundRefreshManager.registerIfNeeded()
      BackgroundCacheRefreshManager.registerIfNeeded()
      MLSBackgroundRefreshManager.registerIfNeeded()
      logger.debug("✅ Background tasks registered")
    }
    #endif
  }

  // MARK: - Debug Tools Setup

  private func setupDebugTools() {
    // Set up logging tools for tracking blocking issues
    AVAssetPropertyTracker.setupBreakpointTracking()
    DebugMonitor.setupDebuggingRecommendations()

    // Log common debugging steps
    //    logger.info(
    //      """
    //      📊 PreferredTransform tracking enabled.
    //      You can diagnose the issue by:
    //      1. Looking for "PreferredTransform accessed on Main Thread" warnings in console
    //      2. Setting breakpoints as recommended by DebugMonitor
    //      3. Monitoring main thread blocking warnings
    //      """)
  }

  // MARK: - Cache Preloading

  /// Pre-load cached feed data for instant display at startup
  @MainActor
  private func preloadCachedFeedData(container: ModelContainer) async {
    logger.debug("📦 Pre-loading cached feed data for instant startup")

    let modelContext = container.mainContext

    // Query recent cached posts for the main timeline
    let sortDescriptors = [SortDescriptor<CachedFeedViewPost>(\.createdAt, order: .reverse)]
    let descriptor = FetchDescriptor<CachedFeedViewPost>(
      predicate: #Predicate<CachedFeedViewPost> { post in
        post.feedType == "following" || post.feedType == "notification-prefetch" || post.feedType == "thread-cache"
      },
      sortBy: sortDescriptors
    )

    do {
      let cachedPosts = try modelContext.fetch(descriptor)
      let postCount = cachedPosts.prefix(50).count

      if postCount > 0 {
        logger.info("✅ Pre-loaded \(postCount) cached posts for instant display")

        // Prefetch images for cached posts to make display truly instant
        let imageURLs = cachedPosts.prefix(20).compactMap { cachedPost -> URL? in
            return try? cachedPost.feedViewPost.post.author.finalAvatarURL()
        }

        if !imageURLs.isEmpty {
          let imageManager = ImageLoadingManager.shared
          await imageManager.startPrefetching(urls: imageURLs)
          logger.debug("🖼️ Pre-fetched \(imageURLs.count) avatar images")
        }
      } else {
        logger.debug("No cached posts found for pre-loading")
      }
    } catch {
      logger.error("Failed to pre-load cached feed data: \(error.localizedDescription)")
    }
  }

  // MARK: - Body
  var body: some Scene {
    WindowGroup {
      Group {
        switch appStateManager.modelContainerState {
        case .loading:
          LoadingView()
            .task {
              await initializeModelContainer()
            }

        case .ready(let container):
          sceneRoot()
            .onAppear {
              handleSceneAppear(container: container)
            }
            .environment(appStateManager)
            .modelContainer(container)
            // Monitor scene phase for feed state persistence
            .onChange(of: scenePhase) { oldPhase, newPhase in
              handleScenePhaseChange(from: oldPhase, to: newPhase)
            }
            .modifier(BiometricAuthModifier(performCheck: performInitialBiometricCheck))
            .task(priority: .high) {
              await initializeApplicationIfNeeded()
            }
            .task(priority: .background) {
              await registerBackgroundTasks()
            }

        case .failed(let error):
          ErrorRecoveryView(error: error, retry: {
            Task {
              await initializeModelContainer()
            }
          })
        }
      }
      .onOpenURL { url in
          logger.info("Received URL: \(url.absoluteString)")

          // Check for gateway BFF callback (Universal Link from catbird.blue)
          // Gateway redirects to: https://catbird.blue/oauth/callback#session_id=<uuid>
          if url.host == "catbird.blue" && url.path == "/oauth/callback" {
            logger.info("Gateway OAuth callback detected")
            Task {
              do {
                try await appStateManager.authentication.handleGatewayCallback(url)
                logger.info("Gateway OAuth callback handled successfully")
              } catch {
                logger.error("Error handling gateway callback: \(error)")
              }
            }
          } else if url.absoluteString.contains("/oauth/callback") {
            // Legacy public OAuth callback (direct ATProto OAuth)
            Task {
              do {
                try await appStateManager.authentication.handleCallback(url)
                logger.info("OAuth callback handled successfully")
              } catch {
                logger.error("Error handling OAuth callback: \(error)")
              }
            }
          } else if url.scheme == "blue.catbird" && url.host == "notifications" {
            // Handle widget notification deep link
            logger.info("Widget notification deep link received")

            // Instead of using the navigation system, directly set the selected tab
            Task { @MainActor in
              guard let appState = self.appState else { return }
              // Access the tab selection mechanism directly
              if let tabSelection = appState.navigationManager.tabSelection {
                tabSelection(2)  // Switch to notifications tab (index 2)
              } else {
                // Fallback if no tab selection mechanism is available
                appState.navigationManager.updateCurrentTab(2)
              }
            }
          } else if url.scheme == "blue.catbird" && url.host == "e2e" {
            // Handle E2E testing commands (only in E2E mode)
            logger.error("[E2E-URL] Received E2E URL: \(url.absoluteString), isE2EMode: \(appStateManager.isE2EMode)")
            if appStateManager.isE2EMode {
              Task { @MainActor in
                logger.error("[E2E-URL] Calling handleE2ECommand")
                await self.handleE2ECommand(url: url)
              }
            } else {
              logger.error("[E2E-URL] E2E URL received but not in E2E mode: \(url.absoluteString)")
            }
          } else {
            // Handle all other URLs through the URLHandler
            if let appState = self.appState {
              _ = appState.urlHandler.handle(url)
            } else {
              logger.error("URL received but AppState is unavailable")
            }
          }
        }
      }
      #if os(macOS)
      .windowStyle(.automatic)
      .defaultSize(width: 1200, height: 800)
      .commands {
        AppCommands()
      }
      #endif
    }
  }
 
private extension CatbirdApp {
  @ViewBuilder
  func sceneRoot() -> some View {
    Group {
      switch appStateManager.lifecycle {
      case .launching:
        LoadingView()

      case .unauthenticated:
        LoginView()
          .environment(appStateManager)

      case .authenticated(let appState):
        if shouldShowContentForAuthenticatedState {
          ContentView()
            .id(appState.userDID)
            .applyAppStateEnvironment(appState)
        } else {
          LoadingView()  // For biometric check
        }
      }
    }
    .overlay {
      biometricOverlay()
    }
  }

  @ViewBuilder
  func biometricOverlay() -> some View {
    if showBiometricPrompt,
       !isAuthenticatedWithBiometric {
      BiometricAuthenticationOverlay(
        isAuthenticated: $isAuthenticatedWithBiometric,
        authManager: appStateManager.authentication
      )
    }
  }

  func handleSceneAppear(container: ModelContainer) {
    // Guard to prevent multiple calls
    guard !appStateManager.hasHandledSceneAppear else {
      logger.debug("⏭️ Skipping handleSceneAppear - already handled")
      return
    }
    appStateManager.hasHandledSceneAppear = true
    logger.debug("✅ handleSceneAppear called for first time")

#if os(iOS)
    if let appState,
       let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let window = windowScene.windows.first,
       let rootVC = window.rootViewController {
      appState.urlHandler.registerTopViewController(rootVC)
      window.restorationIdentifier = "MainWindow"
      window.shouldGroupAccessibilityChildren = true

      Task {
        await restoreApplicationState()
      }
    }
#elseif os(macOS)
    Task {
      await restoreApplicationState()
    }
#endif

#if os(iOS)
    setupBackgroundNotification()
#endif

    PersistentFeedStateManager.initialize(with: container)

    Task { @MainActor in
      if let appState = self.appState {
        appState.composerDraftManager.setModelContext(container.mainContext)
        appState.notificationManager.setModelContext(container.mainContext)
      }
      FeedStateStore.shared.setModelContext(modelContext)
      await preloadCachedFeedData(container: container)
    }

    if #available(iOS 26.0, macOS 26.0, *) {
      let store = AppModelStore(modelContainer: container)
      Task { @MainActor in
        self.appState?.setModelStore(store)
      }
    }

    Task(priority: .background) {
      IncomingSharedDraftHandler.importIfAvailable()
    }
  }

  func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
    // CRITICAL FIX: Synchronously acquire background task assertion
    // This bridges the gap between the synchronous onChange callback and the async Task execution.
    // Without this, aggressive OS suspension (especially in Release builds) can freeze the app 
    // before the Task starts or while it's waiting for the MainActor, potentially causing 
    // 0xdead10cc crashes if file locks are held or acquired during the transition.
    var taskId: UIBackgroundTaskIdentifier = .invalid
    if newPhase == .inactive || newPhase == .background {
      taskId = UIApplication.shared.beginBackgroundTask(withName: "ScenePhaseTransition") {
        // Expiration handler: Clean up if we run out of time
        logger.warning("⏳ ScenePhaseTransition background task expired")
        if taskId != .invalid {
          UIApplication.shared.endBackgroundTask(taskId)
          taskId = .invalid
        }
      }
    }

    Task { @MainActor in
      // Ensure we release the background assertion when this update task completes
      defer {
        if taskId != .invalid {
          UIApplication.shared.endBackgroundTask(taskId)
          taskId = .invalid
        }
      }

      await FeedStateStore.shared.handleScenePhaseChange(newPhase)

#if os(iOS)
      if let appState = appStateManager.lifecycle.appState {
        MLSAppActivityState.setMainAppActive(newPhase == .active, activeUserDID: appState.userDID)
      } else {
        MLSAppActivityState.setMainAppActive(newPhase == .active, activeUserDID: nil)
      }

      // Flush as early as possible (active → inactive) while file access is still valid.
      if oldPhase == .active, newPhase == .inactive {
        // Signal MLS coordinator to break out of any blocking waits to prevent 0xdead10cc
        MLSDatabaseCoordinator.shared.prepareForSuspension()
        
        if let appState = appStateManager.lifecycle.appState {
          await appState.flushMLSStorageForSuspension()
        }
      }
      
      // CRITICAL FIX (2024-12): Reload MLS state from disk when returning to foreground
      // The NSE may have advanced the MLS ratchet while the app was in background.
      // Without this, the app's in-memory state is stale and will cause:
      // - SecretReuseError (trying to use a nonce the NSE already consumed)
      // - InvalidEpoch (app at epoch N but disk/server is at N+1)
      // - DecryptionFailed (using old keys deleted by forward secrecy)
      if (oldPhase == .background || oldPhase == .inactive), newPhase == .active {
        // Resume normal coordination operations
        MLSDatabaseCoordinator.shared.resumeFromSuspension()
        
        if let appState = appStateManager.lifecycle.appState {
          await appState.reloadMLSStateFromDisk()
        }
      }
#endif

      if newPhase == .background {
        saveApplicationState()
#if os(iOS)
        if #available(iOS 13.0, *) {
          ChatBackgroundRefreshManager.schedule()
          BackgroundCacheRefreshManager.schedule()
          MLSBackgroundRefreshManager.scheduleInitialRefresh()
        }
        
        // ═══════════════════════════════════════════════════════════════════════════
        // IDLE MAINTENANCE (2024-12): Perform database cleanup when entering background
        // ═══════════════════════════════════════════════════════════════════════════
        // This helps prevent WAL file growth and resource exhaustion by:
        // 1. Checkpointing WAL files to merge changes into main DB
        // 2. Closing inactive database connections
        // 3. Logging health metrics for debugging
        // ═══════════════════════════════════════════════════════════════════════════
        // CRITICAL FIX: Disabled to prevent 0xdead10cc crashes (holding locks during suspension).
        // The active user is already handled by flushMLSStorageForSuspension() in .inactive phase.
        // Task(priority: .utility) {
        //   await MLSGRDBManager.shared.performIdleMaintenance(aggressiveCheckpoint: false)
        // }
#endif
      }
    }
  }

  func initializeApplicationIfNeeded() async {
    logger.info("📍 initializeApplicationIfNeeded called")
    
    // ═══════════════════════════════════════════════════════════════════════════
    // Log MLS FFI build ID for verification
    // ═══════════════════════════════════════════════════════════════════════════
    // This helps diagnose issues where the wrong FFI binary is shipped.
    // Both main app and NSE should log this - if they differ, it's a build problem.
    // ═══════════════════════════════════════════════════════════════════════════
    let ffiBuildId = getFfiBuildId()
    let ffiBuildInfo = getFfiBuildInfo()
    logger.info("🔧 [MLS-FFI] Build ID: \(ffiBuildId)")
    logger.info("🔧 [MLS-FFI] Build Info: \(ffiBuildInfo)")
    
    let shouldInitialize = await MainActor.run { () -> Bool in
      guard !appStateManager.didInitialize else {
        logger.debug("⚠️ Skipping duplicate initialization - already initialized")
        return false
      }

      appStateManager.didInitialize = true
      logger.info("🎯 Starting first-time app initialization (didInitialize set to true)")
      return true
    }

    guard shouldInitialize else {
      logger.info("⏭️ Skipping initialization (shouldInitialize = false)")
      return
    }


#if DEBUG
      try? Tips.resetDatastore()
#endif
      try? Tips.configure([
        .displayFrequency(.immediate),
        .datastoreLocation(.applicationDefault)
      ])

    // Initialize AppStateManager (checks auth, creates AppState if authenticated)
    logger.info("Starting app initialization")
    await appStateManager.initialize()
    logger.info("App initialization completed - lifecycle: \(appStateManager.lifecycle)")

    // If authenticated, initialize preferences manager and app services
    if let appState = appStateManager.lifecycle.appState {
      appState.initializePreferencesManager(with: modelContext)

      #if canImport(FoundationModels)
      if #available(iOS 26.0, macOS 15.0, *) {
        Task(priority: .background) {
          await TopicSummaryService.shared.prepareLaunchWarmup(appState: appState)
        }
      }
      #endif

      Task {
        do {
          if let prefs = try await appState.preferencesManager.loadPreferences(),
             !prefs.pinnedFeeds.contains(where: { SystemFeedTypes.isTimelineFeed($0) }) {
            // Reserved for targeted timeline feed repairs if needed.
          }
        } catch {
          logger.error("Error checking timeline feed: \(error)")
        }
      }

      // MLS initialization removed - will be lazily initialized when user opens chat
    }

    await performInitialBiometricCheck()

    Task { @MainActor in
      let defaults = UserDefaults(suiteName: "group.blue.catbird.shared")
      if let appLanguage = defaults?.string(forKey: "appLanguage") {
        AppLanguageManager.shared.applyLanguage(appLanguage)
        logger.info("Applied saved language preference: \(appLanguage)")
      }
    }

    logger.info("🎉 initializeApplicationIfNeeded completed - hasBiometricCheck: \(hasBiometricCheck)")
  }


  var shouldShowContent: Bool {
    let hasAppState = appState != nil
    let biometricEnabled = appStateManager.authentication.biometricAuthEnabled
    let authenticated = isAuthenticatedWithBiometric
    let result = hasAppState && hasBiometricCheck && (!biometricEnabled || authenticated)

    logger.info("🔍 shouldShowContent check: hasAppState=\(hasAppState), hasBiometricCheck=\(hasBiometricCheck), biometricEnabled=\(biometricEnabled), authenticated=\(authenticated) → result=\(result)")

    guard hasAppState else {
      logger.warning("⚠️ Not showing content: appState is nil")
      return false
    }
    return hasBiometricCheck && (!biometricEnabled || authenticated)
  }

  var shouldShowContentForAuthenticatedState: Bool {
    let biometricEnabled = appStateManager.authentication.biometricAuthEnabled
    let authenticated = isAuthenticatedWithBiometric

    guard biometricEnabled else {
      return true  // No biometric check needed
    }

    return authenticated  // Show content only if biometric passed
  }

  struct LoadingView: View {
    var body: some View {
      VStack(spacing: 20) {
        Image("CatbirdIcon")
          .resizable()
          .frame(width: 80, height: 80)
          .cornerRadius(16)

        ProgressView()
          .scaleEffect(1.5)

        Text("Loading...")
          .font(.headline)
          .foregroundColor(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.systemBackground)
    }
  }

  struct ErrorRecoveryView: View {
    let error: Error
    let retry: () -> Void

    var body: some View {
      VStack(spacing: 20) {
        Image(systemName: "exclamationmark.triangle")
          .font(.system(size: 60))
          .foregroundColor(.red)

        Text("Database Error")
          .font(.title)
          .fontWeight(.bold)

        Text(error.localizedDescription)
          .font(.body)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal)

        Button(action: retry) {
          Text("Try Again")
            .font(.headline)
            .foregroundColor(.white)
            .padding()
            .background(Color.blue)
            .cornerRadius(10)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.systemBackground)
    }
  }

  func performInitialBiometricCheck() async {
    logger.info("🔐 Starting initial biometric check")
    await checkBiometricAuthentication()
    await MainActor.run {
      logger.info("✅ Setting hasBiometricCheck = true")
      hasBiometricCheck = true
      logger.info("✅ hasBiometricCheck is now: \(hasBiometricCheck)")
    }
    logger.info("🔐 Completed initial biometric check")
  }

  func checkBiometricAuthentication() async {
    logger.info("🔍 Checking biometric authentication - appState: \(appState != nil)")
    guard appState != nil else {
      logger.warning("⚠️ Skipping biometric check - appState is nil")
      return
    }
    logger.info("🔍 Biometric enabled: \(appStateManager.authentication.biometricAuthEnabled), Already authenticated: \(isAuthenticatedWithBiometric)")
    guard appStateManager.authentication.biometricAuthEnabled,
          !isAuthenticatedWithBiometric else {
      logger.info("ℹ️ Skipping biometric prompt - not needed")
      return
    }

    await MainActor.run {
      logger.info("🔓 Showing biometric prompt")
      showBiometricPrompt = true
    }
  }

#if os(iOS)
  func setupBackgroundNotification() {
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { _ in
      UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "backgroundTime")
    }

    NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: .main
    ) { _ in
      let backgroundTime = UserDefaults.standard.double(forKey: "backgroundTime")
      let timeInBackground = Date().timeIntervalSince1970 - backgroundTime

      if timeInBackground > 300 {
        Task { @MainActor in
          isAuthenticatedWithBiometric = false
          hasBiometricCheck = false
        }
      }
    }
  }
#elseif os(macOS)
  func setupBackgroundNotification() {
    NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification,
      object: nil,
      queue: .main
    ) { _ in
      UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "inactiveTime")
    }

    NotificationCenter.default.addObserver(
      forName: NSApplication.willBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { _ in
      let inactiveTime = UserDefaults.standard.double(forKey: "inactiveTime")
      let timeInactive = Date().timeIntervalSince1970 - inactiveTime

      if timeInactive > 300 {
        Task { @MainActor in
          isAuthenticatedWithBiometric = false
          hasBiometricCheck = false
        }
      }
    }
  }
#endif

  // MARK: - E2E Testing URL Handlers
  
  /// Handle E2E testing URL commands
  /// Format: blue.catbird://e2e/{command}?{params}
  /// Commands:
  /// - create-conversation?targetDID=... - Create/join a conversation with the target user
  /// - send-message?text=...&conversationId=... - Send a message to a conversation
  /// - dump-state - Write MLS state dump to app container
  func handleE2ECommand(url: URL) async {
    let e2eLogger = Logger(subsystem: "blue.catbird.e2e", category: "Commands")
    
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let command = components.path.split(separator: "/").last.map(String.init) else {
      e2eLogger.error("[E2E] Invalid E2E URL: \(url.absoluteString)")
      return
    }
    
    let params = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item -> (String, String)? in
      guard let value = item.value else { return nil }
      return (item.name, value)
    })
    
    e2eLogger.info("[E2E] Handling command: \(command) with params: \(params.keys.joined(separator: ", "))")
    
    // Use AppStateManager singleton directly for E2E operations
    // The self.appState computed property may not be available if lifecycle is loading
    let manager = AppStateManager.shared
    
    // Proactively refresh token before any command to ensure fresh auth (especially for 60s token PDSs)
    if let appState = manager.lifecycle.appState, command != "dump-state" {
      do {
        e2eLogger.info("[E2E] Proactively refreshing token before command...")
        let refreshed = try await appState.client.refreshToken()
        e2eLogger.info("[E2E] Token refresh result: \(refreshed)")
      } catch {
        e2eLogger.warning("[E2E] Proactive token refresh failed: \(error.localizedDescription)")
        
        // For E2E mode with short-lived tokens, attempt full re-login
        e2eLogger.info("[E2E] Attempting fresh re-login due to expired tokens...")
        let reloginSuccess = await manager.e2eRelogin()
        if reloginSuccess {
          e2eLogger.info("[E2E] Re-login succeeded - continuing with fresh session")
        } else {
          e2eLogger.error("[E2E] Re-login failed - command may fail due to expired auth")
        }
      }
    }
    
    switch command {
    case "login":
      await handleLogin(params: params, manager: manager, logger: e2eLogger)
      
    case "register-device":
      await handleRegisterDevice(params: params, manager: manager, logger: e2eLogger)
      
    case "create-conversation":
      await handleCreateConversation(params: params, manager: manager, logger: e2eLogger)
      
    case "send-message":
      await handleSendMessage(params: params, manager: manager, logger: e2eLogger)
      
    case "get-messages":
      await handleGetMessages(params: params, manager: manager, logger: e2eLogger)
      
    case "dump-state":
      await handleDumpState(params: params, manager: manager, logger: e2eLogger)
      
    case "sync":
      await handleSync(params: params, manager: manager, logger: e2eLogger)
      
    default:
      e2eLogger.warning("[E2E] Unknown command: \(command)")
      await writeE2EResult(command: command, success: false, error: "Unknown command")
    }
  }
  
  private func handleRegisterDevice(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    e2eLogger.error("[E2E-REGISTER] Starting device registration / MLS opt-in")
    
    // Check if force flag is set (use force=true to re-register even if already registered)
    let forceReregister = params["force"]?.lowercased() == "true"
    
    guard let appState = manager.lifecycle.appState else {
      e2eLogger.error("[E2E-REGISTER] Not authenticated")
      await writeE2EResult(command: "register-device", success: false, error: "Not authenticated")
      return
    }
    
    do {
      guard let conversationManager = await appState.getMLSConversationManager() else {
        throw NSError(domain: "E2E", code: 1, userInfo: [NSLocalizedDescriptionKey: "MLS not initialized"])
      }
      
      // Step 1: Opt-in to MLS via the API client
      e2eLogger.error("[E2E-REGISTER] Calling optIn on MLSAPIClient")
      let (optedIn, optedInAt) = try await conversationManager.apiClient.optIn()
      e2eLogger.error("[E2E-REGISTER] optIn result: optedIn=\(optedIn), at=\(optedInAt)")
      
      // Step 2: Check if already registered to avoid invalidating existing key packages
      if let existingDeviceInfo = await conversationManager.mlsClient.getDeviceInfo(for: appState.userDID), !forceReregister {
        e2eLogger.error("[E2E-REGISTER] Already registered with deviceId: \(existingDeviceInfo.deviceId) - skipping reregistration to preserve key packages")
        await writeE2EResult(command: "register-device", success: true, data: [
          "status": "already_registered",
          "optedIn": String(optedIn),
          "deviceId": existingDeviceInfo.deviceId
        ])
        return
      }
      
      // Step 3: Register device (only if not already registered or force=true)
      e2eLogger.error("[E2E-REGISTER] \(forceReregister ? "Force re-registering" : "Registering") device for MLS")
      let deviceId = try await conversationManager.mlsClient.reregisterDevice(for: appState.userDID)
      e2eLogger.error("[E2E-REGISTER] Device registered: \(deviceId)")
      
      await writeE2EResult(command: "register-device", success: true, data: [
        "status": "registered",
        "optedIn": String(optedIn),
        "deviceId": deviceId
      ])
    } catch {
      e2eLogger.error("[E2E-REGISTER] Failed: \(error.localizedDescription)")
      await writeE2EResult(command: "register-device", success: false, error: error.localizedDescription)
    }
  }
  
  private func handleLogin(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let handle = params["handle"], let password = params["password"] else {
      e2eLogger.error("[E2E] login requires handle and password parameters")
      await writeE2EResult(command: "login", success: false, error: "Missing handle or password")
      return
    }
    
    e2eLogger.info("[E2E] Attempting password login for: \(handle)")
    
    do {
      // Use AuthManager's password login (app password)
      try await manager.authentication.loginWithPasswordForE2E(identifier: handle, password: password)
      e2eLogger.info("[E2E] Login succeeded for: \(handle)")
      
      // Wait for app state to initialize
      try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
      
      let userDID = manager.authentication.state.userDID ?? "unknown"
      await writeE2EResult(command: "login", success: true, data: [
        "handle": handle,
        "userDID": userDID
      ])
    } catch {
      e2eLogger.error("[E2E] Login failed: \(error.localizedDescription)")
      await writeE2EResult(command: "login", success: false, error: error.localizedDescription)
    }
  }
  
  private func handleCreateConversation(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let targetDID = params["targetDID"] else {
      e2eLogger.error("[E2E] create-conversation requires targetDID parameter")
      await writeE2EResult(command: "create-conversation", success: false, error: "Missing targetDID")
      return
    }
    
    guard let appState = manager.lifecycle.appState else {
      e2eLogger.error("[E2E] Not authenticated - cannot create conversation")
      await writeE2EResult(command: "create-conversation", success: false, error: "Not authenticated")
      return
    }
    
    let groupName = params["name"] ?? "E2E Test Conversation"
    
    e2eLogger.info("[E2E] Creating conversation with: \(targetDID)")
    
    do {
      // Get or create conversation via MLS conversation manager
      guard let conversationManager = await appState.getMLSConversationManager() else {
        throw NSError(domain: "E2E", code: 1, userInfo: [NSLocalizedDescriptionKey: "MLS not initialized"])
      }
      
      // Create group with the target member (using DID type)
      let targetMember = try DID(didString: targetDID)
      let conversation = try await conversationManager.createGroup(
        initialMembers: [targetMember],
        name: groupName
      )
      
      e2eLogger.info("[E2E] Conversation created: \(conversation.groupId)")
      await writeE2EResult(command: "create-conversation", success: true, data: [
        "conversationId": conversation.groupId,
        "epoch": "\(conversation.epoch)"
      ])
      
    } catch {
      e2eLogger.error("[E2E] Failed to create conversation: \(error.localizedDescription)")
      await writeE2EResult(command: "create-conversation", success: false, error: error.localizedDescription)
    }
  }
  
  private func handleSendMessage(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let text = params["text"],
          let conversationId = params["conversationId"] else {
      e2eLogger.error("[E2E] send-message requires text and conversationId parameters")
      await writeE2EResult(command: "send-message", success: false, error: "Missing text or conversationId")
      return
    }
    
    guard let appState = manager.lifecycle.appState else {
      e2eLogger.error("[E2E] Not authenticated - cannot send message")
      await writeE2EResult(command: "send-message", success: false, error: "Not authenticated")
      return
    }
    
    e2eLogger.info("[E2E] Sending message to conversation: \(conversationId)")
    
    do {
      guard let conversationManager = await appState.getMLSConversationManager() else {
        throw NSError(domain: "E2E", code: 1, userInfo: [NSLocalizedDescriptionKey: "MLS not initialized"])
      }
      
      // Send the message (using correct API signature)
      let result = try await conversationManager.sendMessage(
        convoId: conversationId,
        plaintext: text
      )
      
      e2eLogger.info("[E2E] Message sent: \(result.messageId)")
      MLSDiagnosticLogger.shared.logE2EMessageSent(
        correlationId: manager.e2eRunId ?? "unknown",
        conversationId: conversationId,
        contentPreview: String(text.prefix(20))
      )
      
      await writeE2EResult(command: "send-message", success: true, data: [
        "messageId": result.messageId,
        "conversationId": conversationId,
        "epoch": "\(result.epoch)"
      ])
      
    } catch {
      e2eLogger.error("[E2E] Failed to send message: \(error.localizedDescription)")
      await writeE2EResult(command: "send-message", success: false, error: error.localizedDescription)
    }
  }
  
  private func handleGetMessages(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let conversationId = params["conversationId"] else {
      e2eLogger.error("[E2E] get-messages requires conversationId parameter")
      await writeE2EResult(command: "get-messages", success: false, error: "Missing conversationId")
      return
    }
    
    guard let appState = manager.lifecycle.appState else {
      e2eLogger.error("[E2E] Not authenticated")
      await writeE2EResult(command: "get-messages", success: false, error: "Not authenticated")
      return
    }
    
    guard let conversationManager = await appState.getMLSConversationManager() else {
      e2eLogger.error("[E2E] MLS not initialized")
      await writeE2EResult(command: "get-messages", success: false, error: "MLS not initialized")
      return
    }
    
    do {
      // Get encrypted messages from server
      let (messageViews, lastSeq, _) = try await conversationManager.apiClient.getMessages(
        convoId: conversationId,
        limit: 50
      )
      
      // Decrypt messages that we can
      var decryptedTexts: [String] = []
      for messageView in messageViews {
        do {
          let decrypted = try await conversationManager.decryptMessage(messageView, source: "e2e-test")
          let payload = decrypted.payload
          if payload.messageType == .text, let text = payload.text {
            decryptedTexts.append(text)
          } else if payload.messageType == .reaction, let reaction = payload.reaction {
            decryptedTexts.append("[reaction:\(reaction.action):\(reaction.emoji) on \(reaction.messageId.prefix(8))]")
          }
        } catch {
          // Skip messages we can't decrypt (from before we joined, etc)
          e2eLogger.debug("[E2E] Could not decrypt message: \(error.localizedDescription)")
        }
      }
      
      e2eLogger.info("[E2E] Got \(messageViews.count) messages, decrypted \(decryptedTexts.count) for conversation \(conversationId)")
      await writeE2EResult(command: "get-messages", success: true, data: [
        "conversationId": conversationId,
        "totalMessages": "\(messageViews.count)",
        "decryptedCount": "\(decryptedTexts.count)",
        "lastSeq": "\(lastSeq ?? 0)",
        "messages": decryptedTexts.joined(separator: "|")
      ])
    } catch {
      e2eLogger.error("[E2E] Failed to get messages: \(error.localizedDescription)")
      await writeE2EResult(command: "get-messages", success: false, error: error.localizedDescription)
    }
  }
  
  private func handleDumpState(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    e2eLogger.error("[E2E-DUMP] Entering handleDumpState")
    e2eLogger.error("[E2E-DUMP] manager.lifecycle: \(String(describing: manager.lifecycle))")
    
    guard let appState = manager.lifecycle.appState else {
      e2eLogger.error("[E2E-DUMP] Not authenticated - manager.lifecycle.appState is nil")
      await writeE2EResult(command: "dump-state", success: false, error: "Not authenticated")
      return
    }
    
    guard let conversationManager = await appState.getMLSConversationManager() else {
      e2eLogger.error("[E2E] MLS not initialized - getMLSConversationManager returned nil")
      await writeE2EResult(command: "dump-state", success: false, error: "MLS not initialized")
      return
    }
    
    e2eLogger.info("[E2E] Got conversation manager, reading conversations")
    
    // Get current MLS state from conversations dictionary
    let conversations = conversationManager.conversations
    
    e2eLogger.info("[E2E] State dump: \(conversations.count) conversations")
    MLSDiagnosticLogger.shared.logMLSStateDump(
      conversationCount: conversations.count,
      groupCount: conversations.count,
      pendingMessages: 0
    )
    
    e2eLogger.info("[E2E] Writing result file")
    await writeE2EResult(command: "dump-state", success: true, data: [
      "conversationCount": "\(conversations.count)",
      "conversations": conversations.keys.joined(separator: ",")
    ])
    e2eLogger.info("[E2E] Dump state complete")
  }
  
  private func handleSync(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    e2eLogger.info("[E2E-SYNC] Starting sync")
    
    guard let appState = manager.lifecycle.appState else {
      e2eLogger.error("[E2E-SYNC] Not authenticated")
      await writeE2EResult(command: "sync", success: false, error: "Not authenticated")
      return
    }
    
    guard let conversationManager = await appState.getMLSConversationManager() else {
      e2eLogger.error("[E2E-SYNC] MLS not initialized")
      await writeE2EResult(command: "sync", success: false, error: "MLS not initialized")
      return
    }
    
    do {
      // Use waitAndSyncWithServer to properly wait for any ongoing sync to complete
      // then trigger a fresh sync that actually fetches from server
      e2eLogger.info("[E2E-SYNC] Calling waitAndSyncWithServer (waits up to 60s for lock)...")
      try await conversationManager.waitAndSyncWithServer(maxWait: 60)
      
      let conversations = conversationManager.conversations
      e2eLogger.info("[E2E-SYNC] Sync complete, \(conversations.count) conversations")
      
      await writeE2EResult(command: "sync", success: true, data: [
        "conversationCount": "\(conversations.count)",
        "conversations": conversations.keys.joined(separator: ",")
      ])
    } catch {
      e2eLogger.error("[E2E-SYNC] Sync failed: \(error.localizedDescription)")
      await writeE2EResult(command: "sync", success: false, error: error.localizedDescription)
    }
  }
  
  /// Write E2E command result to a file the harness can read
  private func writeE2EResult(command: String, success: Bool, error: String? = nil, data: [String: String]? = nil) async {
    let e2eLogger = Logger(subsystem: "blue.catbird.e2e", category: "Results")
    
    // Write to app container where harness can read via simctl
    // Using "group.blue.catbird.shared" - the actual app group identifier
    guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.blue.catbird.shared") else {
      e2eLogger.error("[E2E] Cannot access app group container")
      return
    }
    
    let e2eDir = containerURL.appendingPathComponent("e2e", isDirectory: true)
    try? FileManager.default.createDirectory(at: e2eDir, withIntermediateDirectories: true)
    
    let resultFile = e2eDir.appendingPathComponent("last_result.json")
    
    var result: [String: Any] = [
      "command": command,
      "success": success,
      "timestamp": ISO8601DateFormatter().string(from: Date()),
      "runId": appStateManager.e2eRunId ?? "unknown"
    ]
    
    if let error = error {
      result["error"] = error
    }
    
    if let data = data {
      result["data"] = data
    }
    
    do {
      let jsonData = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted])
      try jsonData.write(to: resultFile)
      e2eLogger.info("[E2E] Result written to: \(resultFile.path)")
    } catch {
      e2eLogger.error("[E2E] Failed to write result: \(error.localizedDescription)")
    }
  }
}

// MARK: - Biometric Authentication Overlay
struct BiometricAuthenticationOverlay: View {
  @Binding var isAuthenticated: Bool
  let authManager: AuthenticationManager
  @State private var isAuthenticating = false
  
  var body: some View {
    ZStack {
      // Full screen background
      Color.black
        .platformIgnoresSafeArea()
      
      VStack(spacing: 30) {
        // App icon
        Image("CatbirdIcon")
          .resizable()
          .frame(width: 80, height: 80)
          .cornerRadius(16)
        
        Text("Catbird Locked")
          .font(.largeTitle)
          .fontWeight(.bold)
          .foregroundColor(.white)
        
        Text("Authenticate to continue")
          .font(.subheadline)
          .foregroundColor(.gray)
        
        if isAuthenticating {
          ProgressView()
            .progressViewStyle(CircularProgressViewStyle(tint: .white))
        } else {
          Button {
            Task {
              await authenticateWithBiometrics()
            }
          } label: {
            Label("Unlock with \(authManager.biometricType.displayName)", systemImage: biometricIcon)
              .font(.headline)
              .foregroundColor(.white)
              .padding()
              .background(Color.blue)
              .cornerRadius(10)
          }
        }
      }
    }
    .task {
      // Automatically prompt for biometric authentication when view appears
      await authenticateWithBiometrics()
    }
  }
  
  private var biometricIcon: String {
    switch authManager.biometricType {
    case .faceID:
      return "faceid"
    case .touchID:
      return "touchid"
    case .opticID:
      return "opticid"
    default:
      return "lock.shield"
    }
  }
  
  private func authenticateWithBiometrics() async {
    await MainActor.run {
      isAuthenticating = true
    }
    
    let success = await authManager.quickAuthenticationCheck()
    
    await MainActor.run {
      isAuthenticating = false
      if success {
        isAuthenticated = true
      }
    }
  }
}

// MARK: - BiometricAuthModifier

private struct BiometricAuthModifier: ViewModifier {
  let performCheck: () async -> Void
  
  func body(content: Content) -> some View {
    #if os(iOS)
    content
      .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
        Task {
          await performCheck()
        }
      }
    #elseif os(macOS)
    content
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.willBecomeActiveNotification)) { _ in
        Task {
          await performCheck()
        }
      }
    #else
    content
    #endif
  }
}

#if os(iOS)
// MARK: - UNUserNotificationCenterDelegate
extension CatbirdApp.AppDelegate {
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let logger = Logger(subsystem: "blue.catbird", category: "AppDelegate")
    let userInfo = response.notification.request.content.userInfo

    logger.info("User tapped notification")

    // 1. Handle silent background notifications (key inventory)
    if let type = userInfo["type"] as? String, type == "keyPackageLowInventory" {
      Task { @MainActor in
        guard let appState = AppStateManager.shared.lifecycle.appState else {
          logger.warning("AppState not available for MLS notification handling")
          completionHandler()
          return
        }
        await MLSNotificationHandler.shared.handleKeyPackageLowInventory(userInfo: userInfo, appState: appState)
        completionHandler()
      }
      return
    }
    
    // 2. Forward to NotificationManager for navigation handling if available
    if let appState = AppStateManager.shared.lifecycle.appState {
      appState.notificationManager.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
      return
    }

    // 3. Fallback handling if AppState/NotificationManager not ready
    // Handle MLS notifications
    if let type = userInfo["type"] as? String {
      switch type {
      case "mls_message", "mls_message_decrypted":
        // Handle MLS chat message notification tap
        // Navigate to the conversation and switch account if needed
        logger.info("🔐 MLS message notification tapped - navigating to conversation")
        
        guard let convoId = userInfo["convo_id"] as? String else {
          logger.warning("MLS notification missing convo_id")
          completionHandler()
          return
        }
        
        let recipientDid = userInfo["recipient_did"] as? String
        
        Task { @MainActor in
          // Switch to the correct account if needed
          if let targetDid = recipientDid {
            await self.switchToAccountIfNeeded(did: targetDid)
          }
          
          // Navigate to the MLS conversation
          await self.navigateToMLSConversation(convoId: convoId)
          
          completionHandler()
        }
        return
        
      default:
        break
      }
    }

    completionHandler()
  }
  
  /// Switch to a different account if it's not currently active
  @MainActor
  private func switchToAccountIfNeeded(did: String) async {
    let logger = Logger(subsystem: "blue.catbird", category: "AppDelegate")
    let appStateManager = AppStateManager.shared
    
    // Check if we're already on the correct account
    if appStateManager.lifecycle.userDID == did {
      logger.debug("Already on correct account: \(did.prefix(24))...")
      return
    }
    
    logger.info("🔄 Switching account to \(did.prefix(24))... for notification navigation")
    _ = await appStateManager.switchAccount(to: did)
    logger.info("✅ Account switched for notification navigation")
  }
  
  /// Navigate to an MLS conversation
  @MainActor
  private func navigateToMLSConversation(convoId: String) async {
    let logger = Logger(subsystem: "blue.catbird", category: "AppDelegate")
    
    // CRITICAL FIX: Wait for account transition to complete
    // This prevents accessing the wrong AppState or MLS manager during switch
    let maxTransitionWait: TimeInterval = 10.0
    let transitionCheckInterval: TimeInterval = 0.1
    var transitionElapsed: TimeInterval = 0
    
    while AppStateManager.shared.isTransitioning && transitionElapsed < maxTransitionWait {
        logger.debug("⏳ Waiting for account transition to complete...")
        try? await Task.sleep(nanoseconds: UInt64(transitionCheckInterval * 1_000_000_000))
        transitionElapsed += transitionCheckInterval
    }
    
    if AppStateManager.shared.isTransitioning {
        logger.error("❌ Account transition timed out - navigation may fail")
    } else {
        logger.info("✅ Account transition complete (or not needed)")
    }
    
    guard let appState = AppStateManager.shared.lifecycle.appState else {
      logger.warning("Cannot navigate to MLS conversation - AppState not available")
      return
    }

    // Wait for MLS service to be ready (up to 5 seconds)
    let maxWaitTime: TimeInterval = 5.0
    let checkInterval: TimeInterval = 0.2
    var elapsed: TimeInterval = 0
    var shouldWait = true
    
    while shouldWait && elapsed < maxWaitTime {
      let status = appState.mlsServiceState.status
      switch status {
      case .ready:
        logger.info("MLS service ready, proceeding with navigation")
        shouldWait = false
      case .failed, .databaseFailed:
        logger.warning("MLS service in failed state, proceeding with navigation anyway")
        shouldWait = false
      case .initializing, .notStarted, .retrying:
        // Still initializing, wait a bit
        try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
        elapsed += checkInterval
      }
    }
    
    if elapsed >= maxWaitTime {
      logger.warning("MLS service did not become ready within \(maxWaitTime)s, proceeding with navigation anyway")
    }
    
    logger.info("📍 Navigating to MLS conversation: \(convoId.prefix(16))...")
    
    // Switch to the chat tab (index 4) 
    appState.navigationManager.updateCurrentTab(4)
    
    // Navigate to the specific MLS conversation
    let destination = NavigationDestination.mlsConversation(convoId)
    appState.navigationManager.navigate(to: destination, in: 4)
    
    logger.info("✅ Navigation to MLS conversation initiated")
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let userInfo = notification.request.content.userInfo
    
    // 1. Handle silent background notifications (key inventory)
    if let type = userInfo["type"] as? String, type == "keyPackageLowInventory" {
      Task { @MainActor in
        guard let appState = AppStateManager.shared.lifecycle.appState else {
          let logger = Logger(subsystem: "blue.catbird", category: "AppDelegate")
          logger.warning("AppState not available for MLS notification handling")
          return
        }
        await MLSNotificationHandler.shared.handleKeyPackageLowInventory(userInfo: userInfo, appState: appState)
      }
      completionHandler([]) // No presentation
      return
    }
    
    // 2. Forward to NotificationManager for rich content/decryption if available
    if let appState = AppStateManager.shared.lifecycle.appState {
      appState.notificationManager.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
      return
    }
    
    // 3. Fallback: Show standard notifications normally
    completionHandler([.banner, .sound, .badge])
  }
}
#endif 
