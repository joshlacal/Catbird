import CatbirdMLSService
import UserNotifications
import OSLog

/// Handler for MLS-related push notifications
///
/// Processes silent push notifications from the MLS server and triggers
/// appropriate client-side actions (e.g., key package replenishment).
actor MLSNotificationHandler {
  static let shared = MLSNotificationHandler()

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSNotifications")

  private init() {}

  /// Handle a low key package inventory notification
  ///
  /// This is called when the server detects that a user's key package inventory
  /// has dropped below the critical threshold.
  ///
  /// - Parameters:
  ///   - userInfo: The notification payload from APNs
  ///   - appState: The AppState instance to access MLS conversation manager
  func handleKeyPackageLowInventory(userInfo: [AnyHashable: Any], appState: AppState) async {
    logger.info("Received low key package inventory notification")

    guard let available = userInfo["available"] as? Int,
          let threshold = userInfo["threshold"] as? Int
    else {
      logger.error("Invalid notification payload - missing required fields")
      return
    }

    logger.warning(
      "Key package inventory critically low: \(available) available (threshold: \(threshold))")

    // Trigger immediate key package refresh
    do {
      // Get manager from MainActor context
      guard let manager = await appState.getMLSConversationManager() else {
        logger.error("MLS conversation manager not initialized - cannot replenish key packages")
        return
      }

      // Force refresh to replenish inventory immediately
      try await manager.smartRefreshKeyPackages()

      logger.info("Successfully replenished key packages in response to notification")
    } catch {
      logger.error("Failed to replenish key packages: \(error)")
    }
  }

  /// Handle any MLS notification based on type
  ///
  /// - Parameters:
  ///   - userInfo: The notification payload from APNs
  ///   - appState: The AppState instance to access MLS conversation manager
  func handleNotification(userInfo: [AnyHashable: Any], appState: AppState) async {
    guard let notificationType = userInfo["type"] as? String else {
      logger.error("Notification missing 'type' field")
      return
    }

    logger.info("Processing MLS notification of type: \(notificationType)")

    switch notificationType {
    case "keyPackageLowInventory":
      await handleKeyPackageLowInventory(userInfo: userInfo, appState: appState)

    default:
      logger.warning("Unknown MLS notification type: \(notificationType)")
    }
  }
}
