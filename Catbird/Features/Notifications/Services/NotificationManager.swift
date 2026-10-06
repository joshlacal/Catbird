import CryptoKit
import Foundation
import Nuke
import OSLog
import Petrel
import SwiftData
import SwiftUI
import UserNotifications
import WidgetKit

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

/// Data structure for sharing notification count with the widget
struct NotificationWidgetData: Codable {
  let count: Int
  let lastUpdated: Date
}

/// Manages push notifications registration and handling for the Catbird app
@Observable
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
  /// Captured before account switching or network resolution can suspend.
  private struct NavigationTarget: Sendable {
    let accountDID: String
    let preferredSceneID: UUID?
  }

  @MainActor
  private func captureNavigationTarget(accountDID: String?) -> NavigationTarget? {
    guard let accountDID = accountDID ?? AppStateManager.shared.lifecycle.userDID else { return nil }
    return NavigationTarget(accountDID: accountDID,
      preferredSceneID: SceneRouteCoordinator.shared.preferredSceneIDForExternalEvent())
  }

  // MARK: - Properties

  /// Logger for notification-related events
  private let notificationLogger = Logger(subsystem: "blue.catbird", category: "Notifications")

  /// The AT Protocol client for API calls
  private var client: ATProtoClient?

  /// Reference to the app state for navigation
  private weak var appState: AppState?

  /// Model context for SwiftData cache operations
  @ObservationIgnored private var modelContext: ModelContext?

  /// Device token for APNS
  private(set) var deviceToken: Data?

  /// Records the last device token that successfully completed registration to avoid redundant work.
  @ObservationIgnored private var lastRegisteredDeviceToken: Data?

  /// Coordinates registration attempts so only one runs at a time.
  @ObservationIgnored private let registrationCoordinator = RegistrationCoordinator()

  /// Whether push notifications are enabled by the user
  private(set) var notificationsEnabled = false

  /// Current status of notifications
  enum NotificationStatus {
    case unknown
    case disabled
    case waitingForPermission
    case permissionDenied
    case registered
    case registrationFailed(Error)

    static func == (lhs: NotificationStatus, rhs: NotificationStatus) -> Bool {
      switch (lhs, rhs) {
      case (.unknown, .unknown), (.disabled, .disabled),
        (.waitingForPermission, .waitingForPermission),
        (.permissionDenied, .permissionDenied), (.registered, .registered):
        return true
      case (.registrationFailed(let error1), (.registrationFailed(let error2))):
        return error1.localizedDescription == error2.localizedDescription
      default:
        return false
      }
    }
  }

  enum NotificationServiceError: Error, LocalizedError {
    case clientUnavailable
    case clientNotConfigured
    case deviceTokenNotAvailable
    case serverError(String)

    var errorDescription: String? {
      switch self {
      case .clientUnavailable:
        return "Network client not available"
      case .clientNotConfigured:
        return "Network client not configured"
      case .deviceTokenNotAvailable:
        return "Device token not available"
      case .serverError(let message):
        return message
      }
    }

    var recoverySuggestion: String? {
      switch self {
      case .deviceTokenNotAvailable:
        return "Please try disabling and re-enabling notifications."
      case .clientUnavailable, .clientNotConfigured:
        return "Please try signing out and signing back in."
      default:
        return nil
      }
    }
  }

  /// Preferences fetch request with flattened App Attest proof.
  struct PreferencesQueryPayload: Codable {
    let did: String
    let deviceToken: String

    enum CodingKeys: String, CodingKey {
      case did
      case deviceToken = "device_token"
    }
  }

  /// Relationships update request with flattened App Attest proof.
  struct RelationshipsUpdatePayload: Codable {
    let did: String
    let deviceToken: String
    let mutes: [String]
    let blocks: [String]

    enum CodingKeys: String, CodingKey {
      case did
      case deviceToken = "device_token"
      case mutes
      case blocks
    }
  }

  /// Activity subscription upsert payload sent to the notification server.
  struct ActivitySubscriptionUpsertPayload: Codable {
    let did: String
    let deviceToken: String
    let subjectDid: String
    let includePosts: Bool
    let includeReplies: Bool

    enum CodingKeys: String, CodingKey {
      case did
      case deviceToken = "device_token"
      case subjectDid = "subject_did"
      case includePosts = "include_posts"
      case includeReplies = "include_replies"
    }
  }

  /// Activity subscription query payload used when listing from the notification server.
  struct ActivitySubscriptionFetchPayload: Codable {
    let did: String
    let deviceToken: String

    enum CodingKeys: String, CodingKey {
      case did
      case deviceToken = "device_token"
    }
  }

  /// Activity subscription delete payload sent to the notification server.
  struct ActivitySubscriptionDeletePayload: Codable {
    let did: String
    let deviceToken: String
    let subjectDid: String

    enum CodingKeys: String, CodingKey {
      case did
      case deviceToken = "device_token"
      case subjectDid = "subject_did"
    }
  }

  /// Activity subscription entry returned from the notification server.
  struct ActivitySubscriptionServerRecord: Decodable {
    let subjectDid: String
    let includePosts: Bool
    let includeReplies: Bool
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
      case subjectDid = "subject_did"
      case includePosts = "include_posts"
      case includeReplies = "include_replies"
      case updatedAt = "updated_at"
    }
  }

  /// Current status of notification setup
  private(set) var status: NotificationStatus = .unknown

  /// Notification preferences
  private(set) var preferences = NotificationPreferences()

  enum PreferencesState: Equatable {
    case unavailable, loading, ready, saving
    case loadFailed(String), saveFailed(String)
  }

  private(set) var preferencesState: PreferencesState = .unavailable
  private(set) var systemAuthorizationStatus: UNAuthorizationStatus?

  var notificationAccountDID: String? { currentAccountDID }
  var hasConfirmedNotificationPreferences: Bool { serverPreferencesSnapshot != nil }
  var pendingNotificationChangesDescription: String? { failedPreferencesMutation?.input.notificationChangesDescription }

  var systemPermissionSummary: String {
    switch systemAuthorizationStatus {
    case .authorized: return "Allowed"
    case .provisional: return "Quiet delivery"
    case .ephemeral: return "Temporary permission"
    case .denied: return "Off in System Settings"
    case .notDetermined: return "Not requested"
    default: return "Not checked"
    }
  }

  var canEditNotificationPreferences: Bool {
    preferencesState == .ready
  }

  /// Delivery and service preferences have distinct states; neither implies the other is ready.
  var settingsSummary: String {
    switch preferencesState {
    case .loading: return "Loading"
    case .loadFailed: return "Couldn’t load"
    case .saving: return "Saving"
    case .saveFailed: return "Couldn’t save"
    case .unavailable: return "Not connected"
    case .ready: return pushDeliverySummary
    }
  }

  var pushDeliverySummary: String {
    guard isPushRequested else { return "Push paused" }
    switch status {
    case .permissionDenied: return "System permission off"
    case .registrationFailed: return "Connection failed"
    case .waitingForPermission: return "Waiting for permission"
    case .registered: return notificationsEnabled ? "Push ready" : "Push paused"
    case .disabled: return "Push paused"
    case .unknown: return notificationsEnabled ? "Connecting" : "Not set up"
    }
  }

  @ObservationIgnored private let preferencesService: NotificationPreferencesService
  @ObservationIgnored private let accountDIDProvider: (() -> String?)?
  @ObservationIgnored private var failedPreferencesMutation: FailedPreferencesMutation?

  private struct FailedPreferencesMutation {
    let requested: NotificationPreferences
    let input: AppBskyNotificationPutPreferencesV2.Input
    let client: ATProtoClient
    let clientGeneration: UInt64
    let accountDID: String
  }

  /// Dedicated notification namespace routed to the Nest push service.
  private let notificationServiceNamespace = "app.bsky.notification"

  /// DID for the Nest push service that owns notification XRPC.
  private let notificationServiceDIDString: String

  /// Latest server-side notification preferences snapshot.
  @ObservationIgnored
  private var serverPreferencesSnapshot: AppBskyNotificationDefs.Preferences?

  /// Persisted key prefix for per-account push notifications master enable preference
  private let masterPushEnabledDefaultsKeyPrefix = "masterPushNotificationsEnabled"

  /// Persisted key prefix for per-account chat notification preference
  private let chatNotificationsDefaultsKeyPrefix = "chatNotificationsEnabled"

  /// Invalidates asynchronous work when the configured account or client changes.
  @ObservationIgnored private var clientGeneration: UInt64 = 0
  @ObservationIgnored private var chatPreferenceChangeGeneration: UInt64 = 0
  @ObservationIgnored private let notificationDefaults: UserDefaults?

  /// Generation counter for serializing preference mutations
  @ObservationIgnored private var preferenceMutationGeneration: UInt64 = 0
  @ObservationIgnored private var preferenceLoadGeneration: UInt64 = 0
  @ObservationIgnored private var activePreferenceLoadTask: Task<AppBskyNotificationDefs.Preferences, Error>?

  /// Current active mutation task to serialize PUT operations
  @ObservationIgnored private var activePreferenceMutationTask: Task<AppBskyNotificationDefs.Preferences?, Error>?

  /// Prior confirmed snapshot before uncommitted mutations
  @ObservationIgnored private var priorConfirmedPreferences: NotificationPreferences?
  @ObservationIgnored private var priorConfirmedServerSnapshot: AppBskyNotificationDefs.Preferences?

  private var currentAccountDID: String? {
    if let accountDIDProvider { return accountDIDProvider() }
    guard let did = appState?.userDID, !did.isEmpty else { return nil }
    return did
  }

  private func isCurrentNotificationClient(
    _ client: ATProtoClient,
    generation: UInt64,
    accountDID: String
  ) -> Bool {
    !pollingBarrier.isSuspended && self.client === client
      && clientGeneration == generation && currentAccountDID == accountDID
  }

  var isPushRequested: Bool { currentAccountDID != nil && isMasterPushEnabled() }

  /// Checks if push notifications are enabled by the user for the current account
  private func isMasterPushEnabled() -> Bool {
    guard let defaults = notificationDefaults,
      let did = currentAccountDID
    else {
      return true
    }
    let key = "\(masterPushEnabledDefaultsKeyPrefix)_\(did)"
    if defaults.object(forKey: key) != nil {
      return defaults.bool(forKey: key)
    }
    return true
  }

  /// Sets the user-controlled master push preference for the current account
  private func setMasterPushEnabled(_ enabled: Bool) {
    guard let defaults = notificationDefaults,
      let did = currentAccountDID
    else {
      return
    }
    let key = "\(masterPushEnabledDefaultsKeyPrefix)_\(did)"
    defaults.set(enabled, forKey: key)
  }

  /// Whether chat message notifications are enabled locally (per-account)
  var chatNotificationsEnabled: Bool = true {
    didSet {
      guard shouldPersistChatPreference else {
        return
      }
      saveChatNotificationPreference()
    }
  }

  /// Save chat notification preference for the current account.
  private func saveChatNotificationPreference() {
    guard let defaults = notificationDefaults, let did = currentAccountDID, let client else {
      return
    }

    defaults.set(chatNotificationsEnabled, forKey: "\(chatNotificationsDefaultsKeyPrefix)_\(did)")
    chatPreferenceChangeGeneration &+= 1
    let changeGeneration = chatPreferenceChangeGeneration
    let generation = clientGeneration
    let chatEnabled = chatNotificationsEnabled
    Task { [weak self] in
      await self?.syncChatPushPreferenceToServer(
        enabled: chatEnabled, client: client, generation: generation,
        accountDID: did, changeGeneration: changeGeneration
      )
    }
  }

  /// Keep the local delivery gate and stored value aligned without scheduling another PUT.
  private func syncChatNotificationPreferenceFromPreferences() {
    let previousPersist = shouldPersistChatPreference
    shouldPersistChatPreference = false
    chatNotificationsEnabled = preferences.chat.push
    shouldPersistChatPreference = previousPersist
    if let did = currentAccountDID {
      notificationDefaults?.set(
        chatNotificationsEnabled, forKey: "\(chatNotificationsDefaultsKeyPrefix)_\(did)"
      )
    }
  }

  /// Sync a user edit only through the account and client that originated it.
  private func syncChatPushPreferenceToServer(
    enabled: Bool,
    client: ATProtoClient,
    generation: UInt64,
    accountDID: String,
    changeGeneration: UInt64
  ) async {
    guard !Task.isCancelled,
      isCurrentNotificationClient(client, generation: generation, accountDID: accountDID),
      changeGeneration == chatPreferenceChangeGeneration
    else { return }

    if serverPreferencesSnapshot == nil {
      _ = await currentNotificationPreferencesSnapshot(using: client)
    }
    guard !Task.isCancelled,
      isCurrentNotificationClient(client, generation: generation, accountDID: accountDID),
      changeGeneration == chatPreferenceChangeGeneration
    else { return }

    do {
      try await updatePreferences({ updated in
        updated.chat = AppBskyNotificationDefs.ChatPreference(
          include: updated.chat.include, push: enabled
        )
      }, expectedAccountDID: accountDID)
    } catch is CancellationError {
      return
    } catch {
      notificationLogger.error(
        "Failed to sync chat push preference to server: \(error.localizedDescription)"
      )
    }
  }

  /// Load chat notification preference for the current account without triggering didSet sync
  private func loadChatNotificationPreference() {
    let previousPersist = shouldPersistChatPreference
    shouldPersistChatPreference = false
    defer { shouldPersistChatPreference = previousPersist }

    guard !Task.isCancelled, let defaults = notificationDefaults,
      let did = currentAccountDID
    else {
      notificationLogger.debug(
        "Cannot load chat notification preference - client or DID unavailable")
      return
    }

    let key = "\(chatNotificationsDefaultsKeyPrefix)_\(did)"
    if defaults.object(forKey: key) != nil {
      let enabled = defaults.bool(forKey: key)
      notificationLogger.info(
        "Loaded chat notification preference for \(did): \(enabled ? "enabled" : "disabled")")
      chatNotificationsEnabled = enabled
    } else {
      // Default to enabled for accounts that haven't set a preference yet
      notificationLogger.info(
        "No chat notification preference found for \(did), defaulting to enabled")
      chatNotificationsEnabled = true
    }
    preferences.chat = .init(include: preferences.chat.include, push: chatNotificationsEnabled)
  }

  /// Flag to avoid persisting chat preference before it is initially loaded from disk
  @ObservationIgnored
  private var shouldPersistChatPreference = false

  /// Cache of muted users
  private(set) var mutedUsers = Set<String>()

  /// Cache of blocked users
  private(set) var blockedUsers = Set<String>()

  /// When the relationship data was last synced with the server
  private var lastRelationshipSync: Date?

  /// Current count of unread notifications
  var unreadCount: Int = 0

  /// Timer for checking unread notifications
  private var unreadCheckTimer: Timer?
  @ObservationIgnored private let pollingBarrier = AccountPollingBarrier()
  @ObservationIgnored private var unreadCheckTask: Task<Void, Never>?
  @ObservationIgnored private var foregroundCheckTask: Task<Void, Never>?
  @ObservationIgnored private var resumeUnreadChecking = false

  @MainActor
  func suspendForAccountSwitch() async {
    if !pollingBarrier.isSuspended { resumeUnreadChecking = unreadCheckTimer != nil }
    pollingBarrier.suspend(accountDID: currentAccountDID)
    clientGeneration &+= 1
    unreadCheckTimer?.invalidate()
    unreadCheckTimer = nil
    let tasks = [unreadCheckTask, foregroundCheckTask].compactMap { $0 }
    for task in tasks { task.cancel() }
    let mutation = activePreferenceMutationTask
    let preferenceLoad = activePreferenceLoadTask
    preferenceLoad?.cancel()
    mutation?.cancel()
    for task in tasks { await task.value }
    _ = try? await mutation?.value
    _ = try? await preferenceLoad?.value
    await pollingBarrier.drain()
    unreadCheckTask = nil
    foregroundCheckTask = nil
    activePreferenceMutationTask = nil
    activePreferenceLoadTask = nil
    // Canceled optimistic edits retain their last confirmed server/local snapshot.
    if let confirmed = priorConfirmedPreferences {
      preferences = confirmed
      serverPreferencesSnapshot = priorConfirmedServerSnapshot
      syncChatNotificationPreferenceFromPreferences()
    }
    priorConfirmedPreferences = nil
    priorConfirmedServerSnapshot = nil
    failedPreferencesMutation = nil
    preferencesState = serverPreferencesSnapshot == nil ? .unavailable : .ready
  }

  @MainActor
  func resumeAfterInterruptedAccountSwitch(accountDID: String) async -> Bool {
    guard let generation = pollingBarrier.suspensionGeneration,
      currentAccountDID == accountDID, let client
    else { return false }
    let authenticatedDID = try? await client.getDid()
    guard self.client === client, currentAccountDID == accountDID,
      authenticatedDID == accountDID, pollingBarrier.resume(accountDID: accountDID, generation: generation)
    else { return false }
    if resumeUnreadChecking { startUnreadNotificationChecking() }
    resumeUnreadChecking = false
    return true
  }

  @MainActor
  private func scheduleUnreadCheck() {
    guard !pollingBarrier.isSuspended, unreadCheckTask == nil else { return }
    unreadCheckTask = Task { [weak self] in
      guard let self else { return }
      defer { self.unreadCheckTask = nil }
      await self.checkUnreadNotifications()
    }
  }

  // MARK: - Initialization

  init(
    notificationServiceDIDString: String = CatbirdGatewayConfiguration.current.serviceDID,
    notificationDefaults: UserDefaults? = UserDefaults(suiteName: "group.blue.catbird.shared"),
    preferencesService: NotificationPreferencesService = .live,
    accountDIDProvider: (() -> String?)? = nil,
    seedsDebugWidgetData: Bool = true
  ) {
    self.notificationServiceDIDString = notificationServiceDIDString
    self.notificationDefaults = notificationDefaults
    self.preferencesService = preferencesService
    self.accountDIDProvider = accountDIDProvider
    super.init()

    // Chat notification preference will be enabled after initial load in updateClient
    // Initialize widget with a test value to ensure it's populated
    #if DEBUG
      if seedsDebugWidgetData { setupTestWidgetData() }
    #endif

    // Register for app lifecycle notifications to handle token registration
    #if os(iOS)
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(appDidBecomeActive),
        name: UIApplication.didBecomeActiveNotification,
        object: nil
      )
    #elseif os(macOS)
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(appDidBecomeActive),
        name: NSApplication.didBecomeActiveNotification,
        object: nil
      )
    #endif
  }

  /// Configure with app state reference for navigation
  func configure(with appState: AppState) {
    guard !pollingBarrier.isSuspended else { return }
    self.appState = appState
    notificationLogger.debug("NotificationManager configured with AppState reference")

    // Set up observers
    setupGraphObservers()

    // Initialize widget data with current count
    updateWidgetUnreadCount(unreadCount)
  }

  /// Configure with model context for SwiftData cache operations
  func setModelContext(_ context: ModelContext) {
    self.modelContext = context
    notificationLogger.debug("NotificationManager configured with ModelContext for caching")
  }

  // MARK: - Public API

  /// Update the client reference when authentication changes
  @MainActor
  func updateClient(_ newClient: ATProtoClient?) async {
    guard let ticket = pollingBarrier.begin(accountDID: currentAccountDID) else { return }
    defer { pollingBarrier.finish(ticket) }
    let previousClient = client
    clientGeneration &+= 1
    preferenceMutationGeneration &+= 1
    chatPreferenceChangeGeneration &+= 1
    let generation = clientGeneration
    self.client = newClient
    shouldPersistChatPreference = false
    activePreferenceMutationTask?.cancel()
    activePreferenceMutationTask = nil
    activePreferenceLoadTask?.cancel()
    activePreferenceLoadTask = nil
    preferences = NotificationPreferences()
    preferencesState = .unavailable
    failedPreferencesMutation = nil
    serverPreferencesSnapshot = nil
    priorConfirmedPreferences = nil
    priorConfirmedServerSnapshot = nil
    lastRegisteredDeviceToken = nil

    if let newClient {
      guard let did = currentAccountDID, !Task.isCancelled else { return }
      if !isMasterPushEnabled() {
        notificationsEnabled = false
        status = .disabled
      }
      // Stored preferences are the fallback; a successful server refresh is authoritative.
      loadChatNotificationPreference()
      shouldPersistChatPreference = true
      await configureNotificationServiceRouting(on: newClient)
      guard !Task.isCancelled,
        isCurrentNotificationClient(newClient, generation: generation, accountDID: did)
      else { return }
      await refreshNotificationPreferences()
      guard !Task.isCancelled,
        isCurrentNotificationClient(newClient, generation: generation, accountDID: did)
      else { return }
      if let deviceToken {
        if isMasterPushEnabled() {
          await registerDeviceToken(deviceToken)
        }
      }
    } else {
      await cleanupNotifications(previousClient: previousClient)
    }
  }

  private func configureNotificationServiceRouting(on client: ATProtoClient) async {
    let routedEndpoints = [
      "app.bsky.notification.registerPush",
      "app.bsky.notification.unregisterPush",
      "app.bsky.notification.getPreferences",
      "app.bsky.notification.putPreferencesV2",
      "app.bsky.notification.listActivitySubscriptions",
      "app.bsky.notification.putActivitySubscription"
    ]

    for endpoint in routedEndpoints {
      await client.setServiceDID(notificationServiceDIDString, for: endpoint)
    }
  }

  private func notificationServiceDID() throws -> DID {
    try DID(didString: notificationServiceDIDString)
  }

  private var pushPlatform: String {
    #if os(iOS)
      "ios"
    #elseif os(macOS)
      "macos"
    #else
      "ios"
    #endif
  }

  private var pushAppID: String {
    Bundle.main.bundleIdentifier ?? "blue.catbird"
  }

  @MainActor
  func refreshNotificationPreferences(expectedAccountDID: String? = nil) async {
    guard expectedAccountDID == nil || expectedAccountDID == currentAccountDID,
      let client else { return }
    _ = await fetchNotificationPreferences(using: client)
  }

  @MainActor
  func retryNotificationPreferences(expectedAccountDID: String) async {
    guard expectedAccountDID == currentAccountDID else { return }
    if let failed = failedPreferencesMutation {
      guard isCurrentNotificationClient(failed.client, generation: failed.clientGeneration,
        accountDID: failed.accountDID) else { return }
      do {
        _ = try await updatePreferences(failed.requested, expectedAccountDID: failed.accountDID,
          retryInput: failed.input)
      } catch { /* The retained attempt and its error remain available to this account. */ }
    } else {
      await refreshNotificationPreferences(expectedAccountDID: expectedAccountDID)
    }
  }

  @discardableResult
  @MainActor
  func fetchNotificationPreferences(using client: ATProtoClient) async
    -> AppBskyNotificationDefs.Preferences? {
    guard let pollingTicket = pollingBarrier.begin(accountDID: currentAccountDID) else { return nil }
    defer { pollingBarrier.finish(pollingTicket) }
    guard let did = currentAccountDID, self.client === client, !Task.isCancelled,
      activePreferenceMutationTask == nil, failedPreferencesMutation == nil else { return nil }
    let generation = clientGeneration
    let mutationGeneration = preferenceMutationGeneration
    activePreferenceLoadTask?.cancel()
    preferenceLoadGeneration &+= 1
    let loadGeneration = preferenceLoadGeneration
    preferencesState = .loading
    defer {
      if isCurrentNotificationClient(client, generation: generation, accountDID: did),
        loadGeneration == preferenceLoadGeneration, preferencesState == .loading {
        preferencesState = serverPreferencesSnapshot == nil ? .unavailable : .ready
      }
    }
    let loadTask = Task { @MainActor [weak self] in
      guard let self else { throw CancellationError() }
      await self.configureNotificationServiceRouting(on: client)
      let authenticatedDID = try await self.preferencesService.authenticatedDID(client)
      guard !Task.isCancelled, authenticatedDID == did,
        self.isCurrentNotificationClient(client, generation: generation, accountDID: did),
        mutationGeneration == self.preferenceMutationGeneration,
        loadGeneration == self.preferenceLoadGeneration, self.activePreferenceMutationTask == nil
      else { throw CancellationError() }
      return try await self.preferencesService.fetch(client)
    }
    activePreferenceLoadTask = loadTask
    defer {
      if loadGeneration == preferenceLoadGeneration, clientGeneration == generation {
        activePreferenceLoadTask = nil
      }
    }
    do {
      let snapshot = try await withTaskCancellationHandler {
        try await loadTask.value
      } onCancel: { loadTask.cancel() }
      guard !Task.isCancelled,
        isCurrentNotificationClient(client, generation: generation, accountDID: did),
        mutationGeneration == preferenceMutationGeneration,
        loadGeneration == preferenceLoadGeneration, activePreferenceMutationTask == nil
      else { return nil }
      applyNotificationPreferencesSnapshot(snapshot)
      return snapshot
    } catch {
      guard !Task.isCancelled, !(error is CancellationError),
        isCurrentNotificationClient(client, generation: generation, accountDID: did),
        mutationGeneration == preferenceMutationGeneration, loadGeneration == preferenceLoadGeneration
      else { return nil }
      preferencesState = .loadFailed(error.localizedDescription)
      notificationLogger.error("Failed to load notification preferences: \(error.localizedDescription)")
      return nil
    }
  }

  func applyNotificationPreferencesSnapshot(_ serverPreferences: AppBskyNotificationDefs.Preferences) {
    serverPreferencesSnapshot = serverPreferences
    preferences = NotificationPreferences(serverPreferences: serverPreferences)
    failedPreferencesMutation = nil
    preferencesState = .ready
    syncChatNotificationPreferenceFromPreferences()
  }

  @MainActor
  func currentNotificationPreferencesSnapshot(using client: ATProtoClient) async
    -> AppBskyNotificationDefs.Preferences? {
    guard let pollingTicket = pollingBarrier.begin(accountDID: currentAccountDID) else { return nil }
    defer { pollingBarrier.finish(pollingTicket) }

    guard self.client === client, !Task.isCancelled else { return nil }
    if let serverPreferencesSnapshot {
      return serverPreferencesSnapshot
    }

    return await fetchNotificationPreferences(using: client)
  }

  /// Enable all notifications
  @MainActor
  func enableNotifications(expectedAccountDID: String? = nil) async {
    guard expectedAccountDID == nil || expectedAccountDID == currentAccountDID else { return }
    guard let pollingTicket = pollingBarrier.begin(accountDID: currentAccountDID) else { return }
    defer { pollingBarrier.finish(pollingTicket) }

    setMasterPushEnabled(true)
    notificationsEnabled = true
    if deviceToken == nil {
      await requestNotificationPermission()
      guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return }
    } else if let token = deviceToken {
      await registerDeviceToken(token)
      guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return }
    }
  }

  /// Disable all notifications
  @MainActor
  func disableNotifications(expectedAccountDID: String? = nil) async {
    guard expectedAccountDID == nil || expectedAccountDID == currentAccountDID else { return }
    guard let pollingTicket = pollingBarrier.begin(accountDID: currentAccountDID) else { return }
    defer { pollingBarrier.finish(pollingTicket) }

    setMasterPushEnabled(false)
    notificationsEnabled = false
    status = .disabled
    if let deviceToken = deviceToken {
      if let did = try? await client?.getDid() {
        guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return }
        await unregisterDeviceToken(deviceToken, did: did)
        guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return }
      }
    }
  }

  /// Request notification permissions from the user
  @MainActor
  func requestNotificationPermission(expectedAccountDID: String? = nil) async {
    guard expectedAccountDID == nil || expectedAccountDID == currentAccountDID else { return }
    guard let pollingTicket = pollingBarrier.begin(accountDID: currentAccountDID) else { return }
    defer { pollingBarrier.finish(pollingTicket) }

    notificationLogger.info("Requesting notification permission")
    status = .waitingForPermission

    do {
      // Request authorization
      let center = UNUserNotificationCenter.current()
      let options: UNAuthorizationOptions = [.alert, .sound, .badge]
      let granted = try await center.requestAuthorization(options: options)
      guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return }

      // Update state based on user's choice
      if granted {
        notificationLogger.info("Notification permission granted")
        setMasterPushEnabled(true)
        notificationsEnabled = true
        await MainActor.run {
          guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return }
          #if os(iOS)
            UIApplication.shared.registerForRemoteNotifications()
            notificationLogger.info(
              "✅ Called UIApplication.shared.registerForRemoteNotifications()")
          #elseif os(macOS)
            NSApplication.shared.registerForRemoteNotifications()
            notificationLogger.info(
              "✅ Called NSApplication.shared.registerForRemoteNotifications()")
          #endif
        }

        // Check current settings to confirm
        let settings = await center.notificationSettings()
        guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return }
        systemAuthorizationStatus = settings.authorizationStatus
        if settings.authorizationStatus == .authorized {
          notificationLogger.info("Notification settings confirmed authorized")
        } else {
          notificationLogger.warning(
            "Unexpected notification settings status: \(settings.authorizationStatus.rawValue)")
        }
      } else {
        notificationLogger.notice("Notification permission denied by user")
        status = .permissionDenied
        systemAuthorizationStatus = .denied
        notificationsEnabled = false
      }
    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return }
      notificationLogger.error(
        "Error requesting notification permission: \(error.localizedDescription)")
      status = .registrationFailed(error)
      notificationsEnabled = false
    }
  }

  /// Request notifications after successful login
  @MainActor
  func requestNotificationsAfterLogin() async {
    guard let pollingTicket = pollingBarrier.begin(accountDID: currentAccountDID) else { return }
    defer { pollingBarrier.finish(pollingTicket) }

    // Only request if we haven't already been granted permission
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return }

    if settings.authorizationStatus == .notDetermined {
      await requestNotificationPermission()
      guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return }
    }
  }

  /// Check the current notification permission status
  @MainActor
  func checkNotificationStatus(expectedAccountDID: String? = nil) async {
    guard expectedAccountDID == nil || expectedAccountDID == currentAccountDID else { return }
    guard let pollingTicket = pollingBarrier.begin(accountDID: currentAccountDID) else { return }
    defer { pollingBarrier.finish(pollingTicket) }

    notificationLogger.debug("Checking notification status")

    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()

    guard !Task.isCancelled,
      pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID)
    else { return }
    systemAuthorizationStatus = settings.authorizationStatus
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      notificationLogger.info("Notifications are authorized")

      let masterEnabled = isMasterPushEnabled()
      if !masterEnabled {
        notificationLogger.info("Push notifications explicitly disabled by user for this account")
        notificationsEnabled = false
        status = .disabled
        return
      }

      notificationsEnabled = true

      // Make sure we're registered for remote notifications
      notificationLogger.info(
        "📱 Permissions already granted, registering for remote notifications...")
      #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        notificationLogger.info(
          "✅ Called UIApplication.shared.registerForRemoteNotifications() in checkNotificationStatus"
        )
      #elseif os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        notificationLogger.info(
          "✅ Called NSApplication.shared.registerForRemoteNotifications() in checkNotificationStatus"
        )
      #endif

    // Note: Don't set status = .registered here!
    // Status should only be .registered after successfully registering with our notification service
    // The device token callback will trigger the actual service registration

    case .denied:
      notificationLogger.info("Notifications permission denied")
      notificationsEnabled = false
      status = .permissionDenied

    case .notDetermined:
      notificationLogger.info("Notification permission not determined")
      notificationsEnabled = false
      status = .unknown

    @unknown default:
      notificationLogger.warning("Unknown notification authorization status")
      notificationsEnabled = false
      status = .unknown
    }
  }

  /// Process a new device token from APNS
  @MainActor
  func handleDeviceToken(_ deviceToken: Data) async {
    let tokenHex = hexString(from: deviceToken)
    notificationLogger.info(
      "📱 Processing device token from APNS: \(tokenHex.prefix(16))... (length: \(deviceToken.count))"
    )
    self.deviceToken = deviceToken
    guard let pollingTicket = pollingBarrier.begin(accountDID: currentAccountDID) else { return }
    defer { pollingBarrier.finish(pollingTicket) }

    if status == .registered,
      let previousToken = lastRegisteredDeviceToken,
      previousToken == deviceToken {
      notificationLogger.info(
        "🔁 Device token already registered with notification service")
      return
    }

    guard notificationsEnabled && isMasterPushEnabled() else {
      notificationLogger.info(
        "Push notifications disabled by user for this account; skipping registration"
      )
      return
    }
    // Check if we have a client before attempting registration
    if client == nil {
      notificationLogger.warning(
        "⚠️ No client available for device token registration - will retry when client is set")
      return
    }

    notificationLogger.info("🚀 Starting device token registration with notification service")
    // Register with our notification service
    await registerDeviceToken(deviceToken)
  }

  /// Update notification preferences with serialized execution and rollback on failure.
  @discardableResult
  @MainActor
  func updatePreferences(_ newPreferences: NotificationPreferences, expectedAccountDID: String? = nil) async throws -> AppBskyNotificationDefs.Preferences? {
    try await updatePreferences(newPreferences, expectedAccountDID: expectedAccountDID, retryInput: nil)
  }

  @MainActor
  private func updatePreferences(_ newPreferences: NotificationPreferences, expectedAccountDID: String?,
    retryInput: AppBskyNotificationPutPreferencesV2.Input?) async throws -> AppBskyNotificationDefs.Preferences? {
    guard let pollingTicket = pollingBarrier.begin(accountDID: currentAccountDID) else { throw CancellationError() }
    defer { pollingBarrier.finish(pollingTicket) }

    guard let client = client else {
      notificationLogger.warning("Cannot update preferences - no client available")
      throw NotificationServiceError.clientUnavailable
    }

    guard let did = currentAccountDID, !Task.isCancelled,
      expectedAccountDID == nil || expectedAccountDID == did else { throw CancellationError() }
    guard preferencesState != .saving else {
      throw NotificationServiceError.serverError("Wait for your current notification changes to finish saving.")
    }
    guard serverPreferencesSnapshot != nil, canEditNotificationPreferences || retryInput != nil else {
      throw NotificationServiceError.serverError("Load your saved notification preferences before making changes.")
    }
    let input = retryInput ?? newPreferences.toPutPreferencesInput(changedFrom: preferences)
    guard !input.isEmptyNotificationUpdate else { return serverPreferencesSnapshot }
    let generation = clientGeneration
    failedPreferencesMutation = nil

    // Save prior confirmed snapshot if this is the first uncommitted mutation in flight
    if priorConfirmedPreferences == nil {
      priorConfirmedPreferences = preferences
      priorConfirmedServerSnapshot = serverPreferencesSnapshot
    }

    // Increment mutation generation and update optimistic state
    preferenceMutationGeneration &+= 1
    let mutationGeneration = preferenceMutationGeneration
    preferences = newPreferences
    preferencesState = .saving
    syncChatNotificationPreferenceFromPreferences()

    let previousTask = activePreferenceMutationTask
    let mutationTask = Task { [weak self] () -> AppBskyNotificationDefs.Preferences? in
      // Wait for any previous mutation to complete (ignoring errors so subsequent edits proceed)
      _ = try? await previousTask?.value

      guard let self else {
        throw NotificationServiceError.clientUnavailable
      }

      try Task.checkCancellation()
      guard self.isCurrentNotificationClient(client, generation: generation, accountDID: did) else {
        throw CancellationError()
      }
      return try await self.performPreferencesMutation(
        input: input, generation: mutationGeneration, client: client,
        clientGeneration: generation, accountDID: did
      )
    }

    activePreferenceMutationTask = mutationTask

    do {
      let result = try await withTaskCancellationHandler {
        try await mutationTask.value
      } onCancel: {
        mutationTask.cancel()
      }
      if isCurrentNotificationClient(client, generation: generation, accountDID: did),
        mutationGeneration == self.preferenceMutationGeneration {
        self.activePreferenceMutationTask = nil
        self.priorConfirmedPreferences = nil
        self.priorConfirmedServerSnapshot = nil
        self.preferencesState = .ready
      }
      return result
    } catch {
      if isCurrentNotificationClient(client, generation: generation, accountDID: did),
        mutationGeneration == self.preferenceMutationGeneration {
        self.activePreferenceMutationTask = nil
        if let prior = self.priorConfirmedPreferences {
          self.notificationLogger.warning(
            "Reverting notification preferences to prior confirmed snapshot due to mutation failure: \(error.localizedDescription)"
          )
          self.preferences = prior
          self.serverPreferencesSnapshot = self.priorConfirmedServerSnapshot
          self.syncChatNotificationPreferenceFromPreferences()
        }
        self.priorConfirmedPreferences = nil
        self.priorConfirmedServerSnapshot = nil
        if error is CancellationError {
          self.preferencesState = self.serverPreferencesSnapshot == nil ? .unavailable : .ready
        } else {
          self.failedPreferencesMutation = FailedPreferencesMutation(requested: newPreferences,
            input: input, client: client, clientGeneration: generation, accountDID: did)
          self.preferencesState = .saveFailed(error.localizedDescription)
        }
      }
      throw error
    }
  }

  /// Mutates notification preferences using a closure, serialized with rollback on failure.
  @discardableResult
  @MainActor
  func updatePreferences(_ mutate: (inout NotificationPreferences) -> Void, expectedAccountDID: String? = nil) async throws -> AppBskyNotificationDefs.Preferences? {
    var updated = preferences
    mutate(&updated)
    return try await updatePreferences(updated, expectedAccountDID: expectedAccountDID)
  }

  @MainActor
  private func performPreferencesMutation(
    input: AppBskyNotificationPutPreferencesV2.Input,
    generation: UInt64,
    client: ATProtoClient,
    clientGeneration: UInt64,
    accountDID: String
  ) async throws -> AppBskyNotificationDefs.Preferences? {
    try Task.checkCancellation()
    await configureNotificationServiceRouting(on: client)
    let authenticatedDID = try await preferencesService.authenticatedDID(client)
    try Task.checkCancellation()
    guard isCurrentNotificationClient(client, generation: clientGeneration, accountDID: accountDID),
      authenticatedDID == accountDID
    else { throw CancellationError() }
    let updatedPreferences = try await preferencesService.save(client, input)
    try Task.checkCancellation()
    guard isCurrentNotificationClient(client, generation: clientGeneration, accountDID: accountDID) else {
      throw CancellationError()
    }

    guard let updatedPreferences else {
      throw NotificationServiceError.serverError("The service did not confirm your saved notification preferences. Try saving again.")
    }
    // Keep the accepted baseline even if another edit arrives before the awaiting caller resumes.
    priorConfirmedPreferences = NotificationPreferences(serverPreferences: updatedPreferences)
    priorConfirmedServerSnapshot = updatedPreferences
    if generation == self.preferenceMutationGeneration {
      applyNotificationPreferencesSnapshot(updatedPreferences)
    }
    return updatedPreferences
  }

  /// Starts periodic checking of unread notifications
  @MainActor
  func startUnreadNotificationChecking() {
    guard !pollingBarrier.isSuspended else { return }
    unreadCheckTimer?.invalidate()
    unreadCheckTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.scheduleUnreadCheck() }
    }
    scheduleUnreadCheck()
    notificationLogger.info("Started background notification checking")
  }

  /// Cleanup notifications when user logs out
  func cleanupNotifications(previousClient: ATProtoClient? = nil) async {
    notificationLogger.info("Cleaning up notifications after logout")
    clientGeneration &+= 1
    preferenceMutationGeneration &+= 1
    chatPreferenceChangeGeneration &+= 1
    let generation = clientGeneration
    let accountDID = currentAccountDID
    shouldPersistChatPreference = false
    activePreferenceMutationTask?.cancel()
    activePreferenceLoadTask?.cancel()
    activePreferenceLoadTask = nil

    // Stop unread checking timer
    unreadCheckTimer?.invalidate()
    unreadCheckTimer = nil

    // Unregister from notification service if we have a device token
    if let deviceToken = deviceToken {
      do {
        let didSource = previousClient ?? client
        if let did = try await didSource?.getDid() {
          await unregisterDeviceToken(deviceToken, did: did, using: didSource)
        }
      } catch {
        notificationLogger.error(
          "Failed to determine DID during cleanup: \(error.localizedDescription)")
      }
    }

    guard clientGeneration == generation, currentAccountDID == accountDID else { return }

    // Reset state
    status = .unknown
    notificationsEnabled = false
    unreadCount = 0
    preferences = NotificationPreferences()
    preferencesState = .unavailable
    failedPreferencesMutation = nil
    serverPreferencesSnapshot = nil
    priorConfirmedPreferences = nil
    priorConfirmedServerSnapshot = nil
    activePreferenceMutationTask = nil
    blockedUsers.removeAll()
    lastRelationshipSync = nil
    lastRegisteredDeviceToken = nil

    // Clear app badge
    #if os(iOS)
      if #available(iOS 17.0, *) {
        UNUserNotificationCenter.current().setBadgeCount(0) { error in
          if let error = error {
            self.notificationLogger.error(
              "Failed to clear badge count: \(error.localizedDescription)")
          }
        }
      } else {
        await MainActor.run {
          UIApplication.shared.applicationIconBadgeNumber = 0
        }
      }
    #elseif os(macOS)
      if #available(macOS 14.0, *) {
        UNUserNotificationCenter.current().setBadgeCount(0) { error in
          if let error = error {
            self.notificationLogger.error(
              "Failed to clear badge count: \(error.localizedDescription)")
          }
        }
      } else {
        await MainActor.run {
          NSApplication.shared.dockTile.badgeLabel = nil
        }
      }
    #endif

    // Update widget to clear count
    updateWidgetUnreadCount(0)

    notificationLogger.info("Notification cleanup completed")
  }

  /// Checks for unread notifications and updates count
  @MainActor
  func checkUnreadNotifications() async {
    guard let pollingTicket = pollingBarrier.begin(accountDID: currentAccountDID) else { return }
    defer { pollingBarrier.finish(pollingTicket) }

    // Inbox activity belongs to the authenticated account, independently of push delivery.
    guard let client = client else {
      notificationLogger.warning("Cannot check unread notifications - no client")
      return
    }

    do {
      let generation = clientGeneration
      guard let did = currentAccountDID else { return }
      await configureNotificationServiceRouting(on: client)
      let authenticatedDID = try await preferencesService.authenticatedDID(client)
      guard !Task.isCancelled, authenticatedDID == did,
        isCurrentNotificationClient(client, generation: generation, accountDID: did)
      else { return }
      let count = try await preferencesService.unreadCount(client)

      guard !Task.isCancelled,
        isCurrentNotificationClient(client, generation: generation, accountDID: did)
      else { return }
      if count != unreadCount {
        unreadCount = count

        // Update app badge
        #if os(iOS)
          if #available(iOS 17.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(self.unreadCount) { error in
              if let error = error {
                self.notificationLogger.error(
                  "Failed to update badge count: \(error.localizedDescription)")
              }
            }
          } else {
            UIApplication.shared.applicationIconBadgeNumber = self.unreadCount
          }
        #elseif os(macOS)
          // macOS badge support
          if #available(macOS 14.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(self.unreadCount) { error in
              if let error = error {
                self.notificationLogger.error(
                  "Failed to update badge count: \(error.localizedDescription)")
              }
            }
          } else {
            NSApplication.shared.dockTile.badgeLabel =
              self.unreadCount > 0 ? "\(self.unreadCount)" : nil
          }
        #endif

        // Share data with widget
        updateWidgetUnreadCount(self.unreadCount)

        // Post notification for observers
        NotificationCenter.default.post(
          name: NSNotification.Name("UnreadNotificationCountChanged"),
          object: nil,
          userInfo: ["count": self.unreadCount]
        )

        notificationLogger.info("Unread notification count updated: \(self.unreadCount)")
      }
    } catch {
      notificationLogger.error("Error checking unread notifications: \(error.localizedDescription)")
    }
  }

  /// Update unread count after notifications are marked as seen
  func updateUnreadCountAfterSeen() {
    let generation = clientGeneration
    let accountDID = currentAccountDID
    Task { @MainActor in
      guard !pollingBarrier.isSuspended, clientGeneration == generation, currentAccountDID == accountDID else { return }
      unreadCount = 0

      // Update app badge
      #if os(iOS)
        if #available(iOS 17.0, *) {
          UNUserNotificationCenter.current().setBadgeCount(0) { error in
            if let error = error {
              self.notificationLogger.error(
                "Failed to reset badge count: \(error.localizedDescription)")
            }
          }
        } else {
          UIApplication.shared.applicationIconBadgeNumber = 0
        }
      #elseif os(macOS)
        // macOS badge reset
        if #available(macOS 14.0, *) {
          UNUserNotificationCenter.current().setBadgeCount(0) { error in
            if let error = error {
              self.notificationLogger.error(
                "Failed to reset badge count: \(error.localizedDescription)")
            }
          }
        } else {
          NSApplication.shared.dockTile.badgeLabel = nil
        }
      #endif

      // Share data with widget
      updateWidgetUnreadCount(0)

      // Post notification for observers
      NotificationCenter.default.post(
        name: NSNotification.Name("UnreadNotificationCountChanged"),
        object: nil,
        userInfo: ["count": 0]
      )

      notificationLogger.info("Reset unread notification count after marking as seen")
    }
  }

  // MARK: - Relationship Sync Methods

  /// Synchronizes muted and blocked users with the notification server
  @MainActor
  func syncRelationships() async {
    guard let pollingTicket = pollingBarrier.begin(accountDID: currentAccountDID) else { return }
    defer { pollingBarrier.finish(pollingTicket) }

    guard notificationsEnabled else {
      notificationLogger.info("Not syncing relationships - notifications are disabled")
      return
    }

    await gatherRelationships()
    guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return }
    lastRelationshipSync = Date()
  }

  /// Gathers current relationships from the graph manager
  @MainActor
  private func gatherRelationships() async {
    guard let pollingTicket = pollingBarrier.begin(accountDID: currentAccountDID) else { return }
    defer { pollingBarrier.finish(pollingTicket) }

    guard let appState = appState else {
      notificationLogger.warning("Cannot gather relationships - no AppState reference")
      return
    }

    do {
      // Use existing graph manager to refresh caches
      try await appState.graphManager.refreshMuteCache()
      guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return }
      try await appState.graphManager.refreshBlockCache()

      // Get muted and blocked users
      await MainActor.run {
        guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return }
        // Access GraphManager's cached values
        mutedUsers = appState.graphManager.muteCache
        blockedUsers = appState.graphManager.blockCache
      }

      notificationLogger.info(
        "Gathered relationships: \(self.mutedUsers.count) mutes, \(self.blockedUsers.count) blocks")
    } catch {
      notificationLogger.error("Error gathering relationships: \(error.localizedDescription)")
    }
  }

  /// Updates relationships on the notification server
  private func updateRelationshipsOnServer() async {
    notificationLogger.debug(
      "Skipping legacy relationship upload; Nest now owns mute/block filtering server-side")
  }

  /// Set up observers for graph changes
  private func setupGraphObservers() {
    // Observe changes to mutes and blocks
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleGraphChange),
      name: NSNotification.Name("UserGraphChanged"),
      object: nil
    )
  }

  @objc private func handleGraphChange() {
    Task {
      await syncRelationships()
    }
  }

  /// Syncs all user data (preferences and relationships) with the notification server
  @MainActor
  func syncAllUserData() async {
    guard let pollingTicket = pollingBarrier.begin(accountDID: currentAccountDID) else { return }
    defer { pollingBarrier.finish(pollingTicket) }

    guard notificationsEnabled else {
      notificationLogger.info("Not syncing user data - notifications are disabled")
      return
    }

    guard status == .registered else {
      notificationLogger.warning("Cannot sync - not properly registered")
      return
    }

    await refreshNotificationPreferences()
    guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return }
    await syncRelationships()
    if let appState {
      let service = await MainActor.run { appState.activitySubscriptionService }
      guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return }
      await service.refreshSubscriptions()
    }

    notificationLogger.info("Completed notification XRPC refresh")
  }

  // MARK: - Moderation Lists & Thread Mutes

  /// Synchronizes moderation lists with the notification server
  func syncModerationLists() async {
    notificationLogger.debug(
      "Skipping legacy moderation list upload; Nest now refreshes moderation state server-side")
  }

  /// Fetches moderation lists from AT Protocol
  @MainActor
  private func fetchModerationLists(
    client: ATProtoClient,
    type: String
  ) async throws -> [(uri: String, purpose: String, name: String?)] {
    guard let pollingTicket = pollingBarrier.begin(accountDID: currentAccountDID) else { throw CancellationError() }
    defer { pollingBarrier.finish(pollingTicket) }

    var allLists: [(uri: String, purpose: String, name: String?)] = []
    var cursor: String?

    // Fetch all pages of lists
    repeat {
      let params: Any
      let result: (responseCode: Int, data: Any?)

      if type == "block" {
        params = AppBskyGraphGetListBlocks.Parameters(limit: 100, cursor: cursor)
        result = try await client.app.bsky.graph.getListBlocks(
          input: params as! AppBskyGraphGetListBlocks.Parameters)
        guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { throw CancellationError() }

        if result.responseCode == 200, let output = result.data as? AppBskyGraphGetListBlocks.Output {
          for list in output.lists {
            allLists.append(
              (
                uri: list.uri.uriString(),
                purpose: list.purpose.rawValue,
                name: list.name
              ))
          }
          cursor = output.cursor
        } else {
          break
        }
      } else if type == "mute" {
        params = AppBskyGraphGetListMutes.Parameters(limit: 100, cursor: cursor)
        result = try await client.app.bsky.graph.getListMutes(
          input: params as! AppBskyGraphGetListMutes.Parameters)
        guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { throw CancellationError() }

        if result.responseCode == 200, let output = result.data as? AppBskyGraphGetListMutes.Output {
          for list in output.lists {
            allLists.append(
              (
                uri: list.uri.uriString(),
                purpose: list.purpose.rawValue,
                name: list.name
              ))
          }
          cursor = output.cursor
        } else {
          break
        }
      } else {
        break
      }
    } while cursor != nil

    notificationLogger.info("Fetched \(allLists.count) \(type) lists from AT Protocol")
    return allLists
  }

  /// Mutes a thread for push notifications
  @MainActor
  func muteThreadNotifications(threadRootURI: String) async throws {
    guard let pollingTicket = pollingBarrier.begin(accountDID: currentAccountDID) else { throw CancellationError() }
    defer { pollingBarrier.finish(pollingTicket) }

    guard let client = client else {
      throw NotificationServiceError.clientNotConfigured
    }

    let input = AppBskyGraphMuteThread.Input(root: try ATProtocolURI(uriString: threadRootURI))
    let responseCode = try await client.app.bsky.graph.muteThread(input: input)
    guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { throw CancellationError() }
    guard responseCode == 200 else {
      throw NotificationServiceError.serverError("HTTP \(responseCode)")
    }
    NotificationCenter.default.post(name: NSNotification.Name("UserGraphChanged"), object: nil)
  }

  /// Unmutes a thread for push notifications
  @MainActor
  func unmuteThreadNotifications(threadRootURI: String) async throws {
    guard let pollingTicket = pollingBarrier.begin(accountDID: currentAccountDID) else { throw CancellationError() }
    defer { pollingBarrier.finish(pollingTicket) }

    guard let client = client else {
      throw NotificationServiceError.clientNotConfigured
    }

    let input = AppBskyGraphUnmuteThread.Input(root: try ATProtocolURI(uriString: threadRootURI))
    let responseCode = try await client.app.bsky.graph.unmuteThread(input: input)
    guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { throw CancellationError() }
    guard responseCode == 200 else {
      throw NotificationServiceError.serverError("HTTP \(responseCode)")
    }
    NotificationCenter.default.post(name: NSNotification.Name("UserGraphChanged"), object: nil)
  }

  // MARK: - Private Methods

  private func hexString(from token: Data) -> String {
    token.map { String(format: "%02.2hhx", $0) }.joined()
  }

  /// Fetch the current set of activity subscriptions from the notification server.
  @MainActor
  func fetchActivitySubscriptionsFromServer() async -> [ActivitySubscriptionServerRecord]? {
    guard let pollingTicket = pollingBarrier.begin(accountDID: currentAccountDID) else { return nil }
    defer { pollingBarrier.finish(pollingTicket) }

    guard notificationsEnabled else {
      notificationLogger.debug("Skipping activity subscription fetch - notifications disabled")
      return nil
    }

    guard status == .registered else {
      notificationLogger.debug(
        "Skipping activity subscription fetch - notification service not registered")
      return nil
    }

    guard let client = client else {
      notificationLogger.warning("Cannot fetch activity subscriptions - missing ATProto client")
      return nil
    }

    do {
      await configureNotificationServiceRouting(on: client)
      guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return nil }
      let (responseCode, output) = try await client.app.bsky.notification.listActivitySubscriptions(
        input: .init(limit: 100)
      )
      guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return nil }

      guard responseCode == 200, let output else {
        notificationLogger.error(
          "Failed to fetch activity subscriptions via XRPC: HTTP \(responseCode)")
        return nil
      }

      return output.subscriptions.compactMap { profile in
        guard let subscription = profile.viewer?.activitySubscription else {
          return nil
        }

        return ActivitySubscriptionServerRecord(
          subjectDid: profile.did.didString(),
          includePosts: subscription.post,
          includeReplies: subscription.reply,
          updatedAt: nil
        )
      }
    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return nil }
      notificationLogger.error(
        "Error fetching activity subscriptions via XRPC: \(error.localizedDescription)")
    }

    return nil
  }

  /// Create or update an activity subscription on the notification server.
  @MainActor
  func updateActivitySubscriptionOnServer(
    subjectDid: String,
    includePosts: Bool,
    includeReplies: Bool
  ) async {
    guard let pollingTicket = pollingBarrier.begin(accountDID: currentAccountDID) else { return }
    defer { pollingBarrier.finish(pollingTicket) }

    guard includePosts || includeReplies else {
      await removeActivitySubscriptionFromServer(
        subjectDid: subjectDid
      )
      guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return }
      return
    }

    guard notificationsEnabled else {
      notificationLogger.debug("Skipping activity subscription sync - notifications disabled")
      return
    }

    guard status == .registered else {
      notificationLogger.debug(
        "Skipping activity subscription sync - notification service not registered")
      return
    }

    guard let client = client else {
      notificationLogger.warning("Cannot sync activity subscription - missing ATProto client")
      return
    }

    do {
      await configureNotificationServiceRouting(on: client)
      guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return }
      let input = AppBskyNotificationPutActivitySubscription.Input(
        subject: try DID(didString: subjectDid),
        activitySubscription: AppBskyNotificationDefs.ActivitySubscription(
          post: includePosts,
          reply: includeReplies
        )
      )
      let (responseCode, _) = try await client.app.bsky.notification.putActivitySubscription(
        input: input
      )
      guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return }

      switch responseCode {
      case 200 ... 299:
        notificationLogger.info(
          "Synced activity subscription for \(subjectDid) via notification XRPC")
      default:
        notificationLogger.error(
          "Failed to sync activity subscription for \(subjectDid): HTTP \(responseCode)"
        )
      }
    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return }
      notificationLogger.error(
        "Error syncing activity subscription for \(subjectDid) via XRPC: \(error.localizedDescription)"
      )
    }
  }

  /// Remove an activity subscription from the notification server.
  @MainActor
  func removeActivitySubscriptionFromServer(
    subjectDid: String
  ) async {
    guard let pollingTicket = pollingBarrier.begin(accountDID: currentAccountDID) else { return }
    defer { pollingBarrier.finish(pollingTicket) }

    guard notificationsEnabled else {
      notificationLogger.debug("Skipping activity subscription removal - notifications disabled")
      return
    }

    guard status == .registered else {
      notificationLogger.debug(
        "Skipping activity subscription removal - notification service not registered")
      return
    }

    guard let client = client else {
      notificationLogger.warning("Cannot remove activity subscription - missing ATProto client")
      return
    }

    do {
      await configureNotificationServiceRouting(on: client)
      guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return }
      let input = AppBskyNotificationPutActivitySubscription.Input(
        subject: try DID(didString: subjectDid),
        activitySubscription: AppBskyNotificationDefs.ActivitySubscription(
          post: false,
          reply: false
        )
      )
      let (responseCode, _) = try await client.app.bsky.notification.putActivitySubscription(
        input: input
      )
      guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return }

      switch responseCode {
      case 200 ... 299:
        notificationLogger.info(
          "Removed activity subscription for \(subjectDid) via notification XRPC")
      default:
        notificationLogger.error(
          "Failed to remove activity subscription for \(subjectDid): HTTP \(responseCode)"
        )
      }
    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(pollingTicket, accountDID: currentAccountDID) else { return }
      notificationLogger.error(
        "Error removing activity subscription for \(subjectDid) via XRPC: \(error.localizedDescription)"
      )
    }
  }

  // MARK: - Service Calls

  /// Unregister the device token from our notification service
  private func unregisterDeviceToken(
    _ token: Data,
    did: String,
    using clientOverride: ATProtoClient? = nil
  ) async {
    notificationLogger.info("Unregistering device token via notification XRPC")

    guard let client = clientOverride ?? client else {
      notificationLogger.warning("Cannot unregister device token - no client available for \(did)")
      return
    }

    do {
      await configureNotificationServiceRouting(on: client)
      let input = AppBskyNotificationUnregisterPush.Input(
        serviceDid: try notificationServiceDID(),
        token: hexString(from: token),
        platform: pushPlatform,
        appId: pushAppID
      )
      let responseCode = try await client.app.bsky.notification.unregisterPush(input: input)

      switch responseCode {
      case 200 ... 299, 404:
        break
      default:
        notificationLogger.warning(
          "Failed to unregister device token via XRPC: HTTP \(responseCode)")
      }
    } catch {
      notificationLogger.error(
        "Error unregistering device token via XRPC: \(error.localizedDescription)")
    }
  }

  /// Register the device token with our notification service
  @MainActor
  private func registerDeviceToken(_ token: Data) async {
    guard let pollingTicket = pollingBarrier.begin(accountDID: currentAccountDID) else { return }
    defer { pollingBarrier.finish(pollingTicket) }

    guard !Task.isCancelled, isMasterPushEnabled() else { return }
    guard let client, let did = currentAccountDID else { return }
    let generation = clientGeneration
    let tokenHex = hexString(from: token)
    notificationLogger.info("🔄 Starting device token registration: \(tokenHex.prefix(16))...")

    guard await registrationCoordinator.begin() else {
      notificationLogger.info("⏳ Registration already in progress; ignoring duplicate request")
      return
    }
    defer {
      Task { await registrationCoordinator.finish() }
    }

    guard !Task.isCancelled, isMasterPushEnabled(),
      isCurrentNotificationClient(client, generation: generation, accountDID: did)
    else { return }

    do {
      await configureNotificationServiceRouting(on: client)
      let authenticatedDID = try await client.getDid()
      guard !Task.isCancelled, isMasterPushEnabled(), authenticatedDID == did,
        isCurrentNotificationClient(client, generation: generation, accountDID: did)
      else { return }
      let input = AppBskyNotificationRegisterPush.Input(
        serviceDid: try notificationServiceDID(),
        token: tokenHex,
        platform: pushPlatform,
        appId: pushAppID
      )
      let responseCode = try await client.app.bsky.notification.registerPush(input: input)
      guard isCurrentNotificationClient(client, generation: generation, accountDID: did) else { return }
      guard isMasterPushEnabled() else {
        notificationsEnabled = false
        status = .disabled
        lastRegisteredDeviceToken = nil
        // Disabling may have raced a successful registration that was already in flight.
        if (200 ... 299).contains(responseCode) {
          await unregisterDeviceToken(token, did: did, using: client)
        }
        return
      }
      guard !Task.isCancelled else { return }

      switch responseCode {
      case 200 ... 299:
        notificationLogger.info("✅ Successfully registered device token via notification XRPC")
        status = .registered
        lastRegisteredDeviceToken = token
        await refreshNotificationPreferences()
        guard !Task.isCancelled,
          isCurrentNotificationClient(client, generation: generation, accountDID: did)
        else { return }
        await syncRelationships()
      default:
        status = .registrationFailed(
          NSError(
            domain: "NotificationManager",
            code: responseCode,
            userInfo: [NSLocalizedDescriptionKey: "Notification registration failed (HTTP \(responseCode))"]
          )
        )
      }
    } catch {
      guard !Task.isCancelled, isMasterPushEnabled(),
        isCurrentNotificationClient(client, generation: generation, accountDID: did)
      else { return }
      notificationLogger.error(
        "❌ Error registering device token via XRPC: \(error.localizedDescription)")
      status = .registrationFailed(error)
    }
  }

  private func createNavigationDestination(from uriString: String, type: String) throws -> NavigationDestination {
    switch type.lowercased() {
    case "follow":
      if uriString.hasPrefix("at://") {
        let uri = try ATProtocolURI(uriString: uriString)
        return .profile(uri.authority)
      } else {
        return .profile(uriString)
      }
    case "starterpack-joined":
      let uri = try ATProtocolURI(uriString: uriString)
      return .starterPack(uri)
    default:
      let uri = try ATProtocolURI(uriString: uriString)
      return .post(uri)
    }
  }

  // MARK: - App Lifecycle

  @MainActor
  @objc private func appDidBecomeActive() {
    guard !pollingBarrier.isSuspended, foregroundCheckTask == nil else { return }
    foregroundCheckTask = Task { [weak self] in
      guard let self,
        let ticket = self.pollingBarrier.begin(accountDID: self.currentAccountDID)
      else { return }
      defer {
        self.pollingBarrier.finish(ticket)
        self.foregroundCheckTask = nil
      }
      await self.checkNotificationStatus()
      guard !Task.isCancelled, self.pollingBarrier.isCurrent(ticket, accountDID: self.currentAccountDID) else { return }
      await self.checkUnreadNotifications()
      guard !Task.isCancelled, self.pollingBarrier.isCurrent(ticket, accountDID: self.currentAccountDID) else { return }
      if let lastSync = self.lastRelationshipSync, Date().timeIntervalSince(lastSync) > 3600 {
        await self.syncRelationships()
      }
      guard !Task.isCancelled, self.pollingBarrier.isCurrent(ticket, accountDID: self.currentAccountDID) else { return }
      self.updateWidgetUnreadCount(self.unreadCount)
    }
  }

  // Test function to manually update widget data
  func testUpdateWidget(count: Int) {
    updateWidgetUnreadCount(count)
    notificationLogger.info("🧪 Manually updated widget with test count: \(count)")
  }

  // Setup initial test data for widget in debug mode
  private func setupTestWidgetData() {
    // Set a default test value of 42 to ensure widget has data
    let testData = NotificationWidgetData(count: 42, lastUpdated: Date())

    if let encoded = try? JSONEncoder().encode(testData) {
      let defaults = UserDefaults(suiteName: "group.blue.catbird.shared")
      defaults?.set(encoded, forKey: "notificationWidgetData")
      defaults?.synchronize()  // Force an immediate write
      notificationLogger.info("🔧 DEBUG: Set initial widget test data with count=42")
    }
  }

  // MARK: - Widget Support

  /// Updates the widget with the current unread notification count
  func updateWidgetUnreadCount(_ count: Int) {
    // Create widget data
    let widgetData = NotificationWidgetData(count: count, lastUpdated: Date())

    // Encode to JSON
    guard let data = try? JSONEncoder().encode(widgetData) else {
      notificationLogger.error("Failed to encode widget data")
      return
    }

    // Save to App Group shared UserDefaults
    let sharedDefaults = UserDefaults(suiteName: "group.blue.catbird.shared")
    if let sharedDefaults = sharedDefaults {
      sharedDefaults.set(data, forKey: "notificationWidgetData")
      notificationLogger.info(
        "📲 Widget data saved to UserDefaults: count=\(count), lastUpdated=\(Date())")
    } else {
      notificationLogger.error(
        "❌ Failed to access shared UserDefaults with suite name 'group.blue.catbird'")
    }

    // Trigger widget refresh
    WidgetCenter.shared.reloadTimelines(ofKind: "CatbirdNotificationWidget")
    notificationLogger.info(
      "🔄 Widget timeline refresh requested for kind: CatbirdNotificationWidget")
  }
  // MARK: - UNUserNotificationCenterDelegate
  /// Handle notifications received while app is in the foreground
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    notificationLogger.info("Received notification while app in foreground")

    let userInfo = notification.request.content.userInfo

    // Pushes for features this build does not include (encrypted chat, Circles) can
    // still arrive for devices registered by an earlier build. Never surface them.
    if Self.isUnsupportedFeaturePush(userInfo) {
      notificationLogger.info("Suppressing foreground push for unsupported feature")
      completionHandler([])
      return
    }

    // Standard Bluesky notifications
    if let uriString = userInfo["uri"] as? String,
      let typeString = userInfo["type"] as? String {
      Task {
        await prefetchNotificationContent(uri: uriString, type: typeString)
      }
    }

    // Suppress banners for the chat conversation currently on screen —
    // the user is already reading it; the thread updates live via polling.
    if let type = userInfo["type"] as? String, type == "chat" || type == "chat_message",
      let convoId = Self.chatConversationID(fromUserInfo: userInfo) {
      let activeConvoId = appState?.chatManager.activeConversationId
      if convoId == activeConvoId {
        notificationLogger.info("Suppressing foreground chat banner for open conversation")
        completionHandler([])
        return
      }
    }

    // Show notification banner even when app is in foreground
    completionHandler([.banner, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    notificationLogger.info("User interacted with notification: \(userInfo)")
    if Self.isUnsupportedFeaturePush(userInfo) {
      notificationLogger.info("Ignoring tap on push for unsupported feature")
      completionHandler()
      return
    }

    let targetDid = userInfo["did"] as? String
    let uriString = userInfo["uri"] as? String
    let typeString = userInfo["type"] as? String

    // Handle chat notifications that identify the conversation by ID instead of URI:
    // NSE `chat_message` pushes carry `convoId`, local polling notifications carry
    // `conversationID`. Payloads with `uri`/`did` keys keep the generic path below.
    if let convoId = Self.chatConversationID(fromUserInfo: userInfo) {
      let recipientDid =
        (userInfo["recipientDid"] as? String) ?? resolveRecipientDID(from: userInfo)

      Task { @MainActor in
        guard let target = captureNavigationTarget(accountDID: recipientDid) else {
          completionHandler()
          return
        }
        await ensureActiveAccount(for: target.accountDID)

        notificationLogger.info(
          "Chat notification tapped - navigating to conversation: \(convoId)")
        #if os(iOS)
        await handleChatNotificationNavigation(convoId, target: target)
        #endif

        await MainActor.run {
          completionHandler()
        }
      }
      return
    }

    // Social pushes from the push gateway identify the event with `reason`, `actorDid`,
    // `subjectUri` and `eventPath` rather than `uri`/`type`.
    if let reason = userInfo["reason"] as? String, let actorDid = userInfo["actorDid"] as? String {
      let destination = Self.socialPushDestination(
        reason: reason,
        actorDid: actorDid,
        subjectUri: userInfo["subjectUri"] as? String,
        eventPath: userInfo["eventPath"] as? String)
      let recipientDid =
        (userInfo["recipientDid"] as? String) ?? resolveRecipientDID(from: userInfo)

      Task { @MainActor in
        defer { completionHandler() }
        guard let target = captureNavigationTarget(accountDID: recipientDid) else { return }
        await ensureActiveAccount(for: target.accountDID)
        guard AppStateManager.shared.lifecycle.userDID == target.accountDID else { return }

        let command: SceneRouteCommand
        if let destination {
          notificationLogger.info("Social notification tapped (\(reason, privacy: .public)) - opening its subject")
          command = .navigate(destination, tabIndex: 2)
        } else {
          notificationLogger.info("Social notification tapped (\(reason, privacy: .public)) - opening Notifications")
          command = .showTab(2, resetPath: false)
        }
        SceneRouteCoordinator.shared.submit(SceneRouteRequest(accountDID: target.accountDID,
          command: command, preferredSceneID: target.preferredSceneID))
      }
      return
    }

    if targetDid != nil || (uriString != nil && typeString != nil) {
      Task { @MainActor in
        guard let target = captureNavigationTarget(accountDID: targetDid) else { return }
        await ensureActiveAccount(for: target.accountDID)
        guard AppStateManager.shared.lifecycle.userDID == target.accountDID else { return }

        if let uri = uriString, let type = typeString {
          notificationLogger.info("Notification contains URI: \(uri) of type: \(type)")
          await prefetchNotificationContent(uri: uri, type: type)
          await handleNotificationNavigation(uriString: uri, type: type, target: target)
        }
      }
    }

    completionHandler()
  }
  /// Push `type` values for features this build does not include (end-to-end encrypted
  /// chat). The notification service extension neutralizes their content; the app
  /// suppresses them in the foreground and ignores taps.
  nonisolated static let unsupportedFeaturePushTypes: Set<String> = [
    "mls_message",
    "mls_message_decrypted",
    "mls_message_request",
    "key_package_replenish_request",
  ]

  /// Whether a push payload belongs to a feature this build does not include
  /// (encrypted chat or Circles activity).
  nonisolated static func isUnsupportedFeaturePush(_ userInfo: [AnyHashable: Any]) -> Bool {
    if let type = userInfo["type"] as? String, unsupportedFeaturePushTypes.contains(type) {
      return true
    }
    return (userInfo["kind"] as? String) == "circle_activity"
  }

  /// Extract the conversation ID from a chat notification payload, or nil when the
  /// payload is not chat-shaped or already satisfies the generic `uri`/`did` routing
  /// guard (those payloads must keep their existing path).
  nonisolated static func chatConversationID(fromUserInfo userInfo: [AnyHashable: Any]) -> String? {
    guard (userInfo["did"] as? String) == nil, (userInfo["uri"] as? String) == nil else {
      return nil
    }
    guard let type = userInfo["type"] as? String, type == "chat" || type == "chat_message" else {
      return nil
    }
    return (userInfo["convoId"] as? String) ?? (userInfo["conversationID"] as? String)
  }

  /// Where a tap on a social push should go. Follows open the follower's profile; likes and
  /// reposts open the post they were about; replies, mentions, quotes and subscribed posts
  /// open the new post itself. Returns nil when the payload does not identify a destination.
  nonisolated static func socialPushDestination(
    reason: String,
    actorDid: String,
    subjectUri: String?,
    eventPath: String?
  ) -> NavigationDestination? {
    let eventURI = eventPath.flatMap { path -> ATProtocolURI? in
      guard !path.isEmpty else { return nil }
      return try? ATProtocolURI(uriString: "at://\(actorDid)/\(path)")
    }
    let subjectURI = subjectUri.flatMap { try? ATProtocolURI(uriString: $0) }

    switch reason.lowercased() {
    case "follow":
      return .profile(actorDid)
    case "like", "repost", "via_like", "via_repost", "like-via-repost", "repost-via-repost":
      return subjectURI.map { .post($0) }
    case "reply", "mention", "quote", "activity_post", "activity_reply", "subscribed-post":
      return (eventURI ?? subjectURI).map { .post($0) }
    case "starterpack-joined":
      return subjectURI.map { .starterPack($0) }
    default:
      return nil
    }
  }

  // MARK: - Notification Navigation Handling

  /// Prefetch content referenced in notification for instant display
  private func prefetchNotificationContent(uri: String, type: String) async {
    guard let appState = appState else {
      notificationLogger.debug("Cannot prefetch - appState unavailable")
      return
    }

    let client = await MainActor.run { AppStateManager.shared.authentication.client }
    guard let client else {
      notificationLogger.debug("Cannot prefetch - no authenticated client")
      return
    }

    // Only prefetch for post-related notifications
    guard ["like", "repost", "reply", "mention", "quote"].contains(type.lowercased()) else {
      return
    }

    do {
      guard let atUri = try? ATProtocolURI(uriString: uri) else {
        notificationLogger.warning("Invalid URI for prefetching: \(uri)")
        return
      }

      notificationLogger.info("Prefetching post content for notification: \(uri)")

      let params = AppBskyFeedGetPosts.Parameters(uris: [atUri])
      let (responseCode, output) = try await client.app.bsky.feed.getPosts(input: params)

      guard responseCode == 200, let posts = output?.posts, !posts.isEmpty else {
        notificationLogger.warning("Failed to prefetch post (HTTP \(responseCode))")
        return
      }

      notificationLogger.info("✅ Successfully prefetched post for notification")

      // Cache post to SwiftData for instant display
      if let postView = posts.first {
        await savePrefetchedPostToCache(postView)

        // Cache images for immediate display
        await prefetchPostImages(postView)
      }

    } catch {
      notificationLogger.error(
        "Error prefetching notification content: \(error.localizedDescription)")
    }
  }

  /// Save prefetched post to SwiftData cache for instant display
  private func savePrefetchedPostToCache(_ postView: AppBskyFeedDefs.PostView) async {
    guard let modelContext = modelContext else {
      notificationLogger.debug("Cannot cache post - modelContext unavailable")
      return
    }

    // Convert PostView to FeedViewPost for caching
    let feedViewPost = AppBskyFeedDefs.FeedViewPost(
      post: postView,
      reply: nil,
      reason: nil,
      feedContext: nil,
      reqId: nil
    )

    // Create cached post with special feedType for notification prefetch
    guard
      let cachedPost = CachedFeedViewPost(
        from: feedViewPost,
        cursor: nil,
        feedType: "notification-prefetch",
        feedOrder: nil
      )
    else {
      notificationLogger.warning("Failed to create CachedFeedViewPost from prefetched post")
      return
    }

    await MainActor.run {
      // Upsert: update existing post or insert new one to avoid constraint violations
      let postId = cachedPost.id
      let postFeedType = cachedPost.feedType
      let descriptor = FetchDescriptor<CachedFeedViewPost>(
        predicate: #Predicate<CachedFeedViewPost> { post in
          post.id == postId && post.feedType == postFeedType
        }
      )

      do {
        let existing = try modelContext.fetch(descriptor)
        let savedPost = modelContext.upsert(
          cachedPost,
          existingModel: existing.first,
          update: { existingPost, newPost in existingPost.update(from: newPost) }
        )
        try modelContext.save()
        if existing.isEmpty {
          notificationLogger.info("✅ Saved prefetched post to cache: \(postView.uri.uriString())")
        } else {
          notificationLogger.debug("Updated cached post: \(postView.uri.uriString())")
        }
      } catch {
        notificationLogger.error(
          "Failed to save prefetched post to cache: \(error.localizedDescription)")
      }
    }
  }

  /// Prefetch images from a post for faster rendering
  private func prefetchPostImages(_ post: AppBskyFeedDefs.PostView) async {
    var imagesToPrefetch: [URL] = []

    // Author avatar
    if let avatarUri = post.author.avatar, let avatarUrl = URL(string: avatarUri.uriString()) {
      imagesToPrefetch.append(avatarUrl)
    }

    // Embedded images
    if let embed = post.embed {
      switch embed {
      case .appBskyEmbedImagesView(let imagesView):
        for image in imagesView.images {
          if let thumbUrl = URL(string: image.thumb.uriString()) {
            imagesToPrefetch.append(thumbUrl)
          }
          if let fullsizeUrl = URL(string: image.fullsize.uriString()) {
            imagesToPrefetch.append(fullsizeUrl)
          }
        }
      case .appBskyEmbedGalleryView(let galleryView):
        for item in galleryView.items {
          guard case .appBskyEmbedGalleryViewImage(let image) = item else { continue }
          if let thumbUrl = URL(string: image.thumbnail.uriString()) {
            imagesToPrefetch.append(thumbUrl)
          }
          if let fullsizeUrl = URL(string: image.fullsize.uriString()) {
            imagesToPrefetch.append(fullsizeUrl)
          }
        }
      case .appBskyEmbedRecordWithMediaView(let recordWithMediaView):
        if case .appBskyEmbedImagesView(let imagesView) = recordWithMediaView.media {
          for image in imagesView.images {
            if let thumbUrl = URL(string: image.thumb.uriString()) {
              imagesToPrefetch.append(thumbUrl)
            }
          }
        }
        if case .appBskyEmbedGalleryView(let galleryView) = recordWithMediaView.media {
          for item in galleryView.items {
            guard case .appBskyEmbedGalleryViewImage(let image) = item else { continue }
            if let thumbUrl = URL(string: image.thumbnail.uriString()) {
              imagesToPrefetch.append(thumbUrl)
            }
          }
        }
      default:
        break
      }
    }

    // Prefetch all images using Nuke
    await withTaskGroup(of: Void.self) { group in
      for imageUrl in imagesToPrefetch {
        group.addTask {
          do {
            let request = Nuke.ImageRequest(url: imageUrl)
            _ = try await Nuke.ImagePipeline.shared.image(for: request)
          } catch {
            // Silent failure - prefetching is opportunistic
          }
        }
      }
    }

    if !imagesToPrefetch.isEmpty {
      notificationLogger.info("Prefetched \(imagesToPrefetch.count) images from notification post")
    }
  }

  @MainActor
  private func ensureActiveAccount(for did: String) async {
    // Get the AppStateManager to handle account switching
    let appStateManager = AppStateManager.shared

    // Check if we're already on the correct account
    if appStateManager.lifecycle.userDID == did {
      return
    }

    notificationLogger.info("Switching active account to \(did) for notification navigation")

    // Use AppStateManager to switch accounts - it manages multiple AppState instances
    let outcome = await appStateManager.switchAccount(to: did)
    appStateManager.presentAccountSwitchOutcome(outcome)
    guard appStateManager.lifecycle.userDID == did else {
      notificationLogger.warning("Notification account switch did not reach the requested account")
      return
    }
    notificationLogger.info("Switched to the requested account for notification navigation")
  }

  // MARK: - Privacy-Preserving Account Matching

  /// Compute SHA-256 hash of a DID for push notification account matching.
  private func hashForAccountMatching(_ did: String) -> String {
    let digest = SHA256.hash(data: Data(did.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  /// Resolve recipient DID from push payload, supporting both hash-based and legacy fields.
  private func resolveRecipientDID(from userInfo: [AnyHashable: Any]) -> String? {
    // Prefer explicit DID (set by NSE after resolving hash, or legacy payload)
    if let did = userInfo["recipient_did"] as? String {
      return did
    }
    // Fall back to resolving recipient_account hash against local accounts
    if let hash = userInfo["recipient_account"] as? String {
      return MainActor.assumeIsolated {
        let appStateManager = AppStateManager.shared
        if let activeDID = appStateManager.lifecycle.userDID,
          hashForAccountMatching(activeDID) == hash {
          return activeDID
        }
        for did in appStateManager.authenticatedDIDs {
          if hashForAccountMatching(did) == hash {
            return did
          }
        }
        return nil
      }
    }
    return nil
  }

  /// Handle navigation from a notification tap
  private func handleNotificationNavigation(uriString: String, type: String, target: NavigationTarget) async {
    #if os(iOS)
    // Handle chat notifications differently
    if type == "chat" {
      await handleChatNotificationNavigation(uriString, target: target)
      return
    }
    #endif

    // CRITICAL FIX: Get the CURRENT AppState from AppStateManager, not the cached reference
    // After account switch, self.appState may point to the OLD account's AppState
    guard
      let currentAppState = await MainActor.run(body: {
        if case .authenticated(let state) = AppStateManager.shared.lifecycle,
           state.userDID == target.accountDID {
          return state
        }
        return nil
      })
    else {
      notificationLogger.error("Cannot navigate - no authenticated AppState")
      return
    }

    // Determine navigation destination based on notification type
    do {
      let destination = try createNavigationDestination(from: uriString, type: type)

      // Use main actor to update UI
      await MainActor.run {
        // Navigate to destination in home tab (index 0)
        guard AppStateManager.shared.lifecycle.userDID == target.accountDID else { return }
        SceneRouteCoordinator.shared.submit(SceneRouteRequest(accountDID: target.accountDID,
          command: .navigate(destination, tabIndex: 0), preferredSceneID: target.preferredSceneID))
        notificationLogger.info("Successfully navigated to destination from notification")
      }
    } catch {
      notificationLogger.error(
        "Failed to create navigation destination: \(error.localizedDescription)")
    }
  }

  /// Handle navigation from a chat notification tap
  #if os(iOS)
  private func handleChatNotificationNavigation(_ uriString: String, target: NavigationTarget) async {
    // CRITICAL FIX: Get the CURRENT AppState from AppStateManager, not the cached reference
    // After account switch, self.appState may point to the OLD account's AppState
    guard
      let currentAppState = await MainActor.run(body: {
        if case .authenticated(let state) = AppStateManager.shared.lifecycle,
           state.userDID == target.accountDID {
          return state
        }
        return nil
      })
    else {
      notificationLogger.error("Cannot navigate to chat - no authenticated AppState")
      return
    }

    // For chat notifications, uriString contains the conversationID
    let conversationID = uriString

    await MainActor.run {
      guard AppStateManager.shared.lifecycle.userDID == target.accountDID else { return }
      SceneRouteCoordinator.shared.submit(SceneRouteRequest(accountDID: target.accountDID,
        command: .navigate(.conversation(conversationID), tabIndex: 4),
        preferredSceneID: target.preferredSceneID))
    }
  }
  #endif
}

// MARK: - Notification Preferences Model

/// Represents user preferences for notifications (channels and filters)
/// The authenticated preference/inbox boundary can be isolated without APNs or OS permission work.
struct NotificationPreferencesService: Sendable {
  var authenticatedDID: @MainActor @Sendable (ATProtoClient) async throws -> String
  var fetch: @MainActor @Sendable (ATProtoClient) async throws -> AppBskyNotificationDefs.Preferences
  var save: @MainActor @Sendable (ATProtoClient, AppBskyNotificationPutPreferencesV2.Input) async throws -> AppBskyNotificationDefs.Preferences?
  var unreadCount: @MainActor @Sendable (ATProtoClient) async throws -> Int

  static let live = Self(
    authenticatedDID: { try await $0.getDid() },
    fetch: { client in
      let (code, output) = try await client.app.bsky.notification.getPreferences(input: .init())
      guard code == 200, let output else {
        throw NotificationManager.NotificationServiceError.serverError("Couldn’t load notification preferences (HTTP \(code)).")
      }
      return output.preferences
    },
    save: { client, input in
      let (code, output) = try await client.app.bsky.notification.putPreferencesV2(input: input)
      guard (200 ... 299).contains(code) else {
        throw NotificationManager.NotificationServiceError.serverError("Couldn’t save notification preferences (HTTP \(code)).")
      }
      return output?.preferences
    },
    unreadCount: { client in
      let (code, output) = try await client.app.bsky.notification.getUnreadCount(input: .init())
      guard code == 200, let output else {
        throw NotificationManager.NotificationServiceError.serverError("Couldn’t load unread activity (HTTP \(code)).")
      }
      return output.count
    }
  )
}

public struct NotificationPreferences: Codable, Equatable, Sendable {
  public var chat: AppBskyNotificationDefs.ChatPreference
  public var follow: AppBskyNotificationDefs.FilterablePreference
  public var like: AppBskyNotificationDefs.FilterablePreference
  public var likeViaRepost: AppBskyNotificationDefs.FilterablePreference
  public var mention: AppBskyNotificationDefs.FilterablePreference
  public var quote: AppBskyNotificationDefs.FilterablePreference
  public var reply: AppBskyNotificationDefs.FilterablePreference
  public var repost: AppBskyNotificationDefs.FilterablePreference
  public var repostViaRepost: AppBskyNotificationDefs.FilterablePreference
  public var starterpackJoined: AppBskyNotificationDefs.Preference
  public var subscribedPost: AppBskyNotificationDefs.Preference
  public var unverified: AppBskyNotificationDefs.Preference
  public var verified: AppBskyNotificationDefs.Preference

  public init() {
    chat = .init(include: "all", push: true)
    follow = .init(include: "all", list: true, push: true)
    like = .init(include: "all", list: true, push: true)
    likeViaRepost = .init(include: "all", list: true, push: true)
    mention = .init(include: "all", list: true, push: true)
    quote = .init(include: "all", list: true, push: true)
    reply = .init(include: "all", list: true, push: true)
    repost = .init(include: "all", list: true, push: true)
    repostViaRepost = .init(include: "all", list: true, push: true)
    starterpackJoined = .init(list: true, push: true)
    subscribedPost = .init(list: true, push: true)
    unverified = .init(list: true, push: true)
    verified = .init(list: true, push: true)
  }

  public init(serverPreferences: AppBskyNotificationDefs.Preferences) {
    chat = serverPreferences.chat
    follow = serverPreferences.follow
    like = serverPreferences.like
    likeViaRepost = serverPreferences.likeViaRepost
    mention = serverPreferences.mention
    quote = serverPreferences.quote
    reply = serverPreferences.reply
    repost = serverPreferences.repost
    repostViaRepost = serverPreferences.repostViaRepost
    starterpackJoined = serverPreferences.starterpackJoined
    subscribedPost = serverPreferences.subscribedPost
    unverified = serverPreferences.unverified
    verified = serverPreferences.verified
  }

  public func toServerPreferences() -> AppBskyNotificationDefs.Preferences {
    AppBskyNotificationDefs.Preferences(
      chat: chat,
      follow: follow,
      like: like,
      likeViaRepost: likeViaRepost,
      mention: mention,
      quote: quote,
      reply: reply,
      repost: repost,
      repostViaRepost: repostViaRepost,
      starterpackJoined: starterpackJoined,
      subscribedPost: subscribedPost,
      unverified: unverified,
      verified: verified
    )
  }

  public func toPutPreferencesInput() -> AppBskyNotificationPutPreferencesV2.Input {
    AppBskyNotificationPutPreferencesV2.Input(
      chat: chat,
      follow: follow,
      like: like,
      likeViaRepost: likeViaRepost,
      mention: mention,
      quote: quote,
      reply: reply,
      repost: repost,
      repostViaRepost: repostViaRepost,
      starterpackJoined: starterpackJoined,
      subscribedPost: subscribedPost,
      unverified: unverified,
      verified: verified
    )
  }

  /// Omitted categories are preserved by putPreferencesV2, including custom service fields.
  public func toPutPreferencesInput(changedFrom prior: NotificationPreferences) -> AppBskyNotificationPutPreferencesV2.Input {
    AppBskyNotificationPutPreferencesV2.Input(
      chat: chat == prior.chat ? nil : chat,
      follow: follow == prior.follow ? nil : follow,
      like: like == prior.like ? nil : like,
      likeViaRepost: likeViaRepost == prior.likeViaRepost ? nil : likeViaRepost,
      mention: mention == prior.mention ? nil : mention,
      quote: quote == prior.quote ? nil : quote,
      reply: reply == prior.reply ? nil : reply,
      repost: repost == prior.repost ? nil : repost,
      repostViaRepost: repostViaRepost == prior.repostViaRepost ? nil : repostViaRepost,
      starterpackJoined: starterpackJoined == prior.starterpackJoined ? nil : starterpackJoined,
      subscribedPost: subscribedPost == prior.subscribedPost ? nil : subscribedPost,
      unverified: unverified == prior.unverified ? nil : unverified,
      verified: verified == prior.verified ? nil : verified
    )
  }
}

extension AppBskyNotificationPutPreferencesV2.Input {
  var isEmptyNotificationUpdate: Bool {
    chat == nil && follow == nil && like == nil && likeViaRepost == nil && mention == nil && quote == nil && reply == nil && repost == nil && repostViaRepost == nil && starterpackJoined == nil && subscribedPost == nil && unverified == nil && verified == nil
  }

  var notificationChangesDescription: String {
    var changes: [String] = []
    if let chat { changes.append("Direct Messages: \(chat.push ? "Push" : "Off")") }
    if let follow { changes.append("New Followers: \(follow.summaryDescription)") }
    if let like { changes.append("Likes: \(like.summaryDescription)") }
    if let likeViaRepost { changes.append("Likes of Your Reposts: \(likeViaRepost.summaryDescription)") }
    if let mention { changes.append("Mentions: \(mention.summaryDescription)") }
    if let quote { changes.append("Quotes: \(quote.summaryDescription)") }
    if let reply { changes.append("Replies: \(reply.summaryDescription)") }
    if let repost { changes.append("Reposts: \(repost.summaryDescription)") }
    if let repostViaRepost { changes.append("Reposts of Your Reposts: \(repostViaRepost.summaryDescription)") }
    if let starterpackJoined { changes.append("Starter Pack Signups: \(starterpackJoined.summaryDescription)") }
    if let subscribedPost { changes.append("Posts from Your Subscriptions: \(subscribedPost.summaryDescription)") }
    if let unverified { changes.append("Verification Removed: \(unverified.summaryDescription)") }
    if let verified { changes.append("Account Verified: \(verified.summaryDescription)") }
    return changes.joined(separator: "\n")
  }
}

extension AppBskyNotificationDefs.FilterablePreference {
  public var summaryDescription: String {
    guard list || push else { return "Off" }
    let channelText: String
    if list && push {
      channelText = "In-App, Push"
    } else if list {
      channelText = "In-App"
    } else {
      channelText = "Push"
    }
    let audienceText: String
    switch include {
    case "follows": audienceText = "People I follow"
    case "all": audienceText = "Everyone"
    default: audienceText = "Existing audience"
    }
    return "\(channelText), \(audienceText)"
  }
}

extension AppBskyNotificationDefs.Preference {
  public var summaryDescription: String {
    guard list || push else { return "Off" }
    if list && push {
      return "In-App, Push"
    } else if list {
      return "In-App"
    } else {
      return "Push"
    }
  }
}

private actor RegistrationCoordinator {
  private var inFlight = false

  func begin() -> Bool {
    if inFlight {
      return false
    }
    inFlight = true
    return true
  }

  func finish() {
    inFlight = false
  }
}
