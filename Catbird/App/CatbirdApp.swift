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

        // Set notification center delegate for handling MLS notifications
        UNUserNotificationCenter.current().delegate = self

      // BGTask registration moved to CatbirdApp.init() to ensure it happens before SwiftUI rendering
      
      // FaultOrdering debugging and setup for physical devices
      logger.debug("🔍 App launched with environment:")
      for (key, value) in ProcessInfo.processInfo.environment {
        if key.contains("FAULT") || key.contains("RUN_") || key.contains("DYLD") || key.contains("XCTest") {
          logger.debug("  \(key) = \(value)")
        }
      }
      
      // CRITICAL FOR PHYSICAL DEVICE: Force set environment variables if in test environment
      if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
        logger.debug("🧪 Running in XCTest environment - checking for FaultOrdering flags")
        
        // Only set FaultOrdering variables if explicitly requested
        if ProcessInfo.processInfo.environment["ENABLE_FAULT_ORDERING"] == "1" {
          logger.debug("✅ FaultOrdering explicitly enabled via ENABLE_FAULT_ORDERING")
          
          // Force set the environment variables that FaultOrdering needs
          setenv("RUN_FAULT_ORDER", "1", 1)
          setenv("RUN_FAULT_ORDER_SETUP", "1", 1)
          setenv("FAULT_ORDERING_ENABLE", "1", 1)
          
          // Verify they were set
          if let runFaultOrder = getenv("RUN_FAULT_ORDER") {
            logger.debug("✅ RUN_FAULT_ORDER set to: \(String(cString: runFaultOrder))")
          }
          if let runFaultOrderSetup = getenv("RUN_FAULT_ORDER_SETUP") {
            logger.debug("✅ RUN_FAULT_ORDER_SETUP set to: \(String(cString: runFaultOrderSetup))")
          }
        } else {
          logger.debug("⚠️ FaultOrdering not enabled - set ENABLE_FAULT_ORDERING=1 to activate")
        }
      }
      
      // Check if FaultOrdering framework is loaded
      if ProcessInfo.processInfo.environment["FAULT_ORDERING_ENABLE"] == "1" || 
         ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
        logger.debug("🔍 FaultOrdering mode detected in AppDelegate")
        
        // Check if debugger is attached (this is what FaultOrdering checks)
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, 4, &info, &size, nil, 0)
        let debuggerAttached = (result == 0) && (info.kp_proc.p_flag & P_TRACED) != 0
        logger.debug("🔍 Debugger attached: \(debuggerAttached)")
        
        // For physical devices, the debugger might not be attached in the traditional sense
        if !debuggerAttached {
          logger.debug("⚠️ Debugger not attached - FaultOrdering may not work correctly")
        }
      }
      
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

    // Fast path for FaultOrdering tests - skip expensive initialization
    let isFaultOrderingMode = ProcessInfo.processInfo.environment["FAULT_ORDERING_ENABLE"] == "1" ||
                              ProcessInfo.processInfo.environment["RUN_FAULT_ORDER"] == "1" ||
                              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    
    if isFaultOrderingMode {
      logger.info("⚡ FaultOrdering mode detected - using fast initialization")
      // Force set environment for FaultOrdering on physical device
      setenv("FAULT_ORDERING_ENABLE", "1", 1)
    } else {
      // MARK: - Navigation Bar Configuration
      // Navigation bar theme is handled completely by ThemeManager during AppState.initialize()
      // to avoid conflicts between initial setup and dynamic theme changes
    }

    // Don't configure audio session at app launch - let it remain in default state
    // This prevents interrupting music or other audio apps when the app starts
    // AudioSessionManager will configure it only when needed (explicit unmute)
    #if os(iOS)
    logger.debug("✅ Skipping audio session configuration at launch to preserve music")
    #endif

    // ModelContainer initialization deferred to async task to avoid blocking main thread

    // Initialize debug tools in development builds (skip for FaultOrdering)
    #if DEBUG
      if !isFaultOrderingMode {
        setupDebugTools()
      }
    #endif

    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 15.0, *), !isFaultOrderingMode {
      Task(priority: .background) {
        await TopicSummaryService.shared.prepareModelWarmupIfNeeded()
      }
    }
    #endif
  }

  // MARK: - ModelContainer Async Initialization

  @MainActor
  private func initializeModelContainer() async {
    logger.info("📦 Starting async ModelContainer initialization")

    let isFaultOrderingMode = ProcessInfo.processInfo.environment["FAULT_ORDERING_ENABLE"] == "1" ||
                              ProcessInfo.processInfo.environment["RUN_FAULT_ORDER"] == "1" ||
                              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

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

      if isFaultOrderingMode {
        // Minimal model container for FaultOrdering - only essential models
        container = try ModelContainer(
          for: Preferences.self, AppSettingsModel.self, DraftPost.self,
          configurations: ModelConfiguration(cloudKitDatabase: .none)
        )
        logger.debug("✅ Minimal model container initialized for FaultOrdering")
      } else {
        // Full model container for normal use
        container = try ModelContainer(
          for: CachedFeedViewPost.self, PersistedScrollPosition.self, PersistedFeedState.self, FeedContinuityInfo.self, Preferences.self, AppSettingsModel.self, DraftPost.self,
          configurations: ModelConfiguration(cloudKitDatabase: .none)
        )
        logger.debug("✅ Model container initialized successfully")
      }

      appStateManager.modelContainerState = .ready(container)

    } catch {
      logger.error("❌ Could not initialize ModelContainer: \(error)")

      // Try to recover
      do {
        let container = try await recoverModelContainer(isFaultOrderingMode: isFaultOrderingMode, error: error)
        appStateManager.modelContainerState = .ready(container)
      } catch {
        logger.error("❌ Failed to recover ModelContainer: \(error)")
        appStateManager.modelContainerState = .failed(error)
      }
    }
  }

  @MainActor
  private func recoverModelContainer(isFaultOrderingMode: Bool, error: Error) async throws -> ModelContainer {
    if isFaultOrderingMode {
      // For FaultOrdering, use in-memory store if file fails
      let container = try ModelContainer(
        for: Preferences.self, AppSettingsModel.self, DraftPost.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
      )
      logger.debug("✅ In-memory model container created for FaultOrdering")
      return container
    } else {
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

      let dbURL = appDocumentsURL.appendingPathComponent("Catbird.sqlite")

      if fileManager.fileExists(atPath: dbURL.path) {
        try fileManager.removeItem(at: dbURL)
        logger.info("🔄 Removed corrupted database, attempting recreate")

        // Retry initialization
        let container = try ModelContainer(
          for: CachedFeedViewPost.self, PersistedScrollPosition.self, PersistedFeedState.self, FeedContinuityInfo.self, Preferences.self, AppSettingsModel.self, DraftPost.self,
          configurations: ModelConfiguration(cloudKitDatabase: .none)
        )
        logger.debug("✅ Model container recreated successfully after recovery")
        return container
      } else {
        // Fallback to in-memory storage
        logger.warning("⚠️ Using in-memory storage as fallback")
        let container = try ModelContainer(
          for: CachedFeedViewPost.self, PersistedScrollPosition.self, PersistedFeedState.self, FeedContinuityInfo.self, Preferences.self, AppSettingsModel.self, DraftPost.self,
          configurations: ModelConfiguration("Catbird", isStoredInMemoryOnly: true)
        )
        return container
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

          if url.absoluteString.contains("/oauth/callback") {
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
    Task { @MainActor in
      await FeedStateStore.shared.handleScenePhaseChange(newPhase)

#if os(iOS)
      // Flush as early as possible (active → inactive) while file access is still valid.
      if oldPhase == .active, newPhase == .inactive {
        if let appState = appStateManager.lifecycle.appState {
          await appState.flushMLSStorageForSuspension()
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
#endif
      }
    }
  }

  func initializeApplicationIfNeeded() async {
    logger.info("📍 initializeApplicationIfNeeded called")
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

    let isFaultOrderingMode = ProcessInfo.processInfo.environment["FAULT_ORDERING_ENABLE"] == "1" ||
      ProcessInfo.processInfo.environment["RUN_FAULT_ORDER"] == "1" ||
      ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    if isFaultOrderingMode {
      configureFaultOrderingEnvironment()
    }

    if !isFaultOrderingMode {
#if DEBUG
      try? Tips.resetDatastore()
#endif
      try? Tips.configure([
        .displayFrequency(.immediate),
        .datastoreLocation(.applicationDefault)
      ])
    }

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

  func configureFaultOrderingEnvironment() {
    logger.info("⚡ FaultOrdering measurement mode detected - initializing measurement server")

    setenv("FAULT_ORDERING_ENABLE", "1", 1)

    logger.info("🔍 FaultOrdering debugging:")
    logger.info("FAULT_ORDERING_ENABLE: \(ProcessInfo.processInfo.environment["FAULT_ORDERING_ENABLE"] ?? "not set")")
    logger.info("RUN_FAULT_ORDER: \(ProcessInfo.processInfo.environment["RUN_FAULT_ORDER"] ?? "not set")")
    logger.info("XCTestConfigurationFilePath: \(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] ?? "not set")")
    logger.info("DYLD_INSERT_LIBRARIES: \(ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"] ?? "not set")")
#if targetEnvironment(simulator)
    logger.info("💻 Running on simulator")
#else
    logger.info("📱 Running on physical device")
#endif

    if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
      let linkmapURL = documentsURL.appendingPathComponent("linkmap-addresses.json")
      let exists = FileManager.default.fileExists(atPath: linkmapURL.path)
      logger.info("🔍 Linkmap file exists at \(linkmapURL.path): \(exists)")
    }

    Task.detached(priority: .high) {
      logger.info("⚡ Starting keep-alive task for FaultOrdering measurement")
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
      }
    }

    Task.detached(priority: .background) {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(5))
        logger.debug("🔄 FaultOrdering keep-alive ping")
      }
    }
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

    // Handle MLS notifications
    if let type = userInfo["type"] as? String {
      if type == "keyPackageLowInventory" {
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
    }

    completionHandler()
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // For MLS notifications, don't show banner/alert (they're silent background notifications)
    let userInfo = notification.request.content.userInfo
    if let type = userInfo["type"] as? String, type == "keyPackageLowInventory" {
      // Silent notification - process in background
      Task { @MainActor in
        guard let appState = AppStateManager.shared.lifecycle.appState else {
          let logger = Logger(subsystem: "blue.catbird", category: "AppDelegate")
          logger.warning("AppState not available for MLS notification handling")
          return
        }
        await MLSNotificationHandler.shared.handleKeyPackageLowInventory(userInfo: userInfo, appState: appState)
      }
      completionHandler([]) // No presentation
    } else {
      // Show other notifications normally
      completionHandler([.banner, .sound, .badge])
    }
  }
}
#endif 
