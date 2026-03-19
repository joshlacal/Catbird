import CatbirdMLSCore
import CryptoKit
import Foundation
import GRDB
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

/// Payload used for generating local chat notifications when background polling detects new messages
struct ChatNotificationPayload {
  let messageID: String
  let conversationID: String
  let senderDisplayName: String
  let senderHandle: String
  let conversationTitle: String
  let messagePreview: String
  let unreadCount: Int
}

/// Manages push notifications registration and handling for the Catbird app
@Observable
final class NotificationManager: NSObject {
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

  /// Dedicated notification namespace routed to the Nest push service.
  private let notificationServiceNamespace = "app.bsky.notification"

  /// DID for the Nest push service that owns notification XRPC.
  private let notificationServiceDIDString: String

  /// Latest server-side notification preferences snapshot.
  @ObservationIgnored
  private var serverPreferencesSnapshot: AppBskyNotificationDefs.Preferences?

  /// Persisted key prefix for per-account chat notification preference
  private let chatNotificationsDefaultsKeyPrefix = "chatNotificationsEnabled"

  /// Whether chat message notifications are enabled locally (per-account)
  var chatNotificationsEnabled: Bool = true {
    didSet {
      guard shouldPersistChatPreference else {
        return
      }
      saveChatNotificationPreference()
    }
  }

  /// Save chat notification preference for the current account
  private func saveChatNotificationPreference() {
    guard let defaults = UserDefaults(suiteName: "group.blue.catbird.shared"),
      let did = appState?.userDID
    else {
      return
    }

    let key = "\(chatNotificationsDefaultsKeyPrefix)_\(did)"
    defaults.set(chatNotificationsEnabled, forKey: key)
    notificationLogger.info(
      "Chat notification preference updated for \(did): \(self.chatNotificationsEnabled ? "enabled" : "disabled")"
    )
  }

  /// Load chat notification preference for the current account
  private func loadChatNotificationPreference() async {
    guard let defaults = UserDefaults(suiteName: "group.blue.catbird.shared"),
      let client = client,
      let did = try? await client.getDid()
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

  // MARK: - Initialization

  init(
    notificationServiceDIDString: String = {
      #if DEBUG
        "did:web:api.catbird.blue"
//        "did:web:dev-api.catbird.blue"
      #else
        "did:web:api.catbird.blue"
      #endif
    }()
  ) {
    self.notificationServiceDIDString = notificationServiceDIDString
    super.init()

    // Chat notification preference will be loaded per-account when client is set
    shouldPersistChatPreference = true

    // Initialize widget with a test value to ensure it's populated
    #if DEBUG
      setupTestWidgetData()
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
  func updateClient(_ newClient: ATProtoClient?) async {
    let previousClient = client
    self.client = newClient

    notificationLogger.info(
      "🔄 Client updated: hasNewClient=\(newClient != nil), hasDeviceToken=\(self.deviceToken != nil)"
    )

    // Clear notification preferences when switching accounts to prevent state leakage
    if newClient != nil && previousClient != nil {
      notificationLogger.info("🧹 Clearing notification preferences for account switch")
      preferences = NotificationPreferences()
      serverPreferencesSnapshot = nil
    }

    // Load chat notification preference for the new account
    if let newClient {
      await configureNotificationServiceRouting(on: newClient)
      await loadChatNotificationPreference()
      await refreshNotificationPreferences()
    }

    // If we have a valid token and a new client, register the device
    if newClient != nil, let deviceToken = deviceToken {
      notificationLogger.info("🚀 Triggering device registration from updateClient")
      await registerDeviceToken(deviceToken)
    } else if newClient == nil {
      notificationLogger.info("🧹 Client cleared - cleaning up notifications")
      // Client was cleared (user logged out), clean up notifications
      await cleanupNotifications(previousClient: previousClient)
    } else if newClient != nil && deviceToken == nil {
      // Client available but no device token - notification preferences are stored locally
      notificationLogger.info(
        "⚠️ Client available but no device token yet - local preferences remain active")
    } else {
      notificationLogger.info("ℹ️ No action needed - no client and no token")
    }
  }

  private func configureNotificationServiceRouting(on client: ATProtoClient) async {
    let routedEndpoints = [
      "app.bsky.notification.registerPush",
      "app.bsky.notification.unregisterPush",
      "app.bsky.notification.getPreferences",
      "app.bsky.notification.putPreferencesV2",
      "app.bsky.notification.listActivitySubscriptions",
      "app.bsky.notification.putActivitySubscription",
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

  private func refreshNotificationPreferences() async {
    guard let client else { return }
    _ = await fetchNotificationPreferences(using: client)
  }

  @discardableResult
  private func fetchNotificationPreferences(using client: ATProtoClient) async
    -> AppBskyNotificationDefs.Preferences?
  {
    do {
      await configureNotificationServiceRouting(on: client)
      let (responseCode, output) = try await client.app.bsky.notification.getPreferences(input: .init())

      guard responseCode == 200, let output else {
        notificationLogger.warning(
          "Failed to fetch notification preferences via XRPC: HTTP \(responseCode)")
        return nil
      }

      applyNotificationPreferencesSnapshot(output.preferences)
      return output.preferences
    } catch {
      notificationLogger.error(
        "Failed to fetch notification preferences via XRPC: \(error.localizedDescription)")
      return nil
    }
  }

  private func applyNotificationPreferencesSnapshot(
    _ serverPreferences: AppBskyNotificationDefs.Preferences
  ) {
    serverPreferencesSnapshot = serverPreferences
    preferences = NotificationPreferences(serverPreferences: serverPreferences)
  }

  private func currentNotificationPreferencesSnapshot(using client: ATProtoClient) async
    -> AppBskyNotificationDefs.Preferences?
  {
    if let serverPreferencesSnapshot {
      return serverPreferencesSnapshot
    }

    return await fetchNotificationPreferences(using: client)
  }

  private func makeNotificationPreferencesInput(
    from serverPreferences: AppBskyNotificationDefs.Preferences
  ) -> AppBskyNotificationPutPreferencesV2.Input {
    AppBskyNotificationPutPreferencesV2.Input(
      chat: AppBskyNotificationDefs.ChatPreference(
        include: serverPreferences.chat.include,
        push: serverPreferences.chat.push
      ),
      follow: AppBskyNotificationDefs.FilterablePreference(
        include: serverPreferences.follow.include,
        list: serverPreferences.follow.list,
        push: preferences.follows
      ),
      like: AppBskyNotificationDefs.FilterablePreference(
        include: serverPreferences.like.include,
        list: serverPreferences.like.list,
        push: preferences.likes
      ),
      likeViaRepost: AppBskyNotificationDefs.FilterablePreference(
        include: serverPreferences.likeViaRepost.include,
        list: serverPreferences.likeViaRepost.list,
        push: preferences.likeViaRepost
      ),
      mention: AppBskyNotificationDefs.FilterablePreference(
        include: serverPreferences.mention.include,
        list: serverPreferences.mention.list,
        push: preferences.mentions
      ),
      quote: AppBskyNotificationDefs.FilterablePreference(
        include: serverPreferences.quote.include,
        list: serverPreferences.quote.list,
        push: preferences.quotes
      ),
      reply: AppBskyNotificationDefs.FilterablePreference(
        include: serverPreferences.reply.include,
        list: serverPreferences.reply.list,
        push: preferences.replies
      ),
      repost: AppBskyNotificationDefs.FilterablePreference(
        include: serverPreferences.repost.include,
        list: serverPreferences.repost.list,
        push: preferences.reposts
      ),
      repostViaRepost: AppBskyNotificationDefs.FilterablePreference(
        include: serverPreferences.repostViaRepost.include,
        list: serverPreferences.repostViaRepost.list,
        push: preferences.repostViaRepost
      ),
      starterpackJoined: AppBskyNotificationDefs.Preference(
        list: serverPreferences.starterpackJoined.list,
        push: serverPreferences.starterpackJoined.push
      ),
      subscribedPost: AppBskyNotificationDefs.Preference(
        list: serverPreferences.subscribedPost.list,
        push: serverPreferences.subscribedPost.push
      ),
      unverified: AppBskyNotificationDefs.Preference(
        list: serverPreferences.unverified.list,
        push: serverPreferences.unverified.push
      ),
      verified: AppBskyNotificationDefs.Preference(
        list: serverPreferences.verified.list,
        push: serverPreferences.verified.push
      )
    )
  }

  /// Request notification permissions from the user
  @MainActor
  func requestNotificationPermission() async {
    notificationLogger.info("Requesting notification permission")
    status = .waitingForPermission

    do {
      // Request authorization
      let center = UNUserNotificationCenter.current()
      let options: UNAuthorizationOptions = [.alert, .sound, .badge]
      let granted = try await center.requestAuthorization(options: options)

      // Update state based on user's choice
      if granted {
        notificationLogger.info("Notification permission granted")
        notificationsEnabled = true

        // Register for remote notifications on the main thread
        notificationLogger.info("📱 Permission granted, registering for remote notifications...")
        await MainActor.run {
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
        if settings.authorizationStatus == .authorized {
          notificationLogger.info("Notification settings confirmed authorized")
        } else {
          notificationLogger.warning(
            "Unexpected notification settings status: \(settings.authorizationStatus.rawValue)")
        }
      } else {
        notificationLogger.notice("Notification permission denied by user")
        status = .permissionDenied
        notificationsEnabled = false
      }
    } catch {
      notificationLogger.error(
        "Error requesting notification permission: \(error.localizedDescription)")
      status = .registrationFailed(error)
      notificationsEnabled = false
    }
  }

  /// Request notifications after successful login
  @MainActor
  func requestNotificationsAfterLogin() async {
    // Only request if we haven't already been granted permission
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()

    if settings.authorizationStatus == .notDetermined {
      await requestNotificationPermission()
    }
  }

  /// Check the current notification permission status
  @MainActor
  func checkNotificationStatus() async {
    notificationLogger.debug("Checking notification status")

    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()

    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      notificationLogger.info("Notifications are authorized")
      notificationsEnabled = true

      // Make sure we're registered for remote notifications
      notificationLogger.info(
        "📱 Permissions already granted, registering for remote notifications...")
      await MainActor.run {
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
      }

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

    if status == .registered,
      let previousToken = lastRegisteredDeviceToken,
      previousToken == deviceToken
    {
      notificationLogger.info(
        "🔁 Device token already registered; skipping duplicate registration request")
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

    // Register with MLS service
    await registerMLSDeviceToken(deviceToken)
  }

  /// Update notification preferences
  func updatePreferences(_ newPreferences: NotificationPreferences) async {
    preferences = newPreferences

    // Only send update if we're in a good state
    guard status == .registered else {
      notificationLogger.warning("Not updating preferences - not properly registered")
      return
    }

    // Send new preferences to the server
    await updateNotificationPreferences()
  }

  /// Toggle a specific notification preference
  func togglePreference(_ type: NotificationTypes) async {
    var newPreferences = preferences

    switch type {
    case .mentions:
      newPreferences.mentions.toggle()
    case .replies:
      newPreferences.replies.toggle()
    case .likes:
      newPreferences.likes.toggle()
    case .follows:
      newPreferences.follows.toggle()
    case .reposts:
      newPreferences.reposts.toggle()
    case .quotes:
      newPreferences.quotes.toggle()
    case .likeViaRepost:
      newPreferences.likeViaRepost.toggle()
    case .repostViaRepost:
      newPreferences.repostViaRepost.toggle()
    }

    await updatePreferences(newPreferences)
  }

  /// Starts periodic checking of unread notifications
  func startUnreadNotificationChecking() {
    // Stop any existing timer
    unreadCheckTimer?.invalidate()

    // Create a new timer (every 60 seconds)
    unreadCheckTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) {
      [weak self] _ in
      Task { [weak self] in
        await self?.checkUnreadNotifications()
      }
    }

    // Initial check
    Task {
      await checkUnreadNotifications()
    }

    notificationLogger.info("Started background notification checking")
  }

  /// Cleanup notifications when user logs out
  func cleanupNotifications(previousClient: ATProtoClient? = nil) async {
    notificationLogger.info("Cleaning up notifications after logout")

    // Stop unread checking timer
    unreadCheckTimer?.invalidate()
    unreadCheckTimer = nil

    // Unregister from notification service if we have a device token
    if let deviceToken = deviceToken {
      do {
        let didSource = previousClient ?? client
        if let did = try await didSource?.getDid() {
          await unregisterDeviceToken(deviceToken, did: did, using: didSource)
          await unregisterMLSDeviceToken(deviceToken)
        }
      } catch {
        notificationLogger.error(
          "Failed to determine DID during cleanup: \(error.localizedDescription)")
      }
    }

    // Reset state
    status = .unknown
    notificationsEnabled = false
    unreadCount = 0
    preferences = NotificationPreferences()
    serverPreferencesSnapshot = nil
    mutedUsers.removeAll()
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
    // Only check when notifications are enabled and we are registered
    guard notificationsEnabled, status == .registered, let client = client else {
      notificationLogger.warning("Cannot check unread notifications - not properly configured")
      return
    }

    do {
      await configureNotificationServiceRouting(on: client)
      let (responseCode, output) = try await client.app.bsky.notification.getUnreadCount(
        input: .init()
      )

      guard responseCode == 200, let output = output else {
        notificationLogger.error("Failed to get unread notification count: \(responseCode)")
        return
      }

      if output.count != unreadCount {
        unreadCount = output.count

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
    Task { @MainActor in
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

  // MARK: - Chat Notifications

  /// Schedule a local notification for a new chat message
  @MainActor
  func scheduleChatNotification(_ payload: ChatNotificationPayload) async {
    // Check if chat notifications are enabled
    guard chatNotificationsEnabled else {
      notificationLogger.debug(
        "Chat notifications disabled, skipping notification for message \(payload.messageID)")
      return
    }

    // Check if we have permission to send notifications
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()

    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      break
    default:
      notificationLogger.warning("No permission to send chat notifications")
      return
    }

    // Create notification content
    let content = UNMutableNotificationContent()
    content.title = payload.conversationTitle
    content.body = "\(payload.senderDisplayName): \(payload.messagePreview)"
    content.sound = .default
    content.badge = NSNumber(value: payload.unreadCount)

    // Add custom data for handling tap
    content.userInfo = [
      "type": "chat",
      "conversationID": payload.conversationID,
      "messageID": payload.messageID,
      "senderHandle": payload.senderHandle,
    ]

    // Create unique identifier to prevent duplicates
    let identifier = "chat-\(payload.conversationID)-\(payload.messageID)"

    // Create request with immediate trigger
    let request = UNNotificationRequest(
      identifier: identifier,
      content: content,
      trigger: nil  // Immediate delivery
    )

    do {
      try await center.add(request)
      notificationLogger.info(
        "Scheduled chat notification for message \(payload.messageID) in conversation \(payload.conversationID)"
      )
    } catch {
      notificationLogger.error(
        "Failed to schedule chat notification: \(error.localizedDescription)")
    }
  }

  // MARK: - Relationship Sync Methods

  /// Synchronizes muted and blocked users with the notification server
  func syncRelationships() async {
    guard notificationsEnabled else {
      notificationLogger.info("Not syncing relationships - notifications are disabled")
      return
    }

    await gatherRelationships()
    lastRelationshipSync = Date()
  }

  /// Gathers current relationships from the graph manager
  private func gatherRelationships() async {
    guard let appState = appState else {
      notificationLogger.warning("Cannot gather relationships - no AppState reference")
      return
    }

    do {
      // Use existing graph manager to refresh caches
      try await appState.graphManager.refreshMuteCache()
      try await appState.graphManager.refreshBlockCache()

      // Get muted and blocked users
      await MainActor.run {
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
  func syncAllUserData() async {
    guard notificationsEnabled else {
      notificationLogger.info("Not syncing user data - notifications are disabled")
      return
    }

    guard status == .registered else {
      notificationLogger.warning("Cannot sync - not properly registered")
      return
    }

    await refreshNotificationPreferences()
    await syncRelationships()
    if let appState {
      let service = await MainActor.run { appState.activitySubscriptionService }
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
  private func fetchModerationLists(
    client: ATProtoClient,
    type: String
  ) async throws -> [(uri: String, purpose: String, name: String?)] {
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

        if result.responseCode == 200, let output = result.data as? AppBskyGraphGetListBlocks.Output
        {
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

        if result.responseCode == 200, let output = result.data as? AppBskyGraphGetListMutes.Output
        {
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
  func muteThreadNotifications(threadRootURI: String) async throws {
    guard let client = client else {
      throw NotificationServiceError.clientNotConfigured
    }

    let input = AppBskyGraphMuteThread.Input(root: try ATProtocolURI(uriString: threadRootURI))
    let responseCode = try await client.app.bsky.graph.muteThread(input: input)
    guard responseCode == 200 else {
      throw NotificationServiceError.serverError("HTTP \(responseCode)")
    }
  }

  /// Unmutes a thread for push notifications
  func unmuteThreadNotifications(threadRootURI: String) async throws {
    guard let client = client else {
      throw NotificationServiceError.clientNotConfigured
    }

    let input = AppBskyGraphUnmuteThread.Input(root: try ATProtocolURI(uriString: threadRootURI))
    let responseCode = try await client.app.bsky.graph.unmuteThread(input: input)
    guard responseCode == 200 else {
      throw NotificationServiceError.serverError("HTTP \(responseCode)")
    }
  }

  // MARK: - Private Methods

  private func hexString(from token: Data) -> String {
    token.map { String(format: "%02.2hhx", $0) }.joined()
  }

  /// Fetch the current set of activity subscriptions from the notification server.
  func fetchActivitySubscriptionsFromServer() async -> [ActivitySubscriptionServerRecord]? {
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
      let (responseCode, output) = try await client.app.bsky.notification.listActivitySubscriptions(
        input: .init(limit: 100)
      )

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
      notificationLogger.error(
        "Error fetching activity subscriptions via XRPC: \(error.localizedDescription)")
    }

    return nil
  }

  /// Create or update an activity subscription on the notification server.
  func updateActivitySubscriptionOnServer(
    subjectDid: String,
    includePosts: Bool,
    includeReplies: Bool
  ) async {
    guard includePosts || includeReplies else {
      await removeActivitySubscriptionFromServer(
        subjectDid: subjectDid
      )
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
      notificationLogger.error(
        "Error syncing activity subscription for \(subjectDid) via XRPC: \(error.localizedDescription)"
      )
    }
  }

  /// Remove an activity subscription from the notification server.
  func removeActivitySubscriptionFromServer(
    subjectDid: String
  ) async {
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
  private func registerDeviceToken(_ token: Data) async {
    let tokenHex = hexString(from: token)
    notificationLogger.info("🔄 Starting device token registration: \(tokenHex.prefix(16))...")

    guard await registrationCoordinator.begin() else {
      notificationLogger.info("⏳ Registration already in progress; ignoring duplicate request")
      return
    }
    defer {
      Task { await registrationCoordinator.finish() }
    }

    guard let client = client else {
      notificationLogger.warning("❌ Cannot register device token - no client available")
      status = .disabled
      return
    }

    do {
      await configureNotificationServiceRouting(on: client)
      let input = AppBskyNotificationRegisterPush.Input(
        serviceDid: try notificationServiceDID(),
        token: tokenHex,
        platform: pushPlatform,
        appId: pushAppID
      )
      let responseCode = try await client.app.bsky.notification.registerPush(input: input)

      switch responseCode {
      case 200 ... 299:
        notificationLogger.info("✅ Successfully registered device token via notification XRPC")
        status = .registered
        lastRegisteredDeviceToken = token
        await refreshNotificationPreferences()
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
      notificationLogger.error(
        "❌ Error registering device token via XRPC: \(error.localizedDescription)")
      status = .registrationFailed(error)
    }
  }

  /// Register device token with MLS server
  private func registerMLSDeviceToken(_ token: Data) async {
    #if os(iOS)
      guard let appState = appState else { return }
      guard let client = client else { return }

      let tokenHex = hexString(from: token)

      do {
        // Get the user's DID
        let did = try await client.getDid()

        // Ensure device is registered with MLS first (Phase 1 & 2)
        // This creates the device record on the server if it doesn't exist
        _ = try await MLSClient.shared.ensureDeviceRegistered(userDid: did)

        // Ensure device record is published for this now-registered/opted-in device.
        // Notification token registration can run before chat UI paths, so this
        // closes the gap where users become opted-in without device records.
        if let conversationManager = await appState.getMLSConversationManager() {
          do {
            try await conversationManager.ensureDeviceRecordPublished()
          } catch {
            notificationLogger.error(
              "❌ Failed to publish device record during token registration: \(error.localizedDescription)"
            )
          }
        }

        // Get the correct deviceId from the manager (it might differ from IDFV if server assigns it)
        guard let deviceInfo = await MLSClient.shared.getDeviceInfo(for: did) else {
          notificationLogger.error("❌ Failed to retrieve device info after registration")
          return
        }

        if let mlsClient = await appState.getMLSAPIClient() {
          notificationLogger.info("🚀 Registering device token with MLS server")

          let deviceName = UIDevice.current.name

          try await mlsClient.registerDeviceToken(
            deviceId: deviceInfo.deviceId,
            pushToken: tokenHex,
            deviceName: deviceName,
            platform: "ios"
          )
          notificationLogger.info("✅ Successfully registered device token with MLS server")
        }
      } catch {
        notificationLogger.error(
          "❌ Failed to register device token with MLS server: \(error.localizedDescription)")
      }
    #endif
  }

  /// Unregister device token from MLS server
  private func unregisterMLSDeviceToken(_ token: Data) async {
    #if os(iOS)
      guard let appState = appState else { return }

      // Use device identifier for vendor as deviceId (same as registration)
      let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"

      if let mlsClient = await appState.getMLSAPIClient() {
        notificationLogger.info("Unregistering device token from MLS server")
        do {
          try await mlsClient.unregisterDeviceToken(deviceId: deviceId)
          notificationLogger.info("✅ Successfully unregistered device token from MLS server")
        } catch {
          notificationLogger.error(
            "❌ Failed to unregister device token from MLS server: \(error.localizedDescription)")
        }
      }
    #endif
  }

  /// Update notification preferences on the server
  private func updateNotificationPreferences(
    attempt _: Int = 0
  ) async {
    guard let client = client else {
      notificationLogger.warning("Cannot update preferences - no client available")
      return
    }

    guard status == .registered else {
      notificationLogger.warning("Cannot update preferences - push registration not complete")
      return
    }

    do {
      await configureNotificationServiceRouting(on: client)

      guard let serverPreferences = await currentNotificationPreferencesSnapshot(using: client) else {
        notificationLogger.warning(
          "Cannot update notification preferences - current server preferences unavailable")
        return
      }

      let input = makeNotificationPreferencesInput(from: serverPreferences)
      let (responseCode, output) = try await client.app.bsky.notification.putPreferencesV2(
        input: input
      )

      switch responseCode {
      case 200 ... 299:
        if let updatedPreferences = output?.preferences {
          applyNotificationPreferencesSnapshot(updatedPreferences)
        } else {
          serverPreferencesSnapshot = nil
          await refreshNotificationPreferences()
        }
        notificationLogger.info("Successfully updated notification preferences via XRPC")
      default:
        throw NSError(
          domain: "NotificationManager",
          code: responseCode,
          userInfo: [
            NSLocalizedDescriptionKey: "Notification preferences update failed (HTTP \(responseCode))"
          ]
        )
      }
    } catch {
      notificationLogger.error(
        "Error updating notification preferences via XRPC: \(error.localizedDescription)")
    }
  }

  // MARK: - App Lifecycle

  @objc private func appDidBecomeActive() {
    // Check notification status when app becomes active
    Task {
      await checkNotificationStatus()

      // Also check for unread notifications
      await checkUnreadNotifications()

      // Sync relationships if we haven't in a while
      if let lastSync = lastRelationshipSync,
        Date().timeIntervalSince(lastSync) > 3600
      {  // If it's been over an hour
        await syncRelationships()
      }

      // Force update widget with current count to ensure it has data
      updateWidgetUnreadCount(unreadCount)
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
}
// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
  /// Handle notifications received while app is in the foreground
  ///
  /// CRITICAL: When app is in foreground, iOS bypasses the Notification Service Extension.
  /// We must decrypt MLS messages here to show meaningful notification content.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    notificationLogger.info("Received notification while app in foreground")

    let userInfo = notification.request.content.userInfo

    // Skip already-decrypted MLS notifications (prevent infinite loop)
    if userInfo["_mls_decrypted"] as? Bool == true {
      notificationLogger.debug("📦 [FG] Already decrypted MLS notification - showing as-is")
      completionHandler([.banner, .sound])
      return
    }

    // Check if this is an MLS message that needs decryption
    if let type = userInfo["type"] as? String, type == "mls_message" {
      notificationLogger.info("🔐 [FG] MLS message detected - attempting foreground decryption")

      // Extract MLS payload fields
      let ciphertext = userInfo["ciphertext"] as? String
      let convoId = userInfo["convo_id"] as? String
      let messageId = userInfo["message_id"] as? String
      let recipientDid: String? = resolveRecipientDID(from: userInfo)
      let senderDid = userInfo["sender_did"] as? String

      // Server ordering fields (more reliable than message_id for cache lookup)
      let epoch = (userInfo["epoch"] as? NSNumber)?.intValue ?? (userInfo["epoch"] as? Int)
      let seq = (userInfo["seq"] as? NSNumber)?.intValue ?? (userInfo["seq"] as? Int)

      // Skip self-sent messages (no notification needed)
      if let sender = senderDid, let recipient = recipientDid,
        sender.lowercased() == recipient.lowercased()
      {
        notificationLogger.info("🔇 [FG] Self-sent message - suppressing notification")
        completionHandler([])
        return
      }

      // Attempt to decrypt and show notification with decrypted content
      if let ciphertext = ciphertext,
        let convoId = convoId,
        let messageId = messageId,
        let recipientDid = recipientDid
      {

        Task {
          await decryptAndPresentMLSNotification(
            ciphertext: ciphertext,
            convoId: convoId,
            messageId: messageId,
            recipientDid: recipientDid,
            epoch: epoch,
            seq: seq,
            originalNotification: notification,
            completionHandler: completionHandler
          )
        }
        return
      } else {
        notificationLogger.warning("⚠️ [FG] Missing MLS payload fields - showing placeholder")
      }
    }

    // Handle non-MLS notifications (standard Bluesky notifications)
    if let uriString = userInfo["uri"] as? String,
      let typeString = userInfo["type"] as? String
    {
      Task {
        await prefetchNotificationContent(uri: uriString, type: typeString)
      }
    }

    // Show notification banner even when app is in foreground
    completionHandler([.banner, .sound])
  }

  /// Decrypt MLS message and present notification with decrypted content
  ///
  /// Called when an MLS push notification arrives while the app is in foreground.
  /// Since iOS bypasses the Notification Service Extension in this case, we must
  /// decrypt MLS messages here to show meaningful notification content.
  ///
  /// CRITICAL FIX (2024-12-22): Race Condition Prevention
  /// ═══════════════════════════════════════════════════════════════════════════
  /// Problem: When the app is in foreground, both the notification handler AND
  /// the main sync loop (polling) can race to decrypt the same message. This
  /// causes OpenMLS to throw SecretReuseError because MLS keys are single-use.
  ///
  /// Solution: For the ACTIVE user, do NOT attempt direct decryption here.
  /// Instead, rely on the main sync loop which is already running and will
  /// decrypt all pending messages in proper order. We poll the cache with
  /// exponential backoff, giving the sync loop time to process the message.
  ///
  /// For NON-ACTIVE users (account switch scenario), the sync loop is not
  /// running, so we must decrypt here using ephemeral database access.
  /// ═══════════════════════════════════════════════════════════════════════════
  private func decryptAndPresentMLSNotification(
    ciphertext: String,
    convoId: String,
    messageId: String,
    recipientDid: String,
    epoch: Int?,
    seq: Int?,
    originalNotification: UNNotification,
    completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) async {
    func getCachedPlaintextByOrder() async -> String? {
      guard let epoch, let seq else { return nil }
      do {
        let normalizedRecipientDid = recipientDid.trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased()
        let message = try await CatbirdMLSCore.MLSGRDBManager.shared.read(for: recipientDid) { db in
          try CatbirdMLSCore.MLSMessageModel
            .filter(CatbirdMLSCore.MLSMessageModel.Columns.conversationID == convoId)
            .filter(CatbirdMLSCore.MLSMessageModel.Columns.currentUserDID == normalizedRecipientDid)
            .filter(CatbirdMLSCore.MLSMessageModel.Columns.epoch == Int64(epoch))
            .filter(CatbirdMLSCore.MLSMessageModel.Columns.sequenceNumber == Int64(seq))
            .fetchOne(db)
        }

        if let message {
          if let plaintext = message.plaintext { return plaintext }

          // Control messages (reactions/readReceipts/etc) often have nil plaintext; derive from payload.
          if let payload = message.parsedPayload {
            switch payload.messageType {
            case .text:
              return payload.text
            case .reaction:
              if let reaction = payload.reaction {
                let verb = (reaction.action == .add) ? "Reacted with" : "Removed reaction"
                return "\(verb) \(reaction.emoji)"
              }
              return "Reaction update"
            case .readReceipt:
              return "Read receipt"
            case .typing:
              return "Typing..."
            case .adminRoster, .adminAction:
              return "Group update"
            case .system:
              return nil
            }
          }
        }

        return nil
      } catch {
        return nil
      }
    }
    func logCacheMissDetails(context: String) async {
      do {
        let normalizedRecipientDid = recipientDid.trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased()
        let (messageById, messageByOrder) = try await CatbirdMLSCore.MLSGRDBManager.shared.read(
          for: recipientDid
        ) { db -> (CatbirdMLSCore.MLSMessageModel?, CatbirdMLSCore.MLSMessageModel?) in
          let byId = try CatbirdMLSCore.MLSMessageModel
            .filter(CatbirdMLSCore.MLSMessageModel.Columns.messageID == messageId)
            .filter(CatbirdMLSCore.MLSMessageModel.Columns.currentUserDID == normalizedRecipientDid)
            .fetchOne(db)

          var byOrder: CatbirdMLSCore.MLSMessageModel?
          if byId == nil, let epoch, let seq {
            byOrder = try CatbirdMLSCore.MLSMessageModel
              .filter(CatbirdMLSCore.MLSMessageModel.Columns.conversationID == convoId)
              .filter(
                CatbirdMLSCore.MLSMessageModel.Columns.currentUserDID == normalizedRecipientDid
              )
              .filter(CatbirdMLSCore.MLSMessageModel.Columns.epoch == Int64(epoch))
              .filter(CatbirdMLSCore.MLSMessageModel.Columns.sequenceNumber == Int64(seq))
              .fetchOne(db)
          }

          return (byId, byOrder)
        }

        if let message = messageById ?? messageByOrder {
          let source = (messageById != nil) ? "message_id" : "epoch/seq"
          let payloadState: String
          if message.payloadJSON != nil {
            payloadState = "present"
          } else if message.payloadExpired {
            payloadState = "expired"
          } else {
            payloadState = "missing"
          }
          notificationLogger.info(
            "📦 [FG] Cache detail (\(context)) hit via \(source) - payload=\(payloadState), state=\(message.processingState), error=\(message.processingError ?? "nil")"
          )
        } else {
          notificationLogger.info(
            "📦 [FG] Cache detail (\(context)) no DB record found (messageId=\(messageId.prefix(16))...)"
          )
        }
      } catch {
        notificationLogger.warning(
          "⚠️ [FG] Cache detail (\(context)) lookup failed: \(error.localizedDescription)"
        )
      }
    }
    notificationLogger.info(
      "🔓 [FG] Starting MLS notification handling for message: \(messageId.prefix(16))...")
    notificationLogger.info("🔓 [FG] Recipient DID: \(recipientDid.prefix(24))...")

    // If we already have the payload cached (by server order), avoid any decryption attempt.
    if let cachedPlaintext = await getCachedPlaintextByOrder() {
      CatbirdMLSCore.MLSNotificationMetrics.increment(
        .cacheHitBeforeDecrypt,
        source: "foreground_pre_route_order_cache"
      )
      notificationLogger.info("📦 [FG] Cache HIT by (epoch,seq) - using cached content")
      await presentDecryptedNotification(
        plaintext: cachedPlaintext,
        convoId: convoId,
        messageId: messageId,
        recipientDid: recipientDid,
        originalNotification: originalNotification,
        completionHandler: completionHandler
      )
      return
    }

    // Route decryption ownership through the unified policy.
    let isActiveUser = await checkIfActiveUser(recipientDid)
    let executionContext: CatbirdMLSCore.MLSNotificationExecutionContext =
      isActiveUser ? .appForegroundActive : .appForegroundInactive
    let routingDecision = CatbirdMLSCore.MLSNotificationCoordinator.routingDecision(
      context: executionContext,
      recipientUserDID: recipientDid
    )

    notificationLogger.info(
      "🧭 [FG] routing_action=\(routingDecision.action.rawValue), policy_reason=\(routingDecision.reason.rawValue), decryption_owner=\(routingDecision.owner?.rawValue ?? "none"), context=\(executionContext.rawValue)"
    )

    switch routingDecision.action {
    case .skip:
      notificationLogger.info("⏭️ [FG] Routing policy skipped decryption")
      completionHandler([.banner, .sound])
      return

    case .cacheOnly:
      notificationLogger.info("✅ [FG] Cache-only route selected for active foreground user")
      let backoffDelaysMs: [UInt64] = [50, 100, 200, 400, 800, 1500, 2000]

      for (attempt, delayMs) in backoffDelaysMs.enumerated() {
        if let cachedPlaintext = await getCachedPlaintextByOrder() {
          CatbirdMLSCore.MLSNotificationMetrics.increment(
            .cacheHitBeforeDecrypt,
            owner: .appSync,
            context: .appForegroundActive,
            source: "foreground_active_order_cache"
          )
          notificationLogger.info(
            "📦 [FG] Cache HIT by (epoch,seq) (attempt \(attempt + 1)) - using cached content")
          await presentDecryptedNotification(
            plaintext: cachedPlaintext,
            convoId: convoId,
            messageId: messageId,
            recipientDid: recipientDid,
            originalNotification: originalNotification,
            completionHandler: completionHandler
          )
          return
        }

        if let cachedPlaintext = await CatbirdMLSCore.MLSCoreContext.shared.getCachedPlaintext(
          messageID: messageId, userDid: recipientDid
        ) {
          CatbirdMLSCore.MLSNotificationMetrics.increment(
            .cacheHitBeforeDecrypt,
            owner: .appSync,
            context: .appForegroundActive,
            source: "foreground_active_message_cache"
          )
          notificationLogger.info(
            "📦 [FG] Cache HIT (attempt \(attempt + 1)) - using cached content")
          await presentDecryptedNotification(
            plaintext: cachedPlaintext,
            convoId: convoId,
            messageId: messageId,
            recipientDid: recipientDid,
            originalNotification: originalNotification,
            completionHandler: completionHandler
          )
          return
        }

        if attempt < backoffDelaysMs.count - 1 {
          do { try await Task.sleep(nanoseconds: delayMs * 1_000_000) } catch {}
        }
      }

      await logCacheMissDetails(context: "active-cache-only-miss")
      notificationLogger.warning(
        "⚠️ [FG] Cache-only route timed out without decrypted payload - showing placeholder")
      completionHandler([.banner, .sound])
      return

    case .decrypt:
      notificationLogger.info(
        "🔄 [FG] Policy selected direct decrypt route for foreground notification")
    }

    do {
      // Check if already cached first
      if let cachedPlaintext = await getCachedPlaintextByOrder() {
        CatbirdMLSCore.MLSNotificationMetrics.increment(
          .cacheHitBeforeDecrypt,
          owner: .appNotification,
          context: .appForegroundInactive,
          source: "foreground_inactive_order_cache"
        )
        notificationLogger.info("📦 [FG] Cache HIT by (epoch,seq) - using cached content")
        await presentDecryptedNotification(
          plaintext: cachedPlaintext,
          convoId: convoId,
          messageId: messageId,
          recipientDid: recipientDid,
          originalNotification: originalNotification,
          completionHandler: completionHandler
        )
        return
      }

      if let cachedPlaintext = await CatbirdMLSCore.MLSCoreContext.shared.getCachedPlaintext(
        messageID: messageId, userDid: recipientDid
      ) {
        CatbirdMLSCore.MLSNotificationMetrics.increment(
          .cacheHitBeforeDecrypt,
          owner: .appNotification,
          context: .appForegroundInactive,
          source: "foreground_inactive_message_cache"
        )
        notificationLogger.info("📦 [FG] Cache HIT - using cached content")
        await presentDecryptedNotification(
          plaintext: cachedPlaintext,
          convoId: convoId,
          messageId: messageId,
          recipientDid: recipientDid,
          originalNotification: originalNotification,
          completionHandler: completionHandler
        )
        return
      }

      // Decode ciphertext from base64
      guard let ciphertextData = Data(base64Encoded: ciphertext) else {
        notificationLogger.error("❌ [FG] Invalid base64 ciphertext")
        completionHandler([.banner, .sound])
        return
      }

      // Convert convoId to groupId
      let groupIdData: Data
      if let hexData = Data(hexEncoded: convoId) {
        groupIdData = hexData
      } else {
        groupIdData = Data(convoId.utf8)
      }

      // Sync group state AND capture plaintext if target message is decrypted
      notificationLogger.info(
        "🔄 [FG] Syncing group state for recipient (may capture target message)...")
      // Padding is stripped by catbird-mls process_message internally.
      let targetCiphertext = ciphertextData
      let syncResult = await syncGroupStateForRecipient(
        convoId: convoId,
        recipientDid: recipientDid,
        targetMessageId: messageId,
        targetEpoch: epoch,
        targetSeq: seq,
        targetCiphertext: targetCiphertext
      )

      // If sync already decrypted our target message, use that plaintext
      if let captured = syncResult {
        notificationLogger.info(
          "✅ [FG] Target message decrypted during sync - using captured plaintext")
        // Use the SERVER message ID so sender lookup works (local pre-send UUID can differ).
        await presentDecryptedNotification(
          plaintext: captured.plaintext,
          convoId: convoId,
          messageId: captured.serverMessageId,
          recipientDid: recipientDid,
          originalNotification: originalNotification,
          completionHandler: completionHandler
        )
        return
      }

      // Check cache again after sync (message may have been stored)
      if let cachedPlaintext = await getCachedPlaintextByOrder() {
        notificationLogger.info("📦 [FG] Cache HIT by (epoch,seq) after sync - using cached content")
        await presentDecryptedNotification(
          plaintext: cachedPlaintext,
          convoId: convoId,
          messageId: messageId,
          recipientDid: recipientDid,
          originalNotification: originalNotification,
          completionHandler: completionHandler
        )
        return
      }

      if let cachedPlaintext = await CatbirdMLSCore.MLSCoreContext.shared.getCachedPlaintext(
        messageID: messageId, userDid: recipientDid
      ) {
        notificationLogger.info("📦 [FG] Cache HIT after sync - using cached content")
        await presentDecryptedNotification(
          plaintext: cachedPlaintext,
          convoId: convoId,
          messageId: messageId,
          recipientDid: recipientDid,
          originalNotification: originalNotification,
          completionHandler: completionHandler
        )
        return
      }

      // If we get here, the target message wasn't in the sync batch
      // This can happen if it's a brand new message not yet on server
      notificationLogger.info("🔓 [FG] Target message not in sync - attempting direct decryption...")
      await logCacheMissDetails(context: "non-active-cache-miss")

      // Use ephemeral path for non-active users
      // This prevents "database locked" errors by NOT checkpointing the active user's DB
      CatbirdMLSCore.MLSNotificationMetrics.increment(
        .decryptAttempt,
        owner: .appNotification,
        context: .appForegroundInactive,
        source: "foreground_inactive_direct_decrypt"
      )
      let decryptResult = try await CatbirdMLSCore.MLSCoreContext.shared.decryptForNotification(
        userDid: recipientDid,
        groupId: groupIdData,
        ciphertext: ciphertextData,
        conversationID: convoId,
        messageID: messageId,
        // Keep lightweight DB access for non-active users, but allow version signaling.
        useEphemeralAccess: false
      )

      notificationLogger.info("✅ [FG] Decryption SUCCESS - showing decrypted notification")
      signalInactiveAccountStateMutation(
        for: recipientDid,
        source: "foreground_direct_decrypt",
        incrementVersion: false
      )

      await presentDecryptedNotification(
        plaintext: decryptResult.plaintext,
        convoId: convoId,
        messageId: messageId,
        recipientDid: recipientDid,
        originalNotification: originalNotification,
        completionHandler: completionHandler
      )

    } catch let error as CatbirdMLSCore.MLSError {
      if case .secretReuseSkipped = error {
        CatbirdMLSCore.MLSNotificationMetrics.increment(
          .secretReuseRecovery,
          owner: .appNotification,
          context: .appForegroundInactive,
          source: "foreground_inactive_secret_reuse"
        )
        notificationLogger.info(
          "🔄 [FG] SecretReuseError - message already processed, checking cache")

        let backoffDelaysMs: [UInt64] = [50, 100, 200]
        for (attempt, delayMs) in backoffDelaysMs.enumerated() {
          var cachedPlaintext = await getCachedPlaintextByOrder()
          if cachedPlaintext == nil {
            cachedPlaintext = await CatbirdMLSCore.MLSCoreContext.shared.getCachedPlaintext(
              messageID: messageId, userDid: recipientDid
            )
          }

          if let cachedPlaintext {
            CatbirdMLSCore.MLSNotificationMetrics.increment(
              .cacheHitBeforeDecrypt,
              owner: .appNotification,
              context: .appForegroundInactive,
              source: "foreground_inactive_secret_reuse_cache"
            )
            notificationLogger.info(
              "📦 [FG] Cache HIT after SecretReuse (attempt \(attempt + 1)) - using cached content")
            await presentDecryptedNotification(
              plaintext: cachedPlaintext,
              convoId: convoId,
              messageId: messageId,
              recipientDid: recipientDid,
              originalNotification: originalNotification,
              completionHandler: completionHandler
            )
            return
          }

          if attempt < backoffDelaysMs.count - 1 {
            do { try await Task.sleep(nanoseconds: delayMs * 1_000_000) } catch {}
          }
        }
        await logCacheMissDetails(context: "non-active-secret-reuse-miss")
      }

      notificationLogger.error("❌ [FG] Decryption FAILED: \(error.localizedDescription)")
      // Show notification with placeholder text as fallback
      completionHandler([.banner, .sound])
    } catch {
      notificationLogger.error("❌ [FG] Decryption FAILED: \(error.localizedDescription)")
      // Show notification with placeholder text as fallback
      completionHandler([.banner, .sound])
    }
  }

  /// Check if the given DID matches the currently active user
  /// - Parameter recipientDid: The DID to check
  /// - Returns: true if this DID is the currently active user
  private func checkIfActiveUser(_ recipientDid: String) async -> Bool {
    let normalizedRecipientDid = recipientDid.lowercased()

    // Best-effort: verify the *currently authenticated* account matches the recipient.
    // This prevents false positives during account-switch races (appState/db can be stale).
    var authenticatedDid: String?
    if let client {
      authenticatedDid = try? await client.getDid()
    }

    if let authenticatedDid, authenticatedDid.lowercased() != normalizedRecipientDid {
      notificationLogger.warning(
        "⚠️ [FG] Active-user mismatch: authenticated=\(authenticatedDid), recipient=\(recipientDid)"
      )
      return false
    }

    // First check against our local appState reference
    if let currentAppState = appState {
      let currentUserDID = await MainActor.run { currentAppState.userDID }
      if currentUserDID.lowercased() == normalizedRecipientDid {
        return true
      }
    }

    // Also check against the database manager's tracking
    return await CatbirdMLSCore.MLSGRDBManager.shared.isActiveUser(recipientDid)
  }

  /// Sync the group state for a recipient before attempting decryption
  /// This ensures the recipient's MLS context has all pending commits processed
  ///
  /// CRITICAL FIX: This method now captures the plaintext if the target message is decrypted
  /// during sync, preventing "SecretReuseError" from double-decryption.
  ///
  /// CRITICAL FIX: This method now handles GroupNotFound by fetching and processing
  /// the Welcome message to join the group before retrying message processing.
  ///
  /// - Parameters:
  ///   - convoId: The conversation ID
  ///   - recipientDid: The recipient's DID
  ///   - targetMessageId: The message ID we want to decrypt (if found during sync, its plaintext is returned)
  /// - Returns: The decrypted plaintext if the target message was found and decrypted during sync, nil otherwise
  private func syncGroupStateForRecipient(
    convoId: String,
    recipientDid: String,
    targetMessageId: String,
    targetEpoch: Int?,
    targetSeq: Int?,
    targetCiphertext: Data
  ) async -> (plaintext: String, serverMessageId: String)? {
    notificationLogger.info("🔄 [FG] Fetching pending messages for recipient's group sync...")
    notificationLogger.info("🔄 [FG] Target message ID: \(targetMessageId.prefix(16))...")

    do {
      // Get or create API client for the recipient
      let apiClient = await getOrCreateAPIClient(for: recipientDid)
      guard let apiClient = apiClient else {
        notificationLogger.warning(
          "⚠️ [FG] Failed to create API client for recipient - skipping group sync")
        return nil
      }

      // Get MLS context for the recipient
      let context = try await CatbirdMLSCore.MLSCoreContext.shared.getContext(for: recipientDid)

      guard let groupIdData = Data(hexEncoded: convoId) else {
        notificationLogger.error("❌ [FG] Invalid convoId format for group sync")
        return nil
      }

      // Check if the group exists locally
      var groupExists = await checkGroupExists(context: context, groupId: groupIdData)

      // If group doesn't exist, try to fetch and process the Welcome message
      if !groupExists {
        notificationLogger.info(
          "🆕 [FG] Group not found locally - attempting to fetch Welcome message...")
        groupExists = await attemptWelcomeJoin(
          apiClient: apiClient,
          context: context,
          convoId: convoId,
          recipientDid: recipientDid
        )

        if !groupExists {
          notificationLogger.warning(
            "⚠️ [FG] Could not join group - Welcome may not be available yet")
          return nil
        }
      }

      // Fetch recent messages to process any commits we missed
      let result = try await apiClient.getMessages(convoId: convoId, sinceSeq: nil)
      notificationLogger.info("🔄 [FG] Fetched \(result.messages.count) messages for group sync")

      var processedCount = 0
      var capturedPlaintext: String? = nil
      var capturedServerMessageId: String? = nil

      // No advisory lock needed - SQLite WAL handles concurrent access
      // Cross-process coordination uses MLSNotificationCoordinator.

      for message in result.messages {
        // ciphertext is already Bytes (Data)
        let ciphertextData = message.ciphertext.data

        // Padding is stripped by catbird-mls process_message internally.
        let actualCiphertext = ciphertextData

        do {
          let processResult = try context.processMessage(
            groupId: groupIdData, messageData: actualCiphertext)
          processedCount += 1

          // ═══════════════════════════════════════════════════════════════════════════
          // CRITICAL FIX (2024-12-22): Cache ALL application messages, not just target
          // ═══════════════════════════════════════════════════════════════════════════
          // MLS decryption consumes the secret key (forward secrecy). If we only cache
          // the target message, other messages like reactions will fail with
          // SecretReuseError when the notification handler tries to access them later.
          // We must cache every successfully decrypted message to prevent this.
          // ═══════════════════════════════════════════════════════════════════════════
          if case .applicationMessage(let plaintextData, let senderCredential) = processResult {
            let senderDid = String(data: senderCredential.identity, encoding: .utf8) ?? "unknown"

            if let textContent = String(data: plaintextData, encoding: .utf8) {
              // Check if this is our target message - capture for return value
              // NOTE: push/message IDs can differ between local sender-generated IDs and server IDs,
              // so we also match by ciphertext to avoid double-decrypt (SecretReuseError).
              let isTargetByOrder =
                (targetEpoch != nil && targetSeq != nil)
                ? (message.epoch == targetEpoch && message.seq == targetSeq)
                : false
              let isTargetByCiphertext = (actualCiphertext == targetCiphertext)
              let isTarget =
                isTargetByOrder || isTargetByCiphertext || message.id == targetMessageId
              if isTarget {
                if let payload = try? CatbirdMLSCore.MLSMessagePayload.decodeFromJSON(plaintextData)
                {
                  let displayText: String
                  switch payload.messageType {
                  case .text:
                    displayText = payload.text ?? textContent
                  case .reaction:
                    if let reaction = payload.reaction {
                      let verb = (reaction.action == .add) ? "Reacted with" : "Removed reaction"
                      displayText = "\(verb) \(reaction.emoji)"
                    } else {
                      displayText = "Reaction update"
                    }
                  case .readReceipt:
                    displayText = "Read receipt"
                  case .typing:
                    displayText = "Typing..."
                  case .adminRoster, .adminAction:
                    displayText = "Group update"
                  case .system:
                    displayText = payload.text ?? ""
                  }

                  capturedPlaintext = displayText
                  capturedServerMessageId = message.id
                  notificationLogger.info(
                    "🎯 [FG] CAPTURED target message during sync! (type: \(payload.messageType.rawValue))"
                  )
                } else {
                  capturedPlaintext = textContent
                  capturedServerMessageId = message.id
                  notificationLogger.info("🎯 [FG] CAPTURED target message (raw text) during sync!")
                }
              }

              // Cache ALL decrypted messages to prevent SecretReuseError
              let serverEpoch = Int64(message.epoch)
              let serverSeq = Int64(message.seq)

              do {
                // Parse payload or create text payload
                let payload =
                  (try? CatbirdMLSCore.MLSMessagePayload.decodeFromJSON(plaintextData))
                  ?? CatbirdMLSCore.MLSMessagePayload.text(textContent, embed: nil)

                // No advisory lock needed - SQLite WAL handles concurrent access
                // Cross-process coordination uses MLSNotificationCoordinator.

                try await CatbirdMLSCore.MLSGRDBManager.shared.write(for: recipientDid) { db in
                  try CatbirdMLSCore.MLSStorageHelpers.savePayloadSync(
                    in: db,
                    messageID: message.id,
                    conversationID: convoId,
                    currentUserDID: recipientDid,
                    payload: payload,
                    senderID: senderDid,
                    epoch: serverEpoch,
                    sequenceNumber: serverSeq
                  )

                  // Persist reactions during sync-group-state caching.
                  // Otherwise, the first decrypt (notification path) burns MLS secrets and the app
                  // can't decrypt later to reconstruct the reaction.
                  if payload.messageType == .reaction,
                    let reaction = payload.reaction,
                    senderDid != "unknown"
                  {
                    switch reaction.action {
                    case .add:
                      let reactionID =
                        "reaction:\(convoId):\(reaction.messageId):\(senderDid):\(reaction.emoji)"
                      let model = CatbirdMLSCore.MLSReactionModel(
                        reactionID: reactionID,
                        messageID: reaction.messageId,
                        conversationID: convoId,
                        currentUserDID: recipientDid,
                        actorDID: senderDid,
                          emoji: reaction.emoji,
                          action: "add",
                          timestamp: Date()
                        )
                        try CatbirdMLSCore.MLSStorageHelpers.saveReactionSync(
                          in: db, reaction: model)
                      case .remove:
                        try CatbirdMLSCore.MLSStorageHelpers.deleteReactionSync(
                          in: db,
                          messageID: reaction.messageId,
                          actorDID: senderDid,
                          emoji: reaction.emoji,
                          currentUserDID: recipientDid
                        )
                      }
                    }
                  }
                notificationLogger.info(
                  "💾 [FG] Cached message \(message.id.prefix(8)) (epoch: \(serverEpoch), seq: \(serverSeq))"
                )
              } catch {
                notificationLogger.warning(
                  "⚠️ [FG] Failed to cache message \(message.id.prefix(8)): \(error.localizedDescription)"
                )
              }
            }
          } else if case .stagedCommit = processResult {
            notificationLogger.debug("🔄 [FG] Processed commit message \(message.id.prefix(8))")
          }

          notificationLogger.debug(
            "🔄 [FG] Processed message \(message.id.prefix(8)) (type: \(message.messageType ?? "unknown"))"
          )
        } catch {
          let errorDescription = error.localizedDescription
          if errorDescription.contains("SecretReuseError")
            || errorDescription.contains("Decryption failed")
          {
            notificationLogger.warning(
              "⚠️ [FG] Message \(message.id.prefix(8)) triggered SecretReuseError/DecryptionFailed - attempting recovery from cache"
            )

            // CRITICAL RECOVERY: If message is already cached (SecretReuseError), validate calls to saveReaction missed by the throw
            do {
              // No advisory lock needed - SQLite WAL handles concurrent access
              // Cross-process coordination uses MLSNotificationCoordinator.

              try await CatbirdMLSCore.MLSGRDBManager.shared.write(for: recipientDid) {
                [self] db in
                // Fetch cached message to get senderID
                if let cached = try CatbirdMLSCore.MLSMessageModel.fetchOne(db, id: message.id) {
                  let senderDid = cached.senderID

                  // Validate senderID not empty/unknown (Fix for reaction overwrite)
                  if !senderDid.isEmpty && senderDid != "unknown", let json = cached.payloadJSON,
                    let payload = try? CatbirdMLSCore.MLSMessagePayload.decodeFromJSON(json),
                    payload.messageType == .reaction,
                    let reaction = payload.reaction
                  {

                    notificationLogger.info(
                      "🔄 [FG] Recovering reaction for \(message.id.prefix(8)) from sender \(senderDid)"
                    )

                    switch reaction.action {
                    case .add:
                      let reactionID =
                        "reaction:\(convoId):\(reaction.messageId):\(senderDid):\(reaction.emoji)"
                      let model = CatbirdMLSCore.MLSReactionModel(
                        reactionID: reactionID,
                        messageID: reaction.messageId,
                        conversationID: convoId,
                        currentUserDID: recipientDid,
                        actorDID: senderDid,
                        emoji: reaction.emoji,
                        action: "add",
                        timestamp: Date()
                      )
                      try CatbirdMLSCore.MLSStorageHelpers.saveReactionSync(
                        in: db, reaction: model)
                      notificationLogger.info(
                        "✅ [FG] Recovered reaction add for \(message.id.prefix(8))")

                    case .remove:
                      try CatbirdMLSCore.MLSStorageHelpers.deleteReactionSync(
                        in: db,
                        messageID: reaction.messageId,
                        actorDID: senderDid,
                        emoji: reaction.emoji,
                        currentUserDID: recipientDid
                      )
                      notificationLogger.info(
                        "✅ [FG] Recovered reaction remove for \(message.id.prefix(8))")
                    }
                  }
                }
              }
            } catch {
              notificationLogger.error(
                "❌ [FG] Recovery failed for \(message.id.prefix(8)): \(error.localizedDescription)")
            }
          }

          // Ignore errors - might be already processed, or the target message we want to decrypt
          notificationLogger.debug(
            "🔄 [FG] Skipping message \(message.id.prefix(8)): \(error.localizedDescription)")
        }
      }

      notificationLogger.info(
        "✅ [FG] Group sync complete - processed \(processedCount)/\(result.messages.count) messages"
      )
      if processedCount > 0 {
        signalInactiveAccountStateMutation(
          for: recipientDid,
          source: "foreground_sync",
          incrementVersion: true
        )
      }

      if let capturedPlaintext, let capturedServerMessageId {
        notificationLogger.info("✅ [FG] Target message was captured during sync!")
        return (capturedPlaintext, capturedServerMessageId)
      } else {
        notificationLogger.info("ℹ️ [FG] Target message was NOT in the sync batch")
        return nil
      }

    } catch {
      notificationLogger.warning("⚠️ [FG] Group sync failed: \(error.localizedDescription)")
      // Continue anyway - decryption might still work
      return nil
    }
  }

  /// Signal cross-process MLS mutations for non-active account foreground decoding.
  ///
  /// This keeps lightweight decoding for inactive users while coordinating state
  /// changes with monotonic versioning and Darwin notifications.
  private func signalInactiveAccountStateMutation(
    for userDid: String,
    source: String,
    incrementVersion: Bool
  ) {
    let newVersion = CatbirdMLSCore.MLSNotificationCoordinator.publishMutation(
      userDID: userDid,
      source: source,
      decryptionOwner: .appNotification,
      incrementVersion: incrementVersion
    )
    if let versionAfter = newVersion {
      notificationLogger.info(
        "📡 [FG] Signaled inactive-account MLS mutation (source=\(source), decryption_owner=app_notification, version_after=\(versionAfter))"
      )
    } else {
      notificationLogger.info(
        "📡 [FG] Signaled inactive-account MLS mutation (source=\(source), decryption_owner=app_notification, version_after=unchanged)"
      )
    }
  }

  // MARK: - Group Join Helpers

  /// Get or create an MLS API client for a specific user
  private func getOrCreateAPIClient(for userDid: String) async -> MLSAPIClient? {
    if let recipientAppState = await getAppStateForUser(userDid),
      let existingClient = await recipientAppState.getMLSAPIClient()
    {
      // IMPORTANT: The stored client can be authenticated as a *different* account
      // if the active account has changed since it was created.
      let authenticated = await existingClient.authenticatedUserDID()
      if let authenticated, authenticated.lowercased() == userDid.lowercased() {
        notificationLogger.info("🔄 [FG] Using existing API client for recipient")
        return existingClient
      } else {
        notificationLogger.warning(
          "⚠️ [FG] Existing API client auth mismatch (authenticated=\(authenticated ?? "nil"), expected=\(userDid)) - creating standalone client"
        )
      }
    }

    // Create a standalone ATProtoClient for the recipient
    notificationLogger.info("🔄 [FG] Creating standalone API client for recipient...")

    guard let standaloneClient = await createStandaloneClientForUser(userDid) else {
      return nil
    }

    let apiClient = await MLSAPIClient(client: standaloneClient, environment: .production)
    notificationLogger.info("🔄 [FG] Created standalone MLS API client for recipient")
    return apiClient
  }

  /// Check if a group exists in the MLS context
  private func checkGroupExists(context: CatbirdMLS.MlsContext, groupId: Data) async -> Bool {
    do {
      // Try to get the epoch - if it fails, the group doesn't exist
      _ = try context.getEpoch(groupId: groupId)
      return true
    } catch {
      return false
    }
  }

  /// Attempt to join a group by fetching and processing the Welcome message
  /// - Returns: true if the group was successfully joined, false otherwise
  private func attemptWelcomeJoin(
    apiClient: MLSAPIClient,
    context: CatbirdMLS.MlsContext,
    convoId: String,
    recipientDid: String
  ) async -> Bool {
    do {
      notificationLogger.info("📩 [FG] Fetching Welcome message for group: \(convoId.prefix(16))...")

      // 🛡️ RACE CONDITION FIX: Coordinate with other processes (NSE)
      // Wait if another process is currently processing the Welcome for this conversation
      try await MLSWelcomeGate.shared.waitForWelcomeIfPending(
        for: convoId, userDID: recipientDid, timeout: .seconds(5))

      // Check if group appeared while we were waiting (processed by NSE)
      if try context.groupExists(groupId: Data(hexEncoded: convoId) ?? Data()) {
        notificationLogger.info(
          "✅ [FG] Group appeared after waiting for WelcomeGate - skipping processing")
        return true
      }

      // Mark start of processing
      try await MLSWelcomeGate.shared.beginWelcomeProcessing(for: convoId, userDID: recipientDid)
      defer {
        Task {
          await MLSWelcomeGate.shared.completeWelcomeProcessing(for: convoId, userDID: recipientDid)
        }
      }

      // Fetch Welcome message from server
      let welcomeData = try await apiClient.getWelcome(convoId: convoId)
      notificationLogger.info("📩 [FG] Received Welcome message: \(welcomeData.count) bytes")

      // Get identity bytes for the user
      let identityBytes = Data(recipientDid.utf8)

      // Process the Welcome message to join the group
      notificationLogger.info("🔐 [FG] Processing Welcome message...")
      let welcomeResult = try context.processWelcome(
        welcomeBytes: welcomeData,
        identityBytes: identityBytes,
        config: nil
      )

      notificationLogger.info(
        "✅ [FG] Successfully joined group via Welcome! GroupID: \(welcomeResult.groupId.hexEncodedString().prefix(16))..."
      )

      // 🚨 ROOT CAUSE FIX: Create SQLCipher conversation record IMMEDIATELY after Welcome
      // This prevents "FOREIGN KEY constraint failed" errors when messages are decrypted.
      // Without this, the message INSERT fails, plaintext is lost, and Forward Secrecy
      // means we can never decrypt the message again (keys are burned after first use).
      do {
        let groupIdHex = welcomeResult.groupId.hexEncodedString()
        // Use smart routing - auto-routes to lightweight DatabaseQueue for inactive users
        try await CatbirdMLSCore.MLSGRDBManager.shared.write(for: recipientDid) { db in
          // CRITICAL: Use ensureConversationExistsSync (Healing)
          // This ensures if a placeholder exists (from NSE), it gets migrated to this real ID
          try CatbirdMLSCore.MLSStorageHelpers.ensureConversationExistsSync(
            in: db,
            userDID: recipientDid,
            conversationID: convoId,
            groupID: groupIdHex
          )
        }
        notificationLogger.info("✅ [FG] Created conversation record for new group (FK fix)")
      } catch {
        // Non-fatal - the safety net in savePlaintext will create a placeholder if needed
        notificationLogger.warning(
          "⚠️ [FG] Failed to pre-create conversation record: \(error.localizedDescription)")
      }

      // Confirm Welcome processing with server (best effort)
      do {
        try await apiClient.confirmWelcome(convoId: convoId, success: true, errorMessage: nil)
        notificationLogger.info("✅ [FG] Confirmed Welcome processing with server")
      } catch {
        notificationLogger.warning(
          "⚠️ [FG] Failed to confirm Welcome (non-critical): \(error.localizedDescription)")
      }

      return true

    } catch let error as MLSAPIError {
      // Check if Welcome is not available (404) or expired (410)
      if case .httpError(let statusCode, _) = error {
        if statusCode == 404 {
          notificationLogger.info("ℹ️ [FG] No Welcome message available for this group (404)")
          return false
        }

        if statusCode == 410 {
          notificationLogger.info(
            "ℹ️ [FG] Welcome expired for this group (410) - attempting External Commit fallback")
          do {
            if let groupIdData = Data(hexEncoded: convoId), try context.groupExists(groupId: groupIdData)
            {
              notificationLogger.info(
                "⏭️ [FG] Group already exists locally after 410 - skipping External Commit")
              return true
            }
            let groupIdData = try await MLSClient.shared.joinByExternalCommit(
              for: recipientDid, convoId: convoId)
            let groupIdHex = groupIdData.hexEncodedString()
            try await CatbirdMLSCore.MLSGRDBManager.shared.write(for: recipientDid) { db in
              try CatbirdMLSCore.MLSStorageHelpers.ensureConversationExistsSync(
                in: db,
                userDID: recipientDid,
                conversationID: convoId,
                groupID: groupIdHex
              )
            }
            notificationLogger.info("✅ [FG] External Commit fallback succeeded")
            return true
          } catch {
            notificationLogger.warning(
              "⚠️ [FG] External Commit fallback failed: \(error.localizedDescription)")
            return false
          }
        }
      }

      notificationLogger.warning("⚠️ [FG] Failed to fetch Welcome: \(error.localizedDescription)")
      return false
    } catch let error as CatbirdMLS.MlsError {
      // Handle specific MLS errors
      switch error {
      case .NoMatchingKeyPackage(let msg):
        notificationLogger.warning(
          "⚠️ [FG] NoMatchingKeyPackage - Welcome references unavailable key package: \(msg)")

        // Best-effort: invalidate this stale Welcome and clean up server-side orphaned packages.
        do {
          _ = try await apiClient.invalidateWelcome(
            convoId: convoId, reason: "NoMatchingKeyPackage")
        } catch {
          notificationLogger.warning(
            "⚠️ [FG] Failed to invalidate Welcome (non-critical): \(error.localizedDescription)")
        }

          Task.detached(priority: .utility) { [self] in
          do {
            _ = try await MLSClient.shared.syncKeyPackageHashes(for: recipientDid)
          } catch {
            notificationLogger.warning(
              "⚠️ [FG] Failed to sync key package hashes: \(error.localizedDescription)")
          }

          do {
            _ = try await MLSClient.shared.monitorAndReplenishBundles(for: recipientDid)
          } catch {
            notificationLogger.warning(
              "⚠️ [FG] Failed to replenish key packages: \(error.localizedDescription)")
          }
        }

        // If we can't process Welcome, try joining via External Commit so we can decrypt immediately.
        do {
          if let groupIdData = Data(hexEncoded: convoId), try context.groupExists(groupId: groupIdData)
          {
            notificationLogger.info(
              "⏭️ [FG] Group already exists after NoMatchingKeyPackage - skipping External Commit")
            return true
          }
          let groupIdData = try await MLSClient.shared.joinByExternalCommit(
            for: recipientDid, convoId: convoId)
          let groupIdHex = groupIdData.hexEncodedString()
          try await CatbirdMLSCore.MLSGRDBManager.shared.write(for: recipientDid) { db in
            try CatbirdMLSCore.MLSStorageHelpers.ensureConversationExistsSync(
              in: db,
              userDID: recipientDid,
              conversationID: convoId,
              groupID: groupIdHex
            )
          }
          notificationLogger.info(
            "✅ [FG] External Commit fallback succeeded after NoMatchingKeyPackage")
          return true
        } catch {
          notificationLogger.warning(
            "⚠️ [FG] External Commit fallback failed after NoMatchingKeyPackage: \(error.localizedDescription)"
          )
          return false
        }

      default:
        notificationLogger.warning(
          "⚠️ [FG] Failed to process Welcome: \(error.localizedDescription)")
        return false
      }
    } catch {
      notificationLogger.warning("⚠️ [FG] Failed to join group: \(error.localizedDescription)")
      return false
    }
  }

  /// Create a standalone ATProtoClient for a specific user
  /// The client will read auth tokens from the shared keychain
  private func createStandaloneClientForUser(_ userDid: String) async -> ATProtoClient? {
    notificationLogger.info(
      "🔐 [FG] Creating standalone ATProtoClient for: \(userDid.prefix(24))...")

    #if targetEnvironment(simulator)
      let accessGroup: String? = nil
    #else
      let accessGroup: String? = MLSKeychainManager.resolvedAccessGroup(
        suffix: "blue.catbird.shared")
    #endif

    let oauthConfig = OAuthConfiguration(
      clientId: "https://catbird.blue/oauth-client-metadata.json",
      redirectUri: "https://catbird.blue/oauth/callback",
      scope: "atproto transition:generic transition:chat.bsky"
    )

    let client: ATProtoClient
    do {
        #if DEBUG
        client = try await ATProtoClient(
          oauthConfig: oauthConfig,
          namespace: "blue.catbird",
          authMode: .gateway,
          gatewayURL: URL(string: "https://api.catbird.blue")!,
//          gatewayURL: URL(string: "https://dev-api.catbird.blue")!,
          userAgent: "Catbird/1.0",
          bskyAppViewDID: "did:web:api.bsky.app#bsky_appview",
          bskyChatDID: "did:web:api.bsky.chat#bsky_chat",
          accessGroup: accessGroup
        )
        #else
      client = try await ATProtoClient(
        oauthConfig: oauthConfig,
        namespace: "blue.catbird",
        authMode: .gateway,
        gatewayURL: URL(string: "https://api.catbird.blue")!,
        userAgent: "Catbird/1.0",
        bskyAppViewDID: "did:web:api.bsky.app#bsky_appview",
        bskyChatDID: "did:web:api.bsky.chat#bsky_chat",
        accessGroup: accessGroup
      )
        #endif
    } catch {
      notificationLogger.error(
        "❌ [FG] Failed to create ATProtoClient: \(error.localizedDescription)")
      return nil
    }

    // Switch to the specific user's account to load their tokens
    do {
      try await client.switchToAccount(did: userDid)
      notificationLogger.info("✅ [FG] Standalone client switched to user: \(userDid.prefix(24))...")
      return client
    } catch {
      notificationLogger.error(
        "❌ [FG] Failed to switch standalone client to user: \(error.localizedDescription)")
      return nil
    }
  }

  /// Get AppState for a specific user DID (for multi-account support)
  private func getAppStateForUser(_ userDid: String) async -> AppState? {
    // First check if current appState matches
    if let currentAppState = appState,
      await MainActor.run(body: { currentAppState.userDID }) == userDid
    {
      return currentAppState
    }

    // Check AppStateManager for other accounts
    return await MainActor.run {
      AppStateManager.shared.getState(for: userDid)
    }
  }

  /// Present a notification with decrypted MLS message content
  ///
  /// NOTE: When the app is in foreground, iOS bypasses the Notification Service Extension,
  /// so we must replicate its “rich notification” logic here (sender + group title + avatar).
  private func presentDecryptedNotification(
    plaintext: String,
    convoId: String,
    messageId: String,
    recipientDid: String,
    originalNotification: UNNotification,
    completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) async {
    // For foreground notifications, we can't modify the content directly.
    // Instead, we schedule a new local notification with the decrypted content
    // and suppress the original push notification.
    let content = UNMutableNotificationContent()
    content.sound = .default
    content.categoryIdentifier = "MLS_MESSAGE"
    content.threadIdentifier = "mls-\(convoId)"

    // ═══════════════════════════════════════════════════════════════════════════
    // Parse MLS message payload to determine notification content
    // Encrypted reactions need special handling
    // ═══════════════════════════════════════════════════════════════════════════

    // Try to parse as MLSMessagePayload JSON first
    if let payloadData = plaintext.data(using: .utf8),
      let payload = try? CatbirdMLSCore.MLSMessagePayload.decodeFromJSON(payloadData)
    {

      switch payload.messageType {
      case .text:
        // Text message - use the text content
        if let text = payload.text, !text.isEmpty {
          content.body = text
        } else {
          content.body = "New Message"
        }
        notificationLogger.info("📝 [FG] Text message notification")

      case .reaction:
        // Only show notifications for added reactions, suppress removed reactions
        if let reaction = payload.reaction {
          if reaction.action == .add {
            content.body = "Reacted with \(reaction.emoji)"
            notificationLogger.info("😀 [FG] Reaction notification: \(reaction.emoji)")
          } else {
            // Removed reactions should not generate notifications
            notificationLogger.info("🔇 [FG] Removed reaction - suppressing notification")
            completionHandler([])  // Suppress original notification
            return
          }
        } else {
          // Malformed reaction payload - suppress
          notificationLogger.warning("⚠️ [FG] Malformed reaction payload - suppressing")
          completionHandler([])
          return
        }

      case .readReceipt:
        // Read receipts should not generate notifications
        notificationLogger.info("📖 [FG] Read receipt - suppressing notification")
        completionHandler([])  // Suppress original notification
        return

      case .typing:
        // Typing indicators are disabled - suppress notification
        notificationLogger.info(
          "⌨️ [FG] Typing indicator (disabled feature) - suppressing notification")
        completionHandler([])  // Suppress original notification
        return

      case .adminRoster, .adminAction:
        // Admin actions - generic notification
        content.body = "Group settings updated"
        notificationLogger.info("👑 [FG] Admin action notification")

      case .system:
        // System messages (history boundary markers) - suppress notification
        notificationLogger.info("🔧 [FG] System message - suppressing notification")
        completionHandler([])
        return
      }
    } else {
      // Fallback: If not valid JSON payload, treat as plain text
      // This handles legacy messages or edge cases
      content.body = plaintext
      notificationLogger.info("📄 [FG] Plain text notification (legacy or fallback)")
    }

    let conversationTitle = await getMLSConversationTitle(
      convoId: convoId, recipientDid: recipientDid)

    // Prefer sender from stored message (post-decryption), fall back to payload if present.
    var senderDid = await getMLSSenderDID(messageId: messageId, recipientDid: recipientDid)
    if senderDid == nil {
      senderDid = originalNotification.request.content.userInfo["sender_did"] as? String
    }

    let canonicalSenderDid = senderDid.map(canonicalDID)

    var senderName: String? = nil
    var senderAvatarURL: URL? = nil

    if let senderDid = canonicalSenderDid {
      if let profile = getCachedProfile(for: senderDid) {
        senderName = profile.displayName ?? profile.handle
        senderAvatarURL = profile.avatarURL.flatMap(URL.init(string:))
      } else if let memberInfo = await getMLSMemberInfo(
        senderDid: senderDid, convoId: convoId, recipientDid: recipientDid)
      {
        senderName = memberInfo.displayName ?? memberInfo.handle
      }

      if senderName == nil {
        senderName = formatShortDID(senderDid)
      }
    }

    if let sender = senderName {
      if let convTitle = conversationTitle, !convTitle.isEmpty {
        content.title = "\(sender) in \(convTitle)"
      } else {
        content.title = sender
      }
    } else if let convTitle = conversationTitle, !convTitle.isEmpty {
      content.title = convTitle
    } else {
      content.title = "New Message"
    }

    // Copy over metadata but mark as already decrypted to prevent infinite loop
    var modifiedUserInfo = originalNotification.request.content.userInfo
    modifiedUserInfo["_mls_decrypted"] = true
    modifiedUserInfo["type"] = "mls_message_decrypted"
    modifiedUserInfo["convo_id"] = convoId
    modifiedUserInfo["recipient_did"] = recipientDid
    modifiedUserInfo["message_id"] = messageId
    if let senderDid = canonicalSenderDid { modifiedUserInfo["sender_did"] = senderDid }
    content.userInfo = modifiedUserInfo

    if let avatarURL = senderAvatarURL {
      await attachProfilePhoto(to: content, from: avatarURL)
    }

    let request = UNNotificationRequest(
      identifier: UUID().uuidString,
      content: content,
      trigger: nil
    )

    UNUserNotificationCenter.current().add(request) { [weak self] error in
      if let error = error {
        self?.notificationLogger.error(
          "❌ [FG] Failed to schedule decrypted notification: \(error.localizedDescription)")
        completionHandler([.banner, .sound])
      } else {
        self?.notificationLogger.info("✅ [FG] Decrypted notification scheduled")
        completionHandler([])
      }
    }
  }

  // MARK: - Foreground rich notification helpers

  private static let mlsNotificationAppGroupSuite = "group.blue.catbird.shared"
  private static let mlsProfileCacheKeyPrefix = "profile_cache_"

  private struct MLSCachedProfile: Codable {
    let did: String
    let handle: String
    let displayName: String?
    let avatarURL: String?
    let cachedAt: Date?
  }

  private func canonicalDID(_ did: String) -> String {
    let trimmed = did.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true).first.map(
      String.init) ?? trimmed
  }

  private func getCachedProfile(for did: String) -> MLSCachedProfile? {
    guard let defaults = UserDefaults(suiteName: Self.mlsNotificationAppGroupSuite) else {
      return nil
    }
    let cacheKey = "\(Self.mlsProfileCacheKeyPrefix)\(did.lowercased())"
    guard let data = defaults.data(forKey: cacheKey) else { return nil }
    return try? JSONDecoder().decode(MLSCachedProfile.self, from: data)
  }

  private func getMLSConversationTitle(convoId: String, recipientDid: String) async -> String? {
    do {
      // Use smart routing - auto-routes to lightweight DatabaseQueue for inactive users
      let normalizedRecipientDid = recipientDid.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

      let conversation = try await CatbirdMLSCore.MLSGRDBManager.shared.read(for: recipientDid) {
        db in
        try CatbirdMLSCore.MLSConversationModel
          .filter(CatbirdMLSCore.MLSConversationModel.Columns.conversationID == convoId)
          .filter(
            CatbirdMLSCore.MLSConversationModel.Columns.currentUserDID == normalizedRecipientDid
          )
          .fetchOne(db)
      }

      return conversation?.title
    } catch {
      return nil
    }
  }

  private func getMLSSenderDID(messageId: String, recipientDid: String) async -> String? {
    do {
      // Use smart routing - auto-routes to lightweight DatabaseQueue for inactive users
      let normalizedRecipientDid = recipientDid.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

      let message = try await CatbirdMLSCore.MLSGRDBManager.shared.read(for: recipientDid) { db in
        try CatbirdMLSCore.MLSMessageModel
          .filter(CatbirdMLSCore.MLSMessageModel.Columns.messageID == messageId)
          .filter(CatbirdMLSCore.MLSMessageModel.Columns.currentUserDID == normalizedRecipientDid)
          .fetchOne(db)
      }

      guard let senderID = message?.senderID, !senderID.isEmpty, senderID != "unknown" else {
        return nil
      }
      return senderID
    } catch {
      return nil
    }
  }

  private func getMLSMemberInfo(
    senderDid: String,
    convoId: String,
    recipientDid: String
  ) async -> (displayName: String?, handle: String?)? {
    do {
      // Use smart routing - auto-routes to lightweight DatabaseQueue for inactive users
      let normalizedSenderDid = senderDid.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      let normalizedRecipientDid = recipientDid.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

      let member = try await CatbirdMLSCore.MLSGRDBManager.shared.read(for: recipientDid) { db in
        try CatbirdMLSCore.MLSMemberModel
          .filter(CatbirdMLSCore.MLSMemberModel.Columns.did == normalizedSenderDid)
          .filter(CatbirdMLSCore.MLSMemberModel.Columns.conversationID == convoId)
          .filter(CatbirdMLSCore.MLSMemberModel.Columns.currentUserDID == normalizedRecipientDid)
          .fetchOne(db)
      }

      guard let member else { return nil }
      return (displayName: member.displayName, handle: member.handle)
    } catch {
      return nil
    }
  }

  private func attachProfilePhoto(to content: UNMutableNotificationContent, from url: URL) async {
    do {
      let (data, response) = try await URLSession.shared.data(from: url)
      guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
        return
      }

      let mimeType = httpResponse.mimeType ?? "image/jpeg"
      let fileExtension: String
      switch mimeType {
      case "image/png": fileExtension = "png"
      case "image/gif": fileExtension = "gif"
      default: fileExtension = "jpg"
      }

      let tempDir = FileManager.default.temporaryDirectory
      let fileURL = tempDir.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
      try data.write(to: fileURL)

      let attachment = try UNNotificationAttachment(
        identifier: "avatar",
        url: fileURL,
        options: [UNNotificationAttachmentOptionsTypeHintKey: mimeType]
      )

      content.attachments = [attachment]
    } catch {
      // Non-fatal
    }
  }

  private func formatShortDID(_ did: String) -> String {
    let components = did.split(separator: ":")
    guard let lastPart = components.last else { return did }
    let identifier = String(lastPart.prefix(8))
    return identifier.isEmpty ? did : "\(identifier)..."
  }

  /// Handle user interaction with the notification
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    notificationLogger.info("User interacted with notification: \(userInfo)")

    let targetDid = userInfo["did"] as? String
    let uriString = userInfo["uri"] as? String
    let typeString = userInfo["type"] as? String

    // Handle MLS message notifications (from NSE)
    if let type = typeString, type == "mls_message" || type == "mls_message_decrypted" {
      let recipientDid = resolveRecipientDID(from: userInfo)
      let convoId = userInfo["convo_id"] as? String

      Task {
        // Switch to correct account if needed
        if let did = recipientDid {
          await ensureActiveAccount(for: did)
        }

        // Navigate to MLS conversation
        if let convoId = convoId {
          notificationLogger.info(
            "MLS notification tapped - navigating to conversation: \(convoId.prefix(16))...")
          await handleMLSNotificationNavigation(convoId)
        }

        await MainActor.run {
          completionHandler()
        }
      }
      return
    }

    if targetDid != nil || (uriString != nil && typeString != nil) {
      Task {
        if let did = targetDid {
          await ensureActiveAccount(for: did)
        }

        if let uri = uriString, let type = typeString {
          notificationLogger.info("Notification contains URI: \(uri) of type: \(type)")
          await prefetchNotificationContent(uri: uri, type: type)
          await handleNotificationNavigation(uriString: uri, type: type)
        }
      }
    }

    completionHandler()
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
      let descriptor = FetchDescriptor<CachedFeedViewPost>(
        predicate: #Predicate<CachedFeedViewPost> { post in
          post.id == postId
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
      case .appBskyEmbedRecordWithMediaView(let recordWithMediaView):
        if case .appBskyEmbedImagesView(let imagesView) = recordWithMediaView.media {
          for image in imagesView.images {
            if let thumbUrl = URL(string: image.thumb.uriString()) {
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
    _ = await appStateManager.switchAccount(to: did)
    notificationLogger.info("✅ Switched to account \(did) for notification navigation")
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
          hashForAccountMatching(activeDID) == hash
        {
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
  private func handleNotificationNavigation(uriString: String, type: String) async {
    // Handle chat notifications differently
    if type == "chat" {
      await handleChatNotificationNavigation(uriString)
      return
    }

    // Handle MLS chat notifications
    if type == "mls_message" || type == "mls_message_decrypted" {
      await handleMLSNotificationNavigation(uriString)
      return
    }

    // CRITICAL FIX: Get the CURRENT AppState from AppStateManager, not the cached reference
    // After account switch, self.appState may point to the OLD account's AppState
    guard
      let currentAppState = await MainActor.run(body: {
        if case .authenticated(let state) = AppStateManager.shared.lifecycle {
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
        currentAppState.navigationManager.navigate(to: destination, in: 0)
        notificationLogger.info("Successfully navigated to destination from notification")
      }
    } catch {
      notificationLogger.error(
        "Failed to create navigation destination: \(error.localizedDescription)")
    }
  }

  /// Handle navigation from an MLS message notification tap
  private func handleMLSNotificationNavigation(_ convoId: String) async {
    // CRITICAL FIX: Get the CURRENT AppState from AppStateManager, not the cached reference
    // After account switch, self.appState may point to the OLD account's AppState
    guard
      let currentAppState = await MainActor.run(body: {
        if case .authenticated(let state) = AppStateManager.shared.lifecycle {
          return state
        }
        return nil
      })
    else {
      notificationLogger.error("Cannot navigate to MLS conversation - no authenticated AppState")
      return
    }

    // Wait for MLS service to be ready (up to 10 seconds) after potential account switch
    // Increased timeout because account switching involves database setup
    let maxWaitTime: TimeInterval = 10.0
    let checkInterval: TimeInterval = 0.3
    var elapsed: TimeInterval = 0
    var shouldWait = true

    notificationLogger.info("Waiting for MLS service to be ready (max \(maxWaitTime)s)...")

    while shouldWait && elapsed < maxWaitTime {
      let status = await MainActor.run { currentAppState.mlsServiceState.status }
      switch status {
      case .ready:
        notificationLogger.info(
          "MLS service ready after \(String(format: "%.1f", elapsed))s, proceeding with navigation")
        shouldWait = false
      case .failed, .databaseFailed:
        notificationLogger.warning(
          "MLS service in failed state, proceeding with navigation anyway (view will handle error)")
        shouldWait = false
      case .initializing, .notStarted, .retrying:
        // Still initializing, wait a bit
        do { try await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000)) } catch {}
        elapsed += checkInterval
      }
    }

    if elapsed >= maxWaitTime {
      notificationLogger.warning(
        "MLS service did not become ready within \(maxWaitTime)s, proceeding with navigation anyway"
      )
    }

    await MainActor.run {
      // Switch the chat mode to MLS so the correct view is shown
      // Using raw value directly: "Catbird Groups" is ChatTabView.ChatMode.mls.rawValue
      UserDefaults.standard.set("Catbird Groups", forKey: "chatMode")

      // CRITICAL FIX: Set targetMLSConversationId BEFORE switching tabs
      // This ensures the conversation list view can pick up the target even while still loading
      currentAppState.navigationManager.targetMLSConversationId = convoId

      // Switch to chat tab using the tab selection callback (this actually changes the tab)
      if let tabSelection = currentAppState.navigationManager.tabSelection {
        tabSelection(4)  // Switch to chat tab
      }
      currentAppState.navigationManager.updateCurrentTab(4)

      // Navigate to the specific MLS conversation
      let destination = NavigationDestination.mlsConversation(convoId)
      currentAppState.navigationManager.navigate(to: destination, in: 4)

      notificationLogger.info("Successfully navigated to MLS conversation \(convoId.prefix(16))...")
    }
  }

  /// Handle navigation from a chat notification tap
  private func handleChatNotificationNavigation(_ uriString: String) async {
    // CRITICAL FIX: Get the CURRENT AppState from AppStateManager, not the cached reference
    // After account switch, self.appState may point to the OLD account's AppState
    guard
      let currentAppState = await MainActor.run(body: {
        if case .authenticated(let state) = AppStateManager.shared.lifecycle {
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
      // Switch the chat mode to Bluesky DMs so the correct view is shown
      // Using raw value directly: "Bluesky DMs" is ChatTabView.ChatMode.bluesky.rawValue
      UserDefaults.standard.set("Bluesky DMs", forKey: "chatMode")

      // Switch to chat tab using the tab selection callback (this actually changes the tab)
      if let tabSelection = currentAppState.navigationManager.tabSelection {
        tabSelection(4)  // Switch to chat tab
      }
      currentAppState.navigationManager.updateCurrentTab(4)

      // Navigate to the specific conversation
      let destination = NavigationDestination.conversation(conversationID)
      currentAppState.navigationManager.navigate(to: destination, in: 4)

      notificationLogger.info("Successfully navigated to chat conversation \(conversationID)")
    }
  }

  /// Create a NavigationDestination from notification data
  private func createNavigationDestination(from uriString: String, type: String) throws
    -> NavigationDestination
  {
    // For URI-based notifications, convert to ATProtocolURI
    if type.lowercased() != "follow" {
      guard let uri = try? ATProtocolURI(uriString: uriString) else {
        notificationLogger.error("Invalid AT Protocol URI: \(uriString)")
        throw NSError(
          domain: "NotificationManager", code: -1,
          userInfo: [NSLocalizedDescriptionKey: "Invalid URI format"])
      }

      switch type.lowercased() {
      case "like", "repost", "reply", "mention", "quote":
        return .post(uri)

      default:
        notificationLogger.warning(
          "Unknown notification type with URI: \(type), using default post navigation")
        return .post(uri)
      }
    } else {  // Handle follow notifications
      // Extract DID from URI format (at://did:plc:xyz/...)
      if uriString.hasPrefix("at://") {
        let components = uriString.components(separatedBy: "/")
        if components.count >= 3 {
          let did = components[2]
          return .profile(did)
        }
      } else if uriString.hasPrefix("did:") {
        // If it's already just a DID
        return .profile(uriString)
      }

      // If we couldn't parse it properly
      throw NSError(
        domain: "NotificationManager", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Could not extract profile ID from URI"])
    }
  }
}

// MARK: - Notification Preferences Model

/// Represents user preferences for push notifications
struct NotificationPreferences: Codable, Equatable {
  var mentions: Bool = true
  var replies: Bool = true
  var likes: Bool = true
  var follows: Bool = true
  var reposts: Bool = true
  var quotes: Bool = true
  var likeViaRepost: Bool = true  // maps to via_likes
  var repostViaRepost: Bool = true  // maps to via_reposts
  // New key expected by server for preferences payloads
  var activitySubscriptions: Bool = true

  init() {}

  init(serverPreferences: AppBskyNotificationDefs.Preferences) {
    mentions = serverPreferences.mention.push
    replies = serverPreferences.reply.push
    likes = serverPreferences.like.push
    follows = serverPreferences.follow.push
    reposts = serverPreferences.repost.push
    quotes = serverPreferences.quote.push
    likeViaRepost = serverPreferences.likeViaRepost.push
    repostViaRepost = serverPreferences.repostViaRepost.push
    activitySubscriptions = serverPreferences.subscribedPost.push
  }

  enum CodingKeys: String, CodingKey {
    case mentions
    case replies
    case likes
    case follows
    case reposts
    case quotes
    case likeViaRepost = "via_likes"
    case repostViaRepost = "via_reposts"
    case activitySubscriptions = "activity_subscriptions"
  }

  func asDictionary() -> [String: Any] {
    return [
      "mentions": mentions,
      "replies": replies,
      "likes": likes,
      "follows": follows,
      "reposts": reposts,
      "quotes": quotes,
      "likeViaRepost": likeViaRepost,
      "repostViaRepost": repostViaRepost,
      "activitySubscriptions": activitySubscriptions,
    ]
  }
}

/// Types of notifications
enum NotificationTypes: String, Codable {
  case mentions
  case replies
  case likes
  case follows
  case reposts
  case quotes
  case likeViaRepost
  case repostViaRepost
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
