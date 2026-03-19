import AVFoundation
import CryptoKit
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

      // Check if this is an MLS key package inventory notification
      if let type = userInfo["type"] as? String,
         type == "keyPackageLowInventory" || type == "keyPackageReplenishRequested"
      {
        logger.info("Processing MLS key package notification (\(type))")

        guard application.applicationState == .active else {
          logger.info(
            "Deferring key package replenishment while app state=\(application.applicationState.rawValue)"
          )
          if #available(iOS 13.0, *) {
            Task {
              await MLSBackgroundRefreshManager.shared.scheduleBackgroundRefresh(delay: 5 * 60)
            }
          }
          completionHandler(.noData)
          return
        }

        Task { @MainActor in
          guard let activeState = AppStateManager.shared.lifecycle.appState else {
            logger.warning("AppState not available for MLS notification handling")
            completionHandler(.noData)
            return
          }
          await MLSNotificationHandler.shared.handleNotification(
            userInfo: userInfo,
            appState: activeState
          )
          completionHandler(.newData)
        }
      } else if let convoId = userInfo["convoId"] as? String ?? userInfo["conversationId"] as? String {
        logger.info("Processing MLS chat notification for conversation: \(convoId)")
        
        guard application.applicationState == .active else {
          logger.info(
            "Deferring MLS catchup while app state=\(application.applicationState.rawValue) to avoid app/NSE races"
          )
          completionHandler(.noData)
          return
        }
        
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

    // Signal-style: TRUNCATE checkpoint at launch to clear any leftover WAL from previous session.
    // If the previous session was terminated before budget checkpoints ran, WAL could be large.
    // This is cheap (no-op if WAL is already empty) and prevents stale WAL accumulation.
    if !ProcessInfo.processInfo.isLowPowerModeEnabled {
      MLSGRDBManager.syncTruncatingCheckpointAtLaunch()
    }

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
  private static let currentSchemaVersion = 3  // Increment when schema changes break migration

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

  /// App group identifier for shared storage (used by MLS databases and NSE, NOT SwiftData)
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
        appStateManager.modelContainerState = .degraded(container, reason: "Crash loop detected - running in safe mode")
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
      appStateManager.modelContainerState = .degraded(container, reason: "Database recovery failed - running in safe mode. Data will not persist.")
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

    return try ModelContainer(
      for: CachedFeedViewPost.self, PersistedScrollPosition.self, PersistedFeedState.self,
      FeedContinuityInfo.self, Preferences.self, AppSettingsModel.self, DraftPost.self,
      BackupRecord.self, BackupConfiguration.self, RepositoryRecord.self,
      ParsedATProtocolRecord.self, ParsedPost.self, ParsedProfile.self,
      ParsedMedia.self, ParsedConnection.self, ParsedUnknownRecord.self,
      configurations: config
    )
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

  /// Resets the crash loop counter (called after successful recovery)
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

        case .degraded(let container, let reason):
          // Running in safe mode with in-memory database
          VStack(spacing: 0) {
            DegradedModeBanner(reason: reason)
            sceneRoot()
              .onAppear {
                handleSceneAppear(container: container)
              }
          }
          .environment(appStateManager)
          .modelContainer(container)
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
    MLSSuspensionFlightRecorder.shared.record(
      .scenePhaseChange,
      details: "\(String(describing: oldPhase)) → \(String(describing: newPhase))",
      process: "app"
    )
    // ═══════════════════════════════════════════════════════════════════════════
    // CRITICAL FIX (0xdead10cc): Cancel MLS tasks BEFORE GRDB suspension
    // ═══════════════════════════════════════════════════════════════════════════
    // MLS initialization tasks (missingConversationsTask, groupInfoRefreshTask, etc.)
    // continue running with open database connections when the user backgrounds the app.
    // These tasks hold SQLite/SQLCipher file locks, which causes iOS to kill the app
    // with 0xdead10cc (file locks held during suspension).
    //
    // We must cancel these tasks SYNCHRONOUSLY before GRDBSuspensionCoordinator starts
    // rejecting database operations, so they stop cleanly rather than crashing.
    // Using MainActor.assumeIsolated because onChange runs on main thread.
    // ═══════════════════════════════════════════════════════════════════════════
    if newPhase == .inactive || newPhase == .background {
      if let appState = appStateManager.lifecycle.appState {
        // SYNCHRONOUS cancellation - must happen before GRDB suspension
        MainActor.assumeIsolated {
          appState.mlsConversationManager?.suspendMLSOperations()
        }
      }

      // Block new MLS FFI work immediately while we transition to background.
      // (MLSClient + MLSCoreContext each maintain their own UniFFI MlsContext caches.)
      MLSClient.markSuspensionInProgress(reason: "scenePhase → \(String(describing: newPhase))")
      MLSCoreContext.markSuspensionInProgress()
    }

    // Suspend/resume GRDB early to avoid holding SQLite/SQLCipher locks across suspension (0xdead10cc).
    GRDBSuspensionCoordinator.setLifecycleSuspended(
      newPhase != .active,
      reason: "scenePhase \(String(describing: oldPhase)) → \(String(describing: newPhase))"
    )

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
        MLSNotificationCoordinator.setMainAppActive(
          newPhase == .active,
          activeUserDID: appState.userDID
        )
      } else {
        MLSNotificationCoordinator.setMainAppActive(newPhase == .active, activeUserDID: nil)
      }

      // ═══════════════════════════════════════════════════════════════════════════
      // 0xdead10cc FIX: Close Rust FFI connections on background within RAII task.
      // GRDB handles its own suspension via observesSuspensionNotifications.
      // SwiftData autosave handles persistence. Only Rust FFI needs explicit close
      // because it holds WAL locks in the App Group container with no suspension mechanism.
      // ═══════════════════════════════════════════════════════════════════════════
      if oldPhase == .active, (newPhase == .inactive || newPhase == .background) {
        // RAII background task protects the Rust close operation
        let bgTask = CatbirdBackgroundTask(name: "MLSSuspensionClose")
        // Close Rust FFI connections (MLSClient + MLSCoreContext) — releases WAL locks in App Group
        MLSClient.emergencyCloseAllContexts(reason: "scenePhase active→\(String(describing: newPhase))")
        MLSCoreContext.emergencyCloseAllContexts()
        bgTask.end()
        logger.info("✅ [0xdead10cc-FIX] Rust FFI contexts closed for suspension")
      }

      // Reload MLS state from disk when returning to foreground.
      // The NSE may have advanced the MLS ratchet while the app was in background.
      if (oldPhase == .background || oldPhase == .inactive), newPhase == .active {
        // CRITICAL: Clear suspension flag FIRST so getContext() works
        MLSCoreContext.clearSuspensionFlag()
        MLSClient.clearSuspensionFlag(reason: "scenePhase → active")

        // Resume GRDB and coordination
        MLSDatabaseCoordinator.shared.resumeFromSuspension()

        if let appState = appStateManager.lifecycle.appState {
          // Creates fresh Rust connections on demand
          await appState.reloadMLSStateFromDisk()

          // Resume MLS operations that were suspended during backgrounding
          if let manager = await appState.getMLSConversationManager() {
            await manager.resumeMLSOperations()
          }

          // Check if auto-backup is needed
          if let backupManager = appState.backupManager {
            await backupManager.checkAndPerformAutoBackupIfNeeded()
          }
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
        logger.info("✅ Background scheduled - GRDB auto-suspended, Rust FFI closed")
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
      appState.configureDataServices(modelContainer: modelContext.container)

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

    @State private var showResetConfirmation = false
    @State private var isResetting = false

    var body: some View {
      VStack(spacing: 24) {
        // Error icon
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 60))
          .foregroundStyle(.red, .red.opacity(0.2))

        // Title
        Text("Database Error")
          .font(.title)
          .fontWeight(.bold)

        // Error details (expandable)
        VStack(alignment: .leading, spacing: 8) {
          Text("Unable to open app database")
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
            Text("Reset Local Database")
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
        "Reset Local Database?",
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
              Text("Resetting...")
                .font(.headline)
                .foregroundColor(.white)
            }
            .padding(32)
            .background(Color(.systemGray6))
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
              Text("Reset Database & Restart")
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

    case "add-member":
      await handleAddMember(params: params, manager: manager, logger: e2eLogger)

    case "remove-member":
      await handleRemoveMember(params: params, manager: manager, logger: e2eLogger)

    case "list-members":
      await handleListMembers(params: params, manager: manager, logger: e2eLogger)

    case "check-message":
      await handleCheckMessage(params: params, manager: manager, logger: e2eLogger)

    case "get-epoch":
      await handleGetEpoch(params: params, manager: manager, logger: e2eLogger)

    case "cleanup-stale":
      await handleCleanupStale(params: params, manager: manager, logger: e2eLogger)

    case "drain-key-packages":
      await handleDrainKeyPackages(params: params, manager: manager, logger: e2eLogger)

    case "keypackage-state":
      await handleKeyPackageState(params: params, manager: manager, logger: e2eLogger)

    case "request-keypackage-replenish":
      await handleRequestKeyPackageReplenish(params: params, manager: manager, logger: e2eLogger)

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
      try await conversationManager.ensureDeviceRecordPublished()

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

      // Ensure device record is published after registration.
      do {
        try await conversationManager.ensureDeviceRecordPublished()
      } catch {
        e2eLogger.error("[E2E-REGISTER] Device record publish after registration failed: \(error.localizedDescription)")
      }
      
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

      // ⭐ E2E FIX: Pre-replenish key packages before creating group.
      // On fresh install the background replenishment task may not have finished yet,
      // causing createGroup to fail or timeout waiting for bundles.
      e2eLogger.info("[E2E] Ensuring key packages are replenished before group creation...")
      do {
        try await conversationManager.smartRefreshKeyPackages()
        e2eLogger.info("[E2E] Key package replenishment complete")
      } catch {
        e2eLogger.warning("[E2E] Key package pre-replenishment failed: \(error.localizedDescription) - createGroup will retry inline")
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
  
  // MARK: - E2E Group Chat Commands

  private func handleAddMember(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let conversationId = params["conversationId"],
          let memberDID = params["memberDID"] else {
      e2eLogger.error("[E2E] add-member requires conversationId and memberDID parameters")
      await writeE2EResult(command: "add-member", success: false, error: "Missing conversationId or memberDID")
      return
    }

    guard let appState = manager.lifecycle.appState else {
      e2eLogger.error("[E2E] Not authenticated")
      await writeE2EResult(command: "add-member", success: false, error: "Not authenticated")
      return
    }

    e2eLogger.info("[E2E] Adding member \(memberDID) to conversation \(conversationId)")

    do {
      guard let conversationManager = await appState.getMLSConversationManager() else {
        throw NSError(domain: "E2E", code: 1, userInfo: [NSLocalizedDescriptionKey: "MLS not initialized"])
      }

      try await conversationManager.addMembers(convoId: conversationId, memberDids: [memberDID])

      e2eLogger.info("[E2E] Member added successfully")
      await writeE2EResult(command: "add-member", success: true, data: [
        "conversationId": conversationId,
        "memberDID": memberDID
      ])
    } catch {
      e2eLogger.error("[E2E] Failed to add member: \(error.localizedDescription)")
      await writeE2EResult(command: "add-member", success: false, error: error.localizedDescription)
    }
  }

  private func handleRemoveMember(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let conversationId = params["conversationId"],
          let memberDID = params["memberDID"] else {
      e2eLogger.error("[E2E] remove-member requires conversationId and memberDID parameters")
      await writeE2EResult(command: "remove-member", success: false, error: "Missing conversationId or memberDID")
      return
    }

    guard let appState = manager.lifecycle.appState else {
      e2eLogger.error("[E2E] Not authenticated")
      await writeE2EResult(command: "remove-member", success: false, error: "Not authenticated")
      return
    }

    let reason = params["reason"]
    e2eLogger.info("[E2E] Removing member \(memberDID) from conversation \(conversationId)")

    do {
      guard let conversationManager = await appState.getMLSConversationManager() else {
        throw NSError(domain: "E2E", code: 1, userInfo: [NSLocalizedDescriptionKey: "MLS not initialized"])
      }

      try await conversationManager.removeMember(from: conversationId, memberDid: memberDID, reason: reason)

      e2eLogger.info("[E2E] Member removed successfully")
      await writeE2EResult(command: "remove-member", success: true, data: [
        "conversationId": conversationId,
        "memberDID": memberDID
      ])
    } catch {
      e2eLogger.error("[E2E] Failed to remove member: \(error.localizedDescription)")
      await writeE2EResult(command: "remove-member", success: false, error: error.localizedDescription)
    }
  }

  private func handleListMembers(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let conversationId = params["conversationId"] else {
      e2eLogger.error("[E2E] list-members requires conversationId parameter")
      await writeE2EResult(command: "list-members", success: false, error: "Missing conversationId")
      return
    }

    guard let appState = manager.lifecycle.appState else {
      e2eLogger.error("[E2E] Not authenticated")
      await writeE2EResult(command: "list-members", success: false, error: "Not authenticated")
      return
    }

    do {
      guard let conversationManager = await appState.getMLSConversationManager() else {
        throw NSError(domain: "E2E", code: 1, userInfo: [NSLocalizedDescriptionKey: "MLS not initialized"])
      }

      guard let convo = conversationManager.conversations[conversationId] else {
        throw NSError(domain: "E2E", code: 2, userInfo: [NSLocalizedDescriptionKey: "Conversation not found"])
      }

      let memberDIDs = convo.members.map { $0.did.description }
      let adminDIDs = convo.members.filter { $0.isAdmin }.map { $0.did.description }

      e2eLogger.info("[E2E] Listed \(memberDIDs.count) members for conversation \(conversationId)")
      await writeE2EResult(command: "list-members", success: true, data: [
        "conversationId": conversationId,
        "memberCount": "\(memberDIDs.count)",
        "members": memberDIDs.joined(separator: ","),
        "admins": adminDIDs.joined(separator: ",")
      ])
    } catch {
      e2eLogger.error("[E2E] Failed to list members: \(error.localizedDescription)")
      await writeE2EResult(command: "list-members", success: false, error: error.localizedDescription)
    }
  }

  private func handleCheckMessage(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let conversationId = params["conversationId"],
          let contentPrefix = params["contentPrefix"] else {
      e2eLogger.error("[E2E] check-message requires conversationId and contentPrefix parameters")
      await writeE2EResult(command: "check-message", success: false, error: "Missing conversationId or contentPrefix")
      return
    }

    guard let appState = manager.lifecycle.appState else {
      e2eLogger.error("[E2E] Not authenticated")
      await writeE2EResult(command: "check-message", success: false, error: "Not authenticated")
      return
    }

    do {
      guard let conversationManager = await appState.getMLSConversationManager() else {
        throw NSError(domain: "E2E", code: 1, userInfo: [NSLocalizedDescriptionKey: "MLS not initialized"])
      }

      guard let userDid = conversationManager.userDid else {
        throw NSError(domain: "E2E", code: 3, userInfo: [NSLocalizedDescriptionKey: "No user DID"])
      }

      let messages = try await conversationManager.storage.fetchMessagesForConversation(
        conversationId,
        currentUserDID: userDid,
        database: conversationManager.database,
        limit: 200
      )

      let matching = messages.filter { msg in
        if let plaintext = msg.plaintext {
          return plaintext.hasPrefix(contentPrefix)
        }
        return false
      }

      let matchTexts = matching.compactMap { $0.plaintext }

      e2eLogger.info("[E2E] Found \(matching.count) messages matching prefix '\(contentPrefix)' in \(conversationId)")
      await writeE2EResult(command: "check-message", success: true, data: [
        "conversationId": conversationId,
        "contentPrefix": contentPrefix,
        "matchCount": "\(matching.count)",
        "totalMessages": "\(messages.count)",
        "matches": matchTexts.joined(separator: "|")
      ])
    } catch {
      e2eLogger.error("[E2E] Failed to check messages: \(error.localizedDescription)")
      await writeE2EResult(command: "check-message", success: false, error: error.localizedDescription)
    }
  }

  private func handleGetEpoch(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let conversationId = params["conversationId"] else {
      e2eLogger.error("[E2E] get-epoch requires conversationId parameter")
      await writeE2EResult(command: "get-epoch", success: false, error: "Missing conversationId")
      return
    }

    guard let appState = manager.lifecycle.appState else {
      e2eLogger.error("[E2E] Not authenticated")
      await writeE2EResult(command: "get-epoch", success: false, error: "Not authenticated")
      return
    }

    do {
      guard let conversationManager = await appState.getMLSConversationManager() else {
        throw NSError(domain: "E2E", code: 1, userInfo: [NSLocalizedDescriptionKey: "MLS not initialized"])
      }

      guard let userDid = conversationManager.userDid else {
        throw NSError(domain: "E2E", code: 3, userInfo: [NSLocalizedDescriptionKey: "No user DID"])
      }

      // Sync first to ensure conversation model is up-to-date after add/remove operations
      try? await conversationManager.syncWithServer(fullSync: false)

      guard let convo = conversationManager.conversations[conversationId] else {
        throw NSError(domain: "E2E", code: 2, userInfo: [NSLocalizedDescriptionKey: "Conversation not found"])
      }

      // Query FFI for ground-truth epoch (authoritative source)
      var ffiEpoch: UInt64 = 0
      if let groupIdData = Data(hexEncoded: convo.groupId) {
        ffiEpoch = try await conversationManager.mlsClient.getEpoch(for: userDid, groupId: groupIdData)
      }

      // Use FFI epoch as the primary value since server epoch may lag
      let epoch = ffiEpoch > 0 ? ffiEpoch : UInt64(convo.epoch)
      e2eLogger.info("[E2E] Epoch for \(conversationId): server=\(convo.epoch), ffi=\(ffiEpoch), reported=\(epoch)")
      await writeE2EResult(command: "get-epoch", success: true, data: [
        "conversationId": conversationId,
        "serverEpoch": "\(epoch)",
        "ffiEpoch": "\(ffiEpoch)"
      ])
    } catch {
      e2eLogger.error("[E2E] Failed to get epoch: \(error.localizedDescription)")
      await writeE2EResult(command: "get-epoch", success: false, error: error.localizedDescription)
    }
  }

  /// E2E: Clean up stale conversations and run GRDB/FFI reconciliation.
  /// Purges local conversations that no longer exist on the server or have no FFI counterpart.
  private func handleCleanupStale(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let appState = manager.lifecycle.appState else {
      e2eLogger.error("[E2E] Not authenticated - cannot cleanup")
      await writeE2EResult(command: "cleanup-stale", success: false, error: "Not authenticated")
      return
    }

    do {
      guard let conversationManager = await appState.getMLSConversationManager() else {
        throw NSError(domain: "E2E", code: 1, userInfo: [NSLocalizedDescriptionKey: "MLS not initialized"])
      }

      e2eLogger.info("[E2E] Running sync to trigger reconciliation and zombie detection...")
      try await conversationManager.syncWithServer(fullSync: true)

      let convoCount = conversationManager.conversations.count
      e2eLogger.info("[E2E] Cleanup complete - \(convoCount) conversations remain after reconciliation")
      await writeE2EResult(command: "cleanup-stale", success: true, data: [
        "remainingConversations": "\(convoCount)"
      ])
    } catch {
      e2eLogger.error("[E2E] Cleanup failed: \(error.localizedDescription)")
      await writeE2EResult(command: "cleanup-stale", success: false, error: error.localizedDescription)
    }
  }

  /// E2E: Delete all local key packages for the current device and sync hashes to server.
  private func handleDrainKeyPackages(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let appState = manager.lifecycle.appState else {
      e2eLogger.error("[E2E] Not authenticated")
      await writeE2EResult(command: "drain-key-packages", success: false, error: "Not authenticated")
      return
    }

    do {
      guard let conversationManager = await appState.getMLSConversationManager() else {
        throw NSError(domain: "E2E", code: 1, userInfo: [NSLocalizedDescriptionKey: "MLS not initialized"])
      }

      let userDid = appState.userDID
      let localHashes = try await conversationManager.mlsClient.getLocalKeyPackageHashes(for: userDid)
      let hashRefs: [Data] = localHashes.compactMap { Data(hexEncoded: $0) }
      let deletedLocal = try await conversationManager.mlsClient.deleteKeyPackageBundles(
        for: userDid,
        hashRefs: hashRefs
      )
      let syncResult = try await conversationManager.mlsClient.syncKeyPackageHashes(for: userDid)
      let stats = try await conversationManager.apiClient.getKeyPackageStats()
      let currentDeviceId = await conversationManager.mlsClient.getDeviceInfo(for: userDid)?.deviceId ?? "unknown"

      await writeE2EResult(command: "drain-key-packages", success: true, data: [
        "userDid": userDid,
        "deviceId": currentDeviceId,
        "localHashesBefore": "\(localHashes.count)",
        "deletedLocalBundles": "\(deletedLocal)",
        "serverOrphaned": "\(syncResult.orphanedCount)",
        "serverDeleted": "\(syncResult.deletedCount)",
        "serverRemainingAvailable": "\(syncResult.remainingAvailable)",
        "aggregateAvailableAfter": "\(stats.stats.available)"
      ])
    } catch {
      e2eLogger.error("[E2E] drain-key-packages failed: \(error.localizedDescription)")
      await writeE2EResult(
        command: "drain-key-packages",
        success: false,
        error: error.localizedDescription
      )
    }
  }

  /// E2E: Capture aggregate and per-device key package inventory for current account.
  private func handleKeyPackageState(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let appState = manager.lifecycle.appState else {
      e2eLogger.error("[E2E] Not authenticated")
      await writeE2EResult(command: "keypackage-state", success: false, error: "Not authenticated")
      return
    }

    do {
      guard let conversationManager = await appState.getMLSConversationManager() else {
        throw NSError(domain: "E2E", code: 1, userInfo: [NSLocalizedDescriptionKey: "MLS not initialized"])
      }

      let userDid = appState.userDID
      let currentDeviceId = await conversationManager.mlsClient.getDeviceInfo(for: userDid)?.deviceId
        ?? "unknown"

      let stats = try await conversationManager.apiClient.getKeyPackageStats()
      let (statusCode, listOutput) = try await conversationManager.apiClient.client.blue.catbird.mlschat.listDevices(
        input: BlueCatbirdMlsChatListDevices.Parameters()
      )
      guard statusCode == 200, let listOutput else {
        throw NSError(
          domain: "E2E",
          code: statusCode,
          userInfo: [NSLocalizedDescriptionKey: "listDevices failed with HTTP \(statusCode)"]
        )
      }

      let devices = listOutput.devices
      let currentDevicePackages = devices.first(where: { $0.deviceId == currentDeviceId })?.keyPackageCount ?? -1
      let deviceCounts = devices.map { "\($0.deviceId):\($0.keyPackageCount)" }.joined(separator: ",")

      await writeE2EResult(command: "keypackage-state", success: true, data: [
        "userDid": userDid,
        "currentDeviceId": currentDeviceId,
        "aggregateAvailable": "\(stats.stats.available)",
        "currentDeviceAvailable": "\(currentDevicePackages)",
        "totalDevices": "\(devices.count)",
        "deviceCounts": deviceCounts
      ])
    } catch {
      e2eLogger.error("[E2E] keypackage-state failed: \(error.localizedDescription)")
      await writeE2EResult(
        command: "keypackage-state",
        success: false,
        error: error.localizedDescription
      )
    }
  }

  /// E2E: Explicitly request peer key package replenishment signal.
  private func handleRequestKeyPackageReplenish(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    let rawTargets = params["targetDIDs"] ?? params["targetDID"] ?? ""
    let targetStrings = rawTargets
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    guard !targetStrings.isEmpty else {
      await writeE2EResult(
        command: "request-keypackage-replenish",
        success: false,
        error: "Missing targetDID or targetDIDs"
      )
      return
    }

    guard let appState = manager.lifecycle.appState else {
      await writeE2EResult(
        command: "request-keypackage-replenish",
        success: false,
        error: "Not authenticated"
      )
      return
    }

    do {
      guard let conversationManager = await appState.getMLSConversationManager() else {
        throw NSError(domain: "E2E", code: 1, userInfo: [NSLocalizedDescriptionKey: "MLS not initialized"])
      }

      let targetDIDs = try targetStrings.map { try DID(didString: $0) }
      let reason = params["reason"] ?? "e2e"
      let convoId = params["conversationId"]
      let result = try await conversationManager.apiClient.requestKeyPackageReplenish(
        dids: targetDIDs,
        reason: reason,
        convoId: convoId
      )

      await writeE2EResult(command: "request-keypackage-replenish", success: true, data: [
        "targetCount": "\(result.targetCount)",
        "deviceCount": "\(result.deviceCount)",
        "deliveredCount": "\(result.deliveredCount)",
        "requested": "\(result.requested)"
      ])
    } catch {
      e2eLogger.error("[E2E] request-keypackage-replenish failed: \(error.localizedDescription)")
      await writeE2EResult(
        command: "request-keypackage-replenish",
        success: false,
        error: error.localizedDescription
      )
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

    // 1. Handle key package notifications
    if let type = userInfo["type"] as? String,
       type == "keyPackageLowInventory" || type == "keyPackageReplenishRequested"
    {
      Task { @MainActor in
        guard let appState = AppStateManager.shared.lifecycle.appState else {
          logger.warning("AppState not available for MLS notification handling")
          completionHandler()
          return
        }
        await MLSNotificationHandler.shared.handleNotification(userInfo: userInfo, appState: appState)
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
        
        let recipientDid: String? = {
          // Prefer recipient_did (set by NSE after resolving hash, or legacy payload)
          if let did = userInfo["recipient_did"] as? String {
            return did
          }
          // Fall back to resolving recipient_account hash against local accounts
          if let hash = userInfo["recipient_account"] as? String {
            return Self.resolveRecipientDID(fromHash: hash)
          }
          return nil
        }()
        
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

  /// Compute SHA-256 hash of a DID for push notification account matching.
  private static func hashForAccountMatching(_ did: String) -> String {
    let digest = SHA256.hash(data: Data(did.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  /// Resolve a recipient DID from a SHA-256 hash by checking locally known accounts.
  private static func resolveRecipientDID(fromHash hash: String) -> String? {
    return MainActor.assumeIsolated {
      let appStateManager = AppStateManager.shared
      // Check the active account first
      if let activeDID = appStateManager.lifecycle.userDID,
        hashForAccountMatching(activeDID) == hash
      {
        return activeDID
      }
      // Check all authenticated accounts
      for did in appStateManager.authenticatedDIDs {
        if hashForAccountMatching(did) == hash {
          return did
        }
      }
      return nil
    }
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
    
    // 1. Handle key package notifications
    if let type = userInfo["type"] as? String,
       type == "keyPackageLowInventory" || type == "keyPackageReplenishRequested"
    {
      Task { @MainActor in
        guard let appState = AppStateManager.shared.lifecycle.appState else {
          let logger = Logger(subsystem: "blue.catbird", category: "AppDelegate")
          logger.warning("AppState not available for MLS notification handling")
          return
        }
        await MLSNotificationHandler.shared.handleNotification(userInfo: userInfo, appState: appState)
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

