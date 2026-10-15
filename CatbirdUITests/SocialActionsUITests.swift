import XCTest

@MainActor
final class SocialActionsUITests: XCTestCase {
  private func launch(largeText: Bool = false, contentSizeCategory: String? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--social-actions-ui-fixture"]
    if largeText { app.launchArguments.append("--social-large-text") }
    if let contentSizeCategory {
      app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSizeCategory]
    }
    app.launch()
    XCTAssertTrue(app.buttons["shareButton"].waitForExistence(timeout: 15))
    return app
  }

  func testShareMenuAndCopyDestination() {
    let app = launch()
    app.buttons["shareButton"].tap()
    XCTAssertTrue(app.buttons["shareToBlueskyChat"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["morePostSharing"].exists)
    attach(app, name: "share-menu")
    app.buttons["copyPostLink"].tap()
    XCTAssertTrue(app.staticTexts["https://bsky.app/profile/river.test/post/3socialfixture"].waitForExistence(timeout: 5))
    app.buttons["shareButton"].tap()
    app.buttons["shareToBlueskyChat"].tap()
    let search = app.textFields["Search people or conversations"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("river")
    let recipient = app.buttons.containing(.staticText, identifier: "River").firstMatch
    XCTAssertTrue(recipient.waitForExistence(timeout: 5))
    attach(app, name: "share-recipients")
    recipient.tap()
    XCTAssertTrue(app.staticTexts["Post staged. No message sent."].waitForExistence(timeout: 5))
    let send = app.buttons["Send message"]
    XCTAssertTrue(send.exists)
    XCTAssertFalse(app.staticTexts["Fixture Send tapped 1 time"].exists)
    attach(app, name: "share-destination")
    send.tap()
    XCTAssertTrue(app.staticTexts["Fixture Send tapped 1 time"].waitForExistence(timeout: 5))
  }

  func testNativeMoreCanBeCancelled() {
    let app = launch()
    app.buttons["shareButton"].tap()
    app.buttons["morePostSharing"].tap()
    let close = app.buttons["Close"]
    XCTAssertTrue(close.waitForExistence(timeout: 5))
    attach(app, name: "native-sharing")
    close.tap()
    XCTAssertTrue(app.buttons["shareButton"].waitForExistence(timeout: 5))
  }

  func testLabelMetadataAndFailedAppealPreserveReason() {
    let app = launch()
    app.buttons["fixtureOwnLabels"].tap()
    XCTAssertTrue(app.staticTexts["Joined May 23"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Informational label"].exists)
    XCTAssertTrue(app.staticTexts["Issued by Community Labels (@labels.test)"].exists)
    attach(app, name: "own-label-details")
    app.buttons["Appeal Label"].tap()
    let reason = app.textFields["appealReason"]
    XCTAssertTrue(reason.waitForExistence(timeout: 5))
    reason.tap()
    reason.typeText("This fixture label was applied in error.")
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    app.buttons["appealSubmit"].tap()
    let failure = app.staticTexts["appealSubmissionError"]
    let retry = app.buttons["appealSubmit"]
    XCTAssertTrue(failure.waitForExistence(timeout: 5))
    XCTAssertEqual(failure.label, "Failed to submit your appeal. Your reason is preserved; please try again.")
    let failureVisible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: failure)
    let retryVisible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true AND enabled == true"), object: retry)
    let keyboardDismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
    XCTAssertEqual(XCTWaiter.wait(for: [failureVisible, retryVisible, keyboardDismissed], timeout: 5), .completed)
    XCTAssertTrue(failure.isHittable)
    XCTAssertTrue(retry.isHittable)
    XCTAssertTrue(retry.isEnabled)
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    XCTAssertEqual(retry.label, "Retry Appeal")
    XCTAssertTrue(app.windows.firstMatch.frame.contains(failure.frame))
    XCTAssertTrue(app.windows.firstMatch.frame.contains(retry.frame))
    XCTAssertEqual(reason.value as? String, "This fixture label was applied in error.")
    attach(app, name: "appeal-failure-preserves-reason")
    app.buttons["Cancel"].tap()
    app.buttons["Done"].tap()
    app.buttons["fixtureOtherLabels"].tap()
    XCTAssertTrue(app.staticTexts["Joined May 23"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Appeal Label"].exists)
    attach(app, name: "other-label-details")
  }

  func testGermHandoffCanBeCancelled() {
    let app = launch()
    app.buttons["fixtureGermProfile"].tap()
    let accountLabel = app.buttons
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "profileAccountLabel-"))
      .firstMatch
    XCTAssertTrue(accountLabel.waitForExistence(timeout: 5))
    accountLabel.tap()
    XCTAssertTrue(app.navigationBars["Applied Labels"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Appeal Label"].exists)
    attach(app, name: "profile-label-entry")
    app.buttons["Done"].tap()
    let moreOptions = app.buttons["More Options"]
    XCTAssertTrue(moreOptions.waitForExistence(timeout: 5))
    moreOptions.tap()
    let germ = app.buttons["Germ DM"]
    XCTAssertTrue(germ.waitForExistence(timeout: 5))
    attach(app, name: "profile-germ-action")
    germ.tap()
    let confirmation = app.alerts["Open Germ DM?"]
    XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
    attach(app, name: "germ-handoff-confirmation")
    confirmation.buttons["Cancel"].tap()
    XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
    XCTAssertEqual(app.state, .runningForeground)
    XCTAssertTrue(moreOptions.isHittable)
  }

  /// The menu is UIKit-drawn, so it follows the system text size rather than the fixture's
  /// SwiftUI `dynamicTypeSize`.
  func testGermMenuActionResizesAtLargeText() {
    let standard = openGermMenuAction(contentSizeCategory: "UICTContentSizeCategoryL")
    let large = openGermMenuAction(contentSizeCategory: "UICTContentSizeCategoryAccessibilityXL")
    XCTAssertGreaterThan(large.height, standard.height)
  }

  /// The profile's tab picker starts under the profile information, pins directly below
  /// the navigation bar once scrolled up to it, and stays pinned when switching tabs there,
  /// including to a tab too short to scroll on its own.
  func testProfileTabPickerPinsBelowNavigationBar() {
    let app = launch()
    app.buttons["fixtureGermProfile"].tap()
    XCTAssertTrue(app.staticTexts["Fog lifted off the river just after nine. (1)"].waitForExistence(timeout: 10))
    let picker = app.segmentedControls["profileTabPicker"]
    XCTAssertTrue(picker.waitForExistence(timeout: 5))
    let barBottom = app.navigationBars.firstMatch.frame.maxY
    let restingY = picker.frame.minY
    XCTAssertGreaterThan(restingY, barBottom + 100, "At the top, the picker sits under the profile information")
    XCTAssertTrue(picker.buttons["Posts"].isSelected)
    attach(app, name: "profile-top")

    for _ in 0..<5 where picker.frame.minY > barBottom + 16 {
      app.swipeUp()
    }
    let pinnedY = picker.frame.minY
    // Under the bar, not behind it or the status bar, and no further down than its own padding.
    XCTAssertGreaterThanOrEqual(pinnedY, barBottom - 0.5)
    XCTAssertLessThanOrEqual(pinnedY, barBottom + 16)
    let row = lowestPostText(below: pinnedY + 60, in: app)
    let rowY = row?.frame.minY ?? 0
    // A third of the screen, held before release so that it doesn't fling the row away.
    let window = app.windows.firstMatch
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).press(
      forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.47)),
      withVelocity: .slow, thenHoldForDuration: 0.3
    )
    XCTAssertEqual(picker.frame.minY, pinnedY, accuracy: 1, "The rows scroll; the picker stays")
    XCTAssertNotNil(row, "A post below the pinned picker")
    if let row {
      XCTAssertTrue(row.exists)
      XCTAssertLessThan(row.frame.minY, rowY - 100, "The rows move up under the picker")
    }
    XCTAssertTrue(picker.buttons["Replies"].isHittable, "Above the rows it floats over")
    attach(app, name: "profile-pinned")

    picker.buttons["Replies"].tap()
    let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "(reply 1)")).firstMatch
    XCTAssertTrue(reply.waitForExistence(timeout: 10))
    XCTAssertTrue(picker.buttons["Replies"].isSelected)
    XCTAssertEqual(picker.frame.minY, pinnedY, accuracy: 1)
    attach(app, name: "profile-pinned-replies")

    picker.buttons["Media"].tap()
    XCTAssertTrue(app.staticTexts["No Media Posts"].waitForExistence(timeout: 10))
    XCTAssertEqual(picker.frame.minY, pinnedY, accuracy: 1)
    attach(app, name: "profile-pinned-short-tab")

    for _ in 0..<5 where picker.frame.minY < restingY - 1 {
      app.swipeDown()
    }
    XCTAssertEqual(picker.frame.minY, restingY, accuracy: 1, "Back at the top, under the profile information")
  }

  /// At an accessibility text size the profile information is much taller, and the picker still
  /// pins under the bar with every segment usable.
  func testProfileTabPickerPinsAtAccessibilityTextSize() {
    let app = launch(largeText: true)
    app.buttons["fixtureGermProfile"].tap()
    let picker = app.segmentedControls["profileTabPicker"]
    XCTAssertTrue(picker.waitForExistence(timeout: 10))
    let barBottom = app.navigationBars.firstMatch.frame.maxY
    for _ in 0..<10 where picker.frame.minY > barBottom + 16 {
      app.swipeUp()
    }
    let pinnedY = picker.frame.minY
    XCTAssertGreaterThanOrEqual(pinnedY, barBottom - 0.5)
    XCTAssertLessThanOrEqual(pinnedY, barBottom + 16)
    for segment in ["Posts", "Replies", "Media", "More"] {
      XCTAssertTrue(picker.buttons[segment].isHittable, "\(segment) is usable while pinned")
    }
    attach(app, name: "profile-pinned-large-text")
    picker.buttons["Replies"].tap()
    let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "(reply 1)")).firstMatch
    XCTAssertTrue(reply.waitForExistence(timeout: 10))
    XCTAssertTrue(picker.buttons["Replies"].isSelected)
    XCTAssertEqual(picker.frame.minY, pinnedY, accuracy: 1)
  }

  func testLabelInspectorAtAccessibilityTextSize() {
    let app = launch(largeText: true)
    app.buttons["fixtureOtherLabels"].tap()
    XCTAssertTrue(app.staticTexts["Joined May 23"].waitForExistence(timeout: 5))
    attach(app, name: "label-details-large-text")
    XCTAssertTrue(app.buttons["Done"].isHittable)
  }

  func testSavedDraftsPreserveRecoveryAndExplainUnavailableMedia() {
    let app = launch()
    app.buttons["fixtureSavedDrafts"].tap()
    XCTAssertTrue(app.staticTexts["A draft saved on this device."].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["My earlier wording, kept after an edit on another device."].exists)
    attach(app, name: "saved-drafts-recovery")
    app.staticTexts["A draft with a photo saved in another app."].tap()
    XCTAssertTrue(app.buttons["Open Without Media"].waitForExistence(timeout: 5))
    attach(app, name: "draft-media-limit")
    if app.buttons["Cancel"].exists {
      app.buttons["Cancel"].tap()
    } else {
      // The iOS 27 compact popover dismisses by tapping outside its menu.
      app.navigationBars["Drafts"].tap()
    }
    XCTAssertFalse(app.buttons["Open Without Media"].exists)
    XCTAssertTrue(app.staticTexts["A draft with a photo saved in another app."].exists)
    app.buttons["Close"].tap()
    XCTAssertTrue(app.buttons["fixtureSavedDrafts"].exists)
  }

  /// Opens the Germ profile's More Options menu at a system text size, checks the Germ DM item
  /// is fully visible and opens the handoff confirmation, cancels it, and returns the item's size.
  private func openGermMenuAction(contentSizeCategory: String) -> CGSize {
    let app = launch(contentSizeCategory: contentSizeCategory)
    app.buttons["fixtureGermProfile"].tap()
    let moreOptions = app.buttons["More Options"]
    XCTAssertTrue(moreOptions.waitForExistence(timeout: 5))
    moreOptions.tap()
    let germ = app.buttons["Germ DM"]
    XCTAssertTrue(germ.waitForExistence(timeout: 5))
    XCTAssertTrue(germ.isHittable)
    XCTAssertTrue(app.windows.firstMatch.frame.contains(germ.frame))
    attach(app, name: "germ-menu-\(contentSizeCategory)")
    let size = germ.frame.size
    germ.tap()
    let confirmation = app.alerts["Open Germ DM?"]
    XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
    confirmation.buttons["Cancel"].tap()
    XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
    XCTAssertEqual(app.state, .runningForeground)
    app.terminate()
    return size
  }

  /// The lowest visible fixture post text ("… (n)") whose top is below `minimumY`, so that a
  /// drag up leaves it on screen. Queried by its label, so it can be found again after scrolling.
  private func lowestPostText(below minimumY: CGFloat, in app: XCUIApplication) -> XCUIElement? {
    let posts = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", ")"))
    let visible = posts.allElementsBoundByIndex.filter { $0.frame.minY > minimumY && $0.isHittable }
    guard let text = visible.max(by: { $0.frame.minY < $1.frame.minY }) else { return nil }
    return app.staticTexts[text.label]
  }

  private func attach(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
