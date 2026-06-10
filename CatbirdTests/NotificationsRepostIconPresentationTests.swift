//
//  NotificationsRepostIconPresentationTests.swift
//  CatbirdTests
//

import Foundation
import Testing

@Suite("Notifications repost icon presentation")
struct NotificationsRepostIconPresentationTests {
  @Test("Notification icons leave the render tree when the tab is inactive")
  func notificationIconsAreRemovedWhileTabIsInactive() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Catbird/Features/Notifications/Views/NotificationsView.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(
      source.contains("NotificationIcon(type: group.type, isActiveTab: isActiveTab)"),
      "Notification cards should pass tab visibility down to the SF Symbol layer."
    )

    guard let iconRange = source.range(of: "struct NotificationIcon: View"),
      let mediaRange = source.range(of: "// MARK: - Media Thumbnail Support")
    else {
      Issue.record("NotificationsView should keep NotificationIcon readable for regression checks.")
      return
    }

    let iconSource = String(source[iconRange.lowerBound..<mediaRange.lowerBound])
    #expect(
      iconSource.contains("let isActiveTab: Bool"),
      "NotificationIcon should know whether its tab is active."
    )
    #expect(
      iconSource.contains("if isActiveTab"),
      "The SF Symbol should only exist while the Notifications tab is active."
    )
    #expect(
      iconSource.contains("Color.clear"),
      "Inactive notification rows should preserve layout without keeping an SF Symbol layer alive."
    )
    #expect(
      iconSource.contains(".id(type)"),
      "The active SF Symbol should have per-notification-type identity."
    )
  }
}
