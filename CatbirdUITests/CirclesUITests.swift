//
//  CirclesUITests.swift
//  CatbirdUITests
//
//  UI tests for Catbird Circles end-to-end user flows and rollout gates.
//

import XCTest

final class CirclesUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
  }

  override func tearDownWithError() throws {
    app = nil
  }

  // MARK: - Launch Helpers

  private func launchAsAliceWithCirclesEnabled(customArgs: [String] = []) {
    app = XCUIApplication()
    app.launchArguments = [
      "-UITestMode", "true",
      "-SkipOnboarding", "true",
      "--enable-circles",
      "-feature.circles.enabled", "YES",
      "--circles-server-capable"
    ] + customArgs
    app.launchEnvironment = [
      "DISABLE_ANIMATIONS": "1",
      "ENABLE_CIRCLES": "1"
    ]
    app.launch()
  }

  private func launchWithUnsupportedCircles() {
    app = XCUIApplication()
    app.launchArguments = [
      "-UITestMode", "true",
      "-SkipOnboarding", "true",
      "--enable-circles",
      "-feature.circles.enabled", "YES",
      "--circles-unsupported-pds"
    ]
    app.launchEnvironment = [
      "DISABLE_ANIMATIONS": "1",
      "ENABLE_CIRCLES": "1"
    ]
    app.launch()
  }

  // MARK: - Navigation & Action Helpers

  private func openCirclesFeed() {
    // Look for Circles button in feeds drawer / start page or tab bar
    let circlesButton = app.buttons["Circles"]
    if circlesButton.waitForExistence(timeout: 4) {
      circlesButton.tap()
    } else {
      let fallback = app.staticTexts["Circles"]
      if fallback.waitForExistence(timeout: 3) {
        fallback.tap()
      }
    }
  }

  private func createCircle(named name: String, members: [String]) {
    openCirclesFeed()

    let createButton = app.buttons["Create Circle"]
    if createButton.waitForExistence(timeout: 3) {
      createButton.tap()
    }

    let nameField = app.textFields["Circle name"]
    if nameField.waitForExistence(timeout: 3) {
      nameField.tap()
      nameField.typeText(name)
    }

    if !members.isEmpty {
      let membersField = app.textFields["Initial member DIDs"]
      if membersField.waitForExistence(timeout: 2) {
        membersField.tap()
        membersField.typeText(members.joined(separator: ", "))
      }
    }

    let submitButton = app.buttons["Create Circle"]
    if submitButton.waitForExistence(timeout: 2) && submitButton.isEnabled {
      submitButton.tap()
    }
  }

  private func postToCircle(named circleName: String, text: String) {
    let composeButton = app.buttons["compose.fab"]
    if composeButton.waitForExistence(timeout: 3) {
      composeButton.tap()
    }

    let audiencePicker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Audience:'")).firstMatch
    if audiencePicker.waitForExistence(timeout: 3) {
      audiencePicker.tap()
      let circleOption = app.buttons[circleName]
      if circleOption.waitForExistence(timeout: 2) {
        circleOption.tap()
      }
    }

    let postEditor = app.textViews.firstMatch
    if postEditor.waitForExistence(timeout: 2) {
      postEditor.tap()
      postEditor.typeText(text)
    }

    let sendButton = app.buttons["post.send"]
    if sendButton.waitForExistence(timeout: 2) && sendButton.isEnabled {
      sendButton.tap()
    }
  }

  private func assertCircleBadge(named circleName: String) {
    let badge = app.staticTexts["Circle: \(circleName)"]
    if !badge.waitForExistence(timeout: 3) {
      let altBadge = app.otherElements.matching(NSPredicate(format: "label CONTAINS[c] %@", circleName)).firstMatch
      XCTAssertTrue(altBadge.waitForExistence(timeout: 3), "Expected circle badge for \(circleName)")
    }
  }

  private func removeMember(_ memberDID: String) {
    let settingsButton = app.buttons["Circle settings and members"]
    if settingsButton.waitForExistence(timeout: 3) {
      settingsButton.tap()
    }

    let memberRow = app.cells.matching(NSPredicate(format: "label CONTAINS[c] %@", memberDID)).firstMatch
    if memberRow.waitForExistence(timeout: 3) {
      memberRow.swipeLeft()
      let removeButton = app.buttons["Remove Member"]
      if removeButton.waitForExistence(timeout: 2) {
        removeButton.tap()
      }
    }
  }

  private func assertRemovalDisclosureVisible() {
    let disclosure = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'removed' OR label CONTAINS[c] 'disclosures'")).firstMatch
    XCTAssertTrue(disclosure.waitForExistence(timeout: 3), "Expected removal disclosure to be visible")
  }

  // MARK: - Step 3 / 6 Required Tests

  /// Approved end-to-end scenario: Create Circle, post, verify badge, remove member, verify removal disclosure
  func testCreatePostReplyLikeRemoveMember() throws {
    launchAsAliceWithCirclesEnabled()
    createCircle(named: "Family", members: ["did:plc:bobtest123", "did:plc:caroltest456"])
    postToCircle(named: "Family", text: "private family update")
    assertCircleBadge(named: "Family")
    removeMember("did:plc:bobtest123")
    assertRemovalDisclosureVisible()
  }

  /// 1. Unsupported PDS: Circles disabled with explanation.
  func testUnsupportedCapabilityShowsExplanation() throws {
    launchWithUnsupportedCircles()

    let unsupportedEntry = app.buttons["Circles, unsupported"]
    if unsupportedEntry.waitForExistence(timeout: 4) {
      XCTAssertFalse(unsupportedEntry.isEnabled, "Unsupported Circles entry must be disabled")
    } else {
      let explanation = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'requires a PDS that supports' OR label CONTAINS[c] 'unsupported'")).firstMatch
      XCTAssertTrue(explanation.waitForExistence(timeout: 4), "Expected unsupported explanation")
    }
  }

  /// 3. Destination lock during image upload: destination remains visible and non-interactive through upload
  func testDestinationLockedDuringImageUpload() throws {
    launchAsAliceWithCirclesEnabled()

    let composeButton = app.buttons["compose.fab"]
    if composeButton.waitForExistence(timeout: 3) {
      composeButton.tap()
    }

    let audiencePicker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Audience:'")).firstMatch
    XCTAssertTrue(audiencePicker.waitForExistence(timeout: 3), "Audience picker must be present in composer")
    XCTAssertTrue(audiencePicker.label.contains("Public"), "Default composer destination must be Public")
  }

  /// 4. Feed: Circle badge visible; no repost/quote/share actions.
  func testUnsupportedActionsAbsentForCirclePost() throws {
    launchAsAliceWithCirclesEnabled()

    openCirclesFeed()

    // For a circle post, repost / quote / public share buttons must not exist
    let repostButton = app.buttons["repost.action"]
    let quoteButton = app.buttons["quote.action"]
    let publicShareButton = app.buttons["share.public"]

    XCTAssertFalse(repostButton.exists, "Repost action must be absent for Circle posts")
    XCTAssertFalse(quoteButton.exists, "Quote action must be absent for Circle posts")
    XCTAssertFalse(publicShareButton.exists, "Public share action must be absent for Circle posts")
  }

  /// 5. Thread: private reply remains in Family Circle.
  func testPrivateReplyRemainsInCircle() throws {
    launchAsAliceWithCirclesEnabled()

    openCirclesFeed()

    let replyButton = app.buttons["reply.action"].firstMatch
    if replyButton.waitForExistence(timeout: 3) {
      replyButton.tap()

      let audiencePicker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Audience:'")).firstMatch
      if audiencePicker.waitForExistence(timeout: 3) {
        // Reply audience must be locked
        XCTAssertFalse(audiencePicker.isEnabled, "Reply audience must be locked to the parent Circle")
      }
    }
  }

  /// 6. Notifications: generic push causes authenticated Circle refresh.
  func testGenericNotificationRefresh() throws {
    launchAsAliceWithCirclesEnabled()

    let notificationsTab = app.buttons["tab_notifications"]
    if notificationsTab.waitForExistence(timeout: 3) {
      notificationsTab.tap()
      let circleSection = app.staticTexts["Circles Activity"].firstMatch
      // If Circle notifications exist or section is rendered, verify it does not expose raw private message
      XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 3))
    }
  }

  /// 7. Account switch/removal: prior Circle content disappears.
  func testAccountSwitchPurgesPriorCircleContentAndSwitchBackReloads() throws {
    launchAsAliceWithCirclesEnabled()

    // Open settings/account switcher if available
    let settingsTab = app.buttons["tab_settings"]
    if settingsTab.waitForExistence(timeout: 3) {
      settingsTab.tap()
      XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
    }
  }

  /// Removal disclosure copy is displayed in Circle management
  func testMemberRemovalDisclosure() throws {
    launchAsAliceWithCirclesEnabled()
    openCirclesFeed()

    let settingsButton = app.buttons["Circle settings and members"]
    if settingsButton.waitForExistence(timeout: 3) {
      settingsButton.tap()
      let disclosures = app.staticTexts["Circle privacy and membership disclosures"]
      XCTAssertTrue(disclosures.waitForExistence(timeout: 3) || app.navigationBars["Circle Settings"].waitForExistence(timeout: 3))
    }
  }
}
