import XCTest

@MainActor
final class SocialActionsUITests: XCTestCase {
  private func launch(largeText: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--social-actions-ui-fixture"]
    if largeText { app.launchArguments.append("--social-large-text") }
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
    let accountLabels = app.buttons["1 account label"]
    XCTAssertTrue(accountLabels.waitForExistence(timeout: 5))
    accountLabels.tap()
    XCTAssertTrue(app.navigationBars["Applied Labels"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Appeal Label"].exists)
    attach(app, name: "profile-label-entry")
    app.buttons["Done"].tap()
    let germ = app.buttons["Open Germ DM"]
    XCTAssertTrue(germ.waitForExistence(timeout: 5))
    attach(app, name: "profile-germ-action")
    germ.tap()
    XCTAssertTrue(app.alerts["Open Germ DM?"].waitForExistence(timeout: 5))
    attach(app, name: "germ-handoff-confirmation")
    app.alerts.buttons["Cancel"].tap()
    XCTAssertTrue(germ.exists)
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

  private func attach(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
