import Foundation

/// Shared with the settings topic: emitted only after the accepted-labeler header is applied.
enum ProfileLabelRefresh {
  static let notificationName = Notification.Name("CatbirdAcceptLabelersHeaderDidChange")

  static func matches(
    _ notification: Notification,
    preferencesManager: AnyObject,
    viewerDID: String,
    isActiveViewer: Bool
  ) -> Bool {
    guard isActiveViewer, !viewerDID.isEmpty,
          notification.name == notificationName,
          let sender = notification.object as AnyObject?, sender === preferencesManager,
          notification.userInfo?["accountDID"] as? String == viewerDID,
          notification.userInfo?["labelerDIDs"] as? [String] != nil else { return false }
    return true
  }
}
