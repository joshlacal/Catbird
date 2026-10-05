import AVFoundation
#if os(iOS)
import BackgroundTasks
#endif
import Sentry

import CoreText
import GRDB
import OSLog
import Petrel
import PetrelCatbird
import Security
import SwiftData
import SwiftUI
import TipKit
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

// Presentation fixtures deliberately bypass account bootstrap and networking.
private var isMessageRequestsUIFixture: Bool {
  #if DEBUG
  ProcessInfo.processInfo.arguments.contains("--message-requests-ui-fixture")
  #else
  false
  #endif
}

private var isVideoFeedUIFixture: Bool {
  #if DEBUG
  ProcessInfo.processInfo.arguments.contains("--video-feed-ui-fixture")
  #else
  false
  #endif
}

private var isSocialActionsUIFixture: Bool {
  #if DEBUG
  ProcessInfo.processInfo.arguments.contains("--social-actions-ui-fixture")
  #else
  false
  #endif
}

private var isSceneRuntimeUIFixture: Bool {
  #if DEBUG && os(iOS)
  ProcessInfo.processInfo.arguments.contains(SceneRuntimeFixture.launchArgument)
  #else
  false
  #endif
}

private var isInlineReplyUIFixture: Bool {
  #if DEBUG && os(iOS)
  ProcessInfo.processInfo.arguments.contains(InlineReplyValidationFixture.launchArgument)
  #else
  false
  #endif
}

private var isMessagesViewportUIFixture: Bool {
  #if DEBUG && os(iOS)
  ProcessInfo.processInfo.arguments.contains(MessagesViewportValidationFixture.launchArgument)
  #else
  false
  #endif
}

/// Any presentation fixture: skips account bootstrap and URL handling.
private var isPresentationUIFixture: Bool {
  isMessageRequestsUIFixture || isVideoFeedUIFixture || isSocialActionsUIFixture || isSettingsUIFixture || isSceneRuntimeUIFixture || isInlineReplyUIFixture || isMessagesViewportUIFixture
}

private var isSettingsUIFixture: Bool {
  #if DEBUG
  ProcessInfo.processInfo.arguments.contains("--settings-ui-fixture")
  #else
  false
  #endif
}

/// Hosted local StoreKit tests configure their session before opening the app's StoreKit connection.
private var shouldDeferSupportTipStartupForLocalTesting: Bool {
  #if DEBUG && os(iOS) && targetEnvironment(simulator)
  ProcessInfo.processInfo.arguments.contains("--support-tip-storekit-test")
  #else
  false
  #endif
}

// App-wide logger
let logger = Logger(subsystem: "blue.catbird", category: "AppLifecycle")

/// Owns the production SwiftData schema so app startup and migration tests open
/// exactly the same store shape.
enum CatbirdSwiftDataStore {
  static let modelTypes: [any PersistentModel.Type] = [
    CachedFeedViewPost.self, PersistedScrollPosition.self, PersistedFeedState.self,
    FeedContinuityInfo.self, Preferences.self, AppSettingsModel.self, DraftPost.self,
    BackupRecord.self, BackupConfiguration.self, RepositoryRecord.self,
    ParsedATProtocolRecord.self, ParsedPost.self, ParsedProfile.self,
    ParsedMedia.self, ParsedConnection.self, ParsedUnknownRecord.self,
  ]

  static func makeContainer(at storeURL: URL) throws -> ModelContainer {
    let schema = Schema(modelTypes)
    let configuration = ModelConfiguration(
      "Catbird",
      schema: schema,
      url: storeURL,
      cloudKitDatabase: .none
    )
    return try ModelContainer(for: schema, configurations: [configuration])
  }

  static func makeContainer(configuration: ModelConfiguration) throws -> ModelContainer {
    let schema = Schema(modelTypes)
    return try ModelContainer(for: schema, configurations: [configuration])
  }
}

// NOTE: ModelContainerState enum moved to AppStateManager.swift to persist across App struct recreations

@main
struct CatbirdApp: App {
  #if os(iOS)
  // MARK: - App Delegate for UIKit callbacks
    class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    // Note: Access AppState via AppStateManager.shared.activeState instead of storing it

    func application(
      _ application: UIApplication,
      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
      if isPresentationUIFixture { return true }
        // Initialize Sentry through SentryService for proper configuration
        SentryService.start()

        // Initialize MetricKit for performance and diagnostic monitoring
        if #available(iOS 26, *) {
          MetricKitManager.shared.start()
          MetricKitManager.shared.beginExtendedLaunchMeasurement(taskName: "AppInitialization")
        }

        // Set notification center delegate for handling notification taps and presentation
        UNUserNotificationCenter.current().delegate = self

      // BGTask handlers MUST be registered before didFinishLaunchingWithOptions returns
      if #available(iOS 13.0, *) {
        BGTaskSchedulerManager.registerIfNeeded()
        ChatBackgroundRefreshManager.registerIfNeeded()
        BackgroundCacheRefreshManager.registerIfNeeded()
      }

      // Request widget updates at app launch
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(1))
        guard AppStateManager.shared.lifecycle.appState != nil else { return }
        // Force widget to refresh
        WidgetCenter.shared.reloadAllTimelines()
        logger.info("🔄 Requested widget refresh at app launch")
      }
      
      // Schedule BGTasks now that registration happened at the beginning
      if #available(iOS 13.0, *) {
        BGTaskSchedulerManager.schedule()
        ChatBackgroundRefreshManager.schedule()
        BackgroundCacheRefreshManager.schedule()
      }
      
      return true
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

    override func buildMenu(with builder: UIMenuBuilder) {
      super.buildMenu(with: builder)
      guard builder.system == .main else { return }

      #if targetEnvironment(macCatalyst)
      // Tab switching: Cmd-1 through Cmd-5
      let tabCommands = (1...5).map { index in
        UIKeyCommand(
          title: ["Home", "Search", "Notifications", "Profile", "Messages"][index - 1],
          action: #selector(handleTabShortcut(_:)),
          input: "\(index)",
          modifierFlags: .command,
          propertyList: index
        )
      }
      let tabMenu = UIMenu(title: "Tabs", options: .displayInline, children: tabCommands)
      builder.insertChild(tabMenu, atStartOfMenu: .view)

      let refreshCommand = UIKeyCommand(
        title: "Refresh",
        action: #selector(handleRefreshShortcut),
        input: "r",
        modifierFlags: .command
      )

      let composeCommand = UIKeyCommand(
        title: "New Post",
        action: #selector(handleComposeShortcut),
        input: "n",
        modifierFlags: .command
      )

      let settingsCommand = UIKeyCommand(
        title: "Settings\u{2026}",
        action: #selector(handleSettingsShortcut),
        input: ",",
        modifierFlags: .command
      )

      let actionMenu = UIMenu(title: "", options: .displayInline, children: [refreshCommand, composeCommand, settingsCommand])
      builder.insertChild(actionMenu, atEndOfMenu: .file)
      #endif
    }

    #if targetEnvironment(macCatalyst)
    @objc func handleTabShortcut(_ sender: UIKeyCommand) {
      guard let index = sender.propertyList as? Int else { return }
      CatalystSceneDelegate.activeCoordinator?.onTabSelected?(index - 1)
    }

    @objc func handleRefreshShortcut() {
      CatalystSceneDelegate.activeCoordinator?.onRefreshTapped?()
    }

    @objc func handleComposeShortcut() {
      let coordinator = CatalystSceneDelegate.activeCoordinator
      if coordinator?.currentTab == 4 {
        coordinator?.onNewMessageTapped?()
      } else {
        coordinator?.onComposeTapped?()
      }
    }

    @objc func handleSettingsShortcut() {
      CatalystSceneDelegate.activeCoordinator?.onSettingsTapped?()
    }
    #endif

    func application(
      _ application: UIApplication,
      configurationForConnecting connectingSceneSession: UISceneSession,
      options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
      let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
      #if targetEnvironment(macCatalyst)
      config.delegateClass = CatalystSceneDelegate.self
      #endif
      return config
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
    if !shouldDeferSupportTipStartupForLocalTesting {
      SupportTipStore.shared.start()
    }
    if isPresentationUIFixture { return }
    // One-time removal of MLS chat data left by TestFlight builds. Nothing in Lite
    // reads those paths, so it runs off the main thread without ordering constraints.
    Task.detached(priority: .utility) {
      LegacyMLSDataPurge.runOnceIfNeeded()
    }
    // Resolve routing first: in DEBUG this installs an explicitly configured runtime fixture
    // transport before any client exists (and refuses to launch on an invalid config).
    _ = CatbirdGatewayConfiguration.current
    logger.info("🚀 CatbirdApp initializing")

    // Register blue.catbird.* / place.stream.* lexicon types with Petrel's decoder registry
    // before any responses containing custom types are decoded.
    PetrelCatbirdLexicons.register()


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
    if #available(iOS 26.0, macOS 26.0, *) {
      Task(priority: .background) {
        await TopicSummaryService.shared.prepareModelWarmupIfNeeded()
      }
    }
    #endif

  }

  // MARK: - Schema Version Management

  /// Current schema version - increment this when making breaking schema changes
  /// This forces a database reset for users with older incompatible schemas
  private static let currentSchemaVersion = 4  // Increment only for a truly incompatible store schema

  /// Checks if database needs reset due to schema version mismatch
  private func shouldResetDatabase() -> Bool {
    let savedVersion = UserDefaults.standard.integer(forKey: "CatbirdSchemaVersion")
    return savedVersion != 0 && savedVersion < Self.currentSchemaVersion
  }

  /// Saves current schema version after successful initialization
  private func saveSchemaVersion() {
    UserDefaults.standard.set(Self.currentSchemaVersion, forKey: "CatbirdSchemaVersion")
  }

  // MARK: - SwiftData Store Configuration

  /// App group identifier for shared storage (used by the NSE and widgets, NOT SwiftData)
  private static let appGroupIdentifier = "group.blue.catbird.shared"

  /// SwiftData store in the app's PRIVATE Application Support directory.
  /// NOT in App Group — SwiftData uses NSFileCoordinator internally when in App Group,
  /// which holds system-level file coordination locks that trigger 0xdead10cc on suspension.
  /// No extensions (NSE, widgets) need SwiftData access.
  private static var swiftDataStoreDirectory: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("swiftdata", isDirectory: true)
  }

  private static var swiftDataStoreURL: URL? {
    swiftDataStoreDirectory?.appendingPathComponent("Catbird.store")
  }

  /// Old App Group location — used for one-time migration and cleanup only
  private static var legacyAppGroupSwiftDataDirectory: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
      .appendingPathComponent("swiftdata", isDirectory: true)
  }

  /// Moves SwiftData files from the old App Group location to private Application Support.
  /// Runs once — skips if already migrated or if no old files exist.
  private static func migrateSwiftDataFromAppGroup() {
    let migrationKey = "SwiftDataMigratedFromAppGroup"
    guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

    let fm = FileManager.default
    guard let oldDir = legacyAppGroupSwiftDataDirectory,
          let newDir = swiftDataStoreDirectory else {
      UserDefaults.standard.set(true, forKey: migrationKey)
      return
    }

    // If old directory doesn't exist or is empty, nothing to migrate
    guard fm.fileExists(atPath: oldDir.path),
          let contents = try? fm.contentsOfDirectory(atPath: oldDir.path),
          !contents.isEmpty else {
      UserDefaults.standard.set(true, forKey: migrationKey)
      return
    }

    // Ensure new directory exists
    try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)

    // Move all SwiftData files (main db, WAL, SHM)
    for fileName in contents {
      let oldFile = oldDir.appendingPathComponent(fileName)
      let newFile = newDir.appendingPathComponent(fileName)

      // Don't overwrite if new location already has data
      if fm.fileExists(atPath: newFile.path) { continue }

      do {
        try fm.moveItem(at: oldFile, to: newFile)
        logger.info("📦 Migrated SwiftData file: \(fileName)")
      } catch {
        logger.warning("⚠️ Failed to migrate \(fileName): \(error.localizedDescription)")
      }
    }

    // Clean up old directory
    try? fm.removeItem(at: oldDir)

    UserDefaults.standard.set(true, forKey: migrationKey)
    logger.info("✅ SwiftData migrated from App Group to private container")
  }

  /// Crash loop detection keys
  private static let launchAttemptCountKey = "CatbirdLaunchAttemptCount"
  private static let lastLaunchTimeKey = "CatbirdLastLaunchTime"
  private static let crashLoopThreshold = 3
  private static let crashLoopWindowSeconds: TimeInterval = 60  // 3 crashes in 60 seconds
  private static let safeModeReason = "Catbird had trouble opening its local data, so changes you make now won’t be saved after you close the app."

  // MARK: - ModelContainer Async Initialization

  @MainActor
  private func initializeModelContainer() async {
    logger.info("📦 Starting async ModelContainer initialization")

    // ═══════════════════════════════════════════════════════════════════════════
    // ONE-TIME MIGRATION: Move SwiftData from App Group to private container
    // App Group + SwiftData = NSFileCoordinator during autosave = 0xdead10cc
    // ═══════════════════════════════════════════════════════════════════════════
    Self.migrateSwiftDataFromAppGroup()

    // ═══════════════════════════════════════════════════════════════════════════
    // CRASH LOOP DETECTION
    // ═══════════════════════════════════════════════════════════════════════════
    let crashLoopDetected = detectCrashLoop()
    if crashLoopDetected {
      logger.error("🔄 CRASH LOOP DETECTED - forcing safe mode recovery")
      // Jump straight to in-memory fallback
      if let container = try? makeInMemoryContainer() {
        appStateManager.modelContainerState = .degraded(container, reason: Self.safeModeReason)
        // Reset crash counter after successful safe mode entry
        resetCrashLoopCounter()
        return
      }
    }

    // Check for schema version mismatch and proactively reset if needed
    if shouldResetDatabase() {
      logger.warning("⚠️ Schema version mismatch detected, resetting database for clean migration")
      quarantineSwiftDataStore(reason: "schema_mismatch")
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // RECOVERY LADDER: Attempt A - Normal initialization
    // ═══════════════════════════════════════════════════════════════════════════
    do {
      let container = try makeContainer()
      saveSchemaVersion()
      appStateManager.modelContainerState = .ready(container)
      // Mark successful launch (resets crash counter after 30s stability)
      scheduleStableLaunchMarker()
      logger.info("✅ ModelContainer initialized successfully")
      return
    } catch {
      logger.error("❌ Attempt A (normal init) failed: \(Self.formatDatabaseError(error))")
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // RECOVERY LADDER: Attempt B - Delete WAL/SHM sidecars only, retry
    // A surprising number of "corruption" reports are just poisoned WAL files
    // ═══════════════════════════════════════════════════════════════════════════
    do {
      logger.warning("🔧 Attempt B: Deleting WAL/SHM sidecars and retrying...")
      deleteSwiftDataSidecarsOnly()
      let container = try makeContainer()
      saveSchemaVersion()
      appStateManager.modelContainerState = .ready(container)
      scheduleStableLaunchMarker()
      logger.warning("✅ Recovered by deleting WAL/SHM sidecars")
      return
    } catch {
      logger.error("❌ Attempt B (sidecar recovery) failed: \(Self.formatDatabaseError(error))")
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // RECOVERY LADDER: Attempt C - Quarantine store and create fresh
    // Move files to timestamped folder for potential diagnostics
    // ═══════════════════════════════════════════════════════════════════════════
    do {
      logger.warning("🔧 Attempt C: Quarantining store and creating fresh database...")
      quarantineSwiftDataStore(reason: "corruption_recovery")
      let container = try makeContainer()
      saveSchemaVersion()
      appStateManager.modelContainerState = .ready(container)
      scheduleStableLaunchMarker()
      logger.warning("✅ Recovered by quarantining store and recreating")
      return
    } catch {
      logger.error("❌ Attempt C (quarantine recovery) failed: \(Self.formatDatabaseError(error))")
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // RECOVERY LADDER: Attempt D - In-memory fallback (LAST RESORT)
    // ═══════════════════════════════════════════════════════════════════════════
    do {
      logger.error("⚠️ Attempt D: Falling back to in-memory storage...")
      let container = try makeInMemoryContainer()
      appStateManager.modelContainerState = .degraded(container, reason: Self.safeModeReason)
      resetCrashLoopCounter()  // Prevent crash loop on next launch
      logger.error("⚠️ Running in DEGRADED MODE - data will not persist across restarts")
      return
    } catch {
      logger.error("❌ Attempt D (in-memory fallback) failed: \(Self.formatDatabaseError(error))")
      appStateManager.modelContainerState = .failed(error)
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

  // MARK: - Database Recovery Helpers

  /// Creates a ModelContainer with explicit store URL in private Application Support
  private func makeContainer() throws -> ModelContainer {
    // Ensure the swiftdata directory exists
    if let storeDir = Self.swiftDataStoreDirectory {
      try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
    }

    // Use explicit URL if available, otherwise fall back to default
    let config: ModelConfiguration
    if let storeURL = Self.swiftDataStoreURL {
      config = ModelConfiguration(
        "Catbird",
        url: storeURL,
        cloudKitDatabase: .none
      )
      logger.debug("📍 Using explicit store URL: \(storeURL.path)")
    } else {
      // Fallback to default location if app group is unavailable
      config = ModelConfiguration(cloudKitDatabase: .none)
      logger.warning("⚠️ App group unavailable, using default store location")
    }

    return try CatbirdSwiftDataStore.makeContainer(configuration: config)
  }

  /// Creates an in-memory ModelContainer for degraded mode
  private func makeInMemoryContainer() throws -> ModelContainer {
    let config = ModelConfiguration("Catbird-InMemory", isStoredInMemoryOnly: true)
    return try ModelContainer(
      for: CachedFeedViewPost.self, PersistedScrollPosition.self, PersistedFeedState.self,
      FeedContinuityInfo.self, Preferences.self, AppSettingsModel.self, DraftPost.self,
      BackupRecord.self, BackupConfiguration.self, RepositoryRecord.self,
      ParsedATProtocolRecord.self, ParsedPost.self, ParsedProfile.self,
      ParsedMedia.self, ParsedConnection.self, ParsedUnknownRecord.self,
      configurations: config
    )
  }

  /// Deletes only WAL and SHM sidecar files, preserving the main database
  /// Often fixes corruption caused by interrupted writes during backgrounding
  private func deleteSwiftDataSidecarsOnly() {
    let fileManager = FileManager.default
    let sidecars = ["-wal", "-shm"]

    // Delete from explicit store location
    if let storeURL = Self.swiftDataStoreURL {
      for suffix in sidecars {
        let sidecarURL = URL(fileURLWithPath: storeURL.path + suffix)
        if fileManager.fileExists(atPath: sidecarURL.path) {
          do {
            try fileManager.removeItem(at: sidecarURL)
            logger.info("🔄 Removed sidecar: \(sidecarURL.lastPathComponent)")
          } catch {
            logger.warning("⚠️ Failed to remove sidecar \(sidecarURL.lastPathComponent): \(error.localizedDescription)")
          }
        }
      }
    }

    // Also clean up legacy locations
    let legacyFiles = [
      "Catbird.store-wal", "Catbird.store-shm",
      "Catbird.sqlite-wal", "Catbird.sqlite-shm",
      "default.store-wal", "default.store-shm"
    ]
    for directory in Self.allDatabaseDirectories() {
      for fileName in legacyFiles {
        let fileURL = directory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: fileURL.path) {
          try? fileManager.removeItem(at: fileURL)
          logger.debug("🔄 Removed legacy sidecar: \(fileName)")
        }
      }
    }
  }

  /// Moves the SwiftData store to a quarantine folder for potential diagnostics
  /// Creates a timestamped backup that can be used for debugging or data recovery
  private func quarantineSwiftDataStore(reason: String) {
    let fileManager = FileManager.default
    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
    let timestamp = dateFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")

    guard let storeDir = Self.swiftDataStoreDirectory else {
      logger.warning("⚠️ Cannot quarantine - store directory unavailable")
      // Fall back to deleting all database files
      Self.resetAllDatabaseFiles()
      return
    }

    let quarantineDir = storeDir.deletingLastPathComponent()
      .appendingPathComponent("quarantine/\(timestamp)_\(reason)", isDirectory: true)

    do {
      try fileManager.createDirectory(at: quarantineDir, withIntermediateDirectories: true)

      // Move all store files to quarantine
      let storeFiles = ["Catbird.store", "Catbird.store-wal", "Catbird.store-shm"]
      for fileName in storeFiles {
        let sourceURL = storeDir.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: sourceURL.path) {
          let destURL = quarantineDir.appendingPathComponent(fileName)
          try fileManager.moveItem(at: sourceURL, to: destURL)
          logger.info("📦 Quarantined: \(fileName) → \(quarantineDir.lastPathComponent)/")
        }
      }

      // Write metadata file for debugging
      let metadata: [String: Any] = [
        "quarantine_reason": reason,
        "timestamp": Date().timeIntervalSince1970,
        "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
        "schema_version": Self.currentSchemaVersion
      ]
      if let metadataData = try? JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted) {
        try metadataData.write(to: quarantineDir.appendingPathComponent("metadata.json"))
      }

      logger.info("✅ Database quarantined to: \(quarantineDir.path)")
    } catch {
      logger.error("❌ Quarantine failed: \(error.localizedDescription) - falling back to delete")
      Self.resetAllDatabaseFiles()
    }
  }

  /// Deletes all SwiftData database files from all possible locations
  /// Called by ErrorRecoveryView's Reset button - works WITHOUT ModelContainer
  static func resetAllDatabaseFiles() {
    let resetLogger = Logger(subsystem: "blue.catbird", category: "DatabaseRecovery")
    resetLogger.warning("🗑️ RESET: Deleting all SwiftData files")

    let fileManager = FileManager.default
    let allFiles = [
      "Catbird.store", "Catbird.store-wal", "Catbird.store-shm",
      "Catbird.sqlite", "Catbird.sqlite-wal", "Catbird.sqlite-shm",
      "default.store", "default.store-wal", "default.store-shm"
    ]

    // Delete from all possible locations
    for directory in allDatabaseDirectories() {
      for fileName in allFiles {
        let fileURL = directory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: fileURL.path) {
          do {
            try fileManager.removeItem(at: fileURL)
            resetLogger.info("🗑️ Deleted: \(fileURL.path)")
          } catch {
            resetLogger.warning("⚠️ Failed to delete \(fileName): \(error.localizedDescription)")
          }
        }
      }
    }

    // Delete the current swiftdata directory
    if let storeDir = swiftDataStoreDirectory, fileManager.fileExists(atPath: storeDir.path) {
      try? fileManager.removeItem(at: storeDir)
      resetLogger.info("🗑️ Deleted swiftdata directory (private container)")
    }

    // Delete legacy App Group swiftdata directory if it still exists
    if let legacyDir = legacyAppGroupSwiftDataDirectory, fileManager.fileExists(atPath: legacyDir.path) {
      try? fileManager.removeItem(at: legacyDir)
      resetLogger.info("🗑️ Deleted legacy swiftdata directory (App Group)")
    }

    // Reset schema version to force fresh init
    UserDefaults.standard.removeObject(forKey: "CatbirdSchemaVersion")

    // Reset crash loop counter
    UserDefaults.standard.removeObject(forKey: launchAttemptCountKey)
    UserDefaults.standard.removeObject(forKey: lastLaunchTimeKey)

    resetLogger.info("✅ Database reset complete")
  }

  /// Returns all directories where database files might exist
  private static func allDatabaseDirectories() -> [URL] {
    var directories: [URL] = []

    // Current private container swiftdata directory
    if let storeDir = swiftDataStoreDirectory {
      directories.append(storeDir)
    }

    // Legacy App Group swiftdata directory (pre-migration)
    if let legacyDir = legacyAppGroupSwiftDataDirectory {
      directories.append(legacyDir)
    }

    // App group root (for any stray files)
    if let appGroup = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
      directories.append(appGroup)
      directories.append(appGroup.appendingPathComponent("Library/Application Support"))
    }

    // Documents directory
    if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
      directories.append(docs)
    }

    // Application Support
    if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      directories.append(appSupport)
    }

    return directories
  }

  // MARK: - Crash Loop Detection

  /// Detects if the app is in a crash loop (multiple launches in quick succession)
  private func detectCrashLoop() -> Bool {
    let defaults = UserDefaults.standard
    let now = Date().timeIntervalSince1970
    let lastLaunch = defaults.double(forKey: Self.lastLaunchTimeKey)
    let attemptCount = defaults.integer(forKey: Self.launchAttemptCountKey)

    // Check if we're within the crash window
    if now - lastLaunch < Self.crashLoopWindowSeconds {
      let newCount = attemptCount + 1
      defaults.set(newCount, forKey: Self.launchAttemptCountKey)
      defaults.set(now, forKey: Self.lastLaunchTimeKey)

      if newCount >= Self.crashLoopThreshold {
        logger.error("🔄 Crash loop detected: \(newCount) launches in \(Int(now - lastLaunch))s")
        return true
      }
    } else {
      // Reset counter - we're outside the crash window
      defaults.set(1, forKey: Self.launchAttemptCountKey)
      defaults.set(now, forKey: Self.lastLaunchTimeKey)
    }

    return false
  }

  /// Resets the crash loop counter (called after successful recovery, and whenever the app
  /// reaches the background cleanly, so quick manual relaunches never count as crashes)
  private func resetCrashLoopCounter() {
    UserDefaults.standard.removeObject(forKey: Self.launchAttemptCountKey)
    UserDefaults.standard.removeObject(forKey: Self.lastLaunchTimeKey)
  }

  /// Schedules a task to mark the launch as stable after 30 seconds
  private func scheduleStableLaunchMarker() {
    Task {
      try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30 seconds
      await MainActor.run {
        resetCrashLoopCounter()
        logger.debug("✅ Launch marked as stable (30s elapsed)")
      }
    }
  }

  /// Formats database errors for better diagnostics
  private static func formatDatabaseError(_ error: Error) -> String {
    var details = error.localizedDescription

    if let nsError = error as NSError? {
      details += " [domain: \(nsError.domain), code: \(nsError.code)]"
      if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
        details += " underlying: \(underlying.localizedDescription)"
      }
    }

    return details
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


  #if os(macOS)
  // MARK: - macOS Window Scenes
  @SceneBuilder
  private var macOSWindowScenes: some Scene {
    WindowGroup(id: "compose") {
      CatbirdWindowRoot(
        appStateManager: appStateManager,
        onOpenURL: { url, scene in handleSceneURL(url, in: scene) },
        onAccountReady: { scene in routePendingLaunchURLIfNeeded(in: scene) }
      ) { scene in
        if case .authenticated(let appState) = appStateManager.lifecycle,
           let context = scene.context, !context.isInvalidated,
           context.accountDID == appState.userDID {
          SceneNavigationHost(appState: appState, appStateManager: appStateManager, context: context) {
            PostComposerViewUIKit(
              appState: appState,
              editingSession: context.composerEditingSession
            )
              .frame(minWidth: 500, minHeight: 400)
          }
          .id(context.activityRegistrationID)
        }
      }
    }
    .defaultSize(width: 600, height: 500)

    Window("Settings", id: "settings") {
      CatbirdWindowRoot(
        appStateManager: appStateManager,
        onOpenURL: { url, scene in handleSceneURL(url, in: scene) },
        onAccountReady: { scene in routePendingLaunchURLIfNeeded(in: scene) }
      ) { scene in
        if case .authenticated(let appState) = appStateManager.lifecycle,
           let context = scene.context, !context.isInvalidated,
           context.accountDID == appState.userDID {
          SceneNavigationHost(appState: appState, appStateManager: appStateManager, context: context) {
            SettingsView()
          }
          .id(context.activityRegistrationID)
        }
      }
    }
    .defaultSize(width: 700, height: 500)
  }
  #endif

  @ViewBuilder
  private func applicationContent(in scene: SceneWindowState) -> some View {
    switch appStateManager.modelContainerState {
        case .loading:
          LoadingView()
            .task {
              await initializeModelContainer()
            }

        case .ready(let container):
          sceneRoot(in: scene)
            .onAppear {
              handleSceneAppear(container: container)
            }
            .environment(appStateManager)
            .modelContainer(container)
            .modifier(BiometricAuthModifier(performCheck: performInitialBiometricCheck))
            .task(priority: .high) {
              await initializeApplicationIfNeeded()
            }

        case .degraded(let container, let reason):
          // Running in safe mode with in-memory database
          VStack(spacing: 0) {
            DegradedModeBanner(reason: reason)
            sceneRoot(in: scene)
              .onAppear {
                handleSceneAppear(container: container)
              }
          }
          .environment(appStateManager)
          .modelContainer(container)
          .modifier(BiometricAuthModifier(performCheck: performInitialBiometricCheck))
          .task(priority: .high) {
            await initializeApplicationIfNeeded()
          }

        case .failed(let error):
          ErrorRecoveryView(error: error, retry: {
            Task {
              await initializeModelContainer()
            }
          })
    }
  }

  // MARK: - Body
  var body: some Scene {
    // Explicit id: SwiftUI otherwise derives the macOS state-restoration identifier from the
    // content's reflected type name, which embeds ASLR-dependent addresses for private types
    // ("(unknown context at $…)"). Saved state then never matches the next launch, AppKit
    // restores nothing, and the relaunched app has no window.
    WindowGroup(id: "main") {
      CatbirdWindowRoot(
        appStateManager: appStateManager,
        onOpenURL: { url, scene in handleSceneURL(url, in: scene) },
        onAccountReady: { scene in routePendingLaunchURLIfNeeded(in: scene) }
      ) { scene in
        Group {
          #if DEBUG
          if isMessageRequestsUIFixture {
            MessageRequestsUIFixture()
          } else if isVideoFeedUIFixture {
            VideoFeedUIFixture()
          } else if isSocialActionsUIFixture {
            SocialActionsUIFixture()
          } else if isInlineReplyUIFixture {
            #if os(iOS)
            InlineReplyValidationFixture()
            #else
            EmptyView()
            #endif
          } else if isMessagesViewportUIFixture {
            #if os(iOS)
            MessagesViewportValidationFixture()
            #else
            EmptyView()
            #endif
          } else if isSceneRuntimeUIFixture {
            #if os(iOS)
            SceneRuntimeFixture(scene: scene)
            #else
            EmptyView()
            #endif
          } else if isSettingsUIFixture {
            SettingsUIFixture()
          } else {
            applicationContent(in: scene)
          }
          #else
          applicationContent(in: scene)
          #endif
        }
        .catalystPlainButtons()
        #if DEBUG && os(iOS)
        .overlay {
          if ProcessInfo.processInfo.arguments.contains("--bluemoji-visual-test") {
            BluemojiVisualTestView()
          }
        }
        #endif
      }
    }
    .onChange(of: scenePhase, initial: true) { oldPhase, newPhase in
      guard !isPresentationUIFixture,
            SceneApplicationPhaseObservation.shared.accept(newPhase) else { return }
      handleScenePhaseChange(from: oldPhase, to: newPhase)
    }
    #if os(macOS)
    .windowStyle(.automatic)
    .windowToolbarStyle(.unified)
    .defaultSize(width: 1200, height: 800)
    .windowResizability(.contentMinSize)
    #endif

    #if os(macOS)
    macOSWindowScenes
    #endif
  }
}

private extension CatbirdApp {
  func handleSceneURL(_ url: URL, in scene: SceneWindowState) {
  guard !isPresentationUIFixture else { return }
  logger.info(
    "Received URL for scheme=\(url.scheme ?? "none", privacy: .public) host=\(url.host ?? "none", privacy: .public) path=\(url.path, privacy: .public)"
  )

  guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
    return
  }
  let scheme = (components.scheme ?? "").lowercased()
  let host = (components.host ?? "").lowercased()
  let path = components.path.lowercased()

  // Check for gateway BFF callback (Universal Link from catbird.blue)
  // Gateway redirects with a one-time exchange code in the query.
  if scheme == "https" && host == "catbird.blue" && path == "/oauth/callback" {
    logger.info("Gateway OAuth callback detected")
    Task {
      do {
        try await appStateManager.authentication.handleGatewayCallback(url)
        logger.info("Gateway OAuth callback handled successfully")
      } catch {
        logger.error("Error handling gateway callback: \(error)")
      }
    }
  } else if (scheme == "catbird" || scheme == "blue.catbird") && ((host == "oauth" && path == "/callback") || (host.isEmpty && path == "/oauth/callback") || (host == "oauth/callback" && path.isEmpty)) {
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
    logger.info("Widget notification deep link received")

    guard let context = scene.context, !context.isInvalidated,
          context.accountDID == self.appState?.userDID else {
      scene.retainLaunchURL(url)
      return
    }
    context.navigationManager.updateCurrentTab(2)
    context.navigationManager.tabSelection?(2)
  } else if (scheme == "blue.catbird" || scheme == "catbird") && Self.widgetRouteHosts.contains(host) {
    handleWidgetURL(url, components: components, host: host, in: scene)
  } else if (url.scheme == "blue.catbird" || url.scheme == "catbird") && (url.host == "e2e" || url.host == "test") {
    // Handle E2E testing commands (DEBUG builds, E2E mode only)
    #if DEBUG
    logger.error("[E2E-URL] Received E2E URL: \(url.absoluteString), isE2EMode: \(appStateManager.isE2EMode)")
    if appStateManager.isE2EMode {
      let receivingContext = scene.context
      Task { @MainActor in
        logger.error("[E2E-URL] Calling handleE2ECommand")
        await self.handleE2ECommand(url: url, sceneContext: receivingContext)
      }
    } else {
      logger.error("[E2E-URL] E2E URL received but not in E2E mode: \(url.absoluteString)")
    }
    #else
    logger.info("Ignoring test-harness URL in a release build")
    #endif
  } else if let intent = ExternalURLIntent.parse(from: url) {
    // Route bluesky://intent/* (compose prefill, verify-email) and group-chat join links through ExternalURLIntentPresenter
    logger.info("External URL intent parsed from URL: \(url.absoluteString, privacy: .private)")
    if let appState = self.appState, let context = scene.context,
         !context.isInvalidated, context.accountDID == appState.userDID {
      context.urlHandler.externalIntentPresenter.handleIntent(intent, from: url, appState: appState)
    } else {
      logger.info("AppState unavailable; retaining pending intent launch URL")
      scene.retainLaunchURL(url)
    }
  } else {
    // Handle all other URLs through the URLHandler
    if let appState = self.appState, let context = scene.context,
         !context.isInvalidated, context.accountDID == appState.userDID {
      _ = context.urlHandler.handle(url)
    } else {
      logger.info("AppState unavailable; retaining pending launch URL")
      scene.retainLaunchURL(url)
    }
  }
  }

  /// Hosts emitted by the Compose and Feed widgets (and post links from widget timelines).
  static let widgetRouteHosts: Set<String> = ["compose", "feed", "profile", "post"]

  /// Routes widget taps such as `blue.catbird://compose?account=<did>`, `blue.catbird://feed/timeline`,
  /// `blue.catbird://feed?url=<feed>`, `blue.catbird://profile/<handle>` and `blue.catbird://post?uri=<at-uri>`.
  /// Requests go through the scene route coordinator so they wait for an account switch to finish.
  func handleWidgetURL(_ url: URL, components: URLComponents, host: String, in scene: SceneWindowState) {
    guard let appState = self.appState else {
      scene.retainLaunchURL(url)
      return
    }
    let queryItems = components.queryItems ?? []
    let requestedDID = queryItems.first(where: { $0.name == "account" })?.value
    let targetDID = (requestedDID?.isEmpty == false ? requestedDID : nil) ?? appState.userDID

    let command: SceneRouteCommand
    var beforeDelivery: SceneRouteCoordinator.BeforeDelivery?
    switch host {
    case "compose":
      command = .showTab(0, resetPath: false)
      beforeDelivery = { context in
        context.presentPostComposer()
        return true
      }
    case "profile":
      let actor = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      guard !actor.isEmpty else {
        command = .showTab(0, resetPath: false)
        break
      }
      command = .navigate(.profile(actor), tabIndex: 0)
    case "post":
      guard let rawURI = queryItems.first(where: { $0.name == "uri" })?.value,
            let uri = try? ATProtocolURI(uriString: rawURI) else {
        command = .showTab(0, resetPath: false)
        break
      }
      command = .navigate(.post(uri), tabIndex: 0)
    default:
      // feed: a custom feed or list arrives as `?url=`; anything else opens the Home timeline.
      if let rawFeed = queryItems.first(where: { $0.name == "url" })?.value, !rawFeed.isEmpty {
        if let uri = try? ATProtocolURI(uriString: rawFeed) {
          command = .navigate(uri.collection == "app.bsky.graph.list" ? .listFeed(uri) : .feed(uri), tabIndex: 0)
        } else if let webURL = URL(string: rawFeed), URLSchemePolicy.isWeb(webURL) {
          command = .showTab(0, resetPath: false)
          beforeDelivery = { context in
            _ = context.urlHandler.handle(webURL, tabIndex: 0)
            return true
          }
        } else {
          command = .showTab(0, resetPath: true)
        }
      } else {
        command = .showTab(0, resetPath: true)
      }
    }

    SceneRouteCoordinator.shared.submit(
      SceneRouteRequest(accountDID: targetDID, command: command, preferredSceneID: scene.sceneID),
      beforeDelivery: beforeDelivery
    )

    // A widget configured for another signed-in account switches to it first; the request
    // above is delivered once this window shows that account.
    if targetDID != appState.userDID {
      Task { @MainActor in
        let outcome = await appStateManager.switchAccount(to: targetDID)
        if case .failed = outcome {
          logger.error("Widget deep link could not switch to the requested account")
        }
      }
    }
  }

  private var pendingAuthAlertBinding: Binding<AuthenticationManager.AuthAlert?> {
    Binding(
      get: { appStateManager.authentication.pendingAuthAlert },
      set: { _ in Task { await appStateManager.authentication.clearPendingAuthAlert() } }
    )
  }

  @ViewBuilder
  func sceneRoot(in scene: SceneWindowState) -> some View {
    @Bindable var scene = scene
    Group {
      switch appStateManager.lifecycle {
      case .launching:
        LoadingView()

      case .unauthenticated:
        LoginView()
          .environment(appStateManager)
          .sheet(item: $scene.unauthenticatedStarterPackItem, onDismiss: {
            if !appStateManager.lifecycle.isAuthenticated {
              scene.dismissStarterPackIfOwned()
            }
            scene.unauthenticatedStarterPackItem = nil
          }) { item in
            StarterPackLandingView(flowID: item.flowID, starterPackURI: item.uri) {
              if !appStateManager.lifecycle.isAuthenticated {
                scene.dismissStarterPackIfOwned()
              }
              scene.unauthenticatedStarterPackItem = nil
            }
            .environment(appStateManager)
          }
      case .authenticated(let appState):
        if shouldShowContentForAuthenticatedState,
           let context = scene.context, !context.isInvalidated,
           context.accountDID == appState.userDID {
          if CommunityStandards.shared.requiresAgreement(for: appState.userDID) {
            // One-time, per-account agreement before any posts are shown (App Review 1.2).
            CommunityStandardsAgreementView(appState: appState)
              .applyAppStateEnvironment(appState)
              .environment(appStateManager)
          } else {
            SceneNavigationHost(appState: appState, appStateManager: appStateManager, context: context) {
              ContentView()
            }
            .id(context.activityRegistrationID)
          }
        } else {
          LoadingView()  // For biometric check
        }

      case .deactivated(let appState):
        if let context = scene.context, !context.isInvalidated,
           context.accountDID == appState.userDID {
          SceneNavigationHost(appState: appState, appStateManager: appStateManager, context: context) {
            AccountDeactivatedView(appState: appState)
          }
          .id(context.activityRegistrationID)
        } else {
          LoadingView()
        }

      case .takendown(let appState):
        if let context = scene.context, !context.isInvalidated,
           context.accountDID == appState.userDID {
          SceneNavigationHost(appState: appState, appStateManager: appStateManager, context: context) {
            AccountTakedownView(appState: appState)
          }
          .id(context.activityRegistrationID)
        } else {
          LoadingView()
        }
      }
    }
    // Sign-out explanations are usually raised while moving to the sign-in screen,
    // so they're presented here, above every lifecycle state.
    .alert(item: pendingAuthAlertBinding) { alert in
      Alert(
        title: Text(alert.title),
        message: Text(alert.message),
        dismissButton: .default(Text("OK"), action: {
          Task { await appStateManager.authentication.clearPendingAuthAlert() }
        })
      )
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

    Task {
      await restoreApplicationState()
    }

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

#if os(iOS)
  /// Checks whether there are connected window scenes in the foreground (`.foregroundActive` or `.foregroundInactive`).
  /// In multi-window environments (iPadOS / macOS Catalyst), process-wide database connections
  /// and background suspension must only be initiated when all scenes are backgrounded (TN3187).
  private var hasOtherActiveScenes: Bool {
    UIApplication.shared.connectedScenes.contains { scene in
      scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive
    }
  }
#endif

  @MainActor
  func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
    guard !isPresentationUIFixture else { return }
    #if os(iOS)
    let otherScenesActive = hasOtherActiveScenes
    #else
    let otherScenesActive = false
    #endif
    let isLeavingForeground = (newPhase == .inactive || newPhase == .background)

    if otherScenesActive && isLeavingForeground {
      logger.info("Scene transitioned to \(String(describing: newPhase)), but other connected scenes remain active in foreground. Preserving process-wide database connections.")
    }

    #if os(iOS)
    // Keep execution time while feed state is saved and GRDB is suspended so no
    // SQLite file lock is held when RunningBoard suspends the process (0xdead10cc).
    var taskId: UIBackgroundTaskIdentifier = .invalid
    if isLeavingForeground && !otherScenesActive {
      taskId = UIApplication.shared.beginBackgroundTask(withName: "ScenePhaseTransition") {
        logger.warning("ScenePhaseTransition background time expired")
        if taskId != .invalid {
          UIApplication.shared.endBackgroundTask(taskId)
          taskId = .invalid
        }
      }
    }
    #endif

    // Suspend/resume GRDB early to avoid holding SQLite locks across suspension (0xdead10cc).
    // In multi-window environments, protect process-wide database connections if another scene is still active.
    let shouldSuspendGRDB = (newPhase != .active) && !otherScenesActive
    GRDBSuspensionCoordinator.setLifecycleSuspended(
      shouldSuspendGRDB,
      reason: "scenePhase \(String(describing: oldPhase)) → \(String(describing: newPhase))"
    )

    Task { @MainActor in
      #if os(iOS)
      // Ensure we release the background assertion when this update task completes
      defer {
        if taskId != .invalid {
          UIApplication.shared.endBackgroundTask(taskId)
          taskId = .invalid
        }
      }
      #endif


      if newPhase == .background {
        // Reaching the background cleanly means this launch didn't crash.
        resetCrashLoopCounter()
        saveApplicationState()
#if os(iOS)
        if !otherScenesActive {
          if #available(iOS 13.0, *) {
            ChatBackgroundRefreshManager.schedule()
            BackgroundCacheRefreshManager.schedule()
          }
          logger.info("Background work scheduled")
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

#if DEBUG
      try? Tips.resetDatastore()
#endif
      if UserDefaults.standard.bool(forKey: OnboardingManager.resetTipsOnNextLaunchKey) {
        UserDefaults.standard.removeObject(forKey: OnboardingManager.resetTipsOnNextLaunchKey)
        try? Tips.resetDatastore()
      }
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
      if #available(iOS 26.0, macOS 26.0, *) {
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

  private func routePendingLaunchURLIfNeeded(in scene: SceneWindowState) {
    guard case .authenticated(let appState) = appStateManager.lifecycle,
          let context = scene.context, !context.isInvalidated,
          context.accountDID == appState.userDID,
          let url = scene.pendingLaunchURL else { return }
    logger.info("Routing receiving-window launch URL after authentication: \(url.absoluteString, privacy: .private)")
    let starterPackFlowID = scene.starterPackFlowID
    scene.clearPendingLaunchURL()
    handleSceneURL(url, in: scene)
    // Only the window that owns this onboarding flow may finalize its pending context.
    if appState.onboardingManager.hasCompletedWelcome(for: appState.userDID),
       let pending = StarterPackOnboardingManager.shared.pendingContext,
       pending.flowID == starterPackFlowID,
       let client = appState.atProtoClient {
      Task {
        _ = try? await StarterPackOnboardingManager.shared.finalizeStarterPackOnboarding(
          client: client,
          appState: appState,
          context: pending
        )
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

        Text("Loading…")
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

    @State private var showResetConfirmation = false
    @State private var isResetting = false

    var body: some View {
      VStack(spacing: 24) {
        // Error icon
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 60))
          .foregroundStyle(.red, .red.opacity(0.2))

        // Title
        Text("Catbird Couldn’t Open")
          .font(.title)
          .fontWeight(.bold)

        // Error details (expandable)
        VStack(alignment: .leading, spacing: 8) {
          Text("Catbird couldn’t open the data it keeps on this device.")
            .font(.body)
            .foregroundColor(.secondary)

          // Technical details
          DisclosureGroup("Technical Details") {
            Text(formatErrorDetails(error))
              .font(.caption)
              .foregroundColor(.secondary)
              .textSelection(.enabled)
              .padding(.top, 4)
          }
          .font(.subheadline)
          .foregroundColor(.secondary)
        }
        .padding(.horizontal, 32)

        Spacer().frame(height: 20)

        // Primary action - Try Again
        Button(action: retry) {
          HStack {
            Image(systemName: "arrow.clockwise")
            Text("Try Again")
          }
          .font(.headline)
          .foregroundColor(.white)
          .frame(maxWidth: .infinity)
          .padding()
          .background(Color.blue)
          .cornerRadius(12)
        }
        .padding(.horizontal, 32)

        // Secondary action - Reset Database (Recommended)
        Button {
          showResetConfirmation = true
        } label: {
          HStack {
            Image(systemName: "trash")
            Text("Reset Local Data")
            Text("(Recommended)")
              .font(.caption)
              .foregroundColor(.orange)
          }
          .font(.headline)
          .foregroundColor(.orange)
          .frame(maxWidth: .infinity)
          .padding()
          .background(Color.orange.opacity(0.15))
          .cornerRadius(12)
        }
        .padding(.horizontal, 32)
        .disabled(isResetting)

        // Help text
        Text("Resetting clears cached data. Your account and posts are stored on the server and will not be affected.")
          .font(.caption)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 32)

        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.systemBackground)
      .confirmationDialog(
        "Reset Local Data?",
        isPresented: $showResetConfirmation,
        titleVisibility: .visible
      ) {
        Button("Reset and Restart", role: .destructive) {
          performReset()
        }
        Button("Cancel", role: .cancel) { }
      } message: {
        Text("This will delete all cached data including drafts. Your account, posts, and followers are stored on the server and will not be affected.")
      }
      .overlay {
        if isResetting {
          ZStack {
            Color.black.opacity(0.5)
            VStack(spacing: 16) {
              ProgressView()
                .scaleEffect(1.5)
              Text("Resetting…")
                .font(.headline)
                .foregroundColor(.white)
            }
            .padding(32)
            #if os(iOS)
            .background(Color(.systemGray6))
            #else
            .background(Color(.controlBackgroundColor))
            #endif
            .cornerRadius(16)
          }
          .ignoresSafeArea()
        }
      }
    }

    private func formatErrorDetails(_ error: Error) -> String {
      var details = [error.localizedDescription]

      if let nsError = error as NSError? {
        details.append("Domain: \(nsError.domain)")
        details.append("Code: \(nsError.code)")

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
          details.append("Underlying: \(underlying.localizedDescription)")
        }

        // Include any file paths mentioned
        for (key, value) in nsError.userInfo {
          if let stringValue = value as? String, stringValue.contains("/") {
            details.append("\(key): ....\(stringValue.suffix(50))")
          }
        }
      }

      return details.joined(separator: "\n")
    }

    private func performReset() {
      isResetting = true

      // CRITICAL: This works WITHOUT ModelContainer
      // Direct file-level operations that can run even when SwiftData fails
      CatbirdApp.resetAllDatabaseFiles()

      // Give the UI a moment to show the progress indicator
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        isResetting = false
        // Trigger retry which will reinitialize with clean database
        retry()
      }
    }
  }

  /// Degraded mode banner shown when running in-memory
  struct DegradedModeBanner: View {
    let reason: String
    @State private var isExpanded = false

    var body: some View {
      VStack(spacing: 0) {
        Button {
          withAnimation(.easeInOut(duration: 0.2)) {
            isExpanded.toggle()
          }
        } label: {
          HStack {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundColor(.orange)
            Text("Safe Mode")
              .fontWeight(.semibold)
            Spacer()
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
              .font(.caption)
          }
          .foregroundColor(.primary)
          .padding(.horizontal)
          .padding(.vertical, 10)
          .background(Color.orange.opacity(0.15))
        }

        if isExpanded {
          VStack(alignment: .leading, spacing: 8) {
            Text(reason)
              .font(.caption)
              .foregroundColor(.secondary)

            Button {
              CatbirdApp.resetAllDatabaseFiles()
              // Force app restart by setting state to loading
              AppStateManager.shared.modelContainerState = .loading
            } label: {
              Text("Reset Local Data")
                .font(.caption)
                .fontWeight(.medium)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
          }
          .padding()
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.orange.opacity(0.08))
        }
      }
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

#if DEBUG
  // MARK: - E2E Testing URL Handlers

  /// Handle E2E testing URL commands (DEBUG builds only, and only in `--e2e-mode`).
  /// Format: blue.catbird://e2e/{command}?{params}
  /// Commands:
  /// - login?handle=...&password=... - Password login for a test account
  /// - login-fixture - Password login from the sandboxed fixture file
  /// - request-notification-permission - Request push notification authorization
  func handleE2ECommand(url: URL, sceneContext: SceneNavigationContext?) async {
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
    let skipProactiveRefresh = CatbirdGatewayConfiguration.current.isRuntimeFixture
    if !skipProactiveRefresh, let appState = manager.lifecycle.appState, command != "request-notification-permission" {
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

    case "login-fixture":
      await handleLoginFixture(manager: manager, logger: e2eLogger)

    case "request-notification-permission":
      do {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await writeE2EResult(command: "request-notification-permission", success: true, data: ["granted": String(granted)])
      } catch {
        await writeE2EResult(command: "request-notification-permission", success: false, error: error.localizedDescription)
      }

    default:
      e2eLogger.warning("[E2E] Unknown command: \(command)")
      await writeE2EResult(command: command, success: false, error: "Unknown command")
    }
  }
  /// Dedicated simulator fixture input. Credentials never travel in a URL,
  /// process argument, or result file; consume the fixed sandbox file once.
  private func handleLoginFixture(manager: AppStateManager, logger e2eLogger: Logger) async {
    guard manager.isE2EMode,
          let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
      await writeE2EResult(command: "login-fixture", success: false, error: "E2E mode required")
      return
    }
    let fixture = documents.appendingPathComponent("e2e-login-fixture.json")
    do {
      let data = try Data(contentsOf: fixture)
      // Remove before decoding or awaiting authentication so malformed input
      // and interrupted logins cannot leave credentials behind on disk.
      try FileManager.default.removeItem(at: fixture)
      let params = try JSONDecoder().decode([String: String].self, from: data)
      guard params["handle"] != nil, params["password"] != nil else {
        await writeE2EResult(command: "login-fixture", success: false, error: "Incomplete login fixture")
        return
      }
      await handleLogin(params: params, manager: manager, logger: e2eLogger)
    } catch {
      await writeE2EResult(command: "login-fixture", success: false, error: "Could not consume login fixture")
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

  /// Write E2E command result to a file the harness can read
  private func writeE2EResult(command: String, success: Bool, error: String? = nil, data: [String: String]? = nil) async {
    let e2eLogger = Logger(subsystem: "blue.catbird.e2e", category: "Results")
    
    // Debug runtime fixtures write results beside their isolated profile, never into the user's App Group.
    #if DEBUG && os(macOS)
    let fixtureContainer = DebugGatewayTransport.shared.activeConfig.map {
      URL(fileURLWithPath: $0.profilePath, isDirectory: true)
    }
    #else
    let fixtureContainer: URL? = nil
    #endif
    guard let containerURL = fixtureContainer
      ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.blue.catbird.shared") else {
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
        
        Text("Unlock to continue")
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
    logger.info("User tapped notification")

    // Forward to NotificationManager for navigation handling if available
    if let appState = AppStateManager.shared.lifecycle.appState {
      appState.notificationManager.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
      return
    }

    completionHandler()
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // Forward to NotificationManager for rich content if available
    if let appState = AppStateManager.shared.lifecycle.appState {
      appState.notificationManager.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
      return
    }

    // Fallback: Show standard notifications normally
    completionHandler([.banner, .sound, .badge])
  }
}
#endif
