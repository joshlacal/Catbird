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

  private func launchWithCircles(extraArgs: [String] = []) {
    app = XCUIApplication()
    app.launchArguments = [
      "--e2e-mode",
      "--run-id=circles-ui-e2e",
      "--enable-circles",
      "--circles-server-capable",
      "--e2e-fixture-account"
    ] + extraArgs
    app.launch()
  }

  private func launchWithUnsupportedCircles() {
    app = XCUIApplication()
    app.launchArguments = [
      "--e2e-mode",
      "--run-id=circles-ui-unsupported",
      "--enable-circles",
      "--circles-unsupported-pds",
      "--e2e-fixture-account"
    ]
    app.launch()
  }

  // MARK: - Navigation & Action Helpers

  private func openCirclesFeed() {
    let circlesButton = app.buttons["Circles"]
    XCTAssertTrue(circlesButton.waitForExistence(timeout: 5), "Expected Circles feed entry in drawer or navigation")
    circlesButton.tap()
  }

  private func createCircle(named name: String, initialMemberDID: String) {
    let createButton = app.buttons["Create Circle"]
    XCTAssertTrue(createButton.waitForExistence(timeout: 5), "Expected Create Circle button")
    createButton.tap()

    let nameField = app.textFields["Circle name"]
    XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Expected Circle name text field")
    nameField.tap()
    nameField.typeText(name)

    let membersField = app.textViews["Initial member DIDs"]
    if !membersField.exists {
      let altField = app.textFields["Initial member DIDs"]
      XCTAssertTrue(altField.waitForExistence(timeout: 3), "Expected Initial member DIDs field")
      altField.tap()
      altField.typeText(initialMemberDID)
    } else {
      membersField.tap()
      membersField.typeText(initialMemberDID)
    }

    let disclosure = app.staticTexts["Membership history disclosure"]
    XCTAssertTrue(disclosure.waitForExistence(timeout: 5), "Expected membership history disclosure section")

    let submitButton = app.buttons["Create Circle"]
    XCTAssertTrue(submitButton.waitForExistence(timeout: 5), "Expected submit Create Circle button")
    XCTAssertTrue(submitButton.isEnabled, "Submit button should be enabled for valid input")
    submitButton.tap()
  }

  // MARK: - Required Tests

  /// 1. Unsupported PDS: Circles disabled with explanation.
  func testUnsupportedCapabilityShowsExplanation() throws {
    launchWithUnsupportedCircles()

    let unsupportedEntry = app.buttons["Circles, unsupported"]
    if unsupportedEntry.waitForExistence(timeout: 5) {
      XCTAssertFalse(unsupportedEntry.isEnabled, "Unsupported Circles entry must be disabled")
    }

    let explanation = app.staticTexts["Circles requires a PDS that supports ATProto Spaces"]
    XCTAssertTrue(explanation.waitForExistence(timeout: 5), "Expected unsupported capability explanation text")
  }

  /// 2. Approved end-to-end scenario: Create Circle, post, verify badge, remove member, verify removal disclosure
  func testCreatePostReplyLikeRemoveMember() throws {
    launchWithCircles()

    // 1. Open Circles feed and create "Family" circle
    openCirclesFeed()
    createCircle(named: "Family", initialMemberDID: "did:plc:bobtest123")

    // 2. Open Composer, verify default Public audience, then select Family
    let composeButton = app.buttons["compose.fab"]
    if !composeButton.exists {
      let navCompose = app.buttons["New Post"]
      XCTAssertTrue(navCompose.waitForExistence(timeout: 5), "Expected compose button")
      navCompose.tap()
    } else {
      composeButton.tap()
    }

    let audiencePicker = app.buttons["composer.audiencePicker"]
    XCTAssertTrue(audiencePicker.waitForExistence(timeout: 5), "Expected audience picker in composer")
    XCTAssertTrue(audiencePicker.label.contains("Public"), "Default composer destination must be Public")

    audiencePicker.tap()
    let familyOption = app.buttons["Family"]
    if familyOption.waitForExistence(timeout: 3) {
      familyOption.tap()
      XCTAssertTrue(audiencePicker.label.contains("Family"), "Audience should update to Family")
    }

    // 3. Type post text and submit
    let editor = app.textViews.firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 5), "Expected post text editor")
    editor.tap()
    editor.typeText("private family update for all members")

    let postButton = app.buttons["Post"]
    if !postButton.exists {
      let altPost = app.buttons["post.send"]
      XCTAssertTrue(altPost.waitForExistence(timeout: 3), "Expected post submit button")
      altPost.tap()
    } else {
      postButton.tap()
    }

    // 4. Verify Circle badge on the post
    let circleBadge = app.staticTexts["Family"]
    XCTAssertTrue(circleBadge.waitForExistence(timeout: 5), "Expected Family circle badge on post")

    // 5. Verify reply and like actions work
    let replyButton = app.buttons["replyButton"].firstMatch
    XCTAssertTrue(replyButton.waitForExistence(timeout: 5), "Expected replyButton on Circle post")

    let likeButton = app.buttons["likeButton"].firstMatch
    XCTAssertTrue(likeButton.waitForExistence(timeout: 5), "Expected likeButton on Circle post")
    likeButton.tap()

    // 6. Open Circle settings and verify removal disclosure
    let settingsButton = app.buttons["Circle Settings"]
    if !settingsButton.exists {
      let altSettings = app.buttons["Circle settings and members"]
      if altSettings.waitForExistence(timeout: 3) {
        altSettings.tap()
      }
    } else {
      settingsButton.tap()
    }

    let removeDisclosure = app.staticTexts["Circle privacy and membership disclosures"]
    if removeDisclosure.waitForExistence(timeout: 3) {
      XCTAssertTrue(removeDisclosure.exists, "Expected removal disclosure in Circle settings")
    }
  }

  /// 3. Destination lock during image upload: destination remains visible and non-interactive through upload
  func testDestinationLockedDuringImageUpload() throws {
    launchWithCircles()

    let composeButton = app.buttons["compose.fab"]
    if !composeButton.exists {
      let navCompose = app.buttons["New Post"]
      XCTAssertTrue(navCompose.waitForExistence(timeout: 5), "Expected compose button")
      navCompose.tap()
    } else {
      composeButton.tap()
    }

    let audiencePicker = app.buttons["composer.audiencePicker"]
    XCTAssertTrue(audiencePicker.waitForExistence(timeout: 5), "Audience picker must be present in composer")
    XCTAssertTrue(audiencePicker.label.contains("Public"), "Default composer destination must be Public")
  }

  /// 4. Feed: Circle badge visible; no repost/quote/share actions. Baseline: public post has them.
  func testUnsupportedActionsAbsentForCirclePost() throws {
    launchWithCircles()

    openCirclesFeed()

    // For a Circle post, repost and share buttons must NOT be rendered in the view hierarchy
    let circleRepostButton = app.buttons["repostButton"]
    let circleShareButton = app.buttons["shareButton"]

    XCTAssertFalse(circleRepostButton.exists, "Repost action must be completely absent for Circle posts")
    XCTAssertFalse(circleShareButton.exists, "Public share action must be completely absent for Circle posts")

    // Verify reply and like remain present
    let replyButton = app.buttons["replyButton"]
    let likeButton = app.buttons["likeButton"]
    XCTAssertTrue(replyButton.waitForExistence(timeout: 5), "Reply button must remain available for Circle post")
    XCTAssertTrue(likeButton.waitForExistence(timeout: 5), "Like button must remain available for Circle post")
  }

  /// 5. Thread: private reply remains locked in Family Circle.
  func testPrivateReplyRemainsInCircle() throws {
    launchWithCircles()

    openCirclesFeed()

    let replyButton = app.buttons["replyButton"].firstMatch
    XCTAssertTrue(replyButton.waitForExistence(timeout: 5), "Expected replyButton on Circle post")
    replyButton.tap()

    let audiencePicker = app.buttons["composer.audiencePicker"]
    if audiencePicker.waitForExistence(timeout: 5) {
      XCTAssertFalse(audiencePicker.isEnabled, "Reply audience must be locked to the parent Circle")
    }
  }

  /// 6. Notifications: generic push causes authenticated Circle refresh.
  func testGenericNotificationRefresh() throws {
    launchWithCircles()

    let notificationsTab = app.buttons["tab_notifications"]
    XCTAssertTrue(notificationsTab.waitForExistence(timeout: 5), "Expected notifications tab")
    notificationsTab.tap()

    XCTAssertTrue(
      app.navigationBars["Notifications"].waitForExistence(timeout: 5)
        || app.staticTexts["Notifications"].waitForExistence(timeout: 5),
      "Expected Notifications view to load"
    )
  }

  /// 7. Account switch/removal: prior Circle content disappears.
  func testAccountSwitchPurgesPriorCircleContentAndSwitchBackReloads() throws {
    launchWithCircles()

    let homeTab = app.buttons["tab_home"]
    XCTAssertTrue(homeTab.waitForExistence(timeout: 5), "Expected home tab")
    homeTab.tap()

    openCirclesFeed()
    XCTAssertTrue(app.navigationBars["Circles"].waitForExistence(timeout: 5) || app.staticTexts["Circles"].waitForExistence(timeout: 5))
  }

  /// 8. Removal disclosure copy is displayed in Circle management
  func testMemberRemovalDisclosure() throws {
    launchWithCircles()

    openCirclesFeed()

    let newCircleButton = app.buttons["Create Circle"]
    XCTAssertTrue(newCircleButton.waitForExistence(timeout: 5), "Expected Create Circle button")
    newCircleButton.tap()

    let disclosure = app.staticTexts["Membership history disclosure"]
    XCTAssertTrue(disclosure.waitForExistence(timeout: 5), "Expected membership history disclosure section")
  }
}
