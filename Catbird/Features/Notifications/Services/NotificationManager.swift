import CryptoKit
import DeviceCheck
import Foundation
import OSLog
import Petrel
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import UserNotifications
import WidgetKit

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

  /// Pending UI prompt when a re-attestation flow is required.
  var pendingReattestationPrompt: ReattestationPrompt?

  // MARK: - Re-attestation Circuit Breaker
  private actor ReattestationCircuitBreaker {
    private var attemptsPerOperation: [String: Int] = [:]
    private var lastResetTime: Date = Date()
    private let maxAttempts = 3
    private let resetInterval: TimeInterval = 300 // 5 minutes

    func canAttempt(for operation: String) -> Bool {
      resetIfNeeded()
      let attempts = attemptsPerOperation[operation, default: 0]
      return attempts < maxAttempts
    }

    func recordAttempt(for operation: String) {
      resetIfNeeded()
      attemptsPerOperation[operation, default: 0] += 1
    }

    func reset(for operation: String) {
      attemptsPerOperation[operation] = 0
    }

    private func resetIfNeeded() {
      if Date().timeIntervalSince(lastResetTime) > resetInterval {
        attemptsPerOperation.removeAll()
        lastResetTime = Date()
      }
    }
  }

  private let circuitBreaker = ReattestationCircuitBreaker()

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

  /// App Attest payload envelope used internally, later flattened when encoding requests.
  struct AppAttestRequestPayload: Codable {
    let keyID: String
    let assertion: String
    let clientData: String
    let challenge: String
    let attestation: String?

    enum CodingKeys: String, CodingKey {
      case keyID = "key_id"
      case assertion
      case clientData = "client_data"
      case challenge
      case attestation
    }
  }

  /// Server challenge envelope returned after successful push operations.
  struct ChallengeRotationResponse: Decodable {
    let nextChallenge: AppAttestChallenge?

    enum CodingKeys: String, CodingKey {
      case nextChallenge = "next_challenge"
    }
  }

  /// Represents a push operation that can be retried after re-attestation.
  enum NotificationServiceOperation: CustomStringConvertible {
    case register(deviceToken: Data)
    case updatePreferences
    case syncRelationships
    case syncActivitySubscriptions
    case updateActivitySubscription(subjectDid: String, includePosts: Bool, includeReplies: Bool)
    case removeActivitySubscription(subjectDid: String)
    case unregister(token: Data, did: String?)

    var description: String {
      switch self {
      case .register:
        return "register"
      case .updatePreferences:
        return "updatePreferences"
      case .syncRelationships:
        return "syncRelationships"
      case .syncActivitySubscriptions:
        return "syncActivitySubscriptions"
      case .updateActivitySubscription(let subjectDid, let includePosts, let includeReplies):
        return "updateActivitySubscription(\(subjectDid), posts: \(includePosts), replies: \(includeReplies))"
      case .removeActivitySubscription(let subjectDid):
        return "removeActivitySubscription(\(subjectDid))"
      case .unregister(_, let did):
        if let did {
          return "unregister(\(did))"
        }
        return "unregister"
      }
    }
  }

  /// UI-facing prompt describing a pending re-attestation flow.
  struct ReattestationPrompt: Identifiable {
    let id = UUID()
    let message: String
    let operation: NotificationServiceOperation
    let forceKeyRotation: Bool
    let forceAttestation: Bool
  }

  enum NotificationServiceError: Error {
    case appStateUnavailable
    case clientUnavailable
    case appAttestUnsupported
    case challengeUnavailable
    case invalidServerResponse
  }

  // MARK: - Flat request payloads (match server schema)

  /// Register request with flattened App Attest proof.
  struct RegisterRequestPayload: Codable {
    let did: String
    let deviceToken: String
    // Flattened App Attest proof
    let appAttestKeyId: String
    let appAttestAssertion: String
    let appAttestClientData: String
    let appAttestChallenge: String
    let appAttestAttestation: String?

    enum CodingKeys: String, CodingKey {
      case did
      case deviceToken = "device_token"
      case appAttestKeyId = "app_attest_key_id"
      case appAttestAssertion = "app_attest_assertion"
      case appAttestClientData = "app_attest_client_data"
      case appAttestChallenge = "app_attest_challenge"
      case appAttestAttestation = "app_attest_attestation"
    }
  }

  /// Unregister request with flattened App Attest proof.
  struct UnregisterRequestPayload: Codable {
    let did: String
    let deviceToken: String
    // Flattened App Attest proof
    let appAttestKeyId: String
    let appAttestAssertion: String
    let appAttestClientData: String
    let appAttestChallenge: String
    // Note: server omits attestation; keeping it absent here

    enum CodingKeys: String, CodingKey {
      case did
      case deviceToken = "device_token"
      case appAttestKeyId = "app_attest_key_id"
      case appAttestAssertion = "app_attest_assertion"
      case appAttestClientData = "app_attest_client_data"
      case appAttestChallenge = "app_attest_challenge"
    }
  }

  /// Preferences update request with flattened App Attest proof and server-expected keys.
  struct PreferencesUpdatePayload: Codable {
    let did: String
    let deviceToken: String
    // Preference booleans
    let mentions: Bool
    let replies: Bool
    let likes: Bool
    let follows: Bool
    let reposts: Bool
    let quotes: Bool
    // Server expects these names:
    let viaLikes: Bool
    let viaReposts: Bool
    let activitySubscriptions: Bool

    enum CodingKeys: String, CodingKey {
      case did
      case deviceToken = "device_token"
      case mentions
      case replies
      case likes
      case follows
      case reposts
      case quotes
      case viaLikes = "via_likes"
      case viaReposts = "via_reposts"
      case activitySubscriptions = "activity_subscriptions"
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

  /// Response shape returned when listing subscriptions from the notification server.
  struct ActivitySubscriptionListResponse: Decodable {
    let subscriptions: [ActivitySubscriptionServerRecord]
    let nextChallenge: AppAttestChallenge?

    enum CodingKeys: String, CodingKey {
      case subscriptions
      case nextChallenge = "next_challenge"
    }
  }

  /// Current status of notification setup
  private(set) var status: NotificationStatus = .unknown

  /// Notification preferences
  private(set) var preferences = NotificationPreferences()

  /// Base URL for the notification service API
  private let serviceBaseURL: URL

  /// Persisted key for chat notification preference
  private let chatNotificationsDefaultsKey = "chatNotificationsEnabled"

  /// Whether chat message notifications are enabled locally
  var chatNotificationsEnabled: Bool = true {
    didSet {
      guard shouldPersistChatPreference, let defaults = UserDefaults(suiteName: "group.blue.catbird.shared") else {
        return
      }

      defaults.set(chatNotificationsEnabled, forKey: chatNotificationsDefaultsKey)
      notificationLogger.info("Chat notification preference updated: \(self.chatNotificationsEnabled ? "enabled" : "disabled")")
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
    serviceBaseURL: URL = {
      #if DEBUG
      // Local dev builds (simulator, device, debug config)
      return URL(string: "https://dev.notifications.catbird.blue")!
      #else
      // Release builds (TestFlight + App Store)
      return URL(string: "https://notifications.catbird.blue")!
      #endif
    }()
  ) {
    self.serviceBaseURL = serviceBaseURL
    super.init()

    if let defaults = UserDefaults(suiteName: "group.blue.catbird.shared"),
       defaults.object(forKey: chatNotificationsDefaultsKey) != nil {
      chatNotificationsEnabled = defaults.bool(forKey: chatNotificationsDefaultsKey)
    }

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

  // MARK: - Public API

  /// Update the client reference when authentication changes
  func updateClient(_ newClient: ATProtoClient?) {
    let previousClient = client
    self.client = newClient

      notificationLogger.info("🔄 Client updated: hasNewClient=\(newClient != nil), hasDeviceToken=\(self.deviceToken != nil)")

    // If we have a valid token and a new client, register the device
    if let client = newClient, let deviceToken = deviceToken {
      notificationLogger.info("🚀 Triggering device registration from updateClient")
      Task {
        await registerDeviceToken(deviceToken)
      }
    } else if newClient == nil {
      notificationLogger.info("🧹 Client cleared - cleaning up notifications")
      // Client was cleared (user logged out), clean up notifications
      Task {
        await cleanupNotifications(previousClient: previousClient)
      }
    } else if newClient != nil && deviceToken == nil {
      notificationLogger.info("⚠️ Client available but no device token yet")
    } else {
      notificationLogger.info("ℹ️ No action needed - no client and no token")
    }
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
          notificationLogger.info("✅ Called UIApplication.shared.registerForRemoteNotifications()")
          #elseif os(macOS)
          NSApplication.shared.registerForRemoteNotifications()
          notificationLogger.info("✅ Called NSApplication.shared.registerForRemoteNotifications()")
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
      notificationLogger.error("Error requesting notification permission: \(error.localizedDescription)")
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
      notificationLogger.info("📱 Permissions already granted, registering for remote notifications...")
      await MainActor.run {
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        notificationLogger.info("✅ Called UIApplication.shared.registerForRemoteNotifications() in checkNotificationStatus")
        #elseif os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        notificationLogger.info("✅ Called NSApplication.shared.registerForRemoteNotifications() in checkNotificationStatus")
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
    notificationLogger.info("📱 Processing device token from APNS: \(tokenHex.prefix(16))... (length: \(deviceToken.count))")
    self.deviceToken = deviceToken

    if
      status == .registered,
      pendingReattestationPrompt == nil,
      let previousToken = lastRegisteredDeviceToken,
      previousToken == deviceToken
    {
      notificationLogger.info("🔁 Device token already registered; skipping duplicate registration request")
      return
    }

    // Check if we have a client before attempting registration
    if client == nil {
      notificationLogger.warning("⚠️ No client available for device token registration - will retry when client is set")
      return
    }

    notificationLogger.info("🚀 Starting device token registration with notification service")
    // Register with our notification service
    await registerDeviceToken(deviceToken)
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

  /// Performs a complete App Attest re-attestation cycle and retries the failed operation.
  func performReattestation(for prompt: ReattestationPrompt) async {
    notificationLogger.info(
      "Starting re-attestation for operation: \(String(describing: prompt.operation))")

    await MainActor.run {
      pendingReattestationPrompt = nil
    }

    if prompt.forceKeyRotation {
      notificationLogger.info("🔁 Clearing App Attest state for forced key rotation")
      await clearAppAttestState()
    } else if prompt.forceAttestation {
      notificationLogger.info("♻️ Refreshing App Attest challenge for re-attestation")
      await refreshAppAttestChallenge()
    }

    switch prompt.operation {
    case .register(let deviceToken):
      await registerDeviceToken(
        deviceToken,
        forceKeyRotation: prompt.forceKeyRotation,
        forceAttestation: prompt.forceAttestation
      )
    case .updatePreferences:
      await updateNotificationPreferences(
        forceKeyRotation: prompt.forceKeyRotation,
        forceAttestation: prompt.forceAttestation
      )
    case .syncRelationships:
      await updateRelationshipsOnServer(
        forceKeyRotation: prompt.forceKeyRotation,
        forceAttestation: prompt.forceAttestation
      )
    case .syncActivitySubscriptions:
      _ = await fetchActivitySubscriptionsFromServer(
        forceKeyRotation: prompt.forceKeyRotation,
        forceAttestation: prompt.forceAttestation
      )
    case .updateActivitySubscription(let subjectDid, let includePosts, let includeReplies):
      await updateActivitySubscriptionOnServer(
        subjectDid: subjectDid,
        includePosts: includePosts,
        includeReplies: includeReplies,
        forceKeyRotation: prompt.forceKeyRotation,
        forceAttestation: prompt.forceAttestation
      )
    case .removeActivitySubscription(let subjectDid):
      await removeActivitySubscriptionFromServer(
        subjectDid: subjectDid,
        forceKeyRotation: prompt.forceKeyRotation,
        forceAttestation: prompt.forceAttestation
      )
    case .unregister(let token, let did):
      if let did {
        await unregisterDeviceToken(
          token,
          did: did,
          forceKeyRotation: prompt.forceKeyRotation,
          forceAttestation: prompt.forceAttestation
        )
      } else {
        notificationLogger.error("Cannot reattempt unregister - missing DID context")
      }
    }
  }

  func dismissReattestationPrompt() {
    pendingReattestationPrompt = nil
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
          await unregisterDeviceToken(deviceToken, did: did)
        }
      } catch {
        notificationLogger.error("Failed to determine DID during cleanup: \(error.localizedDescription)")
      }
    }

    // Reset state
    status = .unknown
    notificationsEnabled = false
    unreadCount = 0
    preferences = NotificationPreferences()
    mutedUsers.removeAll()
    blockedUsers.removeAll()
    lastRelationshipSync = nil
    lastRegisteredDeviceToken = nil

    // Clear app badge
    #if os(iOS)
    if #available(iOS 17.0, *) {
      UNUserNotificationCenter.current().setBadgeCount(0) { error in
        if let error = error {
          self.notificationLogger.error("Failed to clear badge count: \(error.localizedDescription)")
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
          self.notificationLogger.error("Failed to clear badge count: \(error.localizedDescription)")
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
              self.notificationLogger.error("Failed to update badge count: \(error.localizedDescription)")
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
              self.notificationLogger.error("Failed to update badge count: \(error.localizedDescription)")
            }
          }
        } else {
          NSApplication.shared.dockTile.badgeLabel = self.unreadCount > 0 ? "\(self.unreadCount)" : nil
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
            self.notificationLogger.error("Failed to reset badge count: \(error.localizedDescription)")
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
            self.notificationLogger.error("Failed to reset badge count: \(error.localizedDescription)")
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
      notificationLogger.debug("Chat notifications disabled, skipping notification for message \(payload.messageID)")
      return
    }

    // Check if we have permission to send notifications
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()

    guard settings.authorizationStatus == .authorized else {
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
      "senderHandle": payload.senderHandle
    ]

    // Create unique identifier to prevent duplicates
    let identifier = "chat-\(payload.conversationID)-\(payload.messageID)"

    // Create request with immediate trigger
    let request = UNNotificationRequest(
      identifier: identifier,
      content: content,
      trigger: nil // Immediate delivery
    )

    do {
      try await center.add(request)
      notificationLogger.info("Scheduled chat notification for message \(payload.messageID) in conversation \(payload.conversationID)")
    } catch {
      notificationLogger.error("Failed to schedule chat notification: \(error.localizedDescription)")
    }
  }

  // MARK: - Relationship Sync Methods

  /// Synchronizes muted and blocked users with the notification server
  func syncRelationships() async {
    // Add guard to prevent syncing when notifications are disabled
    guard notificationsEnabled else {
      notificationLogger.info("Not syncing relationships - notifications are disabled")
      return
    }

    guard let client = client else {
      notificationLogger.warning("Cannot sync relationships - no client available")
      return
    }

    // Gather relationships from GraphManager
    await gatherRelationships()

    // Send to notification server
    await updateRelationshipsOnServer()
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
  private func updateRelationshipsOnServer(
    forceKeyRotation: Bool = false,
    forceAttestation: Bool = false,
    attempt: Int = 0
  ) async {
    // Add guard to prevent sending when notifications are disabled
    guard notificationsEnabled else {
      notificationLogger.info("Not updating relationships on server - notifications are disabled")
      return
    }

    guard let client = client else {
      notificationLogger.warning("Cannot update relationships - no client available")
      return
    }

    guard let deviceToken = deviceToken else {
      notificationLogger.warning("Cannot update relationships - no device token")
      return
    }

    do {
      // Get the user's DID
      let did = try await client.getDid()

      // Create request
      var request = URLRequest(url: serviceBaseURL.appendingPathComponent("relationships"))
      request.httpMethod = "PUT"
      request.addValue("application/json", forHTTPHeaderField: "Content-Type")

      // Create payload
      let payload = RelationshipsUpdatePayload(
        did: did,
        deviceToken: hexString(from: deviceToken),
        mutes: Array(mutedUsers),
        blocks: Array(blockedUsers)
      )

      let body = try makeJSONEncoder().encode(payload)
      request.httpBody = body

      try await attachAppAttestAssertion(
        to: &request,
        did: did,
        deviceToken: deviceToken,
        bindBody: body,
        forceKeyRotation: forceKeyRotation
      )

      // Send request
      let (data, response) = try await URLSession.shared.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw NotificationServiceError.invalidServerResponse
      }

      switch httpResponse.statusCode {
      case 200, 204:
        notificationLogger.info("Successfully updated relationships on notification server")
        lastRelationshipSync = Date()
        if let keyIdentifier = await currentAppAttestInfo()?.keyIdentifier {
          await applyChallengeRotation(from: data, keyIdentifier: keyIdentifier)
        }
      case 401, 428:
        let serverError = parseServerErrorMessage(from: data) ?? "App Attest validation failed"
        notificationLogger.warning("🔐 Relationship sync rejected: \(serverError)")
        let isKeyMismatch = serverError.lowercased().contains("key mismatch")

        if isKeyMismatch {
          notificationLogger.info("🔑 Relationship sync detected key mismatch - clearing App Attest state")
          await clearAppAttestState()
        } else if attempt == 0 {
          notificationLogger.info("🔁 Retrying relationship sync with fresh App Attest assertion")
          await updateRelationshipsOnServer(
            forceKeyRotation: forceKeyRotation,
            forceAttestation: forceAttestation,
            attempt: attempt + 1
          )
          return
        }

        triggerReattestationPrompt(
          for: .syncRelationships,
          serverMessage: serverError,
          forceKeyRotation: isKeyMismatch,
          forceAttestation: isKeyMismatch
        )
      default:
        let errorMessage = parseServerErrorMessage(from: data) ?? "Unknown error"
        notificationLogger.error(
          "Failed to update relationships: HTTP \(httpResponse.statusCode) - \(errorMessage)"
        )
      }
    } catch {
      notificationLogger.error("Error updating relationships: \(error.localizedDescription)")
    }
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
    // Add guard to prevent syncing when notifications are disabled
    guard notificationsEnabled else {
      notificationLogger.info("Not syncing user data - notifications are disabled")
      return
    }

    guard status == .registered else {
      notificationLogger.warning("Cannot sync - not properly registered")
      return
    }

    // Fetch notification preferences
    await fetchNotificationPreferences()

    // Update preferences on server
    await updateNotificationPreferences()

    // Sync relationships
    await syncRelationships()

    // Sync moderation lists
    await syncModerationLists()

    notificationLogger.info("Completed full user data sync with notification server")
  }

  // MARK: - Moderation Lists & Thread Mutes

  /// Synchronizes moderation lists with the notification server
  func syncModerationLists() async {
    guard notificationsEnabled else {
      notificationLogger.info("Not syncing moderation lists - notifications are disabled")
      return
    }

    guard let client = client else {
      notificationLogger.warning("Cannot sync moderation lists - no client available")
      return
    }

    guard let deviceToken = deviceToken else {
      notificationLogger.warning("Cannot sync moderation lists - no device token")
      return
    }

    do {
      let did = try await client.getDid()

      // Fetch user's moderation lists from AT Protocol
      let blockLists = try await fetchModerationLists(client: client, type: "block")
      let muteLists = try await fetchModerationLists(client: client, type: "mute")
      let allLists = blockLists + muteLists

      notificationLogger.info("Fetched \(allLists.count) moderation lists for sync")

      // Prepare request
      var request = URLRequest(url: serviceBaseURL.appendingPathComponent("sync-moderation-lists"))
      request.httpMethod = "POST"
      request.addValue("application/json", forHTTPHeaderField: "Content-Type")

      // Create payload
      struct ModerationListPayload: Codable {
        let did: String
        let deviceToken: String
        let lists: [ModerationListDTO]
      }

      struct ModerationListDTO: Codable {
        let uri: String
        let purpose: String
        let name: String?
      }

      let payload = ModerationListPayload(
        did: did,
        deviceToken: hexString(from: deviceToken),
        lists: allLists.map {
          ModerationListDTO(uri: $0.uri, purpose: $0.purpose, name: $0.name)
        }
      )

      let body = try makeJSONEncoder().encode(payload)
      request.httpBody = body

      try await attachAppAttestAssertion(
        to: &request,
        did: did,
        deviceToken: deviceToken,
        bindBody: body
      )

      // Send request
      let (data, response) = try await URLSession.shared.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw NotificationServiceError.invalidServerResponse
      }

      if httpResponse.statusCode == 200 {
        notificationLogger.info("Successfully synced moderation lists with notification server")
        if let keyIdentifier = await currentAppAttestInfo()?.keyIdentifier {
          await applyChallengeRotation(from: data, keyIdentifier: keyIdentifier)
        }
      } else {
        notificationLogger.error("Failed to sync moderation lists: HTTP \(httpResponse.statusCode)")
      }
    } catch {
      notificationLogger.error("Error syncing moderation lists: \(error.localizedDescription)")
    }
  }

  /// Fetches moderation lists from AT Protocol
  private func fetchModerationLists(
    client: ATProtoClient,
    type: String
  ) async throws -> [(uri: String, purpose: String, name: String?)] {
    // This would use the actual AT Protocol API
    // For now, return empty array - implement based on Petrel's available APIs
    // TODO: Implement using app.bsky.graph.getListMutes and app.bsky.graph.getListBlocks
    return []
  }

  /// Mutes a thread for push notifications
  func muteThreadNotifications(threadRootURI: String) async throws {
    guard let client = client else {
      throw NotificationServiceError.clientNotConfigured
    }

    guard let deviceToken = deviceToken else {
      throw NotificationServiceError.deviceTokenNotAvailable
    }

    let did = try await client.getDid()

    var request = URLRequest(url: serviceBaseURL.appendingPathComponent("mute-thread"))
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")

    struct MuteThreadPayload: Codable {
      let did: String
      let deviceToken: String
      let threadRootUri: String

      enum CodingKeys: String, CodingKey {
        case did
        case deviceToken = "device_token"
        case threadRootUri = "thread_root_uri"
      }
    }

    let payload = MuteThreadPayload(
      did: did,
      deviceToken: hexString(from: deviceToken),
      threadRootUri: threadRootURI
    )

    let body = try makeJSONEncoder().encode(payload)
    request.httpBody = body

    try await attachAppAttestAssertion(
      to: &request,
      did: did,
      deviceToken: deviceToken,
      bindBody: body
    )

    let (_, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw NotificationServiceError.invalidServerResponse
    }

    if httpResponse.statusCode == 200 {
      notificationLogger.info("Successfully muted thread: \(threadRootURI)")
    } else {
      throw NotificationServiceError.serverError("HTTP \(httpResponse.statusCode)")
    }
  }

  /// Unmutes a thread for push notifications
  func unmuteThreadNotifications(threadRootURI: String) async throws {
    guard let client = client else {
      throw NotificationServiceError.clientNotConfigured
    }

    guard let deviceToken = deviceToken else {
      throw NotificationServiceError.deviceTokenNotAvailable
    }

    let did = try await client.getDid()

    var request = URLRequest(url: serviceBaseURL.appendingPathComponent("unmute-thread"))
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")

    struct UnmuteThreadPayload: Codable {
      let did: String
      let deviceToken: String
      let threadRootUri: String

      enum CodingKeys: String, CodingKey {
        case did
        case deviceToken = "device_token"
        case threadRootUri = "thread_root_uri"
      }
    }

    let payload = UnmuteThreadPayload(
      did: did,
      deviceToken: hexString(from: deviceToken),
      threadRootUri: threadRootURI
    )

    let body = try makeJSONEncoder().encode(payload)
    request.httpBody = body

    try await attachAppAttestAssertion(
      to: &request,
      did: did,
      deviceToken: deviceToken,
      bindBody: body
    )

    let (_, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw NotificationServiceError.invalidServerResponse
    }

    if httpResponse.statusCode == 200 {
      notificationLogger.info("Successfully unmuted thread: \(threadRootURI)")
    } else {
      throw NotificationServiceError.serverError("HTTP \(httpResponse.statusCode)")
    }
  }

  // MARK: - Private Methods

  // MARK: - App Attest Support

  private func prepareAppAttestPayload(
    did: String,
    deviceToken: Data,
    forceKeyRotation: Bool = false,
    forceAttestation: Bool = false,
    isNewRegistration: Bool = false,
    attempt: Int = 0
  ) async throws -> AppAttestRequestPayload {
    guard let appState else {
      throw NotificationServiceError.appStateUnavailable
    }

    guard DCAppAttestService.shared.isSupported else {
      notificationLogger.warning("⚠️ App Attest not supported by DCAppAttestService.isSupported")
      throw NotificationServiceError.appAttestUnsupported
    }

    notificationLogger.info("✅ App Attest is supported, proceeding with attestation")

    // Debug bundle identifier and environment
    if let bundleID = Bundle.main.bundleIdentifier {
      notificationLogger.info("📦 Bundle ID: \(bundleID)")
    } else {
      notificationLogger.warning("⚠️ No bundle identifier found")
    }

    #if DEBUG
    // Comprehensive device and environment debugging
    #if os(iOS)
          
          notificationLogger.info("🔍 DEBUG: iOS Version: \(UIDevice.current.systemVersion)")
          notificationLogger.info("🔍 DEBUG: Device Model: \(UIDevice.current.model)")
          notificationLogger.info("🔍 DEBUG: Device Name: \(UIDevice.current.name)")
#if targetEnvironment(simulator)
          notificationLogger.info("🔍 DEBUG: Running on Simulator: YES")
#else
          notificationLogger.info("🔍 DEBUG: Running on Physical Device: YES")

#endif
#endif
    // Check App Attest support in detail
    let isSupported = DCAppAttestService.shared.isSupported
    notificationLogger.info("🔍 DEBUG: DCAppAttestService.isSupported = \(isSupported)")

    // Check provisioning profile info
    if let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") {
      notificationLogger.info("🔍 DEBUG: Has embedded.mobileprovision")
    } else {
      notificationLogger.info("🔍 DEBUG: No embedded.mobileprovision (likely App Store/TestFlight)")
    }

    // Check code signing info
    if let teamID = Bundle.main.object(forInfoDictionaryKey: "TeamIdentifier") as? String {
      notificationLogger.info("🔍 DEBUG: Team ID: \(teamID)")
    }

    if !isSupported {
      notificationLogger.warning("🚧 DEBUG: App Attest not supported, creating mock payload for testing")
      let mockChallenge = "debug-challenge-\(UUID().uuidString)"
      let mockClientData = try JSONSerialization.data(withJSONObject: ["challenge": mockChallenge], options: [])
      // Return a mock payload for testing with the same JSON structure the server expects.
      return AppAttestRequestPayload(
        keyID: "debug-key-id-\(UUID().uuidString.prefix(8))",
        assertion: "debug-assertion-data",
        clientData: base64Encode(mockClientData),
        challenge: mockChallenge,
        attestation: "debug-attestation-data"
      )
    }
    #endif

    let tokenString = hexString(from: deviceToken)

    let currentInfo = await MainActor.run { appState.appAttestInfo }

    // Check if we should force a fresh key due to previous errors
    let shouldForceRefresh = currentInfo?.keyIdentifier == "62C7ShdKBMnwtz9HdcBWdyYWYobgH9MZhX7+6l7jzs0="

    var info = (forceKeyRotation || shouldForceRefresh) ? nil : currentInfo
    // Include attestation whenever we're provisioning a fresh key or this is a new registration.
    // Do NOT include attestation for forceAttestation alone - that just needs a fresh assertion.
    var shouldIncludeAttestation = forceKeyRotation || info == nil || isNewRegistration || shouldForceRefresh

    // Note: When forceAttestation=true but forceKeyRotation=false, we keep the existing key
    // and just generate a fresh assertion with a new challenge. App Attest only allows ONE
    // attestation per key (at key generation time), but unlimited assertions.

    if shouldForceRefresh {
      notificationLogger.info("🔄 Forcing fresh App Attest key generation due to potential corruption")
      await clearAppAttestState()
      info = nil
    }

    notificationLogger.info(
      "App Attest payload preparation: forceKeyRotation=\(forceKeyRotation), forceAttestation=\(forceAttestation), hasExistingInfo=\(currentInfo != nil), isNewRegistration=\(isNewRegistration), shouldForceRefresh=\(shouldForceRefresh), shouldIncludeAttestation=\(shouldIncludeAttestation)"
    )

    let keyIdentifier: String
    if let existingKey = info?.keyIdentifier, !forceKeyRotation {
      // When using an existing key, we can't send attestation (already consumed)
      // EXCEPT during new registration - server requires attestation for new devices
      // Only send attestation for brand new keys, explicit refresh, or new registration
      if !shouldForceRefresh && !isNewRegistration {
        shouldIncludeAttestation = false
      }
      keyIdentifier = existingKey
    } else {
      keyIdentifier = try await generateAppAttestKey()
      shouldIncludeAttestation = true
      info = AppAttestInfo(keyIdentifier: keyIdentifier, latestChallenge: nil)
    }

    var challenge = info?.latestChallenge
    let shouldForceChallengeRefresh = forceKeyRotation || shouldForceRefresh || forceAttestation
    if challenge == nil || challenge?.isExpired == true || shouldForceChallengeRefresh {
      do {
        challenge = try await requestNewChallenge(
          for: did,
          token: tokenString,
          forceKeyRotation: forceKeyRotation
        )
      } catch {
        notificationLogger.error("Failed to obtain challenge from server: \(error.localizedDescription)")

        // If we can't get a challenge from the server, this is now a real error
        // since we're using the proper /challenge endpoint
        throw NotificationServiceError.challengeUnavailable
      }
    }

    guard let validChallenge = challenge else {
      throw NotificationServiceError.challengeUnavailable
    }

    let clientData = try makeClientDataBytes(for: validChallenge)
    #if DEBUG
    if let clientDataString = String(data: clientData, encoding: .utf8) {
      notificationLogger.info("AppAttest clientDataJSON=\(clientDataString)")
    }
    #endif
    let clientDataHash = Data(SHA256.hash(data: clientData))

    if let expiresAt = validChallenge.expiresAt {
      let secondsUntilExpiry = expiresAt.timeIntervalSinceNow
      notificationLogger.info(
        "AppAttest challenge=\(validChallenge.challenge) len=\(clientData.count) expiresIn=\(String(format: "%.1f", secondsUntilExpiry))s"
      )
    } else {
      notificationLogger.info("AppAttest challenge=\(validChallenge.challenge) len=\(clientData.count)")
    }

    notificationLogger.info("AppAttest clientDataHash(base64url)=\(self.base64Encode(clientDataHash))")

    let attestation: String?
    if shouldIncludeAttestation {
      notificationLogger.info("Generating new App Attest attestation for keyIdentifier: \(keyIdentifier)")
      do {
        let attestationData = try await attestKey(keyIdentifier, clientDataHash: clientDataHash)
        attestation = attestationData.base64EncodedString()
        notificationLogger.info("Successfully generated attestation, length: \(attestation?.count ?? 0)")
      } catch {
        if shouldRetryAppAttest(for: error), attempt == 0 {
          notificationLogger.info("💡 App Attest attestation failed due to stale key; clearing cached state and retrying with a new key")
          await clearAppAttestState()
          return try await prepareAppAttestPayload(
            did: did,
            deviceToken: deviceToken,
            forceKeyRotation: true,
            forceAttestation: true,
            isNewRegistration: isNewRegistration,
            attempt: attempt + 1
          )
        }
        throw error
      }
    } else {
      notificationLogger.info("Skipping attestation generation (using existing key)")
      attestation = nil
    }

    let assertionData: Data
    do {
      assertionData = try await generateAppAttestAssertion(
        keyIdentifier,
        clientDataHash: clientDataHash
      )
    } catch {
      if shouldRetryAppAttest(for: error), attempt == 0 {
        notificationLogger.info("💡 App Attest assertion failed; rotating key and retrying attestation flow")
        await clearAppAttestState()
        return try await prepareAppAttestPayload(
          did: did,
          deviceToken: deviceToken,
          forceKeyRotation: true,
          forceAttestation: true,
          isNewRegistration: isNewRegistration,
          attempt: attempt + 1
        )
      }
      throw error
    }
    let assertion = assertionData.base64EncodedString()

    let payload = AppAttestRequestPayload(
      keyID: keyIdentifier,
      assertion: assertion,
      clientData: base64Encode(clientData),
      challenge: validChallenge.challenge,
      attestation: attestation
    )

    let updatedInfo = AppAttestInfo(keyIdentifier: keyIdentifier, latestChallenge: validChallenge)
    await MainActor.run {
      appState.appAttestInfo = updatedInfo
    }

    return payload
  }

  private func currentAppAttestInfo() async -> AppAttestInfo? {
    guard let appState else { return nil }
    return await MainActor.run { appState.appAttestInfo }
  }

  private func attachAppAttestAssertion(
    to request: inout URLRequest,
    did: String,
    deviceToken: Data,
    bindBody: Data? = nil,
    forceKeyRotation: Bool = false
  ) async throws {
    guard DCAppAttestService.shared.isSupported else {
      notificationLogger.warning("⚠️ App Attest not supported on this device; skipping assertion attachment")
      throw NotificationServiceError.appAttestUnsupported
    }

    guard let keyIdentifier = await currentAppAttestInfo()?.keyIdentifier else {
      notificationLogger.warning("⚠️ Missing App Attest key identifier; cannot attach assertion")
      throw NotificationServiceError.appAttestUnsupported
    }

    let tokenHex = hexString(from: deviceToken)
    let challenge = try await requestNewChallenge(
      for: did,
      token: tokenHex,
      forceKeyRotation: forceKeyRotation
    )

    let clientData = try makeClientDataBytes(for: challenge)
    guard let clientDataString = String(data: clientData, encoding: .utf8) else {
      throw NSError(
        domain: "NotificationManager",
        code: -2,
        userInfo: [
          NSLocalizedDescriptionKey: "Unable to serialize App Attest client data as UTF-8"
        ]
      )
    }
    #if DEBUG
    notificationLogger.info("AppAttest assertion clientDataJSON=\(clientDataString)")
    #endif

    notificationLogger.info("AppAttest assertion challenge=\(challenge.challenge) clientDataLen=\(clientData.count)")

    var digestInput = clientData
    if let bindBody {
      digestInput.append(bindBody)
    }

    let clientDataHash = Data(SHA256.hash(data: digestInput))
    let assertionData = try await generateAppAttestAssertion(
      keyIdentifier,
      clientDataHash: clientDataHash
    )

    request.addValue(keyIdentifier, forHTTPHeaderField: "X-AppAttest-KeyId")
    request.addValue(challenge.challenge, forHTTPHeaderField: "X-AppAttest-Challenge")
    request.addValue(assertionData.base64EncodedString(), forHTTPHeaderField: "X-AppAttest-Assertion")
    request.addValue(clientDataString, forHTTPHeaderField: "X-AppAttest-ClientData")

    if let bindBody {
      let bodyDigest = Data(SHA256.hash(data: bindBody))
      request.addValue(bodyDigest.base64EncodedString(), forHTTPHeaderField: "X-AppAttest-BodySHA256")
    }

    if let appState {
      await MainActor.run {
        appState.appAttestInfo = AppAttestInfo(
          keyIdentifier: keyIdentifier,
          latestChallenge: challenge
        )
      }
    }
  }

  private func shouldRetryAppAttest(for error: Error) -> Bool {
    guard let nsError = error as NSError?, nsError.domain == DCError.errorDomain else {
      return false
    }

    if let code = DCError.Code(rawValue: nsError.code) {
      return code == .invalidKey || code == .invalidInput
    }

    return nsError.code == 2 || nsError.code == 3
  }

  private func requestNewChallenge(
    for did: String,
    token: String,
    forceKeyRotation: Bool
  ) async throws -> AppAttestChallenge {
    // Use the proper /challenge endpoint directly
    notificationLogger.info("🎯 Requesting new challenge from /challenge endpoint")

    var request = URLRequest(url: serviceBaseURL.appendingPathComponent("challenge"))
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")

    var payload: [String: Any] = [
      "did": did,
      "device_token": token
    ]

    if forceKeyRotation {
      payload["force_key_rotation"] = true
    }

    request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw NotificationServiceError.invalidServerResponse
    }

    guard httpResponse.statusCode == 200 else {
      notificationLogger.error("❌ Challenge endpoint failed: HTTP \(httpResponse.statusCode)")
      if let responseString = String(data: data, encoding: .utf8) {
        notificationLogger.info("📄 Challenge error response: \(responseString)")
      }
      throw NSError(domain: "ChallengeError", code: httpResponse.statusCode, userInfo: nil)
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    do {
      let challenge = try decoder.decode(AppAttestChallenge.self, from: data)
      notificationLogger.info("✅ Successfully received challenge from server")
      return challenge
    } catch {
      notificationLogger.error("❌ Failed to decode challenge from server: \(error.localizedDescription)")
      if let responseString = String(data: data, encoding: .utf8) {
        notificationLogger.info("📄 Challenge response data: \(responseString)")
      }
      throw error
    }
  }

  private func base64Encode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
  }

  private func base64Decode(_ value: String) -> Data? {
    if let decoded = Data(base64Encoded: value) {
      return decoded
    }

    var normalized = value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")

    let paddingLength = (4 - (normalized.count % 4)) % 4
    if paddingLength > 0 {
      normalized.append(String(repeating: "=", count: paddingLength))
    }

    return Data(base64Encoded: normalized)
  }

  private func makeClientDataBytes(for challenge: AppAttestChallenge) throws -> Data {
    do {
      // Encode the challenge using the WebAuthn-compatible JSON structure expected by the backend.
      return try JSONSerialization.data(withJSONObject: ["challenge": challenge.challenge], options: [])
    } catch {
      throw NSError(
        domain: "NotificationManager",
        code: -1,
        userInfo: [
          NSLocalizedDescriptionKey: "Unable to encode App Attest client data JSON",
          NSUnderlyingErrorKey: error
        ]
      )
    }
  }

  private func makeJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private func clearAppAttestState() async {
    guard let appState else { return }
    await MainActor.run {
      appState.appAttestInfo = nil
      lastRegisteredDeviceToken = nil
    }
  }

  private func refreshAppAttestChallenge() async {
    guard let appState else { return }
    await MainActor.run {
      if let info = appState.appAttestInfo {
        appState.appAttestInfo = AppAttestInfo(
          keyIdentifier: info.keyIdentifier,
          latestChallenge: nil
        )
      }
    }
  }

  private func generateAppAttestKey() async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      notificationLogger.info("🔑 Generating new App Attest key...")
      DCAppAttestService.shared.generateKey { keyID, error in
        if let error {
          self.notificationLogger.error("❌ App Attest generateKey failed: \(error.localizedDescription)")
          if let nsError = error as NSError? {
            self.notificationLogger.error("   Domain: \(nsError.domain), Code: \(nsError.code)")
          }
          continuation.resume(throwing: error)
        } else if let keyID {
          self.notificationLogger.info("✅ App Attest key generated: \(keyID)")
          continuation.resume(returning: keyID)
        } else {
          self.notificationLogger.error("❌ App Attest generateKey returned nil without error")
          continuation.resume(throwing: NotificationServiceError.appAttestUnsupported)
        }
      }
    }
  }

  private func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      notificationLogger.info("🔐 Attempting to attest key: \(keyID)")
      DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash) { attestation, error in
        if let error {
          self.notificationLogger.error("❌ App Attest attestKey failed: \(error.localizedDescription)")
          if let nsError = error as NSError? {
            self.notificationLogger.error("   Domain: \(nsError.domain), Code: \(nsError.code)")
          }
          continuation.resume(throwing: error)
        } else if let attestation {
          self.notificationLogger.info("✅ App Attest attestation successful, size: \(attestation.count) bytes")
          continuation.resume(returning: attestation)
        } else {
          self.notificationLogger.error("❌ App Attest attestKey returned nil without error")
          continuation.resume(throwing: NotificationServiceError.appAttestUnsupported)
        }
      }
    }
  }

  private func generateAppAttestAssertion(
    _ keyID: String,
    clientDataHash: Data
  ) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash) {
        assertion, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let assertion {
          continuation.resume(returning: assertion)
        } else {
          continuation.resume(throwing: NotificationServiceError.appAttestUnsupported)
        }
      }
    }
  }

  private func applyChallengeRotation(from data: Data?, keyIdentifier: String) async {
    guard
      let appState,
      let data,
      !data.isEmpty
    else {
      return
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    if
      let rotation = try? decoder.decode(ChallengeRotationResponse.self, from: data),
      let nextChallenge = rotation.nextChallenge
    {
      await MainActor.run {
        appState.appAttestInfo = AppAttestInfo(
          keyIdentifier: keyIdentifier,
          latestChallenge: nextChallenge
        )
      }
      return
    }

    if
      let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
      let rawNext = jsonObject["next_challenge"],
      let rawData = try? JSONSerialization.data(withJSONObject: rawNext, options: [])
    {
      if let nextChallenge = try? decoder.decode(AppAttestChallenge.self, from: rawData) {
        await MainActor.run {
          appState.appAttestInfo = AppAttestInfo(
            keyIdentifier: keyIdentifier,
            latestChallenge: nextChallenge
          )
        }
      }
    }
  }

  private func triggerReattestationPrompt(
    for operation: NotificationServiceOperation,
    serverMessage: String?,
    forceKeyRotation: Bool = false,
    forceAttestation: Bool = false
  ) {
    let message = serverMessage?.isEmpty == false
      ? serverMessage!
      : "Push notifications need to re-verify security. Automatically re-attesting..."

    notificationLogger.info("Auto-triggering re-attestation for \(String(describing: operation)): \(message)")

    // Automatically perform re-attestation without user prompt
    Task {
      // Use simplified operation type for circuit breaker (ignore parameters like DID)
      let operationKey: String
      switch operation {
      case .register:
        operationKey = "register"
      case .unregister:
        operationKey = "unregister"
      case .updatePreferences:
        operationKey = "updatePreferences"
      case .syncRelationships:
        operationKey = "syncRelationships"
      case .syncActivitySubscriptions:
        operationKey = "syncActivitySubscriptions"
      case .updateActivitySubscription:
        operationKey = "updateActivitySubscription"
      case .removeActivitySubscription:
        operationKey = "removeActivitySubscription"
      }

      // Check circuit breaker before attempting re-attestation
      guard await circuitBreaker.canAttempt(for: operationKey) else {
        notificationLogger.error("🛑 Circuit breaker triggered for \(operationKey) - too many re-attestation attempts")
        notificationLogger.error("ℹ️ Please check server-side App Attest validation or try again in 5 minutes")

        // Only set registrationFailed status for register operations
        if case .register = operation {
          await MainActor.run {
            status = .registrationFailed(
              NSError(
                domain: "NotificationManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "App Attest validation failed repeatedly. Please try again later."]
              )
            )
          }
        }
        return
      }

      await circuitBreaker.recordAttempt(for: operationKey)

      let prompt = ReattestationPrompt(
        message: message,
        operation: operation,
        forceKeyRotation: forceKeyRotation,
        forceAttestation: forceAttestation
      )
      await performReattestation(for: prompt)
    }
  }

  private func parseServerErrorMessage(from data: Data?) -> String? {
    guard let data, !data.isEmpty else { return nil }

    if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
      if let message = json["message"] as? String {
        return message
      }
      if let error = json["error"] as? String {
        return error
      }
    }

    return String(data: data, encoding: .utf8)
  }

  private func hexString(from token: Data) -> String {
    token.map { String(format: "%02.2hhx", $0) }.joined()
  }

  /// Fetch the current set of activity subscriptions from the notification server.
  func fetchActivitySubscriptionsFromServer(
    forceKeyRotation: Bool = false,
    forceAttestation _: Bool = false
  ) async -> [ActivitySubscriptionServerRecord]? {
    guard notificationsEnabled else {
      notificationLogger.debug("Skipping activity subscription fetch - notifications disabled")
      return nil
    }

    guard status == .registered else {
      notificationLogger.debug("Skipping activity subscription fetch - notification service not registered")
      return nil
    }

    guard let client = client else {
      notificationLogger.warning("Cannot fetch activity subscriptions - missing ATProto client")
      return nil
    }

    guard let deviceToken = deviceToken else {
      notificationLogger.warning("Cannot fetch activity subscriptions - missing device token")
      return nil
    }

    do {
      let did = try await client.getDid()

      var request = URLRequest(url: serviceBaseURL.appendingPathComponent("activity-subscriptions"))
      request.httpMethod = "POST"
      request.addValue("application/json", forHTTPHeaderField: "Content-Type")

      let payload = ActivitySubscriptionFetchPayload(
        did: did,
        deviceToken: hexString(from: deviceToken)
      )

      let body = try makeJSONEncoder().encode(payload)
      request.httpBody = body

      try await attachAppAttestAssertion(
        to: &request,
        did: did,
        deviceToken: deviceToken,
        bindBody: body,
        forceKeyRotation: forceKeyRotation
      )

      let (data, response) = try await URLSession.shared.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw NotificationServiceError.invalidServerResponse
      }

      switch httpResponse.statusCode {
      case 200:
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(ActivitySubscriptionListResponse.self, from: data)
        if let keyIdentifier = await currentAppAttestInfo()?.keyIdentifier {
          await applyChallengeRotation(from: data, keyIdentifier: keyIdentifier)
        }
        notificationLogger.info("Fetched \(payload.subscriptions.count) activity subscriptions from notification server")
        return payload.subscriptions
      case 204:
        if let keyIdentifier = await currentAppAttestInfo()?.keyIdentifier {
          await applyChallengeRotation(from: data, keyIdentifier: keyIdentifier)
        }
        notificationLogger.info("Activity subscription fetch succeeded - no subscriptions registered")
        return []
      case 401, 428:
        let message = parseServerErrorMessage(from: data) ?? "App Attest validation failed"
        notificationLogger.warning("🔐 Activity subscription fetch rejected: \(message)")
        let isKeyMismatch = message.lowercased().contains("key mismatch")

        if isKeyMismatch {
          notificationLogger.info("🔑 Activity subscription fetch detected key mismatch - clearing App Attest state")
          await clearAppAttestState()
        }

        triggerReattestationPrompt(
          for: .syncActivitySubscriptions,
          serverMessage: message,
          forceKeyRotation: isKeyMismatch,
          forceAttestation: isKeyMismatch
        )
      default:
        let message = parseServerErrorMessage(from: data) ?? "Unknown error"
        notificationLogger.error(
          "Failed to fetch activity subscriptions: HTTP \(httpResponse.statusCode) - \(message)"
        )
      }
    } catch {
      notificationLogger.error("Error fetching activity subscriptions: \(error.localizedDescription)")
    }

    return nil
  }

  /// Create or update an activity subscription on the notification server.
  func updateActivitySubscriptionOnServer(
    subjectDid: String,
    includePosts: Bool,
    includeReplies: Bool,
    forceKeyRotation: Bool = false,
    forceAttestation: Bool = false
  ) async {
    guard includePosts || includeReplies else {
      await removeActivitySubscriptionFromServer(
        subjectDid: subjectDid,
        forceKeyRotation: forceKeyRotation,
        forceAttestation: forceAttestation
      )
      return
    }

    guard notificationsEnabled else {
      notificationLogger.debug("Skipping activity subscription sync - notifications disabled")
      return
    }

    guard status == .registered else {
      notificationLogger.debug("Skipping activity subscription sync - notification service not registered")
      return
    }

    guard let client = client else {
      notificationLogger.warning("Cannot sync activity subscription - missing ATProto client")
      return
    }

    guard let deviceToken = deviceToken else {
      notificationLogger.warning("Cannot sync activity subscription - missing device token")
      return
    }

    do {
      let did = try await client.getDid()

      var request = URLRequest(url: serviceBaseURL.appendingPathComponent("activity-subscriptions"))
      request.httpMethod = "PUT"
      request.addValue("application/json", forHTTPHeaderField: "Content-Type")

      let payload = ActivitySubscriptionUpsertPayload(
        did: did,
        deviceToken: hexString(from: deviceToken),
        subjectDid: subjectDid,
        includePosts: includePosts,
        includeReplies: includeReplies
      )

      let body = try makeJSONEncoder().encode(payload)
      request.httpBody = body

      try await attachAppAttestAssertion(
        to: &request,
        did: did,
        deviceToken: deviceToken,
        bindBody: body,
        forceKeyRotation: forceKeyRotation
      )

      let (data, response) = try await URLSession.shared.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw NotificationServiceError.invalidServerResponse
      }

      switch httpResponse.statusCode {
      case 200, 201, 204:
        notificationLogger.info("Synced activity subscription for \(subjectDid) with notification server")
        if let keyIdentifier = await currentAppAttestInfo()?.keyIdentifier {
          await applyChallengeRotation(from: data, keyIdentifier: keyIdentifier)
        }
      case 401, 428:
        let message = parseServerErrorMessage(from: data) ?? "App Attest validation failed"
        notificationLogger.warning("🔐 Activity subscription sync rejected for \(subjectDid): \(message)")
        let isKeyMismatch = message.lowercased().contains("key mismatch")

        if isKeyMismatch {
          notificationLogger.info("🔑 Activity subscription sync detected key mismatch - clearing App Attest state")
          await clearAppAttestState()
        }

        triggerReattestationPrompt(
          for: .updateActivitySubscription(
            subjectDid: subjectDid,
            includePosts: includePosts,
            includeReplies: includeReplies
          ),
          serverMessage: message,
          forceKeyRotation: isKeyMismatch,
          forceAttestation: isKeyMismatch
        )
      default:
        let message = parseServerErrorMessage(from: data) ?? "Unknown error"
        notificationLogger.error(
          "Failed to sync activity subscription for \(subjectDid): HTTP \(httpResponse.statusCode) - \(message)"
        )
      }
    } catch {
      notificationLogger.error("Error syncing activity subscription for \(subjectDid): \(error.localizedDescription)")
    }
  }

  /// Remove an activity subscription from the notification server.
  func removeActivitySubscriptionFromServer(
    subjectDid: String,
    forceKeyRotation: Bool = false,
    forceAttestation _: Bool = false
  ) async {
    guard notificationsEnabled else {
      notificationLogger.debug("Skipping activity subscription removal - notifications disabled")
      return
    }

    guard status == .registered else {
      notificationLogger.debug("Skipping activity subscription removal - notification service not registered")
      return
    }

    guard let client = client else {
      notificationLogger.warning("Cannot remove activity subscription - missing ATProto client")
      return
    }

    guard let deviceToken = deviceToken else {
      notificationLogger.warning("Cannot remove activity subscription - missing device token")
      return
    }

    do {
      let did = try await client.getDid()

      var request = URLRequest(url: serviceBaseURL.appendingPathComponent("activity-subscriptions"))
      request.httpMethod = "DELETE"
      request.addValue("application/json", forHTTPHeaderField: "Content-Type")

      let payload = ActivitySubscriptionDeletePayload(
        did: did,
        deviceToken: hexString(from: deviceToken),
        subjectDid: subjectDid
      )

      let body = try makeJSONEncoder().encode(payload)
      request.httpBody = body

      try await attachAppAttestAssertion(
        to: &request,
        did: did,
        deviceToken: deviceToken,
        bindBody: body,
        forceKeyRotation: forceKeyRotation
      )

      let (data, response) = try await URLSession.shared.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw NotificationServiceError.invalidServerResponse
      }

      switch httpResponse.statusCode {
      case 200, 204, 404:
        notificationLogger.info("Removed activity subscription for \(subjectDid) from notification server")
        if let keyIdentifier = await currentAppAttestInfo()?.keyIdentifier {
          await applyChallengeRotation(from: data, keyIdentifier: keyIdentifier)
        }
      case 401, 428:
        let message = parseServerErrorMessage(from: data) ?? "App Attest validation failed"
        notificationLogger.warning("🔐 Activity subscription removal rejected for \(subjectDid): \(message)")
        let isKeyMismatch = message.lowercased().contains("key mismatch")

        if isKeyMismatch {
          notificationLogger.info("🔑 Activity subscription removal detected key mismatch - clearing App Attest state")
          await clearAppAttestState()
        }

        triggerReattestationPrompt(
          for: .removeActivitySubscription(subjectDid: subjectDid),
          serverMessage: message,
          forceKeyRotation: isKeyMismatch,
          forceAttestation: isKeyMismatch
        )
      default:
        let message = parseServerErrorMessage(from: data) ?? "Unknown error"
        notificationLogger.error(
          "Failed to remove activity subscription for \(subjectDid): HTTP \(httpResponse.statusCode) - \(message)"
        )
      }
    } catch {
      notificationLogger.error("Error removing activity subscription for \(subjectDid): \(error.localizedDescription)")
    }
  }

  // MARK: - Service Calls

  /// Unregister the device token from our notification service
  private func unregisterDeviceToken(
    _ token: Data,
    did: String,
    forceKeyRotation: Bool = false,
    forceAttestation: Bool = false
  ) async {
    notificationLogger.info("Unregistering device token from notification service")

    do {
      let attest = try await prepareAppAttestPayload(
        did: did,
        deviceToken: token,
        forceKeyRotation: forceKeyRotation,
        forceAttestation: forceAttestation
      )

      var request = URLRequest(url: serviceBaseURL.appendingPathComponent("unregister"))
      request.httpMethod = "POST"
      request.addValue("application/json", forHTTPHeaderField: "Content-Type")

      let body = UnregisterRequestPayload(
        did: did,
        deviceToken: hexString(from: token),
        appAttestKeyId: attest.keyID,
        appAttestAssertion: attest.assertion,
        appAttestClientData: attest.clientData,
        appAttestChallenge: attest.challenge
      )

      let encoder = makeJSONEncoder()
      let encodedBody = try encoder.encode(body)
      request.httpBody = encodedBody

      request.addValue(attest.keyID, forHTTPHeaderField: "X-AppAttest-KeyId")
      request.addValue(attest.challenge, forHTTPHeaderField: "X-AppAttest-Challenge")
      request.addValue(attest.assertion, forHTTPHeaderField: "X-AppAttest-Assertion")
      if let clientDataRaw = base64Decode(attest.clientData),
         let clientDataString = String(data: clientDataRaw, encoding: .utf8) {
        request.addValue(clientDataString, forHTTPHeaderField: "X-AppAttest-ClientData")
      } else {
        notificationLogger.warning("⚠️ Unable to decode App Attest client data for header (unregister)")
      }
      if let attestation = attest.attestation {
        request.addValue(attestation, forHTTPHeaderField: "X-AppAttest-Attestation")
      }
      let bodyDigest = Data(SHA256.hash(data: encodedBody)).base64EncodedString()
      request.addValue(bodyDigest, forHTTPHeaderField: "X-AppAttest-BodySHA256")

      let (data, response) = try await URLSession.shared.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw NotificationServiceError.invalidServerResponse
      }

      switch httpResponse.statusCode {
      case 200, 204, 404:
        notificationLogger.info("Successfully unregistered DID \(did) for device token")
        await applyChallengeRotation(from: data, keyIdentifier: attest.keyID)
        // Reset circuit breaker on successful unregister
        await circuitBreaker.reset(for: "unregister")
      case 401, 428:
        let serverError = parseServerErrorMessage(from: data) ?? "App Attest validation failed"
        notificationLogger.warning("🔐 Unregister rejected: \(serverError)")
        let isKeyMismatch = serverError.lowercased().contains("key mismatch")
        let requiresReattestation = serverError.lowercased().contains("requires re-attestation")

        // If server doesn't know our key, we need full key rotation + attestation
        if isKeyMismatch || requiresReattestation {
          notificationLogger.info("🔑 Server doesn't recognize key - forcing full key rotation and attestation")
          await clearAppAttestState()
        }

        triggerReattestationPrompt(
          for: .unregister(token: token, did: did),
          serverMessage: serverError,
          forceKeyRotation: isKeyMismatch || requiresReattestation,
          forceAttestation: isKeyMismatch || requiresReattestation
        )
      default:
        let message = parseServerErrorMessage(from: data) ?? "Unknown error"
        notificationLogger.warning(
          "Failed to unregister device token: HTTP \(httpResponse.statusCode) - \(message)"
        )
      }
    } catch {
      notificationLogger.error("Error unregistering device token: \(error.localizedDescription)")
    }
  }

  /// Register the device token with our notification service
  private func registerDeviceToken(
    _ token: Data,
    forceKeyRotation: Bool = false,
    forceAttestation: Bool = false
  ) async {
    let tokenHex = hexString(from: token)
    notificationLogger.info("🔄 Starting device token registration: \(tokenHex.prefix(16))...")

    guard await registrationCoordinator.begin() else {
      notificationLogger.info("⏳ Registration already in progress; ignoring duplicate request")
      return
    }
    defer {
      Task { await registrationCoordinator.finish() }
    }

    if
      let prompt = pendingReattestationPrompt,
      !forceKeyRotation,
      let registeredToken = lastRegisteredDeviceToken,
      registeredToken == token
    {
      notificationLogger.info("⏸️ Registration deferred (awaiting re-attestation resolution for token \(tokenHex.prefix(16)))")
      notificationLogger.debug("ℹ️ Pending prompt: \(prompt.message.prefix(60))…")
      return
    }

    if forceKeyRotation {
      notificationLogger.info("🔁 Force key rotation requested for registration")
    }

    // Ensure we have a client and user DID
    guard let client = client else {
      notificationLogger.warning("❌ Cannot register device token - no client available")
      status = .disabled
      return
    }

    notificationLogger.info("✅ Client available, proceeding with registration")

    do {
      // Get the user's DID
      let did = try await client.getDid()
      let attest = try await prepareAppAttestPayload(
        did: did,
        deviceToken: token,
        forceKeyRotation: forceKeyRotation,
        forceAttestation: forceAttestation,
        isNewRegistration: true
      )

      var request = URLRequest(url: serviceBaseURL.appendingPathComponent("register"))
      request.httpMethod = "POST"
      request.addValue("application/json", forHTTPHeaderField: "Content-Type")

      let body = RegisterRequestPayload(
        did: did,
        deviceToken: hexString(from: token),
        appAttestKeyId: attest.keyID,
        appAttestAssertion: attest.assertion,
        appAttestClientData: attest.clientData,
        appAttestChallenge: attest.challenge,
        appAttestAttestation: attest.attestation
      )

      notificationLogger.info("Registration payload: keyId=\(attest.keyID), hasAttestation=\(attest.attestation != nil), attestationLength=\(attest.attestation?.count ?? 0)")

      #if DEBUG
      // Log if we're using mock data
      if attest.keyID.hasPrefix("debug-key-id") {
        notificationLogger.warning("🚧 DEBUG: Sending mock App Attest payload to server")
      }
      #endif

      let encodedBody = try makeJSONEncoder().encode(body)
      request.httpBody = encodedBody

      request.addValue(attest.keyID, forHTTPHeaderField: "X-AppAttest-KeyId")
      request.addValue(attest.challenge, forHTTPHeaderField: "X-AppAttest-Challenge")
      request.addValue(attest.assertion, forHTTPHeaderField: "X-AppAttest-Assertion")
      if let clientDataRaw = base64Decode(attest.clientData),
         let clientDataString = String(data: clientDataRaw, encoding: .utf8) {
        request.addValue(clientDataString, forHTTPHeaderField: "X-AppAttest-ClientData")
      } else {
        notificationLogger.warning("⚠️ Unable to decode App Attest client data for header (register)")
      }
      if let attestation = attest.attestation {
        request.addValue(attestation, forHTTPHeaderField: "X-AppAttest-Attestation")
      }
      let bodyDigest = Data(SHA256.hash(data: encodedBody)).base64EncodedString()
      request.addValue(bodyDigest, forHTTPHeaderField: "X-AppAttest-BodySHA256")

      let (data, response) = try await URLSession.shared.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw NotificationServiceError.invalidServerResponse
      }

      switch httpResponse.statusCode {
      case 200, 201:
        notificationLogger.info("✅ Successfully registered device token with notification service")
        status = .registered
        lastRegisteredDeviceToken = token
        await applyChallengeRotation(from: data, keyIdentifier: attest.keyID)
        await fetchNotificationPreferences()
        await syncRelationships()

        // Reset circuit breaker on successful registration
        await circuitBreaker.reset(for: "register")

        if let appState {
          let service = await MainActor.run { appState.activitySubscriptionService }
          Task {
            await service.requestImmediateSync()
          }
        }
      case 401, 428:
        let serverError = parseServerErrorMessage(from: data) ?? "App Attest validation failed"
        notificationLogger.warning("🔐 Server rejected App Attest (HTTP \(httpResponse.statusCode)): \(serverError)")
        let isKeyMismatch = serverError.lowercased().contains("key mismatch")
        let requiresReattestation = serverError.lowercased().contains("requires re-attestation")

        // If server doesn't know our key, we need full key rotation + attestation
        if isKeyMismatch || requiresReattestation {
          notificationLogger.info("🔑 Server doesn't recognize key - forcing full key rotation and attestation")
          await clearAppAttestState()
        }

        triggerReattestationPrompt(
          for: .register(deviceToken: token),
          serverMessage: serverError,
          forceKeyRotation: isKeyMismatch || requiresReattestation,
          forceAttestation: isKeyMismatch || requiresReattestation
        )
        status = .registrationFailed(
          NSError(
            domain: "NotificationManager",
            code: httpResponse.statusCode,
            userInfo: [NSLocalizedDescriptionKey: "App Attest revalidation required"]
          )
        )
      default:
        let errorMessage = parseServerErrorMessage(from: data) ?? "Unknown error"
        notificationLogger.error(
          "❌ Server rejected registration: HTTP \(httpResponse.statusCode) - \(errorMessage)"
        )

        // Log raw server response for debugging
        if let responseString = String(data: data, encoding: .utf8) {
          notificationLogger.info("📄 Server response: \(responseString)")
        }

        // If server requires attestation but we didn't send it, clear state and retry
        if httpResponse.statusCode == 400 && 
           (errorMessage.lowercased().contains("attestation") && 
            errorMessage.lowercased().contains("required")) {
          notificationLogger.info("🔑 Server requires attestation - clearing cached App Attest state and retrying")
          await clearAppAttestState()
          
          // Trigger retry with fresh attestation
          triggerReattestationPrompt(
            for: .register(deviceToken: token),
            serverMessage: errorMessage,
            forceKeyRotation: true,
            forceAttestation: true
          )
        }

        status = .registrationFailed(
          NSError(
            domain: "NotificationManager",
            code: httpResponse.statusCode,
            userInfo: [NSLocalizedDescriptionKey: errorMessage]
          )
        )
      }
    } catch {
      // Check if this is a DeviceCheck/App Attest error
      if let nsError = error as NSError?,
         nsError.domain == DCError.errorDomain {

        let dcCode = DCError.Code(rawValue: nsError.code)

        switch dcCode {
        case .featureUnsupported:
          notificationLogger.warning("❌ DeviceCheck/App Attest not supported on this device/simulator (featureUnsupported)")
          notificationLogger.info("💡 This is expected on iOS Simulator or older devices")

          #if DEBUG
          notificationLogger.info("🧪 DEBUG: App Attest is not available in this environment")
          notificationLogger.info("🔧 For production, ensure testing on physical devices with App Attest support")

          // In debug mode, we could consider implementing a fallback registration
          // For now, mark as failed but provide clear messaging
          status = .registrationFailed(NSError(
            domain: "NotificationManager",
            code: -1,
            userInfo: [
              NSLocalizedDescriptionKey: "App Attest not available (Development/Simulator)",
              NSLocalizedRecoverySuggestionErrorKey: "Test on a physical device for full App Attest functionality"
            ]
          ))
          #else
          // In production, this is a real failure
          status = .registrationFailed(NSError(
            domain: "NotificationManager",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Device security verification not available"]
          ))
          #endif

        case .invalidKey, .invalidInput:
          let codeDescription = dcCode == .invalidKey ? "invalid key" : "invalid input"
          notificationLogger.warning("❌ DeviceCheck/App Attest \(codeDescription) (error \(nsError.code))")
          notificationLogger.info("💡 Stored App Attest state is no longer valid; clearing cached key and retrying")
          notificationLogger.info("🔄 Clearing App Attest state and will retry on next attempt")

          await clearAppAttestState()

          status = .registrationFailed(NSError(
            domain: "NotificationManager",
            code: -1,
            userInfo: [
              NSLocalizedDescriptionKey: "App Attest key invalidated - will regenerate",
              NSLocalizedRecoverySuggestionErrorKey: "Please try enabling notifications again"
            ]
          ))

        case nil:
          switch nsError.code {
          case 2, 3:
            notificationLogger.warning("❌ DeviceCheck/App Attest error \(nsError.code) (interpreted as stale key)")
            notificationLogger.info("💡 Stored App Attest state is no longer valid; clearing cached key and retrying")
            notificationLogger.info("🔄 Clearing App Attest state and will retry on next attempt")

            await clearAppAttestState()

            status = .registrationFailed(NSError(
              domain: "NotificationManager",
              code: -1,
              userInfo: [
                NSLocalizedDescriptionKey: "App Attest key invalidated - will regenerate",
                NSLocalizedRecoverySuggestionErrorKey: "Please try enabling notifications again"
              ]
            ))

          default:
            notificationLogger.error("❌ DeviceCheck/App Attest error \(nsError.code): \(nsError.localizedDescription)")
            status = .registrationFailed(nsError)
          }

        default:
          notificationLogger.error("❌ DeviceCheck/App Attest error \(nsError.code): \(nsError.localizedDescription)")
          status = .registrationFailed(nsError)
        }
      } else {
        notificationLogger.error("❌ Error registering device token: \(error.localizedDescription)")
        status = .registrationFailed(error)
      }
    }
  }

  /// Fetch notification preferences from the server
  private func fetchNotificationPreferences(
    forceKeyRotation: Bool = false,
    forceAttestation: Bool = false,
    attempt: Int = 0
  ) async {
    guard let client = client else {
      notificationLogger.warning("Cannot fetch preferences - no client available")
      return
    }

    guard let deviceToken = deviceToken else {
      notificationLogger.warning("Cannot fetch preferences - missing device token")
      return
    }

    do {
      // Get the user's DID
      let did = try await client.getDid()

      var request = URLRequest(url: serviceBaseURL.appendingPathComponent("preferences"))
      request.httpMethod = "POST"
      request.addValue("application/json", forHTTPHeaderField: "Content-Type")
      request.addValue("application/json", forHTTPHeaderField: "Accept")

      let payload = PreferencesQueryPayload(
        did: did,
        deviceToken: hexString(from: deviceToken)
      )

      let body = try makeJSONEncoder().encode(payload)
      request.httpBody = body

      try await attachAppAttestAssertion(
        to: &request,
        did: did,
        deviceToken: deviceToken,
        bindBody: body,
        forceKeyRotation: forceKeyRotation
      )

      // Send request
      let (data, response) = try await URLSession.shared.data(for: request)

      // Check response
      guard let httpResponse = response as? HTTPURLResponse else {
        throw NotificationServiceError.invalidServerResponse
      }

      switch httpResponse.statusCode {
      case 200, 201:
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        struct PreferencesEnvelope: Decodable {
          let preferences: NotificationPreferences?
          let nextChallenge: AppAttestChallenge?

          enum CodingKeys: String, CodingKey {
            case preferences
            case nextChallenge = "next_challenge"
          }
        }

        if !data.isEmpty {
          if let envelope = try? decoder.decode(PreferencesEnvelope.self, from: data) {
            if let fetched = envelope.preferences {
              self.preferences = fetched
            }
          } else if let decodedPreferences = try? decoder.decode(NotificationPreferences.self, from: data) {
            self.preferences = decodedPreferences
          } else if let rawResponse = String(data: data, encoding: .utf8) {
            notificationLogger.warning("⚠️ Unexpected preferences payload format: \(rawResponse)")
          }
        }

        notificationLogger.info("Successfully fetched notification preferences")
        if let keyIdentifier = await currentAppAttestInfo()?.keyIdentifier {
          await applyChallengeRotation(from: data, keyIdentifier: keyIdentifier)
        }
      case 204:
        notificationLogger.info("Preferences fetch succeeded - no custom preferences stored")
        if let keyIdentifier = await currentAppAttestInfo()?.keyIdentifier {
          await applyChallengeRotation(from: data, keyIdentifier: keyIdentifier)
        }
      case 401, 428:
        let serverError = parseServerErrorMessage(from: data) ?? "App Attest validation failed"
        notificationLogger.warning("🔐 Preferences update rejected: \(serverError)")
        let isKeyMismatch = serverError.lowercased().contains("key mismatch")

        if isKeyMismatch {
          notificationLogger.info("🔑 Preferences fetch detected key mismatch - clearing App Attest state")
          await clearAppAttestState()
        } else if attempt == 0 {
          notificationLogger.info("🔁 Retrying preferences fetch with fresh App Attest assertion")
          await fetchNotificationPreferences(
            forceKeyRotation: forceKeyRotation,
            forceAttestation: forceAttestation,
            attempt: attempt + 1
          )
          return
        }

        triggerReattestationPrompt(
          for: .updatePreferences,
          serverMessage: serverError,
          forceKeyRotation: isKeyMismatch,
          forceAttestation: isKeyMismatch
        )
      default:
        let message = parseServerErrorMessage(from: data) ?? "Invalid response"
        notificationLogger.error("Failed to fetch notification preferences: HTTP \(httpResponse.statusCode) - \(message)")
        throw NSError(
          domain: "NotificationManager", code: httpResponse.statusCode,
          userInfo: [NSLocalizedDescriptionKey: message])
      }

    } catch {
      notificationLogger.error("Error fetching notification preferences: \(error.localizedDescription)")
      // Use default preferences if we can't fetch
    }
  }

  /// Update notification preferences on the server
  private func updateNotificationPreferences(
    forceKeyRotation: Bool = false,
    forceAttestation: Bool = false,
    attempt: Int = 0
  ) async {
    guard let client = client else {
      notificationLogger.warning("Cannot update preferences - no client available")
      return
    }

    guard let deviceToken = deviceToken else {
      notificationLogger.warning("Cannot update preferences - missing device token")
      return
    }

    do {
      // Get the user's DID
      let did = try await client.getDid()

      // Create a payload that matches the server schema
      let payload = PreferencesUpdatePayload(
        did: did,
        deviceToken: hexString(from: deviceToken),
        mentions: preferences.mentions,
        replies: preferences.replies,
        likes: preferences.likes,
        follows: preferences.follows,
        reposts: preferences.reposts,
        quotes: preferences.quotes,
        viaLikes: preferences.likeViaRepost,
        viaReposts: preferences.repostViaRepost,
        activitySubscriptions: preferences.activitySubscriptions
      )

      // Create request
      var request = URLRequest(url: serviceBaseURL.appendingPathComponent("preferences"))
      request.httpMethod = "PUT"
      request.addValue("application/json", forHTTPHeaderField: "Content-Type")

      // Encode payload
      let body = try makeJSONEncoder().encode(payload)
      request.httpBody = body

      try await attachAppAttestAssertion(
        to: &request,
        did: did,
        deviceToken: deviceToken,
        bindBody: body,
        forceKeyRotation: forceKeyRotation
      )

      // Send request
      let (data, response) = try await URLSession.shared.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw NotificationServiceError.invalidServerResponse
      }

      switch httpResponse.statusCode {
      case 200, 204:
        notificationLogger.info("Successfully updated notification preferences")
        if let keyIdentifier = await currentAppAttestInfo()?.keyIdentifier {
          await applyChallengeRotation(from: data, keyIdentifier: keyIdentifier)
        }

        if let appState {
          let service = await MainActor.run { appState.activitySubscriptionService }
          Task {
            await service.requestImmediateSync()
          }
        }
      case 401, 428:
        let serverError = parseServerErrorMessage(from: data) ?? "App Attest validation failed"
        notificationLogger.warning("🔐 Preferences PUT rejected: \(serverError)")
        let isKeyMismatch = serverError.lowercased().contains("key mismatch")

        if isKeyMismatch {
          notificationLogger.info("🔑 Preferences update detected key mismatch - clearing App Attest state")
          await clearAppAttestState()
        } else if attempt == 0 {
          notificationLogger.info("🔁 Retrying preferences update with fresh App Attest assertion")
          await updateNotificationPreferences(
            forceKeyRotation: forceKeyRotation,
            forceAttestation: forceAttestation,
            attempt: attempt + 1
          )
          return
        }

        triggerReattestationPrompt(
          for: .updatePreferences,
          serverMessage: serverError,
          forceKeyRotation: isKeyMismatch,
          forceAttestation: isKeyMismatch
        )
      default:
        let message = parseServerErrorMessage(from: data) ?? "Invalid response"
        throw NSError(
          domain: "NotificationManager", code: httpResponse.statusCode,
          userInfo: [NSLocalizedDescriptionKey: message])
      }

    } catch {
      notificationLogger.error("Error updating notification preferences: \(error.localizedDescription)")
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
         Date().timeIntervalSince(lastSync) > 3600 {  // If it's been over an hour
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
      notificationLogger.info("📲 Widget data saved to UserDefaults: count=\(count), lastUpdated=\(Date())")
    } else {
      notificationLogger.error(
        "❌ Failed to access shared UserDefaults with suite name 'group.blue.catbird.shared'")
    }

    // Trigger widget refresh
    WidgetCenter.shared.reloadTimelines(ofKind: "CatbirdNotificationWidget")
    notificationLogger.info("🔄 Widget timeline refresh requested for kind: CatbirdNotificationWidget")
  }
}
// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
  /// Handle notifications received while app is in the foreground
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    notificationLogger.info("Received notification while app in foreground")

    // Show notification banner even when app is in foreground
    completionHandler([.banner, .sound])
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

    if targetDid != nil || (uriString != nil && typeString != nil) {
      Task {
        if let did = targetDid {
          await ensureActiveAccount(for: did)
        }

        if let uri = uriString, let type = typeString {
          notificationLogger.info("Notification contains URI: \(uri) of type: \(type)")
          await handleNotificationNavigation(uriString: uri, type: type)
        }
      }
    }

    completionHandler()
  }

  // MARK: - Notification Navigation Handling

  @MainActor
  private func ensureActiveAccount(for did: String) async {
    guard let appState = appState else {
      notificationLogger.error("Cannot switch accounts - appState unavailable")
      return
    }

    let authManager = appState.authManager
    let currentDid = authManager.state.userDID

    if currentDid == did {
      return
    }

    notificationLogger.info("Switching active account to \(did) for notification navigation")

    do {
      try await appState.switchToAccount(did: did)
    } catch {
      notificationLogger.error("Failed to switch account for notification: \(error.localizedDescription)")
    }
  }

  /// Handle navigation from a notification tap
  private func handleNotificationNavigation(uriString: String, type: String) async {
    guard let appState = appState else {
      notificationLogger.error("Cannot navigate - appState not configured")
      return
    }

    // Handle chat notifications differently
    if type == "chat" {
      await handleChatNotificationNavigation(uriString)
      return
    }

    // Determine navigation destination based on notification type
    do {
      let destination = try createNavigationDestination(from: uriString, type: type)

      // Use main actor to update UI
      await MainActor.run {
        // Navigate to destination in home tab (index 0)
        appState.navigationManager.navigate(to: destination, in: 0)
        notificationLogger.info("Successfully navigated to destination from notification")
      }
    } catch {
      notificationLogger.error("Failed to create navigation destination: \(error.localizedDescription)")
    }
  }

  /// Handle navigation from a chat notification tap
  private func handleChatNotificationNavigation(_ uriString: String) async {
    guard let appState = appState else {
      notificationLogger.error("Cannot navigate to chat - appState not configured")
      return
    }

    // For chat notifications, uriString contains the conversationID
    let conversationID = uriString

    await MainActor.run {
      // Navigate to the chat tab (index 4) and open the conversation
      appState.navigationManager.updateCurrentTab(4) // Switch to chat tab

      // Navigate to the specific conversation
      let destination = NavigationDestination.conversation(conversationID)
      appState.navigationManager.navigate(to: destination, in: 4)

      notificationLogger.info("Successfully navigated to chat conversation \(conversationID)")
    }
  }

  /// Create a NavigationDestination from notification data
  private func createNavigationDestination(from uriString: String, type: String) throws
    -> NavigationDestination {
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
        notificationLogger.warning("Unknown notification type with URI: \(type), using default post navigation")
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
  var likeViaRepost: Bool = true   // maps to via_likes
  var repostViaRepost: Bool = true // maps to via_reposts
  // New key expected by server for preferences payloads
  var activitySubscriptions: Bool = true

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
      "activitySubscriptions": activitySubscriptions
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
