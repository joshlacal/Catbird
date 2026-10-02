//
//  NotificationsRepostIconPresentationTests.swift
//  CatbirdTests
//

import Foundation
import Testing

@Suite("Notifications repost icon presentation")
struct NotificationsRepostIconPresentationTests {
  @Test("Notification icons remain stable across tab selection changes")
  func notificationIconsRemainStableAcrossTabSelectionChanges() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Catbird/Features/Notifications/Views/NotificationsView.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(
      source.contains("NotificationIcon(type: group.type)"),
      "Notification cards should render the icon without binding it to root tab visibility."
    )

    guard let iconRange = source.range(of: "struct NotificationIcon: View"),
      let mediaRange = source.range(of: "// MARK: - Media Thumbnail Support")
    else {
      Issue.record("NotificationsView should keep NotificationIcon readable for regression checks.")
      return
    }

    let iconSource = String(source[iconRange.lowerBound..<mediaRange.lowerBound])
    #expect(
      !iconSource.contains("let isActiveTab: Bool"),
      "NotificationIcon should not mutate its render tree during TabView selection changes."
    )
    #expect(
      !iconSource.contains("if isActiveTab"),
      "Avoid swapping the SF Symbol for a placeholder during the outgoing tab transition."
    )
    #expect(
      !iconSource.contains("Color.clear"),
      "Avoid replacing the icon with Color.clear while List cells are being hidden by TabView."
    )
    #expect(
      iconSource.contains("Image(systemName: type.icon)"),
      "The notification type should map directly to a stable SF Symbol image."
    )
  }
}
