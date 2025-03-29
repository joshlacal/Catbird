import Foundation
import OSLog
import Petrel
import SwiftUI
import UIKit
import UserNotifications

/// Manages push notifications registration and handling for the Catbird app
@Observable
final class NotificationManager: NSObject {
  // MARK: - Properties

  /// Logger for notification-related events
  private let logger = Logger(subsystem: "blue.catbird", category: "Notifications")

  /// The AT Protocol client for API calls
  private var client: ATProtoClient?

  /// Reference to the app state for navigation
  private weak var appState: AppState?

  /// Device token for APNS
  private(set) var deviceToken: Data?

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
      case (.registrationFailed(let error1), .registrationFailed(let error2)):
        return error1.localizedDescription == error2.localizedDescription
      default:
        return false
      }
    }
  }

  /// A payload for updating notification preferences.
  struct PreferencesPayload: Codable {
    let did: String
    let mentions: Bool
    let replies: Bool
    let likes: Bool
    let follows: Bool
    let reposts: Bool
    let quotes: Bool
  }

  /// Current status of notification setup
  private(set) var status: NotificationStatus = .unknown

  /// Notification preferences
  private(set) var preferences = NotificationPreferences()

  /// Base URL for the notification service API
  private let serviceBaseURL: URL

  // MARK: - Initialization

  init(serviceBaseURL: URL = URL(string: "https://notifications.catbird.blue")!) {
    self.serviceBaseURL = serviceBaseURL
    super.init()

    // Register for app lifecycle notifications to handle token registration
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
  }

  /// Configure with app state reference for navigation
  func configure(with appState: AppState) {
    self.appState = appState
    logger.debug("NotificationManager configured with AppState reference")
  }

  // MARK: - Public API

  /// Update the client reference when authentication changes
  func updateClient(_ client: ATProtoClient?) {
    self.client = client

    // If we have a valid token and a new client, register the device
    if let client = client, let deviceToken = deviceToken {
      Task {
        await registerDeviceToken(deviceToken)
      }
    }
  }

  /// Request notification permissions from the user
  @MainActor
  func requestNotificationPermission() async {
    logger.info("Requesting notification permission")
    status = .waitingForPermission

    do {
      // Request authorization
      let center = UNUserNotificationCenter.current()
      let options: UNAuthorizationOptions = [.alert, .sound, .badge]
      let granted = try await center.requestAuthorization(options: options)

      // Update state based on user's choice
      if granted {
        logger.info("Notification permission granted")
        notificationsEnabled = true

        // Register for remote notifications on the main thread
        await MainActor.run {
          UIApplication.shared.registerForRemoteNotifications()
        }

        // Check current settings to confirm
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .authorized {
          logger.info("Notification settings confirmed authorized")
        } else {
          logger.warning(
            "Unexpected notification settings status: \(settings.authorizationStatus.rawValue)")
        }
      } else {
        logger.notice("Notification permission denied by user")
        status = .permissionDenied
        notificationsEnabled = false
      }
    } catch {
      logger.error("Error requesting notification permission: \(error.localizedDescription)")
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
    logger.debug("Checking notification status")

    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()

    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      logger.info("Notifications are authorized")
      notificationsEnabled = true

      // Make sure we're registered for remote notifications
      await MainActor.run {
        UIApplication.shared.registerForRemoteNotifications()
      }

      // If we already have a token, update status accordingly
      if deviceToken != nil {
        status = .registered
      }

    case .denied:
      logger.info("Notifications permission denied")
      notificationsEnabled = false
      status = .permissionDenied

    case .notDetermined:
      logger.info("Notification permission not determined")
      notificationsEnabled = false
      status = .unknown

    @unknown default:
      logger.warning("Unknown notification authorization status")
      notificationsEnabled = false
      status = .unknown
    }
  }

  /// Process a new device token from APNS
  @MainActor
  func handleDeviceToken(_ deviceToken: Data) async {
    logger.info("Received device token from APNS")
    self.deviceToken = deviceToken

    // Register with our notification service
    await registerDeviceToken(deviceToken)
  }

  /// Update notification preferences
  func updatePreferences(_ newPreferences: NotificationPreferences) async {
    preferences = newPreferences

    // Only send update if we're in a good state
    guard status == .registered, let token = deviceToken else {
      logger.warning("Not updating preferences - not properly registered")
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
    }

    await updatePreferences(newPreferences)
  }

  // MARK: - Private Methods

  /// Register the device token with our notification service
  private func registerDeviceToken(_ token: Data) async {
    // Ensure we have a client and user DID
    guard let client = client else {
      logger.warning("Cannot register device token - no client available")
      status = .disabled
      return
    }

    do {
      // Get the user's DID
         let did = try await client.getDid()

      // Convert token to string format
      let tokenString = token.map { String(format: "%02.2hhx", $0) }.joined()

      // Create request
      var request = URLRequest(url: serviceBaseURL.appendingPathComponent("register"))
      request.httpMethod = "POST"
      request.addValue("application/json", forHTTPHeaderField: "Content-Type")

      // Create payload
      let payload: [String: String] = [
        "did": did,
        "device_token": tokenString,
      ]

      // Encode payload
      request.httpBody = try JSONEncoder().encode(payload)

      // Send request
      let (data, response) = try await URLSession.shared.data(for: request)

      // Check response
      guard let httpResponse = response as? HTTPURLResponse else {
        throw NSError(
          domain: "NotificationManager", code: -1,
          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
      }

      if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
        logger.info("Successfully registered device token with notification service")
        status = .registered

        // Now that we're registered, fetch the current preferences
        await fetchNotificationPreferences()
      } else {
        let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
        logger.error(
          "Failed to register device token: HTTP \(httpResponse.statusCode) - \(errorMessage)")
        status = .registrationFailed(
          NSError(
            domain: "NotificationManager", code: httpResponse.statusCode,
            userInfo: [NSLocalizedDescriptionKey: errorMessage]))
      }
    } catch {
      logger.error("Error registering device token: \(error.localizedDescription)")
      status = .registrationFailed(error)
    }
  }

  /// Fetch notification preferences from the server
  private func fetchNotificationPreferences() async {
    guard let client = client else {
      logger.warning("Cannot fetch preferences - no client available")
      return
    }

    do {
      // Get the user's DID
      let did = try await client.getDid()

      // Create request
      var components = URLComponents(
        url: serviceBaseURL.appendingPathComponent("preferences"), resolvingAgainstBaseURL: true)
      components?.queryItems = [URLQueryItem(name: "did", value: did)]

      guard let requestURL = components?.url else {
        throw NSError(
          domain: "NotificationManager", code: -1,
          userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
      }

      var request = URLRequest(url: requestURL)
      request.httpMethod = "GET"

      // Send request
      let (data, response) = try await URLSession.shared.data(for: request)

      // Check response
      guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
        throw NSError(
          domain: "NotificationManager", code: -1,
          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
      }

      // Decode preferences
      let decodedPreferences = try JSONDecoder().decode(NotificationPreferences.self, from: data)

      // Update local preferences
      self.preferences = decodedPreferences
      logger.info("Successfully fetched notification preferences")

    } catch {
      logger.error("Error fetching notification preferences: \(error.localizedDescription)")
      // Use default preferences if we can't fetch
    }
  }

  /// Update notification preferences on the server
  private func updateNotificationPreferences() async {
    guard let client = client else {
      logger.warning("Cannot update preferences - no client available")
      return
    }

    do {
        
      // Get the user's DID
        let did = try await client.getDid() 
      // Create a payload with explicit types
      let payload = PreferencesPayload(
        did: did,
        mentions: preferences.mentions,
        replies: preferences.replies,
        likes: preferences.likes,
        follows: preferences.follows,
        reposts: preferences.reposts,
        quotes: preferences.quotes
      )

      // Create request
      var request = URLRequest(url: serviceBaseURL.appendingPathComponent("preferences"))
      request.httpMethod = "PUT"
      request.addValue("application/json", forHTTPHeaderField: "Content-Type")

      // Encode payload
      request.httpBody = try JSONEncoder().encode(payload)

      // Send request
      let (_, response) = try await URLSession.shared.data(for: request)

      // Check response
      guard let httpResponse = response as? HTTPURLResponse,
        httpResponse.statusCode == 200 || httpResponse.statusCode == 204
      else {
        throw NSError(
          domain: "NotificationManager", code: -1,
          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
      }

      logger.info("Successfully updated notification preferences")

    } catch {
      logger.error("Error updating notification preferences: \(error.localizedDescription)")
    }
  }

  // MARK: - App Lifecycle

  @objc private func appDidBecomeActive() {
    // Check notification status when app becomes active
    Task {
      await checkNotificationStatus()
    }
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

    logger.info("Received notification while app in foreground")

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
    logger.info("User interacted with notification: \(userInfo)")

    // Handle navigation based on notification
    if let uriString = userInfo["uri"] as? String,
      let typeString = userInfo["type"] as? String
    {

      logger.info("Notification contains URI: \(uriString) of type: \(typeString)")

      // Parse the URI and navigate
      handleNotificationNavigation(uriString: uriString, type: typeString)
    }

    completionHandler()
  }

  // MARK: - Notification Navigation Handling

  /// Handle navigation from a notification tap
  private func handleNotificationNavigation(uriString: String, type: String) {
    guard let appState = appState else {
      logger.error("Cannot navigate - appState not configured")
      return
    }

    // Determine navigation destination based on notification type
    do {
      let destination = try createNavigationDestination(from: uriString, type: type)

      // Use main actor to update UI
      Task { @MainActor in
        // Navigate to destination in home tab (index 0)
        appState.navigationManager.navigate(to: destination, in: 0)
        logger.info("Successfully navigated to destination from notification")
      }
    } catch {
      logger.error("Failed to create navigation destination: \(error.localizedDescription)")
    }
  }

  /// Create a NavigationDestination from notification data
  private func createNavigationDestination(from uriString: String, type: String) throws
    -> NavigationDestination
  {
    // For URI-based notifications, convert to ATProtocolURI
    if type.lowercased() != "follow" {
      guard let uri = try? ATProtocolURI(uriString: uriString) else {
        logger.error("Invalid AT Protocol URI: \(uriString)")
        throw NSError(
          domain: "NotificationManager", code: -1,
          userInfo: [NSLocalizedDescriptionKey: "Invalid URI format"])
      }

      switch type.lowercased() {
      case "like", "repost", "reply", "mention", "quote":
        return .post(uri)

      default:
        logger.warning("Unknown notification type with URI: \(type), using default post navigation")
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

  func asDictionary() -> [String: Any] {
    return [
      "mentions": mentions,
      "replies": replies,
      "likes": likes,
      "follows": follows,
      "reposts": reposts,
      "quotes": quotes,
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
}
