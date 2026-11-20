import AVFoundation
#if os(iOS)
import BackgroundTasks
#endif
import CryptoKit
import Sentry

import CoreText
import OSLog
import Petrel
import PetrelCatbird
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

// Presentation fixtures deliberately bypass account bootstrap and networking.
private var isEncryptedRequestUIFixture: Bool {
  #if DEBUG
  ProcessInfo.processInfo.arguments.contains("--encrypted-request-ui-fixture")
  #else
  false
  #endif
}

private var isConversationKindUIFixture: Bool {
  #if DEBUG
  ConversationKindUIFixture.isRequested
  #else
  false
  #endif
}

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
  #if DEBUG && os(iOS)
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

private var isSearchTabReselectionUIFixture: Bool {
  #if DEBUG && os(iOS)
  ProcessInfo.processInfo.arguments.contains(SearchTabReselectionFixture.launchArgument)
  #else
  false
  #endif
}

private var isMessagesNavigationUIFixture: Bool {
  #if DEBUG && os(iOS)
  ProcessInfo.processInfo.arguments.contains(MessagesNavigationFixture.launchArgument)
  #else
  false
  #endif
}

/// Any presentation fixture: skips account bootstrap, MLS lifecycle, and URL handling.
private var isPresentationUIFixture: Bool {
  isConversationKindUIFixture || isEncryptedRequestUIFixture || isMessageRequestsUIFixture || isVideoFeedUIFixture || isSocialActionsUIFixture || isSettingsUIFixture || isOnboardingIntelUIFixture || isSceneRuntimeUIFixture || isInlineReplyUIFixture || isMessagesViewportUIFixture || isSearchTabReselectionUIFixture || isMessagesNavigationUIFixture || isModerationUIFixture || isFeedPerformanceFixture
}

private var isOnboardingIntelUIFixture: Bool {
  #if DEBUG
  ProcessInfo.processInfo.arguments.contains(OnboardingIntelligenceUIFixture.launchArgument)
  #else
  false
  #endif
}

private var isFeedPerformanceFixture: Bool {
  #if DEBUG && os(iOS)
  ProcessInfo.processInfo.arguments.contains("--feed-perf-fixture")
  #else
  false
  #endif
}

private var isModerationUIFixture: Bool {
  #if DEBUG && os(iOS)
  ProcessInfo.processInfo.arguments.contains("--moderation-ui-fixture")
  #else
  false
  #endif
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

@MainActor
private enum MLSSceneTransitionTracker {
  private static var generation: UInt64 = 0
  private static var currentPhase: ScenePhase?

  static func recordTransition(to phase: ScenePhase) -> UInt64 {
    generation &+= 1
    currentPhase = phase
    return generation
  }

  static func isCurrent(_ token: UInt64, expectedPhase: ScenePhase) -> Bool {
    token == generation && currentPhase == expectedPhase
  }
}


/// Owns the production SwiftData schema so app startup and migration tests open
/// exactly the same store shape.
enum CatbirdSwiftDataStore {
  /// Recovery works on these locations and defaults; the live instance stays outside the
  /// database files recovery can remove. Tests pass temporary locations through the same hooks.
  struct RecoveryLocations {
    let storeDirectory: URL?
    let legacyDirectory: URL?
    let additionalDatabaseDirectories: [URL]
    let defaults: UserDefaults

    var storeURL: URL? { storeDirectory?.appendingPathComponent("Catbird.store") }
    var quarantineDirectory: URL? {
      storeDirectory?.deletingLastPathComponent().appendingPathComponent("quarantine", isDirectory: true)
    }
    var databaseDirectories: [URL] {
      var seen = Set<URL>()
      return ([storeDirectory, legacyDirectory].compactMap { $0 } + additionalDatabaseDirectories)
        .filter { seen.insert($0).inserted }
    }
    static var live: Self {
      Self(storeDirectory: CatbirdSwiftDataStore.swiftDataStoreDirectory,
           legacyDirectory: CatbirdSwiftDataStore.legacyAppGroupSwiftDataDirectory,
           additionalDatabaseDirectories: CatbirdSwiftDataStore.allDatabaseDirectories(), defaults: .standard)
    }
  }

  static let modelTypes: [any PersistentModel.Type] = [
    CachedFeedViewPost.self, PersistedScrollPosition.self, PersistedFeedState.self,
    FeedContinuityInfo.self, Preferences.self, AppSettingsModel.self, DraftPost.self,
    BackupRecord.self, BackupConfiguration.self, RepositoryRecord.self,
    ParsedATProtocolRecord.self, ParsedPost.self, ParsedProfile.self,
    ParsedMedia.self, ParsedConnection.self, ParsedUnknownRecord.self,
  ]

  static let currentSchemaVersion = 4
  static let appGroupIdentifier = "group.blue.catbird.shared"
  static let launchAttemptCountKey = "CatbirdLaunchAttemptCount"
  static let lastLaunchTimeKey = "CatbirdLastLaunchTime"
  static let crashLoopThreshold = 3
  static let crashLoopWindowSeconds: TimeInterval = 60
  static let safeModeReason = "Catbird had trouble opening its local data, so changes you make now won’t be saved after you close the app."

  static var swiftDataStoreDirectory: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("swiftdata", isDirectory: true)
  }

  static var swiftDataStoreURL: URL? {
    swiftDataStoreDirectory?.appendingPathComponent("Catbird.store")
  }

  /// Where quarantineSwiftDataStore sets a store aside, one folder per quarantine.
  static var quarantineDirectory: URL? {
    swiftDataStoreDirectory?.deletingLastPathComponent().appendingPathComponent("quarantine", isDirectory: true)
  }

  static let storeResetDateKey = "CatbirdSwiftDataStoreResetAt"
  private static let volatileSessionKey = "CatbirdSwiftDataVolatileSessionPending"

  /// When the store last lost rows: deleted, set aside in quarantine, or stripped of its
  /// write-ahead log. Kept in standard defaults, outside the files a reset removes, so draft
  /// photo cleanup (DraftImageOrphanSweep) keeps photos first written before then, which a lost
  /// draft re-imported from Bluesky may still name.
  static var lastStoreResetDate: Date? {
    lastStoreResetDate(in: .standard)
  }

  static func lastStoreResetDate(in defaults: UserDefaults) -> Date? {
    (defaults.object(forKey: storeResetDateKey) as? Double).map(Date.init(timeIntervalSince1970:))
  }

  /// Records a store reset before the files go, so a crash part way still leaves the record.
  static func recordStoreReset(at date: Date = Date(), defaults: UserDefaults = .standard) {
    defaults.set(date.timeIntervalSince1970, forKey: storeResetDateKey)
  }

  /// Photos written during safe mode survive on disk while their rows do not. Fence through
  /// the next durable opening, rather than only safe-mode entry, to protect every account's
  /// photos until its remote drafts can be imported. Consume once so healthy launches do not
  /// extend retention forever. Both values live outside the database being recovered.
  private static func finishDurableOpening(defaults: UserDefaults, now: Date) {
    guard defaults.bool(forKey: volatileSessionKey) else { return }
    recordStoreReset(at: now, defaults: defaults)
    defaults.removeObject(forKey: volatileSessionKey)
  }

  static var legacyAppGroupSwiftDataDirectory: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
      .appendingPathComponent("swiftdata", isDirectory: true)
  }

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

  static func makeContainer(locations: RecoveryLocations = .live) throws -> ModelContainer {
    if let storeDir = locations.storeDirectory {
      try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
    }

    let config: ModelConfiguration
    if let storeURL = locations.storeURL {
      config = ModelConfiguration(
        "Catbird",
        url: storeURL,
        cloudKitDatabase: .none
      )
      logger.debug("📍 Using explicit store URL: \(storeURL.path)")
    } else {
      config = ModelConfiguration(cloudKitDatabase: .none)
      logger.warning("⚠️ App group unavailable, using default store location")
    }

    return try makeContainer(configuration: config)
  }

  static func makeInMemoryContainer() throws -> ModelContainer {
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

  static func deleteSwiftDataSidecarsOnly(locations: RecoveryLocations = .live, now: Date = Date()) {
    // Rows not yet checkpointed into the store go with the write-ahead log.
    recordStoreReset(at: now, defaults: locations.defaults)
    let fileManager = FileManager.default
    let sidecars = ["-wal", "-shm"]

    if let storeURL = locations.storeURL {
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

    let legacyFiles = [
      "Catbird.store-wal", "Catbird.store-shm",
      "Catbird.sqlite-wal", "Catbird.sqlite-shm",
      "default.store-wal", "default.store-shm"
    ]
    for directory in locations.databaseDirectories {
      for fileName in legacyFiles {
        let fileURL = directory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: fileURL.path) {
          try? fileManager.removeItem(at: fileURL)
          logger.debug("🔄 Removed legacy sidecar: \(fileName)")
        }
      }
    }
  }

  static func quarantineSwiftDataStore(reason: String, locations: RecoveryLocations = .live, now: Date = Date()) {
    recordStoreReset(at: now, defaults: locations.defaults)
    let fileManager = FileManager.default
    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
    let timestamp = dateFormatter.string(from: now).replacingOccurrences(of: ":", with: "-")

    guard let storeDir = locations.storeDirectory, let quarantineRoot = locations.quarantineDirectory else {
      logger.warning("⚠️ Cannot quarantine - store directory unavailable")
      resetAllDatabaseFiles(locations: locations, now: now)
      return
    }

    let quarantineDir = quarantineRoot.appendingPathComponent("\(timestamp)_\(reason)", isDirectory: true)

    do {
      try fileManager.createDirectory(at: quarantineDir, withIntermediateDirectories: true)

      let storeFiles = ["Catbird.store", "Catbird.store-wal", "Catbird.store-shm"]
      for fileName in storeFiles {
        let sourceURL = storeDir.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: sourceURL.path) {
          let destURL = quarantineDir.appendingPathComponent(fileName)
          try fileManager.moveItem(at: sourceURL, to: destURL)
          logger.info("📦 Quarantined: \(fileName) → \(quarantineDir.lastPathComponent)/")
        }
      }

      let metadata: [String: Any] = [
        "quarantine_reason": reason,
        "timestamp": now.timeIntervalSince1970,
        "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
        "schema_version": currentSchemaVersion
      ]
      if let metadataData = try? JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted) {
        try metadataData.write(to: quarantineDir.appendingPathComponent("metadata.json"))
      }

      logger.info("✅ Database quarantined to: \(quarantineDir.path)")
    } catch {
      logger.error("❌ Quarantine failed: \(error.localizedDescription) - falling back to delete")
      resetAllDatabaseFiles(locations: locations, now: now)
    }
  }

  static func resetAllDatabaseFiles(locations: RecoveryLocations = .live, now: Date = Date()) {
    let resetLogger = Logger(subsystem: "blue.catbird", category: "DatabaseRecovery")
    resetLogger.warning("🗑️ RESET: Deleting all SwiftData files")
    recordStoreReset(at: now, defaults: locations.defaults)

    let fileManager = FileManager.default
    let allFiles = [
      "Catbird.store", "Catbird.store-wal", "Catbird.store-shm",
      "Catbird.sqlite", "Catbird.sqlite-wal", "Catbird.sqlite-shm",
      "default.store", "default.store-wal", "default.store-shm"
    ]

    for directory in locations.databaseDirectories {
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

    if let storeDir = locations.storeDirectory, fileManager.fileExists(atPath: storeDir.path) {
      try? fileManager.removeItem(at: storeDir)
      resetLogger.info("🗑️ Deleted swiftdata directory (private container)")
    }

    if let legacyDir = locations.legacyDirectory, fileManager.fileExists(atPath: legacyDir.path) {
      try? fileManager.removeItem(at: legacyDir)
      resetLogger.info("🗑️ Deleted legacy swiftdata directory (App Group)")
    }

    locations.defaults.removeObject(forKey: "CatbirdSchemaVersion")
    locations.defaults.removeObject(forKey: launchAttemptCountKey)
    locations.defaults.removeObject(forKey: lastLaunchTimeKey)

    resetLogger.info("✅ Database reset complete")
  }

  static func allDatabaseDirectories() -> [URL] {
    var directories: [URL] = []
    if let storeDir = swiftDataStoreDirectory {
      directories.append(storeDir)
    }
    if let legacyDir = legacyAppGroupSwiftDataDirectory {
      directories.append(legacyDir)
    }
    if let appGroup = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
      directories.append(appGroup)
      directories.append(appGroup.appendingPathComponent("Library/Application Support"))
    }
    if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
      directories.append(docs)
    }
    if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      directories.append(appSupport)
    }
    return directories
  }

  static func migrateSwiftDataFromAppGroup(locations: RecoveryLocations = .live, now: Date = Date()) {
    let migrationKey = "SwiftDataMigratedFromAppGroup"
    guard !locations.defaults.bool(forKey: migrationKey) else { return }

    let fm = FileManager.default
    guard let oldDir = locations.legacyDirectory,
          let newDir = locations.storeDirectory else {
      locations.defaults.set(true, forKey: migrationKey)
      return
    }

    guard fm.fileExists(atPath: oldDir.path),
          let contents = try? fm.contentsOfDirectory(atPath: oldDir.path),
          !contents.isEmpty else {
      locations.defaults.set(true, forKey: migrationKey)
      return
    }

    try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)

    for fileName in contents {
      let oldFile = oldDir.appendingPathComponent(fileName)
      let newFile = newDir.appendingPathComponent(fileName)
      if fm.fileExists(atPath: newFile.path) {
        // The old copy is discarded below even though a different destination store wins.
        recordStoreReset(at: now, defaults: locations.defaults)
        continue
      }
      do {
        try fm.moveItem(at: oldFile, to: newFile)
        logger.info("📦 Migrated SwiftData file: \(fileName)")
      } catch {
        // The old folder is removed below, so whatever this file held is lost.
        recordStoreReset(at: now, defaults: locations.defaults)
        logger.warning("⚠️ Failed to migrate \(fileName): \(error.localizedDescription)")
      }
    }

    try? fm.removeItem(at: oldDir)
    locations.defaults.set(true, forKey: migrationKey)
    logger.info("✅ SwiftData migrated from App Group to private container")
  }

  static func detectCrashLoop(defaults: UserDefaults = .standard, now date: Date = Date()) -> Bool {
    let now = date.timeIntervalSince1970
    let lastLaunch = defaults.double(forKey: lastLaunchTimeKey)
    let attemptCount = defaults.integer(forKey: launchAttemptCountKey)

    if now - lastLaunch < crashLoopWindowSeconds {
      let newCount = attemptCount + 1
      defaults.set(newCount, forKey: launchAttemptCountKey)
      defaults.set(now, forKey: lastLaunchTimeKey)

      if newCount >= crashLoopThreshold {
        logger.error("🔄 Crash loop detected: \(newCount) launches in \(Int(now - lastLaunch))s")
        return true
      }
    } else {
      defaults.set(1, forKey: launchAttemptCountKey)
      defaults.set(now, forKey: lastLaunchTimeKey)
    }

    return false
  }

  static func resetCrashLoopCounter(defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: launchAttemptCountKey)
    defaults.removeObject(forKey: lastLaunchTimeKey)
  }

  static func shouldResetDatabase(defaults: UserDefaults = .standard) -> Bool {
    let savedVersion = defaults.integer(forKey: "CatbirdSchemaVersion")
    return savedVersion != 0 && savedVersion < currentSchemaVersion
  }

  static func saveSchemaVersion(defaults: UserDefaults = .standard) {
    defaults.set(currentSchemaVersion, forKey: "CatbirdSchemaVersion")
  }

  static func formatDatabaseError(_ error: Error) -> String {
    var details = error.localizedDescription
    if let nsError = error as NSError? {
      details += " [domain: \(nsError.domain), code: \(nsError.code)]"
      if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
        details += " underlying: \(underlying.localizedDescription)"
      }
    }
    return details
  }

  /// Runs the full recovery ladder off the main thread.
  static func openWithRecovery(locations: RecoveryLocations = .live, now: Date = Date()) -> ModelContainerState {
    logger.info("📦 Starting off-main ModelContainer initialization")
    migrateSwiftDataFromAppGroup(locations: locations, now: now)

    if detectCrashLoop(defaults: locations.defaults, now: now) {
      logger.error("🔄 CRASH LOOP DETECTED - forcing safe mode recovery")
      if let container = try? makeInMemoryContainer() {
        locations.defaults.set(true, forKey: volatileSessionKey)
        resetCrashLoopCounter(defaults: locations.defaults)
        return .degraded(container, reason: safeModeReason)
      }
    }

    if shouldResetDatabase(defaults: locations.defaults) {
      logger.warning("⚠️ Schema version mismatch detected, resetting database for clean migration")
      quarantineSwiftDataStore(reason: "schema_mismatch", locations: locations, now: now)
    }

    // Attempt A: Normal initialization
    do {
      let container = try makeContainer(locations: locations)
      saveSchemaVersion(defaults: locations.defaults)
      logger.info("✅ ModelContainer initialized successfully")
      finishDurableOpening(defaults: locations.defaults, now: now)
      return .ready(container)
    } catch {
      logger.error("❌ Attempt A (normal init) failed: \(formatDatabaseError(error))")
    }

    // Attempt B: Delete sidecars only
    do {
      logger.warning("🔧 Attempt B: Deleting WAL/SHM sidecars and retrying...")
      deleteSwiftDataSidecarsOnly(locations: locations, now: now)
      let container = try makeContainer(locations: locations)
      saveSchemaVersion(defaults: locations.defaults)
      logger.warning("✅ Recovered by deleting WAL/SHM sidecars")
      finishDurableOpening(defaults: locations.defaults, now: now)
      return .ready(container)
    } catch {
      logger.error("❌ Attempt B (sidecar recovery) failed: \(formatDatabaseError(error))")
    }

    // Attempt C: Quarantine store and retry fresh
    do {
      logger.warning("🔧 Attempt C: Quarantining store and creating fresh database...")
      quarantineSwiftDataStore(reason: "corruption_recovery", locations: locations, now: now)
      let container = try makeContainer(locations: locations)
      saveSchemaVersion(defaults: locations.defaults)
      logger.warning("✅ Recovered by quarantining store and recreating")
      finishDurableOpening(defaults: locations.defaults, now: now)
      return .ready(container)
    } catch {
      logger.error("❌ Attempt C (quarantine recovery) failed: \(formatDatabaseError(error))")
    }

    // Attempt D: In-memory fallback
    do {
      logger.error("⚠️ Attempt D: Falling back to in-memory storage...")
      let container = try makeInMemoryContainer()
      locations.defaults.set(true, forKey: volatileSessionKey)
      resetCrashLoopCounter(defaults: locations.defaults)
      logger.error("⚠️ Running in DEGRADED MODE - data will not persist across restarts")
      return .degraded(container, reason: safeModeReason)
    } catch {
      logger.error("❌ Attempt D (in-memory fallback) failed: \(formatDatabaseError(error))")
      return .failed(error)
    }
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

      // Set notification center delegate for handling notification taps, presentation, and MLS notifications
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
      if let kind = userInfo["kind"] as? String, kind == "circle_activity" {
        logger.info("Processing generic Circle activity push notification")
        Task { @MainActor in
          if let activeState = AppStateManager.shared.lifecycle.appState {
            await activeState.notificationManager.handlePush(userInfo)
            completionHandler(.newData)
          } else {
            completionHandler(.noData)
          }
        }
        return
      }

      // Check if this is an MLS key package inventory notification
      if let type = userInfo["type"] as? String,
         type == "keyPackageLowInventory" || type == "keyPackageReplenishRequested" {
        guard application.applicationState == .active else {
          completionHandler(.noData)
          return
        }
        Task { @MainActor in
          guard let activeState = AppStateManager.shared.lifecycle.appState,
                let coordinator = await activeState.getOrOpenMLSCoordinator() else {
            completionHandler(.noData)
            return
          }
          try? await coordinator.resumeFromBackground()
          await activeState.loadMLSConversations()
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
        Task { @MainActor in
          guard let activeState = AppStateManager.shared.lifecycle.appState,
                let coordinator = await activeState.getOrOpenMLSCoordinator() else {
            completionHandler(.noData)
            return
          }
          try? await coordinator.resumeFromBackground()
          await activeState.loadMLSConversations()
          completionHandler(.newData)
        }
      } else {
        logger.debug("Not an MLS notification, ignoring. Keys: \(userInfo.keys.map { String(describing: $0) }.joined(separator: ", "))")
        completionHandler(.noData)
      }
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

  // No @Environment(\.modelContext) here: an App struct is outside every
  // .modelContainer, so it reads SwiftUI's empty placeholder context, not the store.
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
    // Resolve routing first: in DEBUG this installs an explicitly configured runtime fixture
    // transport before any client exists (and refuses to launch on an invalid config).
    _ = CatbirdGatewayConfiguration.current
    // Start auth restore concurrently with startup
    Task { @MainActor in
      await AppStateManager.shared.initialize()
    }
    // Purges older builds' raw video upload snapshots and keeps that folder out of backups even if
    // no composer opens a video again, off the main thread and before any upload can start.
    VideoUploadCheckpointStore.openSharedInBackground()
    logger.info("🚀 CatbirdApp initializing")

    // Register blue.catbird.* / place.stream.* lexicon types with Petrel's decoder registry
    // before any responses containing custom types are decoded.
    PetrelCatbirdLexicons.register()

    // Bridge Petrel logs into Sentry (Sentry is initialized in AppDelegate)
    PetrelSentryBridge.enable()
    // Bridge MLS diagnostic records into Sentry
    MLSSentryBridge.enable()
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

    // P001: Dead model-warmup calls removed

  }

  // MARK: - ModelContainer Async Initialization

  /// The open in progress. Every window shows LoadingView while the store opens,
  /// so a multi-window restore would otherwise open the SQLite store twice at once.
  @MainActor private static var inFlightModelContainerOpen: Task<ModelContainerState, Never>?

  @MainActor
  private func initializeModelContainer() async {
    if case .failed = appStateManager.modelContainerState {
      appStateManager.modelContainerState = .loading
    }
    guard case .loading = appStateManager.modelContainerState else { return }
    if let inFlight = Self.inFlightModelContainerOpen {
      _ = await inFlight.value
      return
    }
    logger.info("📦 Requesting off-main ModelContainer initialization")
    let open = Task.detached(priority: .userInitiated) {
      CatbirdSwiftDataStore.openWithRecovery()
    }
    Self.inFlightModelContainerOpen = open
    let result = await open.value
    Self.inFlightModelContainerOpen = nil
    appStateManager.modelContainerState = result
    if case .ready = result {
      scheduleStableLaunchMarker()
    }
  }

  /// Deletes all SwiftData database files from all possible locations
  /// Called by ErrorRecoveryView's Reset button - works WITHOUT ModelContainer
  static func resetAllDatabaseFiles() {
    CatbirdSwiftDataStore.resetAllDatabaseFiles()
  }

  /// Schedules a task to mark the launch as stable after 30 seconds
  private func scheduleStableLaunchMarker() {
    Task {
      try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30 seconds
      await MainActor.run {
        CatbirdSwiftDataStore.resetCrashLoopCounter()
        logger.debug("✅ Launch marked as stable (30s elapsed)")
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
              .platformAgeProtected(.generalContent)
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
            appStateManager.modelContainerState = .loading
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
          if ConversationKindUIFixture.isRequested {
            ConversationKindUIFixture()
          } else if isEncryptedRequestUIFixture {
            MLSEncryptedRequestUIFixture()
          } else if isMessageRequestsUIFixture {
            MessageRequestsUIFixture()
          } else if isVideoFeedUIFixture {
            VideoFeedUIFixture()
          } else if isSocialActionsUIFixture {
            #if os(iOS)
            SocialActionsUIFixture()
            #else
            EmptyView()
            #endif
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
          } else if isSearchTabReselectionUIFixture {
            #if os(iOS)
            SearchTabReselectionFixture()
            #else
            EmptyView()
            #endif
          } else if isMessagesNavigationUIFixture {
            #if os(iOS)
            MessagesNavigationFixture()
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
          } else if isOnboardingIntelUIFixture {
            OnboardingIntelligenceUIFixture()
          } else if isModerationUIFixture {
            #if os(iOS)
            ModerationUIFixture()
            #else
            EmptyView()
            #endif
          } else if isFeedPerformanceFixture {
            #if os(iOS)
            FeedPerformanceFixture()
            #else
            EmptyView()
            #endif
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
  } else if url.scheme == "blue.catbird" && url.host == "oauth"
              && url.lastPathComponent == "circle-appview" {
    // Circle AppView authorization completed. The AppView owns the
    // grant server-side; this only records that it succeeded.
    logger.info("Circle AppView OAuth completion deep link received")
    Task { @MainActor in
      CircleAppViewAuthCoordinator.shared.complete(callback: url)
    }
  } else if (scheme == "blue.catbird" || scheme == "catbird") && host == "share" {
    // The share extension saved a draft to the app group and opened Catbird.
    // The import presents it in the composer once an account is ready, and
    // keeps any draft that was already open as a recoverable saved draft.
    IncomingSharedDraftHandler.importIfAvailable()
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
        appStateManager.presentAccountSwitchOutcome(outcome)
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
          SceneNavigationHost(appState: appState, appStateManager: appStateManager, context: context) {
            ContentView()
              .modifier(MLSDirectDraftPresentation())
          }
          .id(context.activityRegistrationID)
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
    // Asks to sign in again when a switch reached an account whose session expired.
    // It waits while the sign-out alert below is up, so the two never stack.
    .modifier(AccountReauthenticationPromptModifier(appStateManager: appStateManager))
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
      FeedStateStore.shared.setModelContext(container.mainContext)
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
    let sceneTransitionToken = MLSSceneTransitionTracker.recordTransition(to: newPhase)
    #if os(iOS)
    let hasOtherScenes = hasOtherActiveScenes
    #else
    let hasOtherScenes = false
    #endif
    #if os(macOS)
    let isMacOS = true
    #else
    let isMacOS = false
    #endif
    let otherScenesActive = Self.sceneDeactivationPreservesMLS(
      isMacOS: isMacOS,
      otherScenesActive: hasOtherScenes
    )
    CopilotAvailability.setApplicationActive(newPhase == .active || hasOtherScenes)

    if otherScenesActive && (newPhase == .inactive || newPhase == .background) {
      logger.info("Scene transitioned to \(String(describing: newPhase)), but other connected scenes remain active in foreground. Preserving process-wide database and MLS connections.")
    }

    #if os(iOS)
    var taskId: UIBackgroundTaskIdentifier = .invalid
    if newPhase == .background && !otherScenesActive {
      taskId = UIApplication.shared.beginBackgroundTask(withName: "CatbirdMLSPrepareForBackground") {
        logger.warning("CatbirdMLSPrepareForBackground expired — cancelling MLS tasks and ending background assertion")
        MainActor.assumeIsolated {
          AppStateManager.shared.lifecycle.appState?.cancelMLSInitialization()
        }
        if taskId != .invalid {
          UIApplication.shared.endBackgroundTask(taskId)
          taskId = .invalid
        }
      }
    }
    #endif

    if newPhase == .background && !otherScenesActive {
      appStateManager.lifecycle.appState?.cancelMLSInitialization()
    }

    let shouldSuspendGRDB = (newPhase == .background) && !otherScenesActive
    GRDBSuspensionCoordinator.setLifecycleSuspended(
      shouldSuspendGRDB,
      reason: "scenePhase \(String(describing: oldPhase)) → \(String(describing: newPhase))"
    )

    Task { @MainActor in
      #if os(iOS)
      defer {
        if taskId != .invalid {
          UIApplication.shared.endBackgroundTask(taskId)
          taskId = .invalid
        }
      }
      #endif

      guard MLSSceneTransitionTracker.isCurrent(
        sceneTransitionToken,
        expectedPhase: newPhase
      ) else {
        logger.debug("Skipping stale scene lifecycle task")
        return
      }

      if newPhase == .background && !otherScenesActive {
        await appStateManager.lifecycle.appState?.prepareMLSForBackground()
        logger.info("Rust CatbirdMlsClient checkpointed WAL and closed SQLite handle before suspension")
      } else if newPhase == .active && oldPhase != .active {
        await resumeMLSAfterReturningToForeground(transitionToken: sceneTransitionToken)
      }

      if newPhase == .background {
        // Reaching the background cleanly means this launch didn't crash.
        CatbirdSwiftDataStore.resetCrashLoopCounter()
        saveApplicationState()
        // The last scene left: unlike otherScenesActive, which also keeps MLS open on macOS.
        if !hasOtherScenes {
          startDraftPhotoSweepIfDue()
        }
        #if os(iOS)
        if !otherScenesActive {
          if #available(iOS 13.0, *) {
            ChatBackgroundRefreshManager.schedule()
            BackgroundCacheRefreshManager.schedule()
          }
          logger.info("Background work scheduled after MLS SQLite checkpoint and close")
        }
        #endif
      }
    }
  }

  @MainActor
  private func resumeMLSAfterReturningToForeground(transitionToken: UInt64) async {
    guard MLSSceneTransitionTracker.isCurrent(transitionToken, expectedPhase: .active),
          let appState = appStateManager.lifecycle.appState else {
      return
    }
    await appState.resumeMLSFromBackground()
    guard MLSSceneTransitionTracker.isCurrent(transitionToken, expectedPhase: .active) else {
      return
    }
    if let backupManager = appState.backupManager {
      await backupManager.checkAndPerformAutoBackupIfNeeded()
    }
    logger.info("✅ [RESUME] MLS coordinator resumed and UI state refreshed")
  }

  /// Starts the daily draft photo sweep (ComposerDraftManager.sweepOrphanedDraftImageFilesIfDue).
  /// Its background task begins here, while the scene transition still holds its own, and ends
  /// when the sweep does; expiry cancels the sweep before its next batch.
  @MainActor
  private func startDraftPhotoSweepIfDue() {
    guard let manager = appStateManager.lifecycle.appState?.composerDraftManager else { return }
    let sweep = Task { @MainActor in
      _ = await manager.sweepOrphanedDraftImageFilesIfDue()
    }
    let assertion = CatbirdBackgroundTask(name: "DraftPhotoSweep") { sweep.cancel() }
    Task { @MainActor in
      await sweep.value
      assertion.end()
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
      // Bind the real store. AppStateManager has normally done this already, and the
      // bootstrap key makes a repeat with the same container a no-op.
      if let container = appStateManager.modelContainerState.container {
        appState.initializePreferencesManager(with: container.mainContext)
        appState.configureDataServices(modelContainer: container)
      }

      // P001: Dead model-warmup calls removed

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

  /// Picks up exactly where the launch screen leaves off: the same 250pt
  /// `LaunchIcon`, centered on the system background, with progress below it,
  /// so a cold launch doesn't jump to a smaller icon.
  struct LoadingView: View {
    private static let launchIconSize: CGFloat = 250

    var body: some View {
      Image("LaunchIcon")
        .accessibilityHidden(true)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
          VStack(spacing: 12) {
            ProgressView()
            Text("Loading…")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .offset(y: Self.launchIconSize / 2 + 48)
        }
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

  /// Handle E2E testing URL commands
  /// Format: blue.catbird://e2e/{command}?{params}
  /// Commands:
  /// - create-conversation?targetDID=... - Create/join a conversation with the target user
  /// - accept-conversation?conversationId=... - Accept a pending clean-chat invitation
  /// - send-message?text=...&conversationId=... - Send a message to a conversation
  /// - dump-state - Write MLS state dump to app container
  /// - block?did=... - Block a DID and leave shared MLS conversations
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
    #if DEBUG
    let skipProactiveRefresh = CatbirdGatewayConfiguration.current.isRuntimeFixture
    #else
    let skipProactiveRefresh = false
    #endif
    if !skipProactiveRefresh, let appState = manager.lifecycle.appState, command != "dump-state", command != "request-notification-permission" {
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
#if DEBUG
    case "login-fixture":
      await handleLoginFixture(manager: manager, logger: e2eLogger)
#endif
      
    case "register-device":
      await handleRegisterDevice(params: params, manager: manager, logger: e2eLogger)
      
    case "request-send":
      await handleDirectRequest(params: params, manager: manager, inspect: false)

    case "request-inspect":
      await handleDirectRequest(params: params, manager: manager, inspect: true)

    case "request-delivery-enable":
      await handleRequestDeliveryEnable(params: params, manager: manager, logger: e2eLogger)

    case "create-conversation":
      await handleCreateConversation(params: params, manager: manager, logger: e2eLogger)

    case "accept-conversation":
      await handleAcceptConversation(params: params, manager: manager, logger: e2eLogger)
      
    case "send-message":
      await handleSendMessage(params: params, manager: manager, logger: e2eLogger)
      
    case "get-messages":
      await handleGetMessages(params: params, manager: manager, logger: e2eLogger)
      
    case "dump-state":
      await handleDumpState(params: params, manager: manager, logger: e2eLogger)
      
    case "sync":
      await handleSync(params: params, manager: manager, logger: e2eLogger)

    case "block":
      await handleBlock(params: params, manager: manager, logger: e2eLogger)

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

    case "force-delete-conversation", "force_delete_conversation":
      await handleForceDeleteConversation(params: params, manager: manager, logger: e2eLogger)

    case "drain-key-packages":
      await handleDrainKeyPackages(params: params, manager: manager, logger: e2eLogger)

    case "keypackage-state":
      await handleKeyPackageState(params: params, manager: manager, logger: e2eLogger)

    case "refresh-key-packages":
      await handleRefreshKeyPackages(params: params, manager: manager, logger: e2eLogger)

    case "request-keypackage-replenish":
      await handleRequestKeyPackageReplenish(params: params, manager: manager, logger: e2eLogger)

    case "wipe-mls-state", "wipe_mls_state":
      await handleWipeMLSState(params: params, manager: manager, logger: e2eLogger)

    case "get-recovery-state", "get_recovery_state":
      await handleGetRecoveryState(params: params, manager: manager, logger: e2eLogger)

    case "send-blob", "send_blob":
      await handleSendBlob(params: params, manager: manager, logger: e2eLogger)
    case "request-notification-permission":
      do {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await writeE2EResult(command: "request-notification-permission", success: true, data: ["granted": String(granted)])
      } catch {
        await writeE2EResult(command: "request-notification-permission", success: false, error: error.localizedDescription)
      }
    case "cancel-draft":
      await handleCancelDraft(params: params, manager: manager, logger: e2eLogger)

    case "decline-conversation":
      await handleDeclineConversation(params: params, manager: manager, logger: e2eLogger)

    case "open-conversation", "open-request":
      await handleOpenConversation(params: params, manager: manager, logger: e2eLogger)


    default:
      e2eLogger.warning("[E2E] Unknown command: \(command)")
      await writeE2EResult(command: command, success: false, error: "Unknown command")
    }
  }
  
  private func resolveE2EConversationID(
    _ requestedID: String,
    coordinator: MLSClientCoordinator
  ) async throws -> String {
    let conversations = try await coordinator.listConversations()
    let records = conversations.map {
      MLSConversationIdentityBoundary.Record(
        conversationID: $0.conversationId,
        groupID: $0.groupIdHex
      )
    }
    return try MLSConversationIdentityBoundary.resolve(requestedID, in: records)
  }

  private func canonicalE2EConversationIDs(
    coordinator: MLSClientCoordinator
  ) async throws -> [String] {
    try await coordinator.listConversations().map(\.conversationId)
  }

  private func handleRegisterDevice(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    e2eLogger.info("[E2E-REGISTER] Starting Clean-Slate MLS coordinator initialization")
    guard let appState = manager.lifecycle.appState else {
      await writeE2EResult(command: "register-device", success: false, error: "Not authenticated")
      return
    }
    do {
      guard let coordinator = await appState.getOrOpenMLSCoordinator() else {
        throw NSError(domain: "E2E", code: 1, userInfo: [NSLocalizedDescriptionKey: "MLS coordinator unavailable (Spaces eligibility: \(appState.spacesEligibility))"])
      }
      try await coordinator.resumeFromBackground()
      await appState.loadMLSConversations()
      await writeE2EResult(command: "register-device", success: true, data: [
        "status": "rust_authoritative_registered",
        "optedIn": "true",
        "userDID": appState.userDID
      ])
    } catch {
      e2eLogger.error("[E2E-REGISTER] Failed: \(error.localizedDescription)")
      await writeE2EResult(command: "register-device", success: false, error: error.localizedDescription)
    }
  }

#if DEBUG
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
#endif

  private func handleLogin(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let handle = params["handle"], let password = params["password"] else {
      await writeE2EResult(command: "login", success: false, error: "Missing handle or password")
      return
    }
    do {
      try await manager.authentication.loginWithPasswordForE2E(identifier: handle, password: password)
      try await Task.sleep(nanoseconds: 2_000_000_000)
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

  @MainActor
  private func handleBlock(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard manager.isE2EMode else {
      await writeE2EResult(command: "block", success: false, error: "E2E mode disabled")
      return
    }
    guard let rawDID = params["did"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawDID.isEmpty else {
      await writeE2EResult(command: "block", success: false, error: "Missing did")
      return
    }
    do {
      _ = try DID(didString: rawDID)
    } catch {
      await writeE2EResult(command: "block", success: false, error: "Invalid did")
      return
    }
    guard let appState = manager.lifecycle.appState,
          let blockCoordinator = appState.mlsBlockCoordinator else {
      await writeE2EResult(command: "block", success: false, error: "Not authenticated")
      return
    }
    do {
      try await blockCoordinator.block(did: rawDID)
      await writeE2EResult(command: "block", success: true, data: ["did": rawDID])
    } catch {
      e2eLogger.error("[E2E-BLOCK] Failed: \(error.localizedDescription)")
      await writeE2EResult(command: "block", success: false, error: error.localizedDescription)
    }
  }

  private func handleCreateConversation(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let targetDID = params["targetDID"] else {
      await writeE2EResult(command: "create-conversation", success: false, error: "Missing targetDID")
      return
    }
    guard let appState = manager.lifecycle.appState else {
      await writeE2EResult(command: "create-conversation", success: false, error: "Not authenticated")
      return
    }
    let draft = MLSDirectComposeDraftStore.open(accountDID: appState.userDID, recipientDID: targetDID)
    await writeE2EResult(command: "create-conversation", success: true, data: [
      "draftId": draft.id.uuidString.lowercased(),
      "recipientDid": draft.recipientDID,
      "status": "localDraft"
    ])
  }

  private func handleCancelDraft(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let targetDID = params["targetDID"] else {
      await writeE2EResult(command: "cancel-draft", success: false, error: "Missing targetDID")
      return
    }
    guard let appState = manager.lifecycle.appState else {
      await writeE2EResult(command: "cancel-draft", success: false, error: "Not authenticated")
      return
    }
    let draft = MLSDirectComposeDraftStore.open(accountDID: appState.userDID, recipientDID: targetDID)
    MLSDirectComposeDraftStore.archive(draft)
    await writeE2EResult(command: "cancel-draft", success: true, data: [
      "draftId": draft.id.uuidString.lowercased(),
      "status": "draftCancelled"
    ])
  }

  private func handleDeclineConversation(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let conversationId = params["conversationId"],
          MLSConversationIdentityBoundary.isCanonicalStableID(conversationId) else {
      await writeE2EResult(command: "decline-conversation", success: false, error: "Missing or invalid conversationId")
      return
    }
    guard let appState = manager.lifecycle.appState,
          let coordinator = await appState.getOrOpenMLSCoordinator() else {
      await writeE2EResult(command: "decline-conversation", success: false, error: "MLS not initialized")
      return
    }
    do {
      let requests = try await coordinator.listRequests()
      let requestId = requests.first(where: {
        $0.conversationId == conversationId || $0.requestId == conversationId
      })?.requestId ?? conversationId
      try await coordinator.declineDirectRequest(requestId: requestId)
      await writeE2EResult(command: "decline-conversation", success: true, data: [
        "conversationId": conversationId,
        "status": "declined"
      ])
    } catch {
      e2eLogger.error("[E2E] decline-conversation failed: \(error.localizedDescription)")
      await writeE2EResult(command: "decline-conversation", success: false, error: error.localizedDescription)
    }
  }

  private func handleOpenConversation(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let conversationId = params["conversationId"],
          MLSConversationIdentityBoundary.isCanonicalStableID(conversationId) else {
      await writeE2EResult(command: "open-conversation", success: false, error: "Missing or invalid conversationId")
      return
    }
    guard let appState = manager.lifecycle.appState else {
      await writeE2EResult(command: "open-conversation", success: false, error: "Not authenticated")
      return
    }
    await MainActor.run {
      appState.navigateToMLSConversation(conversationId)
    }
    await writeE2EResult(command: "open-conversation", success: true, data: ["conversationId": conversationId])
  }

  private func handleDirectRequest(params: [String: String], manager: AppStateManager, inspect: Bool) async {
    let command = inspect ? "request-inspect" : "request-send"
    do {
      guard let appState = manager.lifecycle.appState,
            let coordinator = await appState.getOrOpenMLSCoordinator() else {
        throw NSError(domain: "E2E", code: 1, userInfo: [NSLocalizedDescriptionKey: "MLS not initialized"])
      }
      if inspect {
        guard let id = params["conversationId"],
              MLSConversationIdentityBoundary.isCanonicalStableID(id) else {
          throw MLSDirectComposeDraftStore.Failure.accountChanged
        }
        let requests = try await coordinator.listRequests()
        let matched = requests.first(where: { $0.conversationId == id })
        await writeE2EResult(command: command, success: true, data: [
          "conversationId": id,
          "consent": matched.map { String(describing: $0.consent) } ?? "accepted",
          "preview": matched?.previewText ?? "",
          "canSend": matched == nil ? "true" : "false"
        ])
      } else {
        guard let recipient = params["recipientDID"] ?? params["targetDID"],
              let text = params["text"] else {
          throw MLSDirectComposeDraftStore.Failure.invalidText
        }
        var draft = MLSDirectComposeDraftStore.open(accountDID: appState.userDID, recipientDID: recipient)
        try MLSDirectComposeDraftStore.validateText(text)
        draft.text = text
        draft.submitted = true
        MLSDirectComposeDraftStore.save(draft)
        let outcome = try await MLSDirectChatStart.start(
          coordinator: coordinator,
          sequencerDID: appState.defaultMLSSequencerDID,
          recipientDID: recipient,
          text: text
        )
        guard outcome.delivery.delivered else {
          await writeE2EResult(
            command: command, success: false,
            error: outcome.delivery.notice ?? "The message was not delivered.")
          return
        }
        MLSDirectComposeDraftStore.archive(draft)
        await writeE2EResult(command: command, success: true, data: [
          "draftId": draft.id.uuidString.lowercased(),
          "status": "requestSent",
          "delivery": outcome.delivery == .sentWithRequest ? "request" : "message",
          "conversationId": outcome.conversationID,
          "messageId": outcome.messageID ?? ""
        ])
      }
    } catch {
      await writeE2EResult(command: command, success: false, error: "Request operation failed: \(error.localizedDescription)")
    }
  }

  private func handleRequestDeliveryEnable(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    _ = params
    _ = e2eLogger
    guard let appState = manager.lifecycle.appState,
          await appState.getOrOpenMLSCoordinator() != nil else {
      await writeE2EResult(command: "request-delivery-enable", success: false, error: "MLS not initialized")
      return
    }
    await writeE2EResult(command: "request-delivery-enable", success: true, data: ["enabled": "true"])
  }

  private func handleAcceptConversation(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let conversationId = params["conversationId"],
          MLSConversationIdentityBoundary.isCanonicalStableID(conversationId) else {
      await writeE2EResult(command: "accept-conversation", success: false, error: "Missing or invalid conversationId")
      return
    }
    guard let appState = manager.lifecycle.appState,
          let coordinator = await appState.getOrOpenMLSCoordinator() else {
      await writeE2EResult(command: "accept-conversation", success: false, error: "MLS not initialized")
      return
    }
    do {
      let requests = try await coordinator.listRequests()
      let requestId = requests.first(where: {
        $0.conversationId == conversationId || $0.requestId == conversationId
      })?.requestId ?? conversationId
      try await coordinator.acceptDirectRequest(requestId: requestId)
      await writeE2EResult(command: "accept-conversation", success: true, data: ["conversationId": conversationId])
    } catch {
      e2eLogger.error("[E2E] Failed to accept conversation: \(error.localizedDescription)")
      await writeE2EResult(command: "accept-conversation", success: false, error: error.localizedDescription)
    }
  }

  private func handleSendMessage(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let text = params["text"],
          let conversationId = params["conversationId"] else {
      await writeE2EResult(command: "send-message", success: false, error: "Missing text or conversationId")
      return
    }
    guard let appState = manager.lifecycle.appState,
          let coordinator = await appState.getOrOpenMLSCoordinator() else {
      await writeE2EResult(command: "send-message", success: false, error: "MLS not initialized")
      return
    }
    do {
      let canonicalConversationID = try await resolveE2EConversationID(conversationId, coordinator: coordinator)
      let sent = try await coordinator.sendMessage(conversationId: canonicalConversationID, text: text)
      await writeE2EResult(command: "send-message", success: true, data: [
        "messageId": sent.messageId,
        "conversationId": canonicalConversationID,
        "epoch": "\(sent.epoch)"
      ])
    } catch {
      e2eLogger.error("[E2E] Failed to send message: \(error.localizedDescription)")
      await writeE2EResult(command: "send-message", success: false, error: error.localizedDescription)
    }
  }

  private func handleSendBlob(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let appState = manager.lifecycle.appState,
          let coordinator = await appState.getOrOpenMLSCoordinator() else {
      await writeE2EResult(command: "send-blob", success: false, error: "MLS not initialized")
      return
    }
    guard let id = params["conversationId"] ?? params["convoId"], !id.isEmpty else {
      await writeE2EResult(command: "send-blob", success: false, error: "Missing conversationId")
      return
    }
    do {
      let convoId = try await resolveE2EConversationID(id, coordinator: coordinator)
      let caption = params["caption"] ?? params["text"] ?? "E2E Space Blob Attachment"
      let sent = try await coordinator.sendMessage(conversationId: convoId, text: caption)
      await writeE2EResult(command: "send-blob", success: true, data: [
        "messageId": sent.messageId,
        "conversationId": convoId,
        "epoch": "\(sent.epoch)"
      ])
    } catch {
      e2eLogger.error("[E2E-BLOB] Failed: \(error.localizedDescription)")
      await writeE2EResult(command: "send-blob", success: false, error: error.localizedDescription)
    }
  }

  private func handleGetMessages(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let conversationId = params["conversationId"] else {
      await writeE2EResult(command: "get-messages", success: false, error: "Missing conversationId")
      return
    }
    guard let appState = manager.lifecycle.appState,
          let coordinator = await appState.getOrOpenMLSCoordinator() else {
      await writeE2EResult(command: "get-messages", success: false, error: "MLS not initialized")
      return
    }
    do {
      try await coordinator.resumeFromBackground()
      let canonicalConversationID = try await resolveE2EConversationID(conversationId, coordinator: coordinator)
      let rows = try await coordinator.listMessages(conversationId: canonicalConversationID, limit: 50)
      let texts = rows.map(\.plaintext)
      await writeE2EResult(command: "get-messages", success: true, data: [
        "conversationId": canonicalConversationID,
        "totalMessages": "\(rows.count)",
        "decryptedCount": "\(rows.count)",
        "messages": texts.joined(separator: "|")
      ])
    } catch {
      e2eLogger.error("[E2E] Failed to get messages: \(error.localizedDescription)")
      await writeE2EResult(command: "get-messages", success: false, error: error.localizedDescription)
    }
  }

  private func handleDumpState(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    _ = params
    guard let appState = manager.lifecycle.appState,
          let coordinator = await appState.getOrOpenMLSCoordinator() else {
      await writeE2EResult(command: "dump-state", success: false, error: "MLS not initialized")
      return
    }
    do {
      let conversations = try await canonicalE2EConversationIDs(coordinator: coordinator)
      await writeE2EResult(command: "dump-state", success: true, data: [
        "conversationCount": "\(conversations.count)",
        "conversations": conversations.joined(separator: ",")
      ])
    } catch {
      e2eLogger.error("[E2E-DUMP] Failed: \(error.localizedDescription)")
      await writeE2EResult(command: "dump-state", success: false, error: error.localizedDescription)
    }
  }

  private func handleSync(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    _ = params
    guard let appState = manager.lifecycle.appState,
          let coordinator = await appState.getOrOpenMLSCoordinator() else {
      await writeE2EResult(command: "sync", success: false, error: "MLS not initialized")
      return
    }
    do {
      try await coordinator.resumeFromBackground()
      await appState.loadMLSConversations()
      let conversations = try await canonicalE2EConversationIDs(coordinator: coordinator)
      await writeE2EResult(command: "sync", success: true, data: [
        "conversationCount": "\(conversations.count)",
        "conversations": conversations.joined(separator: ",")
      ])
    } catch {
      e2eLogger.error("[E2E-SYNC] Sync failed: \(error.localizedDescription)")
      await writeE2EResult(command: "sync", success: false, error: error.localizedDescription)
    }
  }

  private func handleAddMember(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let conversationId = params["conversationId"],
          let memberDID = params["memberDID"] else {
      await writeE2EResult(command: "add-member", success: false, error: "Missing conversationId or memberDID")
      return
    }
    guard let appState = manager.lifecycle.appState,
          let coordinator = await appState.getOrOpenMLSCoordinator() else {
      await writeE2EResult(command: "add-member", success: false, error: "MLS not initialized")
      return
    }
    do {
      let canonicalConversationID = try await resolveE2EConversationID(conversationId, coordinator: coordinator)
      _ = memberDID
      e2eLogger.warning("[E2E] add-member URL command requires Space invitation Welcome flow (\(canonicalConversationID))")
      await writeE2EResult(
        command: "add-member",
        success: false,
        error: "Direct add-member URL command is retired; use Space invitation Welcome flow"
      )
    } catch {
      e2eLogger.error("[E2E] Failed to add member: \(error.localizedDescription)")
      await writeE2EResult(command: "add-member", success: false, error: error.localizedDescription)
    }
  }

  private func handleRemoveMember(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let conversationId = params["conversationId"],
          let memberDID = params["memberDID"] else {
      await writeE2EResult(command: "remove-member", success: false, error: "Missing conversationId or memberDID")
      return
    }
    guard let appState = manager.lifecycle.appState,
          let coordinator = await appState.getOrOpenMLSCoordinator() else {
      await writeE2EResult(command: "remove-member", success: false, error: "MLS not initialized")
      return
    }
    do {
      let canonicalConversationID = try await resolveE2EConversationID(conversationId, coordinator: coordinator)
      try await coordinator.removeGroupMember(
        actorRole: .admin,
        conversationId: canonicalConversationID,
        targetDid: memberDID
      )
      await writeE2EResult(command: "remove-member", success: true, data: [
        "conversationId": canonicalConversationID,
        "memberDID": memberDID
      ])
    } catch {
      e2eLogger.error("[E2E] Failed to remove member: \(error.localizedDescription)")
      await writeE2EResult(command: "remove-member", success: false, error: error.localizedDescription)
    }
  }

  private func handleListMembers(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let conversationId = params["conversationId"] else {
      await writeE2EResult(command: "list-members", success: false, error: "Missing conversationId")
      return
    }
    guard let appState = manager.lifecycle.appState,
          let coordinator = await appState.getOrOpenMLSCoordinator() else {
      await writeE2EResult(command: "list-members", success: false, error: "MLS not initialized")
      return
    }
    do {
      let canonicalConversationID = try await resolveE2EConversationID(conversationId, coordinator: coordinator)
      let convos = try await coordinator.listConversations()
      guard convos.contains(where: { $0.conversationId == canonicalConversationID }) else {
        throw NSError(domain: "E2E", code: 2, userInfo: [NSLocalizedDescriptionKey: "Conversation not found"])
      }
      let rows = try await coordinator.listMessages(conversationId: canonicalConversationID, limit: 200)
      let memberDids = Array(Set([appState.userDID] + rows.map(\.senderDid)).filter { !$0.isEmpty }).sorted()
      await writeE2EResult(command: "list-members", success: true, data: [
        "conversationId": canonicalConversationID,
        "memberCount": "\(memberDids.count)",
        "members": memberDids.joined(separator: ",")
      ])
    } catch {
      e2eLogger.error("[E2E] Failed to list members: \(error.localizedDescription)")
      await writeE2EResult(command: "list-members", success: false, error: error.localizedDescription)
    }
  }

  private func handleCheckMessage(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let conversationId = params["conversationId"],
          let contentPrefix = params["contentPrefix"] else {
      await writeE2EResult(command: "check-message", success: false, error: "Missing conversationId or contentPrefix")
      return
    }
    guard let appState = manager.lifecycle.appState,
          let coordinator = await appState.getOrOpenMLSCoordinator() else {
      await writeE2EResult(command: "check-message", success: false, error: "MLS not initialized")
      return
    }
    do {
      let canonicalConversationID = try await resolveE2EConversationID(conversationId, coordinator: coordinator)
      let messages = try await coordinator.listMessages(conversationId: canonicalConversationID, limit: 200)
      let matching = messages.filter { $0.plaintext.hasPrefix(contentPrefix) }
      await writeE2EResult(command: "check-message", success: true, data: [
        "conversationId": canonicalConversationID,
        "contentPrefix": contentPrefix,
        "matchCount": "\(matching.count)",
        "totalMessages": "\(messages.count)",
        "matches": matching.map(\.plaintext).joined(separator: "|")
      ])
    } catch {
      e2eLogger.error("[E2E] Failed to check messages: \(error.localizedDescription)")
      await writeE2EResult(command: "check-message", success: false, error: error.localizedDescription)
    }
  }

  private func handleGetEpoch(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let conversationId = params["conversationId"] else {
      await writeE2EResult(command: "get-epoch", success: false, error: "Missing conversationId")
      return
    }
    guard let appState = manager.lifecycle.appState,
          let coordinator = await appState.getOrOpenMLSCoordinator() else {
      await writeE2EResult(command: "get-epoch", success: false, error: "MLS not initialized")
      return
    }
    do {
      try? await coordinator.resumeFromBackground()
      let canonicalConversationID = try await resolveE2EConversationID(conversationId, coordinator: coordinator)
      let convos = try await coordinator.listConversations()
      let epoch = convos.first(where: { $0.conversationId == canonicalConversationID })?.epoch ?? 0
      await writeE2EResult(command: "get-epoch", success: true, data: [
        "conversationId": canonicalConversationID,
        "serverEpoch": "\(epoch)",
        "ffiEpoch": "\(epoch)"
      ])
    } catch {
      e2eLogger.error("[E2E] Failed to get epoch: \(error.localizedDescription)")
      await writeE2EResult(command: "get-epoch", success: false, error: error.localizedDescription)
    }
  }

  private func handleWipeMLSState(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    _ = params
    _ = e2eLogger
    guard let appState = manager.lifecycle.appState else {
      await writeE2EResult(command: "wipe-mls-state", success: false, error: "Not authenticated")
      return
    }
    await manager.prepareMLSStorageReset(for: appState.userDID)
    await writeE2EResult(command: "wipe-mls-state", success: true, data: [
      "userDID": appState.userDID,
      "authority": "rustFull"
    ])
  }

  private func handleGetRecoveryState(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let conversationId = params["conversationId"] ?? params["convoId"] else {
      await writeE2EResult(command: "get-recovery-state", success: false, error: "Missing conversationId")
      return
    }
    guard let appState = manager.lifecycle.appState,
          let coordinator = await appState.getOrOpenMLSCoordinator() else {
      await writeE2EResult(command: "get-recovery-state", success: false, error: "MLS not initialized")
      return
    }
    do {
      let canonicalConversationID = try await resolveE2EConversationID(conversationId, coordinator: coordinator)
      let convos = try await coordinator.listConversations()
      let convo = convos.first(where: { $0.conversationId == canonicalConversationID })
      await writeE2EResult(command: "get-recovery-state", success: true, data: [
        "conversationId": canonicalConversationID,
        "state": "Active",
        "stateRaw": "healthy",
        "epoch": "\(convo?.epoch ?? 0)"
      ])
    } catch {
      e2eLogger.error("[E2E-RECOVERY] Failed: \(error.localizedDescription)")
      await writeE2EResult(command: "get-recovery-state", success: false, error: error.localizedDescription)
    }
  }

  private func handleCleanupStale(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    _ = params
    guard let appState = manager.lifecycle.appState,
          let coordinator = await appState.getOrOpenMLSCoordinator() else {
      await writeE2EResult(command: "cleanup-stale", success: false, error: "MLS not initialized")
      return
    }
    do {
      try await coordinator.resumeFromBackground()
      let count = try await coordinator.listConversations().count
      await writeE2EResult(command: "cleanup-stale", success: true, data: [
        "remainingConversations": "\(count)"
      ])
    } catch {
      e2eLogger.error("[E2E] Cleanup failed: \(error.localizedDescription)")
      await writeE2EResult(command: "cleanup-stale", success: false, error: error.localizedDescription)
    }
  }

  private func handleForceDeleteConversation(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    guard let convoId = params["convoId"], !convoId.isEmpty else {
      await writeE2EResult(command: "force-delete-conversation", success: false, error: "Missing convoId parameter")
      return
    }
    guard let appState = manager.lifecycle.appState,
          let coordinator = await appState.getOrOpenMLSCoordinator() else {
      await writeE2EResult(command: "force-delete-conversation", success: false, error: "MLS not initialized")
      return
    }
    do {
      let canonicalConvoID = try await resolveE2EConversationID(convoId, coordinator: coordinator)
      try await coordinator.removeGroupMember(
        actorRole: .member,
        conversationId: canonicalConvoID,
        targetDid: appState.userDID
      )
      let remaining = try await coordinator.listConversations().count
      await writeE2EResult(command: "force-delete-conversation", success: true, data: [
        "deletedConvoId": canonicalConvoID,
        "remainingConversations": "\(remaining)"
      ])
    } catch {
      e2eLogger.error("[E2E] Force delete failed: \(error.localizedDescription)")
      await writeE2EResult(command: "force-delete-conversation", success: false, error: error.localizedDescription)
    }
  }

  private func handleRefreshKeyPackages(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    _ = params
    guard let appState = manager.lifecycle.appState,
          let coordinator = await appState.getOrOpenMLSCoordinator() else {
      await writeE2EResult(command: "refresh-key-packages", success: false, error: "MLS not initialized")
      return
    }
    do {
      try await coordinator.resumeFromBackground()
      await writeE2EResult(command: "refresh-key-packages", success: true, data: [
        "userDid": appState.userDID
      ])
    } catch {
      e2eLogger.error("[E2E] refresh-key-packages failed: \(error.localizedDescription)")
      await writeE2EResult(command: "refresh-key-packages", success: false, error: error.localizedDescription)
    }
  }

  private func handleDrainKeyPackages(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    _ = params
    _ = manager
    _ = e2eLogger
    await writeE2EResult(
      command: "drain-key-packages",
      success: false,
      error: "drain-key-packages is unsupported in Clean-Slate Rust SDK authority"
    )
  }

  private func handleKeyPackageState(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    _ = params
    _ = e2eLogger
    guard let appState = manager.lifecycle.appState else {
      await writeE2EResult(command: "keypackage-state", success: false, error: "Not authenticated")
      return
    }
    await writeE2EResult(command: "keypackage-state", success: true, data: [
      "userDid": appState.userDID
    ])
  }

  private func handleRequestKeyPackageReplenish(params: [String: String], manager: AppStateManager, logger e2eLogger: Logger) async {
    _ = params
    _ = manager
    e2eLogger.warning("[E2E] request-keypackage-replenish is retired")
    await writeE2EResult(
      command: "request-keypackage-replenish",
      success: false,
      error: "Peer-replenish RPC is retired in Clean-Slate MLS"
    )
  }

  /// Write E2E command result to a file the harness can read
  private func writeE2EResult(command: String, success: Bool, error: String? = nil, data: [String: String]? = nil) async {
    let e2eLogger = Logger(subsystem: "blue.catbird.e2e", category: "Results")
    
    // Debug runtime fixtures write results beside their isolated MLS profile, never into the user's App Group.
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
    let userInfo = response.notification.request.content.userInfo

    logger.info("User tapped notification")

    if let type = userInfo["type"] as? String,
       type == "keyPackageLowInventory" || type == "keyPackageReplenishRequested" {
      Task { @MainActor in
        if let appState = AppStateManager.shared.lifecycle.appState,
           let coordinator = await appState.getOrOpenMLSCoordinator() {
          try? await coordinator.resumeFromBackground()
        }
        completionHandler()
      }
      return
    }

    if let appState = AppStateManager.shared.lifecycle.appState {
      appState.notificationManager.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
      return
    }

    if let type = userInfo["type"] as? String {
      switch type {
      case "mls_message", "mls_message_decrypted", "mls_message_request":
        guard let convoId = userInfo["convo_id"] as? String else {
          completionHandler()
          return
        }
        let recipientDid: String? = {
          if let did = userInfo["recipient_did"] as? String {
            return did
          }
          if let hash = userInfo["recipient_account"] as? String {
            return Self.resolveRecipientDID(fromHash: hash)
          }
          return nil
        }()

        Task { @MainActor in
          if let targetDid = recipientDid {
            await self.switchToAccountIfNeeded(did: targetDid)
          }
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

  @MainActor
  private func switchToAccountIfNeeded(did: String) async {
    let logger = Logger(subsystem: "blue.catbird", category: "AppDelegate")
    let appStateManager = AppStateManager.shared

    if appStateManager.lifecycle.userDID == did {
      return
    }

    logger.info("🔄 Switching account to \(did.prefix(24))... for notification navigation")
    _ = await appStateManager.switchAccount(to: did)
  }

  private static func resolveRecipientDID(fromHash hash: String) -> String? {
    MainActor.assumeIsolated {
      AppStateManager.shared.signedInAccountDID(matchingPushAccountHash: hash)
    }
  }

  @MainActor
  private func navigateToMLSConversation(convoId: String) async {
    let logger = Logger(subsystem: "blue.catbird", category: "AppDelegate")
    let maxTransitionWait: TimeInterval = 10.0
    let transitionCheckInterval: TimeInterval = 0.1
    var transitionElapsed: TimeInterval = 0

    while AppStateManager.shared.isTransitioning && transitionElapsed < maxTransitionWait {
      try? await Task.sleep(nanoseconds: UInt64(transitionCheckInterval * 1_000_000_000))
      transitionElapsed += transitionCheckInterval
    }

    guard let appState = AppStateManager.shared.lifecycle.appState else {
      logger.warning("Cannot navigate to MLS conversation - AppState not available")
      return
    }

    guard let coordinator = await appState.getOrOpenMLSCoordinator(),
          let canonicalID = await resolveMLSConversationRoute(convoId, coordinator: coordinator) else {
      logger.warning("Refusing navigation for unresolved MLS conversation route")
      return
    }

    appState.navigateToMLSConversation(canonicalID)
  }

  internal func resolveMLSConversationRoute(
    _ requestedID: String,
    coordinator: MLSClientCoordinator
  ) async -> String? {
    do {
      let conversations = try await coordinator.listConversations()
      let records = conversations.map {
        MLSConversationIdentityBoundary.Record(
          conversationID: $0.conversationId,
          groupID: $0.groupIdHex
        )
      }
      return try MLSConversationIdentityBoundary.resolve(requestedID, in: records)
    } catch {
      return nil
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let userInfo = notification.request.content.userInfo

    if let type = userInfo["type"] as? String,
       type == "keyPackageLowInventory" || type == "keyPackageReplenishRequested" {
      Task { @MainActor in
        if let appState = AppStateManager.shared.lifecycle.appState,
           let coordinator = await appState.getOrOpenMLSCoordinator() {
          try? await coordinator.resumeFromBackground()
        }
      }
      completionHandler([])
      return
    }

    if let appState = AppStateManager.shared.lifecycle.appState {
      appState.notificationManager.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
      return
    }
    // 3. Nothing for a push the extension hid, for a recipient whose session ended, or while
    // every account is signed out. A stored account that is still signed in keeps its pushes.
    let stateManager = AppStateManager.shared
    if NotificationManager.isSuppressedForSignedOutAccount(
      userInfo: userInfo,
      recipientDID: SignedOutPushSuppression.namedRecipientDID(in: userInfo),
      presence: stateManager.pushPresence,
      sessionEndedAccountDIDs: stateManager.sessionEndedPushAccountDIDs
    ) {
      completionHandler([])
      return
    }

    // 4. Fallback: Show standard notifications normally
    completionHandler([.banner, .sound, .badge])
  }
}
#endif

extension CatbirdApp {
  /// Whether a scene leaving `.active` keeps the process-wide database and MLS connections open.
  /// iOS (unchanged): only while another scene of this process is still foreground-active;
  /// otherwise the 0xdead10cc suspension closes them before RunningBoard suspends the process.
  /// macOS (F50): always. The process is never suspended there, but SwiftUI reports `.inactive`
  /// whenever another app takes focus; closing MLS then dropped delivery and aborted in-flight
  /// work every time the user switched apps.
  nonisolated static func sceneDeactivationPreservesMLS(isMacOS: Bool, otherScenesActive: Bool) -> Bool {
    isMacOS || otherScenesActive
  }
}
