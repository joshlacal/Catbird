//
//  RepostGhostPhysicalUITests.swift
//  CatbirdUITests
//
//  Focused manual-evidence UI tests for the iOS 27 repost/notification ghost.
//

import XCTest

final class RepostGhostPhysicalUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
  }

  override func tearDownWithError() throws {
    app = nil
  }

  @MainActor
  func testRepostMenuScrollThenTabSwitchCapturesEvidence() throws {
    app.launch()

    let repostButton = waitForFirstRepostButton()
    addScreenshot(named: "01-home-feed-before-repost-menu")

    repostButton.tap()
    XCTAssertTrue(waitForMenuToAppear(), "Expected the repost menu to appear.")
    addScreenshot(named: "02-repost-menu-open")

    app.swipeUp()
    addScreenshot(named: "03-after-scroll-with-menu")

    tapTab(named: "tab_search", fallbackLabel: "Search")
    addScreenshot(named: "04-after-first-search-tap")

    tapTab(named: "tab_search", fallbackLabel: "Search")
    XCTAssertTrue(
      app.staticTexts["Search"].waitForExistence(timeout: 5)
        || app.searchFields.firstMatch.waitForExistence(timeout: 5),
      "Expected to reach Search after dismissing menu and tapping the tab."
    )
    addScreenshot(named: "05-search-after-menu-dismissed")

    tapTab(named: "tab_home", fallbackLabel: "Home")
    _ = waitForFirstRepostButton()

    app.swipeUp()
    let lowerRepostButton = waitForFirstRepostButton()
    lowerRepostButton.tap()
    XCTAssertTrue(waitForMenuToAppear(), "Expected the repost menu to appear on the scrolled feed.")
    addScreenshot(named: "06-scrolled-repost-menu-open")

    app.swipeUp()
    tapTab(named: "tab_notifications", fallbackLabel: "Notifications")
    addScreenshot(named: "07-after-notifications-first-tap")

    tapTab(named: "tab_notifications", fallbackLabel: "Notifications")
    XCTAssertTrue(
      app.staticTexts["Notifications"].waitForExistence(timeout: 5)
        || app.navigationBars["Notifications"].waitForExistence(timeout: 5),
      "Expected to reach Notifications after dismissing menu and tapping the tab."
    )
    addScreenshot(named: "08-notifications-after-menu-dismissed")
  }

  @MainActor
  func testNotificationsRepostIconScrollThenTabSwitchCapturesEvidence() throws {
    app.launch()

    tapTab(named: "tab_notifications", fallbackLabel: "Notifications")
    XCTAssertTrue(waitForNotificationsToAppear(), "Expected to reach Notifications.")
    addScreenshot(named: "01-notifications-initial")

    let foundRepostNotification = scrollUntilRepostNotificationIsVisible()
    addScreenshot(named: foundRepostNotification
      ? "02-notifications-repost-visible"
      : "02-notifications-repost-label-not-found")

    app.swipeUp()
    app.swipeDown()
    addScreenshot(named: "03-notifications-after-scroll")

    tapTab(named: "tab_search", fallbackLabel: "Search")
    XCTAssertTrue(waitForSearchToAppear(), "Expected to reach Search after leaving Notifications.")
    addScreenshot(named: "04-search-after-notifications")

    tapTab(named: "tab_home", fallbackLabel: "Home")
    addScreenshot(named: "05-home-after-notifications")

    tapTab(named: "tab_notifications", fallbackLabel: "Notifications")
    XCTAssertTrue(waitForNotificationsToAppear(), "Expected to return to Notifications.")
    addScreenshot(named: "06-notifications-return")

    tapTab(named: "tab_messages", fallbackLabel: "Messages")
    addScreenshot(named: "07-messages-after-notifications")

    XCTAssertTrue(
      foundRepostNotification,
      "Expected at least one repost notification so the arrow.2.squarepath NotificationIcon path is exercised."
    )
  }

  private func waitForFirstRepostButton() -> XCUIElement {
    let button = app.buttons["repostButton"].firstMatch
    XCTAssertTrue(button.waitForExistence(timeout: 30), "Expected at least one repost button on the feed.")
    return button
  }

  private func scrollUntilRepostNotificationIsVisible() -> Bool {
    let repostText = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS[c] 'reposted your'")
    ).firstMatch

    if repostText.waitForExistence(timeout: 5) {
      return true
    }

    for _ in 0..<8 {
      app.swipeUp()
      if repostText.waitForExistence(timeout: 1.5) {
        return true
      }
    }

    return false
  }

  private func waitForNotificationsToAppear() -> Bool {
    app.staticTexts["Notifications"].waitForExistence(timeout: 8)
      || app.navigationBars["Notifications"].waitForExistence(timeout: 8)
  }

  private func waitForSearchToAppear() -> Bool {
    app.staticTexts["Search"].waitForExistence(timeout: 8)
      || app.searchFields.firstMatch.waitForExistence(timeout: 8)
  }

  private func waitForMenuToAppear() -> Bool {
    app.buttons["Repost"].waitForExistence(timeout: 3)
      || app.buttons["Quote Post"].waitForExistence(timeout: 3)
      || app.staticTexts["Repost"].waitForExistence(timeout: 3)
      || app.staticTexts["Quote Post"].waitForExistence(timeout: 3)
  }

  private func tapTab(named identifier: String, fallbackLabel: String) {
    let identified = app.buttons[identifier].firstMatch
    if identified.waitForExistence(timeout: 2) {
      identified.tap()
      return
    }

    let labeled = app.buttons[fallbackLabel].firstMatch
    XCTAssertTrue(labeled.waitForExistence(timeout: 5), "Expected \(fallbackLabel) tab to exist.")
    labeled.tap()
  }

  private func addScreenshot(named name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
